// HR card video pins to the MiSTer video path, one for one.
//
// Each 24M period the pins go into a 16-entry dual-clock FIFO (clk ->
// clk_vid).  clk_vid runs at 96 MHz with the HR card fitted, from the same
// 50 MHz reference as clk, so the fill stays put: reading starts at half
// full, one entry per four clk_vid.  The PLL's fractional step leaves
// clk_vid 2.4e-12 slow: one entry drift every 4.8 hours, a dropped 24M
// period once the FIFO fills after about 38 hours.
//
//   clk     : ck24 -> push {mono, hs, vs, hblank, vblank, level, pixels}
//   clk_vid : every 4th clock pop; mono shifts four pixels out, one per
//             clock (CE_PIXEL always on); colour shows one pixel with
//             CE_PIXEL every fourth clock
//
// Blanking is the card's U262 nets: HBlank while neither DE nor DE DLY is
// high (mono: DE leads the shifter output by 9 periods, DE DLY trails it
// by 7; colour: 8 and 8),
// VBlank while -VBLANK is low.
//
// Levels: mono lit 0xFF (intensity) or 0xCC, dark with MONO EN off;
// colour gun 0xFF with I, 0xAA without.
`default_nettype none

module hr_video (
  input  logic       clk,        // master clock, 48 MHz
  input  logic       ck24,       // the card's 24M rise pulse
  input  logic       colour,     // JP3 M/C linked
  input  logic       hsync,
  input  logic       vsync_n,
  input  logic       de,
  input  logic       de_dly,
  input  logic       vblank_n,
  input  logic [3:0] rgbi,       // I, R, G, B
  input  logic [3:0] u104,       // four mono pixels, bit 3 first
  input  logic       mono_en,
  input  logic       mono_i,
  input  logic       clk_vid,    // 96 MHz
  output logic       ce_pix = 1'b0,
  output logic [7:0] r = '0,
  output logic [7:0] g = '0,
  output logic [7:0] b = '0,
  output logic       hs = 1'b0,
  output logic       vs = 1'b0,
  output logic       hblank = 1'b1,
  output logic       vblank = 1'b1
);
  // ---- clk: one entry per 24M period ----
  // Level code: 0 dark, 1 0xAA, 2 0xCC, 3 0xFF.
  logic [1:0] lvl;
  logic [3:0] nib;
  always_comb begin
    if (colour) begin
      lvl = rgbi[3] ? 2'd3 : 2'd1;
      nib = {1'b0, rgbi[2:0]};
    end else begin
      lvl = !mono_en ? 2'd0 : (mono_i ? 2'd3 : 2'd2);
      nib = u104;
    end
  end

  logic [10:0] word;
  assign word = {~colour, hsync, ~vsync_n, ~(de | de_dly), ~vblank_n, lvl, nib};

  logic [1:0]  ph;
  logic [10:0] cur;
  logic        cur_ok;
  vid_fifo #(.W(11)) u_fifo (.clk_src(clk), .push(ck24), .word(word),
    .clk_vid(clk_vid), .ph(ph), .cur(cur), .cur_ok(cur_ok));

  function automatic logic [7:0] level(input logic [1:0] c);
    case (c)
      2'd1:    level = 8'hAA;
      2'd2:    level = 8'hCC;
      2'd3:    level = 8'hFF;
      default: level = 8'h00;
    endcase
  endfunction

  logic       mono;
  logic [3:0] pix;
  logic [2:0] on;
  assign mono = cur[10];
  assign pix  = cur[3:0];
  assign on   = mono ? {3{pix[~ph]}} : pix[2:0];

  always_ff @(posedge clk_vid) begin
    ce_pix <= cur_ok && (mono || ph == 2'd0);
    hs     <= cur[9];
    vs     <= cur[8];
    hblank <= cur[7];
    vblank <= cur[6];
    r <= on[2] ? level(cur[5:4]) : 8'h00;
    g <= on[1] ? level(cur[5:4]) : 8'h00;
    b <= on[0] ? level(cur[5:4]) : 8'h00;
  end
endmodule

`default_nettype wire
