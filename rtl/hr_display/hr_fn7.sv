// HR card FN#7 mouse interface: U755 (decode, buttons, MCLK), U754
// (74LS374 sampling each quadrature line and its own previous sample on
// MCLK), U756/U757 (axis PAL20X8s, also clocked by MCLK).  One master
// clock; the board glue turns MCLK rising into a one-master-clock pulse.
`default_nettype none

module hr_fn7 (
  input  logic        clk,
  input  logic        b1_n, b2_n, b3_n,   // J2 buttons
  input  logic        xa, xb, ya, yb,     // J2 quadrature
  input  logic        io4_n,
  input  logic        a4, a2, a1,
  input  logic        zclk,
  input  logic        brw,
  input  logic        bds_n,
  input  logic        mc,
  output logic [15:0] bad,
  output logic        drive,
  output logic        selw_n
);
  logic selx_n, sely_n, selz_n, bad13, bad14, bad15, mclk;
  hr_u755 u755 (.b1_n, .b2_n, .b3_n, .io4_n, .a4, .a1, .zclk, .brw, .bds_n,
    .selx_n, .selz_n, .selw_n, .bad13, .bad14, .bad15, .mclk, .sely_n);

  // Justification: last MCLK level for the edge pulse, U754 flip-flops
  // (reg-a).
  logic       mclk_q;
  logic [7:0] u754;
  logic       mclk_rise;
  assign mclk_rise = mclk && !mclk_q;

  initial begin
    mclk_q = 1'b0; u754 = '0;
  end
  always_ff @(posedge clk) begin
    mclk_q <= mclk;
    if (mclk_rise) u754 <= {xa, u754[7], xb, u754[5], ya, u754[3], yb, u754[1]};
  end

  logic [9:0] xbad, ybad;
  logic       xdrv, ydrv;
  hr_pal20x8 #(.Y_AXIS(1'b0)) u756 (.clk, .mclk_rise, .a_now(u754[7]), .a_prev(u754[6]),
    .b_now(u754[5]), .b_prev(u754[4]), .mc, .a2, .sel_n(selx_n), .bad(xbad), .drive(xdrv));
  hr_pal20x8 #(.Y_AXIS(1'b1)) u757 (.clk, .mclk_rise, .a_now(u754[3]), .a_prev(u754[2]),
    .b_now(u754[1]), .b_prev(u754[0]), .mc, .a2, .sel_n(sely_n), .bad(ybad), .drive(ydrv));

  wire unused = selz_n;
  assign drive = xdrv || ydrv;
  assign bad   = drive ? {bad15, bad14, bad13, 3'b000, xdrv ? xbad : ybad} : 16'h0000;
endmodule

`default_nettype wire
