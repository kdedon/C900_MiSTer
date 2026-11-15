// HR card FN#3 fetch counter: U315 and U317 (74HC4024, 7 bits each,
// counting on CLK falling, MR high clearing) cascade into XP0-XP13.  U315
// is clocked by ZMEMC XCLK, U317 by U315 Q7; both are cleared by U262
// CNT RES.  The board glue turns each falling clock pin into a
// one-master-clock pulse; MR acts on the master clock.
`default_nettype none

module hr_fn3_xp (
  input  logic        clk,
  input  logic        xclk,
  input  logic        cntres,
  output logic [13:0] xp
);
  // Justification: U315/U317 counts and the last XCLK / U315 Q7 levels
  // for the edge pulses (reg-a).
  logic [6:0] u315, u317;
  logic       xclk_q, q7_q;

  logic xclk_fall, q7_fall;
  assign xclk_fall = xclk_q && !xclk;
  assign q7_fall   = q7_q && !u315[6];

  initial begin
    u315 = '0; u317 = '0; xclk_q = 1'b0; q7_q = 1'b0;
  end
  always_ff @(posedge clk) begin
    xclk_q <= xclk;
    q7_q   <= u315[6];
    if (cntres) begin
      u315 <= '0;
      u317 <= '0;
    end else begin
      if (xclk_fall) u315 <= u315 + 7'd1;
      if (q7_fall) u317 <= u317 + 7'd1;
    end
  end

  assign xp = {u317, u315};
endmodule

`default_nettype wire
