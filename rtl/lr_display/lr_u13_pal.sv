// LR card dot-clock side: U30 oscillator, U24 74LS163A character counter
// and the video half of U13 PAL16R6A (Address Bus sheet).  Runs in
// clk_vid; one dot = CLKS_PER_DOT clk_vid cycles.
//
// Schematic:
//   U30 -> two U14 74S04 -> OSC: U24 CLK, U13 CLK (pin 1), DOTCLK.
//   U24: LD, ENP, ENT High; A-D Low; /CLR = S-L = /QD (U14 5->6), so the
//   counter runs 0..8 and clears: divide by 9.  QC = _CCLK (CCLK = /QC via
//   U14 9->8 to the 6845 CLK), QD = _S-L (S-L to the U1 LS166 SH/_LD).
//   U13 inputs: I0..I3 = U24 QA..QD, I4 BW-R, I5 A0, I6 U18 F0 (CDR),
//   I7 BB-W.  Outputs: pin 19 _SELMBUF (combinational), 18 MUX-CLK,
//   17 _OE, 16 _W1, 15 _DATCLK, 14 _W2 (registered on OSC), 13 not
//   connected, 12 _WAIT (combinational).
//
// INFERRED (U13 is not dumped): the schedule below follows the sheet, not a
// fuse map.
//   q = U24 count during the dot.  CCLK (/QC) falls at the 3->4 count.  The
//   CPU's VRAM slot (MUX-CLK on the CPU side) opens
//   at the same boundary (cpu_slot); the CRTC fetch (MUX-CLK on the MA
//   side, _OE) reads the VRAM at the end of dot 8 (fetch); U3/U4 latch the
//   word at the end of dot 0 (latch); S-L loads U1 at the end of dot 8
//   (load).  The CPU-side half (_WAIT, _W1/_W2, _SELMBUF) is in lr_cdr.
`default_nettype none
module lr_u13_pal #(
  parameter int CLKS_PER_DOT = 4
) (
  input  logic       clk_vid,
  input  logic       rst_n,        // clk_vid domain
  output logic       dot_ce,       // one clk_vid cycle per dot (end of dot)
  output logic [3:0] q,            // U24 count 0..8 during the dot
  output logic       cpu_slot,     // CPU VRAM slot opens
  output logic       fetch,        // CRTC-side VRAM read
  output logic       latch,        // U3/U4 word latch
  output logic       load          // S-L: U1 parallel load
);
  localparam int PW = $clog2(CLKS_PER_DOT);
  localparam logic [PW-1:0] PLAST = PW'(CLKS_PER_DOT - 1);

  // Justification: (reg-a) U30 period divider (clk_vid -> dot).
  logic [PW-1:0] pre_q;
  always_ff @(posedge clk_vid) begin
    if (!rst_n)              pre_q <= '0;
    else if (pre_q == PLAST) pre_q <= '0;
    else                     pre_q <= pre_q + 1'b1;
  end
  assign dot_ce = (pre_q == PLAST);

  // Justification: (reg-a) U24, synchronous clear by S-L at count 8.
  logic [3:0] u24_q;
  always_ff @(posedge clk_vid) begin
    if (!rst_n)             u24_q <= 4'd0;
    else if (dot_ce) begin
      if (u24_q[3])         u24_q <= 4'd0;
      else                  u24_q <= u24_q + 4'd1;
    end
  end
  assign q = u24_q;

  assign cpu_slot = dot_ce && (u24_q == 4'd3);
  assign fetch    = dot_ce && (u24_q == 4'd8);
  assign latch    = dot_ce && (u24_q == 4'd0);
  assign load     = dot_ce && (u24_q == 4'd8);
endmodule
`default_nettype wire
