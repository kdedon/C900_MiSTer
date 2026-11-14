// fifo64 storage bank: a write and an asynchronous read, one MLAB.
`default_nettype none

module fifo64_bank #(
  parameter int DEPTH = 16,
  parameter int AW    = 4
) (
  input  logic          clk,
  input  logic          we,
  input  logic [AW-1:0] wa,
  input  logic [7:0]    wd,
  input  logic [AW-1:0] ra,
  output logic [7:0]    rq
);
  (* ramstyle = "MLAB, no_rw_check" *) logic [7:0] mem [DEPTH];
  always_ff @(posedge clk) begin
    if (we) mem[wa] <= wd;
  end
  assign rq = mem[ra];
endmodule

`default_nettype wire
