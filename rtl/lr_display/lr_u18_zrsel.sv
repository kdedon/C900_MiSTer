// Generated from the 82S100 dump of U18; do not edit.
//
// LR card U18 "ZRSEL" (Address Bus sheet).
// Pin map as the card wires it:
//   I0 A0 (unused by every output)   I1 A2   I2 A3   I3 A4
//   I4 U27 A16&A17&A18   I5..I8 U28 /(A20&A21), A19, A22, A23 (order
//   among I5..I8 is immaterial: each must be Low for the CDR)
//   I9 BW-R (High = write)   I10 BB-W (unused)
//   I11 _BMREQ   I12 _BDS   I13 _I-O4   I14 _SUP   I15 _CCLK (unused)
//   F0 CDR (Low = selected)  F1 _SELI-O  F2 _CTL  F3 _STAT  F4 _6545
//   F5 PH2 (6545 E, High)  F6, F7 unused (0)
`default_nettype none
module lr_u18_zrsel (
  input  logic [15:0] i,   // input pins I15..I0
  output logic [7:0]  f    // output pins F7..F0 (electrical levels)
);
  // F0: support I4,I5,I6,I7,I8,I11,I14; 1 product terms, complement form
  assign f[0] = ~(
        (i[4] & ~i[5] & ~i[6] & ~i[7] & ~i[8] & ~i[11] & i[14]));
  // F1: support I3,I13; 1 product terms, complement form
  assign f[1] = ~(
        (i[3] & ~i[13]));
  // F2: support I1,I2,I3,I9,I12,I13; 1 product terms, complement form
  assign f[2] = ~(
        (~i[1] & i[2] & i[3] & i[9] & ~i[12] & ~i[13]));
  // F3: support I1,I2,I3,I9,I13; 1 product terms, complement form
  assign f[3] = ~(
        (i[1] & i[2] & i[3] & ~i[9] & ~i[13]));
  // F4: support I1,I2,I3,I13; 1 product terms, complement form
  assign f[4] = ~(
        (~i[1] & ~i[2] & i[3] & ~i[13]));
  // F5: support I1,I2,I3,I12,I13; 1 product terms
  assign f[5] =
        (~i[1] & ~i[2] & i[3] & ~i[12] & ~i[13]);
  assign f[6] = 1'b0;  // constant
  assign f[7] = 1'b0;  // constant
  // Inputs no output depends on.
  logic unused_ok;
  assign unused_ok = &{1'b0, i[15], i[10], i[0]};
endmodule
`default_nettype wire
