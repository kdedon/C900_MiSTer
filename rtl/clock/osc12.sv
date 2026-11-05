// Y1, the CPU board's 12 MHz oscillator (sheet 2), on the 48 MHz master
// clock: mod-4 phase counter, rises at phase 2, falls at phase 0; each edge
// is a one-master-clock pulse.
`default_nettype none
module osc12 (
  input  logic clk,      // 48 MHz master clock
  output logic ck_rise,  // Y1 rises now
  output logic ck_fall   // Y1 falls now
);
  // Justification: (reg-a) phase counter and the two edge pulses.
  logic [1:0] ph_q    = 2'd0;
  logic       rise_q  = 1'b0;
  logic       fall_q  = 1'b0;
  always_ff @(posedge clk) begin
    ph_q   <= ph_q + 2'd1;
    rise_q <= (ph_q == 2'd1);
    fall_q <= (ph_q == 2'd3);
  end
  assign ck_rise = rise_q;
  assign ck_fall = fall_q;
endmodule
`default_nettype wire
