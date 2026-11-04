module probe (
  input  logic       clk,
  input  logic [3:0] va, vb, vc, vd, ve,
  input  logic [1:0] ra, rb, rc, rd, re,
  output logic       ya, yb, yc, yd, ye
);
  logic a, b, c, d, e;
  logic [1:0] ix;
  always_comb begin
    a = 1'b0; b = 1'b0; c = 1'b0; d = 1'b0; e = 1'b0;
    for (int k = 3; k >= 0; k--) begin
      if (va[2'(ra + k)]) a = 1'b1;
      if (vb[rb + 2'(k)]) b = 1'b1;
      if (vc[int'(rc) + k]) c = 1'b1;
      if (vd[2'(int'(rd))]) d = 1'b1;
      ix = re + k[1:0];
      if (ve[ix]) e = 1'b1;
    end
  end
  always_ff @(posedge clk) begin ya <= a; yb <= b; yc <= c; yd <= d; ye <= e; end
endmodule
