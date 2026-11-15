// HR card sync group (FN#2): U207 74S161 dividing 24M into T1/T2/T4/T8
// (control pins tied high), U262 82S105 sequencer clocked by T8, U261
// HC4040 line counter clocked by U262 H CNT (counting on its fall) and
// cleared by CNT RES.  One master clock; U207's CLK pin (24M) is the
// rising-edge pulse ck24_rise, and the board glue here turns T8 rising
// and H CNT falling into one-master-clock pulses on the same clock.
//
// U262 inputs: I0-I2 = DE, HSYNC, H CNT (own outputs), I3 = M/C, I4 =
// 4PC (JP3, high = open), I5-I15 = U261 Q1-Q11.  Outputs F0-F7 = DE,
// HSYNC, H CNT, -HSYNC, -VSYNC, -VBLANK, DE DLY, CNT RES.
`default_nettype none

module hr_syn (
  input  logic        clk,
  input  logic        ck24_rise,
  input  logic        mc,
  input  logic        pc4,
  output logic [3:0]  t,
  output logic [7:0]  f,
  output logic [11:0] v
);
  // Justification: U207 74S161 count (reg-a).
  logic [3:0] u207;
  // Justification: U261 HC4040 count (reg-a).
  logic [11:0] u261;
  // Justification: last T8 and H CNT levels for the edge pulses (reg-a).
  logic t8_q, hcnt_q;

  logic t8_rise, hcnt_fall;
  assign t8_rise   = u207[3] && !t8_q;
  assign hcnt_fall = hcnt_q && !f[2];

  hr_u262 u262 (.clk, .ck_rise(t8_rise), .i({u261[10:0], pc4, mc, f[2], f[1], f[0]}), .f);

  initial begin
    u207 = '0; u261 = '0; t8_q = 1'b0; hcnt_q = 1'b0;
  end
  always_ff @(posedge clk) begin
    t8_q   <= u207[3];
    hcnt_q <= f[2];
    if (ck24_rise) u207 <= u207 + 4'd1;
    if (f[7]) u261 <= '0;
    else if (hcnt_fall) u261 <= u261 + 12'd1;
  end

  assign t = u207;
  assign v = u261;
endmodule

`default_nettype wire
