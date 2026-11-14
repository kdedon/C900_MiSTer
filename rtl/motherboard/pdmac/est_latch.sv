// 8716 _EST output (pin 8): reset when LD0 falls, set when the block has
// finished, asserted at reset and idle (CCCP spec 96-000016 sec 4.1.28:
// "reset whenever a DMA cycle is started by LD0-").
//
// Same-sample order: est_set (/RESET edge, CmdReset), then the LD0 latch
// (PCSS of LD0 or SS), then blk_done (the block's trailing byte); the
// later one wins.
`default_nettype none

module est_latch (
  input  logic clk,
  input  logic est_set,
  input  logic ld0_latch,
  input  logic blk_done,
  output logic est_n
);

  // Justification: _EST level between the LD0 latch and the end of block (reg-a).
  logic est_q;

  initial begin
    est_q = 1'b1;
  end
  always_ff @(posedge clk) begin
    if (blk_done) est_q <= 1'b1;
    else if (ld0_latch) est_q <= 1'b0;
    else if (est_set) est_q <= 1'b1;
  end

  assign est_n = ~est_q;

endmodule

`default_nettype wire
