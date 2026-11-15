// ST-506 hard drive emulator (an FPGA-side board, not a chip): the drive
// on the WD1003-CMD cable, serving an image held in external RAM
// through an sd_* block interface (MiSTer hps_io shape).
//
// Drive side = the ST-506 cable signals as logic levels (High = asserted,
// the card's 3486/3487 and line drivers sit outside): DS (this drive's
// select line), STEP, DIRIN, HS2-0, WG, RWC, WMFM in; READY (drdy), SC,
// TK000, WF, INDEX, RMFM out.  Outputs are low while DS is low, and
// STEP/WG/WMFM are ignored.  RWC only switches the real drive's write
// current.
//
// Image side: img_mounted (pulse) with img_size/img_readonly as hps_io
// gives them, and the geometry of the image (cylinders, heads 1-8,
// sectors per track, SDH sector size code), latched at the mount.  The
// sd_* slot carries image blocks, and with sd_fmt high the blocks of a
// format region (recorded track formats, st506_media).  `late` pulses
// when the image side delivers a sector after the disk needs it.
//
// Time base: one step = 50 ns, one clk with step_en high (the core's
// 20 MHz enable, the WD10C20 crystal's).  A revolution is 10,418
// bytes of 16 cells, a cell 2 steps.  INDEX is high for the first step of
// the revolution; RMFM is a one-step pulse at the start of each recorded
// 1-cell.  The spindle starts when the first sectors under the heads
// are fetched after a mount; READY follows.
//
// Stepping: the head moves on the falling edge of STEP (DIRIN high =
// inward), within the cylinder count.  SC drops at the STEP rising edge
// and rises SETTLE_STEPS after the last falling edge, but not before the
// new cylinder's formats and first sectors are in (st506_media).
//
// Reading: the recorded bytes are produced from the sector buffer and
// the track format one byte ahead (st506_walker).  For three byte times
// after a head change, a write, a cylinder change, or a sector that is
// not in the buffer the head reads nothing (RMFM low).
//
// Writing: cells written under WG are decoded (st506_wrdec).  A data
// field is stored by the slot it was written over (Write Sector), or
// under the last ID written in the same pass (Write Format).  A pass
// whose WG rises within 4 bytes of INDEX is a Write Format: its IDs and
// gaps replace that track's format when WG falls.  Recorded formats
// live in the format region until the image is ejected (the image holds
// none).  WF = WG on a read-only image.  A geometry whose cylinder is not
// a whole number of 512-byte blocks, or whose sectors are larger than
// 2^MAX_L2 bytes, never becomes READY.  An eject drops a write not yet
// sent.
`default_nettype none

module st506_drive #(
  parameter int unsigned MAX_L2       = 9,       // largest sector 2^MAX_L2 bytes (9 or 10)
  parameter int unsigned FMT_SLOTS    = 64,      // IDs kept per recorded track format (<= 126)
  parameter int unsigned SETTLE_STEPS = 0        // SC delay after the last STEP
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        step_en,   // one clk per 50 ns step
  // ST-506 cable
  input  logic        ds,
  input  logic        step,
  input  logic        dirin,
  input  logic [2:0]  hs,
  input  logic        wg,
  input  logic        rwc,
  input  logic        wmfm,
  output logic        drdy,
  output logic        sc,
  output logic        tk000,
  output logic        wf,
  output logic        index,
  output logic        rmfm,
  // image side
  input  logic        img_mounted,
  input  logic        img_readonly,
  input  logic [63:0] img_size,
  input  logic [11:0] geo_cyls,
  input  logic [3:0]  geo_heads,
  input  logic [7:0]  geo_spt,
  input  logic [1:0]  geo_ssz,
  output logic        late,
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

  localparam int unsigned IW  = $clog2(8 * FMT_SLOTS);
  localparam int unsigned KW  = $clog2(FMT_SLOTS);
  localparam logic [13:0] LastByte = 14'(BytesPerRev - 1);
  localparam logic [23:0] Settle   = 24'(SETTLE_STEPS);

  logic unused_ok;
  assign unused_ok = &{1'b0, rwc, img_size[63:32], id_hb[4:3], cyl_bytes_c[22:21], data_ecc};

  // ------------------------------------------------------------------
  // Mount: image presence, write protect and geometry.

  // Justification: mount state latched from the one-clk img_mounted (reg-a).
  logic        present_q, ro_q, mount_ev_q;
  logic [11:0] cyls_q;
  logic [3:0]  heads_q;
  logic [7:0]  spt_q;
  logic [1:0]  ssz_q;
  // Justification: derived geometry, registered off the mount (reg-b).
  logic        geo_ok_q;
  logic [11:0] bpc_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      present_q <= 1'b0;  ro_q <= 1'b1;  mount_ev_q <= 1'b0;
      cyls_q <= 12'd0;  heads_q <= 4'd0;  spt_q <= 8'd0;  ssz_q <= 2'b01;
    end else begin
      mount_ev_q <= img_mounted;
      if (img_mounted) begin
        present_q <= |img_size[31:0];
        ro_q      <= img_readonly;
        cyls_q    <= geo_cyls;  heads_q <= geo_heads;  spt_q <= geo_spt;  ssz_q <= geo_ssz;
      end
    end
  end

  logic [3:0]  size_l2_c;
  logic [11:0] hs_prod_c;
  logic [22:0] cyl_bytes_c;
  assign size_l2_c   = size_log2(ssz_q);
  assign hs_prod_c   = (heads_q[0] ? {4'd0, spt_q} : 12'd0) + (heads_q[1] ? {3'd0, spt_q, 1'b0} : 12'd0) +
                       (heads_q[2] ? {2'd0, spt_q, 2'b0} : 12'd0) + (heads_q[3] ? {1'd0, spt_q, 3'b0} : 12'd0);
  assign cyl_bytes_c = {11'd0, hs_prod_c} << size_l2_c;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      geo_ok_q <= 1'b0;  bpc_q <= 12'd0;
    end else begin
      geo_ok_q <= heads_q != 4'd0 && heads_q <= 4'd8 && spt_q != 8'd0 && cyls_q != 12'd0 &&
                  cyl_bytes_c[8:0] == 9'd0 && size_l2_c <= 4'(MAX_L2);
      bpc_q    <= cyl_bytes_c[20:9];
    end
  end

  logic media_c, writable_c;
  assign media_c    = present_q && geo_ok_q && !mount_ev_q;
  assign writable_c = media_c && !ro_q;

  // ------------------------------------------------------------------
  // Cable inputs as this drive sees them.

  logic       step_c, wg_c, wmfm_c, on_surf_c;
  assign step_c    = ds && step;
  assign wg_c      = ds && wg;
  assign wmfm_c    = ds && wmfm;
  assign on_surf_c = {1'b0, hs} < heads_q;

  // ------------------------------------------------------------------
  // Stepper and SC.

  // Justification: STEP level last step, head cylinder, SC latch and settle count (reg-a).
  logic        step_q;
  logic [10:0] cyl_q;
  logic        scl_q;
  logic [23:0] scw_q;

  logic        fall_c;
  logic [10:0] cyl_n, maxcyl_c;
  logic        scl_n;
  logic [23:0] scw_n;

  assign maxcyl_c = 11'(cyls_q - 12'd1);
  assign fall_c   = step_q && !step_c;
  always_comb begin
    cyl_n = cyl_q;
    scl_n = scl_q;
    scw_n = scw_q;
    if (fall_c) begin
      if (dirin) begin
        if (!(cyls_q > 12'd1 && cyl_q >= maxcyl_c)) cyl_n = cyl_q + 11'd1;
      end else if (cyl_q != 11'd0) begin
        cyl_n = cyl_q - 11'd1;
      end
      scw_n = Settle;
      scl_n = Settle == 24'd0;
    end
    if (!step_q && step_c) scl_n = 1'b0;
    if (scw_n != 24'd0 && !step_c) begin
      scw_n = scw_n - 24'd1;
      scl_n = scw_n == 24'd0;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      step_q <= 1'b0;  cyl_q <= 11'd0;  scl_q <= 1'b1;  scw_q <= 24'd0;
    end else if (step_en) begin
      step_q <= step_c;  cyl_q <= cyl_n;  scl_q <= scl_n;  scw_q <= scw_n;
    end
  end

  // ------------------------------------------------------------------
  // Media (sector buffer, staging, format region, image client).

  logic          m_ready, load_ev, m_late;
  logic [10:0]   rdy_cyl;
  logic [MAX_L2+3:0] wk_addr;
  logic [7:0]    wk_q;
  logic [3:0]    ek_idx;
  logic [31:0]   ek_q;
  logic          st_we;
  logic [9:0]    st_addr;
  logic [7:0]    st_d;
  logic          cm_req_q;
  logic [2:0]    cm_head_q;
  logic [7:0]    cm_sec_q;
  logic [2:0]    pf_h;
  logic [IW-1:0] pf_id_addr, fl_id_addr;
  logic          pf_id_gnt, fl_custom_we, fl_hdr_we, fl_id_we;
  logic [7:0]    fl_custom, fl_nsl;
  logic [2:0]    fl_h;
  logic [15:0]   fl_gap1, fl_gap;
  logic [24:0]   fl_id_d;
  logic [2:0]    lk_head;
  logic [7:0]    lk_sec;
  logic          lk_hit, lk_full;
  logic [3:0]    lk_ent;
  logic [10:0]   lk_cnt;
  logic          fc_req_c;
  logic [7:0]    fc_custom_c;
  logic [15:0]   fc_gap_c;
  logic [7:0]    fc_nsl_c;
  logic          wk_id_use;

  st506_media #(.MAX_L2(MAX_L2), .FMT_SLOTS(FMT_SLOTS)) u_media (
    .clk, .rst_n,
    .mount_ev(mount_ev_q), .present(present_q && geo_ok_q), .size_l2(size_l2_c), .bpc(bpc_q),
    .spt(spt_q), .heads(heads_q),
    .want_cyl(cyl_q), .ready(m_ready), .rdy_cyl, .load_ev,
    .pos(nb_q), .byte_tick(run_c && bstart_c), .sel_head(hs), .wg_busy(wg_q),
    .fp_act(wg_q && fon_q), .fp_head(whead_q), .fp_n(fpn_q), .fp_s0(fps0_q), .fp_s1(fps1_q),
    .pf_h, .pf_custom(custom_q[pf_h]), .pf_gap1(fgap1_q[pf_h]), .pf_gap(fgap_q[pf_h]), .pf_nsl(fnsl_q[pf_h]),
    .pf_id_addr, .pf_id_gnt, .id_q,
    .fl_custom_we, .fl_custom, .fl_hdr_we, .fl_h, .fl_gap1, .fl_gap, .fl_nsl, .fl_id_we, .fl_id_addr, .fl_id_d,
    .lk_head, .lk_sec, .lk_hit, .lk_ent, .lk_full, .lk_cnt,
    .wk_addr, .wk_q, .ek_idx, .ek_q,
    .st_we, .st_addr, .st_d, .cm_req(cm_req_q), .cm_head(cm_head_q), .cm_sec(cm_sec_q),
    .fb_we(id_we), .fb_addr(7'(pcnt_q)), .fb_d(id_wd),
    .fc_req(fc_req_c), .fc_cyl(cyl_q), .fc_head(whead_q), .fc_custom(fc_custom_c),
    .fc_gap1(gap1_n[15:0]), .fc_gap(fc_gap_c), .fc_nsl(fc_nsl_c),
    .late(m_late),
    .sd_lba, .sd_rd, .sd_wr, .sd_fmt, .sd_ack, .sd_buff_addr, .sd_buff_dout, .sd_buff_din, .sd_buff_wr
  );

  logic buf_ok_c, buf_ok_n;
  assign buf_ok_c = m_ready && rdy_cyl == cyl_q;
  assign buf_ok_n = m_ready && rdy_cyl == cyl_n;

  // Justification: spindle up (first cylinder buffered after the mount),
  // and turning from the step after READY rose (reg-a).
  logic spun_q, turn_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      spun_q <= 1'b0;  turn_q <= 1'b0;
    end else if (mount_ev_q) begin
      spun_q <= 1'b0;  turn_q <= 1'b0;
    end else begin
      if (media_c && buf_ok_c) spun_q <= 1'b1;
      if (step_en) turn_q <= spun_q;
    end
  end

  // ------------------------------------------------------------------
  // Rotation.

  // Justification: step in the byte, byte of the revolution (reg-a).
  logic [4:0]  sib_q;
  logic [13:0] nb_q;
  logic        run_c, bstart_c, cstart_c;
  logic [13:0] nb_next_c;
  logic [17:0] cell_c;

  assign run_c     = step_en && turn_q;
  assign bstart_c  = sib_q == 5'd0;
  assign cstart_c  = !sib_q[0];
  assign nb_next_c = (nb_q == LastByte) ? 14'd0 : nb_q + 14'd1;
  assign cell_c    = {nb_q, sib_q[4:1]};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sib_q <= 5'd0;  nb_q <= 14'd0;
    end else if (mount_ev_q) begin
      sib_q <= 5'd0;  nb_q <= 14'd0;
    end else if (run_c) begin
      sib_q <= sib_q + 5'd1;
      if (sib_q == 5'd31) nb_q <= nb_next_c;
    end
  end

  // ------------------------------------------------------------------
  // Track formats of the buffered cylinder, per head.

  // Justification: per-head recorded format (reg-a).
  logic [7:0]  custom_q;
  logic [15:0] fgap1_q [8];
  logic [15:0] fgap_q  [8];
  logic [7:0]  fnsl_q  [8];
  (* ramstyle = "M10K" *) logic [24:0] id_mem [0:8*FMT_SLOTS-1];

  logic          id_we;
  logic [IW-1:0] id_waddr, id_raddr, wk_id_raddr;
  logic [24:0]   id_wd, id_q;

  always_ff @(posedge clk) begin
    if (fl_id_we)   id_mem[fl_id_addr] <= fl_id_d;
    else if (id_we) id_mem[id_waddr] <= id_wd;
    id_q <= id_mem[id_raddr];
  end

  // ------------------------------------------------------------------
  // Write channel: one decision per cell from the WG rise.

  // A flux reversal is written at each WMFM rising edge, so a pulse
  // counts in the cell where it starts, whatever its width or phase.
  // Justification: WG and WMFM last step, a reversal in the current cell (reg-a).
  logic wg_q, wmfm_q, hit_q;
  logic dec_v_c, wstart_c, wstop_c;
  logic [17:0] dec_idx_c;

  assign dec_v_c   = run_c && media_c && cstart_c && wg_q;
  assign wstart_c  = run_c && media_c && wg_c && !wg_q;
  assign wstop_c   = run_c && media_c && !wg_c && wg_q;
  assign dec_idx_c = (cell_c == 18'd0) ? 18'(BytesPerRev * 16 - 1) : cell_c - 18'd1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wg_q <= 1'b0;  wmfm_q <= 1'b0;  hit_q <= 1'b0;
    end else if (mount_ev_q) begin
      wg_q <= 1'b0;  wmfm_q <= 1'b0;  hit_q <= 1'b0;
    end else if (run_c && media_c) begin
      wg_q   <= wg_c;
      wmfm_q <= wmfm_c;
      hit_q  <= (wg_c && wmfm_c && !wmfm_q && on_surf_c && writable_c) ||
               (hit_q && !(cstart_c && wg_q) && !(wg_c && !wg_q));
    end
  end

  logic        ev_dhdr, ev_data, ev_id;
  logic [31:0] data_ecc;
  logic [10:0] id_cyl;
  logic [7:0]  id_hb, id_sec;
  logic [13:0] fq;

  st506_wrdec u_wrdec (
    .clk, .rst_n, .start(wstart_c), .cell_v(dec_v_c), .cell_bit(hit_q), .cell_idx(dec_idx_c),
    .size_l2(size_l2_c), .st_we, .st_addr, .st_d,
    .ev_dhdr, .ev_data, .data_ecc, .ev_id, .id_cyl, .id_hb, .id_sec, .fq
  );

  // The pass: format or not, its head; format bookkeeping; the slot a
  // Write Sector data field went over.

  // Justification: pass state, latched at the WG rise (reg-a).
  logic        fon_q;
  logic [2:0]  whead_q;
  logic signed [16:0] pgap1_q, pgap_q;
  logic [7:0]  pcnt_q, plast_q;
  logic        phave_q;
  // Justification: sectors of a format pass's first two IDs (reg-a).
  logic [1:0]  fpn_q;
  logic [7:0]  fps0_q, fps1_q;
  // Justification: the stop of a pass, aligned with the decoder's last event (reg-a).
  logic        stop_q;
  // Justification: slot search for a Write Sector data field (reg-a).
  typedef enum logic [2:0] {SlIdle, SlDiv, SlId, SlIdv, SlDone, SlNone} sl_e;
  sl_e         sl_q;
  logic [15:0] srem_q;
  logic [7:0]  sk_q, ssec_q;

  logic [10:0] slotfix_c;
  logic [15:0] wslen_c;
  logic signed [16:0] sn_c;
  logic [7:0]  whm_c, wdsec_c;

  assign slotfix_c = SlotFixed0 + (11'd1 << size_l2_c);
  assign wslen_c   = {5'd0, slotfix_c} + (custom_q[whead_q] ? fgap_q[whead_q] : Gap3Def);
  // n = fq - gap1 - 36; slot = (n + sl/2) / sl when n >= -sl/2
  assign sn_c      = signed'({3'd0, fq}) - signed'({1'b0, custom_q[whead_q] ? fgap1_q[whead_q] : Gap1Def})
                     - 17'sd36 + signed'({2'd0, wslen_c[15:1]});
  always_comb begin
    whm_c = head_mod(whead_q, spt_q);
    wdsec_c = (sk_q >= whm_c) ? sk_q - whm_c : sk_q + spt_q - whm_c;
  end

  logic signed [16:0] gap1_n, gap_n;
  logic [7:0]         cnt_n, last_n;
  logic               have_n;
  always_comb begin
    gap1_n = pgap1_q;  gap_n = pgap_q;  cnt_n = pcnt_q;  last_n = plast_q;  have_n = phave_q;
    if (ev_id && fon_q) begin
      if (pgap1_q < 0)              gap1_n = signed'({3'd0, fq}) - 17'sd14;
      else if (pcnt_q == 8'd1)      gap_n  = signed'({3'd0, fq}) - pgap1_q - 17'sd14 - signed'({6'd0, slotfix_c});
      if (pcnt_q != 8'hFF) cnt_n = pcnt_q + 8'd1;
      last_n = id_sec;
      have_n = 1'b1;
    end
  end

  assign id_we    = ev_id && fon_q && pcnt_q < 8'(FMT_SLOTS);
  assign id_waddr = IW'({whead_q, pcnt_q[KW-1:0]});
  assign id_wd    = {id_hb[7], id_hb[6:5], id_hb[2:0], id_cyl, id_sec};
  assign id_raddr  = wg_q ? IW'({whead_q, sk_q[KW-1:0]}) : wk_id_use ? wk_id_raddr : pf_id_addr;
  assign pf_id_gnt = !wg_q && !wk_id_use;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fon_q <= 1'b0;  whead_q <= 3'd0;  pgap1_q <= -17'sd1;  pgap_q <= 17'sd0;
      pcnt_q <= 8'd0;  plast_q <= 8'd0;  phave_q <= 1'b0;  stop_q <= 1'b0;
      sl_q <= SlIdle;  srem_q <= 16'd0;  sk_q <= 8'd0;  ssec_q <= 8'd0;
      fpn_q <= 2'd0;  fps0_q <= 8'd0;  fps1_q <= 8'd0;
    end else begin
      if (ev_id && fon_q && pcnt_q == 8'd0) begin fps0_q <= id_sec;  fpn_q <= 2'd1; end
      if (ev_id && fon_q && pcnt_q == 8'd1) begin fps1_q <= id_sec;  fpn_q <= 2'd2; end
      stop_q  <= wstop_c;
      pgap1_q <= gap1_n;  pgap_q <= gap_n;  pcnt_q <= cnt_n;  plast_q <= last_n;  phave_q <= have_n;
      if (wstart_c) begin
        fon_q   <= cell_c < 18'd64;
        whead_q <= hs;
        pgap1_q <= -17'sd1;  pgap_q <= 17'sd0;  pcnt_q <= 8'd0;  phave_q <= 1'b0;
        sl_q    <= SlNone;
        fpn_q   <= 2'd0;
      end
      unique case (sl_q)
        SlIdle, SlDone, SlNone: begin
          if (ev_dhdr && !fon_q) begin
            if (sn_c < 0) sl_q <= SlNone;
            else begin srem_q <= sn_c[15:0];  sk_q <= 8'd0;  sl_q <= SlDiv; end
          end
        end
        SlDiv: begin
          if (srem_q >= wslen_c) begin
            srem_q <= srem_q - wslen_c;  sk_q <= sk_q + 8'd1;
          end else if (sk_q >= (custom_q[whead_q] ? fnsl_q[whead_q] : spt_q)) begin
            sl_q <= SlNone;
          end else begin
            sl_q <= SlId;
          end
        end
        SlId: sl_q <= SlIdv;
        SlIdv: begin
          ssec_q <= custom_q[whead_q] ? id_q[7:0] : wdsec_c;
          sl_q   <= SlDone;
        end
        default: sl_q <= SlNone;
      endcase
    end
  end

  // Commit a complete data field.
  logic       dsec_ok_c;
  logic [7:0] dsec_c;
  assign dsec_ok_c = fon_q ? phave_q : sl_q == SlDone;
  assign dsec_c    = fon_q ? plast_q : ssec_q;


  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cm_req_q <= 1'b0;  cm_head_q <= 3'd0;  cm_sec_q <= 8'd0;
    end else begin
      cm_req_q  <= ev_data && dsec_ok_c && dsec_c < spt_q && {1'b0, whead_q} < heads_q &&
                   writable_c && buf_ok_c;
      cm_head_q <= whead_q;
      cm_sec_q  <= dsec_c;
    end
  end

  // Format commit at the end of a pass (after the decoder's last event).
  logic fmt_commit_c;
  assign fmt_commit_c = stop_q && fon_q && !(gap1_n < 0);
  assign fc_req_c     = fmt_commit_c && present_q && geo_ok_q;
  assign fc_gap_c     = (gap_n > 0) ? gap_n[15:0] : Gap3Def;
  assign fc_nsl_c     = (cnt_n > 8'(FMT_SLOTS)) ? 8'(FMT_SLOTS) : cnt_n;
  always_comb begin
    fc_custom_c = custom_q;
    fc_custom_c[whead_q] = 1'b1;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      custom_q <= 8'h00;
      for (int i = 0; i < 8; i++) begin fgap1_q[i] <= Gap1Def; fgap_q[i] <= Gap3Def; fnsl_q[i] <= 8'd0; end
    end else if (mount_ev_q || load_ev) begin
      custom_q <= 8'h00;
    end else if (fl_custom_we) begin
      custom_q <= fl_custom;
    end else if (fl_hdr_we) begin
      fgap1_q[fl_h] <= fl_gap1;
      fgap_q[fl_h]  <= fl_gap;
      fnsl_q[fl_h]  <= fl_nsl;
    end else if (fmt_commit_c) begin
      custom_q          <= fc_custom_c;
      fgap1_q[whead_q]  <= gap1_n[15:0];
      fgap_q[whead_q]   <= fc_gap_c;
      fnsl_q[whead_q]   <= fc_nsl_c;
    end
  end

  // ------------------------------------------------------------------
  // Read channel.

  logic [2:0]  hs_q;
  logic [2:0]  wfh;
  logic        wk_done;
  logic [7:0]  wk_val;
  logic        wk_mark;
  logic        wk_miss;
  logic        wk_miss_c;      // a miss on a head with a surface (others hold no data)
  logic        wk_start_c;

  assign wk_start_c = run_c && bstart_c && !wg_c;

  st506_walker #(.MAX_L2(MAX_L2), .FMT_SLOTS(FMT_SLOTS)) u_walker (
    .clk, .rst_n, .start(wk_start_c), .pos_byte(nb_next_c), .head(hs),
    .hint_clr(mount_ev_q || load_ev || fl_hdr_we || fmt_commit_c), .fhead(wfh),
    .fmt_custom(custom_q[wfh]), .fmt_gap1(fgap1_q[wfh]), .fmt_gap(fgap_q[wfh]), .fmt_nslots(fnsl_q[wfh]),
    .cyl(cyl_q), .spt(spt_q), .ssz(ssz_q),
    .id_raddr(wk_id_raddr), .id_q, .id_use(wk_id_use),
    .lk_head, .lk_sec, .lk_hit, .lk_ent, .lk_full, .lk_cnt,
    .wk_addr, .wk_q, .ek_idx, .ek_q,
    .done(wk_done), .val(wk_val), .mark(wk_mark), .miss(wk_miss)
  );

  assign wk_miss_c = wk_miss && {1'b0, wfh} < heads_q;

  // Justification: cells of the byte under the head, last data bit, settle count (reg-a).
  logic [15:0] cells_q;
  logic        lsb_q;
  logic [1:0]  settle_q;
  logic [15:0] cells_c;
  logic [1:0]  settle_n;
  logic        cell_bit_c;

  always_comb begin
    cells_c = cells_q;
    if (bstart_c) cells_c = wk_mark ? A1Cells : mfm_cells(wk_val, (nb_q == 14'd0) ? 1'b0 : lsb_q);
    cell_bit_c = cells_c[4'd15 - sib_q[4:1]];
    settle_n = settle_q;
    if (bstart_c && settle_q != 2'd3) settle_n = settle_q + 2'd1;
    if (hs != hs_q || wg_c || !buf_ok_n || (bstart_c && (!wk_done || wk_miss_c))) settle_n = 2'd0;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hs_q <= 3'd0;  cells_q <= 16'h0000;  lsb_q <= 1'b0;  settle_q <= 2'd0;
    end else if (mount_ev_q) begin
      settle_q <= 2'd0;
    end else if (run_c) begin
      hs_q     <= hs;
      settle_q <= settle_n;
      if (bstart_c) begin
        cells_q <= cells_c;
        lsb_q   <= wk_val[0];
      end
    end
  end

  // ------------------------------------------------------------------
  // Cable outputs, updated at each step.

  // Justification: drive outputs (reg-a, one per pin).
  logic drdy_q, sc_q, tk_q, wf_q, idx_q, rmfm_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      drdy_q <= 1'b0;  sc_q <= 1'b1;  tk_q <= 1'b1;  wf_q <= 1'b0;  idx_q <= 1'b0;  rmfm_q <= 1'b0;
    end else if (step_en) begin
      drdy_q <= ds && media_c && spun_q;
      sc_q   <= ds && scl_n && (!media_c || buf_ok_n);
      tk_q   <= ds && cyl_n == 11'd0;
      wf_q   <= ds && media_c && wg_c && !writable_c;
      idx_q  <= ds && turn_q && nb_q == 14'd0 && sib_q == 5'd0;
      rmfm_q <= ds && media_c && turn_q && buf_ok_n && !wg_c && on_surf_c && cstart_c &&
                settle_n == 2'd3 && cell_bit_c;
    end
  end

  assign drdy  = drdy_q;
  assign sc    = sc_q;
  assign tk000 = tk_q;
  assign wf    = wf_q;
  assign index = idx_q;
  assign rmfm  = rmfm_q;

  // A sector the walker needed and did not have, while the drive reads.
  // Justification: registered late pulse (reg-a).
  logic late_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) late_q <= 1'b0;
    else        late_q <= m_late || (run_c && bstart_c && wk_done && wk_miss_c && media_c && turn_q &&
                                     buf_ok_c && !wg_c && wfh == hs);
  end
  assign late = late_q;

endmodule

`default_nettype wire
