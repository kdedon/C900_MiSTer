// CN5 printer model: the host side is driven the way the lp driver does it
// (wait BUSY low, data, strobe about 2 us, wait /ACK).  Unattached, the
// lines read as the board pull-ups leave them.
`timescale 1ns/1ps
`default_nettype none
module tb_prn;
  logic clk = 0, rst_n = 0;
  always #10.416 clk = ~clk;

  logic [7:0]  data = 8'hFF;
  logic        strobe_n = 1;
  logic        ack_n, busy, attached = 0, byte_valid;
  logic [7:0]  byte_data;

  centronics_printer #(.CLK_HZ(48_000_000)) u_prn (
    .clk(clk), .rst_n(rst_n), .attached(attached), .data(data), .strobe_n(strobe_n),
    .ack_n(ack_n), .busy(busy), .byte_valid(byte_valid), .byte_data(byte_data), .byte_ready(1'b1)
  );

  byte got [$];
  always_ff @(posedge clk) if (byte_valid) got.push_back(byte_data);

  task automatic wait_us(input int us);
    repeat (us * 48) @(posedge clk);
  endtask

  // One byte the lp way; returns 0 if BUSY never drops.
  task automatic lp_char(input byte c, output bit ok);
    int n = 0;
    ok = 1;
    while (busy) begin
      @(posedge clk);
      n++;
      if (n > 48 * 20000) begin ok = 0; return; end
    end
    data <= c;
    wait_us(1);
    strobe_n <= 0;
    wait_us(2);
    strobe_n <= 1;
    if (!busy) $fatal(1, "BUSY not raised by the strobe");
    n = 0;
    while (ack_n) begin
      @(posedge clk);
      n++;
      if (n > 48 * 20000) $fatal(1, "no /ACK");
    end
    if (n < 48 * 90) $fatal(1, "/ACK %0d clocks after the strobe; want about 100 us", n);
    n = 0;
    while (!ack_n) begin @(posedge clk); n++; end
    if (n < 48 * 4 || n > 48 * 6) $fatal(1, "/ACK width %0d clocks", n);
    if (busy) $fatal(1, "BUSY high after /ACK");
  endtask

  bit ok;
  initial begin
    repeat (10) @(posedge clk);
    rst_n <= 1;
    wait_us(1);
    if (!busy || !ack_n) $fatal(1, "unattached: BUSY and /ACK must read High");
    strobe_n <= 0; wait_us(2); strobe_n <= 1;
    wait_us(200);
    if (!busy || !ack_n || got.size() != 0) $fatal(1, "unattached printer reacted to /STROBE");

    attached <= 1;
    wait_us(1);
    for (int i = 0; i < 20; i++) begin
      lp_char(byte'(i * 7 + 1), ok);
      if (!ok) $fatal(1, "stuck busy at byte %0d", i);
    end
    wait_us(10);
    if (got.size() != 20) $fatal(1, "%0d bytes taken; want 20", got.size());
    for (int i = 0; i < 20; i++)
      if (got[i] != byte'(i * 7 + 1)) $fatal(1, "byte %0d = %02x", i, got[i]);
    $display("tb_prn: PASS");
    $finish;
  end
endmodule
`default_nettype wire
