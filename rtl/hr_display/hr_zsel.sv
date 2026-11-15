// HR card ZSEL U208 (PAL16L8, FN#2, combinational; equations INFERRED,
// not dumped): the bitmap window A23-A17 = 0011111
// with -BMREQ; -WAIT until ZARB reports the access served (SRV); the read
// latches drive BAD while -BDS is low and SRV is set.
`default_nettype none

module hr_zsel (
  input  logic [6:0] a,       // A23-A17
  input  logic       bmreq_n,
  input  logic       brw,     // high = read
  input  logic       bds_n,
  input  logic       srv,     // from ZARB
  output logic       sel,
  output logic       wait_o,
  output logic       adrlat,
  output logic       wclk,
  output logic       rg,
  output logic       re1,
  output logic       re2
);
  logic match, read, drive;
  assign match  = a == 7'h1F && !bmreq_n;
  assign read   = match && brw;
  assign drive  = read && !bds_n && srv;
  assign sel    = match;
  assign wait_o = match && !srv;
  assign adrlat = match;
  assign wclk   = match && !brw;
  assign rg     = read;
  assign re1    = drive;
  assign re2    = drive;
endmodule

`default_nettype wire
