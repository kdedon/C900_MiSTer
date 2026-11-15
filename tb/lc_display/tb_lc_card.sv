// LC card bench: Z-Bus I/O cycles into c900_lc_card, scoreboarded.
//   ID and decode, 8568 register write/read-back, RAM fill and read through
//   R18/R19/R31, block fill and copy, status ready, VBLANK and version,
//   R37 read-back, the INTR pin on CN11 _NVI, the NTSC frame's sync timing,
//   refresh cycles per line (R36), the sync polarity (R37) at the pins and
//   positive pulses out of lc_video whatever R37 sets, and
//   the 48/32 MHz boundary at every clock phase with bus and turbo strobes,
//   a frame of coloured, reversed and underlined text, and lc_video: every
//   displayed 8568 pixel reaches clk_vid in order, in the CGA palette.
// The RAM is the shared display RAM (c900_dispram) on clk, the HR side
// fed noise.  +vdcph: the 8568's dot divider starts one clk_vdc later, so
// its columns start at the other clk phase.
`timescale 1ns/1fs
module tb_lc_card;
  localparam real T_CLK = 1000.0 / 48.0;     // master clock
  localparam real T_VDC = 1000.0 / 32.0;     // 2 x 16 MHz card oscillator
  localparam logic [3:0] ST_IO = 4'b0010, ST_INT = 4'b0000;

  // One VCO: both clocks from the 192 MHz edge grid, rises together every
  // 62.5 ns (12 edges), as the PLL makes them.
  localparam real T_EDGE = 1000.0 / 192.0;
  logic clk = 1'b0, clk_vdc = 1'b0;
  int   edge_n = 0;
  always #(T_EDGE) begin
    edge_n = (edge_n + 1) % 12;
    if (edge_n % 2 == 1) clk = !clk;
    if (edge_n % 3 == 0) clk_vdc = !clk_vdc;
  end

  logic        rst_n = 1'b0, mreset_n = 1'b0;
  logic [15:0] pa = 16'h0000, ad_bus = 16'hFFFF;
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

  logic [13:0] hr_wrow = '0, hr_rrow = '0;
  logic [7:0]  hr_we = '0;
  logic [63:0] hr_wd = '0, hr_q;
  always @(posedge clk) begin
    hr_wrow <= 14'($urandom); hr_rrow <= 14'($urandom);
    hr_we <= 8'($urandom); hr_wd <= {$urandom, $urandom};
  end
  c900_dispram u_ram (
    .clk(clk), .lc_sel(1'b1),
    .hr_wrow(hr_wrow), .hr_we(hr_we), .hr_wd(hr_wd), .hr_rrow(hr_rrow), .hr_q(hr_q),
    .lc_rd(ram_rd), .lc_we(ram_we), .lc_addr(ram_addr), .lc_di(ram_di), .lc_do(ram_do)
  );
  initial if ($test$plusargs("vdcph")) begin
    #1 dut.u_8568.u_vdc.clkdiv = 2'd1;
  end

  // lc_video, clk_vid from a separate PLL on the same reference: 64 MHz,
  // own phase, 0.1 ppm slow for a fractional step.
  logic clk_vid = 1'b0;
  initial begin
    #(3.3);
    forever #(1000.0 / 128.0 * 1.0000001) clk_vid = !clk_vid;
  end
  logic       v_ce, v_hs, v_vs, v_hb, v_vb;
  logic [7:0] v_r, v_g, v_b;
  lc_video u_video (
    .clk_vdc(clk_vdc), .rgbi(rgbi), .hsync(hsync), .vsync(vsync), .pixel_ce(pixel_ce),
    .active_h(active_h), .active_v(active_v),
    .clk_vid(clk_vid), .ce_pix(v_ce), .r(v_r), .g(v_g), .b(v_b),
    .hs(v_hs), .vs(v_vs), .hblank(v_hb), .vblank(v_vb)
  );

  // CGA palette (rgbicolor palette 0), R G B I.
  function automatic logic [23:0] cga(input logic [3:0] c);
    case (c)
      4'h0: cga = 24'h000000;  4'h1: cga = 24'h4E4E4E;  4'h2: cga = 24'h0000C4;  4'h3: cga = 24'h4E4EDC;
      4'h4: cga = 24'h00C400;  4'h5: cga = 24'h4EDC4E;  4'h6: cga = 24'h00C4C4;  4'h7: cga = 24'h4EF3F3;
      4'h8: cga = 24'hC40000;  4'h9: cga = 24'hDC4E4E;  4'hA: cga = 24'hC400C4;  4'hB: cga = 24'hF34EF3;
      4'hC: cga = 24'hC47E00;  4'hD: cga = 24'hF3F34E;  4'hE: cga = 24'hC4C4C4;  default: cga = 24'hFFFFFF;
    endcase
  endfunction
  logic [3:0] pix_q[$];
  int         pix_in = 0, pix_out = 0, pix_bad = 0, pix_under = 0;
  logic [15:0] pix_seen = '0;
  logic        cnt_on = 1'b0;
  int          cnt_c[16] = '{default: 0};
  // Sampled between edges: the words the FIFO accepts on the next rise. A
  // word refused while full is lost, counted after the first frame.
  int pix_drop = 0;
  always @(negedge clk_vdc) begin
    if (pixel_ce && active_h && active_v && cnt_on) cnt_c[rgbi]++;
    if (u_video.push && u_video.u_fifo.full && vs_rise.size() > 0) pix_drop++;
    if (u_video.push && !u_video.u_fifo.full && pixel_ce && active_h && active_v) begin
      pix_q.push_back(rgbi);
      pix_in++;
    end
  end
  always @(posedge clk_vid) if (v_ce && !v_hb && !v_vb) begin
    if (pix_q.size() == 0) pix_under++;
    else begin
      logic [3:0] c;
      c = pix_q.pop_front();
      pix_seen[c] = 1'b1;
      pix_out++;
      if ({v_r, v_g, v_b} !== cga(c)) begin
        if (pix_bad < 5) $display("FAIL pixel %0d: rgbi %h got %06h", pix_out, c, {v_r, v_g, v_b});
        pix_bad++;
      end
    end
  end

  int nvi_diffs = 0;
  always @(negedge clk_vdc) if (nvi_n !== dut.u_8568.intr_n) nvi_diffs++;
  int errors = 0, checks = 0, max_wait = 0, min_wait = 1000;
  // wait_nx: each /WAIT clock after the first as it said one clock before.
  logic wait_q = 1'b1, wait_nx_q = 1'b1;
  always @(posedge clk) begin
    if (!wait_q && wait_n !== wait_nx_q) begin errors++; $display("FAIL wait_nx"); end
    wait_q    <= wait_n;
    wait_nx_q <= wait_nx;
  end
  int ds_min = 8, as_len = 4, last_wait = 0;   // /DS low clocks before /WAIT counts
  task automatic check(input string what, input logic [31:0] got, input logic [31:0] exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("FAIL %s: got %h expected %h", what, got, exp);
    end
  endtask

  // One Z-Bus cycle: /AS, then /DS low for at least 8 clocks (6 MHz I/O
  // with its automatic wait), stretched while /WAIT is low.
  task automatic cycle(input logic [3:0] s, input logic [15:0] a, input logic wr,
                       input logic [7:0] d, output logic [7:0] q, output logic drv);
    int w = 0;
    @(posedge clk); #1;
    st = s; r_w = !wr; b_w = 1'b1; as_n = 1'b0;
    ad_bus = a;
    repeat (as_len) @(posedge clk); #1 as_n = 1'b1;
    @(posedge clk); #1 ad_bus = 16'h0000;
    repeat (as_len - 1) @(posedge clk); #1 ds_n = 1'b0;
    ad_bus = wr ? {d, d} : 16'hFFFF;
    repeat (ds_min) begin @(posedge clk); if (!wait_n) w++; end
    while (!wait_n) begin @(posedge clk); if (!wait_n) w++; end
    #1;
    q   = ad_oe[0] ? ad_out[7:0] : 8'hFF;
    drv = ad_oe[0];
    @(posedge clk); #1 ds_n = 1'b1;
    @(posedge clk); #1 st = ST_INT; ad_bus = 16'hFFFF;
    last_wait = w;
    if (s == ST_IO && a[15:2] == 14'h0060 && a[0]) begin
      if (w > max_wait) max_wait = w;
      if (w < min_wait) min_wait = w;
    end
  endtask

  task automatic outb(input logic [15:0] a, input logic [7:0] d);
    logic [7:0] q; logic drv;
    cycle(ST_IO, a, 1'b1, d, q, drv);
  endtask
  task automatic inb(input logic [15:0] a, output logic [7:0] q);
    logic drv;
    cycle(ST_IO, a, 1'b0, 8'h00, q, drv);
  endtask

  task automatic ready();
    logic [7:0] s;
    int n = 0;
    do begin inb(16'h0181, s); n++; end while (!s[7] && n < 1000);
    if (!s[7]) begin errors++; $display("FAIL ready timeout"); end
  endtask
  task automatic vwr(input logic [5:0] r, input logic [7:0] v);
    outb(16'h0181, {2'b00, r}); ready(); outb(16'h0183, v);
  endtask
  task automatic vrd(input logic [5:0] r, output logic [7:0] v);
    outb(16'h0181, {2'b00, r}); ready(); inb(16'h0183, v);
  endtask

  // Read-back of a register: unused bits read 1.
  function automatic logic [7:0] rb(input logic [5:0] r, input logic [7:0] v);
    case (r)
      5, 9, 11, 23, 29: rb = v | 8'hE0;
      8:                rb = v | 8'hFC;
      10:               rb = v | 8'h80;
      28:               rb = v | 8'h0F;
      36:               rb = v | 8'hF0;
      default:          rb = v;
    endcase
  endfunction

  // C128 KERNAL NTSC table, R28 for 64 KB.
  logic [7:0] ntsc [0:36];
  initial begin
    ntsc = '{8'h7E, 8'h50, 8'h66, 8'h49, 8'h20, 8'h00, 8'h19, 8'h1D, 8'h00, 8'h07,
             8'h20, 8'h07, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
             8'h08, 8'h00, 8'h78, 8'h08, 8'h20, 8'h40, 8'hF0, 8'h00, 8'h30, 8'h07,
             8'h00, 8'h00, 8'h00, 8'h00, 8'h7D, 8'h64, 8'h05};
  end

  function automatic logic [7:0] pat(input int i);
    pat = 8'(i * 7 + 3);
  endfunction

  task automatic set_ua(input logic [15:0] a);
    vwr(6'd18, a[15:8]); vwr(6'd19, a[7:0]);
  endtask
  task automatic ram_read(input logic [15:0] a, input int n, output logic [7:0] buf_q [64]);
    logic [7:0] v;
    set_ua(a);
    outb(16'h0181, 8'd31);
    for (int i = 0; i < n; i++) begin ready(); inb(16'h0183, v); buf_q[i] = v; end
  endtask

  // Sync measurement, in ns.
  realtime hs_rise[$], vs_rise[$], vs_fall[$];
  always @(posedge hsync) hs_rise.push_back($realtime);
  always @(posedge vsync) vs_rise.push_back($realtime);
  longint vdc_cyc = 0, vs_cyc[$];
  always @(posedge clk_vdc) vdc_cyc++;
  always @(posedge vsync) vs_cyc.push_back(vdc_cyc);
  always @(negedge vsync) vs_fall.push_back($realtime);

  // Refresh cycles (R36) in the last complete line.
  int rf_n = 0, rf_line = -1;
  always @(posedge clk_vdc) if (dut.u_8568.u_vdc.enable) begin
    if (dut.u_8568.u_vdc.signals.newCol && dut.u_8568.u_vdc.signals.col == 8'd0) begin
      rf_line = rf_n; rf_n = 0;
    end
    if (dut.u_8568.u_vdc.signals.endCol && dut.u_8568.u_vdc.ram.ramAction == 3'd5) rf_n++;
  end

  // Sync high time per clk_vdc, at the 8568 pins and out of lc_video.
  int pol_n = 0, pol_hs = 0, pol_vs = 0, pol_vhs = 0, pol_vvs = 0;
  logic pol_on = 1'b0;
  always @(posedge clk_vdc) if (pol_on) begin
    pol_n++;
    pol_hs  += int'(hsync); pol_vs  += int'(vsync);
    pol_vhs += int'(u_video.hs_p); pol_vvs += int'(u_video.vs_p);
  end
  task automatic polarity(input string tag, input logic hneg, input logic vneg);
    repeat (3) @(posedge u_video.vs_p);
    pol_n = 0; pol_hs = 0; pol_vs = 0; pol_vhs = 0; pol_vvs = 0;
    pol_on = 1'b1;
    @(posedge u_video.vs_p);
    pol_on = 1'b0;
    $display("%s: HSYNC high %.1f%%, VSYNC high %.1f%% at the pins; %.1f%%, %.1f%% to the scaler", tag,
             100.0 * pol_hs / pol_n, 100.0 * pol_vs / pol_n, 100.0 * pol_vhs / pol_n, 100.0 * pol_vvs / pol_n);
    check({tag, " HSYNC pin active low"}, pol_hs > pol_n / 2, hneg);
    check({tag, " VSYNC pin active low"}, pol_vs > pol_n / 2, vneg);
    check({tag, " scaler HSYNC positive"}, pol_vhs < pol_n / 2, 1'b1);
    check({tag, " scaler VSYNC positive"}, pol_vvs < pol_n / 2, 1'b1);
    check({tag, " scaler HSYNC high time"}, pol_vhs, hneg ? pol_n - pol_hs : pol_hs);
  endtask

  // Handshake invariants at the clk_vdc side: payload stable while req_q is
  // high, one 8568 strobe per request, ack only while requested.
  int hs_bad = 0, strobes = 0, reqs = 0;
  logic [9:0] pay_q;
  logic       req_d = 1'b0;
  always @(posedge clk_vdc) begin
    if (dut.req_q && req_d && pay_q != {dut.rs_q, dut.we_q, dut.wd_q}) hs_bad++;
    if (dut.ack_vq && !dut.req_q && !dut.done_q && dut.started_q) hs_bad++;
    if (dut.cs_vq) strobes++;
    if (dut.req_q && !req_d) reqs++;
    pay_q <= {dut.rs_q, dut.we_q, dut.wd_q};
    req_d <= dut.req_q;
  end

  logic [7:0] q, v;
  logic       drv;
  logic [7:0] rbuf [64];
  realtime    t0, line_ns;
  int         n_lines, vbl_hi, vbl_lo;
  logic [7:0] rfv [3] = {8'd5, 8'd0, 8'd15};

  initial begin
    repeat (10) @(posedge clk);
    #1 rst_n = 1'b1; mreset_n = 1'b1;
    repeat (20) @(posedge clk);

    // ID and decode
    inb(16'h01FF, q); check("ID", q, 8'hC1);
    cycle(ST_IO, 16'h0185, 1'b0, 8'h00, q, drv); check("0x0185 undriven", drv, 1'b0);
    cycle(ST_IO, 16'h0180, 1'b0, 8'h00, q, drv); check("0x0180 undriven", drv, 1'b0);
    cycle(ST_IO, 16'h0101, 1'b0, 8'h00, q, drv); check("0x0101 undriven", drv, 1'b0);
    cycle(ST_IO, 16'h01F9, 1'b0, 8'h00, q, drv); check("0x01F9 undriven", drv, 1'b0);
    cycle(ST_IO, 16'h01FB, 1'b0, 8'h00, q, drv); check("0x01FB undriven", drv, 1'b0);
    cycle(4'b0011, 16'h01FF, 1'b0, 8'h00, q, drv); check("special I/O undriven", drv, 1'b0);

    // Registers
    for (int r = 0; r <= 36; r++)
      if (!(r >= 16 && r <= 19) && r != 30 && r != 31) vwr(6'(r), ntsc[r]);
    for (int r = 0; r <= 36; r++)
      if (!(r >= 16 && r <= 19) && r != 30 && r != 31) begin
        vrd(6'(r), v); check($sformatf("R%0d", r), v, rb(6'(r), ntsc[r]));
      end
    inb(16'h0181, q); check("status b4:0 (version 2)", q[4:0], 5'b00010);
    // R37, 8568 only: HSYNC and VSYNC polarity read back, 1s from reset
    vrd(6'd37, v); check("R37 after reset", v, 8'hFF);
    vwr(6'd37, 8'h40); vrd(6'd37, v); check("R37", v, 8'h7F);
    vwr(6'd37, 8'h00); vrd(6'd37, v); check("R37 clear", v, 8'h3F);
    vwr(6'd37, 8'hC0); vrd(6'd37, v); check("R37 set", v, 8'hFF);

    // RAM fill and read-back through R31
    set_ua(16'h1000);
    outb(16'h0181, 8'd31);
    for (int i = 0; i < 64; i++) begin ready(); outb(16'h0183, pat(i)); end
    ram_read(16'h1000, 64, rbuf);
    for (int i = 0; i < 64; i++) check($sformatf("RAM %h", 16'h1000 + i), rbuf[i], pat(i));
    vrd(6'd18, v); check("UA hi after reads", v, 8'h10);

    // Block fill: guard bytes, then A5 x 16 from 0x2000
    set_ua(16'h1FFF); vwr(6'd31, 8'h11);
    set_ua(16'h2010); vwr(6'd31, 8'h22);
    vwr(6'd24, 8'h20);
    set_ua(16'h2000); vwr(6'd31, 8'hA5); ready();
    vwr(6'd30, 8'd15); ready();
    ram_read(16'h1FFF, 18, rbuf);
    check("fill guard lo", rbuf[0], 8'h11);
    for (int i = 1; i <= 16; i++) check($sformatf("fill %0d", i), rbuf[i], 8'hA5);
    check("fill guard hi", rbuf[17], 8'h22);

    // Block copy 16 bytes 0x1000 -> 0x3000
    vwr(6'd24, 8'hA0);
    vwr(6'd32, 8'h10); vwr(6'd33, 8'h00);
    set_ua(16'h3000);
    vwr(6'd30, 8'd16); ready();
    vwr(6'd24, 8'h20);
    ram_read(16'h3000, 16, rbuf);
    for (int i = 0; i < 16; i++) check($sformatf("copy %0d", i), rbuf[i], pat(i));

    // INTR [VDCDS p.40]: low on the Update Ready rise, released by a status
    // read and while Update Ready is 0.  No status reads below until said.
    ready();
    repeat (4) @(posedge clk_vdc); #1;
    check("INTR released by a status read", dut.u_8568.intr_n, 1'b1);
    vwr(6'd24, 8'h20); set_ua(16'h4000); vwr(6'd31, 8'h33); ready();
    inb(16'h0181, q);
    outb(16'h0181, 8'd30); outb(16'h0183, 8'd200);
    check("fill busy", dut.u_8568.busy, 1'b1);
    check("INTR released while not ready", dut.u_8568.intr_n, 1'b1);
    wait (!dut.u_8568.busy);
    repeat (2) @(posedge clk_vdc); #1;
    check("INTR low after the ready rise", dut.u_8568.intr_n, 1'b0);
    check("CN11 _NVI low with INTR", nvi_n, 1'b0);
    repeat (500) @(posedge clk);
    check("INTR held low", dut.u_8568.intr_n, 1'b0);
    inb(16'h0181, q);
    check("status ready at the read", q[7], 1'b1);
    repeat (2) @(posedge clk_vdc); #1;
    check("INTR released by the status read", dut.u_8568.intr_n, 1'b1);
    check("CN11 _NVI released with INTR", nvi_n, 1'b1);
    outb(16'h0181, 8'd30); outb(16'h0183, 8'd100);
    wait (!dut.u_8568.busy);
    repeat (2) @(posedge clk_vdc); #1;
    check("INTR low after the second fill", dut.u_8568.intr_n, 1'b0);
    outb(16'h0181, 8'd31); outb(16'h0183, 8'h44);
    if (dut.u_8568.busy) begin
      @(posedge clk_vdc); #1;
      check("INTR released while busy again", dut.u_8568.intr_n, 1'b1);
    end else begin
      wait (dut.u_8568.busy); @(posedge clk_vdc); #1;
      check("INTR released while busy again", dut.u_8568.intr_n, 1'b1);
    end
    wait (!dut.u_8568.busy);
    repeat (2) @(posedge clk_vdc); #1;
    check("INTR low after the R31 write", dut.u_8568.intr_n, 1'b0);
    ready();
    check("INTR released by ready()", dut.u_8568.intr_n, 1'b1);
    ram_read(16'h4000, 4, rbuf);
    check("fill byte", rbuf[0], 8'h33);

    // Status VBLANK over one frame (about 17 ms), sampled every 100 us
    vbl_hi = 0; vbl_lo = 0;
    for (int i = 0; i < 170; i++) begin
      inb(16'h0181, q);
      if (q[5]) vbl_hi++; else vbl_lo++;
      #(100us);
    end
    $display("VBLANK samples: %0d high, %0d low (expect about 64/264 high)", vbl_hi, vbl_lo);
    check("VBLANK seen high", vbl_hi > 20 && vbl_hi < 60, 1'b1);

    // Sync timing (NTSC table): line 1016 dots = 63.5 us, 264 lines
    wait (vs_rise.size() >= 3);
    check("enough hsyncs", hs_rise.size() > 300, 1'b1);
    line_ns = hs_rise[hs_rise.size() - 1] - hs_rise[hs_rise.size() - 2];
    $display("line %.3f us", line_ns / 1000.0);
    check("line period ns", 32'($rtoi(line_ns + 0.5)), 32'd63500);
    check("two vsyncs", vs_rise.size() >= 2, 1'b1);
    t0 = vs_rise[vs_rise.size() - 1] - vs_rise[vs_rise.size() - 2];
    n_lines = $rtoi(t0 / 63500.0 + 0.5);
    $display("frame %.3f ms, %0d lines", t0 / 1.0e6, n_lines);
    check("frame lines", n_lines, 264);
    check("frame exact clk_vdc", 32'(vs_cyc[vs_cyc.size() - 1] - vs_cyc[vs_cyc.size() - 2]),
          32'(264 * 2032));
    begin
      realtime w;
      int k;
      k = vs_fall.size() - 1;
      w = vs_fall[k] - vs_rise[vs_rise.size() - 1];
      if (w < 0) w = vs_fall[k] - vs_rise[vs_rise.size() - 2];
      $display("vsync width %.1f lines", w / 63500.0);
      check("vsync width lines", $rtoi(w / 63500.0 + 0.5), 4);
    end

    // Clock boundary: an 8568 access from each of the three clk phases in
    // the 62.5 ns grid, at bus speed and with turbo strobes (/AS and /DS one
    // clock, held only by /WAIT).
    for (int sp = 0; sp < 2; sp++) begin
      as_len = sp ? 1 : 4; ds_min = sp ? 1 : 8;
      for (int ph = 0; ph < 3; ph++) begin
        int wmin = 1000, wmax = 0;
        for (int k = 0; k < 6; k++) begin
          logic [7:0] d;
          d = 8'(8'h3C + 16 * sp + 4 * ph + k);
          while (edge_n != 4 * ((ph + k) % 3) + 1) @(posedge clk);
          outb(16'h0181, 8'd20);
          if (last_wait < wmin) wmin = last_wait; if (last_wait > wmax) wmax = last_wait;
          outb(16'h0183, d);
          if (last_wait < wmin) wmin = last_wait; if (last_wait > wmax) wmax = last_wait;
          inb(16'h0183, q);
          if (last_wait < wmin) wmin = last_wait; if (last_wait > wmax) wmax = last_wait;
          check($sformatf("R20 speed %0d phase %0d run %0d", sp, ph, k), q, d);
        end
        $display("boundary speed %0d phase %0d: /WAIT %0d-%0d clocks", sp, ph, wmin, wmax);
        check($sformatf("/WAIT bound speed %0d phase %0d", sp, ph), wmax <= 6 && wmin >= 5, 1'b1);
      end
    end
    as_len = 4; ds_min = 8;
    // a 6 MHz CPU samples /WAIT 12 clocks after the /DS fall: never held
    check("/WAIT clear by the 6 MHz sample", max_wait < 12, 1'b1);

    check("payload stable, ack only on request", hs_bad, 0);
    check("one 8568 strobe per request", strobes, reqs);

    // Coloured text frame: row 0 holds char 1 (left half lit) in colours
    // 1-C and F, a blank char reversed in D and a blank char underlined in E.
    // Per frame: 32 pixels of each glyph colour, 64 of D, 8 of E. Scroll 7
    // (R25 = 47, the C128 value) puts column 0 at the window's left edge.
    vwr(6'd20, 8'h08); vwr(6'd21, 8'h00); vwr(6'd25, 8'h47);
    set_ua(16'h2010);
    outb(16'h0181, 8'd31);
    for (int i = 0; i < 16; i++) begin ready(); outb(16'h0183, 8'hF0); end
    set_ua(16'h0000);
    outb(16'h0181, 8'd31);
    for (int i = 0; i < 15; i++) begin ready(); outb(16'h0183, i < 13 ? 8'h01 : 8'h02); end
    set_ua(16'h0800);
    outb(16'h0181, 8'd31);
    for (int i = 0; i < 15; i++) begin
      ready();
      outb(16'h0183, i < 12 ? 8'(i + 1) : i == 12 ? 8'h0F : i == 13 ? 8'h4D : 8'h2E);
    end
    @(posedge vsync); @(posedge clk_vdc); cnt_on = 1'b1;
    @(posedge vsync); @(posedge clk_vdc); cnt_on = 1'b0;
    for (int c = 1; c < 16; c++)
      check($sformatf("frame pixels colour %h", c), cnt_c[c], c == 13 ? 64 : c == 14 ? 8 : 32);
    $display("frame: %0d pixels, %0d colour 0", cnt_c.sum(), cnt_c[0]);
    repeat (2000) @(posedge clk_vdc);
    check("colours through the palette", pix_seen, 16'hFFFF);

    // Refresh cycles per line: R36 of them
    foreach (rfv[i]) begin
      vwr(6'd36, rfv[i]);
      repeat (2) @(posedge hsync);
      @(posedge hsync);
      check($sformatf("refresh cycles per line, R36 %0d", rfv[i]), rf_line, rfv[i]);
    end
    vwr(6'd36, ntsc[36]);

    // Sync polarity: R37 b7 HSYNC, b6 VSYNC, 1 = positive
    polarity("R37 C0", 1'b0, 1'b0);
    vwr(6'd37, 8'h00); polarity("R37 00", 1'b1, 1'b1);
    vwr(6'd37, 8'h80); polarity("R37 80", 1'b0, 1'b1);
    vwr(6'd37, 8'hC0); polarity("R37 C0 again", 1'b0, 1'b0);

    $display("/WAIT per 8568 access: %0d-%0d clocks (%.0f-%.0f ns)", min_wait, max_wait,
             min_wait * T_CLK, max_wait * T_CLK);
    $display("lc_video: %0d pixels in, %0d out, %0d wrong, %0d underruns, %0d dropped, colours %b",
             pix_in, pix_out, pix_bad, pix_under, pix_drop, pix_seen);
    check("video pixels out", pix_out > 100000, 1'b1);
    check("video pixels lost", pix_in - pix_out <= 16, 1'b1);
    check("video FIFO drops", pix_drop, 0);
    check("video pixels wrong", pix_bad, 0);
    check("video underruns", pix_under, 0);
    check("CN11 _NVI is INTR every clk_vdc", 32'(nvi_diffs), 32'd0);
    if (errors == 0) $display("PASS tb_lc_card: %0d checks", checks);
    else             $display("FAIL tb_lc_card: %0d of %0d checks", errors, checks);
    $finish;
  end

  initial begin #(400ms); $display("FAIL timeout"); $finish; end
endmodule
