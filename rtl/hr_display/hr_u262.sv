// HR card U262 "SYN" (Signetics 82S105 FPLS, FN#2) with its INFERRED
// program (hr_syn_prog.svh, generated).  All
// fourteen S-R flip-flops load on CK rising, the one-clk pulse ck_rise
// (pin 1, 1.5M = U207 T8 rising).  S and R together hold.  PR/OE is held
// enabled.
`default_nettype none

module hr_u262 (
  input  logic        clk,
  input  logic        ck_rise,
  input  logic [15:0] i,        // I15..I0
  output logic [7:0]  f         // F7..F0
);
  `include "hr_syn_prog.svh"

  // Justification: 82S105 buried state P5-P0 and outputs F7-F0 (reg-a).
  logic [5:0] p;
  logic [7:0] fq;
  logic [5:0] ps, pr, p_d;
  logic [7:0] fs, fr, f_d;

  always_comb begin
    ps = '0; pr = '0; fs = '0; fr = '0;
    for (int k = 0; k < SYN_NTERMS; k++) begin
      if ((i & SYN_IMASK[k]) == SYN_IVAL[k] && (p & SYN_PMASK[k]) == SYN_PVAL[k]) begin
        ps = ps | SYN_PSET[k];
        pr = pr | SYN_PRST[k];
        fs = fs | SYN_FSET[k];
        fr = fr | SYN_FRST[k];
      end
    end
    p_d = (p | (ps & ~pr)) & ~(pr & ~ps);
    f_d = (fq | (fs & ~fr)) & ~(fr & ~fs);
  end

  initial begin
    p  = '0;
    fq = '0;
  end
  always_ff @(posedge clk) begin
    if (ck_rise) begin
      p  <= p_d;
      fq <= f_d;
    end
  end

  assign f = fq;
endmodule

`default_nettype wire
