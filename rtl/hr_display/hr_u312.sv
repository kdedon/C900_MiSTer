// HR card U312 (74LS174, FN#3): the control register, BAD5-0 loaded on
// the rising edge of -SEL W, cleared by /MRESET.  Q = BKS1, BKS2,
// MONO EN, MONO I, and two unused bits.  BAD meets the setup time before
// -SEL W rises; by the time the rise is seen the CPU may already drive
// the next address, so D is the BAD byte held while -SEL W is low.  The
// board glue makes a one-master-clock pulse from -SEL W rising.
`default_nettype none

module hr_u312 (
  input  logic       clk,
  input  logic       selw_n,
  input  logic       mreset_n,
  input  logic [5:0] bad,       // BAD5-0
  output logic [5:0] q
);
  // Justification: LS174 flip-flops, last -SEL W level, D held (reg-a).
  logic [5:0] r;
  logic       selw_q;
  logic [5:0] d;

  initial begin
    r = '0; selw_q = 1'b0; d = '0;
  end
  always_ff @(posedge clk) begin
    if (!selw_n) d <= bad;
    selw_q <= selw_n;
    if (!mreset_n) r <= '0;
    else if (selw_n && !selw_q) r <= d;
  end
  assign q = r;
endmodule

`default_nettype wire
