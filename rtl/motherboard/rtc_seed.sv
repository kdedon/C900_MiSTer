// NON-STOCK: stands in for U16's battery.  While the board is held in
// reset (the CIO cannot drive Port B or PC1 then) it writes the HPS time
// into the RTC through the chip's own pins: select,
// STOP, the 13 time registers, the reset register, STOP off, deselect.
// It runs once, at the first board reset after the HPS has sent the time;
// a reset that ends mid-sequence aborts it and the next reset retries.
//
// rtc is hps_io's RTC: BCD seconds, minutes, hours (24 h), day, month,
// year, then the weekday 0-6 (Sunday 0); bit 64 toggles on each update.
`default_nettype none
module rtc_seed (
  input  logic        clk,
  input  logic        mreset_n,    // board -MRESET
  input  logic [64:0] rtc,
  output logic        active,      // the seed drives the RTC pins
  output logic [3:0]  d,
  output logic        cs1,
  output logic        stop,
  output logic        addr_write,
  output logic        write
);
  // One register write = 8 phases of 4 clocks: address on D, ADDRESS WRITE
  // high, low, data on D, WRITE high, low, two idle.  Writes 0-12 are the
  // time registers, 13 the reset register; write 14 drops STOP, 15
  // deselects.
  localparam int PH_W = 2;  // log2 clocks per phase

  // Justification: (reg-a) update toggle seen, done flag, sequence counter.
  logic       tog_q = 1'b0, have_q = 1'b0, done_q = 1'b0;
  logic [4+3+PH_W-1:0] seq_q;   // {write index, phase, clock}
  logic       run;

  logic [3:0] widx;
  logic [2:0] ph;
  assign widx = seq_q[$high(seq_q) -: 4];
  assign ph   = seq_q[PH_W +: 3];
  assign run  = !mreset_n && have_q && !done_q;

  always_ff @(posedge clk) begin
    tog_q <= rtc[64];
    if (rtc[64] != tog_q) have_q <= 1'b1;
  end

  always_ff @(posedge clk) begin
    if (!run) seq_q <= '0;
    else      seq_q <= seq_q + 1'b1;
    if (run && &seq_q) done_q <= 1'b1;
  end

  // The register file in chip order: S1 S10 MI1 MI10 H1 H10 W D1 D10 MO1
  // MO10 Y1 Y10 (24-hour mode, Gregorian leap selection), then reset.
  logic [3:0] val;
  always_comb begin
    unique case (widx)
      4'd0:  val = rtc[3:0];
      4'd1:  val = {1'b0, rtc[6:4]};
      4'd2:  val = rtc[11:8];
      4'd3:  val = {1'b0, rtc[14:12]};
      4'd4:  val = rtc[19:16];
      4'd5:  val = {2'b10, rtc[21:20]};
      4'd6:  val = {1'b0, rtc[50:48]};
      4'd7:  val = rtc[27:24];
      4'd8:  val = {2'b00, rtc[29:28]};
      4'd9:  val = rtc[35:32];
      4'd10: val = {3'b000, rtc[36]};
      4'd11: val = rtc[43:40];
      4'd12: val = rtc[47:44];
      default: val = 4'h0;
    endcase
  end

  logic regw;
  assign regw       = widx <= 4'd13;
  assign active     = run;
  assign cs1        = run && widx != 4'd15;
  assign stop       = run && widx <= 4'd13;
  assign addr_write = run && regw && ph == 3'd1;
  assign write      = run && regw && ph == 3'd4;
  assign d          = (ph <= 3'd2) ? widx : val;

  logic unused_ok;
  assign unused_ok = &{1'b0, rtc[63:51], rtc[39:37], rtc[31:30], rtc[23:22], rtc[15], rtc[7]};
endmodule
`default_nettype wire
