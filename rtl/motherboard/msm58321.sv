// OKI MSM58321 real-time clock (C900 U16), at its pins.
//
//   XT -> 15-stage divider -> 1 Hz -> sec /10 /6 -> min /10 /6 -> hour
//   /12 or /24 -> day of week /7, day /10 /3 (month length, leap year)
//   -> month /12 -> year /10 /10
//
// The counters are the registers; a write lands in the counter at once.
// CS1 low is data-holding mode: the chip counts and ignores its inputs.
// The pins are sampled on the master clock.  INFERRED: ADDRESS WRITE and
// WRITE transparent while high (no setup before the rise, hold after the
// fall), CS1 gating STOP, STOP halting the divider, the reset register
// clearing all 15 stages, the 14-edge BUSY window, out-of-range digits
// counting on without carry, 31 days for an unknown month, and the
// standard signal's 1024 Hz on divider stage 5 and 1 sec on stage 15.
// OPEN: the 1 min and 1 hour standard signals (read 0) and TEST.
`default_nettype none
module msm58321 (
  input  logic       clk,         // master clock
  input  logic       cs1,         // pin 13, power-fail select
  input  logic       cs2,         // pin 1
  input  logic       read,        // pin 3
  input  logic       write,       // pin 2
  input  logic       addr_write,  // pin 9
  input  logic       stop,        // pin 11
  input  logic       test,        // pin 12
  input  logic       xt_rise,     // pin 14 rises (32.768 kHz)
  input  logic [3:0] d_in,        // pins 4-7, the bus level
  output logic [3:0] d_out,
  output logic       d_oe,
  output logic       busy_n       // pin 10, open drain
);
  localparam logic [3:0] A_H10 = 4'h5, A_RST = 4'hD;
  localparam logic [14:0] BUSY_AT = 15'd32754;  // 14 XT edges before the carry

  // Justification: (reg-a) the chip's counters, address latch and divider.
  logic [3:0]  s1_q, mi1_q, h1_q, d1_q, mo1_q, y1_q, y10_q;
  logic [2:0]  s10_q, mi10_q, w_q;
  logic [3:0]  h10_q;   // 24/12, PM/AM, tens
  logic [3:0]  d10_q;   // leap selection, tens
  logic        mo10_q;
  logic [3:0]  addr_q;
  logic [14:0] div_q;

  logic        sel, aw_on, wr_on, xt_go, tick;
  logic [3:0]  addr_w;
  logic [14:0] div_w;

  assign sel     = cs1 & cs2;
  assign aw_on   = sel & addr_write;
  assign wr_on   = sel & write;
  assign addr_w  = aw_on ? d_in : addr_q;
  assign xt_go   = xt_rise & ~(stop & cs1);
  assign div_w   = (wr_on && addr_w == A_RST) ? 15'd0 : div_q;
  assign tick    = xt_go && div_w == 15'h7FFF;

  // ---- write, then the 1 Hz carry through the cascade ----------------------
  logic [3:0] s1_w, mi1_w, h1_w, d1_w, mo1_w, y1_w, y10_w, h10_w, d10_w;
  logic [2:0] s10_w, mi10_w, w_w;
  logic       mo10_w;

  always_comb begin
    {s1_w, s10_w, mi1_w, mi10_w, h1_w, h10_w, w_w} =
      {s1_q, s10_q, mi1_q, mi10_q, h1_q, h10_q, w_q};
    {d1_w, d10_w, mo1_w, mo10_w, y1_w, y10_w} = {d1_q, d10_q, mo1_q, mo10_q, y1_q, y10_q};
    if (wr_on) begin
      unique case (addr_w)
        4'h0: s1_w   = d_in;
        4'h1: s10_w  = d_in[2:0];
        4'h2: mi1_w  = d_in;
        4'h3: mi10_w = d_in[2:0];
        4'h4: h1_w   = d_in;
        4'h5: h10_w  = d_in;
        4'h6: w_w    = d_in[2:0];
        4'h7: d1_w   = d_in;
        4'h8: d10_w  = d_in;
        4'h9: mo1_w  = d_in;
        4'hA: mo10_w = d_in[0];
        4'hB: y1_w   = d_in;
        4'hC: y10_w  = d_in;
        default: ;
      endcase
    end
  end

  logic       c_s1, c_s10, c_mi1, c_mi10, c_hr, c_day, c_mo;
  logic       mode24, h12_11, h12_12, h24_23, last_day, leap;
  logic [1:0] ymod4;
  logic [3:0] s1_d, mi1_d, h1_d, d1_d, mo1_d, y1_d, y10_d, h10_d, d10_d;
  logic [2:0] s10_d, mi10_d, w_d;
  logic       mo10_d;

  assign c_s1   = tick   && s1_w == 4'd9;
  assign c_s10  = c_s1   && s10_w == 3'd5;
  assign c_mi1  = c_s10  && mi1_w == 4'd9;
  assign c_mi10 = c_mi1  && mi10_w == 3'd5;

  assign mode24 = h10_w[3];
  assign h24_23 = h10_w[1:0] == 2'd2 && h1_w == 4'd3;
  assign h12_11 = h10_w[1:0] == 2'd1 && h1_w == 4'd1;
  assign h12_12 = h10_w[1:0] == 2'd1 && h1_w == 4'd2;
  assign c_hr   = c_mi10 && (mode24 ? h24_23 : h12_11 && h10_w[2]);

  // February has 29 days when (year mod 4 + selection) mod 4 = 0.
  assign ymod4 = {y10_w[0], 1'b0} + y1_w[1:0];
  assign leap  = 2'(ymod4 + d10_w[3:2]) == 2'd0;
  always_comb begin
    unique case ({mo10_w, mo1_w})
      5'b0_0100, 5'b0_0110, 5'b0_1001, 5'b1_0001:
               last_day = d10_w[1:0] == 2'd3 && d1_w == 4'd0;
      5'b0_0010: last_day = d10_w[1:0] == 2'd2 && d1_w == (leap ? 4'd9 : 4'd8);
      default: last_day = d10_w[1:0] == 2'd3 && d1_w == 4'd1;
    endcase
  end
  assign c_day = c_hr && last_day;
  assign c_mo  = c_day && mo10_w && mo1_w == 4'd2;

  always_comb begin
    s1_d   = !tick   ? s1_w   : (c_s1   ? 4'd0 : s1_w + 4'd1);
    s10_d  = !c_s1   ? s10_w  : (c_s10  ? 3'd0 : s10_w + 3'd1);
    mi1_d  = !c_s10  ? mi1_w  : (c_mi1  ? 4'd0 : mi1_w + 4'd1);
    mi10_d = !c_mi1  ? mi10_w : (c_mi10 ? 3'd0 : mi10_w + 3'd1);

    h1_d  = h1_w;
    h10_d = h10_w;
    if (c_mi10) begin
      if (mode24 && h24_23) begin
        h1_d = 4'd0;
        h10_d[1:0] = 2'd0;
      end else if (!mode24 && h12_11) begin
        h1_d = 4'd2;
        h10_d[2] = ~h10_w[2];
      end else if (!mode24 && h12_12) begin
        h1_d = 4'd1;
        h10_d[1:0] = 2'd0;
      end else if (h1_w == 4'd9) begin
        h1_d = 4'd0;
        h10_d[1:0] = h10_w[1:0] + 2'd1;
      end else begin
        h1_d = h1_w + 4'd1;
      end
    end

    w_d = !c_hr ? w_w : (w_w == 3'd6 ? 3'd0 : w_w + 3'd1);

    d1_d  = d1_w;
    d10_d = d10_w;
    if (c_day) begin
      d1_d = 4'd1;
      d10_d[1:0] = 2'd0;
    end else if (c_hr && d1_w == 4'd9) begin
      d1_d = 4'd0;
      d10_d[1:0] = d10_w[1:0] + 2'd1;
    end else if (c_hr) begin
      d1_d = d1_w + 4'd1;
    end

    mo1_d  = mo1_w;
    mo10_d = mo10_w;
    if (c_mo) begin
      mo1_d  = 4'd1;
      mo10_d = 1'b0;
    end else if (c_day && mo1_w == 4'd9) begin
      mo1_d  = 4'd0;
      mo10_d = ~mo10_w;
    end else if (c_day) begin
      mo1_d = mo1_w + 4'd1;
    end

    y1_d  = !c_mo ? y1_w : (y1_w == 4'd9 ? 4'd0 : y1_w + 4'd1);
    y10_d = !(c_mo && y1_w == 4'd9) ? y10_w : (y10_w == 4'd9 ? 4'd0 : y10_w + 4'd1);
  end

  always_ff @(posedge clk) begin
    {s1_q, s10_q, mi1_q, mi10_q, h1_q, h10_q, w_q} <= {s1_d, s10_d, mi1_d, mi10_d, h1_d, h10_d, w_d};
    {d1_q, d10_q, mo1_q, mo10_q, y1_q, y10_q} <= {d1_d, d10_d, mo1_d, mo10_d, y1_d, y10_d};
  end

  always_ff @(posedge clk) addr_q <= addr_w;
  always_ff @(posedge clk) div_q <= xt_go ? div_w + 15'd1 : div_w;

  // ---- outputs ---------------------------------------------------------------
  always_comb begin
    unique case (addr_q)
      4'h0: d_out = s1_q;
      4'h1: d_out = {1'b0, s10_q};
      4'h2: d_out = mi1_q;
      4'h3: d_out = {1'b0, mi10_q};
      4'h4: d_out = h1_q;
      A_H10: d_out = {h10_q[3], h10_q[2] & ~h10_q[3], h10_q[1:0]};
      4'h6: d_out = {1'b0, w_q};
      4'h7: d_out = d1_q;
      4'h8: d_out = d10_q;
      4'h9: d_out = mo1_q;
      4'hA: d_out = {3'b000, mo10_q};
      4'hB: d_out = y1_q;
      4'hC: d_out = y10_q;
      4'hE, 4'hF: d_out = {2'b00, div_q[14], div_q[4]};
      default: d_out = 4'h0;
    endcase
  end
  assign d_oe   = sel & read;
  assign busy_n = div_q < BUSY_AT;

  logic unused_ok;
  assign unused_ok = test;
endmodule
`default_nettype wire
