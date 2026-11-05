// Stand-ins for the off-board crystals (independent oscillators, no phase
// relation to Y1) as phase accumulators on the 48 MHz master clock; each
// edge is a one-master-clock pulse.
//   hdc   10 MHz      5/12 edges per master clock      HDC card Y101
//   kbd    2 MHz      one rise per 24 master clocks     keyboard crystal
//   rtc   32.768 kHz  64/46875 edges per master clock   MSM58321 XT
// The keyboard rise lands on master clock 13 mod 24.
`default_nettype none
module fantdiv (
  input  logic clk,        // master clock
  output logic hdc_rise,
  output logic hdc_fall,
  output logic kbd_rise,
  output logic rtc_rise
);
  localparam int HDC_NUM = 5,  HDC_DEN = 12;
  localparam int RTC_NUM = 64, RTC_DEN = 46875;

  // Justification: (reg-a) accumulators, output levels and edge pulses.
  logic [4:0]  hdc_q  = 5'd0;
  logic [4:0]  kbd_q  = 5'd0;
  logic [15:0] rtc_q  = 16'd0;
  logic        hdc_o  = 1'b0;
  logic        rtc_o  = 1'b0;
  logic        hdc_r_q = 1'b0, hdc_f_q = 1'b0, kbd_r_q = 1'b0, rtc_r_q = 1'b0;

  logic [4:0]  hdc_s;          // up to 11 + 5
  logic [15:0] rtc_s;
  logic        hdc_t, rtc_t;
  assign hdc_s = hdc_q + 5'(HDC_NUM);
  assign rtc_s = rtc_q + 16'(RTC_NUM);
  assign hdc_t = hdc_s >= 5'(HDC_DEN);
  assign rtc_t = rtc_s >= 16'(RTC_DEN);

  always_ff @(posedge clk) begin
    hdc_q   <= hdc_t ? hdc_s - 5'(HDC_DEN) : hdc_s;
    rtc_q   <= rtc_t ? rtc_s - 16'(RTC_DEN) : rtc_s;
    kbd_q   <= (kbd_q == 5'd23) ? 5'd0 : kbd_q + 5'd1;
    if (hdc_t) hdc_o <= ~hdc_o;
    if (rtc_t) rtc_o <= ~rtc_o;
    hdc_r_q <= hdc_t & ~hdc_o;
    hdc_f_q <= hdc_t &  hdc_o;
    rtc_r_q <= rtc_t & ~rtc_o;
    kbd_r_q <= (kbd_q == 5'd12);
  end

  assign hdc_rise = hdc_r_q;
  assign hdc_fall = hdc_f_q;
  assign kbd_rise = kbd_r_q;
  assign rtc_rise = rtc_r_q;
endmodule
`default_nettype wire
