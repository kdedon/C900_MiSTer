// 5.25" drive emulator, image side for both drives: one sd_* slot per
// drive (512-byte blocks), served one job at a time.  Nothing of the
// medium is held whole: each head's walk gets the sector it is in and the
// next one, fetched a sector ahead into a two-slot buffer per head.
//
// Image LBAs: fd_pkg lba_of (cylinder-major, side 0 then side 1).  With
// `sd_scr` (held with sd_rd/sd_wr) the block is in the drive's scratch
// region, which the server keeps in RAM only (not written back to the
// file, dropped at eject): the raw records (LBA side * 64 + block) and
// the decoder's staging (LBA 128 + slot, 17 slots), 145 blocks.  A
// scratch block is read only after it was written since the mount.
//
// Jobs, by priority: raw record blocks (fd_raw lanes), head sector
// fills (a head's buffer slot refetched in place after a commit is
// still read meanwhile), then the decoder's: staging writes, commit
// copies, record blocks and sector fills for its own walk.  A commit
// copies each staged sector to its image block, then refetches every
// head buffer slot holding that track and side; `cm_busy` stays high
// until they are back.
//
// Jobs for a drive without a medium complete at once without a transfer.
`default_nettype none

module fd_media
  import fd_pkg::*;
(
  input  logic             clk,
  input  logic             rst_n,
  input  logic [1:0]       mount_ev,
  input  logic [1:0]       present,
  // head walks, per drive (data one clk after the grant)
  input  logic [1:0][6:0]  w_trk,
  input  logic [1:0]       w_req,
  input  logic [1:0][13:0] w_raddr,
  input  logic [1:0]       w_need,
  output logic [1:0]       w_gnt,
  output logic [1:0][7:0]  w_rdata,
  input  logic [1:0][4:0]  w_ck_idx,
  output logic [1:0][7:0]  w_ck_q,
  input  logic [1:0][4:0]  w_sec,
  input  logic [1:0]       w_sec_ok,
  output logic [1:0]       w_warm,         // both sides hold the walk's sector and the next
  // raw record lanes, index {drive, side}
  input  logic [3:0]       r_rq,
  input  logic [3:0]       r_rq_wr,
  input  logic [3:0][5:0]  r_rq_blk,
  output logic [3:0]       r_take,
  output logic [3:0]       r_done,
  output logic [3:0]       r_pb_we,
  output logic [3:0]       r_pb_rd,
  output logic [8:0]       pb_addr,
  output logic [7:0]       pb_d,
  input  logic [3:0][7:0]  r_pb_q,
  input  logic [3:0][RawBlocks-1:0] r_written,
  // decoder: drive, track, side of the decode or commit
  input  logic             dec_busy,
  input  logic             dstart,
  input  logic             dd,
  input  logic [6:0]       dtrk,
  input  logic             dside,
  input  logic [12:0]      s_raddr,
  output logic             s_rok,
  output logic [31:0]      s_rq,
  input  logic             s_req,
  input  logic [13:0]      s_laddr,
  input  logic             s_need,
  output logic             s_gnt,
  output logic [7:0]       s_ldata,
  input  logic [4:0]       s_ck_idx,
  output logic [7:0]       s_ck_q,
  input  logic [4:0]       s_sec,
  input  logic             s_sec_ok,
  input  logic             st_we,
  input  logic [13:0]      st_addr,
  input  logic [7:0]       st_d,
  output logic             st_stall,
  input  logic             cm_req,
  input  logic [4:0]       cm_map16,
  output logic             cm_busy,
  output logic             dbusy,
  // hps_io sd_*, one slot per drive
  output logic [1:0][31:0] sd_lba,
  output logic [1:0]       sd_scr,
  output logic [1:0]       sd_rd,
  output logic [1:0]       sd_wr,
  input  logic [1:0]       sd_ack,
  input  logic [8:0]       sd_buff_addr,
  input  logic [7:0]       sd_buff_dout,
  output logic [7:0]       sd_buff_din,
  input  logic             sd_buff_wr
);

  typedef enum logic [2:0] {JLane, JRaw, JDRec, JDSec, JOutW, JCmR, JCmW} job_e;
  typedef enum logic [1:0] {EIdle, EReq, EXfer, ESkip} est_e;

  // Justification: the job in progress: kind, drive, LBA, direction, lane, slot, void (reg-a).
  est_e        es_q;
  job_e        jt_q;
  logic        jd_q, jwr_q, jk_q, jcan_q;
  logic [1:0]  jl_q;
  logic [31:0] jlba_q;
  logic        jscr_q;
  logic [7:0]  jck_q;
  // Justification: sd_ack edge detect (reg-c), request level (reg-a).
  logic        ackq_q, req_q;
  // Justification: last fill byte address, so a strobe held over several clks counts once (reg-a).
  logic        fav_q;
  logic [8:0]  fa_q;

  logic ack_c, done_c, fill_c;
  assign ack_c  = sd_ack[jd_q];
  assign done_c = (es_q == EXfer && !ack_c) || es_q == ESkip;
  assign fill_c = (es_q == EReq || es_q == EXfer) && ack_c && sd_buff_wr && !jwr_q;

  assign pb_addr = sd_buff_addr;
  assign pb_d    = sd_buff_dout;

  function automatic logic [3:0] nexts(input logic [3:0] s, input logic [4:0] spt);
    return ({1'b0, s} + 5'd1 == spt) ? 4'd0 : s + 4'd1;
  endfunction

  // ------------------------------------------------------------------
  // Head sector buffers: per drive 2 sides x 2 slots x 512 B.

  // Justification: per head lane {drive, side} and slot: valid, stale, track, sector, checksum (reg-a).
  logic [1:0]      lv_q [4];
  logic [1:0]      lst_q [4];
  logic [6:0]      lt_q [4][2];
  logic [3:0]      ls_q [4][2];
  logic [7:0]      lck_q [4][2];
  // Justification: a lane job is pending in the engine (reg-a).
  logic [3:0]      lbusy_q;

  logic [3:0]       lj_v, lj_ref, lj_k, lw_c;
  logic [3:0][3:0]  lj_sec;
  logic [3:0][6:0]  lj_trk;
  logic [3:0][11:0] lj_base;    // image block of sector 0 of the job's track and side

  always_comb begin
    for (int l = 0; l < 4; l++) begin : lane_want
      logic [6:0] t;
      logic [4:0] spt;
      logic [3:0] s0, s1;
      logic [1:0] h0, h1;
      t   = w_trk[l >> 1];
      spt = spt_of(zone_of(t));
      s0  = (w_sec[l >> 1] >= spt) ? 4'd0 : w_sec[l >> 1][3:0];
      s1  = nexts(s0, spt);
      for (int k = 0; k < 2; k++) begin
        h0[k] = lv_q[l][k] && lt_q[l][k] == t && ls_q[l][k] == s0;
        h1[k] = lv_q[l][k] && lt_q[l][k] == t && ls_q[l][k] == s1;
      end
      lw_c[l] = |h0 && |h1;
      lj_v[l] = 1'b0;  lj_ref[l] = 1'b0;  lj_k[l] = 1'b0;  lj_sec[l] = s0;  lj_trk[l] = t;
      lj_base[l] = lba_of(t) + (l[0] ? {7'd0, spt} : 12'd0);
      if (present[l >> 1] && w_sec_ok[l >> 1] && !lbusy_q[l]) begin
        if (!(|h0)) begin
          lj_v[l] = 1'b1;  lj_k[l] = h1[0];
        end else if (!(|h1)) begin
          lj_v[l] = 1'b1;  lj_k[l] = h0[0];  lj_sec[l] = s1;
        end
      end
      if (present[l >> 1] && !lbusy_q[l] && !lj_v[l] && |(lst_q[l] & lv_q[l])) begin
        lj_v[l] = 1'b1;  lj_ref[l] = 1'b1;  lj_k[l] = !lst_q[l][0];
        lj_sec[l] = ls_q[l][!lst_q[l][0]];  lj_trk[l] = lt_q[l][!lst_q[l][0]];
        lj_base[l] = lba_of(lt_q[l][!lst_q[l][0]]) + (l[0] ? {7'd0, spt_of(zone_of(lt_q[l][!lst_q[l][0]]))} : 12'd0);
      end
    end
  end

  always_comb
    for (int d = 0; d < 2; d++) w_warm[d] = w_sec_ok[d] && lw_c[2 * d] && lw_c[2 * d + 1];

  // walk reads
  logic [1:0][1:0] wh_c;
  always_comb begin
    for (int d = 0; d < 2; d++) begin : walk_hit
      logic sd;
      sd = w_raddr[d][13];
      for (int k = 0; k < 2; k++)
        wh_c[d][k] = lv_q[{d[0], sd}][k] && lt_q[{d[0], sd}][k] == w_trk[d] &&
                     ls_q[{d[0], sd}][k] == w_raddr[d][12:9];
      w_gnt[d] = w_req[d] && (!w_need[d] || |wh_c[d]);
    end
  end
  always_comb begin
    for (int d = 0; d < 2; d++) begin : walk_ck
      logic sd, k1;
      sd = w_ck_idx[d][4];
      k1 = lv_q[{d[0], sd}][1] && lt_q[{d[0], sd}][1] == w_trk[d] && ls_q[{d[0], sd}][1] == w_ck_idx[d][3:0];
      w_ck_q[d] = lck_q[{d[0], sd}][k1];
    end
  end

  genvar gd;
  generate
  for (gd = 0; gd < 2; gd++) begin : g_smem
    (* ramstyle = "M10K" *) logic [7:0] smem [0:2047];
    logic        swe_c;
    logic [10:0] swa_c, sra_c;
    assign swe_c = fill_c && jt_q == JLane && jd_q == 1'(gd) && !jcan_q;
    assign swa_c = {jl_q[0], jk_q, sd_buff_addr};
    assign sra_c = {w_raddr[gd][13], wh_c[gd][1], w_raddr[gd][8:0]};
    always_ff @(posedge clk) begin
      if (swe_c) smem[swa_c] <= sd_buff_dout;
      w_rdata[gd] <= smem[sra_c];
    end
  end
  endgenerate

  // ------------------------------------------------------------------
  // Decoder sector buffer (one side, 2 slots) and record ring (2 blocks).

  // Justification: decoder sector slots: valid, sector, checksum (reg-a).
  logic [1:0] dsv_q;
  logic [3:0] dss_q [2];
  logic [7:0] dsck_q [2];
  // Justification: decoder record slots: valid, block, all-zero (reg-a).
  logic [1:0] drv_q, drz_q;
  logic [5:0] drb_q [2];
  // Justification: decoder jobs pending in the engine (reg-a).
  logic       dsbusy_q, drbusy_q;

  logic [4:0] dspt_c;
  logic [3:0] ds0_c, ds1_c;
  logic [1:0] dh0_c, dh1_c, dsh_c, dck_c;
  assign dspt_c = spt_of(zone_of(dtrk));
  assign ds0_c  = (s_sec >= dspt_c) ? 4'd0 : s_sec[3:0];
  assign ds1_c  = nexts(ds0_c, dspt_c);
  always_comb
    for (int k = 0; k < 2; k++) begin
      dh0_c[k] = dsv_q[k] && dss_q[k] == ds0_c;
      dh1_c[k] = dsv_q[k] && dss_q[k] == ds1_c;
      dsh_c[k] = dsv_q[k] && dss_q[k] == s_laddr[12:9];
      dck_c[k] = dsv_q[k] && dss_q[k] == s_ck_idx[3:0];
    end
  assign s_gnt  = s_req && (!s_need || |dsh_c);

  logic unused_ok;
  assign unused_ok = &{1'b0, s_laddr[13], s_ck_idx[4], dck_c[0]};
  assign s_ck_q = dsck_q[dck_c[1]];

  logic       dj_v, dj_k;
  logic [3:0] dj_sec;
  always_comb begin
    dj_v = 1'b0;  dj_k = 1'b0;  dj_sec = ds0_c;
    if (dec_busy && s_sec_ok && !dsbusy_q) begin
      if (!(|dh0_c))      begin dj_v = 1'b1; dj_k = dh1_c[0]; end
      else if (!(|dh1_c)) begin dj_v = 1'b1; dj_k = dh0_c[0]; dj_sec = ds1_c; end
    end
  end

  (* ramstyle = "M10K" *) logic [7:0] dsmem [0:1023];
  always_ff @(posedge clk) begin
    if (fill_c && jt_q == JDSec && !jcan_q) dsmem[{jk_q, sd_buff_addr}] <= sd_buff_dout;
    s_ldata <= dsmem[{dsh_c[1], s_laddr[8:0]}];
  end

  // record ring
  logic [12:0] dnw_c;
  logic [5:0]  dlast_c, rb0_c, rb1_c;
  logic [1:0]  rh0_c, rh1_c;
  logic [RawBlocks-1:0] dwr_c;
  assign dnw_c   = 13'((nbits_of(zone_of(dtrk)) + 17'd15) >> 4);
  assign dlast_c = 6'((dnw_c - 13'd1) >> 7);
  assign rb0_c   = s_raddr[12:7];
  assign rb1_c   = (rb0_c == dlast_c) ? 6'd0 : rb0_c + 6'd1;
  assign dwr_c   = r_written[{dd, dside}];
  always_comb
    for (int k = 0; k < 2; k++) begin
      rh0_c[k] = drv_q[k] && drb_q[k] == rb0_c;
      rh1_c[k] = drv_q[k] && drb_q[k] == rb1_c;
    end
  assign s_rok = |rh0_c;

  logic       rj_v, rj_k, rj_zero;
  logic [5:0] rj_blk;
  always_comb begin
    rj_v = 1'b0;  rj_k = 1'b0;  rj_blk = rb0_c;  rj_zero = 1'b0;
    if (dec_busy && !drbusy_q) begin
      if (!(|rh0_c))      begin rj_k = rh1_c[0]; end
      else if (!(|rh1_c)) begin rj_k = rh0_c[0]; rj_blk = rb1_c; end
      if (!(|rh0_c) || !(|rh1_c)) begin
        if (rj_blk < 6'(RawBlocks) && dwr_c[rj_blk]) rj_v = 1'b1;
        else                                          rj_zero = 1'b1;
      end
    end
  end

  // Justification: record word read and its zero flag (reg-a).
  logic [31:0] drq_q;
  logic        drz_rd_q;
  // byte-enabled simple dual port; the fill writes one byte lane at a time
  (* ramstyle = "M10K" *) logic [3:0][7:0] drmem [0:255];
  logic       drwe_c;
  logic [7:0] drwa_c;
  assign drwe_c = fill_c && jt_q == JDRec && !jcan_q;
  assign drwa_c = {jk_q, sd_buff_addr[8:2]};
  always_ff @(posedge clk) begin
    if (drwe_c) begin
      if (sd_buff_addr[1:0] == 2'd0) drmem[drwa_c][0] <= sd_buff_dout;
      if (sd_buff_addr[1:0] == 2'd1) drmem[drwa_c][1] <= sd_buff_dout;
      if (sd_buff_addr[1:0] == 2'd2) drmem[drwa_c][2] <= sd_buff_dout;
      if (sd_buff_addr[1:0] == 2'd3) drmem[drwa_c][3] <= sd_buff_dout;
    end
    drq_q <= drmem[{rh0_c[1], s_raddr[6:0]}];
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) drz_rd_q <= 1'b1;
    else        drz_rd_q <= drz_q[rh0_c[1]];
  end
  assign s_rq = drz_rd_q ? 32'd0 : drq_q;

  // ------------------------------------------------------------------
  // Staging / commit buffer (512 B).

  // Justification: staging write pending and its slot (reg-a).
  logic       opend_q;
  logic [4:0] oslot_q;
  // Justification: commit sequence: active, drive, track, side, slot-16 map, sector, phase, refetch (reg-a).
  logic       cm_on_q, cmd_q, cmside_q, cmph_q, cmref_q;
  logic [6:0] cmtrk_q;
  logic [4:0] cmmap_q;
  logic [3:0] cmsec_q;

  (* ramstyle = "M10K" *) logic [7:0] omem [0:511];
  logic [7:0] oq_q;
  always_ff @(posedge clk) begin
    if (st_we)                              omem[st_addr[8:0]] <= st_d;
    else if (fill_c && jt_q == JCmR && !jcan_q) omem[sd_buff_addr] <= sd_buff_dout;
    oq_q <= omem[sd_buff_addr];
  end
  assign st_stall = opend_q;

  logic [4:0] cmspt_c;
  logic [4:0] cmsrc_c;
  assign cmspt_c = spt_of(zone_of(cmtrk_q));
  assign cmsrc_c = (cmmap_q[4] && cmmap_q[3:0] == cmsec_q) ? 5'd16 : {1'b0, cmsec_q};

  // ------------------------------------------------------------------
  // Engine: pick a job when idle.

  logic        pk_v, pk_d, pk_wr, pk_k;
  job_e        pk_t;
  logic [1:0]  pk_l;
  logic [31:0] pk_lba;
  logic        pk_scr;
  always_comb begin
    pk_scr = 1'b0;
    pk_v = 1'b0;  pk_t = JLane;  pk_d = 1'b0;  pk_wr = 1'b0;  pk_k = 1'b0;  pk_l = 2'd0;  pk_lba = 32'd0;
    for (int l = 3; l >= 0; l--)
      if (lj_v[l]) begin
        pk_v = 1'b1;  pk_t = JLane;  pk_d = l[1];  pk_l = 2'(l);  pk_k = lj_k[l];  pk_scr = 1'b0;
        pk_lba = {20'd0, lj_base[l] + {8'd0, lj_sec[l]}};
      end
    if (!pk_v) begin
      if (opend_q) begin
        pk_v = 1'b1;  pk_t = JOutW;  pk_d = dd;  pk_wr = 1'b1;  pk_scr = 1'b1;  pk_lba = 32'd128 + {27'd0, oslot_q};
      end else if (cm_on_q && !cmref_q) begin
        pk_v = 1'b1;  pk_d = cmd_q;
        if (!cmph_q) begin pk_t = JCmR;  pk_scr = 1'b1;  pk_lba = 32'd128 + {27'd0, cmsrc_c}; end
        else begin
          pk_t = JCmW;  pk_wr = 1'b1;
          pk_lba = {20'd0, lba_of(cmtrk_q)} + (cmside_q ? {27'd0, cmspt_c} : 32'd0) + {28'd0, cmsec_q};
        end
      end else if (rj_v) begin
        pk_v = 1'b1;  pk_t = JDRec;  pk_d = dd;  pk_k = rj_k;
        pk_scr = 1'b1;  pk_lba = {25'd0, dside, rj_blk};
      end else if (dj_v) begin
        pk_v = 1'b1;  pk_t = JDSec;  pk_d = dd;  pk_k = dj_k;
        pk_lba = {20'd0, lba_of(dtrk)} + (dside ? {27'd0, dspt_c} : 32'd0) + {28'd0, dj_sec};
      end
    end
    // raw record blocks first
    for (int l = 3; l >= 0; l--)
      if (r_rq[l]) begin
        pk_v = 1'b1;  pk_t = JRaw;  pk_d = l[1];  pk_l = 2'(l);  pk_wr = r_rq_wr[l];
        pk_scr = 1'b1;  pk_lba = {25'd0, l[0], r_rq_blk[l]};
      end
  end

  logic take_c;
  assign take_c = es_q == EIdle && pk_v;
  always_comb
    for (int l = 0; l < 4; l++) begin
      r_take[l]  = take_c && pk_t == JRaw && pk_l == 2'(l);
      r_done[l]  = done_c && jt_q == JRaw && jl_q == 2'(l);
      r_pb_we[l] = fill_c && jt_q == JRaw && jl_q == 2'(l);
      r_pb_rd[l] = (es_q == EReq || es_q == EXfer) && ack_c && jwr_q && jt_q == JRaw && jl_q == 2'(l);
    end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      es_q <= EIdle;  jt_q <= JLane;  jd_q <= 1'b0;  jwr_q <= 1'b0;  jk_q <= 1'b0;  jcan_q <= 1'b0;
      jl_q <= 2'd0;  jlba_q <= 32'd0;  jscr_q <= 1'b0;  jck_q <= 8'd0;  ackq_q <= 1'b0;  req_q <= 1'b0;  fav_q <= 1'b0;
      fa_q <= 9'd0;
    end else begin
      ackq_q <= ack_c;
      if (fill_c && !(fav_q && fa_q == sd_buff_addr)) jck_q <= jck_q ^ sd_buff_dout;
      if (fill_c) begin fav_q <= 1'b1; fa_q <= sd_buff_addr; end
      if (mount_ev[jd_q] && es_q != EIdle) jcan_q <= 1'b1;
      unique case (es_q)
        EIdle: if (pk_v) begin
          jt_q <= pk_t;  jd_q <= pk_d;  jwr_q <= pk_wr;  jk_q <= pk_k;  jl_q <= pk_l;  jlba_q <= pk_lba;  jscr_q <= pk_scr;
          jck_q <= 8'h07;  jcan_q <= 1'b0;  fav_q <= 1'b0;
          es_q <= present[pk_d] ? EReq : ESkip;
        end
        EReq: begin
          req_q <= 1'b1;
          if (ack_c && !ackq_q) begin req_q <= 1'b0; es_q <= EXfer; end
        end
        EXfer: if (!ack_c) es_q <= EIdle;
        ESkip: es_q <= EIdle;
        default: es_q <= EIdle;
      endcase
    end
  end

  always_comb begin
    for (int d = 0; d < 2; d++) begin
      sd_lba[d] = jlba_q;
      sd_scr[d] = jscr_q;
      sd_rd[d]  = req_q && !jwr_q && jd_q == 1'(d);
      sd_wr[d]  = req_q && jwr_q && jd_q == 1'(d);
    end
  end

  always_comb begin
    if (jt_q == JRaw) sd_buff_din = r_pb_q[jl_q];
    else              sd_buff_din = oq_q;
  end

  // ------------------------------------------------------------------
  // Buffer tags, staging and commit.

  logic ok_c;   // the job completed with its data
  assign ok_c = done_c && !jcan_q && es_q == EXfer;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int l = 0; l < 4; l++) begin
        lv_q[l] <= 2'b00;  lst_q[l] <= 2'b00;
        for (int k = 0; k < 2; k++) begin lt_q[l][k] <= 7'd0; ls_q[l][k] <= 4'd0; lck_q[l][k] <= 8'd0; end
      end
      lbusy_q <= 4'd0;
      dsv_q <= 2'b00;  dss_q[0] <= 4'd0;  dss_q[1] <= 4'd0;  dsck_q[0] <= 8'd0;  dsck_q[1] <= 8'd0;
      drv_q <= 2'b00;  drz_q <= 2'b00;  drb_q[0] <= 6'd0;  drb_q[1] <= 6'd0;
      dsbusy_q <= 1'b0;  drbusy_q <= 1'b0;
      opend_q <= 1'b0;  oslot_q <= 5'd0;
      cm_on_q <= 1'b0;  cmd_q <= 1'b0;  cmside_q <= 1'b0;  cmph_q <= 1'b0;  cmref_q <= 1'b0;
      cmtrk_q <= 7'd0;  cmmap_q <= 5'd0;  cmsec_q <= 4'd0;
    end else begin
      // job taken
      if (take_c) begin
        unique case (pk_t)
          JLane: begin
            lbusy_q[pk_l] <= 1'b1;
            if (!lj_ref[pk_l]) begin
              lv_q[pk_l][pk_k] <= 1'b0;  lst_q[pk_l][pk_k] <= 1'b0;
              lt_q[pk_l][pk_k] <= lj_trk[pk_l];  ls_q[pk_l][pk_k] <= lj_sec[pk_l];
            end
          end
          JDSec: begin dsbusy_q <= 1'b1; dsv_q[pk_k] <= 1'b0; dss_q[pk_k] <= dj_sec; end
          JDRec: begin drbusy_q <= 1'b1; drv_q[pk_k] <= 1'b0; drb_q[pk_k] <= rj_blk; end
          default: ;
        endcase
      end
      if (rj_zero && !(take_c && pk_t == JDRec)) begin
        drv_q[rj_k] <= 1'b1;  drz_q[rj_k] <= 1'b1;  drb_q[rj_k] <= rj_blk;
      end
      // job done
      if (done_c) begin
        unique case (jt_q)
          JLane: begin
            lbusy_q[jl_q] <= 1'b0;
            if (ok_c) begin
              lv_q[jl_q][jk_q] <= 1'b1;  lst_q[jl_q][jk_q] <= 1'b0;  lck_q[jl_q][jk_q] <= jck_q;
            end
          end
          JDSec: begin
            dsbusy_q <= 1'b0;
            if (ok_c) begin dsv_q[jk_q] <= 1'b1; dsck_q[jk_q] <= jck_q; end
          end
          JDRec: begin
            drbusy_q <= 1'b0;
            if (ok_c) begin drv_q[jk_q] <= 1'b1; drz_q[jk_q] <= 1'b0; end
          end
          JOutW: opend_q <= 1'b0;
          JCmR:  cmph_q <= 1'b1;
          JCmW: begin
            cmph_q <= 1'b0;
            if ({1'b0, cmsec_q} + 5'd1 == cmspt_c) begin
              cmref_q <= 1'b1;
              // refetch every head slot of this track and side
              for (int k = 0; k < 2; k++)
                if (lv_q[{cmd_q, cmside_q}][k] && lt_q[{cmd_q, cmside_q}][k] == cmtrk_q)
                  lst_q[{cmd_q, cmside_q}][k] <= 1'b1;
            end else begin
              cmsec_q <= cmsec_q + 4'd1;
            end
          end
          default: ;
        endcase
      end
      if (cmref_q && !(|lst_q[{cmd_q, cmside_q}]) && !lbusy_q[{cmd_q, cmside_q}]) begin
        cmref_q <= 1'b0;  cm_on_q <= 1'b0;
      end
      // a full data field staged
      if (st_we && st_addr[8:0] == 9'd511) begin opend_q <= 1'b1; oslot_q <= st_addr[13:9]; end
      if (cm_req && !mount_ev[dd]) begin
        cm_on_q <= 1'b1;  cmd_q <= dd;  cmtrk_q <= dtrk;  cmside_q <= dside;  cmmap_q <= cm_map16;
        cmsec_q <= 4'd0;  cmph_q <= 1'b0;  cmref_q <= 1'b0;
      end
      if (dstart) begin dsv_q <= 2'b00; drv_q <= 2'b00; end
      // a new medium: its buffers are void, a commit to it stops
      for (int d = 0; d < 2; d++)
        if (mount_ev[d]) begin
          lv_q[2 * d] <= 2'b00;  lv_q[2 * d + 1] <= 2'b00;  lst_q[2 * d] <= 2'b00;  lst_q[2 * d + 1] <= 2'b00;
          if (cmd_q == 1'(d)) begin cm_on_q <= 1'b0; cmref_q <= 1'b0; end
        end
    end
  end


  assign cm_busy = cm_on_q || cm_req;
  assign dbusy   = dsbusy_q || drbusy_q || opend_q;

endmodule

`default_nettype wire
