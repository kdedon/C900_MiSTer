// 8563 on the shared display RAM against the 8563 with its own RAM block:
// vdo_top is the chip before its RAM moved out (vdcram, the vendor block's
// read-enable behaviour), vdc_top drives c900_dispram on the 48 MHz clk.
// Same bus on both; every clk_vdc compares the pins and the bus byte.
// Register writes, R31 text, fills, copies and reads at random times, a
// scoreboard of the bytes read back.
//   +cth=<n>   R22 high nibble (character width; 1 = the shortest column)
//   +dbl       R25 b4 (pixel double width, a column every 4 clk_vdc)
//   +vdcph     dot divider starts one clk_vdc later: columns start at the
//              other clk phase
`timescale 1ns/1fs
module tb_lc_eq;
  localparam real T_EDGE = 1000.0 / 192.0;
  logic clk = 1'b0, clk_vdc = 1'b0;
  int   edge_n = 0;
  always #(T_EDGE) begin
    edge_n = (edge_n + 1) % 12;
    if (edge_n % 2 == 1) clk = !clk;
    if (edge_n % 3 == 0) clk_vdc = !clk_vdc;
  end

  logic reset = 1'b1, cs = 1'b0, rs = 1'b0, we = 1'b0;
  logic [7:0] db = 8'h00;
  wire  [7:0] do_o, do_n;
  wire        vs_o, hs_o, ce_o, ah_o, av_o, vs_n, hs_n, ce_n, ah_n, av_n;
  wire  [3:0] rgbi_o, rgbi_n;

  vdo_top #(.RAM_ADDR_BITS(16)) u_old (.version(1'b0), .ram64k(1'b1), .initRam(1'b0), .debug(1'b0),
    .clk(clk_vdc), .enableBus(cs), .reset(reset), .init(1'b0), .cs(cs), .rs(rs), .we(we), .db_in(db),
    .db_out(do_o), .lp_n(1'b1), .vsync(vs_o), .hsync(hs_o), .pixel_ce(ce_o), .active_h(ah_o),
    .active_v(av_o), .rgbi(rgbi_o));

  wire        m_rd, m_we;
  wire [15:0] m_a;
  wire  [7:0] m_di, m_do;
  vdc_top #(.RAM_ADDR_BITS(16)) u_new (.version(1'b0), .ram64k(1'b1), .initRam(1'b0), .debug(1'b0),
    .clk(clk_vdc), .enableBus(cs), .reset(reset), .init(1'b0), .cs(cs), .rs(rs), .we(we), .db_in(db),
    .db_out(do_n), .lp_n(1'b1), .vsync(vs_n), .hsync(hs_n), .pixel_ce(ce_n), .active_h(ah_n),
    .active_v(av_n), .rgbi(rgbi_n),
    .mem_rd(m_rd), .mem_we(m_we), .mem_addr(m_a), .mem_di(m_di), .mem_do(m_do));

  logic [13:0] hr_wrow = '0, hr_rrow = '0;
  logic [7:0]  hr_we = '0;
  logic [63:0] hr_wd = '0, hr_q;
  always @(posedge clk) begin
    hr_wrow <= 14'($urandom); hr_rrow <= 14'($urandom);
    hr_we <= 8'($urandom); hr_wd <= {$urandom, $urandom};
  end
  c900_dispram u_ram (.clk(clk), .lc_sel(1'b1),
    .hr_wrow(hr_wrow), .hr_we(hr_we), .hr_wd(hr_wd), .hr_rrow(hr_rrow), .hr_q(hr_q),
    .lc_rd(m_rd), .lc_we(m_we), .lc_addr(m_a), .lc_di(m_di), .lc_do(m_do));

  initial if ($test$plusargs("vdcph")) begin
    #1 u_old.clkdiv = 2'd1; u_new.clkdiv = 2'd1;
  end

  // Pins every clk_vdc; the column-start phase in the 62.5 ns grid.
  longint cyc = 0, diffs = 0, vsr = 0, pix = 0, lit = 0, rds = 0, wrs = 0;
  logic vs_q = 1'b0, rd_q = 1'b0, we_q = 1'b0;
  int ph_n[12] = '{default: 0};
  always @(posedge clk_vdc) begin
    cyc <= cyc + 1;
    if ({vs_o, hs_o, ce_o, ah_o, av_o, rgbi_o, do_o} !== {vs_n, hs_n, ce_n, ah_n, av_n, rgbi_n, do_n}) begin
      if (diffs < 20) $display("DIFF cyc %0d old vs%b hs%b ce%b ah%b av%b rgbi%h db%h new vs%b hs%b ce%b ah%b av%b rgbi%h db%h",
        cyc, vs_o, hs_o, ce_o, ah_o, av_o, rgbi_o, do_o, vs_n, hs_n, ce_n, ah_n, av_n, rgbi_n, do_n);
      diffs <= diffs + 1;
    end
    vs_q <= vs_o; rd_q <= m_rd; we_q <= m_we;
    if (vs_o && !vs_q) vsr <= vsr + 1;
    if (ce_o) pix <= pix + 1;
    if (ce_o && rgbi_o != 0) lit <= lit + 1;
    if (m_rd && !reset) rds <= rds + 1;
    if (m_we) wrs <= wrs + 1;
    if ((m_rd || m_we) && !reset) ph_n[edge_n]++;
  end

  task automatic bus(input logic r, input logic w, input logic [7:0] v);
    @(negedge clk_vdc) begin cs = 1'b1; rs = r; we = w; db = v; end
    @(negedge clk_vdc) cs = 1'b0;
    repeat (3) @(negedge clk_vdc);
  endtask
  task automatic ready();
    int n = 0;
    do begin bus(1'b0, 1'b0, 8'h00); n++; end while (!do_n[7] && n < 100000);
    if (!do_n[7]) $fatal(1, "FAIL ready timeout");
  endtask
  task automatic wr(input logic [5:0] r, input logic [7:0] v);
    bus(1'b0, 1'b1, {2'b00, r}); ready(); bus(1'b1, 1'b1, v);
  endtask
  task automatic rd(input logic [5:0] r, output logic [7:0] v);
    bus(1'b0, 1'b1, {2'b00, r}); ready(); bus(1'b1, 1'b0, 8'h00); v = do_n;
  endtask
  task automatic set_ua(input logic [15:0] a);
    wr(6'd18, a[15:8]); wr(6'd19, a[7:0]);
  endtask

  // Expected RAM contents for the scoreboard.
  logic [7:0] ram [65536];
  int checks = 0, errors = 0;
  task automatic check_block(input logic [15:0] a, input int n, input string what);
    logic [7:0] v;
    set_ua(a);
    bus(1'b0, 1'b1, 8'd31);
    for (int i = 0; i < n; i++) begin
      ready(); bus(1'b1, 1'b0, 8'h00); v = do_n;
      checks++;
      if (v !== ram[16'(a + i)]) begin
        errors++;
        if (errors < 10) $display("FAIL %s %h: got %h expected %h", what, 16'(a + i), v, ram[16'(a + i)]);
      end
    end
  endtask

  logic [7:0] ntsc [0:36];
  int seed, cth;
  initial begin
    ntsc = '{8'h7E, 8'h50, 8'h66, 8'h49, 8'h20, 8'h00, 8'h19, 8'h1D, 8'h00, 8'h07,
             8'h20, 8'h07, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
             8'h08, 8'h00, 8'h78, 8'h08, 8'h20, 8'h47, 8'hF5, 8'h00, 8'h30, 8'h07,
             8'h00, 8'h00, 8'h00, 8'h00, 8'h7D, 8'h64, 8'h05};
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if ($value$plusargs("cth=%d", cth)) ntsc[22] = {4'(cth), 4'(cth)};
    if ($test$plusargs("dbl")) ntsc[25] = ntsc[25] | 8'h10;
    for (int i = 0; i < 65536; i++) ram[i] = 8'h00;
    void'($urandom(seed));
    repeat (8) @(negedge clk_vdc);
    reset = 1'b0;
    repeat (8) @(negedge clk_vdc);
    for (int r = 0; r <= 36; r++) if (r != 31 && r != 30 && !(r >= 16 && r <= 19)) wr(6'(r), ntsc[r]);

    // Text at 0x0000 and attributes at 0x0800 through R31.
    set_ua(16'h0000);
    bus(1'b0, 1'b1, 8'd31);
    for (int i = 0; i < 400; i++) begin
      ready(); bus(1'b1, 1'b1, 8'(i * 7 + 3)); ram[i] = 8'(i * 7 + 3);
    end
    set_ua(16'h0800);
    bus(1'b0, 1'b1, 8'd31);
    for (int i = 0; i < 400; i++) begin
      ready(); bus(1'b1, 1'b1, 8'(i + 1)); ram[16'h0800 + i] = 8'(i + 1);
    end
    check_block(16'h0000, 400, "text");
    check_block(16'h0800, 400, "attr");

    // Random work: R31 runs, fills, copies, read-backs, at random times.
    for (int k = 0; k < 60; k++) begin
      int unsigned r, n;
      logic [15:0] a, b;
      logic [7:0]  d;
      r = $urandom;
      repeat (r % 30000) @(negedge clk_vdc);
      a = 16'($urandom);
      n = 1 + $urandom % 64;
      d = 8'($urandom);
      case (k % 4)
        0: begin
          set_ua(a);
          bus(1'b0, 1'b1, 8'd31);
          for (int i = 0; i < n; i++) begin
            ready(); bus(1'b1, 1'b1, 8'(d + i)); ram[16'(a + i)] = 8'(d + i);
          end
        end
        1: begin                                       // fill n bytes of d from a
          wr(6'd24, 8'h20);
          set_ua(a); wr(6'd31, d); ram[a] = d;
          ready(); wr(6'd30, 8'(n - 1)); ready();
          for (int i = 1; i < n; i++) ram[16'(a + i)] = d;
        end
        2: begin                                       // copy n bytes b -> a
          b = 16'($urandom);
          wr(6'd24, 8'hA0);
          wr(6'd32, b[15:8]); wr(6'd33, b[7:0]);
          set_ua(a); wr(6'd30, 8'(n)); ready();
          for (int i = 0; i < n; i++) ram[16'(a + i)] = ram[16'(b + i)];
          wr(6'd24, 8'h20);
        end
        3: ;
      endcase
      check_block(a, n, $sformatf("job %0d", k));
    end
    check_block(16'h0000, 400, "text end");
    repeat (1200000) @(negedge clk_vdc);
    $display("RESULT cyc %0d vsync rises %0d pixels %0d lit %0d RAM reads %0d writes %0d RAM strobes seen at clk_vdc rises 3/9 of the grid (clk rises at 9) %0d/%0d checks %0d errors %0d diffs %0d",
             cyc, vsr, pix, lit, rds, wrs, ph_n[3], ph_n[9], checks, errors, diffs);
    if (diffs != 0 || errors != 0 || vsr < 1 || lit == 0) $fatal(1, "FAIL tb_lc_eq");
    $display("PASS tb_lc_eq");
    $finish;
  end
endmodule
