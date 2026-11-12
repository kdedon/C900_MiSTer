// SN75160 octal GPIB data transceiver (U67, sheet 10).  Non-inverting;
// TE High sends terminal to bus, Low receives.  PE Low makes the bus
// drivers open-collector (the board straps PE to GND).  Levels are
// electrical: 1 = High.
`default_nettype none
module sn75160 (
  input  logic       te,
  input  logic       pe,
  input  logic [7:0] term_in,    // terminal pins 12-19 (undriven read High)
  input  logic [7:0] bus_in,     // resolved bus, pins 2-9
  output logic [7:0] bus_pull,   // bus lines pulled Low
  output logic [7:0] bus_drv_hi, // bus lines driven High (PE High only)
  output logic [7:0] term_out,
  output logic       term_oe
);
  assign bus_pull   = te ? ~term_in : 8'h00;
  assign bus_drv_hi = (te && pe) ? term_in : 8'h00;
  assign term_out   = bus_in;
  assign term_oe    = ~te;
endmodule
`default_nettype wire
