// LC card throughput: the wb900 lcbench loops replayed as Z8000 bus
// cycles with their instruction clocks, display on and mostly blanked
// (R1 8, R6 2).  Prints ns and CPU clocks per operation, busy polls, and
// the 8568's busy time per access.
//   +tc=N   CPU clock = 48 MHz / N (8: 6 MHz, 1: 48 MHz)
//   +zio    I/O cycles at the 6 MHz ZCLK edges, as the turbo CPU runs them
//   +probe  free CPU columns per line over a frame, then stop
// Each case starts its passes at evenly spaced points of the frame.
`timescale 1ns/1fs
module tb_lc_perf;
  localparam logic [3:0] ST_IO = 4'b0010, ST_INT = 4'b0000;
  localparam real T_EDGE = 1000.0 / 192.0;
  logic clk = 1'b0, clk_vdc = 1'b0;
  int   edge_n = 0;
  always #(T_EDGE) begin
    edge_n = (edge_n + 1) % 12;
    if (edge_n % 2 == 1) clk = !clk;
    if (edge_n % 3 == 0) clk_vdc = !clk_vdc;
  end

  logic        rst_n = 1'b0, mreset_n = 1'b0;
  logic [15:0] ad_bus = 16'hFFFF;
  logic        as_n = 1'b1, ds_n = 1'b1, r_w = 1'b1, b_w = 1'b1;
  logic [3:0]  st = ST_INT;
  logic [15:0] ad_out, ad_oe;
  logic        wait_n, wait_nx, nvi_n;
  logic [3:0]  rgbi;
  logic        hsync, vsync, pixel_ce, active_h, active_v;
  logic        ram_rd, ram_we;
  logic [15:0] ram_addr;
  logic [7:0]  ram_di, ram_do;
  c900_lc_card dut (.*);
  logic [63:0] hr_q;
  c900_dispram u_ram (
    .clk(clk), .lc_sel(1'b1),
    .hr_wrow(14'h0), .hr_we(8'h00), .hr_wd(64'h0), .hr_rrow(14'h0), .hr_q(hr_q),
    .lc_rd(ram_rd), .lc_we(ram_we), .lc_addr(ram_addr), .lc_di(ram_di), .lc_do(ram_do)
  );

  int tc = 8, ctc = 8;
  bit zio = 0;
  int zph = 0;
  always @(posedge clk) zph <= (zph + 1) % 8;
  task automatic clocks(input int n);
    repeat (n * tc) @(posedge clk);
  endtask

  // One I/O instruction of n clocks: n-4 internal, then T1 (/AS), T2 and
  // the automatic wait TWA with /DS low, wait states while /WAIT is low,
  // T3 (/DS rises halfway).
  task automatic io(input logic wr, input logic [15:0] a, input logic [7:0] d,
                    output logic [7:0] q, input int n);
    clocks(n - 4);
    if (zio) begin
      ctc = tc; tc = 8;
      while (zph != 7) @(posedge clk);
      @(posedge clk);
    end
    #1 st = ST_IO; r_w = !wr; as_n = 1'b0; ad_bus = a;
    repeat ((tc + 1) / 2) @(posedge clk);
    #1 as_n = 1'b1;
    repeat (tc - (tc + 1) / 2) @(posedge clk);
    #1 ds_n = 1'b0; ad_bus = wr ? {d, d} : 16'hFFFF;
    repeat (2 * tc) @(posedge clk);
    #1 while (!wait_n) begin repeat (tc) @(posedge clk); #1; end
    q = ad_oe[0] ? ad_out[7:0] : 8'hFF;
    repeat ((tc + 1) / 2) @(posedge clk);
    #1 ds_n = 1'b1;
    repeat (tc - (tc + 1) / 2) @(posedge clk);
    #1 st = ST_INT; ad_bus = 16'hFFFF;
    if (zio) tc = ctc;
  endtask

  logic [7:0] q;
  int busy_polls = 0;
  task automatic sel(input logic [7:0] r, input int n = 10); io(1, 16'h0181, r, q, n); endtask
  task automatic dat(input logic [7:0] v, input int n = 10); io(1, 16'h0183, v, q, n); endtask
  // calr rdy: calr 15, then inb 10, bitb 4 and ret nz 13, or inc 4, jr 6.
  task automatic rdy();
    clocks(15);
    forever begin
      io(0, 16'h0181, 8'h00, q, 10);
      clocks(4);
      if (q[7]) begin clocks(13); break; end
      busy_polls++;
      clocks(10);
    end
  endtask
  task automatic wr(input logic [5:0] r, input logic [7:0] v);
    sel({2'b00, r}); rdy(); dat(v);
  endtask
  task automatic seek(input logic [15:0] a); wr(18, a[15:8]); wr(19, a[7:0]); endtask

  // The 8568 side: busy clk_vdc cycles and CPU RAM slots.
  int busy_cyc = 0, cpu_slots = 0, nvi_falls = 0, run = 0, run_max = 0, long_runs = 0;
  logic nvi_q = 1'b1;
  always @(posedge clk_vdc) begin
    if (dut.u_8568.busy) begin busy_cyc++; run++; end
    else if (run > 0) begin
      if (run > run_max) run_max = run;
      if (run > 320) long_runs++;
      run = 0;
    end
    if (dut.u_8568.u_vdc.enable && dut.u_8568.u_vdc.endCol &&
        dut.u_8568.u_vdc.ram.ramAction == 3'd4) cpu_slots++;
    nvi_q <= nvi_n;
    if (nvi_q && !nvi_n) nvi_falls++;
  end

  // Idle columns per line over a frame.
  bit probe_on = 0;
  int idle = 0, hist[int], nlines = 0, tot = 0;
  logic hs_q = 1'b0;
  always @(posedge clk_vdc) begin
    hs_q <= hsync;
    if (dut.u_8568.u_vdc.enable && dut.u_8568.u_vdc.endCol &&
        dut.u_8568.u_vdc.ram.ramAction == 3'd0) idle++;
    if (hsync && !hs_q) begin
      if (probe_on) begin
        if (hist.exists(idle)) hist[idle]++; else hist[idle] = 1;
        nlines++; tot += idle;
      end
      idle = 0;
    end
  end

  realtime t0, at = 0;
  int b0, s0, p0, ab = 0, as_ = 0, ap = 0;
  task automatic start(); t0 = $realtime; b0 = busy_cyc; s0 = cpu_slots; p0 = busy_polls; endtask
  task automatic stop();
    at += $realtime - t0; ab += busy_cyc - b0; as_ += cpu_slots - s0; ap += busy_polls - p0;
  endtask
  task automatic show(input string what, input int n);
    real ns = at / n;
    $display("%-28s %9.0f ns %7.1f clk  busy polls %5.2f  busy %7.0f ns  slots %5.2f",
             what, ns, ns * 48.0 / 1000.0 / tc, real'(ap) / n,
             real'(ab) * 31.25 / n, real'(as_) / n);
    $display("%-28s longest busy %0.1f us, %0d over 10 us", "", run_max * 0.03125, long_runs);
    at = 0; ab = 0; as_ = 0; ap = 0; run_max = 0; long_runs = 0;
  endtask

  // lc.gfxdriver's bitmap mode
  logic [7:0] regs [0:36] = '{
    8'h7E, 8'h50, 8'h66, 8'h49, 8'h20, 8'h00, 8'h19, 8'h1D,
    8'h00, 8'h07, 8'h20, 8'h07, 8'h00, 8'h00, 8'h00, 8'h00,
    8'h00, 8'h00, 8'h00, 8'h00, 8'h10, 8'h00, 8'h78, 8'h08,
    8'h00, 8'h87, 8'h00, 8'h00, 8'h10, 8'h07, 8'h00, 8'h00,
    8'h00, 8'h00, 8'h7D, 8'h64, 8'h05};

  localparam int REPS = 8;
  localparam int FRAME = 264 * 127 * 24;     // master clocks
  // Pass r of n starts r/n of a frame after a vsync rise.
  task automatic phase(input int r, input int n);
    @(posedge vsync);
    repeat (FRAME / n * r) @(posedge clk);
  endtask
  int k, lost;
  logic [7:0] pat [256];
  task automatic chip(input string m);
    // R31 polled: outb data, djnz 11, then inb 10, bitb 4, jr 6 per poll.
    for (int r = 0; r < REPS; r++) begin
      phase(r, REPS);
      seek(16'h4000); sel(31);
      start();
      for (int i = 0; i < 256; i++) begin
        forever begin
          io(0, 16'h0181, 8'h00, q, 10); clocks(4 + 6);
          if (q[7]) break;
          busy_polls++; clocks(10);
        end
        dat(8'h55); clocks(11);
      end
      stop();
    end
    show({m, "R31 write, polled"}, REPS * 256);
    // R31 outib unpolled: outib 21, jr 6.
    lost = 0;
    for (int r = 0; r < REPS; r++) begin
      phase(r, REPS);
      seek(16'h4000); sel(31);
      for (int i = 0; i < 256; i++) pat[i] = 8'($urandom);
      start();
      for (int i = 0; i < 256; i++) begin dat(pat[i], 21); clocks(6); end
      stop();
      rdy(); seek(16'h4000); sel(31);
      for (int i = 0; i < 256; i++) begin
        rdy(); io(0, 16'h0183, 8'h00, q, 10);
        if (q !== pat[i]) lost++;
      end
    end
    show({m, "R31 write, unpolled"}, REPS * 256);
    $display("%s  lost %0d of %0d", m, lost, REPS * 256);
    // select alone, select + poll
    start();
    for (int i = 0; i < 256; i++) begin sel(31); clocks(11); end
    stop(); show({m, "select"}, 256);
    start();
    for (int i = 0; i < 256; i++) begin
      sel(31);
      forever begin
        io(0, 16'h0181, 8'h00, q, 10); clocks(4 + 6);
        if (q[7]) break;
        busy_polls++; clocks(10);
      end
      clocks(11);
    end
    stop(); show({m, "select + poll"}, 256);
    // seek: ldb 5, outb, calr rdy, ldb 3, outb, twice; djnz 11
    for (int r = 0; r < REPS; r++) begin
      phase(r, REPS);
      start();
      for (int i = 0; i < 16; i++) begin
        clocks(5); sel(18); rdy(); clocks(3); dat(8'h40);
        clocks(5); sel(19); rdy(); clocks(3); dat(8'(i)); clocks(11);
      end
      stop();
    end
    show({m, "seek"}, REPS * 16);
    // fill and copy, 16 blocks of 256
    for (int cp = 0; cp < 2; cp++)
      for (int r = 0; r < REPS / 2; r++) begin
        phase(r, REPS / 2);
        if (cp) begin wr(24, 8'h80); wr(32, 8'h60); wr(33, 8'h00); seek(16'h4000); end
        else begin wr(24, 8'h00); seek(16'h4000); wr(31, 8'hAA); end
        start();
        for (int b = 0; b < 16; b++) begin
          clocks(5); sel(30); rdy(); clocks(3); dat(8'h00); clocks(11);
        end
        rdy(); stop();
        if (r == REPS / 2 - 1) show({m, cp ? "copy 256" : "fill 256"}, REPS / 2 * 16);
      end
    wr(24, 8'h00); rdy();
  endtask

  initial begin
    if ($value$plusargs("tc=%d", tc)) ;
    zio = $test$plusargs("zio");
    repeat (20) @(posedge clk);
    #1 rst_n = 1'b1; mreset_n = 1'b1;
    repeat (20) @(posedge clk);
    for (int r = 0; r <= 36; r++) wr(6'(r), regs[r]);
    repeat (200000) @(posedge clk);
    if ($test$plusargs("probe")) begin
      probe_on = 1;
      @(posedge vsync); @(posedge vsync);
      probe_on = 0;
      $display("lines by idle columns (free for the CPU):");
      foreach (hist[c]) $display("  %3d free: %0d lines", c, hist[c]);
      $display("frame: %0d lines, %0d free columns", nlines, tot);
      $finish;
    end
    $display("CPU %0.2f MHz%s", 48.0 / tc, zio ? ", I/O at ZCLK" : "");
    chip("on    ");
    wr(1, 8'h08); wr(6, 8'h02);
    chip("blank ");
    $display("NVI falls %0d", nvi_falls);
    $finish;
  end
endmodule
