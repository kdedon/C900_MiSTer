// The MiSTer UART on one of the six SCC lines; the others idle (RxD and
// the modem inputs High).  The HPS UART has no DCD: its DSR feeds both.
// sel: 0 U74 B, 1 U74 A, 2 U31 A, 3 U31 B, 4 U36 A, 5 U36 B.  SWAP_U74
// exchanges 0 and 1.  Lines: 0 U74 A, 1 U74 B, 2..5 the LR SCCs, A even.
`default_nettype none
module uart_sel #(
  parameter bit SWAP_U74 = 1'b0
) (
  input  logic       clk,
  input  logic [2:0] sel,
  input  logic       uart_rxd,
  input  logic       uart_cts,
  input  logic       uart_dsr,
  output logic       uart_txd,
  output logic       uart_rts,
  output logic       uart_dtr,
  output logic [5:0] ser_rxd,
  output logic [5:0] ser_cts_n,
  output logic [5:0] ser_dcd_n,
  output logic [5:0] ser_dsr_n,
  input  logic [5:0] ser_txd,
  input  logic [5:0] ser_rts_n,
  input  logic [5:0] ser_dtr_n
);
  // One-hot line select, registered.
  logic [5:0] line_q;
  always_ff @(posedge clk) begin
    unique case (sel)
      3'd0:    line_q <= SWAP_U74 ? 6'b000001 : 6'b000010;
      3'd1:    line_q <= SWAP_U74 ? 6'b000010 : 6'b000001;
      3'd2:    line_q <= 6'b000100;
      3'd3:    line_q <= 6'b001000;
      3'd4:    line_q <= 6'b010000;
      3'd5:    line_q <= 6'b100000;
      default: line_q <= SWAP_U74 ? 6'b000001 : 6'b000010;
    endcase
  end

  assign ser_rxd   = ~line_q | {6{uart_rxd}};
  assign ser_cts_n = ~line_q | {6{uart_cts}};
  assign ser_dcd_n = ~line_q | {6{uart_dsr}};
  assign ser_dsr_n = ~line_q | {6{uart_dsr}};

  assign uart_txd = &(~line_q | ser_txd);
  assign uart_rts = &(~line_q | ser_rts_n);
  assign uart_dtr = &(~line_q | ser_dtr_n);
endmodule
`default_nettype wire
