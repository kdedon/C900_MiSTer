// Row latches in flip-flops (vdr_top, row_ram.patch reversed) against row
// latches in block RAM (vdc_top), on the same clock, bus and RAM contents.
// Every clock compares all pins: sync, pixel, RGBI, data bus, busy and the
// RAM pins. Text with attributes, then register writes at random times:
// display and attribute start, row length (beyond the 82-byte latch too),
// smooth scroll, address increment, mode bits, interlace, cursor; R31
// text, fills and copies in between.
//   +cth=<n>   R22 high nibble (1 = the shortest column)
//   +dbl       R25 b4 (pixel double width)
//   +vdcph     dot divider starts one clock later
//   +bmp       bitmap mode with attributes at the start
`timescale 1ns/1ps
module tb_rowram_eq;
  logic clk = 1'b0;
  always #15.625 clk = ~clk;              // 32 MHz
  logic reset = 1'b1, cs = 1'b0, rs = 1'b0, we = 1'b0;
  logic [7:0] db = 8'h00;
  wire  [7:0] do_o, do_n;
  wire        vs_o, hs_o, ce_o, ah_o, av_o, bz_o, vs_n, hs_n, ce_n, ah_n, av_n, bz_n;
  wire  [3:0] rgbi_o, rgbi_n;
  wire        rd_o, we_o, rd_n, we_n;
  wire [15:0] a_o, a_n;
  wire  [7:0] di_o, mo_o, di_n, mo_n;

  vdr_top #(.RAM_ADDR_BITS(16)) u_old (.version(1'b1), .ram64k(1'b1), .initRam(1'b0), .debug(1'b0),
    .clk(clk), .enableBus(cs), .reset(reset), .init(1'b0), .cs(cs), .rs(rs), .we(we), .db_in(db),
    .db_out(do_o), .lp_n(1'b1), .vsync(vs_o), .hsync(hs_o), .pixel_ce(ce_o), .active_h(ah_o),
    .active_v(av_o), .rgbi(rgbi_o), .status_busy(bz_o),
    .mem_rd(rd_o), .mem_we(we_o), .mem_addr(a_o), .mem_di(di_o), .mem_do(mo_o));
  vdcram #(8, 16) u_old_ram (.clk(clk), .rd(rd_o), .we(we_o), .addr(a_o), .dai(di_o), .dao(mo_o));
  vdc_top #(.RAM_ADDR_BITS(16)) u_new (.version(1'b1), .ram64k(1'b1), .initRam(1'b0), .debug(1'b0),
    .clk(clk), .enableBus(cs), .reset(reset), .init(1'b0), .cs(cs), .rs(rs), .we(we), .db_in(db),
    .db_out(do_n), .lp_n(1'b1), .vsync(vs_n), .hsync(hs_n), .pixel_ce(ce_n), .active_h(ah_n),
    .active_v(av_n), .rgbi(rgbi_n), .status_busy(bz_n),
    .mem_rd(rd_n), .mem_we(we_n), .mem_addr(a_n), .mem_di(di_n), .mem_do(mo_n));
  vdcram #(8, 16) u_new_ram (.clk(clk), .rd(rd_n), .we(we_n), .addr(a_n), .dai(di_n), .dao(mo_n));

  // Same random contents in both RAMs.
  initial begin
    #1;
    for (int i = 0; i < 65536; i++) begin
      u_old_ram.mem[i] = 8'($urandom(i + 77));
      u_new_ram.mem[i] = u_old_ram.mem[i];
    end
  end

  initial if ($test$plusargs("vdcph")) begin
    #2 u_old.clkdiv = 2'd1; u_new.clkdiv = 2'd1;
  end

  wire [51:0] pins_o = {vs_o, hs_o, ce_o, ah_o, av_o, bz_o, rgbi_o, do_o, rd_o, we_o, a_o, we_o ? di_o : 8'h00, mo_o};
  wire [51:0] pins_n = {vs_n, hs_n, ce_n, ah_n, av_n, bz_n, rgbi_n, do_n, rd_n, we_n, a_n, we_n ? di_n : 8'h00, mo_n};

  // Fetches into the latches in the RAM version (ramAction 2 screen, 3 attribute).
  longint cyc = 0, diffs = 0, vsr = 0, pix = 0, lit = 0, fs = 0, fa = 0, fc = 0, av = 0, ab = 0;
  logic vs_q = 1'b0;
  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (pins_o !== pins_n) begin
      if (diffs < 20) $display("DIFF cyc %0d old %h new %h", cyc, pins_o, pins_n);
      diffs <= diffs + 1;
    end
    vs_q <= vs_o;
    if (vs_o && !vs_q) vsr <= vsr + 1;
    if (ce_o) pix <= pix + 1;
    if (ce_o && rgbi_o != 4'h0) lit <= lit + 1;
    if (ce_o && u_new.reg_atr && u_new.video.attr != 8'h00) av <= av + 1;
    if (u_new.enable && u_new.endCol && !reset) begin
      if (u_new.ram.ramAction == 3'd2) fs <= fs + 1;
      if (u_new.ram.ramAction == 3'd3) fa <= fa + 1;
      if (u_new.ram.ramAction == 3'd1) fc <= fc + 1;
      if (u_new.ram.ramAction == 3'd1 && u_new.reg_atr && !u_new.reg_text && u_new.ram.ram_addr[u_new.reg_ctv[4] ? 13 : 12]) ab <= ab + 1;
    end
  end

  task automatic bus(input logic r, input logic w, input logic [7:0] v);
    @(negedge clk) begin cs = 1'b1; rs = r; we = w; db = v; end
    @(negedge clk) cs = 1'b0;
    repeat (3) @(negedge clk);
  endtask
  task automatic ready();
    int n = 0;
    do begin bus(1'b0, 1'b0, 8'h00); n++; end while (!do_n[7] && n < 100000);
    if (!do_n[7]) $fatal(1, "FAIL ready timeout");
  endtask
  task automatic wr(input logic [5:0] r, input logic [7:0] v);
    bus(1'b0, 1'b1, {2'b00, r}); ready(); bus(1'b1, 1'b1, v);
  endtask

  logic [7:0] ntsc [0:36];
  int seed, cth = 0;
  function automatic int unsigned rnd();
    seed = seed * 1664525 + 1013904223;
    return {seed[15:0], seed[31:16]};
  endfunction
  initial begin
    ntsc = '{8'h7E, 8'h50, 8'h66, 8'h49, 8'h20, 8'h00, 8'h19, 8'h1D, 8'h00, 8'h07,
             8'h20, 8'h07, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
             8'h08, 8'h00, 8'h78, 8'h08, 8'h20, 8'h47, 8'hF5, 8'h00, 8'h30, 8'h07,
             8'h00, 8'h00, 8'h00, 8'h00, 8'h7D, 8'h64, 8'h05};
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if ($value$plusargs("cth=%d", cth)) ntsc[22] = {4'(cth), 4'(cth)};
    if ($test$plusargs("dbl")) ntsc[25] = ntsc[25] | 8'h10;
    if ($test$plusargs("bmp")) ntsc[25] = ntsc[25] | 8'h80;
    repeat (8) @(negedge clk);
    reset = 1'b0;
    repeat (8) @(negedge clk);
    for (int r = 0; r <= 36; r++) if (r != 31 && r != 30 && !(r >= 16 && r <= 19)) wr(6'(r), ntsc[r]);
    repeat (3 * 532000) @(negedge clk);
    $display("static: cyc %0d vsync rises %0d diffs %0d", cyc, vsr, diffs);

    for (int k = 0; k < 48; k++) begin
      int unsigned r, n;
      r = rnd();
      repeat (r % 300000) @(negedge clk);
      case (k % 16)
        0:  begin wr(6'd12, 8'(rnd())); wr(6'd13, 8'(rnd())); end       // display start
        1:  begin wr(6'd20, 8'(rnd())); wr(6'd21, 8'(rnd())); end       // attribute start
        2:  case (r[9:8])                                                     // row length
              2'd0: wr(6'd1, 8'h50);
              2'd1: wr(6'd1, 8'h52);
              2'd2: wr(6'd1, 8'(8'h53 + r[4:0]));
              2'd3: wr(6'd1, 8'(8'h28 + r[5:0]));
            endcase
        3:  wr(6'd25, {ntsc[25][7:4], 4'(r[3:0] % (ntsc[22][7:4] + 1))});     // smooth scroll within the column
        4:  wr(6'd27, 8'(r[1:0] == 2'd0 ? 8'h00 : 8'(rnd() % 9)));         // address increment
        5:  wr(6'd24, {1'b0, 2'(r[6:5]), 5'(r[4:0])});                        // vertical scroll, rvs, blink
        6:  wr(6'd25, {2'(r[1:0]), 1'b0, ntsc[25][4], 4'(r[7:4] % (ntsc[22][7:4] + 1))});  // text/bitmap, attributes
        7:  wr(6'd9, 8'(r[0] ? 8'h07 : 8'(r[4:1])));                          // character total vertical
        8:  wr(6'd8, 8'(r[1:0]));                                             // interlace
        9:  begin wr(6'd14, 8'(rnd())); wr(6'd15, 8'(rnd()));           // cursor
                  wr(6'd10, 8'(r[6:5] << 5)); end
        10: wr(6'd28, {3'(r[2:0]), 1'b1, 4'h0});                              // character base
        11: begin                                                             // R31 text
              wr(6'd18, 8'(rnd())); wr(6'd19, 8'(rnd()));
              n = 1 + rnd() % 120;
              bus(1'b0, 1'b1, 8'd31);
              for (int i = 0; i < n; i++) begin ready(); bus(1'b1, 1'b1, 8'(rnd())); end
            end
        12: begin                                                             // fill
              wr(6'd24, 8'h20);
              wr(6'd18, 8'(rnd())); wr(6'd19, 8'(rnd())); wr(6'd31, 8'(rnd()));
              ready(); wr(6'd30, 8'(rnd())); ready();
            end
        13: begin                                                             // copy
              wr(6'd24, 8'hA0);
              wr(6'd32, 8'(rnd())); wr(6'd33, 8'(rnd()));
              wr(6'd18, 8'(rnd())); wr(6'd19, 8'(rnd()));
              wr(6'd30, 8'(rnd())); ready(); wr(6'd24, 8'h20);
            end
        14: wr(6'd26, 8'(rnd()));                                          // colours
        15: begin wr(6'd1, ntsc[1]); wr(6'd9, ntsc[9]); wr(6'd8, 8'h00);      // back to the start mode
                  wr(6'd25, ntsc[25]); wr(6'd27, 8'h00); end
      endcase
    end
    repeat (2 * 532000) @(negedge clk);
    $display("RESULT cyc %0d vsync rises %0d pixels %0d lit %0d fetches screen %0d attribute %0d char %0d (alternate set %0d) attributes shown %0d diffs %0d",
             cyc, vsr, pix, lit, fs, fa, fc, ab, av, diffs);
    if (diffs != 0) $fatal(1, "FAIL: %0d clocks differ", diffs);
    if (vsr < 4 || lit == 0 || fs == 0 || fa == 0 || (ab == 0 && !ntsc[25][7]) || av == 0) $fatal(1, "FAIL: coverage");
    $display("PASS tb_rowram_eq");
    $finish;
  end
endmodule
