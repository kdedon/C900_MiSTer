// LR card SCC bench: U31 and U36 on a behavioural
// Z-Bus master at the C900 6 MHz ZCLK.
//   [1] U36: WR2 written at 0x03A5 reads back; U31's WR2 (0x0325)
//       is a separate register
//   [2] U36 channel A programmed as the BIOS programs its console (WR4 4C,
//       WR11 56, TC 17 from PCLK, WR14 03, WR3 C1, WR5 EA); a byte written
//       to 0x03B1 leaves TxD (scc_txd[2]) as start, 8 data bits LSB first,
//       stop, at 2 x (17 + 2) x 16 PCLKs per bit; U31's TxD stays idle
//       (TxD is checked after the power-up /AS + /DS reset)
`timescale 1ps/1ps
`default_nettype none
module tb_lr_scc;
  localparam int HALF_SYS = 10417;   // 48 MHz
  localparam int HALF_VID = 7689;
  localparam int BIT_CLKS = 2 * (17 + 2) * 16 * 8;   // PCLK = 8 master clocks

  logic clk = 1'b0, clk_vid = 1'b0, rst_n = 1'b0;
  always #(HALF_SYS) clk = ~clk;
  always #(HALF_VID) clk_vid = ~clk_vid;

  logic        zclk = 1'b0;
  logic [15:0] ad_bus, mst_ad = 16'hFFFF, card_ad_out, card_ad_oe;
  logic        mst_oe = 1'b0;
  logic [23:0] pa = 24'hFFFFFF;
  logic        as_n = 1'b1, ds_n = 1'b1, r_w = 1'b1, b_w = 1'b0;
  logic        io_cyc = 1'b0;
  logic [7:0]  port_q = 8'h00;
  logic        io3_n, io4_n, wait_n, vi_n, ieo;
  logic [3:0]  scc_txd, scc_rts_n, scc_dtr_n;
  logic        ce_pix, hsync, vsync, de, hblank, vblank, vid, intens;

  assign io3_n = ~(io_cyc && port_q == 8'h03);
  assign io4_n = ~(io_cyc && port_q == 8'h04);

  logic [15:0] ad_wire;
  assign ad_wire = (mst_oe ? mst_ad : 16'hFFFF) & (card_ad_oe & card_ad_out | ~card_ad_oe);
  always_ff @(posedge clk) ad_bus <= ad_wire;

  int zdiv = 0;
  logic zclk_rise = 1'b0, zclk_fall = 1'b0;
  always @(posedge clk) begin
    zdiv <= (zdiv + 1) % 4;
    if (zdiv == 3) zclk <= ~zclk;
    zclk_rise <= (zdiv == 3) && !zclk;
    zclk_fall <= (zdiv == 3) && zclk;
  end

  c900_lr_card #(.CLKS_PER_DOT(4)) dut (
    .clk(clk), .rst_n(rst_n), .mreset_n(1'b1), .clk_vid(clk_vid),
    .rom_we(1'b0), .rom_addr(12'h000), .rom_data(8'h00),
    .clk_pin_rise(zclk_fall), .clk_pin_fall(zclk_rise), .ad_bus(ad_bus), .pa(pa), .as_n(as_n), .ds_n(ds_n), .mreq_n(1'b1),
    .r_w(r_w), .b_w(b_w), .io3_n(io3_n), .io4_n(io4_n), .sup_n(1'b1),
    .intack_n(1'b1), .iei(1'b1),
    .ad_out(card_ad_out), .ad_oe(card_ad_oe), .wait_n(wait_n), .vi_n(vi_n), .ieo(ieo),
    .scc_rxd(4'hF), .scc_cts_n(4'hF), .scc_dcd_n(4'hF), .scc_dsr_n(4'hF),
    .scc_txd(scc_txd), .scc_rts_n(scc_rts_n), .scc_dtr_n(scc_dtr_n),
    .ce_pix(ce_pix), .hsync(hsync), .vsync(vsync), .de(de), .hblank(hblank),
    .vblank(vblank), .vid(vid), .intens(intens)
  );

  int errors = 0;

  task automatic fail(input string msg);
    if (errors < 20) $display("FAIL: %s", msg);
    errors++;
  endtask

  task automatic io_write(input logic [15:0] port, input logic [7:0] data);
    @(posedge clk);
    port_q <= port[15:8]; io_cyc <= 1'b1; pa <= {14'h3FFF, port[9:0]};
    mst_ad <= port; mst_oe <= 1'b1; r_w <= 1'b0; b_w <= 1'b1; as_n <= 1'b0;
    repeat (4) @(posedge clk);
    as_n <= 1'b1;
    repeat (2) @(posedge clk);
    mst_ad <= {data, data};
    repeat (2) @(posedge clk);
    ds_n <= 1'b0;
    repeat (16) @(posedge clk);
    if (!wait_n) fail("/WAIT on an I/O cycle");
    ds_n <= 1'b1;
    repeat (2) @(posedge clk);
    mst_oe <= 1'b0; io_cyc <= 1'b0; r_w <= 1'b1;
    repeat (8) @(posedge clk);
  endtask

  task automatic io_read(input logic [15:0] port, output logic [7:0] data);
    @(posedge clk);
    port_q <= port[15:8]; io_cyc <= 1'b1; pa <= {14'h3FFF, port[9:0]};
    mst_ad <= port; mst_oe <= 1'b1; r_w <= 1'b1; b_w <= 1'b1; as_n <= 1'b0;
    repeat (4) @(posedge clk);
    as_n <= 1'b1;
    repeat (2) @(posedge clk);
    mst_oe <= 1'b0;
    repeat (2) @(posedge clk);
    ds_n <= 1'b0;
    repeat (16) @(posedge clk);
    data = ad_bus[7:0];                        // byte I/O on AD7:0
    ds_n <= 1'b1;
    io_cyc <= 1'b0;
    repeat (8) @(posedge clk);
  endtask


  // Hardware reset of both SCCs: /AS and /DS Low together, as the board does.
  task automatic scc_reset();
    @(posedge clk); as_n <= 1'b0; ds_n <= 1'b0;
    repeat (40) @(posedge clk);
    as_n <= 1'b1; ds_n <= 1'b1;
    repeat (40) @(posedge clk);
  endtask

  // BIOS console set-up (contab) on the channel at base (ch A = base 0x20).
  task automatic scc_console(input logic [15:0] base);
    logic [7:0] tab [0:23];
    tab = '{8'h09, 8'hC0, 8'h04, 8'h4C, 8'h05, 8'h14, 8'h03, 8'hC0, 8'h0B, 8'h56,
            8'h0C, 8'h11, 8'h0D, 8'h00, 8'h0E, 8'h02, 8'h0E, 8'h03, 8'h03, 8'hC1,
            8'h05, 8'hEA, 8'h01, 8'h00};
    for (int k = 0; k < 24; k += 2) io_write(base | 16'(tab[k]) << 1 | 16'h1, tab[k+1]);
  endtask

  // Receive one frame on txd[ch]: start bit, 8 data bits, stop bit.
  task automatic rx_byte(input int ch, output logic [7:0] b, output logic ok);
    int t = 0;
    ok = 1'b0; b = 8'h00;
    while (scc_txd[ch] && t < 40 * BIT_CLKS) begin @(posedge clk); t++; end
    if (scc_txd[ch]) return;
    repeat (BIT_CLKS / 2) @(posedge clk);
    if (scc_txd[ch]) return;
    for (int i = 0; i < 8; i++) begin
      repeat (BIT_CLKS) @(posedge clk);
      b[i] = scc_txd[ch];
    end
    repeat (BIT_CLKS) @(posedge clk);
    ok = scc_txd[ch];
  endtask

  // TxD edges on the other channels.
  int other_edges = 0;
  logic watch = 1'b0;
  logic [3:0] txd_q = 4'hF;
  always @(posedge clk) begin
    txd_q <= scc_txd;
    if (watch && ((txd_q ^ scc_txd) & 4'b1011) != 4'b0000) begin
      other_edges <= other_edges + 1;
    end
  end

  initial begin
    logic [7:0] b;
    logic ok;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (10) @(posedge clk);
    scc_reset();
    watch = 1'b1;

    // [1] registers
    io_write(16'h03A5, 8'h5A);
    io_write(16'h0325, 8'hA6);
    io_read(16'h03A5, b);
    if (b !== 8'h5A) fail($sformatf("[1] U36 WR2 read %02x, want 5A", b));
    io_read(16'h0325, b);
    if (b !== 8'hA6) fail($sformatf("[1] U31 WR2 read %02x, want A6", b));

    // [2] a TX byte on U36 channel A
    scc_console(16'h03A0);
    io_write(16'h03B1, 8'hC5);
    rx_byte(2, b, ok);
    if (!ok || b !== 8'hC5) fail($sformatf("[2] U36 A TxD frame %02x ok=%b, want C5", b, ok));
    if (other_edges != 0) fail($sformatf("[2] %0d TxD edges on other channels", other_edges));
    if (!vi_n) fail("[2] /VI Low with interrupts disabled");

    if (errors) $fatal(1, "tb_lr_scc: FAIL (%0d)", errors);
    $display("tb_lr_scc: PASS");
    $finish;
  end
endmodule
`default_nettype wire
