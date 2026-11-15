// HR card U756 (X, Y_AXIS = 0) / U757 (Y, Y_AXIS = 1), PAL20X8 axis
// counters on FN#7 (equations INFERRED, not dumped):
// eight registers BAD9-2 step +1 when the quadrature phase wraps from
// position 3 (earlier pair) to 0 (newer pair) and -1 the other way, on
// MCLK rising (the one-clk pulse mclk_rise); the two combinatorial pins
// BAD1-0 carry the earlier phase, or with A2 high a constant (U756: M/C
// open 10, linked 01; U757: 00).  All ten drive while -SEL is low.
`default_nettype none

module hr_pal20x8 #(
  parameter bit Y_AXIS = 1'b0
) (
  input  logic       clk,
  input  logic       mclk_rise,
  input  logic       a_now,     // pin 2
  input  logic       a_prev,    // pin 3
  input  logic       b_now,     // pin 4
  input  logic       b_prev,    // pin 5
  input  logic       mc,        // pin 7
  input  logic       a2,        // pin 8
  input  logic       sel_n,     // pins 11, 13
  output logic [9:0] bad,
  output logic       drive
);
  // Justification: the eight output registers (reg-a).
  logic [7:0] count;

  logic [1:0] was, now;
  assign was = {a_prev, a_prev ^ b_prev};
  assign now = {a_now, a_now ^ b_now};

  initial count = '0;
  always_ff @(posedge clk) begin
    if (mclk_rise) begin
      if (was == 2'd3 && now == 2'd0) count <= count + 8'd1;
      else if (was == 2'd0 && now == 2'd3) count <= count - 8'd1;
    end
  end

  logic [1:0] low;
  always_comb begin
    if (!a2) low = was;
    else if (Y_AXIS) low = 2'b00;
    else if (mc) low = 2'b10;
    else low = 2'b01;
  end
  assign drive = !sel_n;
  assign bad   = sel_n ? 10'd0 : {count, low};
endmodule

`default_nettype wire
