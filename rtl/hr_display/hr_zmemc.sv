// HR card ZMEMC U209 (PAL16R8, FN#2; equations INFERRED, not dumped),
// registered on CLK (24M) rising, a one-master-clock
// pulse on ck_rise.  Per count: CPU RAS 1-6 with -CDONE at 6; display RAS 9-14, XCLK
// 15; -OE1 12-14 and SR LAT CLK 14 catch row bytes 0-3, SR LD 15 loads
// them; -OE2 15 and 0 and SR LAT CLK 0 catch bytes 4-7, SR LD 7 loads
// them.  DE DLY (pin 6) is not used by this program.
`default_nettype none

module hr_zmemc (
  input  logic       clk,
  input  logic       ck_rise,   // pin 1 CLK (24M), rising-edge pulse
  input  logic [3:0] t,
  input  logic       dedly,
  input  logic       vblk_n,
  input  logic       de,
  input  logic       creq_n,
  output logic [7:0] q        // {oe2, oe1, srlatclk, srld, cyc, cdone, xclk, ras}
);
  logic [3:0] n;
  logic       disp, cyc, fetch;
  logic [7:0] d;
  assign n     = t + 4'd1;
  assign disp  = de && vblk_n;
  assign cyc   = (!creq_n && n == 4'd1) || (q[3] && n >= 4'd2 && n <= 4'd6);
  assign fetch = de && n >= 4'd9 && n <= 4'd14;
  assign d[0]  = cyc || fetch;                                          // RAS
  assign d[1]  = de && n == 4'd15;                                      // XCLK
  assign d[2]  = q[3] && n == 4'd6;                                     // CDONE
  assign d[3]  = cyc;                                                   // CYC
  assign d[4]  = disp && (n == 4'd15 || n == 4'd7);                     // SR LD
  assign d[5]  = disp && (n == 4'd14 || n == 4'd0);                     // SR LAT CLK
  assign d[6]  = (cyc && n >= 4'd3) || (disp && n >= 4'd12 && n <= 4'd14); // OE1
  assign d[7]  = (cyc && n >= 4'd3) || (disp && (n == 4'd15 || n == 4'd0)); // OE2

  wire unused_dedly = dedly;

  // Justification: PAL16R8 output registers (reg-a).
  logic [7:0] r;
  initial r = '0;
  always_ff @(posedge clk) if (ck_rise) r <= d;
  assign q = r;
endmodule

`default_nettype wire
