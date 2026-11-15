// U54 82S100 FPLA (sheet 5): DRAM bank strobes, boot ROM select and the
// MA8 row/column bit.  Inputs are the device pins i0..i15.  Equations
// minimized from the chip dump.
`default_nettype none
module c900_u54_fpla (
  input  logic mux_col_bit,  // i0
  input  logic a17,          // i1
  input  logic mux_row_bit,  // i2
  input  logic a19,          // i3
  input  logic a20,          // i4
  input  logic a21,          // i5
  input  logic a22,          // i6
  input  logic a23,          // i7
  input  logic a0,           // i8
  input  logic ras_timing,   // i9
  input  logic ras_enable,   // i10
  input  logic rom_enable,   // i11
  input  logic cas_timing,   // i12
  input  logic cas13,        // i13
  input  logic ras14,        // i14
  input  logic mux_sel,      // i15
  output logic ras0_n,
  output logic cas0l_n,
  output logic cas0h_n,
  output logic ras1_n,
  output logic cas1l_n,
  output logic cas1h_n,
  output logic romcs_n,
  output logic ma8
);
  // Deassert form: each active-low output is High when its term is true.
  assign ras0_n  = ras_enable | (ras_timing & ras14 & (~a19 | a20 | a21 | a22 | a23));
  assign ras1_n  = ras_enable | (ras_timing & ras14 & (a19 | ~a20 | a21 | a22 | a23));
  assign cas0l_n = a21 | ~a19 | a20 | a22 | a23 | cas13 | (~a0 & cas_timing);
  assign cas0h_n = a21 | ~a19 | a20 | a22 | a23 | cas13 | ( a0 & cas_timing);
  assign cas1l_n = a21 | ~a20 | a22 | a19 | a23 | cas13 | (~a0 & cas_timing);
  assign cas1h_n = a21 | ~a20 | a22 | a19 | a23 | cas13 | ( a0 & cas_timing);
  assign romcs_n = a17 | mux_row_bit | a19 | a20 | a21 | a22 | a23 | ras_enable | ~rom_enable;
  assign ma8     = mux_sel ? mux_row_bit : mux_col_bit;
endmodule
`default_nettype wire
