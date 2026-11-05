// fantdiv edge rates over 0.1 s of the 48 MHz master clock: HDC Y101
// 10 MHz (edges alternate, 2 or 3 master clocks apart), keyboard 2 MHz,
// RTC 32.768 kHz.
`default_nettype none
module tb_fantdiv;
  localparam longint N = 64'd4800000;

  logic clk = 1'b0;
  logic hdc_rise, hdc_fall, kbd_rise, rtc_rise;
  fantdiv dut (.clk(clk), .hdc_rise(hdc_rise), .hdc_fall(hdc_fall), .kbd_rise(kbd_rise),
               .rtc_rise(rtc_rise));

  always #1 clk = ~clk;

  longint n_hr = 0, n_hf = 0, n_kbd = 0, n_rtc = 0, since = 0, gap_min = 99, gap_max = 0;
  logic   last_rise = 1'b0;
  longint i;

  initial begin
    for (i = 0; i < N; i++) begin
      @(posedge clk);
      #0.5;
      since++;
      if (hdc_rise && hdc_fall) $fatal(1, "hdc rise and fall on one clock at %0d", i);
      if (hdc_rise || hdc_fall) begin
        if (n_hr + n_hf > 0) begin
          if (hdc_rise == last_rise) $fatal(1, "hdc edges do not alternate at %0d", i);
          if (since < gap_min) gap_min = since;
          if (since > gap_max) gap_max = since;
        end
        last_rise = hdc_rise;
        since = 0;
      end
      n_hr  += longint'(hdc_rise);
      n_hf  += longint'(hdc_fall);
      n_kbd += longint'(kbd_rise);
      n_rtc += longint'(rtc_rise);
    end
    $display("hdc %0d rises %0d falls, gap %0d-%0d; kbd %0d; rtc %0d", n_hr, n_hf, gap_min, gap_max, n_kbd, n_rtc);
    if (n_hr != 64'd1000000 || n_hf != 64'd1000000) $fatal(1, "FAIL hdc: want 1000000 rises and falls (10 MHz)");
    if (gap_min != 64'd2 || gap_max != 64'd3) $fatal(1, "FAIL hdc: edges 2-3 master clocks apart");
    if (n_kbd != 64'd200000) $fatal(1, "FAIL kbd: want 200000 rises (2 MHz)");
    if (n_rtc < 64'd3276 || n_rtc > 64'd3277) $fatal(1, "FAIL rtc: want 3276-3277 rises (32.768 kHz)");
    $display("PASS");
    $finish;
  end
endmodule
`default_nettype wire
