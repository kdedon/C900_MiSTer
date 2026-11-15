// tb_scc_rx -- SCC channel A async receive under a slow reader.
//
// The SCC is set up as the COHERENT al driver leaves a RAW 9600 line
// (x16, 8 bits, 2 stop, no parity, BRG from 6 MHz PCLK, TC 17, Rx Int on
// all characters or special condition, VIS + MIE).  A host sends 8N1 at
// exactly 9600 baud, back to back.  The reader acts like alRxintr/alSCintr:
// it waits for /INT, waits a latency, then reads RR0 and RR8 until RR0 D0
// clears, spending a cost per character; a special condition at the head
// takes the alSCintr path (Error Reset, read and discard one character).
//
// Time unit: one PCLK (166.7 ns at 6 MHz).  One host bit is 625 PCLK, one
// character 6250 PCLK (1.042 ms).
`default_nettype none
module tb_scc_rx;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic pclk_rise = 1'b0;
  always @(posedge clk) pclk_rise <= ~pclk_rise;
  longint pc = 0;
  always @(posedge clk) if (pclk_rise) pc <= pc + 1;

  logic [7:0] ad_in = 8'h00;
  logic       as_n = 1'b1, ds_n = 1'b1, r_w = 1'b1, cs0_n = 1'b1, cs1 = 1'b0;
  logic       intack_n = 1'b1;
  logic [1:0] rxd = 2'b11;
  logic [7:0] ad_out;
  logic       ad_drive, int_n, ieo;
  logic [1:0] txd, rts_n, dtr_n, trxc_out, trxc_drive, sync_out, sync_drive;

  z8030_scc dut (
    .clk(clk), .ad_in(ad_in), .as_n(as_n), .ds_n(ds_n), .r_w(r_w),
    .cs0_n(cs0_n), .cs1(cs1), .intack_n(intack_n), .iei(1'b1), .pclk_rise(pclk_rise),
    .rxd(rxd), .cts_n(2'b11), .dcd_n(2'b11),
    .trxc_rise(2'b00), .trxc_fall(2'b00), .rxc_rise(2'b00), .rxc_fall(2'b00), .sync_in(2'b11),
    .ad_out(ad_out), .ad_drive(ad_drive), .int_n(int_n), .ieo(ieo),
    .txd(txd), .rts_n(rts_n), .dtr_n(dtr_n), .trxc_out(trxc_out), .trxc_drive(trxc_drive),
    .sync_out(sync_out), .sync_drive(sync_drive)
  );

  localparam int CH_A = 0;
  localparam int CHAR_PCLK = 6250;

  function automatic logic [7:0] adr(input int reg_no);
    return 8'(reg_no << 1) | 8'h20;
  endfunction

  // One bus phase: two master clocks, one of them a PCLK rise.
  task automatic phase();
    @(posedge clk); @(posedge clk); #1;
  endtask
  task automatic wait_pclk(input int n);
    longint t; t = pc + n;
    while (pc < t) @(posedge clk);
    #1;
  endtask

  task automatic wr(input int reg_no, input logic [7:0] val);
    as_n = 1'b0; cs0_n = 1'b0; cs1 = 1'b1; r_w = 1'b0; ad_in = adr(reg_no); phase();
    as_n = 1'b1;                                                         phase();
    ds_n = 1'b0; ad_in = val;                                            phase();
    ds_n = 1'b1;                                                         phase();
    cs0_n = 1'b1; cs1 = 1'b0;                                            phase();
  endtask
  task automatic rd(input int reg_no, output logic [7:0] val);
    as_n = 1'b0; cs0_n = 1'b0; cs1 = 1'b1; r_w = 1'b1; ad_in = adr(reg_no); phase();
    as_n = 1'b1;                                                         phase();
    ds_n = 1'b0;                                                         phase();
    #1; val = ad_out;
    ds_n = 1'b1;                                                         phase();
    cs0_n = 1'b1; cs1 = 1'b0;                                            phase();
  endtask
  // A bus cycle that does not select the SCC: /AS still clocks its /INT latch.
  task automatic idle_cycle();
    as_n = 1'b0; phase(); as_n = 1'b1; phase(); phase();
  endtask

  // ---- host transmitter: 8N1, 625 PCLK per bit, characters back to back
  logic [7:0] tx_q [$];
  int         n_sent;
  bit         tx_busy = 1'b0;
  task automatic host_send(input int n, input int seed);
    int s; s = seed;
    tx_busy = 1'b1;
    for (int i = 0; i < n; i++) begin
      logic [7:0] b;
      b = 8'($urandom(s + i));
      tx_q.push_back(b);
      rxd[CH_A] = 1'b0; wait_pclk(625);
      for (int k = 0; k < 8; k++) begin rxd[CH_A] = b[k]; wait_pclk(625); end
      rxd[CH_A] = 1'b1; wait_pclk(625);
      n_sent++;
    end
    tx_busy = 1'b0;
  endtask

  // ---- reader
  logic [7:0] rx_q [$];
  int         n_ovr_seen, n_sc, n_isr, lat_pclk, cost_pclk, post_pclk;
  int         stall_at, stall_len;   // one extra stall before the ISR at char stall_at
  bit         reader_on = 1'b0;
  bit         reader_idle = 1'b0;

  task automatic isr();
    logic [7:0] r0, r1, d;
    n_isr++;
    rd(1, r1);
    if ((r1 & 8'h70) != 8'h00) begin          // special condition vector
      n_sc++;
      if (r1[5]) n_ovr_seen++;
      wr(0, 8'h30);                            // Error Reset
      rd(8, d);                                // read and discard
    end else begin
      rd(0, r0);
      while (r0[0]) begin
        rd(1, r1);
        if (r1[5]) n_ovr_seen++;
        rd(8, d);
        rx_q.push_back(d);
        wait_pclk(cost_pclk);
        rd(0, r0);
      end
    end
    wr(0, 8'h38);                              // Reset Highest IUS
  endtask

  initial begin : reader
    forever begin
      if (reader_on && !int_n) begin
        if (stall_len > 0 && n_sent >= stall_at) begin
          wait_pclk(stall_len); stall_len = 0;
        end
        wait_pclk(lat_pclk);
        isr();
        wait_pclk(post_pclk);
      end else if (reader_on) idle_cycle();
      else begin reader_idle = 1'b1; @(posedge clk); #1; reader_idle = 1'b0; end
    end
  end

  task automatic scc_init();
    as_n = 1'b0; ds_n = 1'b0; phase(); phase();
    as_n = 1'b1; ds_n = 1'b1; repeat (6) phase();
    wr(9, 8'hC1); wr(2, 8'h10);
    // alinit[]
    wr(4, 8'h4C); wr(3, 8'hC0); wr(5, 8'h60); wr(10, 8'h00); wr(11, 8'h56);
    wr(12, 8'd17); wr(13, 8'h00); wr(14, 8'h03); wr(3, 8'hC1); wr(5, 8'h68);
    wr(15, 8'h00); wr(0, 8'h10); wr(0, 8'h10);
    // alopen, no modem control
    wr(3, 8'hC1); wr(5, 8'hEA); wr(9, 8'h09); wr(15, 8'h80); wr(1, 8'h13);
    // alparam, RAW
    wr(12, 8'd17); wr(13, 8'h00); wr(3, 8'hC1); wr(5, 8'hEA); wr(4, 8'h4C);
  endtask

  int fails = 0;
  // Bytes delivered in order, none lost or changed.
  function automatic int lost();
    int j, m;
    j = 0; m = 0;
    foreach (tx_q[i]) begin
      if (j < rx_q.size() && rx_q[j] == tx_q[i]) j++;
      else m++;
    end
    return m;
  endfunction

  task automatic run(input string name, input int n, input int lat, input int cost,
                     input int s_at, input int s_len,
                     input int want_lost_min, input int want_lost_max, input bit want_ovr,
                     input int post = 0);
    int l;
    tx_q.delete(); rx_q.delete();
    n_sent = 0; n_ovr_seen = 0; n_sc = 0; n_isr = 0;
    lat_pclk = lat; cost_pclk = cost; post_pclk = post; stall_at = s_at; stall_len = s_len;
    reader_on = 1'b1;
    host_send(n, n * 7 + lat + cost + s_len);
    wait_pclk(8 * CHAR_PCLK);
    reader_on = 1'b0;
    wait (reader_idle);
    l = lost();
    if (l < want_lost_min || l > want_lost_max || (n_ovr_seen != 0) != want_ovr) begin
      fails++;
      $display("  FAIL  %s: sent %0d got %0d lost %0d overrun %0d sc %0d isr %0d",
               name, n, rx_q.size(), l, n_ovr_seen, n_sc, n_isr);
    end else
      $display("  PASS  %s: sent %0d got %0d lost %0d overrun %0d sc %0d isr %0d",
               name, n, rx_q.size(), l, n_ovr_seen, n_sc, n_isr);
    // Leave the channel clean for the next run.
    wr(0, 8'h30);
  endtask

  initial begin
    @(posedge clk); #1;
    scc_init();
    $display("tb_scc_rx: 9600 8N1 host into SCC A at TC 17 (9868 baud x16)");
    // Prompt reader, 0.1 ms per character: everything arrives.
    run("fast reader", 300, 300, 600, 0, 0, 0, 0, 1'b0);
    // Latency just under three characters.
    run("latency 2.9 ms", 100, 17400, 600, 0, 0, 0, 0, 1'b0);
    // Latency past three characters and a half: the fourth character
    // overwrites the third, every burst.
    run("latency 3.5 ms", 100, 21000, 600, 0, 0, 1, 100, 1'b1);
    // One 3.0 ms stall mid-stream: absorbed by the FIFO.
    run("one 3.0 ms stall", 100, 300, 600, 50, 18000, 0, 0, 1'b0);
    // One 4.5 ms stall: loses characters, overrun reported.
    run("one 4.5 ms stall", 100, 300, 600, 50, 27000, 1, 4, 1'b1);
    // Per-character cost below the character time.
    run("cost 0.95 ms/char", 100, 300, 5700, 0, 0, 0, 0, 1'b0);
    // Per-character cost above the character time: the backlog grows.
    run("cost 1.2 ms/char", 100, 300, 7200, 0, 0, 1, 100, 1'b1);
    // Interrupts masked for a while after every service, as when the
    // character wakes a reader and the kernel switches to it.
    run("masked 2.5 ms after each ISR", 200, 300, 600, 0, 0, 0, 0, 1'b0, 15000);
    run("masked 3.5 ms after each ISR", 200, 300, 600, 0, 0, 1, 200, 1'b1, 21000);
    // No reader: five characters into the three-deep FIFO.  The fourth and
    // fifth overwrite the third; the survivor carries Rx Overrun (RR1 D5),
    // which stays latched until Error Reset.
    begin
      logic [7:0] r0, r1, d;
      logic [7:0] got [3], st [3];
      tx_q.delete(); n_sent = 0;
      host_send(5, 99);
      wait_pclk(2 * CHAR_PCLK);
      for (int i = 0; i < 3; i++) begin rd(1, st[i]); rd(8, got[i]); end
      rd(0, r0); rd(1, r1);
      if (got[0] == tx_q[0] && got[1] == tx_q[1] && got[2] == tx_q[4] &&
          !st[0][5] && !st[1][5] && st[2][5] && !r0[0] && r1[5]) begin
        $display("  PASS  FIFO full: %02h %02h %02h kept, RR1 D5 on the last and latched", got[0], got[1], got[2]);
      end else begin
        fails++;
        $display("  FAIL  FIFO full: sent %02h %02h %02h %02h %02h, read %02h/%02h %02h/%02h %02h/%02h, RR0 %02h RR1 %02h",
                 tx_q[0], tx_q[1], tx_q[2], tx_q[3], tx_q[4], got[0], st[0], got[1], st[1], got[2], st[2], r0, r1);
      end
      wr(0, 8'h30); rd(1, r1);
      if (r1[5]) begin fails++; $display("  FAIL  Error Reset left RR1 D5 set"); end
      else $display("  PASS  Error Reset clears RR1 D5");
    end
    if (fails == 0) $display("PASS"); else $display("FAIL (%0d)", fails);
    $finish;
  end
endmodule
`default_nettype wire
