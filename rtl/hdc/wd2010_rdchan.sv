// WD2010-05 read channel: synchronizer, AM detect, MFM decoder,
// serial to parallel (datasheet Figure 1; "MFM Encoding and Decoding",
// "Address Mark (AM) Detection", p.71; Read Data Timing, p.95).
//
// RCLK (pin 39) is the separator's VCO / 2: each half period is one MFM
// cell window, and RD (pin 37) pulses inside the window of a 1 cell.
// RCLK arrives as edge pulses and RD is sampled by the fabric clock; a
// rising RD sample marks the current window, every RCLK edge pulse closes
// it and shifts the window's bit into a 16-cell register.  With `am_en` set, the 16 cells
// A1 with the missing clock (0100 0100 1000 1001) set byte alignment
// and pulse `am`.  From then on every 16 cells give one byte (the data
// cells are the second of each clock/data pair).  `clr` (RG low or the
// controller restarting a search) drops the alignment.
`default_nettype none

module wd2010_rdchan (
  input  logic       clk,
  input  logic       rclk_rise,
  input  logic       rclk_fall,
  input  logic       rd,
  input  logic       clr,
  input  logic       am_en,
  output logic       am,        // A1 found this sample
  output logic       byte_v,    // byte complete this sample
  output logic [7:0] byte_q
);

  localparam logic [15:0] A1_CELLS = 16'h4489;

  // Justification: RD edge detection (reg-a).
  logic        rd_q;
  // Justification: a pulse seen in the current window (reg-a).
  logic        seen_q;
  // Justification: last 16 cells, alignment, cell count in the byte (reg-a).
  logic [14:0] cells_q;
  logic        aligned_q;
  logic [3:0]  cnt_q;
  // Justification: the assembled byte (reg-a).
  logic [7:0]  byte_r;
  logic        am_r, bv_r;

  logic        edge_c, rise_c;
  logic [15:0] cells_n;

  assign edge_c  = rclk_rise | rclk_fall;
  assign rise_c  = rd & ~rd_q;
  assign cells_n = {cells_q[14:0], seen_q | rise_c};

  initial begin
    rd_q = 1'b0;  seen_q = 1'b0;
    cells_q = 15'h0000;  aligned_q = 1'b0;  cnt_q = 4'd0;
    byte_r = 8'h00;  am_r = 1'b0;  bv_r = 1'b0;
  end
  always_ff @(posedge clk) begin
    rd_q   <= rd;
    am_r   <= 1'b0;
    bv_r   <= 1'b0;
    if (edge_c) begin
      seen_q  <= 1'b0;
      cells_q <= cells_n[14:0];
      if (clr) begin
        aligned_q <= 1'b0;
      end else if (!aligned_q) begin
        if (am_en && cells_n == A1_CELLS) begin
          aligned_q <= 1'b1;
          cnt_q     <= 4'd0;
          am_r      <= 1'b1;
        end
      end else begin
        cnt_q <= cnt_q + 4'd1;
        if (cnt_q == 4'd15) begin
          byte_r <= {cells_n[14], cells_n[12], cells_n[10], cells_n[8],
                     cells_n[6],  cells_n[4],  cells_n[2],  cells_n[0]};
          bv_r   <= 1'b1;
        end
      end
    end else begin
      if (rise_c) seen_q <= 1'b1;
      if (clr)    aligned_q <= 1'b0;
    end
  end

  assign am     = am_r;
  assign byte_v = bv_r;
  assign byte_q = byte_r;

endmodule

`default_nettype wire
