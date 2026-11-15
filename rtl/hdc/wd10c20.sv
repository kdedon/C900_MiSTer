// Western Digital WD10C20 data separator / write precompensation
// (WD1003-CMD U101, schematic 68-000057 sheet 4).  No WD10C20 datasheet
// is on file: the ports are the schematic's digital pins (the delay-line,
// VCO, pump, DRUNRC and ADJUST pins are analog and not modelled), the
// behaviour is the WD2010-05 side of the interface (pins pp.68-69, Fig 4
// p.74, timing pp.95-97), INFERRED.
//
// Data pins are `clk`-domain levels.  XTAL is the Y101 10 MHz crystal net,
// taken as one-`clk` edge pulses `xtal_rise`/`xtal_fall`: each is one
// 50 ns step, at which the chip samples its inputs and updates every
// output.  RCLK and WCLK drive the WD2010 and leave as edge-pulse pairs
// `rclk_rise`/`rclk_fall` and `wclk_rise`/`wclk_fall`, high in the `clk`
// in which the clock pin changes.
//
// Read: the VCO runs at the bit rate.  RG low: it follows the reference
// (crystal / 4 = one 200 ns cell).  RG high: a read pulse puts the VCO
// on a half-period start (ideal lock).  RCLK = VCO / 2.  RDATA is the
// read pulse taken at the step (Fig 4 draws a VCO-clocked JK flip-flop;
// not modelled).  DRUN is a 250 ns retriggerable one-shot on read
// pulses (the period is set by the DRUNRC trimpot network; 250 ns is
// the WD2010's nominal).  Inputs are levels taken at each step, so a
// read pulse held for several steps retriggers at each.
// Write: WCLK = crystal / 2 (5 MHz).  WMFM = WDATA gated by BWG.
// EARLY-/LATE- select delay taps a few ns apart, below one step, and
// WPCEN only enables them, so none of the three moves a pulse here.
//
// The chip has no reset pin.  Registers power up at zero; the divider and VCO phases at power-up are OPEN (no datasheet).
`default_nettype none

module wd10c20 (
  input  logic clk,
  input  logic xtal_rise, // XTALIN, Y101 10 MHz
  input  logic xtal_fall,
  // drive side
  input  logic rmfm,      // pin 14, from the 3486 receivers
  output logic wmfm,      // pin 16, to the 3487 drivers
  // WD2010 side
  input  logic rgate,     // pin 4
  input  logic bwg,       // pin 3, WD2010 WG
  input  logic wdata,     // pin 8
  input  logic early_n,   // pin 7
  input  logic late_n,    // pin 6
  input  logic wpcen,     // pin 5
  output logic rdata,     // pin 22
  output logic rclk_rise, // pin 23
  output logic rclk_fall,
  output logic drun,      // pin 12
  output logic wclk_rise, // pin 9
  output logic wclk_fall
);

  localparam logic [2:0] DrunSteps = 3'd5;   // 250 ns

  // Justification: reference divider and VCO phase, one cell = 4 steps (reg-a).
  logic [1:0] ref_q, vco_q;
  // Justification: DRUN one-shot remaining steps (reg-a).
  logic [2:0] drun_q;
  // Justification: output pins, updated at crystal edges (reg-a).
  logic       rdata_q, rclk_q, drun_out_q, wclk_q, wmfm_q;
  // Justification: output clock edge pulses, one `clk` wide (reg-a).
  logic       rclk_rise_q, rclk_fall_q, wclk_rise_q, wclk_fall_q;

  logic       step_c;
  logic [1:0] vco_c;
  logic [2:0] drun_c;

  logic unused_ok;
  assign unused_ok = &{1'b0, early_n, late_n, wpcen};

  assign step_c = xtal_rise | xtal_fall;

  always_comb begin
    drun_c = rmfm ? DrunSteps : drun_q;
    vco_c  = (rmfm && rgate) ? {vco_q[1], 1'b0} : vco_q;
    if (!rgate) vco_c = ref_q;
  end

  initial begin
    ref_q = 2'd0;  vco_q = 2'd0;  drun_q = 3'd0;
  end
  always_ff @(posedge clk) begin
    if (step_c) begin
      ref_q  <= ref_q + 2'd1;
      vco_q  <= vco_c + 2'd1;
      drun_q <= (drun_c != 3'd0) ? drun_c - 3'd1 : 3'd0;
    end
  end

  initial begin
    rclk_rise_q = 1'b0;  rclk_fall_q = 1'b0;  wclk_rise_q = 1'b0;  wclk_fall_q = 1'b0;
  end
  always_ff @(posedge clk) begin
    rclk_rise_q <= step_c & ~vco_c[1] & ~rclk_q;
    rclk_fall_q <= step_c & vco_c[1] & rclk_q;
    wclk_rise_q <= step_c & ~ref_q[1] & ~wclk_q;
    wclk_fall_q <= step_c & ref_q[1] & wclk_q;
  end

  initial begin
    rdata_q = 1'b0;  rclk_q = 1'b0;  drun_out_q = 1'b0;  wclk_q = 1'b0;  wmfm_q = 1'b0;
  end
  always_ff @(posedge clk) begin
    if (step_c) begin
      rdata_q    <= rmfm;
      rclk_q     <= ~vco_c[1];
      drun_out_q <= drun_c != 3'd0;
      wclk_q     <= ~ref_q[1];
      wmfm_q     <= bwg & wdata;
    end
  end

  assign rdata = rdata_q;
  assign rclk_rise = rclk_rise_q;
  assign rclk_fall = rclk_fall_q;
  assign drun  = drun_out_q;
  assign wclk_rise = wclk_rise_q;
  assign wclk_fall = wclk_fall_q;
  assign wmfm  = wmfm_q;

endmodule

`default_nettype wire
