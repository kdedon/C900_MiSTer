// Event crossing (two-phase pulse synchroniser): a one-cycle pulse in the
// source domain flips a toggle register; the toggle crosses through a
// c900_sync2 and any edge of it is a one-cycle pulse in the destination
// domain.  Events must be at least ~4 destination cycles apart.
`default_nettype none
module lr_cdc_event (
  input  logic src_clk,
  input  logic src_rst_n,
  input  logic src_pulse,
  input  logic dst_clk,
  input  logic dst_rst_n,
  output logic dst_pulse
);
  // Justification: (reg-c) the crossing source, a register by contract.
  logic tgl_q;
  always_ff @(posedge src_clk) begin
    if (!src_rst_n)     tgl_q <= 1'b0;
    else if (src_pulse) tgl_q <= ~tgl_q;
  end

  logic tgl_s, tgl_s_q;
  c900_sync2 u_sync (.clk(dst_clk), .d(tgl_q), .q(tgl_s));

  always_ff @(posedge dst_clk) begin
    if (!dst_rst_n) tgl_s_q <= 1'b0;
    else            tgl_s_q <= tgl_s;
  end
  assign dst_pulse = tgl_s ^ tgl_s_q;
endmodule
`default_nettype wire
