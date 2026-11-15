// ps2_mouse_quad driving the HR card's FN#7 (hr_fn7) on a 6 MHz ZCLK,
// against the Go card's port words (mouse_ports.txt, made by
// mouse_ports.go.txt): each line's move is sent as PS/2 reports of at most
// 255 counts, drained, then 0x400 and 0x402 are read.  Every quadrature
// line change is checked to be one Gray step at least STEP_CLKS apart; a
// report while the OSD is open must not move the counters.
`default_nettype none
module tb_mouse;
  localparam int STEP_CLKS = 4800;
  logic clk = 1'b0, rst_n = 1'b0;
  always #1 clk = ~clk;

  logic [24:0] ps2 = '0;
  logic        osd = 1'b0;
  logic        h, hq, v, vq;
  logic [2:0]  b_n;
  ps2_mouse_quad #(.STEP_CLKS(STEP_CLKS)) dut (.clk, .rst_n, .ps2_mouse(ps2), .osd,
    .m_h(h), .m_hq(hq), .m_v(v), .m_vq(vq), .m_b_n(b_n));

  // ZCLK 6 MHz = 8 master clocks.
  logic [2:0] zc = '0;
  always_ff @(posedge clk) zc <= zc + 3'd1;

  logic        io4_n = 1'b1, bds_n = 1'b1, a1 = 1'b0;
  logic [15:0] bad;
  logic        drive, selw_n;
  hr_fn7 fn7 (.clk, .b1_n(b_n[0]), .b2_n(b_n[1]), .b3_n(b_n[2]), .xa(h), .xb(hq), .ya(v), .yb(vq),
    .io4_n, .a4(1'b0), .a2(1'b0), .a1, .zclk(zc[2]), .brw(1'b1), .bds_n, .mc(1'b1),
    .bad, .drive, .selw_n);

  int errors = 0;

  // Quadrature monitor: one line per axis per change, Gray, spaced.
  logic [1:0] lx, ly;
  longint     tx, ty, now;
  initial begin lx = 2'b00; ly = 2'b00; tx = -STEP_CLKS; ty = -STEP_CLKS; now = 0; end
  always_ff @(posedge clk) begin
    now <= now + 1;
    if ({h, hq} != lx) begin
      if (^({h, hq} ^ lx) != 1'b1 || now - tx < STEP_CLKS) begin
        errors <= errors + 1; $display("FAIL X step at %0d: %b -> %b, %0d clocks", now, lx, {h, hq}, now - tx);
      end
      lx <= {h, hq}; tx <= now;
    end
    if ({v, vq} != ly) begin
      if (^({v, vq} ^ ly) != 1'b1 || now - ty < STEP_CLKS) begin
        errors <= errors + 1; $display("FAIL Y step at %0d: %b -> %b, %0d clocks", now, ly, {v, vq}, now - ty);
      end
      ly <= {v, vq}; ty <= now;
    end
  end

  task automatic report(input int dx, input int dy, input logic l, input logic m, input logic r);
    logic [8:0] x9, y9;
    x9 = dx[8:0]; y9 = (-dy);
    @(negedge clk);
    ps2 <= {~ps2[24], y9[7:0], x9[7:0], 2'b00, y9[8], x9[8], 1'b1, m, r, l};
    repeat (4) @(negedge clk);
  endtask

  task automatic move(input int dx, input int dy, input logic l, input logic m, input logic r);
    int cx, cy;
    do begin
      cx = dx > 255 ? 255 : dx < -255 ? -255 : dx;
      cy = dy > 255 ? 255 : dy < -255 ? -255 : dy;
      report(cx, cy, l, m, r);
      dx -= cx; dy -= cy;
    end while (dx != 0 || dy != 0);
  endtask

  task automatic read(input logic y, output logic [15:0] w);
    @(negedge clk); io4_n = 1'b0; bds_n = 1'b0; a1 = y;
    repeat (2) @(negedge clk);
    if (!drive) begin errors++; $display("FAIL port not driven"); end
    w = bad;
    io4_n = 1'b1; bds_n = 1'b1;
  endtask

  int fd, n, dx, dy, l, m, r, ln;
  logic [15:0] ex, ey, gx, gy;
  initial begin
    repeat (20) @(negedge clk);
    rst_n = 1'b1;
    repeat (20) @(negedge clk);
    fd = $fopen("mouse_ports.txt", "r");
    if (fd == 0) $fatal(1, "no mouse_ports.txt");
    ln = 0;
    while ($fscanf(fd, "%d %d %d %d %d %h %h\n", dx, dy, l, m, r, ex, ey) == 7) begin
      ln++;
      move(dx, dy, l[0], m[0], r[0]);
      n = (dx < 0 ? -dx : dx) > (dy < 0 ? -dy : dy) ? (dx < 0 ? -dx : dx) : (dy < 0 ? -dy : dy);
      repeat ((n + 2) * STEP_CLKS) @(negedge clk);
      read(1'b0, gx); read(1'b1, gy);
      if (gx !== ex || gy !== ey) begin
        errors++; $display("FAIL line %0d move %0d,%0d: 0x400 %04x want %04x, 0x402 %04x want %04x",
                           ln, dx, dy, gx, ex, gy, ey);
      end
    end
    $fclose(fd);
    // OSD open: a report is dropped.
    osd = 1'b1;
    report(50, 50, 1'b1, 1'b1, 1'b1);
    osd = 1'b0;
    repeat (60 * STEP_CLKS) @(negedge clk);
    read(1'b0, gx); read(1'b1, gy);
    if (gx !== ex || gy !== ey) begin
      errors++; $display("FAIL OSD report moved the mouse: %04x %04x", gx, gy);
    end
    if (errors) $fatal(1, "tb_mouse FAIL: %0d errors", errors);
    $display("tb_mouse PASS: %0d moves match the Go port words; steps Gray, >= %0d clocks apart", ln, STEP_CLKS);
    $finish;
  end
endmodule
`default_nettype wire
