// LR card bench: a behavioural Z-Bus master programs the 6845 with the
// boot ROM table (BIOS 00:434a), clears the CDR the way the BIOS does
// (word 0x0720 per cidx), writes text, reads it back, and the bench then
// captures two frames at ce_pix and checks:
//   [1] H period 882 dots (98 x 9), V period 370 lines, DE 720 x 350
//   [2] every displayed pixel against a reference built from the
//       character ROM and the U22 closed forms plus the 6845 cursor (R10/R11 from the table)
//   [3] /WAIT: every CDR access waits for the CPU slot, never longer
//       than one character + the crossing; the array access lands
//       between dots 4 and 7, away from the CRTC fetch at dot 8
//   [4] lane rules: word read = {attr, char}; a byte write at an even
//       address lands in the character SRAM
//   [5] CRTC R14/R15 read back through the data port
// +crom=<path> names the 4 KB character ROM dump.
`timescale 1ps/1ps
`default_nettype none
module tb_lr_card;
  localparam int HALF_SYS = 10417;   // 48 MHz
  localparam int HALF_VID = 7689;    // 65.028 MHz = 4 x 16.257 MHz

  logic clk = 1'b0, clk_vid = 1'b0, rst_n = 1'b0;
  always #(HALF_SYS) clk = ~clk;
  always #(HALF_VID) clk_vid = ~clk_vid;

  // ---- Z-Bus master -------------------------------------------------------------------
  logic        rom_we = 1'b0;
  logic [11:0] rom_addr = 12'h000;
  logic [7:0]  rom_data = 8'h00;
  logic        zclk = 1'b0;
  logic [15:0] ad_bus, mst_ad = 16'hFFFF, card_ad_out, card_ad_oe;
  logic        mst_oe = 1'b0;
  logic [23:0] pa = 24'hFFFFFF;
  logic        as_n = 1'b1, ds_n = 1'b1, mreq_n = 1'b1, r_w = 1'b1, b_w = 1'b0;
  logic        io_cyc = 1'b0;
  logic [7:0]  port_q = 8'h00;
  logic        io3_n, io4_n, wait_n, wait_nx, vi_n, ieo;
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
    .rom_we(rom_we), .rom_addr(rom_addr), .rom_data(rom_data),
    .clk_pin_rise(zclk_fall), .clk_pin_fall(zclk_rise), .ad_bus(ad_bus), .pa(pa), .as_n(as_n), .ds_n(ds_n), .mreq_n(mreq_n),
    .r_w(r_w), .b_w(b_w), .io3_n(io3_n), .io4_n(io4_n), .sup_n(1'b1),
    .intack_n(1'b1), .iei(1'b1),
    .ad_out(card_ad_out), .ad_oe(card_ad_oe), .wait_n(wait_n), .wait_nx(wait_nx), .vi_n(vi_n), .ieo(ieo),
    .scc_rxd(4'hF), .scc_cts_n(4'hF), .scc_dcd_n(4'hF), .scc_dsr_n(4'hF),
    .scc_txd(scc_txd), .scc_rts_n(scc_rts_n), .scc_dtr_n(scc_dtr_n),
    .ce_pix(ce_pix), .hsync(hsync), .vsync(vsync), .de(de), .hblank(hblank),
    .vblank(vblank), .vid(vid), .intens(intens)
  );

  int errors = 0;
  int wait_max = 0, wait_min = 1000, waits_seen = 0, accesses = 0;

  task automatic fail(input string msg);
    if (errors < 20) $display("FAIL: %s", msg);
    errors++;
  endtask

  // wait_nx: each /WAIT clock after the first as it said one clock before.
  logic wait_q = 1'b1, wait_nx_q = 1'b1;
  always @(posedge clk) begin
    if (!wait_q && wait_n !== wait_nx_q) fail("wait_nx");
    wait_q    <= wait_n;
    wait_nx_q <= wait_nx;
  end

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

  // Memory cycle to the CDR (segment 0x37).  Holds /DS while /WAIT is Low.
  task automatic mem_cycle(input logic wr, input logic byte_op, input logic [11:0] off,
                           input logic [15:0] wdata, output logic [15:0] rdata);
    int n;
    @(posedge clk);
    pa <= {12'h370, off}; mst_ad <= {4'h0, off}; mst_oe <= 1'b1;
    r_w <= ~wr; b_w <= byte_op; as_n <= 1'b0; mreq_n <= 1'b0;
    repeat (4) @(posedge clk);
    as_n <= 1'b1;
    repeat (2) @(posedge clk);
    if (wr) mst_ad <= wdata;
    else    mst_oe <= 1'b0;
    repeat (2) @(posedge clk);
    ds_n <= 1'b0;
    @(posedge clk);
    n = 0;
    while (!wait_n) begin
      n++;
      @(posedge clk);
      if (n > 200) begin
        fail("/WAIT stuck");
        break;
      end
    end
    accesses++;
    if (n > 0) waits_seen++;
    if (n > wait_max) wait_max = n;
    if (n < wait_min) wait_min = n;
    repeat (8) @(posedge clk);
    rdata = ad_bus;
    ds_n <= 1'b1;
    repeat (2) @(posedge clk);
    mreq_n <= 1'b1; mst_oe <= 1'b0; r_w <= 1'b1;
    repeat (6) @(posedge clk);
  endtask

  // [3] the array access must not land on the fetch dot.
  always @(posedge clk) begin
    if (rst_n && dut.u5_u6.access && (dut.u24_q == 4'd8 || dut.u24_q < 4'd3))
      fail($sformatf("CPU VRAM access at dot %0d", dut.u24_q));
  end

  // ---- reference -------------------------------------------------------------------------
  logic [7:0] crom [0:4095];
  logic [7:0] ref_chr [0:1999];
  logic [7:0] ref_atr [0:1999];

  function automatic logic u22_vid(input logic [7:0] a, input logic ul, input logic enbl);
    logic b0, b1, b2, b5, b6, b7;
    {b7, b6, b5} = a[7:5];
    {b2, b1, b0} = a[2:0];
    if (!ul) return b0 & (!b6 | (b7 & !enbl));
    return b0 & ((!b6 & b1) | (b6 & b5 & !b1) | (b5 & !b1 & b2) | (!enbl & b7 & (b1 | !b5)));
  endfunction

  function automatic logic u22_blank(input logic [7:0] a, input logic ul, input logic enbl);
    logic b0, b1, b2, b5, b7;
    b0 = a[0]; b1 = a[1]; b2 = a[2]; b5 = a[5]; b7 = a[7];
    if (!ul) return b0 & b7 & !enbl;
    return b0 & ((b5 & !b1 & b2) | (!enbl & b7 & (!b5 | b1)));
  endfunction

  // Cursor from the table: R10 = 0x0B (steady, start 11), R11 = 0x0C,
  // R14/R15 = 0 -> cidx 0.
  function automatic logic ref_pixel(input int x, input int y, input logic enbl);
    int col, row, scan, dot, cidx;
    logic [7:0] a, c, rb;
    logic g, v, bl, cur;
    col = x / 9; dot = x % 9; row = y / 14; scan = y % 14;
    cidx = row * 80 + col;
    a = ref_atr[cidx]; c = ref_chr[cidx];
    rb = crom[{c, scan[3:0]}];
    bl = u22_blank(a, scan == 12, enbl);
    v  = u22_vid(a, scan == 12, enbl);
    cur = (cidx == 0) && scan >= 11 && scan <= 12;
    if (bl) rb = 8'h00;
    if (dot < 8) g = rb[7 - dot];
    else         g = (c[7:5] == 3'b110) && rb[0];
    return cur | (g ^ ~v);
  endfunction

  // ---- capture -------------------------------------------------------------------------
  logic        fb [0:349][0:719];
  int          vid_cyc = 0, hs_last = -1, vs_last = -1, hper = 0, vper = 0;
  int          x = 0, y = -1, de_w = 0, de_lines = 0, frames = 0;
  logic        hs_q = 1'b0, vs_q = 1'b0, de_q = 1'b0, capturing = 1'b0;
  logic        cpu_done = 1'b0, cap_started = 1'b0, cap_done = 1'b0;
  logic        enbl_cap;

  always @(posedge clk_vid) begin
    vid_cyc++;
    if (ce_pix) begin
      if (hsync && !hs_q) begin
        if (hs_last >= 0) hper = vid_cyc - hs_last;
        hs_last = vid_cyc;
      end
      if (vsync && !vs_q) begin
        if (vs_last >= 0) vper = vid_cyc - vs_last;
        if ($test$plusargs("vper")) $display("vsync %0d at %0d period %0d", frames, vid_cyc, vper);
        vs_last = vid_cyc;
        frames++;
        if (capturing) begin
          capturing = 1'b0;
          cap_done  = 1'b1;
          if (de_lines != 350) fail($sformatf("DE lines %0d, want 350", de_lines));
        end
        if (cpu_done && !cap_started) begin
          capturing   = 1'b1;
          cap_started = 1'b1;
          enbl_cap  = ~dut.u_pix.fld_q[4];
        end
        y = -1; de_lines = 0;
      end
      if (de && !de_q) begin
        y++; x = 0; de_w = 0;
      end
      if (de) begin
        if (capturing && y >= 0 && y < 350 && x < 720) fb[y][x] = vid;
        x++; de_w++;
      end
      if (!de && de_q) begin
        de_lines++;
        if (de_w != 720) fail($sformatf("DE width %0d, want 720", de_w));
      end
      if (de != ~(hblank | vblank)) fail("DE != ~(HBlank|VBlank)");
      hs_q = hsync; vs_q = vsync; de_q = de;
    end
  end

  // ---- stimulus ------------------------------------------------------------------------
  // BIOS table at 00:434a: register, value pairs.
  logic [7:0] crtc_tab [0:31] = '{
    8'h00, 8'h61, 8'h01, 8'h50, 8'h02, 8'h52, 8'h03, 8'h0f,
    8'h04, 8'h19, 8'h05, 8'h06, 8'h06, 8'h19, 8'h07, 8'h19,
    8'h08, 8'h02, 8'h09, 8'h0d, 8'h0a, 8'h0b, 8'h0b, 8'h0c,
    8'h0c, 8'h00, 8'h0d, 8'h00, 8'h0e, 8'h00, 8'h0f, 8'h00};

  string path;
  string msg = "COMMODORE 900 LR CARD: TEXT FROM THE 2532 CHARACTER ROM";
  initial begin
    int fd, n;
    logic [15:0] rd;
    logic [7:0]  b;
    if (!$value$plusargs("crom=%s", path)) $fatal(1, "need +crom=<char ROM dump>");
    fd = $fopen(path, "rb");
    if (fd == 0) $fatal(1, "cannot open %s", path);
    n = $fread(crom, fd);
    $fclose(fd);
    if (n != 4096) $fatal(1, "char ROM is %0d bytes", n);

    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (10) @(posedge clk);

    for (int k = 0; k < 4096; k++) begin
      @(posedge clk);
      rom_we <= 1'b1; rom_addr <= k[11:0]; rom_data <= crom[k];
    end
    @(posedge clk) rom_we <= 1'b0;

    for (int k = 0; k < 16; k++) begin
      io_write(16'h0410, crtc_tab[2*k]);
      io_write(16'h0412, crtc_tab[2*k+1]);
    end
    io_write(16'h0418, 8'h28);

    // [5] R14/R15 read back (R15 = 0x00 from the table; set 0x00 again).
    io_write(16'h0410, 8'h0f);
    io_read(16'h0412, b);
    if (b !== 8'h00) fail($sformatf("R15 read %02h, want 00", b));

    // Clear: 0x0720 in every cidx (BIOS LDIR).
    for (int k = 0; k < 2000; k++) begin
      mem_cycle(1'b1, 1'b0, 12'(2 * k), 16'h0720, rd);
      ref_atr[k] = 8'h07; ref_chr[k] = 8'h20;
    end
    // Text on row 1 by word writes.
    for (int k = 0; k < msg.len(); k++) begin
      mem_cycle(1'b1, 1'b0, 12'(2 * (80 + k)), {8'h07, msg[k]}, rd);
      ref_chr[80 + k] = msg[k];
    end
    // [4] byte write at the EVEN (attribute) address lands in the char SRAM.
    mem_cycle(1'b1, 1'b1, 12'(2 * 162), 16'h4141, rd);
    ref_chr[162] = 8'h41;
    // Reverse video (0x70), box drawing (0xC4 9th dot), blink-free intense.
    mem_cycle(1'b1, 1'b0, 12'(2 * 164), 16'h7042, rd);
    ref_atr[164] = 8'h70; ref_chr[164] = 8'h42;
    mem_cycle(1'b1, 1'b0, 12'(2 * 165), 16'h07C4, rd);
    ref_chr[165] = 8'hC4;
    mem_cycle(1'b1, 1'b0, 12'(2 * 166), 16'h0FC4, rd);
    ref_atr[166] = 8'h0F; ref_chr[166] = 8'hC4;
    // All 256 codes on rows 4..7.
    for (int k = 0; k < 256; k++) begin
      mem_cycle(1'b1, 1'b0, 12'(2 * (320 + k)), {8'h07, k[7:0]}, rd);
      ref_chr[320 + k] = k[7:0];
    end

    // [4] read back: word = {attr, char}.
    mem_cycle(1'b0, 1'b0, 12'(2 * 162), 16'h0000, rd);
    if (rd !== 16'h0741) fail($sformatf("cidx 162 read %04h, want 0741", rd));
    mem_cycle(1'b0, 1'b0, 12'(2 * 81), 16'h0000, rd);
    if (rd !== {8'h07, msg[1]}) fail($sformatf("cidx 81 read %04h", rd));
    mem_cycle(1'b0, 1'b1, 12'(2 * 164 + 1), 16'h0000, rd);
    if (rd[7:0] !== 8'h42) fail($sformatf("byte read odd %02h, want 42", rd[7:0]));
    mem_cycle(1'b0, 1'b1, 12'(2 * 164), 16'h0000, rd);
    if (rd[15:8] !== 8'h70) fail($sformatf("byte read even %02h, want 70", rd[15:8]));

    // [3] /WAIT bounds: one character = 36 clk_vid = 553 ns = 26.6 clk;
    // plus two to three clk of synchroniser.
    if (waits_seen == 0) fail("no CDR access ever waited");
    if (wait_max > 31) fail($sformatf("/WAIT max %0d clk", wait_max));
    $display("CDR accesses %0d, waited %0d, /WAIT min %0d max %0d clk (48 MHz)",
             accesses, waits_seen, wait_min, wait_max);

    // Capture the first frame that starts after the writes.
    cpu_done = 1'b1;
    wait (cap_done);

    // [1] timing
    if (hper != 882 * 4) fail($sformatf("H period %0d clk_vid, want %0d", hper, 882 * 4));
    if (vper != 882 * 4 * 370) fail($sformatf("V period %0d clk_vid, want %0d", vper, 882 * 4 * 370));
    $display("H: %0d dots/line -> %.3f Hz; V: %0d lines -> %.4f Hz (at 16.257 MHz)",
             hper / 4, 16257000.0 / (hper / 4), vper / hper, 16257000.0 / (vper / 4));

    // [2] pixels
    n = 0;
    for (int yy = 0; yy < 350; yy++)
      for (int xx = 0; xx < 720; xx++)
        if (fb[yy][xx] !== ref_pixel(xx, yy, enbl_cap)) begin
          if (n < 10) $display("pixel (%0d,%0d) got %b want %b", xx, yy, fb[yy][xx],
                               ref_pixel(xx, yy, enbl_cap));
          n++;
        end
    if (n != 0) fail($sformatf("%0d pixels differ", n));

    // ASCII art of text row 1 (first 40 columns) for the log.
    for (int yy = 14; yy < 28; yy++) begin
      string s = "";
      for (int xx = 0; xx < 360; xx++) s = {s, fb[yy][xx] ? "#" : "."};
      $display("%s", s);
    end

    if (errors != 0) $fatal(1, "tb_lr_card: %0d failures", errors);
    $display("tb_lr_card: PASS");
    $finish;
  end

  initial begin
    #(64'd200_000_000_000);
    $fatal(1, "timeout");
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, vi_n, ieo, scc_txd, scc_rts_n, scc_dtr_n, intens};
endmodule
`default_nettype wire
