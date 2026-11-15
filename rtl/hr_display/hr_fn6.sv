// HR card FN#6 shift register array and the FN#1 mono stage.
//
// The fetch row (FN#4) is on the DRAM outputs from the clock its eight
// CAS strobes fall; -OE1 puts bytes 0-3 on MD31-0, -OE2 bytes 4-7, each
// with the lower Z-Bus word on MD15-0 (even byte high).  Plane p (B, G,
// R, I) has an LS374 (U646/648/650/652) on MD12+p, 8+p, 4+p, p, 28+p,
// 24+p, 20+p, 16+p (D8..D1) clocked by SR LAT CLK, and a 74S299
// (U647/...) loaded from it when SR LD (S1) is high at a 24M edge and
// otherwise shifting toward QH', DS0 grounded.  U104 (FN#1) takes the
// four QH' outputs each 24M clock: four mono pixels, I first.
//
// One master clock: 24M (the S299 and U104 clock pins) is the pulse
// ck24_rise; the board glue makes pulses from SR LAT CLK rising and the
// eight CAS strobes asserting.
`default_nettype none

module hr_fn6 (
  input  logic        clk,
  input  logic        ck24_rise,   // 24M: S299 CP and U104 clock
  input  logic        oe1,
  input  logic        oe2,
  input  logic        srld,
  input  logic        srlatclk,
  input  logic [7:0]  cas,
  input  logic [63:0] row_q,     // the fetch row from FN#4
  output logic [3:0]  rgbi,      // QH' of the S299s: I, R, G, B
  output logic [3:0]  u104
);
  // Justification: DRAM outputs held while CAS is low, last SR LAT CLK
  // and CAS levels, LS374s, S299s, U104 (reg-a).
  logic [63:0] dout;
  logic        srlat_q;
  logic [7:0]  cas_q;
  logic [7:0]  lat [4];
  logic [7:0]  sr  [4];
  logic [3:0]  u104_q;

  logic [63:0] dout_n;
  logic [31:0] md_n;
  assign dout_n = (cas == 8'hFF && cas_q != 8'hFF) ? row_q : dout;
  // MD floats unless the eight CAS strobes and an OE are on; SR LAT CLK
  // rises only then.
  always_comb begin
    md_n = '0;
    if (cas == 8'hFF) begin
      if (oe1)      md_n = {dout_n[23:16], dout_n[31:24], dout_n[7:0],   dout_n[15:8]};
      else if (oe2) md_n = {dout_n[55:48], dout_n[63:56], dout_n[39:32], dout_n[47:40]};
    end
  end

  logic [3:0] qh;
  always_comb
    for (int p = 0; p < 4; p++) qh[p] = sr[p][7];

  function automatic logic [7:0] plane(input logic [31:0] m, input int p);
    plane = {m[12+p], m[8+p], m[4+p], m[p], m[28+p], m[24+p], m[20+p], m[16+p]};
  endfunction

  initial begin
    dout = '0; srlat_q = 1'b0; cas_q = '0; u104_q = '0;
    for (int p = 0; p < 4; p++) begin
      lat[p] = '0;
      sr[p]  = '0;
    end
  end
  always_ff @(posedge clk) begin
    cas_q   <= cas;
    srlat_q <= srlatclk;
    dout    <= dout_n;
    for (int p = 0; p < 4; p++)
      if (srlatclk && !srlat_q) lat[p] <= plane(md_n, p);
    if (ck24_rise) begin
      u104_q <= qh;
      for (int p = 0; p < 4; p++)
        sr[p] <= srld ? lat[p] : {sr[p][6:0], 1'b0};
    end
  end

  assign rgbi = qh;
  assign u104 = u104_q;
endmodule

`default_nettype wire
