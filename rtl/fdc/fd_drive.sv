// C900 5.25" 96-TPI floppy drives 0 and 1 (an FPGA-side board, not a
// chip): both drives on the 8723's cable, each with its medium, a
// 1,224,704-byte image behind one MiSTer hps_io sd_* slot per drive.
//
// Drive side = the digital drive port at the 8723, as levels.  Per drive: stepper phases PH[3:0], MTRON, LED in;
// TRK0 and WRPT out (sensor levels, High = track 0 / protected).  Shared:
// HOSEL (side), WRGT, ERASE, WD (write current), NWD in; RDATA (read amp
// pulse, High) out.  The head matrix (U205: A = HOSEL, B = LED1,
// C = WRGT or ERASE) puts drive LED1's head of side HOSEL on RDATA and
// gives only that drive WRGT and WD.  LED0, ERASE and NWD do not change
// a drive.
//
// Time base: one tick = one `clkin` pulse, the board's 6 MHz _CLK rise
// (a one-clk pulse; pulses may be on consecutive clks).  Per drive:
//   - Stepper: a phase change to the adjacent entry of the 05/06/0A/09
//     table moves the head one track (0-79); the head reads nothing for
//     STEP_TICKS + SETTLE_TICKS after it.
//   - Spindle: 300 RPM, speed ramping 0 -> full over SPINUP_TICKS with
//     MTRON (and back with it off); the platter advances by the speed
//     each tick and keeps its angle across steps.
//   - Track: zoned GCR, 13/14/15/16 ticks per cell, the firmware layout
//     (fd_layout) walked for both heads from sector data fetched a
//     sector ahead, one RDATA pulse of 2 ticks at the start of each
//     recorded 1.  One walk serves the drive LED1 selects (`wown_q`).
//     An LED1 change ends the old drive's burst, writes the rings back,
//     then moves the walk to the new drive, which reseeks; RDATA is low
//     meanwhile, and a burst cannot start (WRGT then sets `late`).
//   - Write: each WD edge under WRGT records a 1 in the cell under the
//     head, a cell without one records a 0, into the raw record of that
//     side (fd_raw).  When the burst ends, the record is decoded
//     (fd_scan, one decoder for both drives): a clean sector set goes to
//     the image and the record is dropped; otherwise the head keeps
//     reading the record.
//   - Image: resident on the image side; sector data and the raw
//     records' blocks are fetched as the heads need them (fd_media).  The
//     records and the decoder's staging use a scratch region per slot
//     (`sd_scr` held with sd_rd/sd_wr; RAM only on the server).
//     `late` (sticky) says a head needed data that had not arrived.
//
// Raw records: one per drive and side; one ring per side, for the walk's
// drive.  A write on a side whose record
// belongs to another track drops that record (the model keeps one per
// track).  While a record is decoded and committed the head reads the
// record; the model switches to the sectors at once.  A new burst on the
// same side before the decode is done joins the record and the decode
// runs at its end (the model decodes each burst at its own end, so a
// clean burst followed at once by an unclean one commits in the model
// and not here).  A gate held through a step drops the old track's
// record undecoded.  Every cell under the gate is rewritten.
`default_nettype none

module fd_drive #(
  parameter int unsigned STEP_TICKS   = 18000,     // 3 ms
  parameter int unsigned SETTLE_TICKS = 90000,     // 15 ms
  parameter int unsigned SPINUP_TICKS = 2400000    // 400 ms
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             clkin,
  // drive port
  input  logic [1:0][3:0]  ph,
  input  logic [1:0]       mtron,
  input  logic [1:0]       led,
  input  logic             hosel,
  input  logic             wrgt,
  input  logic             erase,
  input  logic             wd,
  input  logic             nwd,
  output logic             rdata,
  output logic [1:0]       trk0,
  output logic [1:0]       wrpt,
  // image side, one hps_io slot per drive
  input  logic [1:0]       img_mounted,
  input  logic             img_readonly,
  input  logic [63:0]      img_size,
  output logic [1:0][31:0] sd_lba,
  output logic [1:0]       sd_scr,
  output logic [1:0]       sd_rd,
  output logic [1:0]       sd_wr,
  input  logic [1:0]       sd_ack,
  input  logic [8:0]       sd_buff_addr,
  input  logic [7:0]       sd_buff_dout,
  output logic [1:0][7:0]  sd_buff_din,
  input  logic             sd_buff_wr,
  output logic             late
);
  import fd_pkg::*;

  logic unused_ok;
  assign unused_ok = &{1'b0, led[0], erase, nwd, img_size[63:32]};

  // ------------------------------------------------------------------
  // Mount

  // Justification: per drive medium present, write protect, mount event (reg-a).
  logic [1:0] present_q, ro_q, mount_ev_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      present_q <= 2'b00;  ro_q <= 2'b11;  mount_ev_q <= 2'b00;
    end else begin
      mount_ev_q <= img_mounted;
      for (int d = 0; d < 2; d++)
        if (img_mounted[d]) begin present_q[d] <= |img_size[31:0]; ro_q[d] <= img_readonly; end
    end
  end

  // ------------------------------------------------------------------
  // Drives

  logic             sel_c;
  logic [1:0]       h_rdata, h_late;
  logic [1:0][6:0]  w_trk, h_trk;
  logic [1:0]       w_req, w_need, w_gnt, w_sec_ok, w_warm;
  logic [1:0][13:0] w_raddr;
  logic [1:0][7:0]  w_rdata, w_ck_q;
  logic [1:0][4:0]  w_ck_idx, w_sec;
  logic [3:0]       r_rq, r_rq_wr, r_take, r_done, r_pb_we, r_pb_rd;
  logic [3:0][5:0]  r_rq_blk;
  logic [3:0][7:0]  r_pb_q;
  logic [3:0][RawBlocks-1:0] r_written;
  logic [8:0]       pb_addr;
  logic [7:0]       pb_d;
  logic [1:0]       dq_v, dq_side, dgo, downs, dabort, ddone, cm_req;
  logic [1:0][6:0]  dq_trk;
  logic             dec_busy, dec_done, dec_clean, cm_busy, m_dbusy;
  logic [4:0]       map16;

  assign sel_c = led[1];

  // ------------------------------------------------------------------
  // Walk owner.  On an LED1 change: the old owner's burst ends (its WRGT
  // is gone), the rings stop fetching and write back, then in one clk
  // (no record clear under way) they are emptied, the owner changes to
  // the current LED1 and reseeks.  The walk's sector is the old owner's
  // until that seek.

  // Justification: walk owner, switch pending, reseek pending (reg-a).
  logic       wown_q, sw_q, skp_q;
  logic [1:0] l_clean, l_busy, h_wron, h_resk;
  logic [1:0] h_seek;
  logic [1:0][1:0] h_clr;
  logic       swap_c;
  assign swap_c = sw_q && !h_wron[wown_q] && &l_clean && !(|l_busy) && !(|h_clr);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wown_q <= 1'b0;  sw_q <= 1'b0;
    end else if (swap_c) begin
      wown_q <= sel_c;  sw_q <= 1'b0;
    end else if (sel_c != wown_q) begin
      sw_q <= 1'b1;
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                skp_q <= 1'b0;
    else if (swap_c)           skp_q <= 1'b1;
    else if (h_seek[wown_q])   skp_q <= 1'b0;
  end
  always_comb
    for (int d = 0; d < 2; d++) h_resk[d] = swap_c && sel_c == 1'(d);

  // per-drive head signals for the walk and the rings
  logic [1:0]        h_adv, h_load, h_radv, h_wrap;
  logic [1:0][16:0]  h_pos, h_cell;
  logic [1:0][12:0]  h_nwords;
  logic [1:0][1:0]   h_act, h_hold, h_set, h_val, h_flush, h_clean;
  logic              l_rdy, l_ahead, l_lost;
  logic [1:0]        l_bits, l_mask, l_data, l_rdy_r, l_late, l_full;
  logic [1:0][RawBlocks-1:0] l_written [2];

  genvar gd;
  generate
  for (gd = 0; gd < 2; gd++) begin : g_drv
    fd_head #(.STEP_TICKS(STEP_TICKS), .SETTLE_TICKS(SETTLE_TICKS), .SPINUP_TICKS(SPINUP_TICKS)) u_head (
      .clk, .rst_n, .ce(clkin),
      .ph(ph[gd]), .mtron(mtron[gd]), .hosel,
      .wrgt(wrgt && sel_c == 1'(gd)), .wd(wd && sel_c == 1'(gd)),
      .rdata(h_rdata[gd]), .trk0(trk0[gd]), .wrpt(wrpt[gd]), .late(h_late[gd]),
      .mount_ev(mount_ev_q[gd]), .present_q(present_q[gd]), .ro_q(ro_q[gd]),
      .own(wown_q == 1'(gd) && !sw_q), .resk(h_resk[gd]), .trk(h_trk[gd]),
      .l_seek(h_seek[gd]), .l_pos(h_pos[gd]), .l_adv(h_adv[gd]), .l_rdy, .l_ahead, .l_lost, .l_bits, .l_warm(w_warm[wown_q]),
      .r_nwords(h_nwords[gd]), .r_act(h_act[gd]), .r_hold(h_hold[gd]), .r_load(h_load[gd]),
      .r_cell(h_cell[gd]), .r_adv(h_radv[gd]), .r_wrap(h_wrap[gd]), .r_set(h_set[gd]), .r_val(h_val[gd]),
      .r_flush(h_flush[gd]), .r_clr(h_clr[gd]), .r_mask(l_mask), .r_data(l_data), .r_rdy(l_rdy_r),
      .r_late(l_late), .r_full(l_full), .r_clean(h_clean[gd]), .wron(h_wron[gd]),
      .dq_v(dq_v[gd]), .dq_side(dq_side[gd]), .dq_trk(dq_trk[gd]), .dgo(dgo[gd]), .downs(downs[gd]),
      .dabort(dabort[gd]), .ddone(ddone[gd]), .dclean(dec_clean), .cm_busy, .cm_req(cm_req[gd])
    );
    // a drive's records are clean on the image side unless it owns the rings
    assign h_clean[gd] = wown_q == 1'(gd) ? l_clean : 2'b11;
  end
  endgenerate
  assign w_trk = h_trk;

  // ------------------------------------------------------------------
  // Shared walk and rings, on the owner's track and cell

  logic        l_req, l_need, l_gnt, l_sec_ok;
  logic [13:0] l_raddr;
  logic [7:0]  l_rdata, l_ck_q;
  logic [4:0]  l_ck_idx, l_sec;
  fd_layout #(.NS(2)) u_lay (
    .clk, .rst_n, .track(h_trk[wown_q]), .side0(1'b0),
    .seek(h_seek[wown_q]), .pos(h_pos[wown_q]), .adv(h_adv[wown_q]),
    .rdy(l_rdy), .ahead(l_ahead), .bit_q(l_bits),
    .req(l_req), .raddr(l_raddr), .need(l_need), .gnt(l_gnt), .rdata(l_rdata), .ck_idx(l_ck_idx),
    .ck_q(l_ck_q), .sec(l_sec), .sec_ok(l_sec_ok), .lost(l_lost)
  );
  always_comb
    for (int d = 0; d < 2; d++) begin
      w_req[d]    = l_req && wown_q == 1'(d);
      w_need[d]   = l_need && wown_q == 1'(d);
      w_sec_ok[d] = l_sec_ok && wown_q == 1'(d) && !skp_q;
      w_raddr[d]  = l_raddr;
      w_ck_idx[d] = l_ck_idx;
      w_sec[d]    = l_sec;
    end
  assign l_gnt   = w_gnt[wown_q];
  assign l_rdata = w_rdata[wown_q];
  assign l_ck_q  = w_ck_q[wown_q];

  logic [1:0]       l_rq, l_rq_wr, l_take, l_done, l_pb_we, l_pb_rd;
  logic [1:0][5:0]  l_rq_blk;
  logic [1:0][7:0]  l_pb_q;
  genvar gs;
  generate
  for (gs = 0; gs < 2; gs++) begin : g_raw
    fd_raw u_raw (
      .clk, .rst_n, .nwords(h_nwords[wown_q]), .act(h_act[wown_q][gs] && !sw_q), .hold(h_hold[wown_q][gs]),
      .h_load(h_load[wown_q]), .h_cell(h_cell[wown_q]), .h_adv(h_radv[wown_q]), .h_wrap(h_wrap[wown_q]),
      .h_set(h_set[wown_q][gs]), .h_val(h_val[wown_q][gs]),
      .h_flush(h_flush[wown_q][gs]), .h_mask(l_mask[gs]), .h_data(l_data[gs]), .h_rdy(l_rdy_r[gs]),
      .h_late(l_late[gs]), .h_full(l_full[gs]), .clr(h_clr[wown_q][gs]), .own(wown_q), .oclr(h_clr[!wown_q][gs]),
      .inv(swap_c), .clean(l_clean[gs]), .busy(l_busy[gs]), .written(l_written[gs]),
      .rq(l_rq[gs]), .rq_wr(l_rq_wr[gs]), .rq_blk(l_rq_blk[gs]), .take(l_take[gs]), .done(l_done[gs]),
      .pb_we(l_pb_we[gs]), .pb_rd(l_pb_rd[gs]), .pb_addr, .pb_d, .pb_q(l_pb_q[gs])
    );
  end
  endgenerate

  // fd_media's lanes are {drive, side}: the rings' jobs go to the owner's
  always_comb
    for (int l = 0; l < 4; l++) begin
      r_rq[l]      = l_rq[l & 1] && wown_q == 1'(l >> 1);
      r_rq_wr[l]   = l_rq_wr[l & 1];
      r_rq_blk[l]  = l_rq_blk[l & 1];
      r_pb_q[l]    = l_pb_q[l & 1];
      r_written[l] = l_written[l & 1][l >> 1];
    end
  always_comb
    for (int s = 0; s < 2; s++) begin
      l_take[s]  = r_take[{wown_q, 1'(s)}];
      l_done[s]  = r_done[{wown_q, 1'(s)}];
      l_pb_we[s] = r_pb_we[{wown_q, 1'(s)}];
      l_pb_rd[s] = r_pb_rd[{wown_q, 1'(s)}];
    end

  // ------------------------------------------------------------------
  // Decoder, shared: one decode or commit at a time.

  // Justification: drive, track and side of the decode and its commit (reg-a).
  logic       own_q, dside_q;
  logic [6:0] dtrk_q;
  logic       free_c, dstart_c, dabort_c;

  assign free_c   = !dec_busy && !dec_done && !cm_busy && !(|cm_req) && !m_dbusy;
  assign dgo[0]   = free_c && dq_v[0];
  assign dgo[1]   = free_c && dq_v[1] && !dq_v[0];
  assign dstart_c = |dgo;
  always_comb
    for (int d = 0; d < 2; d++) begin
      downs[d] = dec_busy && own_q == 1'(d);
      ddone[d] = dec_done && own_q == 1'(d);
    end
  assign dabort_c = dec_busy && (dabort[own_q] || mount_ev_q[own_q]);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      own_q <= 1'b0;  dside_q <= 1'b0;  dtrk_q <= 7'd0;
    end else if (dstart_c) begin
      own_q <= dgo[1];  dside_q <= dq_side[dgo[1]];  dtrk_q <= dq_trk[dgo[1]];
    end
  end

  logic        s_req, s_need, s_gnt, s_rok, s_lsec_ok, st_we, st_stall;
  logic [13:0] s_laddr, st_addr;
  logic [7:0]  s_ldata, s_ck_q, st_d;
  logic [4:0]  s_ck_idx, s_lsec;
  logic [12:0] s_raddr;
  logic [31:0] s_rq;

  fd_scan u_scan (
    .clk, .rst_n, .start(dstart_c), .abort(dabort_c), .side(dq_side[dgo[1]]), .track(dq_trk[dgo[1]]),
    .busy(dec_busy), .done(dec_done), .clean(dec_clean), .map16, .stall(st_stall),
    .r_addr(s_raddr), .r_ok(s_rok), .r_q(s_rq),
    .req(s_req), .raddr(s_laddr), .gnt(s_gnt), .rdata(s_ldata), .need(s_need), .ck_idx(s_ck_idx), .ck_q(s_ck_q),
    .lsec(s_lsec), .lsec_ok(s_lsec_ok),
    .st_we, .st_addr, .st_d
  );

  // ------------------------------------------------------------------
  // Image side

  logic [7:0] din_c;
  fd_media u_media (
    .clk, .rst_n, .mount_ev(mount_ev_q), .present(present_q),
    .w_trk, .w_req, .w_raddr, .w_need, .w_gnt, .w_rdata, .w_ck_idx, .w_ck_q, .w_sec, .w_sec_ok, .w_warm,
    .r_rq, .r_rq_wr, .r_rq_blk, .r_take, .r_done, .r_pb_we, .r_pb_rd, .pb_addr, .pb_d, .r_pb_q, .r_written,
    .dec_busy, .dstart(dstart_c), .dd(own_q), .dtrk(dtrk_q), .dside(dside_q),
    .s_raddr, .s_rok, .s_rq, .s_req, .s_laddr, .s_need, .s_gnt, .s_ldata, .s_ck_idx, .s_ck_q,
    .s_sec(s_lsec), .s_sec_ok(s_lsec_ok), .st_we, .st_addr, .st_d, .st_stall,
    .cm_req(|cm_req), .cm_map16(map16), .cm_busy, .dbusy(m_dbusy),
    .sd_lba, .sd_scr, .sd_rd, .sd_wr, .sd_ack, .sd_buff_addr, .sd_buff_dout, .sd_buff_din(din_c), .sd_buff_wr
  );
  assign sd_buff_din = {din_c, din_c};

  // ------------------------------------------------------------------
  // Outputs

  // Justification: data-late flag, sticky (reg-a).
  logic late_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) late_q <= 1'b0;
    else if (|h_late) late_q <= 1'b1;
  end

  assign rdata = h_rdata[sel_c] && !sw_q;
  assign late  = late_q;

endmodule

`default_nettype wire
