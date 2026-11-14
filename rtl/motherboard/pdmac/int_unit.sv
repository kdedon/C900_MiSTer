// 8716 interrupt unit: /VI (VI state, sheet 7), /IREQ (set by _IO_6 with
// /DS Low, cleared by the IREQ state; sheets 3, 4, 7), IEO, and the vector
// on AD7-AD0 while IEI is High and /IACK and /DS are Low (sheet 3).
//
// INFERRED, no 8716 document gives it: an end-of-block term on pin 29.  An enable is set by PCSS 0xFF
// (Power_On) and cleared by 0x7F (Reset) and /RESET.  While it is set, the
// end of a continuous (256-word) block pulls pin 29 Low; single-step words
// never do.  The term is released when LD0 falls, and by 0x7F, 0x9F, an
// _IO_6 write with zero data and /RESET.
//
// Same-sample order: /RESET edge, then the PCSS command and the LD0 latch,
// then a block end by B-side pop, then _IO_6, then the /RESET level, then
// a block end by memory commit, then the acknowledge.  The /DS fall of an acknowledge releases /VI; the vector stays
// on AD until /DS rises (the CPU reads it at the end of the acknowledge).
`default_nettype none

module int_unit (
  input  logic       clk,
  input  logic       chip_rst,
  input  logic       reset_hold,
  input  logic       cmd_stb,
  input  logic [7:0] cmd,
  input  logic       ld0_latch,
  input  logic       blk_done,
  input  logic       blk_commit,
  input  logic       blk_sector,
  input  logic       io6,
  input  logic       ds_n_in,
  input  logic       iack_n,
  input  logic       iei,
  input  logic [7:0] ad_lo,
  output logic       vi_n,
  output logic       ieo_n,
  output logic       ireq_n,
  output logic       vec_oe
);

  localparam logic [7:0] CMD_IRQ_HIGH = 8'h9F, CMD_VI_GND = 8'hBF,
                         CMD_POWERON = 8'hFF, CMD_RESET = 8'h7F;

  // Justification: VI and IREQ states (reg-a); /DS and _IO_6 edge
  // detection (reg-a); vi_rel_q keeps the vector driven from the release
  // until /DS rises (reg-a).
  logic vi_q, ireq_q, ds_n_q, io6ds_q, vi_rel_q;
  // Justification: INFERRED end-of-block enable and term (reg-a).
  logic blk_en_q, blk_ireq_q;

  logic vi_pre, ack, vec, vi_rel, io6ds, ireq_d;
  logic io6_zero, blk_en_mid, blk_en_d, blk_ireq_d;

  assign vi_pre = (vi_q & ~chip_rst) | (cmd_stb & (cmd == CMD_VI_GND));
  assign ack    = ~iack_n & ~ds_n_in & iei;
  assign vec    = ack & vi_pre;
  assign vi_rel = vec & ds_n_q;
  assign io6ds  = io6 & ~ds_n_in;

  assign io6_zero = io6ds & ~io6ds_q & (ad_lo == 8'h00);

  always_comb begin
    ireq_d = ireq_q & ~chip_rst & ~(cmd_stb & (cmd == CMD_IRQ_HIGH));
    // AD7:0 == 0 clears instead of setting (O-3).
    if (io6ds & ~io6ds_q) ireq_d = (ad_lo != 8'h00);
  end

  always_comb begin
    blk_en_mid = (blk_en_q & ~chip_rst) | (cmd_stb & (cmd == CMD_POWERON));
    if (cmd_stb && cmd == CMD_RESET) blk_en_mid = 1'b0;
    blk_en_d = blk_en_mid & ~reset_hold;

    blk_ireq_d = blk_ireq_q & ~chip_rst;
    if (cmd_stb && (cmd == CMD_RESET || cmd == CMD_IRQ_HIGH)) blk_ireq_d = 1'b0;
    if (ld0_latch) blk_ireq_d = 1'b0;
    if (blk_done && !blk_commit && blk_sector && blk_en_mid) blk_ireq_d = 1'b1;
    if (io6_zero || reset_hold) blk_ireq_d = 1'b0;
    if (blk_commit && blk_sector && blk_en_d) blk_ireq_d = 1'b1;
  end

  initial begin
    blk_en_q   = 1'b0;
    blk_ireq_q = 1'b0;
  end
  always_ff @(posedge clk) begin
    blk_en_q   <= blk_en_d;
    blk_ireq_q <= blk_ireq_d;
  end

  initial begin
    vi_q = 1'b0;
  end
  always_ff @(posedge clk) begin
    vi_q <= vi_pre & ~vi_rel;
  end

  initial begin
    vi_rel_q = 1'b0;
  end
  always_ff @(posedge clk) begin
    vi_rel_q <= vi_rel | (vi_rel_q & ~ds_n_in);
  end

  initial begin
    ireq_q = 1'b0;
  end
  always_ff @(posedge clk) begin
    ireq_q <= ireq_d;
  end

  initial begin
    ds_n_q  = 1'b1;
    io6ds_q = 1'b0;
  end
  always_ff @(posedge clk) begin
    ds_n_q  <= ds_n_in;
    io6ds_q <= io6ds;
  end

  assign vec_oe = ack & (vi_q | vi_rel_q);
  assign vi_n   = ~(vi_q & iei);
  assign ieo_n  = ~iei | vi_q;
  assign ireq_n = ~(ireq_q | blk_ireq_q);

endmodule

`default_nettype wire
