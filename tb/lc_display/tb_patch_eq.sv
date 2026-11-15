// Unpatched (vdo_top) and patched (vdc_top) 8563 side by side on the same
// clock and bus; every clock compares the pins and counts vsync rises.
`timescale 1ns/1ps
module tb_patch_eq;
  logic clk = 0;
  always #15.625 clk = ~clk;              // 32 MHz
  logic reset = 1, cs = 0, rs = 0, we = 0;
  logic [7:0] db = 0;
  wire  [7:0] do_o, do_n;
  wire        vs_o, hs_o, ce_o, ah_o, av_o, vs_n, hs_n, ce_n, ah_n, av_n;
  wire  [3:0] rgbi_o, rgbi_n;
  wire        m_rd_o, m_we_o, m_rd_n, m_we_n;
  wire [13:0] m_a_o, m_a_n;
  wire  [7:0] m_di_o, m_do_o, m_di_n, m_do_n;

  vdo_top #(.RAM_ADDR_BITS(14)) u_old (.version(1'b0), .ram64k(1'b0), .initRam(1'b0), .debug(1'b0),
    .clk(clk), .enableBus(cs), .reset(reset), .init(1'b0), .cs(cs), .rs(rs), .we(we), .db_in(db),
    .db_out(do_o), .lp_n(1'b1), .vsync(vs_o), .hsync(hs_o), .pixel_ce(ce_o), .active_h(ah_o),
    .active_v(av_o), .rgbi(rgbi_o),
    .mem_rd(m_rd_o), .mem_we(m_we_o), .mem_addr(m_a_o), .mem_di(m_di_o), .mem_do(m_do_o));
  vdcram #(8, 14) u_old_ram (.clk(clk), .rd(m_rd_o), .we(m_we_o), .addr(m_a_o), .dai(m_di_o), .dao(m_do_o));
  vdc_top #(.RAM_ADDR_BITS(14)) u_new (.version(1'b0), .ram64k(1'b0), .initRam(1'b0), .debug(1'b0),
    .clk(clk), .enableBus(cs), .reset(reset), .init(1'b0), .cs(cs), .rs(rs), .we(we), .db_in(db),
    .db_out(do_n), .lp_n(1'b1), .vsync(vs_n), .hsync(hs_n), .pixel_ce(ce_n), .active_h(ah_n),
    .active_v(av_n), .rgbi(rgbi_n),
    .mem_rd(m_rd_n), .mem_we(m_we_n), .mem_addr(m_a_n), .mem_di(m_di_n), .mem_do(m_do_n));
  vdcram #(8, 14) u_new_ram (.clk(clk), .rd(m_rd_n), .we(m_we_n), .addr(m_a_n), .dai(m_di_n), .dao(m_do_n));

  longint cyc = 0, diffs = 0, vsr = 0, hsr = 0, pix = 0, lit = 0;
  logic vs_q = 0, hs_q = 0;
  int fd;
  string vsfile;
  always @(posedge clk) begin
    cyc <= cyc + 1;
    if ({vs_o, hs_o, ce_o, ah_o, av_o, rgbi_o, do_o} !== {vs_n, hs_n, ce_n, ah_n, av_n, rgbi_n, do_n}) begin
      if (diffs < 20) $display("DIFF cyc %0d old vs%b hs%b ce%b ah%b av%b rgbi%h db%h new vs%b hs%b ce%b ah%b av%b rgbi%h db%h",
        cyc, vs_o, hs_o, ce_o, ah_o, av_o, rgbi_o, do_o, vs_n, hs_n, ce_n, ah_n, av_n, rgbi_n, do_n);
      diffs <= diffs + 1;
    end
    vs_q <= vs_o; hs_q <= hs_o;
    if (vs_o && !vs_q) begin vsr <= vsr + 1; $fdisplay(fd, "vsync rise cyc %0d (old vs%b new vs%b)", cyc, vs_o, vs_n); end
    if (hs_o && !hs_q) hsr <= hsr + 1;
    if (ce_o) pix <= pix + 1;
    if (ce_o && rgbi_o != 0) lit <= lit + 1;
  end

  task automatic wr(input logic [5:0] r, input logic [7:0] v);
    @(negedge clk) begin cs = 1; rs = 0; we = 1; db = {2'b00, r}; end
    @(negedge clk) cs = 0;
    repeat (3) @(negedge clk);
    @(negedge clk) begin cs = 1; rs = 1; we = 1; db = v; end
    @(negedge clk) cs = 0;
    repeat (40) @(negedge clk);
  endtask

  logic [7:0] ntsc [0:36];
  int seed, frames;
  initial begin
    ntsc = '{8'h7E, 8'h50, 8'h66, 8'h49, 8'h20, 8'h00, 8'h19, 8'h1D, 8'h00, 8'h07,
             8'h20, 8'h07, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
             8'h08, 8'h00, 8'h78, 8'h08, 8'h20, 8'h47, 8'hF0, 8'h00, 8'h10, 8'h07,
             8'h00, 8'h00, 8'h00, 8'h00, 8'h7D, 8'h64, 8'h05};
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("frames=%d", frames)) frames = 4;
    if (!$value$plusargs("vsfile=%s", vsfile)) vsfile = "obj_dir/eq_vsync.txt";
    fd = $fopen(vsfile, "w");
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (8) @(negedge clk);
    for (int r = 0; r <= 36; r++) if (r != 31 && !(r >= 16 && r <= 19)) wr(6'(r), ntsc[r]);
    if ($test$plusargs("im")) wr(6'd8, 8'h03);          // interlace sync and video
    if ($test$plusargs("ims")) wr(6'd8, 8'h01);         // interlace sync
    // screen text and attributes
    wr(6'd18, 8'h00); wr(6'd19, 8'h00);
    for (int i = 0; i < 160; i++) wr(6'd31, 8'(i * 7 + 3));
    wr(6'd18, 8'h08); wr(6'd19, 8'h00);
    for (int i = 0; i < 160; i++) wr(6'd31, 8'(i + 1));
    // static frames
    repeat (frames * 532000) @(negedge clk);
    $display("static: cyc %0d vsync rises %0d hsync rises %0d diffs %0d", cyc, vsr, hsr, diffs);
    if ($test$plusargs("rw")) begin
      // R0 / R2 writes at random times, then a frame on each new value
      int unsigned r;
      for (int k = 0; k < 24; k++) begin
        r = $urandom(seed + k);
        repeat (r % 400000) @(negedge clk);
        case (k % 6)
          0: wr(6'd0, 8'h7F);
          1: wr(6'd2, 8'(8'h50 + r[11:8]));
          2: wr(6'd0, 8'(8'h70 + r[13:10]));
          3: wr(6'd2, 8'h00);                          // sync position = R0
          4: wr(6'd0, 8'(r[7:0] | 8'h03));             // any R0, wraps the modulo
          5: wr(6'd2, 8'(r[15:8]));                    // any R2, may exceed R0
        endcase
        if (k % 6 == 5) begin wr(6'd0, 8'h7E); wr(6'd2, 8'h66); end
      end
      repeat (2 * 532000) @(negedge clk);
      $display("writes: cyc %0d vsync rises %0d hsync rises %0d diffs %0d", cyc, vsr, hsr, diffs);
    end
    $display("RESULT cyc %0d vsync rises %0d hsync rises %0d pixels %0d lit %0d diffs %0d",
             cyc, vsr, hsr, pix, lit, diffs);
    $fclose(fd);
    if (diffs != 0) $fatal(1, "FAIL: %0d clocks differ", diffs);
    $display("PASS tb_patch_eq");
    $finish;
  end
endmodule
