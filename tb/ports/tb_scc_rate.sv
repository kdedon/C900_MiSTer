// tb_scc_rate -- SCC channel A async receive against a sender off rate.
//
// The SCC is set up as the COHERENT al driver leaves a RAW line (x16, 8
// bits, no parity, BRG from 6 MHz PCLK, Rx Int on all characters or special
// condition) at TC 18 (9375 baud, 640 PCLK a bit) and TC 8 (18750 baud, 320
// PCLK a bit), with WR4 at 1 and at 2 stop bits.  A host sends 8N1 back to
// back with its bit period scaled by 1/(1+offset).  A prompt reader counts
// characters delivered in order, framing errors and overruns.
//
// A receiver that resynchronises on every start bit takes a few percent of
// rate error either way; a 10% fast sender breaks the stop bit sample.
`default_nettype none
module tb_scc_rate;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic pclk_rise = 1'b0;
  always @(posedge clk) pclk_rise <= ~pclk_rise;
  longint pc = 0;
  always @(posedge clk) if (pclk_rise) pc <= pc + 1;

  logic [7:0] ad_in = 8'h00;
  logic       as_n = 1'b1, ds_n = 1'b1, r_w = 1'b1, cs0_n = 1'b1, cs1 = 1'b0;
  logic [1:0] rxd = 2'b11;
  logic [7:0] ad_out;
  logic       ad_drive, int_n, ieo;
  logic [1:0] txd, rts_n, dtr_n, trxc_out, trxc_drive, sync_out, sync_drive;

  z8030_scc dut (
    .clk(clk), .ad_in(ad_in), .as_n(as_n), .ds_n(ds_n), .r_w(r_w),
    .cs0_n(cs0_n), .cs1(cs1), .intack_n(1'b1), .iei(1'b1), .pclk_rise(pclk_rise),
    .rxd(rxd), .cts_n(2'b11), .dcd_n(2'b11),
    .trxc_rise(2'b00), .trxc_fall(2'b00), .rxc_rise(2'b00), .rxc_fall(2'b00), .sync_in(2'b11),
    .ad_out(ad_out), .ad_drive(ad_drive), .int_n(int_n), .ieo(ieo),
    .txd(txd), .rts_n(rts_n), .dtr_n(dtr_n), .trxc_out(trxc_out), .trxc_drive(trxc_drive),
    .sync_out(sync_out), .sync_drive(sync_drive)
  );

  localparam int CH_A = 0;
  localparam int N_CHARS = 200;

  function automatic logic [7:0] adr(input int reg_no);
    return 8'(reg_no << 1) | 8'h20;
  endfunction

  task automatic phase();
    @(posedge clk); @(posedge clk); #1;
  endtask
  task automatic wait_pclk(input int n);
    longint t; t = pc + n;
    while (pc < t) @(posedge clk);
    #1;
  endtask
  task automatic wait_until(input longint t);
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
  task automatic idle_cycle();
    as_n = 1'b0; phase(); as_n = 1'b1; phase(); phase();
  endtask

  // ---- host: 8N1 back to back, edges at round(t0 + k * period)
  logic [7:0] tx_q [$];
  bit         tx_busy = 1'b0;
  task automatic host_send(input int n, input real period, input int seed);
    longint t0; int k;
    t0 = pc; k = 0;
    tx_busy = 1'b1;
    for (int i = 0; i < n; i++) begin
      logic [9:0] fr;
      logic [7:0] b;
      b = 8'($urandom(seed + i));
      tx_q.push_back(b);
      fr = {1'b1, b, 1'b0};
      for (int j = 0; j < 10; j++) begin
        rxd[CH_A] = fr[j];
        k++;
        wait_until(t0 + longint'($rtoi(real'(k) * period + 0.5)));
      end
    end
    tx_busy = 1'b0;
  endtask

  // ---- reader: alRxintr/alSCintr with no latency
  logic [7:0] rx_q [$];
  int         n_fe, n_ovr;
  bit         reader_on = 1'b0;
  bit         reader_idle = 1'b0;

  task automatic isr();
    logic [7:0] r0, r1, d;
    rd(0, r0);
    while (r0[0]) begin
      rd(1, r1);
      if (r1[6]) n_fe++;
      if (r1[5]) n_ovr++;
      rd(8, d);
      if ((r1 & 8'h70) != 8'h00) wr(0, 8'h30);
      else rx_q.push_back(d);
      rd(0, r0);
    end
    wr(0, 8'h38);
  endtask

  initial begin : reader
    forever begin
      if (reader_on && !int_n) begin
        wait_pclk(300);
        isr();
      end else if (reader_on) idle_cycle();
      else begin reader_idle = 1'b1; @(posedge clk); #1; reader_idle = 1'b0; end
    end
  end

  task automatic scc_init();
    as_n = 1'b0; ds_n = 1'b0; phase(); phase();
    as_n = 1'b1; ds_n = 1'b1; repeat (6) phase();
    wr(9, 8'hC1); wr(2, 8'h10);
    wr(4, 8'h4C); wr(3, 8'hC0); wr(5, 8'h60); wr(10, 8'h00); wr(11, 8'h56);
    wr(12, 8'd18); wr(13, 8'h00); wr(14, 8'h03); wr(3, 8'hC1); wr(5, 8'h68);
    wr(15, 8'h00); wr(0, 8'h10); wr(0, 8'h10);
    wr(3, 8'hC1); wr(5, 8'hEA); wr(9, 8'h09); wr(15, 8'h80); wr(1, 8'h13);
  endtask

  // Characters delivered in order.
  function automatic int good();
    int j; j = 0;
    foreach (tx_q[i]) if (j < rx_q.size() && rx_q[j] == tx_q[i]) j++;
    return j;
  endfunction

  int fails = 0;
  task automatic run(input int tc, input bit two_stop, input real off, input bit want_ok);
    real period;
    int g;
    bit ok;
    // Stop the BRG while its count changes.
    wr(14, 8'h02); wr(12, 8'(tc)); wr(13, 8'h00); wr(14, 8'h03);
    wr(4, two_stop ? 8'h4C : 8'h44);
    wr(3, 8'hC1);
    wait_pclk(4000);
    wr(0, 8'h30);
    tx_q.delete(); rx_q.delete(); n_fe = 0; n_ovr = 0;
    period = real'(32 * (tc + 2)) / (1.0 + off / 100.0);
    reader_on = 1'b1;
    host_send(N_CHARS, period, tc * 1000 + int'(off * 10.0) + (two_stop ? 7 : 0));
    wait_pclk(64 * 32 * (tc + 2));
    reader_on = 1'b0;
    wait (reader_idle);
    g = good();
    ok = g == N_CHARS && n_fe == 0 && n_ovr == 0;
    if (ok != want_ok) fails++;
    $display("  %s  TC %2d  %0d stop  %5.1f%%  good %3d/%0d  framing %3d  overrun %3d",
             ok == want_ok ? "PASS" : "FAIL", tc, two_stop ? 2 : 1, off, g, N_CHARS, n_fe, n_ovr);
  endtask

  real offs [9] = '{-10.0, -3.0, -0.5, 0.0, 0.1, 0.5, 2.3, 3.0, 10.0};

  initial begin
    @(posedge clk); #1;
    scc_init();
    $display("tb_scc_rate: 8N1 host off rate into SCC A, x16, %0d characters a run", N_CHARS);
    foreach (offs[i]) run(18, 1'b1, offs[i], offs[i] > -5.0 && offs[i] < 5.0);
    foreach (offs[i]) run(18, 1'b0, offs[i], offs[i] > -5.0 && offs[i] < 5.0);
    foreach (offs[i]) run(8, 1'b1, offs[i], offs[i] > -5.0 && offs[i] < 5.0);
    foreach (offs[i]) run(8, 1'b0, offs[i], offs[i] > -5.0 && offs[i] < 5.0);
    if (fails == 0) $display("PASS"); else $display("FAIL (%0d)", fails);
    $finish;
  end
endmodule
`default_nettype wire
