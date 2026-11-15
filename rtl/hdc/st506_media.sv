// ST-506 drive emulator, media side: sector streaming from the image,
// the write path back to it, and the session store of recorded track
// formats.  The image stays in external RAM behind an sd_* block
// interface (512-byte blocks, levels as sys/hps_io.sv); this side holds
// only the sectors being read.
//
// Image layout: flat; a cylinder is the byte range cyl * bpc * 512, a
// sector (head, sec) starts at byte ((head * spt + sec) << size_l2) of
// its cylinder.
//
// Sector buffer: two entries per head (16 x 2^MAX_L2 bytes), each
// tagged with the sector it holds, with the data-field ECC computed as
// it fills.  For every head the scanner keeps the next two data fields
// that have not yet passed the head (the one under it counts until its
// last ECC byte): both entries of the head hold them, so a head switch
// finds the sector under the new head at once.  The selected head is
// scanned first.  A fetch is one block request (two for 1024-byte
// sectors); its bytes are readable as they arrive (in order), the ECC
// once the sector is complete.
//
// Writes: a committed data field goes out at once as one block write
// from its half of the two-field staging buffer (the decoder fills the
// other half meanwhile); a sector under 512 bytes is merged into its block
// (read, then write).  Entries holding the sector are dropped and
// refetched after the write.
//
// Track formats: a Write Format's IDs and gaps are written as one block
// to the format region, block {cyl, head}, with sd_fmt high.  A bit per
// track (cleared at mount) says which tracks have one; on a cylinder
// change those are read back into the drive's format table.  Formats
// last until the image is ejected; the image itself holds none.
// Format block: word w (bytes 4w..4w+3, MSB first) = ID w for w <
// FMT_SLOTS ({bad, size[1:0], head[2:0], cyl[10:0], sec[7:0]}); word 126
// = {gap1, gap3}; word 127 = number of slots.
//
// sd_* jobs, one at a time: commit, fetch, format write, cylinder change.
// `ready` = the cylinder `rdy_cyl` is loaded and every head's next data
// field is in the buffer or on its way; it stays up until the next
// cylinder change.  `late` pulses when a fetch, a commit or a format
// write misses the time the disk needs it.
//
// Server contract: requests are levels until ack rises; read data comes
// in address order with sd_buff_wr; write data is read from sd_buff_din
// one clk after sd_buff_addr changes; a read after a write of the same
// block returns the written data.
`default_nettype none

module st506_media #(
  parameter int unsigned MAX_L2    = 9,      // log2 of the largest sector size (9 or 10)
  parameter int unsigned FMT_SLOTS = 64,
  parameter int unsigned MAX_CYLS  = 2048
) (
  input  logic        clk,
  input  logic        rst_n,
  // configuration, from the mount
  input  logic        mount_ev,       // a mount or eject happened: drop everything
  input  logic        present,
  input  logic [3:0]  size_l2,
  input  logic [11:0] bpc,            // 512-byte blocks per cylinder
  input  logic [7:0]  spt,
  input  logic [3:0]  heads,
  // cylinder and rotation
  input  logic [10:0] want_cyl,
  output logic        ready,
  output logic [10:0] rdy_cyl,
  output logic        load_ev,        // a cylinder change starts (format table goes)
  input  logic [13:0] pos,            // byte of the revolution under the heads
  input  logic        byte_tick,      // a byte starts (walker request)
  input  logic [2:0]  sel_head,
  input  logic        wg_busy,        // the ID table port is the write channel's
  // a Write Format pass in progress on fp_head: the sectors of its first
  // two IDs (fp_n of them written so far)
  input  logic        fp_act,
  input  logic [2:0]  fp_head,
  input  logic [1:0]  fp_n,
  input  logic [7:0]  fp_s0,
  input  logic [7:0]  fp_s1,
  // format of head pf_h (drive's table)
  output logic [2:0]  pf_h,
  input  logic        pf_custom,
  input  logic [15:0] pf_gap1,
  input  logic [15:0] pf_gap,
  input  logic [7:0]  pf_nsl,
  // ID table read for the scanner (granted when the walker does not use it)
  output logic [$clog2(8*FMT_SLOTS)-1:0] pf_id_addr,
  input  logic        pf_id_gnt,
  input  logic [24:0] id_q,
  // format table loads
  output logic        fl_custom_we,
  output logic [7:0]  fl_custom,
  output logic        fl_hdr_we,
  output logic [2:0]  fl_h,
  output logic [15:0] fl_gap1,
  output logic [15:0] fl_gap,
  output logic [7:0]  fl_nsl,
  output logic        fl_id_we,
  output logic [$clog2(8*FMT_SLOTS)-1:0] fl_id_addr,
  output logic [24:0] fl_id_d,
  // walker lookup and reads
  input  logic [2:0]  lk_head,
  input  logic [7:0]  lk_sec,
  output logic        lk_hit,
  output logic [3:0]  lk_ent,
  output logic        lk_full,
  output logic [10:0] lk_cnt,
  input  logic [MAX_L2+3:0] wk_addr,
  output logic [7:0]        wk_q,
  input  logic [3:0]        ek_idx,
  output logic [31:0]       ek_q,
  // write decoder: staging buffer and commit
  input  logic        st_we,
  input  logic [9:0]  st_addr,
  input  logic [7:0]  st_d,
  input  logic        cm_req,         // pulse: commit staging to (cm_head, cm_sec)
  input  logic [2:0]  cm_head,
  input  logic [7:0]  cm_sec,
  // format commit
  input  logic        fb_we,          // an ID of the pass in progress
  input  logic [6:0]  fb_addr,
  input  logic [24:0] fb_d,
  input  logic        fc_req,         // pulse: the pass's format is recorded
  input  logic [10:0] fc_cyl,
  input  logic [2:0]  fc_head,
  input  logic [7:0]  fc_custom,      // the cylinder's format bits after it
  input  logic [15:0] fc_gap1,
  input  logic [15:0] fc_gap,
  input  logic [7:0]  fc_nsl,
  output logic        late,
  // sd_* (one slot, plus the format region)
  output logic [31:0] sd_lba,
  output logic        sd_rd,
  output logic        sd_wr,
  output logic        sd_fmt,
  input  logic        sd_ack,
  input  logic [8:0]  sd_buff_addr,
  input  logic [7:0]  sd_buff_dout,
  output logic [7:0]  sd_buff_din,
  input  logic        sd_buff_wr
);
  import st506_pkg::*;

  localparam int unsigned HB  = 1 << MAX_L2;
  localparam int unsigned IW  = $clog2(8 * FMT_SLOTS);
  localparam int unsigned KW  = $clog2(FMT_SLOTS);
  localparam int unsigned CW  = $clog2(MAX_CYLS);
  localparam logic [16:0] Rev = 17'(BytesPerRev);

  logic unused_ok;
  assign unused_ok = &{1'b0, st_addr[9], heads[3], id_q[24:8]};

  // ------------------------------------------------------------------
  // Memories

  (* ramstyle = "M10K" *)          logic [7:0]  dat_mem [0:16*HB-1];
  (* ramstyle = "no_rw_check, MLAB" *) logic [31:0] ecc_mem [0:15];
  (* ramstyle = "M10K" *)          logic [7:0]  stg_mem [0:2*HB-1];
  (* ramstyle = "M10K" *)          logic [7:0]  rmw_mem [0:511];
  (* ramstyle = "no_rw_check, MLAB" *) logic [24:0] fb_mem  [0:FMT_SLOTS-1];
  (* ramstyle = "M10K" *)          logic [7:0]  bm_mem  [0:MAX_CYLS-1];

  logic              dat_we;
  logic [MAX_L2+3:0] dat_waddr;
  logic              ecc_we;
  logic [3:0]        ecc_widx;
  logic [31:0]       ecc_wd;
  logic              rmw_we;
  logic [8:0]        sv_rmw_a;
  logic [KW-1:0]     sv_fb_a;
  logic [7:0]        stg_q, rmw_q;
  logic [24:0]       fb_q;
  logic              bm_we;
  logic [CW-1:0]     bm_waddr, bm_raddr;
  logic [7:0]        bm_wd, bm_q;
  logic [MAX_L2-1:0] stg_ra;

  always_ff @(posedge clk) begin
    if (dat_we) dat_mem[dat_waddr] <= sd_buff_dout;
    wk_q <= dat_mem[wk_addr];
  end
  always_ff @(posedge clk) begin
    if (ecc_we) ecc_mem[ecc_widx] <= ecc_wd;
    ek_q <= ecc_mem[ek_idx];
  end
  always_ff @(posedge clk) begin
    if (st_we) stg_mem[{wh_q, st_addr[MAX_L2-1:0]}] <= st_d;
    stg_q <= stg_mem[{ah_q, stg_ra}];
  end
  always_ff @(posedge clk) begin
    if (rmw_we) rmw_mem[sd_buff_addr] <= sd_buff_dout;
    rmw_q <= rmw_mem[sv_rmw_a];
  end
  always_ff @(posedge clk) begin
    if (fb_we && fb_addr < 7'(FMT_SLOTS)) fb_mem[KW'(fb_addr)] <= fb_d;
    fb_q <= fb_mem[sv_fb_a];
  end
  always_ff @(posedge clk) begin
    if (bm_we) bm_mem[bm_waddr] <= bm_wd;
    bm_q <= bm_mem[bm_raddr];
  end

  // ------------------------------------------------------------------
  // Geometry helpers

  logic [10:0] size_c;
  logic [11:0] dend_c;      // slot offset past the data field's last ECC byte
  logic [15:0] slen_c;      // slot length of head pf_h
  logic [15:0] g1_c;
  logic [7:0]  nsl_c;
  assign size_c = 11'd1 << size_l2;
  assign dend_c = 12'(OffData) + 12'd6 + {1'b0, size_c};
  assign slen_c = {5'd0, SlotFixed0 + size_c} + (pf_custom ? pf_gap : Gap3Def);
  assign g1_c   = pf_custom ? pf_gap1 : Gap1Def;
  assign nsl_c  = pf_custom ? pf_nsl : spt;

  // ------------------------------------------------------------------
  // Entries

  // Justification: entry valid bits and tags (reg-a).
  logic [15:0] ev_q;
  logic [7:0]  etag_q [16];
  // Justification: the fetch in progress: entry, discard, bytes filled, ECC (reg-a).
  logic        fill_q, disc_q;
  logic [3:0]  fent_q;
  logic [10:0] fcnt_q;
  logic [31:0] fecc_q;

  logic [3:0] lk_e0, lk_e1;
  logic       lk_m0, lk_m1;
  assign lk_e0 = {lk_head, 1'b0};
  assign lk_e1 = {lk_head, 1'b1};
  assign lk_m0 = (ev_q[lk_e0] || (fill_q && !disc_q && fent_q == lk_e0)) && etag_q[lk_e0] == lk_sec;
  assign lk_m1 = (ev_q[lk_e1] || (fill_q && !disc_q && fent_q == lk_e1)) && etag_q[lk_e1] == lk_sec;
  assign lk_hit  = lk_m0 || lk_m1;
  assign lk_ent  = lk_m0 ? lk_e0 : lk_e1;
  assign lk_full = ev_q[lk_ent];
  assign lk_cnt  = fcnt_q;

  // ------------------------------------------------------------------
  // Scanner: per head, the next two data fields and their sectors.

  typedef enum logic [3:0] {
    PIdle, PSetup, PDiv0, PDiv, PPick, PIdA, PIdAv, PIdB, PIdBv, PChk, PWait, PNext
  } pf_e;

  // Justification: scanner state, round, head, slot search (reg-a).
  pf_e         ps_q;
  logic [3:0]  rnd_q;
  logic [2:0]  rh_q, h_q;
  logic        clean_q;
  logic [15:0] rem_q, base_q;
  logic [7:0]  k_q;
  logic [7:0]  f1_q, f2_q, s1_q, s2_q;
  logic [16:0] f1st_q, f2st_q;       // slot start, + one revolution when wrapped
  logic        sp_q;                 // the head's format pass sets its wanted sectors
  // Justification: fetch request to the client and its deadline (reg-a).
  logic        fr_q;
  logic [3:0]  fr_ent_q;
  logic [2:0]  fr_h_q;
  logic [7:0]  fr_s_q;
  // Justification: per head, the sectors the last scan wanted (reg-a).
  logic [7:0]  pv_q;
  logic [7:0]  pw1_q [8];
  logic [7:0]  pw2_q [8];
  // Justification: the cache: cylinder loaded, LBA base, ready (reg-a).
  logic        cv_q, rdy_q;
  logic [10:0] ccyl_q;
  logic [31:0] cbase_q;

  logic        fr_take, fr_done;   // client: fetch started / finished
  logic        scan_late;

  // head of round step rnd_q (0 = the selected head)
  logic [2:0] rstep_h_c;
  logic       rstep_skip_c;
  assign rstep_h_c    = (rnd_q == 4'd0) ? rh_q : 3'(rnd_q - 4'd1);
  assign rstep_skip_c = {1'b0, rstep_h_c} >= heads || (rnd_q != 4'd0 && rstep_h_c == rh_q);

  // default slot -> sector for head h_q; the head mod spt is registered
  // (h_q is set in PSetup, read in PPick at the earliest).
  // Justification: breaks the spt -> sector path (reg-b).
  logic [7:0] hmod_c, hmod_q, ds1_c, ds2_c;
  always_comb begin
    hmod_c = head_mod(h_q, spt);
  end
  always_ff @(posedge clk) hmod_q <= hmod_c;
  assign ds1_c = (f1_q >= hmod_q) ? f1_q - hmod_q : f1_q + spt - hmod_q;
  assign ds2_c = (f2_q >= hmod_q) ? f2_q - hmod_q : f2_q + spt - hmod_q;

  // check: which of the two wanted sectors is missing, and the victim
  logic       n1_c, n2_c, has1_c, has2_c, miss1_c, miss2_c;
  logic [3:0] e0_c, e1_c, vic_c;
  logic       w0_c;
  logic [16:0] d_c;
  logic signed [17:0] dist_c;
  logic       past_c;
  logic [7:0] fs_c;
  function automatic logic holds(input logic [15:0] v, input logic f, input logic dsc, input logic [3:0] fe,
                                 input logic [3:0] e, input logic [7:0] tg, input logic [7:0] s);
    return (v[e] || (f && !dsc && fe == e)) && tg == s;
  endfunction
  assign e0_c    = {h_q, 1'b0};
  assign e1_c    = {h_q, 1'b1};
  assign n1_c    = s1_q < spt;
  assign n2_c    = s2_q < spt && f2_q != f1_q;
  assign has1_c  = holds(ev_q, fill_q, disc_q, fent_q, e0_c, etag_q[e0_c], s1_q) ||
                   holds(ev_q, fill_q, disc_q, fent_q, e1_c, etag_q[e1_c], s1_q);
  assign has2_c  = holds(ev_q, fill_q, disc_q, fent_q, e0_c, etag_q[e0_c], s2_q) ||
                   holds(ev_q, fill_q, disc_q, fent_q, e1_c, etag_q[e1_c], s2_q);
  assign miss1_c = n1_c && !has1_c;
  assign miss2_c = n2_c && !has2_c;
  assign w0_c    = (n1_c && holds(ev_q, fill_q, disc_q, fent_q, e0_c, etag_q[e0_c], s1_q)) ||
                   (n2_c && holds(ev_q, fill_q, disc_q, fent_q, e0_c, etag_q[e0_c], s2_q));
  assign vic_c   = w0_c ? e1_c : e0_c;
  assign fs_c    = miss1_c ? s1_q : s2_q;
  assign d_c     = (miss1_c ? f1st_q : f2st_q) + 17'(OffData) + 17'd2;
  assign dist_c  = signed'({1'b0, d_c}) - signed'({4'd0, pos});
  assign past_c  = dist_c <= 18'sd1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ps_q <= PIdle;  rnd_q <= 4'd0;  rh_q <= 3'd0;  h_q <= 3'd0;  clean_q <= 1'b0;
      rem_q <= 16'd0;  base_q <= 16'd0;  k_q <= 8'd0;
      f1_q <= 8'd0;  f2_q <= 8'd0;  s1_q <= 8'd0;  s2_q <= 8'd0;  f1st_q <= 17'd0;  f2st_q <= 17'd0;
      sp_q <= 1'b0;
      fr_q <= 1'b0;  fr_ent_q <= 4'd0;  fr_h_q <= 3'd0;  fr_s_q <= 8'd0;
      pv_q <= 8'h00;  rdy_q <= 1'b0;  scan_late <= 1'b0;
      for (int i = 0; i < 8; i++) begin pw1_q[i] <= 8'd0; pw2_q[i] <= 8'd0; end
    end else if (mount_ev || !cv_q) begin
      ps_q <= PIdle;  fr_q <= 1'b0;  pv_q <= 8'h00;  rdy_q <= 1'b0;  scan_late <= 1'b0;
    end else begin
      scan_late <= 1'b0;
      if (fr_take) fr_q <= 1'b0;
      if (cm_req) pv_q[cm_head] <= 1'b0;
      if (fc_req) pv_q[fc_head] <= 1'b0;
      unique case (ps_q)
        PIdle: begin
          if (ccyl_q == want_cyl) begin
            rh_q <= sel_head;  rnd_q <= 4'd0;  clean_q <= 1'b1;  ps_q <= PSetup;
          end
        end
        PSetup: begin
          sp_q <= 1'b0;
          if (rstep_skip_c) ps_q <= PNext;
          else if (fp_act && rstep_h_c == fp_head) begin
            h_q <= rstep_h_c;
            if (fp_n == 2'd0) ps_q <= PNext;
            else begin
              sp_q <= 1'b1;  f1_q <= 8'd0;  f2_q <= (fp_n > 2'd1) ? 8'd1 : 8'd0;
              s1_q <= fp_s0;  s2_q <= fp_s1;  f1st_q <= 17'd0;  f2st_q <= 17'd0;
              ps_q <= PChk;
            end
          end else begin h_q <= rstep_h_c;  ps_q <= PDiv0; end
        end
        PDiv0: begin
          if (nsl_c == 8'd0) begin
            ps_q <= PNext;
          end else if ({2'd0, pos} < g1_c) begin
            k_q <= 8'd0;  rem_q <= 16'd0;  base_q <= g1_c;  ps_q <= PPick;
            f1_q <= 8'd0;  f1st_q <= {1'b0, g1_c};
            f2_q <= (nsl_c > 8'd1) ? 8'd1 : 8'd0;
            f2st_q <= (nsl_c > 8'd1) ? {1'b0, g1_c} + {1'b0, slen_c} : {1'b0, g1_c} + Rev;
          end else begin
            rem_q <= {2'd0, pos} - g1_c;  k_q <= 8'd0;  base_q <= g1_c;  ps_q <= PDiv;
          end
        end
        PDiv: begin
          if (rem_q >= slen_c && k_q < nsl_c) begin
            rem_q <= rem_q - slen_c;  k_q <= k_q + 8'd1;  base_q <= base_q + slen_c;
          end else begin
            if (k_q < nsl_c && rem_q < {4'd0, dend_c}) begin
              f1_q <= k_q;  f1st_q <= {1'b0, base_q};
              f2_q <= (k_q + 8'd1 < nsl_c) ? k_q + 8'd1 : 8'd0;
              f2st_q <= (k_q + 8'd1 < nsl_c) ? {1'b0, base_q} + {1'b0, slen_c} : {1'b0, g1_c} + Rev;
            end else if (k_q + 8'd1 < nsl_c) begin
              f1_q <= k_q + 8'd1;  f1st_q <= {1'b0, base_q} + {1'b0, slen_c};
              f2_q <= (k_q + 8'd2 < nsl_c) ? k_q + 8'd2 : 8'd0;
              f2st_q <= (k_q + 8'd2 < nsl_c) ? {1'b0, base_q} + {slen_c, 1'b0} : {1'b0, g1_c} + Rev;
            end else begin
              f1_q <= 8'd0;  f1st_q <= {1'b0, g1_c} + Rev;
              f2_q <= (nsl_c > 8'd1) ? 8'd1 : 8'd0;
              f2st_q <= {1'b0, g1_c} + Rev + ((nsl_c > 8'd1) ? {1'b0, slen_c} : Rev);
            end
            ps_q <= PPick;
          end
        end
        PPick: begin
          if (pf_custom) ps_q <= PIdA;
          else begin s1_q <= ds1_c;  s2_q <= ds2_c;  ps_q <= PChk; end
        end
        PIdA: begin
          if (pf_id_gnt)    ps_q <= PIdAv;
          else if (wg_busy) begin clean_q <= 1'b0; ps_q <= PNext; end
        end
        PIdAv: begin s1_q <= id_q[7:0];  ps_q <= PIdB; end
        PIdB: begin
          if (pf_id_gnt)    ps_q <= PIdBv;
          else if (wg_busy) begin clean_q <= 1'b0; ps_q <= PNext; end
        end
        PIdBv: begin s2_q <= id_q[7:0];  ps_q <= PChk; end
        PChk: begin
          pv_q[h_q]  <= 1'b1;
          pw1_q[h_q] <= n1_c ? s1_q : 8'hFF;
          pw2_q[h_q] <= n2_c ? s2_q : 8'hFF;
          if (miss1_c || miss2_c) clean_q <= 1'b0;
          if (miss1_c || miss2_c) begin
            fr_q <= 1'b1;  fr_ent_q <= vic_c;  fr_h_q <= h_q;  fr_s_q <= fs_c;
            scan_late <= rdy_q && !wg_busy && !sp_q && past_c && pv_q[h_q] && (pw1_q[h_q] == fs_c || pw2_q[h_q] == fs_c);
            ps_q <= PWait;
          end else begin
            ps_q <= PNext;
          end
        end
        PWait: begin
          if (fr_done) begin rnd_q <= 4'd0;  rh_q <= sel_head;  clean_q <= 1'b1;  ps_q <= PSetup; end
        end
        PNext: begin
          if (rnd_q == 4'd8) begin
            if (clean_q) rdy_q <= 1'b1;
            ps_q <= PIdle;
          end else begin
            rnd_q <= rnd_q + 4'd1;  ps_q <= PSetup;
          end
        end
        default: ps_q <= PIdle;
      endcase
    end
  end

  assign pf_h       = h_q;
  assign pf_id_addr = IW'({h_q, ((ps_q == PIdA) ? f1_q[KW-1:0] : f2_q[KW-1:0])});

  // ------------------------------------------------------------------
  // Fetch deadline: from the issue, byte ticks until the walker asks for
  // the first data byte; then one data byte per tick, the ECC at the end.

  // Justification: deadline tracker of the fetch in flight (reg-a).
  logic        trk_q;
  logic [15:0] dl_q;
  logic [10:0] need_q;
  logic        trk_late;

  // ------------------------------------------------------------------
  // sd client

  typedef enum logic [3:0] {
    CIdle, CClr, CMul, CBm0, CBm1, CFlNext, CReq, CXfer, CNext
  } cl_e;
  typedef enum logic [2:0] {JFetch, JCmRd, JCmWr, JFw, JFl} job_e;

  // Justification: client state, job, transfer parameters (reg-a).
  cl_e         cs_q;
  job_e        job_q;
  logic        blk_q;              // second block of a 1024-byte sector
  logic [8:0]  boff_q;             // sector offset in its block (under 512 bytes)
  logic [31:0] lba_q;
  logic        rd_q, wr_q, fmt_q;
  logic        ack_q;
  // Justification: pending commit and format write (reg-a).
  logic        cm_pend_q, cm_act_q;
  logic        wh_q;               // staging half the decoder writes
  logic        ph_q, ah_q;         // staging half of the pending / active commit
  logic [2:0]  cmh_q;
  logic [7:0]  cms_q;
  logic        fw_pend_q;
  logic        fw_ok_q;            // a clean scan round since the format commit
  logic [13:0] fw_blk_q;
  logic [15:0] fw_g1_q, fw_g_q;
  logic [7:0]  fw_n_q;
  // Justification: mount clear of the format bits (reg-a).
  logic          clr_q;
  logic [CW-1:0] clra_q;
  // Justification: cylinder change: multiplier, format bits, head loop (reg-a).
  logic [31:0] macc_q, mcand_q;
  logic [11:0] mplier_q;
  logic [7:0]  cust_q;
  logic [3:0]  flh_q;
  logic        load_q;
  // Justification: format block load: byte assembly and gaps (reg-a).
  logic [23:0] facc_q;
  logic [15:0] fg1_q, fg_q;
  logic        flhw_q;
  logic [7:0]  fln_q;
  logic        flidw_q;
  logic [IW-1:0] flia_q;
  logic [24:0] flid_q;
  // Justification: late pulses for staging and format block reuse (reg-a).
  logic        wlate_q;

  logic        ack_rise_c, xfer_c;
  logic [20:0] soff_c;
  logic        cm_go_c, cm_take_c, fr_go_c, fw_go_c, sw_go_c;

  assign ack_rise_c = sd_ack && !ack_q;
  assign xfer_c     = sd_ack && sd_buff_wr && cs_q == CXfer;

  // sector byte offset in the cylinder for (head, sec)
  function automatic logic [20:0] sec_off(input logic [2:0] h, input logic [7:0] s, input logic [7:0] n,
                                          input logic [3:0] l2);
    logic [20:0] t;
    t = (h[0] ? {13'd0, n} : 21'd0) + (h[1] ? {12'd0, n, 1'b0} : 21'd0) + (h[2] ? {11'd0, n, 2'b0} : 21'd0) +
        {13'd0, s};
    return t << l2;
  endfunction
  assign soff_c = cm_go_c ? sec_off(cmh_q, cms_q, spt, size_l2) : sec_off(fr_h_q, fr_s_q, spt, size_l2);

  assign cm_go_c   = cm_pend_q;
  assign cm_take_c = cs_q == CIdle && !sd_ack && !clr_q && cm_go_c;
  assign fr_go_c = fr_q && cv_q && ccyl_q == want_cyl;
  assign fw_go_c = fw_pend_q && (fw_ok_q || !cv_q || ccyl_q != want_cyl);
  assign sw_go_c = present && (!cv_q || ccyl_q != want_cyl) && !cm_req;

  assign fr_take = cs_q == CIdle && !sd_ack && !clr_q && !cm_go_c && fr_go_c;
  assign fr_done = cs_q == CNext && job_q == JFetch && !(size_l2 == 4'd10 && !blk_q);

  // fill writes
  logic [11:0] fsb_c;    // sector byte of this block byte
  logic        fin_c;
  assign fsb_c = {2'd0, blk_q, sd_buff_addr} - {3'd0, boff_q};
  assign fin_c = fsb_c < {1'b0, size_c};
  assign dat_we    = xfer_c && job_q == JFetch && fin_c;
  assign dat_waddr = {fent_q, fsb_c[MAX_L2-1:0]};
  assign rmw_we    = xfer_c && job_q == JCmRd;
  assign ecc_we    = fr_done && !disc_q;
  assign ecc_widx  = fent_q;
  assign ecc_wd    = fecc_q;

  // write data source
  logic [9:0]  sv_rel_c;
  logic        sv_in_c;
  logic [1:0]  sv_sel_c;   // 0 staging, 1 rmw, 2 format block, 3 format header
  // Justification: source select and byte lane of the registered read (reg-a).
  logic [1:0]  sv_sel_q;
  logic [1:0]  sv_lane_q;
  logic        sv_hw_q;
  logic        sv_fbok_q;
  assign sv_rel_c = {1'b0, sd_buff_addr} - {1'b0, boff_q};
  assign sv_in_c  = sd_buff_addr >= boff_q && sv_rel_c < size_c[9:0];
  always_comb begin
    sv_rmw_a = sd_buff_addr;
    sv_fb_a  = KW'(sd_buff_addr[8:2]);
    stg_ra   = MAX_L2'({blk_q, sd_buff_addr});
    sv_sel_c = 2'd0;
    if (job_q == JFw) begin
      sv_sel_c = (sd_buff_addr[8:2] >= 7'd126) ? 2'd3 : 2'd2;
    end else if (size_l2 < 4'd9) begin
      stg_ra   = MAX_L2'(sv_rel_c[8:0]);
      sv_sel_c = sv_in_c ? 2'd0 : 2'd1;
    end
  end

  logic [31:0] hdr_c;
  always_ff @(posedge clk) begin
    sv_sel_q  <= sv_sel_c;
    sv_lane_q <= sd_buff_addr[1:0];
    sv_hw_q   <= sd_buff_addr[2];
    sv_fbok_q <= sd_buff_addr[8:2] < 7'(FMT_SLOTS);
  end
  assign hdr_c = sv_hw_q ? {24'd0, fw_n_q} : {fw_g1_q, fw_g_q};
  always_comb begin
    logic [31:0] w;
    w = 32'd0;
    case (sv_sel_q)
      2'd0:    sd_buff_din = stg_q;
      2'd1:    sd_buff_din = rmw_q;
      2'd2: begin
        w = sv_fbok_q ? {7'd0, fb_q} : 32'd0;
        sd_buff_din = w[{~sv_lane_q, 3'b000} +: 8];
      end
      default: sd_buff_din = hdr_c[{~sv_lane_q, 3'b000} +: 8];
    endcase
  end

  // bitmap ports
  always_comb begin
    bm_we    = 1'b0;
    bm_waddr = clra_q;
    bm_wd    = 8'h00;
    if (clr_q) begin
      bm_we = 1'b1;
    end else if (fc_req) begin
      bm_we    = 1'b1;
      bm_waddr = CW'(fc_cyl);
      bm_wd    = fc_custom;
    end
  end
  assign bm_raddr = CW'(ccyl_q);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) ack_q <= 1'b0;
    else        ack_q <= sd_ack;
  end

  // pending commit and format write
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cm_pend_q <= 1'b0;  cmh_q <= 3'd0;  cms_q <= 8'd0;  wh_q <= 1'b0;  ph_q <= 1'b0;  ah_q <= 1'b0;
      fw_pend_q <= 1'b0;  fw_ok_q <= 1'b0;  fw_blk_q <= 14'd0;  fw_g1_q <= 16'd0;  fw_g_q <= 16'd0;  fw_n_q <= 8'd0;
      wlate_q <= 1'b0;
    end else if (mount_ev) begin
      cm_pend_q <= 1'b0;  fw_pend_q <= 1'b0;  wlate_q <= 1'b0;
    end else begin
      wlate_q <= (st_we && ((cm_pend_q && ph_q == wh_q) || (cm_act_q && ah_q == wh_q))) ||
                 (fb_we && fw_pend_q) || (cm_req && cm_pend_q && !cm_take_c) ||
                 (fc_req && fw_pend_q);
      if (cm_req) begin
        cm_pend_q <= 1'b1;  cmh_q <= cm_head;  cms_q <= cm_sec;  ph_q <= wh_q;  wh_q <= !wh_q;
      end else if (cm_take_c) begin
        cm_pend_q <= 1'b0;
      end
      if (cm_take_c) ah_q <= ph_q;
      if (ps_q == PNext && rnd_q == 4'd8 && clean_q) fw_ok_q <= 1'b1;
      if (fc_req) begin
        fw_pend_q <= 1'b1;  fw_ok_q <= 1'b0;  fw_blk_q <= {fc_cyl, fc_head};
        fw_g1_q <= fc_gap1;  fw_g_q <= fc_gap;  fw_n_q <= fc_nsl;
      end else if (cs_q == CNext && job_q == JFw) begin
        fw_pend_q <= 1'b0;
      end
    end
  end

  // entries
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ev_q <= 16'h0000;  fill_q <= 1'b0;  disc_q <= 1'b0;  fent_q <= 4'd0;  fcnt_q <= 11'd0;
      fecc_q <= 32'h0;
      for (int i = 0; i < 16; i++) etag_q[i] <= 8'd0;
    end else if (mount_ev || load_q) begin
      ev_q <= 16'h0000;  fill_q <= 1'b0;  disc_q <= 1'b0;
    end else begin
      if (fr_take) begin
        ev_q[fr_ent_q] <= 1'b0;  etag_q[fr_ent_q] <= fr_s_q;
        fill_q <= 1'b1;  disc_q <= 1'b0;  fent_q <= fr_ent_q;  fcnt_q <= 11'd0;  fecc_q <= EccAfterMark;
      end
      if (dat_we && fsb_c[10:0] == fcnt_q) begin
        fcnt_q <= fcnt_q + 11'd1;
        fecc_q <= ecc32_byte(fecc_q, sd_buff_dout);
      end
      if (fr_done) begin
        fill_q <= 1'b0;
        ev_q[fent_q] <= !disc_q && fcnt_q == size_c;
      end
      if (cm_req) begin
        for (int i = 0; i < 2; i++) begin
          if (etag_q[{cm_head, 1'(i)}] == cm_sec) ev_q[{cm_head, 1'(i)}] <= 1'b0;
        end
        if (fill_q && fent_q[3:1] == cm_head && etag_q[fent_q] == cm_sec) disc_q <= 1'b1;
        if (fr_take && fr_h_q == cm_head && fr_s_q == cm_sec) disc_q <= 1'b1;
      end
    end
  end

  // deadline tracker
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      trk_q <= 1'b0;  dl_q <= 16'd0;  need_q <= 11'd0;  trk_late <= 1'b0;
    end else if (mount_ev || load_q) begin
      trk_q <= 1'b0;  trk_late <= 1'b0;
    end else begin
      trk_late <= 1'b0;
      if (ps_q == PChk && (miss1_c || miss2_c)) begin
        trk_q  <= !past_c && rdy_q && !sp_q;
        dl_q   <= 16'(dist_c - 18'sd1);
        need_q <= 11'd0;
      end else if (fr_done) begin
        trk_q <= 1'b0;
      end else if (trk_q && byte_tick) begin
        if (dl_q > 16'd1) begin
          dl_q <= dl_q - 16'd1;
        end else begin
          dl_q <= 16'd0;
          if (need_q <= size_c) need_q <= need_q + 11'd1;
          if (need_q < size_c) trk_late <= !wg_busy && !(fill_q && !disc_q && fcnt_q > need_q);
          else if (need_q == size_c) trk_late <= !wg_busy;
        end
      end
    end
  end

  // client
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cs_q <= CIdle;  job_q <= JFetch;  blk_q <= 1'b0;  boff_q <= 9'd0;  lba_q <= 32'd0;
      rd_q <= 1'b0;  wr_q <= 1'b0;  fmt_q <= 1'b0;  cm_act_q <= 1'b0;
      clr_q <= 1'b1;  clra_q <= '0;
      macc_q <= 32'd0;  mcand_q <= 32'd0;  mplier_q <= 12'd0;  cust_q <= 8'h00;  flh_q <= 4'd0;
      load_q <= 1'b0;  cv_q <= 1'b0;  ccyl_q <= 11'd0;  cbase_q <= 32'd0;
      fl_custom_we <= 1'b0;  fl_custom <= 8'h00;
    end else if (mount_ev) begin
      cs_q <= CIdle;  rd_q <= 1'b0;  wr_q <= 1'b0;  cm_act_q <= 1'b0;
      clr_q <= 1'b1;  clra_q <= '0;  load_q <= 1'b0;  cv_q <= 1'b0;  fl_custom_we <= 1'b0;
    end else begin
      load_q       <= 1'b0;
      fl_custom_we <= 1'b0;
      if (clr_q) begin
        clra_q <= clra_q + 1'b1;
        if (clra_q == CW'(MAX_CYLS - 1)) clr_q <= 1'b0;
      end
      unique case (cs_q)
        CIdle: begin
          if (!sd_ack && !clr_q) begin
            if (cm_go_c) begin
              cm_act_q <= 1'b1;
              blk_q    <= 1'b0;
              boff_q   <= (size_l2 < 4'd9) ? soff_c[8:0] : 9'd0;
              lba_q    <= cbase_q + {20'd0, soff_c[20:9]};
              fmt_q    <= 1'b0;
              job_q    <= (size_l2 < 4'd9) ? JCmRd : JCmWr;
              cs_q     <= CReq;
            end else if (fr_go_c) begin
              blk_q  <= 1'b0;
              boff_q <= (size_l2 < 4'd9) ? soff_c[8:0] : 9'd0;
              lba_q  <= cbase_q + {20'd0, soff_c[20:9]};
              fmt_q  <= 1'b0;
              job_q  <= JFetch;
              cs_q   <= CReq;
            end else if (fw_go_c) begin
              lba_q <= {18'd0, fw_blk_q};
              fmt_q <= 1'b1;
              job_q <= JFw;
              cs_q  <= CReq;
            end else if (sw_go_c) begin
              cv_q     <= 1'b0;  ccyl_q <= want_cyl;  load_q <= 1'b1;
              macc_q   <= 32'd0;  mcand_q <= {21'd0, want_cyl};  mplier_q <= bpc;
              cs_q     <= CMul;
            end
          end
        end
        CMul: begin
          if (mplier_q == 12'd0) begin
            cbase_q <= macc_q;  cs_q <= CBm0;
          end else begin
            if (mplier_q[0]) macc_q <= macc_q + mcand_q;
            mcand_q  <= mcand_q << 1;
            mplier_q <= mplier_q >> 1;
          end
        end
        CBm0: cs_q <= CBm1;
        CBm1: begin
          cust_q <= bm_q;  fl_custom <= bm_q;  fl_custom_we <= 1'b1;
          flh_q  <= 4'd0;  cs_q <= CFlNext;
        end
        CFlNext: begin
          if (flh_q >= heads || flh_q == 4'd8) begin
            cv_q <= 1'b1;  cs_q <= CIdle;
          end else if (cust_q[flh_q[2:0]]) begin
            lba_q <= {18'd0, ccyl_q, flh_q[2:0]};
            fmt_q <= 1'b1;
            job_q <= JFl;
            cs_q  <= CReq;
          end else begin
            flh_q <= flh_q + 4'd1;
          end
        end
        CReq: begin
          rd_q <= job_q == JFetch || job_q == JCmRd || job_q == JFl;
          wr_q <= job_q == JCmWr || job_q == JFw;
          if (ack_rise_c) begin rd_q <= 1'b0;  wr_q <= 1'b0;  cs_q <= CXfer; end
        end
        CXfer: begin
          if (!sd_ack) cs_q <= CNext;
        end
        CNext: begin
          unique case (job_q)
            JFetch: begin
              if (size_l2 == 4'd10 && !blk_q) begin
                blk_q <= 1'b1;  lba_q <= lba_q + 32'd1;  cs_q <= CReq;
              end else begin
                cs_q <= CIdle;
              end
            end
            JCmRd: begin job_q <= JCmWr;  cs_q <= CReq; end
            JCmWr: begin
              if (size_l2 == 4'd10 && !blk_q) begin
                blk_q <= 1'b1;  lba_q <= lba_q + 32'd1;  cs_q <= CReq;
              end else begin
                cm_act_q <= 1'b0;  cs_q <= CIdle;
              end
            end
            JFl:     begin flh_q <= flh_q + 4'd1;  cs_q <= CFlNext; end
            default: cs_q <= CIdle;
          endcase
        end
        default: cs_q <= CIdle;
      endcase
    end
  end

  // format block load: bytes MSB first, a word every fourth
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      facc_q <= 24'd0;  fg1_q <= 16'd0;  fg_q <= 16'd0;  fln_q <= 8'd0;  flhw_q <= 1'b0;
      flidw_q <= 1'b0;  flia_q <= '0;  flid_q <= 25'd0;
    end else begin
      flidw_q <= 1'b0;
      flhw_q  <= 1'b0;
      if (xfer_c && job_q == JFl) begin
        facc_q <= {facc_q[15:0], sd_buff_dout};
        if (sd_buff_addr[1:0] == 2'b11) begin
          if (sd_buff_addr[8:2] < 7'(FMT_SLOTS)) begin
            flidw_q <= 1'b1;
            flia_q  <= IW'({flh_q[2:0], sd_buff_addr[KW+1:2]});
            flid_q  <= {facc_q[16:0], sd_buff_dout};
          end else if (sd_buff_addr[8:2] == 7'd126) begin
            fg1_q <= facc_q[23:8];
            fg_q  <= {facc_q[7:0], sd_buff_dout};
          end else if (sd_buff_addr[8:2] == 7'd127) begin
            fln_q  <= sd_buff_dout;
            flhw_q <= 1'b1;
          end
        end
      end
    end
  end

  assign fl_id_we   = flidw_q;
  assign fl_id_addr = flia_q;
  assign fl_id_d    = flid_q;
  assign fl_hdr_we  = flhw_q;
  assign fl_h       = flh_q[2:0];
  assign fl_gap1    = fg1_q;
  assign fl_gap     = fg_q;
  assign fl_nsl     = fln_q;

  assign ready   = rdy_q && cv_q;
  assign rdy_cyl = ccyl_q;
  assign load_ev = load_q;
  assign late    = scan_late || trk_late || wlate_q;
  assign sd_lba  = lba_q;
  assign sd_rd   = rd_q;
  assign sd_wr   = wr_q;
  assign sd_fmt  = fmt_q;

endmodule

`default_nettype wire
