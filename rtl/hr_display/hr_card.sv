// C900 HR display card (Rev 5): FN#2 sync group and memory-control PALs,
// FN#3 fetch counter and control register, FN#4 bitmap (block RAM),
// FN#5 CPU data path, FN#6 shifters with the FN#1 mono stage, FN#7 mouse.
// Equations of the undumped parts are INFERRED.
//
// Clocking: one master clock (48 MHz on the FPGA, at least two per 24M
// period).  The card's 24M (U103, from the 96 MHz VCO) arrives as the
// one-master-clock pulse ck24_rise and clocks U207, the 16R8s, the
// 74S299s and U104.  Every other clock pin is a real signal of the card
// (T8, H CNT, XCLK, U315 Q7, SR LAT CLK, -CDONE, CAS, MCLK, -SEL W) whose
// edge the board glue turns into a one-master-clock pulse.
//
// Video: rgbi is the four 74S299 QH' outputs (one RGBI pixel per 24M in
// colour), u104 the FN#1 ECL shifter's nibble (four mono pixels per 24M,
// bit 3 first) gated by mono_en and set to full or 80 % by mono_i.
// hsync, hsync_n and vsync_n are U262 F1, F3 and F4 (connector syncs).
// de, de_dly and vblank_n are U262 F0, F6 and F5, card nets the host
// needs for blanking.
`default_nettype none

module hr_card (
  input  logic        clk,
  input  logic        ck24_rise,
  // Z-Bus side, as the motherboard presents it
  input  logic        io4_n,     // U57 decode of an I/O cycle at 04xxH
  input  logic        bmreq_n,   // memory transaction
  input  logic [6:0]  a,         // A23-A17
  input  logic [16:0] la,        // latched A16-A0
  input  logic [15:0] ad_in,
  output logic [15:0] ad_out,
  output logic        ad_drive,
  input  logic        brw,       // high = read
  input  logic        lbw,       // high = byte
  input  logic        bds_n,
  input  logic        zclk,
  input  logic        reset_n,   // /MRESET
  output logic        wait_n,
  output logic        wait_nx,   // NON-STOCK: /WAIT one clock ahead, for a 48 MHz turbo CPU
  // J2 mouse
  input  logic        b1_n, b2_n, b3_n,
  input  logic        xa, xb, ya, yb,
  // JP3 (high = link open)
  input  logic        mc,
  input  logic        pc4,
  // video
  output logic        hsync,
  output logic        hsync_n,
  output logic        vsync_n,
  output logic        de,
  output logic        de_dly,
  output logic        vblank_n,
  output logic [3:0]  rgbi,
  output logic [3:0]  u104,
  output logic        mono_en,
  output logic        mono_i,
  // FN#4 bitmap block RAM (hr_fn4_dram)
  output logic [13:0] m_wrow,
  output logic [7:0]  m_we,
  output logic [63:0] m_wd,
  output logic [13:0] m_rrow,
  input  logic [63:0] m_q
);
  // FN#2 sync group
  logic [3:0]  t;
  logic [7:0]  f;
  logic [11:0] v;
  hr_syn syn (.clk, .ck24_rise, .mc, .pc4, .t, .f, .v);

  // FN#2 memory control
  logic       sel, wait_o, adrlat, wclk, rg, re1, re2;
  logic [3:0] arb;
  logic [7:0] mem, cas;
  hr_zsel zsel (.a, .bmreq_n, .brw, .bds_n, .srv(arb[1]),
    .sel, .wait_o, .adrlat, .wclk, .rg, .re1, .re2);
  hr_zarb zarb (.clk, .ck_rise(ck24_rise), .t, .cdone_n(!mem[2]), .sel_n(!sel),
    .ras_n(!mem[0]), .brw, .q(arb));
  hr_zmemc zmemc (.clk, .ck_rise(ck24_rise), .t, .dedly(f[6]), .vblk_n(f[5]), .de(f[0]),
    .creq_n(!arb[0]), .q(mem));
  hr_zcas zcas (.clk, .ck_rise(ck24_rise), .t8(t[3]), .ras_n(!mem[0]), .la(la[2:0]), .lbw,
    .mux(arb[2]), .vblk_n(f[5]), .q(cas));

  // FN#3, FN#4, FN#5, FN#6/FN#1
  logic [13:0] xp;
  logic [63:0] a_q, b_q, wd;
  logic [7:0]  dwe;
  logic [15:0] mem_ad;
  logic        mem_drive;
  hr_fn3_xp fn3 (.clk, .xclk(mem[1]), .cntres(f[7]), .xp);
  hr_fn4_dram fn4 (.clk, .a_row(la[16:3]), .a_we(dwe), .a_wd(wd), .a_q, .b_row(xp), .b_q,
    .m_wrow, .m_we, .m_wd, .m_rrow, .m_q);
  hr_fn5 fn5 (.clk, .cyc(mem[3]), .cdone(mem[2]), .we(arb[3]), .cas,
    .lrw(brw), .re(re1 && re2), .la(la[2:1]), .ad_in, .row_q(a_q),
    .dram_we(dwe), .dram_wd(wd), .ad_out(mem_ad), .ad_drive(mem_drive));
  hr_fn6 fn6 (.clk, .ck24_rise, .oe1(mem[6]), .oe2(mem[7]), .srld(mem[4]),
    .srlatclk(mem[5]), .cas, .row_q(b_q), .rgbi, .u104);

  // FN#7 and the U312 control register
  logic [15:0] m_ad;
  logic        m_drive, selw_n;
  logic [5:0]  ctl;
  hr_fn7 fn7 (.clk, .b1_n, .b2_n, .b3_n, .xa, .xb, .ya, .yb, .io4_n,
    .a4(la[4]), .a2(la[2]), .a1(la[1]), .zclk, .brw, .bds_n, .mc,
    .bad(m_ad), .drive(m_drive), .selw_n);
  hr_u312 u312 (.clk, .selw_n, .mreset_n(reset_n), .bad(ad_in[5:0]), .q(ctl));

  wire unused = ^{v, f[2], adrlat, wclk, rg, ctl[5:4], ctl[1:0]};

  assign wait_n   = !wait_o;
  // SRV after the next CLK (24M) edge: ZARB's SRV term on its live inputs
  wire srv_nx = ck24_rise ? (sel && (arb[1] || mem[2])) : arb[1];
  assign wait_nx  = !(sel && !srv_nx);
  assign ad_drive = mem_drive || m_drive;
  assign ad_out   = mem_drive ? mem_ad : m_ad;
  assign hsync    = f[1];
  assign hsync_n  = f[3];
  assign vsync_n  = f[4];
  assign de       = f[0];
  assign de_dly   = f[6];
  assign vblank_n = f[5];
  assign mono_en  = ctl[2];
  assign mono_i   = ctl[3];
endmodule

`default_nettype wire
