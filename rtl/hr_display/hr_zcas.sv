// HR card ZCAS U210 (PAL16R8, FN#2; equations INFERRED, not dumped),
// registered on CLK (24M) rising, a one-master-clock
// pulse on ck_rise.  Bit b strobes byte b of the 64-bit row.  A fetch (T8 high)
// strobes all eight outside vertical blank and holds them one clock past
// -RAS through its own outputs.
`default_nettype none

module hr_zcas (
  input  logic       clk,
  input  logic       ck_rise,   // pin 1 CLK (24M), rising-edge pulse
  input  logic       t8,
  input  logic       ras_n,
  input  logic [2:0] la,
  input  logic       lbw,     // high = byte
  input  logic       mux,
  input  logic       vblk_n,
  output logic [7:0] q
);
  // Justification: PAL16R8 output registers (reg-a).
  logic [7:0] r;
  logic [7:0] d;

  always_comb begin
    d = 8'h00;
    if (!ras_n && !mux) begin
      if (t8) d = vblk_n ? 8'hFF : 8'h00;
      else if (lbw) d = 8'h01 << la;
      else d = 8'h03 << {la[2:1], 1'b0};
    end else if (t8 && r == 8'hFF) begin
      d = 8'hFF;
    end
  end

  initial r = '0;
  always_ff @(posedge clk) if (ck_rise) r <= d;
  assign q = r;
endmodule

`default_nettype wire
