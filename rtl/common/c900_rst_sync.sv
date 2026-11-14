// Reset release synchroniser: release two clock edges after both the reset
// request is gone and the PLL is locked.  Loss of lock asserts at once, a
// request at the next edge.  The asynchronous clear comes from a register.
`default_nettype none
module c900_rst_sync (
  input  logic clk,
  input  logic arst,        // active high
  input  logic pll_locked,
  output logic rst_n
);
  (* preserve *) logic src_q, sync_q;
  always_ff @(posedge clk or negedge pll_locked) begin
    if (!pll_locked) src_q <= 1'b0;
    else             src_q <= ~arst;
  end
  always_ff @(posedge clk or negedge src_q) begin
    if (!src_q) sync_q <= 1'b0;
    else        sync_q <= 1'b1;
  end
  assign rst_n = sync_q;
endmodule
`default_nettype wire
