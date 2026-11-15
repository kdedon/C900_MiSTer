// LC card interlace bench: c900_lc_card and lc_video, the field flag.
//   Progressive (the C128 NTSC table, R8 0): field stays 0.
//   Interlaced 640x400 (R8 3, 8x16 cells, 525 lines): per field the sync
//   timing, the field flag toggling once per field, 200 lines; the two
//   fields woven as the scaler does (field 0 on the even lines) give each
//   cell's 16 glyph lines in order; the cursor on the cell lines of a
//   progressive 16-line cell.
//   Interlaced sync only (R8 1): the same lines in both fields, VSYNC half
//   a line later in alternate fields and whole lines wide; the flag follows
//   the VSYNC phase.
// +vdcph: the 8568's dot divider starts one clk_vdc later.  +r4=32: the
// interlaced set with the C128 R4-R7.  +bmp: a 400-line bitmap, the upper
// field from R12/R13, the lower field continuing after it.
`timescale 1ns/1fs
module tb_lc_int;
  localparam real T_EDGE = 1000.0 / 192.0;
  localparam logic [3:0] ST_IO = 4'b0010, ST_INT = 4'b0000;
  localparam real T_LINE = 63500.0;
  localparam int ROWS = 25, CELL = 16, LINES = ROWS * CELL;

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

  c900_dispram u_ram (
    .clk(clk), .lc_sel(1'b1),
    .hr_wrow(14'd0), .hr_we(8'd0), .hr_wd(64'd0), .hr_rrow(14'd0), .hr_q(),
    .lc_rd(ram_rd), .lc_we(ram_we), .lc_addr(ram_addr), .lc_di(ram_di), .lc_do(ram_do)
  );

  initial if ($test$plusargs("vdcph")) begin
    #1 dut.u_8568.u_vdc.clkdiv = 2'd1;
  end

  logic clk_vid = 1'b0;
  initial begin
    #(3.3);
    forever #(1000.0 / 128.0 * 1.0000001) clk_vid = !clk_vid;
  end
  logic       v_ce, v_hs, v_vs, v_hb, v_vb, v_fl;
  logic [7:0] v_r, v_g, v_b;
  lc_video u_video (
    .clk_vdc(clk_vdc), .rgbi(rgbi), .hsync(hsync), .vsync(vsync), .pixel_ce(pixel_ce),
    .active_h(active_h), .active_v(active_v),
    .clk_vid(clk_vid), .ce_pix(v_ce), .r(v_r), .g(v_g), .b(v_b),
    .hs(v_hs), .vs(v_vs), .hblank(v_hb), .vblank(v_vb), .field(v_fl)
  );

  int errors = 0, checks = 0;
  task automatic check(input string what, input logic [31:0] got, input logic [31:0] exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("FAIL %s: got %0d expected %0d", what, got, exp);
    end
  endtask

  task automatic cycle(input logic [3:0] s, input logic [15:0] a, input logic wr,
                       input logic [7:0] d, output logic [7:0] q);
    @(posedge clk); #1;
    st = s; r_w = !wr; b_w = 1'b1; as_n = 1'b0;
    ad_bus = a;
    repeat (4) @(posedge clk); #1 as_n = 1'b1;
    @(posedge clk); #1 ad_bus = 16'h0000;
    repeat (3) @(posedge clk); #1 ds_n = 1'b0;
    ad_bus = wr ? {d, d} : 16'hFFFF;
    repeat (8) @(posedge clk);
    while (!wait_n) @(posedge clk);
    #1 q = ad_oe[0] ? ad_out[7:0] : 8'hFF;
    @(posedge clk); #1 ds_n = 1'b1;
    @(posedge clk); #1 st = ST_INT; ad_bus = 16'hFFFF;
  endtask
  task automatic outb(input logic [15:0] a, input logic [7:0] d);
    logic [7:0] q;
    cycle(ST_IO, a, 1'b1, d, q);
  endtask
  task automatic inb(input logic [15:0] a, output logic [7:0] q);
    cycle(ST_IO, a, 1'b0, 8'h00, q);
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
  task automatic set_ua(input logic [15:0] a);
    vwr(6'd18, a[15:8]); vwr(6'd19, a[7:0]);
  endtask
  // n bytes of v from a, by block fill
  task automatic fill(input logic [15:0] a, input int n, input logic [7:0] v);
    set_ua(a); vwr(6'd31, v); ready();
    n--;
    while (n > 0) begin
      vwr(6'd30, 8'(n > 255 ? 255 : n)); ready();
      n -= n > 255 ? 255 : n;
    end
  endtask

  // Glyph line k of the character on screen row r.
  function automatic logic [7:0] glyph(input int r, input int k);
    glyph = 8'({4'(r), 4'(k)} ^ 8'hA5);
  endfunction

  // C128 KERNAL NTSC table; the interlaced set differs in R4-R9 and R23.
  logic [7:0] ntsc [0:36];
  initial ntsc = '{8'h7E, 8'h50, 8'h66, 8'h49, 8'h20, 8'h00, 8'h19, 8'h1D, 8'h00, 8'h07,
                   8'h20, 8'h07, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
                   8'h08, 8'h00, 8'h78, 8'h08, 8'h20, 8'h47, 8'hF0, 8'h00, 8'h30, 8'h07,
                   8'h00, 8'h00, 8'h00, 8'h00, 8'h7D, 8'h64, 8'h05};

  // ---- clk_vdc: sync pins per field ----
  realtime hs_t[$], vs_t[$], vsf_t[$];
  always @(posedge hsync) hs_t.push_back($realtime);
  always @(posedge vsync) vs_t.push_back($realtime);
  always @(negedge vsync) vsf_t.push_back($realtime);
  realtime av_t[$];
  always @(posedge active_v) av_t.push_back($realtime);

  // ---- clk_vid: lines as the scaler takes them ----
  // The scaler sets a frame's line phase from the flag latched at the last
  // line start before the frame (i_flm at the first displayed pixel), which
  // is the previous field's flag: a field flagged 0 follows a field flagged
  // 1 and starts at the first (even) line; a field flagged 1 goes on the
  // odd lines.
  // A field starts at the VSYNC rise; its field flag is the one at its
  // first displayed pixel.  Each displayed line keeps its first 16 pixels.
  logic        vs_d = 1'b0, de_d = 1'b0;
  int          fno = -1, fline = 0, fpix = 0;
  logic        f_fl [64];
  int          f_lines [64];
  logic [7:0]  f_byte [64][LINES], f_hi [64][LINES];
  logic [15:0] cur_b;
  logic        de;
  assign de = v_ce && !v_hb && !v_vb;
  always @(posedge clk_vid) begin
    if (v_vs && !vs_d && fno < 63) begin
      fno = fno + 1; fline = 0; f_lines[fno] = 0; f_fl[fno] = 1'bx;
    end
    vs_d <= v_vs;
    if (v_ce && fno >= 0) begin
      if (de && !de_d) begin
        if (fline == 0) f_fl[fno] = v_fl;
        fpix = 0; cur_b = '0;
      end
      if (de && fpix < 16) begin
        cur_b[15 - fpix] = |{v_r, v_g, v_b};
        fpix++;
        if (fpix == 16 && fline < LINES) begin
          f_byte[fno][fline] = cur_b[15:8]; f_hi[fno][fline] = cur_b[7:0];
          fline++; f_lines[fno] = fline;
        end
      end
      de_d <= de;
    end
  end
  int fl_flips = 0, fl_ones = 0;
  logic fl_q = 1'b0;
  always @(posedge clk_vid) begin
    if (v_fl != fl_q) fl_flips++;
    if (v_fl) fl_ones++;
    fl_q <= v_fl;
  end

  // Measure n fields after the current VSYNC rise.
  task automatic fields(input int n, output int f0);
    @(posedge vsync);
    @(posedge v_vs);
    #1 f0 = fno;
    fl_flips = 0;
    repeat (n) @(posedge v_vs);
  endtask

  // Sync pins of n fields from VSYNC rise k0: length (checked against hl
  // half lines unless 0), VSYNC phase to HSYNC (moving half a line after a
  // field of odd half lines), width, first displayed line.  alt: the phase
  // alternates.
  task automatic sync_fields(input string tag, input int k0, input int n, input int hl,
                             output logic alt);
    realtime d, ph, dv, d_q;
    int nh;
    logic m, m_q;
    alt = 1'b1;
    for (int i = k0; i < k0 + n; i++) begin
      d  = vs_t[i + 1] - vs_t[i];
      nh = 0; ph = 0; dv = 0;
      foreach (hs_t[j]) begin
        if (hs_t[j] >= vs_t[i] && hs_t[j] < vs_t[i + 1]) nh++;
        if (hs_t[j] <= vs_t[i]) ph = vs_t[i] - hs_t[j];
      end
      foreach (av_t[j]) if (av_t[j] > vs_t[i] && av_t[j] < vs_t[i + 1]) dv = av_t[j] - vs_t[i];
      $display("%s field %0d: %.2f lines, %0d hsyncs, VSYNC %.2f lines after HSYNC, %.2f lines wide, first line %.2f lines after VSYNC",
               tag, i - k0, d / T_LINE, nh, ph / T_LINE, (vsf_t[i] - vs_t[i]) / T_LINE, dv / T_LINE);
      if (hl != 0) check($sformatf("%s field %0d half lines", tag, i - k0), $rtoi(2.0 * d / T_LINE + 0.5), hl);
      m = ph / T_LINE >= 0.25 && ph / T_LINE < 0.75;
      if (i > k0) begin
        if (m == m_q) alt = 1'b0;
        check($sformatf("%s field %0d: VSYNC phase moves with an odd half line", tag, i - k0),
              $rtoi(2.0 * d_q / T_LINE + 0.5) % 2, m != m_q);
      end
      m_q = m; d_q = d;
    end
  endtask

  int f0, nh, k0, r4, hl;
  logic alt;
  logic [15:0] cur_i, cur_p;
  initial begin
    repeat (10) @(posedge clk);
    #1 rst_n = 1'b1; mreset_n = 1'b1;
    repeat (20) @(posedge clk);

    // Progressive
    for (int r = 0; r <= 36; r++)
      if (!(r >= 16 && r <= 19) && r != 30 && r != 31) vwr(6'(r), ntsc[r]);
    fields(1, f0);
    fl_flips = 0; fl_ones = 0;
    fields(3, f0);
    check("progressive: field flag flips", fl_flips, 0);
    check("progressive: field flag high", fl_ones, 0);

    // Screen: row r column 0 holds char 0x40+r, all else blank; attributes
    // white; glyph lines of 0x40+r are glyph(r, k).
    fill(16'h0000, 2000, 8'h20);
    fill(16'h0800, 2000, 8'h0F);
    fill(16'h2000 + 16'h0020 * 16, 16, 8'h00);
    for (int r = 0; r < ROWS; r++) begin
      set_ua(16'(r * 80)); vwr(6'd31, 8'(8'h40 + r));
    end
    set_ua(16'h2000 + 16'h0040 * 16);
    outb(16'h0181, 8'd31);
    for (int r = 0; r < ROWS; r++)
      for (int k = 0; k < CELL; k++) begin ready(); outb(16'h0183, glyph(r, k)); end

    // Interlaced 640x400: 80x25 cells of 8x16; the vertical registers count
    // rows of 8 lines per field.  32 rows x 16 + 13 = 525 half lines a
    // field (262.5 lines); +r4=32: the C128 R4-R7 with R5 0, 527 half lines.
    // VSYNC at row 29.
    if (!$value$plusargs("r4=%d", r4)) r4 = 31;
    hl = r4 == 31 ? 525 : 0;
    vwr(6'd4, 8'(r4)); vwr(6'd5, r4 == 31 ? 8'h0D : 8'h00); vwr(6'd6, 8'h19); vwr(6'd7, 8'h1D);
    vwr(6'd9, 8'h0F); vwr(6'd23, r4 == 31 ? 8'h0F : 8'h10); vwr(6'd8, 8'h03);
    fields(2, f0);
    k0 = vs_t.size();
    fields(6, f0);
    $display("R8 3: field flag flipped %0d times in 6 fields", fl_flips);
    check("R8 3: field flag flips once per field", fl_flips, 6);
    sync_fields("R8 3", k0, 5, hl, alt);
    check("R8 3: VSYNC half a line apart in alternate fields", alt, 1'b1);
    for (int f = f0; f < f0 + 6; f++) begin
      $display("field %0d: flag %b, %0d lines", f - f0, f_fl[f], f_lines[f]);
      check($sformatf("field %0d lines", f - f0), f_lines[f], LINES / 2);
      if (f > f0) check($sformatf("field %0d flag alternates", f - f0), f_fl[f], !f_fl[f - 1]);
    end
    // Weave pairs (field 0 even lines, field 1 odd) and compare.
    for (int f = f0; f < f0 + 6; f += 2) begin
      int bad = 0, top, bot;
      top = f_fl[f] ? f + 1 : f;
      bot = f_fl[f] ? f : f + 1;
      for (int n = 0; n < LINES; n++) begin
        logic [7:0] got;
        got = (n % 2 == 0) ? f_byte[top][n / 2] : f_byte[bot][n / 2];
        if (got !== glyph(n / CELL, n % CELL)) begin
          if (bad < 6) $display("  woven line %0d: got %h expected %h (row %0d line %0d)",
                                n, got, glyph(n / CELL, n % CELL), n / CELL, n % CELL);
          bad++;
        end
      end
      $display("frame %0d: %0d of %0d woven lines wrong", (f - f0) / 2, bad, LINES);
      check($sformatf("frame %0d woven lines", (f - f0) / 2), bad, 0);
    end

    // Cursor on row 0 column 0, steady, R10 12 to R11 16: the woven cell
    // shows the cursor on the cell lines a progressive 16-line cell does.
    vwr(6'd10, 8'h0C); vwr(6'd11, 8'h10);
    fields(2, f0);
    fields(2, f0);
    cur_i = '0;
    for (int n = 0; n < CELL; n++) begin
      logic [7:0] got;
      got = f_byte[f_fl[f0] != (n % 2 == 0) ? f0 : f0 + 1][n / 2];
      cur_i[n] = got === ~glyph(0, n);
      if (got !== glyph(0, n) && got !== ~glyph(0, n)) begin
        errors++; $display("FAIL cursor cell line %0d: %h", n, got);
      end
    end
    vwr(6'd8, 8'h00);
    fields(2, f0);
    fields(1, f0);
    cur_p = '0;
    for (int n = 0; n < CELL; n++) cur_p[n] = f_byte[f0][n] === ~glyph(0, n);
    $display("cursor cell lines: interlaced %b, progressive %b (line 0 rightmost)", cur_i, cur_p);
    check("cursor lines interlaced as progressive", cur_i, cur_p);
    vwr(6'd10, 8'h20);

    // Bitmap: 400 lines of 80 bytes from 0, line m starting m[7:0], m[8].
    // R12/R13 load once a frame: the upper field shows lines 0-199, the
    // lower field continues with 200-399, so woven frame line n shows
    // bitmap line n/2 (even n) or 200 + n/2 (odd n).
    if ($test$plusargs("bmp")) begin
      vwr(6'd26, 8'hF0); vwr(6'd25, 8'h87); vwr(6'd8, 8'h03);
      for (int n = 0; n < LINES; n++) begin
        set_ua(16'(n * 80)); vwr(6'd31, 8'(n)); ready(); outb(16'h0183, {7'd0, n[8]});
      end
      fields(2, f0);
      fields(2, f0);
      begin
        int bad = 0, top, bot, got;
        top = f_fl[f0] ? f0 + 1 : f0;
        bot = f_fl[f0] ? f0 : f0 + 1;
        for (int n = 0; n < LINES; n++) begin
          int f;
          f = n % 2 == 0 ? top : bot;
          got = {f_hi[f][n / 2][0], f_byte[f][n / 2]};
          if (n < 8 || n >= LINES - 4) $display("bitmap woven line %0d (%s field line %0d): bitmap line %0d",
                                                 n, n % 2 == 0 ? "upper" : "lower", n / 2, got);
          if (got != (n % 2 == 0 ? n / 2 : LINES / 2 + n / 2)) bad++;
        end
        $display("bitmap: %0d of %0d woven lines wrong", bad, LINES);
        check("bitmap woven lines", bad, 0);
      end
      vwr(6'd25, 8'h47);
    end

    // Interlaced sync only: the same lines in both fields, VSYNC half a
    // line later in alternate fields and R3 lines wide; the flag toggles.
    vwr(6'd8, 8'h01);
    fields(2, f0);
    k0 = vs_t.size();
    fields(4, f0);
    sync_fields("R8 1", k0, 3, 0, alt);
    $display("R8 1: VSYNC phase %s, field flag flipped %0d times in 4 fields",
             alt ? "alternates" : "constant", fl_flips);
    check("R8 1: VSYNC half a line apart in alternate fields", alt, 1'b1);
    check("R8 1: field flag follows the VSYNC phase", fl_flips, alt ? 4 : 0);
    for (int i = k0; i < k0 + 3; i++)
      check($sformatf("R8 1 field %0d: VSYNC width in lines", i - k0),
            $rtoi(2.0 * (vsf_t[i] - vs_t[i]) / T_LINE + 0.5), 2 * 4);
    check("R8 1: frame lines", $rtoi((vs_t[k0 + 2] - vs_t[k0]) / T_LINE + 0.5), 2 * (r4 + 1) * CELL + 2 * (r4 == 31 ? 13 : 0));
    begin
      int bad = 0;
      for (int n = 0; n < LINES; n++) if (f_byte[f0][n] !== f_byte[f0 + 1][n]) bad++;
      $display("R8 1: %0d of %0d lines differ between the fields", bad, LINES);
      check("R8 1: same lines in both fields", bad, 0);
      check("R8 1: field lines", f_lines[f0], LINES);
    end

    if (errors == 0) $display("PASS tb_lc_int: %0d checks", checks);
    else             $display("FAIL tb_lc_int: %0d of %0d checks", errors, checks);
    $finish;
  end

  initial begin #(1200ms); $display("FAIL timeout"); $finish; end
endmodule
