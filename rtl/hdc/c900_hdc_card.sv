// WD1003-CMD hard disk card (68-000057) on CN9: Intel 8049 U10 (the CCCP,
// on-chip 2 KB ROM), PAL U8, WD2010 U12, WD10C20 U101 + Y101 10 MHz, U5
// (74LS245 data buffer), U9 (74LS367A strobe drivers), the 74LS14 on
// IREQ- and the 7406 on INTEN, and the ST-506 drive.  Wiring:
//   8049 XTAL      host _CLK (CN9 26), U14 QA
//   8049 T0        IREQ- (CN9 22) through the 74LS14: High while asserted
//   8049 /INT      WD2010 INTRQ, inverted
//   8049 P1.2-0    WD2010 A2-0;  P1.3 WCS-: Low selects the WD2010, High
//                  enables U5 and U9 (WEN-) toward the host;  P1.5 in:
//                  WD2010 BCS active;  P1.6 HINT-: Low drives INTEN (CN9);
//                  P1.7 SMR- to U8
//   8049 P2.4/P2.5 Low selects drive 0/1
//   8049 RD-/WR-   WD2010 RE-/WE- (the WD2010 drives them inside a BCS
//                  frame: its buffer strobes) and U8
//   ALE            WD2010 BRDY
//   card data bus  8049 DB, WD2010 D, U5 to the host DMAD (OMAD) lines:
//                  toward the card while WCS- is High and the 8049 reads or
//                  the WD2010 strobes RE- (buffer read), else toward the host
//   SDHLE-         the WD2010's SDH write strobe latches the head select
//                  HS2-0 from the card data bus (latch designator untraced)
//   drives 0, 1    on one cable: each drive's DS from P2.4/P2.5; a drive
//                  not selected drives none of the shared status lines
// Clock pins take one-master-clock edge pulses: host _CLK and the card's
// Y101.  The 8049's mask ROM is loaded at startup.
`default_nettype none
module c900_hdc_card (
  input  logic        clk,           // master clock
  input  logic        rst_n,
  input  logic        host_clk_rise, // CN9 _CLK rises now (8049 XTAL, U8 CPUCLK)
  input  logic        host_clk_fall, // CN9 _CLK falls now (8049 XTAL)
  input  logic        y101_rise,     // Y101 10 MHz crystal (WD10C20 XTAL) edges
  input  logic        y101_fall,
  // 8049 mask ROM loader (not a card signal)
  input  logic        rom_we,
  input  logic [10:0] rom_addr,
  input  logic [7:0]  rom_data,
  input  logic        reset_n,       // CN9 /RESET
  // CN9 to the 8716
  input  logic [7:0]  bd_in,
  output logic [7:0]  bd_out,
  output logic        bd_oe,
  output logic        pcss_n,
  output logic        pcsd_n,
  input  logic        ireq_n,
  input  logic        est_n,
  output logic        inten,
  output logic        led,
  // track server, [0] drive 0, [1] drive 1
  input  logic [1:0]        img_mounted,
  input  logic              img_readonly,
  input  logic [63:0]       img_size,
  output logic [1:0][31:0]  sd_lba,
  output logic [1:0]        sd_rd,
  output logic [1:0]        sd_wr,
  output logic [1:0]        sd_fmt,        // block is in the drive's format region
  input  logic [1:0]        sd_ack,
  input  logic [8:0]        sd_buff_addr,
  input  logic [7:0]        sd_buff_dout,
  output logic [1:0][7:0]   sd_buff_din,
  input  logic              sd_buff_wr,
  output logic [1:0]        drv_sel,       // the drive select lines
  output logic [1:0][11:0]  drv_bpc,       // blocks per cylinder of each image, 0 unknown
  output logic              late           // a selected drive's data arrived too late
);
  // ---- 8049 (CCCP) ---------------------------------------------------------------
  logic [7:0]  p1, p2, db_out, cbus;
  logic        db_dir, ale, rd_n, wr_n, t0_out, t0_oe, psen_n, prog_n;
  logic        intrq, bcs_n, wd_re_n, wd_we_n, wd_re_oe, wd_we_oe;

  // P1 and P2 are quasi-bidirectional: a pin reads its latch AND what the
  // card drives on it (P1.5 = WD2010 BCS active).  T1 reads High.
  t48_wdc u10_cccp (
    .clk(clk), .xtal_rise(host_clk_rise), .xtal_fall(host_clk_fall), .reset_n(reset_n), .int_n(~intrq),
    .t0_in(~ireq_n), .t0_out(t0_out), .t0_oe(t0_oe), .t1_in(1'b1),
    .db_in(cbus), .db_out(db_out), .db_oe(db_dir),
    .ale(ale), .psen_n(psen_n), .rd_n(rd_n), .wr_n(wr_n), .prog_n(prog_n),
    .p1_in({2'b11, ~bcs_n, 5'h1F} & p1), .p1_out(p1), .p2_in(p2), .p2_out(p2),
    .rom_we(rom_we), .rom_addr(rom_addr), .rom_data(rom_data)
  );

  logic wen;                       // P1.3 WCS- High: U5 and U9 enabled (WEN-)
  assign wen   = p1[3];
  assign inten = ~p1[6];

  // ---- U8 ------------------------------------------------------------------------------
  logic u8_pcss, u8_pcsd, buf_re_n, buf_we_n;
  assign buf_re_n = wd_re_oe ? wd_re_n : 1'b1;
  assign buf_we_n = wd_we_oe ? wd_we_n : 1'b1;

  pal_hdc_u8 u8_pal (
    .clk(clk), .cpuclk(host_clk_rise), .est_n(est_n), .bcs_n(bcs_n), .bufwe_n(buf_we_n), .bufre_n(buf_re_n),
    .wcs_n(wen), .smr_n(p1[7]), .wr_n(wr_n), .rd_n(rd_n), .pcss(u8_pcss), .pcsd(u8_pcsd)
  );

  // U9 group 1 (/G1 = WEN-): the strobes on CN9 18/20, released otherwise.
  assign pcss_n = ~(wen & u8_pcss);
  assign pcsd_n = ~(wen & u8_pcsd);

  // ---- card data bus and U5 --------------------------------------------------------
  logic [7:0] wd_dout;
  logic       wd_doe, to_card;
  assign to_card = wen & (~rd_n | ~buf_re_n);
  assign cbus    = (db_dir ? db_out : 8'hFF) & (wd_doe ? wd_dout : 8'hFF) & (to_card ? bd_in : 8'hFF);
  assign bd_out  = cbus;
  assign bd_oe   = wen & ~to_card;

  // ---- WD2010 + WD10C20 ----------------------------------------------------------------
  logic step, dirin, rwc, wg, rg, wd, early_n, late_n, bcr_n, bdrq, sdhle_n;
  logic rdata, rclk_rise, rclk_fall, drun, wclk_rise, wclk_fall, rmfm, wmfm, drdy, sc, tk000, wf, index;

  // The drive steps once per 50 ns: at each Y101 transition.
  logic step_en;
  assign step_en = y101_rise | y101_fall;

  wd2010 u12_wd2010 (
    .clk(clk),
    .cs_n(wen), .a(p1[2:0]), .re_n_in(rd_n & buf_re_n), .we_n_in(wr_n & buf_we_n),
    .d_in(cbus), .d_out(wd_dout), .d_oe(wd_doe),
    .re_n_out(wd_re_n), .re_oe(wd_re_oe), .we_n_out(wd_we_n), .we_oe(wd_we_oe),
    .mr_n(reset_n), .intrq(intrq), .sdhle_n(sdhle_n),
    .bcs_n(bcs_n), .bcr_n(bcr_n), .brdy(ale), .bdrq(bdrq),
    .wclk_rise(wclk_rise), .wclk_fall(wclk_fall), .rclk_rise(rclk_rise), .rclk_fall(rclk_fall),
    .rd(rdata), .drun(drun), .rg(rg), .wg(wg), .wd(wd),
    .early_n(early_n), .late_n(late_n), .rwc(rwc), .step(step), .dirin(dirin),
    .drdy(drdy), .index(index), .wf(wf), .tk000(tk000), .sc(sc)
  );

  // WPCEN: source untraced; precompensation moves no pulse here either way.
  wd10c20 u101_sep (
    .clk(clk), .xtal_rise(y101_rise), .xtal_fall(y101_fall), .rmfm(rmfm), .wmfm(wmfm),
    .rgate(rg), .bwg(wg), .wdata(wd), .early_n(early_n), .late_n(late_n), .wpcen(1'b0),
    .rdata(rdata), .rclk_rise(rclk_rise), .rclk_fall(rclk_fall), .drun(drun),
    .wclk_rise(wclk_rise), .wclk_fall(wclk_fall)
  );

  // Head select latch: loads the card bus while SDHLE- is Low.
  logic [2:0] hs;
  always_ff @(posedge clk) begin
    if (!rst_n)        hs <= 3'd0;
    else if (!sdhle_n) hs <= cbus[2:0];
  end

  // Drive select from the CCCP: P2.4 Low drive 0, P2.5 Low drive 1.
  logic [1:0] ds;
  assign ds      = ~p2[5:4];
  assign drv_sel = ds;

  // ---- drives and image geometry ---------------------------------------------
  logic [1:0] d_drdy, d_sc, d_tk000, d_wf, d_index, d_rmfm, d_late;
  localparam int NHD = 2;
  genvar k;
  generate for (k = 0; k < NHD; k++) begin : g_drive
    logic        img_busy, img_present, img_ro;
    logic [11:0] img_cyls;
    logic [3:0]  img_heads;
    logic [7:0]  img_spt;
    logic [31:0] img_sectors, probe_lba, drv_lba;
    logic        probe_rd, drv_rd, drv_wr, drv_fmt;

    hd_image u_image (
      .clk(clk), .rst_n(rst_n),
      .img_mounted(img_mounted[k]), .img_readonly(img_readonly), .img_size(img_size),
      .sd_lba(probe_lba), .sd_rd(probe_rd), .sd_ack(sd_ack[k]),
      .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
      .busy(img_busy), .present(img_present), .readonly(img_ro),
      .cyls(img_cyls), .heads(img_heads), .spt(img_spt), .sectors(img_sectors)
    );

    // The drive is mounted when the probe has decided (busy falls), or at
    // once on an eject (no probe).
    logic img_busy_q, drv_mount, eject_q;
    always_ff @(posedge clk) begin
      if (!rst_n) begin
        img_busy_q <= 1'b0;
        eject_q    <= 1'b0;
      end else begin
        img_busy_q <= img_busy;
        eject_q    <= img_mounted[k] && (img_size[63:9] == 55'd0);
      end
    end
    assign drv_mount = (img_busy_q & ~img_busy) | eject_q;

    drive_st506 u_drive (
      .clk(clk), .rst_n(rst_n), .step_en(step_en), .sel(ds[k]), .step(step), .dirin(dirin),
      .head(hs), .wg(wg), .rwc(rwc), .wmfm(wmfm), .rmfm(d_rmfm[k]), .drdy(d_drdy[k]), .sc(d_sc[k]),
      .tk000(d_tk000[k]), .wf(d_wf[k]), .index(d_index[k]),
      .mount(drv_mount), .present(img_present), .readonly(img_ro), .cyls(img_cyls),
      .heads(img_heads), .spt(img_spt), .sectors(img_sectors),
      .sd_lba(drv_lba), .sd_rd(drv_rd), .sd_wr(drv_wr), .sd_fmt(drv_fmt), .sd_ack(sd_ack[k]),
      .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din[k]),
      .sd_buff_wr(sd_buff_wr), .late(d_late[k])
    );

    assign sd_lba[k] = img_busy ? probe_lba : drv_lba;
    assign sd_rd[k]  = img_busy ? probe_rd  : drv_rd;
    assign sd_wr[k]  = ~img_busy & ~img_ro & drv_wr;
    assign sd_fmt[k] = ~img_busy & drv_fmt;
    // 512-byte sectors: a cylinder is heads x spt blocks
    assign drv_bpc[k] = (img_busy || !img_present) ? 12'd0 : 12'(img_heads * img_spt);
  end endgenerate

  assign drdy  = |d_drdy;
  assign sc    = |d_sc;
  assign tk000 = |d_tk000;
  assign wf    = |d_wf;
  assign index = |d_index;
  assign rmfm  = |d_rmfm;
  assign late  = |(d_late & ds);

  assign led = wg | rg;

  logic unused_ok;
  assign unused_ok = &{1'b0, bcr_n, bdrq, p2[7:6], p2[3:0], t0_out, t0_oe, psen_n, prog_n};
endmodule
`default_nettype wire
