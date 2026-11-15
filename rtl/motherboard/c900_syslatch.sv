// C900 single-step and latch logic (motherboard sheet 6), at its pins:
//
//   U61 NOR(_I-O2, _BDS, GND)   -> SS_WR
//   U63 NAND(SS_WR, A1)         -> STEP_CLK    U63 NAND(SS_WR, A2) -> REN_CLK
//   U11 AND(_MRESET, _NVIACK)   -> STEP_CLR
//   U64 LS74 D=VCC  CLK=STEP_CLK CLR=STEP_CLR -> STEP
//   U64 LS74 D=BAD8 CLK=REN_CLK  CLR=_MRESET  -> REN (IEEE-488 remote enable)
//   U61 NOR(_BAS, CLK, _IF1)    -> NVI_CLK
//   U62 LS74 D=/Q1 CLK=NVI_CLK CLR=STEP -> Q1
//   U62 LS74 D=Q1  CLK=NVI_CLK CLR=STEP -> /Q2 = _NVI
//
// An access to 0x0200-0x02FF with A1 set arms STEP as /DS rises; the second
// first-word fetch after it lowers _NVI and the acknowledge clears STEP.
// A write with A2 set latches BAD8 (a byte's bit 0) into REN.  The gate
// outputs are sampled on the master clock; a flip-flop takes D in the
// sample its clock rises.
`default_nettype none
module c900_syslatch (
  input  logic clk,           // master clock
  input  logic io2_n,         // U57 /I-O2
  input  logic bds_n,
  input  logic a1,            // U56 latched address
  input  logic a2,
  input  logic bad8,
  input  logic mreset_n,
  input  logic nviack_n,      // U58 status 0110
  input  logic bas_n,
  input  logic clk_pin_rise,  // board CLK net (U13) edges
  input  logic clk_pin_fall,
  input  logic if1_n,         // U58 status 1101
  output logic step,
  output logic ren,
  output logic nvi_n
);
  // Justification: (reg-a) the four LS74s, the CLK net level, and the three
  // flip-flop clock nets one sample back for edge detection.  The clock
  // nets power up at their idle level; _MRESET, low at power-on, holds
  // the flip-flops clear in any case.
  logic step_q, ren_q, q1_q, q2_q, ck_q;
  logic step_clk_q = 1'b1, ren_clk_q = 1'b1, nvi_clk_q = 1'b0;

  logic ck, ss_wr, step_clk, ren_clk, nvi_clk, step_d;
  assign ck       = clk_pin_rise | (ck_q & ~clk_pin_fall);
  assign ss_wr    = ~io2_n & ~bds_n;
  assign step_clk = ~(ss_wr & a1);
  assign ren_clk  = ~(ss_wr & a2);
  assign nvi_clk  = ~(bas_n | ck | if1_n);
  assign step_d   = (mreset_n & nviack_n) & (step_q | (step_clk & ~step_clk_q));

  always_ff @(posedge clk) begin
    ck_q       <= ck;
    step_clk_q <= step_clk;
    ren_clk_q  <= ren_clk;
    nvi_clk_q  <= nvi_clk;
  end

  always_ff @(posedge clk) step_q <= step_d;

  always_ff @(posedge clk) begin
    if (!mreset_n)                   ren_q <= 1'b0;
    else if (ren_clk && !ren_clk_q)  ren_q <= bad8;
  end

  always_ff @(posedge clk) begin
    if (!step_d)                     {q1_q, q2_q} <= 2'b00;
    else if (nvi_clk && !nvi_clk_q)  {q1_q, q2_q} <= {~q1_q, q1_q};
  end

  assign step  = step_q;
  assign ren   = ren_q;
  assign nvi_n = ~q2_q;
endmodule
`default_nettype wire
