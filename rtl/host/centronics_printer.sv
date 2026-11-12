// A period dot-matrix printer on CN5 (Epson MX-80 class interface):
// latches the data on the /STROBE falling edge and raises BUSY, hands the
// byte on, then gives a 5 us /ACK and drops BUSY at its end.  BUSY stays
// High until the byte is taken, as when the printer's buffer is full.
// Not attached, every line it drives floats High (the board pull-ups).
`default_nettype none
module centronics_printer #(
  parameter int CLK_HZ    = 48_000_000,
  parameter int ACCEPT_US = 100,        // /STROBE fall to /ACK, at least
  parameter int ACK_US    = 5
) (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       attached,
  input  logic [7:0] data,
  input  logic       strobe_n,
  output logic       ack_n,
  output logic       busy,
  output logic       byte_valid,
  output logic [7:0] byte_data,
  input  logic       byte_ready
);
  localparam int ACCEPT_CLK = CLK_HZ / 1_000_000 * ACCEPT_US;
  localparam int ACK_CLK    = CLK_HZ / 1_000_000 * ACK_US;
  localparam int TW         = $clog2(ACCEPT_CLK + 1);

  typedef enum logic [1:0] {StIdle, StTake, StAck} st_e;
  st_e          st_q;
  logic         strobe_q;
  logic [TW-1:0] timer_q;

  always_ff @(posedge clk) begin
    if (!rst_n || !attached) begin
      st_q       <= StIdle;
      strobe_q   <= 1'b1;
      byte_valid <= 1'b0;
      timer_q    <= '0;
    end else begin
      strobe_q <= strobe_n;
      if (timer_q != '0) timer_q <= timer_q - 1'b1;
      unique case (st_q)
        StIdle: if (strobe_q && !strobe_n) begin
          byte_data  <= data;
          byte_valid <= 1'b1;
          timer_q    <= TW'(ACCEPT_CLK);
          st_q       <= StTake;
        end
        StTake: begin
          if (byte_valid && byte_ready) byte_valid <= 1'b0;
          if (!byte_valid && timer_q == '0) begin
            timer_q <= TW'(ACK_CLK);
            st_q    <= StAck;
          end
        end
        StAck: if (timer_q == '0) st_q <= StIdle;
        default: st_q <= StIdle;
      endcase
    end
  end

  assign busy  = !attached || st_q != StIdle;
  assign ack_n = !attached || st_q != StAck;
endmodule
`default_nettype wire
