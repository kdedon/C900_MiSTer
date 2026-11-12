// U67 SN75160 and U68 SN75161 against their function tables, and the
// speaker level filter.
`timescale 1ns/1ps
`default_nettype none
module tb_xcvr;
  localparam int REN = 0, IFC = 1, NDAC = 2, NRFD = 3, DAV = 4, EOI = 5, ATN = 6, SRQ = 7;

  logic       te, pe, dc;
  logic [7:0] t60_in, b60_in, b60_pull, b60_hi, t60_out;
  logic       t60_oe;
  logic [7:0] t61_in, b61_in, b61_pull, t61_out, t61_oe;

  sn75160 u67 (.te(te), .pe(pe), .term_in(t60_in), .bus_in(b60_in), .bus_pull(b60_pull),
               .bus_drv_hi(b60_hi), .term_out(t60_out), .term_oe(t60_oe));
  sn75161 u68 (.te(te), .dc(dc), .term_in(t61_in), .bus_in(b61_in), .bus_pull(b61_pull),
               .term_out(t61_out), .term_oe(t61_oe));

  logic clk = 0, rst_n = 0, spk_on = 0;
  logic signed [15:0] sample;
  always #10.416 clk = ~clk;
  speaker_audio u_spk (.clk(clk), .rst_n(rst_n), .spk_on(spk_on), .sample(sample));

  initial begin
    // SN75160: TE High open-collector (PE Low), TE Low receive.
    te = 1; pe = 0; dc = 1; t60_in = 8'h5A; b60_in = 8'h00; t61_in = 8'hFF; b61_in = 8'hFF;
    #1;
    if (b60_pull != 8'hA5 || b60_hi != 8'h00 || t60_oe) $fatal(1, "75160 TE=1 PE=0: %h %h %b", b60_pull, b60_hi, t60_oe);
    pe = 1; #1;
    if (b60_hi != 8'h5A) $fatal(1, "75160 PE=1 drive-high %h", b60_hi);
    te = 0; b60_in = 8'h3C; #1;
    if (!t60_oe || t60_out != 8'h3C || b60_pull != 8'h00) $fatal(1, "75160 TE=0 receive");

    // SN75161 direction table; terminal all Low so every transmitted line pulls.
    t61_in = 8'h00;
    for (int i = 0; i < 8; i++) begin
      logic tt, dd, aa;
      {tt, dd, aa} = 3'(i);
      te = tt; dc = dd; b61_in = aa ? 8'hFF : 8'hBF;   // bus ATN level
      #1;
      if (b61_pull[ATN] != ~dd || b61_pull[REN] != ~dd || b61_pull[IFC] != ~dd || b61_pull[SRQ] != dd)
        $fatal(1, "75161 DC=%b management %b", dd, b61_pull);
      if (b61_pull[DAV] != tt || b61_pull[NDAC] != ~tt || b61_pull[NRFD] != ~tt)
        $fatal(1, "75161 TE=%b handshake %b", tt, b61_pull);
      if (t61_oe != ~b61_pull) $fatal(1, "75161 term_oe %b vs pull %b", t61_oe, b61_pull);
    end
    // EOI with the chip's own ATN released (terminal ATN High).
    t61_in = 8'b1101_1111;   // EOI Low, others High
    te = 1; dc = 1; b61_in = 8'hFF; #1;  if (!b61_pull[EOI]) $fatal(1, "EOI: TE=1 ATN=1 must send");
    te = 1; dc = 1; b61_in = 8'hBF; #1;  if (b61_pull[EOI])  $fatal(1, "EOI: TE=1 DC=1 ATN=0 must receive");
    te = 0; dc = 0; b61_in = 8'hBF; #1;  if (!b61_pull[EOI]) $fatal(1, "EOI: TE=0 DC=0 ATN=0 must send");
    te = 0; dc = 0; b61_in = 8'hFF; #1;  if (b61_pull[EOI])  $fatal(1, "EOI: TE=0 DC=0 ATN=1 must receive");
    te = 0; dc = 1; b61_in = 8'hFF; #1;  if (b61_pull[EOI])  $fatal(1, "EOI: TE=0 DC=1 must receive");

    // Speaker: silent at rest, settles near LEVEL with the coil on.
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (64 * 100) @(posedge clk);
    if (sample != 0) $fatal(1, "speaker not silent: %0d", sample);
    spk_on = 1;
    repeat (64 * 100) @(posedge clk);
    if (sample < 16'sd8100 || sample > 16'sd8192) $fatal(1, "speaker on level %0d", sample);
    spk_on = 0;
    repeat (64 * 100) @(posedge clk);
    if (sample > 16'sd100) $fatal(1, "speaker off level %0d", sample);
    $display("tb_xcvr: PASS");
    $finish;
  end
endmodule
`default_nettype wire
