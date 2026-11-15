// LR (low-resolution, 80x25 text) display card, sheets
// 47-51: U30 16.257 MHz oscillator, U24 character counter, U13 PAL16R6A
// sequencer, U18 ZRSEL decode, U9 HD46505 CRTC, U5/U6 CDR, U2 character
// ROM + U1 shifter, U22 attribute PLA, U31 Z8030 SCC and the U36 socket
// for a second one.
// The card sits at the bottom of the interrupt chain (IEI from CN11 pin
// 33), U31 then U36.
//
// Clocks.  The card has two clock domains, as the board does:
//   clk      Z-Bus side (the machine's master clock; ZCLK arrives as its
//            rise pulse).  Decode (U18, U27, U28), /WAIT, the CDR CPU port, the
//            control latch, U31, and U9 (the HD6545, clocked on its CLK
//            and E pins).
//   clk_vid  dot side: U30 = CLKS_PER_DOT clk_vid cycles per dot
//            (65.028 MHz = 4 x 16.257 MHz).  U24, the video half of U13,
//            the CRTC-side VRAM port, U2, U1, U22.  Every video output is
//            a clk_vid register; ce_pix marks a dot.
//
// Crossings (the board's two crystals):
//   clk_vid -> clk  CCLK (U24 QC inverted) to the 6845 CLK pin: c900_sync2,
//                   then its fall as a one-master-clock pulse.
//   clk -> clk_vid  the 6845's MA, RA, DE, CURSOR, HSYNC, VSYNC: they
//                   change once per character, a few master clocks after
//                   the CCLK fall, and the dot side takes them at the end
//                   of dot 8 (the VRAM fetch, lr_pixel_path stage A), more
//                   than four dots later.
//   clk_vid -> clk  CPU VRAM slot, once per character: lr_cdc_event.  The
//                   board's /WAIT arbitration (U13) is modelled on the clk
//                   side against this event (see lr_cdr).
//   both            VRAM U5/U6: dual-clock block RAM, port per domain.
//                   U2 character ROM: written by the loader (clk), read by
//                   the pixel path (clk_vid); quasi-static.
//   reset           rst_n is registered here and released into clk_vid by
//                   c900_rst_sync.
//
// Backplane pins taken as ports, as on CN11: _I-O3 and _I-O4 (main board
// U57) and _SUP (Z8010).  pa is the backplane address A23:A0.
// vs_hit_last in the vendored 6845 core has no reset.
`default_nettype none
module c900_lr_card #(
  parameter int CLKS_PER_DOT = 4
) (
  input  logic        clk,
  input  logic        rst_n,           // card held in reset when absent
  input  logic        mreset_n,        // backplane _MRESET
  input  logic        clk_vid,         // CLKS_PER_DOT x 16.257 MHz
  // ROM loader (U2 character ROM), clk domain
  input  logic        rom_we,
  input  logic [11:0] rom_addr,
  input  logic [7:0]  rom_data,
  // backplane, clk domain
  input  logic        clk_pin_rise,    // CN11 CLK = QA inverted by U13
  input  logic        clk_pin_fall,
  input  logic [15:0] ad_bus,
  input  logic [23:0] pa,
  input  logic        as_n,
  input  logic        ds_n,
  input  logic        mreq_n,
  input  logic        r_w,
  input  logic        b_w,
  input  logic        io3_n,           // CN11 _I-O3
  input  logic        io4_n,           // CN11 _I-O4
  input  logic        sup_n,           // CN _SUP
  input  logic        intack_n,
  input  logic        iei,
  output logic [15:0] ad_out,
  output logic [15:0] ad_oe,
  output logic        wait_n,
  output logic        wait_nx,         // NON-STOCK: /WAIT one clock ahead, for a 48 MHz turbo CPU
  output logic        vi_n,
  output logic        ieo,
  // SCC serial lines: [1:0] U31, [3:2] U36; channel A even.  /DSR reaches
  // /SYNC through the 1489.
  input  logic [3:0]  scc_rxd,
  input  logic [3:0]  scc_cts_n,
  input  logic [3:0]  scc_dcd_n,
  input  logic [3:0]  scc_dsr_n,
  output logic [3:0]  scc_txd,
  output logic [3:0]  scc_rts_n,
  output logic [3:0]  scc_dtr_n,
  // video (CN2), clk_vid domain
  output logic        ce_pix,
  output logic        hsync,
  output logic        vsync,
  output logic        de,
  output logic        hblank,
  output logic        vblank,
  output logic        vid,
  output logic        intens
);
  // ---- resets ------------------------------------------------------------------
  logic rst_q, rst_vid_n;
  always_ff @(posedge clk) rst_q <= rst_n;
  c900_rst_sync u_rst_vid (.clk(clk_vid), .arst(~rst_q), .pll_locked(1'b1), .rst_n(rst_vid_n));

  // ---- U27, U28, U18 ZRSEL ---------------------------------------------------------
  logic        u27_y, u28_y;
  logic [15:0] u18_i;
  logic [7:0]  u18_f;
  logic        cdr_sel, crtc_sel, ph2, ctl_n, stat_n, seli_o_n;

  assign u27_y = pa[16] & pa[17] & pa[18];
  assign u28_y = ~(pa[20] & pa[21]);

  always_comb begin
    u18_i     = 16'h0000;
    u18_i[0]  = pa[0];
    u18_i[1]  = pa[2];
    u18_i[2]  = pa[3];
    u18_i[3]  = pa[4];
    u18_i[4]  = u27_y;
    u18_i[5]  = u28_y;
    u18_i[6]  = pa[19];
    u18_i[7]  = pa[22];
    u18_i[8]  = pa[23];
    u18_i[9]  = ~r_w;          // BW-R
    u18_i[10] = b_w;           // BB-W
    u18_i[11] = mreq_n;        // _BMREQ
    u18_i[12] = ds_n;          // _BDS
    u18_i[13] = io4_n;         // _I-O4
    u18_i[14] = sup_n;         // _SUP
    u18_i[15] = 1'b1;          // _CCLK: unused by the decode, not crossed
  end

  lr_u18_zrsel u18 (.i(u18_i), .f(u18_f));

  assign cdr_sel  = ~u18_f[0];
  assign seli_o_n = u18_f[1];
  assign ctl_n    = u18_f[2];
  assign stat_n   = u18_f[3];
  assign crtc_sel = ~u18_f[4];
  assign ph2      = u18_f[5];

  // ---- dot side: U30 / U24 / U13 ----------------------------------------------------
  logic       dot_ce, cpu_slot, fetch, latch, load;
  logic [3:0] u24_q;

  lr_u13_pal #(.CLKS_PER_DOT(CLKS_PER_DOT)) u13 (
    .clk_vid(clk_vid), .rst_n(rst_vid_n), .dot_ce(dot_ce), .q(u24_q),
    .cpu_slot(cpu_slot), .fetch(fetch), .latch(latch), .load(load)
  );

  logic slot_ev;
  lr_cdc_event u_slot_x (
    .src_clk(clk_vid), .src_rst_n(rst_vid_n), .src_pulse(cpu_slot),
    .dst_clk(clk), .dst_rst_n(rst_q), .dst_pulse(slot_ev)
  );

  // ---- U9 HD6545 CRTC ------------------------------------------------------------------
  // The CRTC is clocked on its pins: CLK (CCLK = /U24 QC through U14, a
  // dot-side level brought into the bus domain through c900_sync2) and E
  // (PH2 from U18).  RS = A1, R/W = BR-W, /CS = U18's CRTC select.  The
  // CPU holds the bus past the fall of E on the board; on the registered
  // bus the next cycle is already there in the clock E falls, so the
  // pins the CRTC sees are taken while E is High and held after it.
  // The CRTC's pins take edge pulses: the CLK fall after the synchroniser,
  // and the rise and fall of U18's PH2 output (a decode of the bus, edge
  // detected on the master clock like any strobe).
  logic       cclk_vid, cclk, cclk_q, cclk_fall, ph2_q, e_rise, e_fall;
  logic       e_rs_q, e_rw_q, e_cs_n_q;
  logic [7:0] e_d_q;
  always_ff @(posedge clk_vid) cclk_vid <= ~u24_q[2];
  c900_sync2 #(.INIT(1'b1)) u_cclk_x (.clk(clk), .d(cclk_vid), .q(cclk));
  always_ff @(posedge clk) begin
    cclk_q <= cclk;
    ph2_q  <= ph2;
  end
  assign cclk_fall = cclk_q & ~cclk;
  assign e_rise    = ph2 & ~ph2_q;
  assign e_fall    = ~ph2 & ph2_q;

  always_ff @(posedge clk) begin
    if (!rst_q) begin
      e_rs_q   <= 1'b0;
      e_rw_q   <= 1'b1;
      e_cs_n_q <= 1'b1;
      e_d_q    <= 8'hFF;
    end else if (ph2) begin
      e_rs_q   <= pa[1];
      e_rw_q   <= r_w;
      e_cs_n_q <= ~crtc_sel;
      e_d_q    <= ad_bus[7:0];
    end
  end

  logic [7:0]  crtc_do;
  logic        crtc_doe, crtc_hs, crtc_vs, crtc_de, crtc_cur;
  logic [13:0] ma;
  logic [4:0]  ra;

  // nRESET is an asynchronous clear in the 6845: fed from a register.
  logic crtc_rst_n_q;
  always_ff @(posedge clk) crtc_rst_n_q <= rst_q & mreset_n;

  mc6845_lrdisp u9_crtc (
    .clk(clk), .reset_n(crtc_rst_n_q), .cclk(cclk_fall), .e_rise(e_rise), .e_fall(e_fall), .cs_n(e_cs_n_q), .rs(e_rs_q),
    .r_w(e_rw_q), .d_in(e_d_q), .d_out(crtc_do), .d_oe(crtc_doe), .lpstb(1'b0),
    .hsync(crtc_hs), .vsync(crtc_vs), .de(crtc_de), .cursor(crtc_cur), .ma(ma), .ra(ra)
  );

  // ---- control latch (_CTL, I/O 0x0418 write) ---------------------------------------
  // Clocked at the end of _CTL.  Its bits feed U23 (ENVID / EN_LINK) on
  // sheet 47; which bits and what they gate is untraced: the value is held
  // only.
  // (The registered bus shows the next cycle in the clock _CTL rises, so the
  // byte is taken while _CTL is Low; the last such value is what the edge
  // clocks in.)
  logic [7:0] ctl_q;
  always_ff @(posedge clk) begin
    if (!rst_q || !mreset_n) ctl_q <= 8'h00;   // U23 CLR = _MRESET
    else if (!ctl_n)         ctl_q <= ad_bus[7:0];
  end

  // ---- CDR U5/U6 ----------------------------------------------------------------------
  logic [15:0] cdr_ad_out;
  logic        cdr_ad_oe;
  logic [7:0]  chr, attr;

  lr_cdr u5_u6 (
    .clk(clk), .rst_n(rst_q), .cdr_sel(cdr_sel), .ds_n(ds_n), .r_w(r_w), .b_w(b_w),
    .a0(pa[0]), .wa(pa[11:1]), .ad_in(ad_bus), .slot(slot_ev),
    .ad_out(cdr_ad_out), .ad_oe(cdr_ad_oe), .wait_n(wait_n), .wait_nx(wait_nx),
    .clk_vid(clk_vid), .fetch(fetch), .ma(ma[10:0]), .chr(chr), .attr(attr)
  );

  // ---- U2 character ROM (4 KB, loaded from boot1.rom) -----------------------------------
  (* ramstyle = "M10K, no_rw_check" *) logic [7:0] u2_mem [0:4095];
  logic [11:0] crom_addr;
  logic [7:0]  crom_q;
  always_ff @(posedge clk) if (rom_we) u2_mem[rom_addr] <= rom_data;
  always_ff @(posedge clk_vid) crom_q <= u2_mem[crom_addr];

  // ---- pixel path: U3/U4/U21/U1/U22/U25 ---------------------------------------------------
  lr_pixel_path u_pix (
    .clk_vid(clk_vid), .rst_n(rst_vid_n), .dot_ce(dot_ce), .fetch(fetch), .latch(latch),
    .load(load), .chr(chr), .attr(attr),
    .ra(ra), .de(crtc_de), .cursor(crtc_cur), .hs(crtc_hs), .vs(crtc_vs),
    .rom_addr(crom_addr), .rom_q(crom_q),
    .ce_pix(ce_pix), .vid(vid), .intens(intens), .hsync(hsync), .vsync(vsync),
    .de_out(de), .hblank(hblank), .vblank(vblank)
  );

  // ---- SCCs: _CS0 = _I-O3; CS1 = /A7 (U31, 0x0300-0x037F) or A7 (U36,
  // 0x0380-0x03FF); PCLK and /RTxCA, /RTxCB = backplane CLK.  /TRxC: no load.
  logic [7:0] u31_ad_out, u36_ad_out;
  logic       u31_ad_drive, u36_ad_drive, u31_int_n, u36_int_n, u31_ieo, u36_ieo;
  logic [3:0] trxc_out, trxc_drive, sync_out, sync_drive;

  z8030_scc u31_scc (
    .clk(clk),
    .ad_in(ad_bus[7:0]), .as_n(as_n), .ds_n(ds_n), .r_w(r_w), .cs0_n(io3_n), .cs1(~pa[7]),
    .intack_n(intack_n), .iei(iei), .pclk_rise(clk_pin_rise),
    .rxd(scc_rxd[1:0]), .cts_n(scc_cts_n[1:0]), .dcd_n(scc_dcd_n[1:0]),
    .trxc_rise(2'b00), .trxc_fall(2'b00), .rxc_rise({2{clk_pin_rise}}), .rxc_fall({2{clk_pin_fall}}), .sync_in(scc_dsr_n[1:0]),
    .ad_out(u31_ad_out), .ad_drive(u31_ad_drive), .int_n(u31_int_n), .ieo(u31_ieo),
    .txd(scc_txd[1:0]), .rts_n(scc_rts_n[1:0]), .dtr_n(scc_dtr_n[1:0]),
    .trxc_out(trxc_out[1:0]), .trxc_drive(trxc_drive[1:0]), .sync_out(sync_out[1:0]),
    .sync_drive(sync_drive[1:0])
  );

  z8030_scc u36_scc (
    .clk(clk),
    .ad_in(ad_bus[7:0]), .as_n(as_n), .ds_n(ds_n), .r_w(r_w), .cs0_n(io3_n),
    .cs1(pa[7]), .intack_n(intack_n), .iei(u31_ieo), .pclk_rise(clk_pin_rise),
    .rxd(scc_rxd[3:2]), .cts_n(scc_cts_n[3:2]), .dcd_n(scc_dcd_n[3:2]),
    .trxc_rise(2'b00), .trxc_fall(2'b00), .rxc_rise({2{clk_pin_rise}}), .rxc_fall({2{clk_pin_fall}}), .sync_in(scc_dsr_n[3:2]),
    .ad_out(u36_ad_out), .ad_drive(u36_ad_drive), .int_n(u36_int_n), .ieo(u36_ieo),
    .txd(scc_txd[3:2]), .rts_n(scc_rts_n[3:2]), .dtr_n(scc_dtr_n[3:2]),
    .trxc_out(trxc_out[3:2]), .trxc_drive(trxc_drive[3:2]), .sync_out(sync_out[3:2]),
    .sync_drive(sync_drive[3:2])
  );
  assign vi_n = u31_int_n & u36_int_n;
  assign ieo  = u36_ieo;

  // ---- AD drive: CDR word, CRTC and SCC on AD7:0 ---------------------------------------
  // The 6545 drives only for R14-R17; _STAT (0x041C read) has no known
  // data source and drives nothing.

  always_comb begin
    ad_oe  = 16'h0000;
    ad_out = 16'hFFFF;
    if (cdr_ad_oe) begin
      ad_oe  = 16'hFFFF;
      ad_out = cdr_ad_out;
    end
    if (crtc_doe) begin
      ad_oe[7:0]  = 8'hFF;
      ad_out[7:0] = ad_out[7:0] & crtc_do;
    end
    if (u31_ad_drive) begin
      ad_oe[7:0]  = 8'hFF;
      ad_out[7:0] = ad_out[7:0] & u31_ad_out;
    end
    if (u36_ad_drive) begin
      ad_oe[7:0]  = 8'hFF;
      ad_out[7:0] = ad_out[7:0] & u36_ad_out;
    end
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, u24_q, pa[15:12], u18_f[7:6], seli_o_n, stat_n, ctl_q, ma[13:11],
                       trxc_out, trxc_drive, sync_out, sync_drive};
endmodule
`default_nettype wire
