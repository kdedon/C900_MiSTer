// HR card ZARB U211 (PAL16R8, FN#2; equations INFERRED, not dumped):
// CREQ, SRV, MUX (high = row address), WE,
// registered on CLK (24M) rising, a one-master-clock pulse on ck_rise.
// t is U207's count k (T8 T4 T2 T1); the edge enters k + 1.
`default_nettype none

module hr_zarb (
  input  logic       clk,
  input  logic       ck_rise,   // pin 1 CLK (24M), rising-edge pulse
  input  logic [3:0] t,
  input  logic       cdone_n,
  input  logic       sel_n,
  input  logic       ras_n,
  input  logic       brw,
  output logic [3:0] q        // {we, mux, srv, creq}
);
  logic [3:0] n, d;
  assign n    = t + 4'd1;
  wire unused_n = n[3] ^ n[0];
  assign d[0] = !sel_n && !q[1] && cdone_n;                        // CREQ
  assign d[1] = !sel_n && (q[1] || !cdone_n);                      // SRV
  assign d[2] = n[2:1] == 2'b00;                                   // MUX
  assign d[3] = !brw && !ras_n && !t[3] && t >= 4'd1 && t <= 4'd5; // WE

  // Justification: PAL16R8 output registers (reg-a).
  logic [3:0] r;
  initial r = '0;
  always_ff @(posedge clk) if (ck_rise) r <= d;
  assign q = r;
endmodule

`default_nettype wire
