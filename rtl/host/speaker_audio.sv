// The internal speaker as a sound: the coil drive (7407s sinking) as a
// level, smoothed by a one-pole low-pass of about 15 kHz updated at
// 750 kHz.  Signed, silent when the coil is off.
`default_nettype none
module speaker_audio #(
  parameter int DIV   = 64,          // 48 MHz / 750 kHz
  parameter logic signed [15:0] LEVEL = 16'sd8192
) (
  input  logic               clk,
  input  logic               rst_n,
  input  logic               spk_on,
  output logic signed [15:0] sample
);
  logic [$clog2(DIV)-1:0] div_q;
  logic signed [15:0]     x;

  assign x = spk_on ? LEVEL : 16'sd0;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      div_q  <= '0;
      sample <= 16'sd0;
    end else begin
      div_q <= div_q + 1'b1;
      if (div_q == '0) sample <= sample + ((x - sample) >>> 3);
    end
  end
endmodule
`default_nettype wire
