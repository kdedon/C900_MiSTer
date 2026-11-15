// Behavioural model of the 8563 RAM block as the vendor instantiates it
// (single port, read enable, unregistered output): a write leaves the
// output alone, a read updates it.
module vdcram #(
  parameter DATA_WIDTH    = 8,
  parameter ADDRESS_WIDTH = 16
) (
  input                          clk,
  input                          rd,
  input                          we,
  input      [ADDRESS_WIDTH-1:0] addr,
  input      [DATA_WIDTH-1:0]    dai,
  output reg [DATA_WIDTH-1:0]    dao
);
  reg [DATA_WIDTH-1:0] mem [0:(1<<ADDRESS_WIDTH)-1];
  integer i;
  initial begin
    for (i = 0; i < (1<<ADDRESS_WIDTH); i = i + 1) mem[i] = 0;
    dao = 0;
  end
  always @(posedge clk) begin
    if (we) mem[addr] <= dai;
    if (rd) dao <= mem[addr];
  end
endmodule
