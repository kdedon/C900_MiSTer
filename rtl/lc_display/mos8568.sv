// MOS 8568 VDC (PN 315092-01): the vendored 8563/8568 core in 8568 mode
// plus the 8568's INTR pin.
//   INTR [VDCDS p.40]: open drain, driven low when Update Ready (status b7)
//   goes 0 to 1; released while Update Ready is 0 or when the CPU reads the
//   status register.  intr_n = 0 is the pin pulled low.
//   INIT [VDCDS p.40]: active low, clears the control latches (the core's
//   reset: registers, scan counters, RAM interface).
//   RES [VDCDS p.40]: resets the scan counters only (the core's init).
// clk is twice DCLK; cs is one clk per bus access (the core's bus strobe).
`default_nettype none
module mos8568 (
  input  logic        clk,
  input  logic        init_n,
  input  logic        res,
  input  logic        cs,
  input  logic        rs,
  input  logic        we,
  input  logic [7:0]  d_in,
  output logic [7:0]  d_out,
  output logic        intr_n,
  input  logic        lpen,
  output logic        vsync,
  output logic        hsync,
  output logic [3:0]  rgbi,
  output logic        pixel_ce,
  output logic        active_h,
  output logic        active_v,
  // RAM pins
  output logic        ram_rd,
  output logic        ram_we,
  output logic [15:0] ram_addr,
  output logic [7:0]  ram_di,
  input  logic [7:0]  ram_do
);
  logic busy;

  vdc_top #(
    .RAM_ADDR_BITS(16)
  ) u_vdc (
    .version     (1'b1),
    .ram64k      (1'b1),
    .initRam     (1'b0),
    .debug       (1'b0),
    .clk         (clk),
    .enableBus   (cs),
    .reset       (!init_n),
    .init        (res),
    .cs          (cs),
    .rs          (rs),
    .we          (we),
    .db_in       (d_in),
    .db_out      (d_out),
    .lp_n        (lpen),       // the core latches on its rise, as LPEN
    .vsync       (vsync),
    .hsync       (hsync),
    .pixel_ce    (pixel_ce),
    .active_h    (active_h),
    .active_v    (active_v),
    .rgbi        (rgbi),
    .mem_rd      (ram_rd),
    .mem_we      (ram_we),
    .mem_addr    (ram_addr),
    .mem_di      (ram_di),
    .mem_do      (ram_do),
    .status_busy (busy)
  );

  // Justification: Update Ready last clk and the INTR latch (reg-a).
  logic ready_q = 1'b0, intr_q = 1'b0;
  always_ff @(posedge clk) begin
    ready_q <= !busy;
    if (!init_n || busy || (cs && !we && !rs)) intr_q <= 1'b0;
    else if (!ready_q)                          intr_q <= 1'b1;
  end
  assign intr_n = !intr_q;
endmodule
`default_nettype wire
