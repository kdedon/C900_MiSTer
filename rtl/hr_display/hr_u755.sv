// HR card U755 (PAL16L8, FN#7): port decode, button gate, MCLK buffer.
// Equations INFERRED, not dumped:
// -SEL X/Y = I/O read with A1 = 0/1, -SEL W = I/O write with A1 = 0,
// -SEL Z = I/O read with A4 = 1, BAD15-13 = pressed B1-B3, MCLK = ZCLK.
`default_nettype none

module hr_u755 (
  input  logic b1_n,     // pin 11
  input  logic b2_n,     // pin 1
  input  logic b3_n,     // pin 2
  input  logic io4_n,    // pin 3
  input  logic a4,       // pin 4
  input  logic a1,       // pin 5
  input  logic zclk,     // pin 6
  input  logic brw,      // pin 7, high = read
  input  logic bds_n,    // pin 8
  output logic selx_n,   // pin 12
  output logic selz_n,   // pin 13
  output logic selw_n,   // pin 14
  output logic bad13,    // pin 15
  output logic bad14,    // pin 16
  output logic bad15,    // pin 17
  output logic mclk,     // pin 18
  output logic sely_n    // pin 19
);
  logic io, rd, wr;
  assign io     = !io4_n && !bds_n;
  assign rd     = io && brw;
  assign wr     = io && !brw;
  assign selx_n = !(rd && !a1);
  assign sely_n = !(rd && a1);
  assign selw_n = !(wr && !a1);
  assign selz_n = !(rd && a4);
  assign bad15  = !b1_n;
  assign bad14  = !b2_n;
  assign bad13  = !b3_n;
  assign mclk   = zclk;
endmodule

`default_nettype wire
