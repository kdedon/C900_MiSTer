// 311075 keyboard interface on the CPU board (U1-U4: LS299 shifter, 2x
// LS74A, LS125).  The LS299 shifts on falling cable-clock edges; the first
// edge after a clear is the keyboard's prelude, the next eight carry the
// byte LSB first, and the ninth completes it: DAV (U2b) sets, the byte is
// presented (QB..QH = PA6..PA0, QA = PC2, the last bit), and the register
// holds until CIO PC3 (KBDCLR) Low clears it and DAV.
//
// Cable lines are open collector.  U3b pulls KBDAT Low while DAV is set,
// and U3a pulls KBCLK Low while U2a (/HLDKBCLK, bit 1 of a write to 0x205,
// cleared by /KBRST) is Low.  The keyboard sends a byte only when it reads
// both lines High, so it waits for the ack instead of losing the byte.
`default_nettype none
module kbdshifter (
  input  logic       clk,
  input  logic       rst_n,       // /KBRST (MRESET)
  input  logic       kbclk,       // cable clock line
  input  logic       kbdat,       // cable data line
  input  logic       kbdclr,      // CIO PC3: Low clears
  input  logic       clk204,      // CN2-1: U2a clock
  input  logic       bad1,        // U2a D
  output logic [6:0] data,        // to CIO PA6:0
  output logic       dav,         // to CIO PA7
  output logic       updown,      // to CIO PC2
  output logic       kbclk_low,   // U3a drives KBCLK Low
  output logic       kbdat_low    // U3b drives KBDAT Low
);
  logic [7:0] reg_q;
  logic [6:0] acc_q;
  logic [3:0] edges_q;
  logic       dav_q, kbclk_q;
  // Justification: (reg-a) U2a, and its clock and D one sample back.
  logic       hld_n_q, clk204_q, bad1_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      reg_q   <= 8'h00;
      acc_q   <= 7'h00;
      edges_q <= 4'd0;
      dav_q   <= 1'b0;
      kbclk_q <= 1'b0;
    end else begin
      kbclk_q <= kbclk;
      if (!kbdclr) begin
        reg_q   <= 8'h00;
        acc_q   <= 7'h00;
        edges_q <= 4'd0;
        dav_q   <= 1'b0;
      end else if (kbclk_q && !kbclk && !dav_q) begin
        if (edges_q == 4'd8) begin
          reg_q   <= {kbdat, acc_q[6:0]};
          dav_q   <= 1'b1;
          acc_q   <= 7'h00;
          edges_q <= 4'd0;
        end else begin
          if (edges_q != 4'd0) acc_q[3'(edges_q - 4'd1)] <= kbdat;
          edges_q <= edges_q + 4'd1;
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    clk204_q <= clk204;
    bad1_q   <= bad1;
    // The bus gives up the write data in the sample /DS rises, so D is
    // taken from the sample before the clock edge.
    if (!rst_n)                     hld_n_q <= 1'b0;
    else if (clk204 && !clk204_q)   hld_n_q <= bad1_q;
  end

  assign data      = reg_q[6:0];
  assign dav       = dav_q;
  assign updown    = reg_q[7];
  assign kbdat_low = dav_q;
  assign kbclk_low = ~hld_n_q;
endmodule
`default_nettype wire
