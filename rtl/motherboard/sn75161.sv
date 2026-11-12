// SN75161 octal GPIB management/handshake transceiver (U68, sheet 10).
// Non-inverting; levels electrical (1 = High).  Line order in every
// vector: {SRQ, ATN, EOI, DAV, NRFD, NDAC, IFC, REN} = [7:0].
//
// Direction (T = terminal to bus, R = bus to terminal):
//   DC Low: ATN REN IFC T, SRQ R.   DC High: the reverse.
//   TE High: DAV T, NDAC NRFD R.    TE Low: the reverse.
//   EOI T when (TE High and bus ATN High) or (DC Low and bus ATN Low).
`default_nettype none
module sn75161 (
  input  logic       te,
  input  logic       dc,
  input  logic [7:0] term_in,   // terminal pins 2-9 (undriven read High)
  input  logic [7:0] bus_in,    // resolved bus, pins 12-19
  output logic [7:0] bus_pull,  // bus lines pulled Low
  output logic [7:0] term_out,
  output logic [7:0] term_oe
);
  localparam int REN = 0, IFC = 1, NDAC = 2, NRFD = 3, DAV = 4, EOI = 5, ATN = 6, SRQ = 7;

  logic [7:0] tx;
  logic       atn_bus;

  // ATN's direction does not depend on ATN, so the EOI direction can use
  // the bus ATN including this chip's own drive.
  assign atn_bus = bus_in[ATN] & ~(~dc & ~term_in[ATN]);

  always_comb begin
    tx       = 8'h00;
    tx[ATN]  = ~dc;
    tx[REN]  = ~dc;
    tx[IFC]  = ~dc;
    tx[SRQ]  = dc;
    tx[DAV]  = te;
    tx[NDAC] = ~te;
    tx[NRFD] = ~te;
    tx[EOI]  = (te & atn_bus) | (~dc & ~atn_bus);
  end

  assign bus_pull = tx & ~term_in;
  assign term_out = bus_in;
  assign term_oe  = ~tx;
endmodule
`default_nettype wire
