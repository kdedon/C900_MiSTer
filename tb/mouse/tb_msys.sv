// ps2_mouse_msys: ps2_mouse reports in, RxD decoded as an 8N1 UART at
// BIT_CLKS clocks per bit.  Checks the packet bytes (buttons, motion split,
// saturation and carry, sign), back-to-back bytes and packets, exact bit
// edges, an idle line with nothing pending, reports dropped with the OSD
// open, and an idle line when off or with the HR card.
`default_nettype none
module tb_msys;
  parameter int BIT = 400;
  localparam int PKT = 50 * BIT;
  logic clk = 1'b0, rst_n = 1'b0;
  always #1 clk = ~clk;

  logic [24:0] ps2 = '0;
  logic        osd = 1'b0, on = 1'b1, hr = 1'b0;
  logic        active, rxd;
  ps2_mouse_msys #(.BIT_CLKS(BIT)) dut (.clk, .rst_n, .ps2_mouse(ps2), .osd, .on, .hr,
    .active, .rxd);

  int errors = 0;
  longint now = 0;
  always_ff @(posedge clk) now <= now + 1;

  // Receiver: every edge inside a byte must fall on a bit boundary.
  byte    rx_q[$];
  longint rx_t[$];
  logic   in_byte = 1'b0, last = 1'b1;
  longint t0 = 0;
  logic [7:0] sh;
  always @(posedge clk) begin
    if (rxd != last && in_byte && (now - t0) % BIT != 0) begin
      errors++; $display("FAIL edge off the bit grid at %0d", now - t0);
    end
    last <= rxd;
    if (!in_byte && last && !rxd) begin in_byte <= 1'b1; t0 <= now; end
    if (in_byte) begin
      for (int k = 0; k < 10; k++) if (now - t0 == BIT / 2 + k * BIT) begin
        if (k == 0 && rxd) begin errors++; $display("FAIL start bit"); end
        if (k >= 1 && k <= 8) sh[k-1] <= rxd;
        if (k == 9) begin
          if (!rxd) begin errors++; $display("FAIL stop bit"); end
          rx_q.push_back(sh); rx_t.push_back(t0);
          in_byte <= 1'b0;
        end
      end
    end
  end

  task automatic report(input int dx, input int dy, input logic l, input logic m, input logic r);
    logic [8:0] x9, y9;
    x9 = dx[8:0]; y9 = dy[8:0];
    @(negedge clk);
    ps2 <= {~ps2[24], y9[7:0], x9[7:0], 2'b00, y9[8], x9[8], 1'b1, m, r, l};
    repeat (4) @(negedge clk);
  endtask

  // Wait until the line has been idle for three packet times.
  task automatic settle();
    longint quiet;
    quiet = 0;
    while (quiet < 3 * PKT) begin @(posedge clk); quiet = (rxd && !in_byte) ? quiet + 1 : 0; end
  endtask

  int pk[$][5];
  // Split the received bytes into packets; bytes and packets back to back.
  task automatic take(input string name);
    pk.delete();
    if (rx_q.size() % 5 != 0) begin errors++; $display("FAIL %s: %0d bytes", name, rx_q.size()); end
    for (int i = 0; i + 4 < rx_q.size(); i += 5) begin
      int p[5];
      for (int j = 0; j < 5; j++) p[j] = (j == 0) ? int'(rx_q[i]) & 255 : int'(rx_q[i+j]);
      if ((p[0] & 8'hF8) != 8'h80) begin errors++; $display("FAIL %s: sync %02x", name, p[0]); end
      for (int j = 1; j < 5; j++) if (p[j] < -127) begin errors++; $display("FAIL %s: byte -128", name); end
      pk.push_back(p);
    end
    for (int i = 1; i < rx_t.size(); i++) if (rx_t[i] - rx_t[i-1] != 10 * BIT) begin
      errors++; $display("FAIL %s: gap %0d clocks before byte %0d", name, rx_t[i] - rx_t[i-1], i);
    end
    rx_q.delete(); rx_t.delete();
  endtask

  task automatic expect1(input string name, input int b, input int x1, input int y1, input int x2, input int y2);
    take(name);
    if (pk.size() != 1 || pk[0][0] != b || pk[0][1] != x1 || pk[0][2] != y1 || pk[0][3] != x2 || pk[0][4] != y2) begin
      errors++;
      $display("FAIL %s: %0d packets, want %02x %0d %0d %0d %0d", name, pk.size(), b, x1, y1, x2, y2);
      foreach (pk[i]) $display("  got %02x %0d %0d %0d %0d", pk[i][0], pk[i][1], pk[i][2], pk[i][3], pk[i][4]);
    end else $display("ok   %s", name);
  endtask

  task automatic expect_none(input string name);
    take(name);
    if (pk.size() != 0) begin errors++; $display("FAIL %s: %0d packets", name, pk.size()); end
    else $display("ok   %s", name);
  endtask

  initial begin
    #(200 * PKT);
    $fatal(1, "FAIL tb_msys: timeout");
  end

  initial begin
    repeat (20) @(negedge clk);
    rst_n = 1'b1;
    repeat (20) @(negedge clk);
    settle(); expect_none("idle after reset");

    report(10, -6, 0, 0, 0);   settle(); expect1("move 10,-6", 8'h87, 5, -3, 5, -3);
    // At the real rate (1200 baud at 48 MHz) one packet is enough.
    if (BIT > 1000) begin
      if (errors == 0) $display("PASS tb_msys BIT=%0d", BIT);
      else $fatal(1, "FAIL tb_msys: %0d errors", errors);
      $finish;
    end
    report(7, -7, 0, 0, 0);    settle(); expect1("odd split 7,-7", 8'h87, 4, -4, 3, -3);
    report(0, 20, 0, 0, 0);    settle(); expect1("Y up stays positive", 8'h87, 0, 10, 0, 10);
    report(0, 0, 1, 0, 0);     settle(); expect1("left", 8'h83, 0, 0, 0, 0);
    report(0, 0, 0, 1, 0);     settle(); expect1("middle", 8'h85, 0, 0, 0, 0);
    report(0, 0, 0, 0, 1);     settle(); expect1("right", 8'h86, 0, 0, 0, 0);
    report(0, 0, 1, 1, 1);     settle(); expect1("all three", 8'h80, 0, 0, 0, 0);
    report(0, 0, 0, 0, 0);     settle(); expect1("release", 8'h87, 0, 0, 0, 0);

    // 1000 counts each way in four reports: 127 per byte, the rest carried.
    for (int i = 0; i < 4; i++) report(250, -250, 0, 0, 0);
    settle(); take("saturate");
    begin
      int sx, sy, big;
      sx = 0; sy = 0; big = 0;
      foreach (pk[i]) begin
        sx += pk[i][1] + pk[i][3]; sy += pk[i][2] + pk[i][4];
        for (int j = 1; j < 5; j++) if (pk[i][j] == 127 || pk[i][j] == -127) big++;
      end
      if (pk.size() != 4 || sx != 1000 || sy != -1000 || big != 12 || pk[0][1] != 127 || pk[0][4] != -127) begin
        errors++; $display("FAIL saturate: %0d packets, sum %0d,%0d, %0d bytes at 127", pk.size(), sx, sy, big);
        foreach (pk[i]) $display("  got %02x %0d %0d %0d %0d", pk[i][0], pk[i][1], pk[i][2], pk[i][3], pk[i][4]);
      end else $display("ok   saturate and carry: 4 packets, 1000,-1000");
    end

    // OSD open: the report is lost, not deferred.
    osd = 1'b1; report(50, 50, 1, 0, 0); osd = 1'b0;
    settle(); expect_none("OSD drop");

    on = 1'b0; report(30, 30, 0, 0, 1);
    settle();
    if (active) begin errors++; $display("FAIL off: active"); end
    expect_none("off");

    on = 1'b1; hr = 1'b1; repeat (4) @(negedge clk);
    report(30, 30, 0, 0, 1);
    begin
      logic seen_low;
      seen_low = 1'b0;
      for (int i = 0; i < 3 * PKT; i++) begin @(posedge clk); if (!rxd || active) seen_low = 1'b1; end
      if (seen_low) begin errors++; $display("FAIL HR: line not idle"); end
    end
    expect_none("HR fitted: RxD idle");

    hr = 1'b0; repeat (4) @(negedge clk);
    report(-2, 2, 0, 0, 0); settle(); expect1("back on", 8'h87, -1, 1, -1, 1);

    if (errors == 0) $display("PASS tb_msys BIT=%0d", BIT);
    else $fatal(1, "FAIL tb_msys: %0d errors", errors);
    $finish;
  end
endmodule
`default_nettype wire
