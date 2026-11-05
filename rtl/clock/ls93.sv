// 74LS93 ripple counter: divide-by-2 (CKA -> QA) and divide-by-8 (CKB ->
// QB, QC, QD), each stage toggling on the falling edge of its clock; R0(1)
// and R0(2) both High clear all outputs.  Clock inputs are fall pulses; each
// stage changes one master clock after its input pulse and emits its edges
// as pulses.  QA feeds CKB internally.
`default_nettype none
module ls93 (
  input  logic clk,       // master clock
  input  logic cka_fall,  // pin 14 falls now
  input  logic r0_1,      // pin 2
  input  logic r0_2,      // pin 3
  output logic qa_rise,   // pin 12
  output logic qa_fall,
  output logic qd_rise,   // pin 11
  output logic qd_fall
);
  // Justification: (reg-a) the four flip-flops and the edge pulses.
  logic       qa_q  = 1'b0;
  logic [2:0] bcd_q = 3'd0;
  logic       qa_r_q = 1'b0, qa_f_q = 1'b0, qd_r_q = 1'b0, qd_f_q = 1'b0;

  logic clr, ckb_fall;
  assign clr      = r0_1 & r0_2;
  assign ckb_fall = qa_f_q;

  always_ff @(posedge clk) begin
    qa_r_q <= 1'b0;
    qa_f_q <= 1'b0;
    qd_r_q <= 1'b0;
    qd_f_q <= 1'b0;
    if (clr) begin
      qa_q   <= 1'b0;
      bcd_q  <= 3'd0;
      qa_f_q <= qa_q;
      qd_f_q <= bcd_q[2];
    end else begin
      if (cka_fall) begin
        qa_q   <= ~qa_q;
        qa_r_q <= ~qa_q;
        qa_f_q <= qa_q;
      end
      if (ckb_fall) begin
        bcd_q  <= bcd_q + 3'd1;
        qd_r_q <= (bcd_q == 3'd3);
        qd_f_q <= (bcd_q == 3'd7);
      end
    end
  end

  assign qa_rise = qa_r_q;
  assign qa_fall = qa_f_q;
  assign qd_rise = qd_r_q;
  assign qd_fall = qd_f_q;
endmodule
`default_nettype wire
