// NON-STOCK: Z8070 APU on the CN13 connector (sheet 20), off unless enabled.
//
// CN13 carries the CPU's own pins (ahead of the bus buffers), _STOP, _VI,
// _MRESET, IEI and IEA.  With no APU a link joins IEI to IEA (CIO U70's
// IEI), so the APU sits first on the daisy chain; removing the link puts
// it between them.  Disabled, every output is released and IEA follows IEI.
//
// Clocks: CLK.I is the CPU's CLK; CLK.D comes in as a rise pulse.
//
// /BSY drives /STOP, and /WAIT while the status latched at /AS is an EPU
// data cycle (1010, 1011, 1110) up to its /DS rise: a store's data cycles
// follow word 2 at once, before any STOP sample.  CN13 has no _WAIT pin;
// the card reaches /WAIT on the expansion bus.
//
//   CPU /AS /DS ST SN ----+------------------+
//   AD (as the CPU reads) |   +----------+   |  /BSY ---------------> /STOP
//                         +-->|  Z8070   |---+--[EPU data cycle]----> /WAIT
//   CPU CLK -> CLK.I -------->|          |------ /INT --------------> /VI
//   CLK.D ------------------->|          |------ IEO -----+
//   IEI ----+---------------->|          |                +--[link]-> IEA
//           +---------------------------------------------+
`default_nettype none
module z8070_epu (
  input  logic        clk,
  input  logic        mreset_n,
  input  logic        enable,
  input  logic        clki_rise,      // CPU CLK edges
  input  logic        clki_fall,
  input  logic        clkd_rise,
  input  logic [15:0] ad_bus,
  input  logic        as_n,
  input  logic        ds_n,
  input  logic        r_w,
  input  logic        b_w,
  input  logic        n_s,
  input  logic [6:0]  sn,
  input  logic [3:0]  st,
  input  logic        busack_n,
  input  logic        iei,
  output logic [15:0] ad_out,
  output logic [15:0] ad_oe,
  output logic        stop_n,
  output logic        wait_n,
  output logic        int_n,
  output logic        iea
);
  logic [15:0] fpu_ad_out;
  logic        fpu_ad_drive, bsy_n, fpu_int_n, fpu_ieo;

  z8070_fpu u_fpu (
    .clk      (clk),
    .clki_rise(clki_rise),
    .clki_fall(clki_fall),
    .clkd_rise(clkd_rise),
    .reset_n  (mreset_n & enable),
    .ad_in    (ad_bus),
    .ad_out   (fpu_ad_out),
    .ad_drive (fpu_ad_drive),
    .as_n     (as_n),
    .ds_n     (ds_n),
    .r_w      (r_w),
    .b_w      (b_w),
    .n_s      (n_s),
    .st       (st),
    .sn       (sn),
    .busack_n (busack_n),
    .abort_n  (1'b1),
    .bsy_n    (bsy_n),
    .int_n    (fpu_int_n),
    .iei      (iei),
    .ieo      (fpu_ieo),
    .id       (2'b00),
    .opt      (2'b11)
  );

  // Justification: (reg-a) the EPU data cycle the /WAIT gate covers: status
  // through a latch open while /AS is Low, held to the /DS rise.
  logic ds_q, epu_cyc_q, epu_cyc;
  always_ff @(posedge clk) begin
    ds_q <= ds_n;
    if (!as_n || (ds_n && !ds_q)) epu_cyc_q <= !as_n && epu_cyc;
  end
  assign epu_cyc = !as_n ? (st == 4'b1010 || st == 4'b1011 || st == 4'b1110) : epu_cyc_q;

  assign ad_out = fpu_ad_out;
  assign ad_oe  = {16{enable & fpu_ad_drive}};
  assign stop_n = !enable || bsy_n;
  assign wait_n = !enable || bsy_n || !epu_cyc;
  assign int_n  = !enable || fpu_int_n;
  assign iea    = enable ? fpu_ieo : iei;
endmodule
`default_nettype wire
