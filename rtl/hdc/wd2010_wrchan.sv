// WD2010-05 write channel: parallel to serial and MFM encoder
// (datasheet Figure 1; "MFM Encoding and Decoding", p.71; Write Data
// Timing, p.96).
//
// WCLK (pin 25) arrives as edge pulses.  One data bit per WCLK
// period: the WCLK-high half is the clock cell, the WCLK-low half the
// data cell; WD (pin 21) is High for the half whose cell is a 1.  A
// clock 1 is written between two data 0s, except at data bit 2 of a
// byte presented with `mc` (A1 with the missing clock, 0x4489).  At each
// byte boundary the next byte is taken from `nbyte`/`mc` and `take`
// pulses; the controller must present the following byte within 8 WCLK.
// With `run` Low the encoder idles with WD Low and forgets the last
// data bit.
`default_nettype none

module wd2010_wrchan (
  input  logic       clk,
  input  logic       wclk_rise,
  input  logic       wclk_fall,
  input  logic       run,
  input  logic [7:0] nbyte,
  input  logic       mc,
  output logic       take,
  output logic       wd
);

  // Justification: byte in flight, missing-clock flag, bit count, last data bit (reg-a).
  logic [7:0] sh_q;
  logic       mc_q;
  logic [2:0] bit_q;
  logic       prev_q, cur_q;
  logic       wd_q, take_q;

  logic       rise_c, fall_c, load_c, b_c, clk1_c;
  logic [7:0] sh_c;
  logic       mc_c;

  assign rise_c = wclk_rise;
  assign fall_c = wclk_fall;
  assign load_c = bit_q == 3'd0;
  assign sh_c   = load_c ? nbyte : sh_q;
  assign mc_c   = load_c ? mc : mc_q;
  assign b_c    = sh_c[7];
  assign clk1_c = ~prev_q & ~b_c & ~(mc_c && bit_q == 3'd5);

  initial begin
    sh_q = 8'h00;  mc_q = 1'b0;  bit_q = 3'd0;
    prev_q = 1'b0;  cur_q = 1'b0;  wd_q = 1'b0;  take_q = 1'b0;
  end
  always_ff @(posedge clk) begin
    take_q <= 1'b0;
    if (!run) begin
      bit_q  <= 3'd0;
      prev_q <= 1'b0;
      wd_q   <= 1'b0;
    end else if (rise_c) begin
      take_q <= load_c;
      mc_q   <= mc_c;
      sh_q   <= {sh_c[6:0], 1'b0};
      cur_q  <= b_c;
      wd_q   <= clk1_c;
      bit_q  <= bit_q + 3'd1;
    end else if (fall_c) begin
      wd_q   <= cur_q;
      prev_q <= cur_q;
    end
  end

  assign take = take_q;
  assign wd   = wd_q;

endmodule

`default_nettype wire
