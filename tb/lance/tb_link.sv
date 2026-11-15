// tb_link: lance_link against Main's side of the frame ring and a
// stand-in for the chip's serial pins.  The DDRAM model answers with a
// random BUSY and random read latency, and checks that a command held
// in BUSY does not change.  The chip side sends frames on TX/TENA (with
// or without an FCS) and takes frames off RX/RENA.  Checks: the header,
// the MAC word, TX frames in the ring with the FCS gone, RX frames
// padded to 60 with a good FCS, the RENA echo, the heartbeat, a peer
// frame cut by a collision (32 jam bits) and sent again, a new epoch
// when the card comes back.  The MAC word is written as Main writes it
// (00:80:10 and the interface's low three bytes, bit 63 valid) and
// survives a restart.  The IP configuration (words 8-15, word 8 bit 63
// valid) reaches the cfg port whole, and again after a restart.  A
// frame from Main that ends while a TX copy is still running goes out
// once.
//   +seed=<n>
`timescale 1ns/1ps
`default_nettype none
module tb_link;
  localparam logic [31:0] POLY = 32'hEDB8_8320, RESIDUE = 32'hDEBB_20E3;
  localparam int TXS = 'h200, RXS = 'hA00;

  logic clk = 1'b0;
  always #10.417 clk = ~clk;
  logic rst_n = 1'b0, card_on = 1'b0;

  // TCLK: 5 edges per 12 clocks, as the card makes it
  logic [3:0] acc = 4'd0;
  logic       ck = 1'b0, tclk_rise = 1'b0, tclk_fall = 1'b0;
  always_ff @(posedge clk) begin
    logic [4:0] s;
    s = 5'(acc) + 5'd5;
    acc       <= s >= 5'd12 ? 4'(s - 5'd12) : s[3:0];
    if (s >= 5'd12) ck <= ~ck;
    tclk_rise <= s >= 5'd12 && !ck;
    tclk_fall <= s >= 5'd12 && ck;
  end

  logic        tx = 1'b0, tena = 1'b0;
  logic        rclk_rise, rx, rena, clsn, mac_ok;
  logic [47:0] mac;
  logic        cfg_ok, cfg_wr;
  logic [4:0]  cfg_addr;
  logic [15:0] cfg_data;
  logic [63:0] cfg [0:7];
  always @(posedge clk) if (cfg_wr) cfg[cfg_addr[4:2]][16*cfg_addr[1:0] +: 16] <= cfg_data;
  logic        busy;
  logic [7:0]  bc;
  logic [28:0] addr;
  logic [63:0] dout, din;
  logic        dready = 1'b0, rd, we;
  logic [7:0]  be;

  lance_link dut (
    .clk(clk), .rst_n(rst_n), .card_on(card_on),
    .tclk_rise(tclk_rise), .tclk_fall(tclk_fall), .tx(tx), .tena(tena),
    .rclk_rise(rclk_rise), .rx(rx), .rena(rena), .clsn(clsn), .mac_ok(mac_ok), .mac(mac),
    .cfg_ok(cfg_ok), .cfg_wr(cfg_wr), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
    .ddr_busy(busy), .ddr_burstcnt(bc), .ddr_addr(addr), .ddr_dout(dout), .ddr_dout_ready(dready),
    .ddr_rd(rd), .ddr_din(din), .ddr_be(be), .ddr_we(we)
  );

  // ---- DDRAM: the 64 KB window, words from byte 0x30400000 ----
  logic [63:0] ram [0:8191];
  int          seed;
  logic        busy_q = 1'b0;
  logic        rd_q, we_q;
  logic [28:0] a_q;
  logic [63:0] d_q;
  logic [7:0]  bc_q;
  int          wbeats = 0, nwr = 0;
  logic [28:0] wa;
  typedef struct { int addr; int n; int at; } rdreq_t;
  rdreq_t      rq[$];
  rdreq_t      r;
  longint      now = 0;
  bit          slow = 1'b0;   // BUSY most clocks: long copies

  function automatic int widx(logic [28:0] a);
    if (a < 29'h0608_0000 || a >= 29'h0608_2000) $fatal(1, "DDR access outside the window: %h", a);
    return int'(a - 29'h0608_0000);
  endfunction

  always @(posedge clk) begin
    now++;
    if (rd && we) $fatal(1, "RD and WE together");
    if ((rd_q || we_q) && busy_q && (rd != rd_q || we != we_q || addr != a_q || din != d_q || bc != bc_q))
      $fatal(1, "a command changed while BUSY");
    rd_q <= rd; we_q <= we; a_q <= addr; d_q <= din; bc_q <= bc;
    if (we && !busy) begin
      if (wbeats == 0) begin
        if (bc == 8'd0) $fatal(1, "burst count 0");
        wa = addr;
        wbeats = int'(bc);
      end
      for (int i = 0; i < 8; i++) if (be[i]) ram[widx(wa)][8*i +: 8] = din[8*i +: 8];
      wa = wa + 29'd1;
      wbeats--;
      nwr++;
    end
    if (rd && !busy) begin
      if (wbeats != 0) $fatal(1, "read inside a write burst");
      r.addr = widx(addr);
      r.n    = int'(bc);
      r.at   = int'(now) + 4 + int'($urandom_range(0, 40));
      rq.push_back(r);
    end
    busy   <= slow ? $urandom_range(0, 15) != 0 : $urandom_range(0, 3) == 0;
    busy_q <= busy;
    dready <= 1'b0;
    if (rq.size() != 0 && now >= rq[0].at && $urandom_range(0, 3) != 0) begin
      dready <= 1'b1;
      dout   <= ram[rq[0].addr];
      rq[0].addr++;
      rq[0].n--;
      if (rq[0].n == 0) void'(rq.pop_front());
    end
  end

  function automatic logic [31:0] crc_byte(logic [31:0] c, byte b);
    for (int i = 0; i < 8; i++) c = (c >> 1) ^ ((c[0] ^ b[i]) ? POLY : 32'd0);
    return c;
  endfunction

  // ---- chip side: send a frame on TX ----
  task automatic send(byte f[$], bit fcs);
    logic [31:0] c;
    bit          bits[$];
    c = '1;
    for (int i = 0; i < 64; i++) bits.push_back(i >= 62 || i % 2 == 0);
    foreach (f[k]) begin
      for (int i = 0; i < 8; i++) bits.push_back(f[k][i]);
      c = crc_byte(c, f[k]);
    end
    if (fcs) for (int i = 0; i < 32; i++) bits.push_back(~c[i]);
    @(posedge clk iff tclk_rise);
    foreach (bits[i]) begin
      tena <= 1'b1;
      tx   <= bits[i];
      @(posedge clk iff tclk_rise);
    end
    tena <= 1'b0;
    tx   <= 1'b0;
  endtask

  // ---- chip side: frames taken off RX while RENA, with no TENA ----
  byte rxf[$][$];
  bit  rbits[$];
  logic rena_q = 1'b0, peer = 1'b0, pcut = 1'b0;   // pcut: the frame met a collision
  always @(posedge clk) if (rclk_rise) begin
    if (rena && !dut.echo_q) rbits.push_back(rx);
    if (rena && !dut.echo_q) peer <= 1'b1;
    if (rena && clsn && tena) pcut <= 1'b1;
    if (!rena && rena_q && peer && pcut) begin
      rbits.delete();
      peer <= 1'b0;
      pcut <= 1'b0;
    end else if (!rena && rena_q && peer) begin
      byte f[$];
      int  i, k;
      f.delete();
      for (i = 1; i < rbits.size() && !(rbits[i-1] && rbits[i]); i++) ;
      for (k = i + 1; k + 7 < rbits.size(); k += 8) begin
        byte b;
        for (int j = 0; j < 8; j++) b[j] = rbits[k + j];
        f.push_back(b);
      end
      rxf.push_back(f);
      rbits.delete();
      peer <= 1'b0;
    end
    if (!rena) rbits.delete();
    rena_q <= rena;
  end

  // the echo: RENA with TENA, RX = TX half a bit later
  logic tx_h;
  always @(posedge clk) if (tclk_fall) begin
    tx_h <= tx;
  end
  always @(posedge clk) if (tclk_rise && !dut.p_q && tena && rena && rx !== tx_h && dut.echo_q)
    $fatal(1, "RX does not echo TX");

  // heartbeat: CLSN from 1.0 to 2.0 us after TENA falls
  int   since = 999, hb_lo = 999, hb_hi = -1, nhb = 0;
  logic tena_r = 1'b0;
  always @(posedge clk) if (tclk_rise) begin
    since <= tena ? 0 : since + 1;
    if (!tena && clsn && since < 40) begin
      if (since < hb_lo) hb_lo <= since;
      if (since > hb_hi) hb_hi <= since;
    end
  end

  // word 5 as Main builds it: bytes 0-5 the MAC, byte 7 0x80, little-endian
  function automatic logic [63:0] macword(logic [47:0] m);
    logic [63:0] v = 64'h8000_0000_0000_0000;
    for (int i = 0; i < 6; i++) v[8*i +: 8] = m[47 - 8*i -: 8];
    return v;
  endfunction
  localparam logic [47:0] HOSTMAC = 48'h00_80_10_A4_5B_C6;

  function automatic logic [63:0] w(int i);
    return ram[i];
  endfunction

  task automatic waitc(int n);
    repeat (n) @(posedge clk);
  endtask

  // Main's IP configuration, word 8 (valid) written last
  logic [63:0] ipcfg [0:7];
  task automatic check_cfg(string when);
    int t = 0;
    while (!cfg_ok) begin waitc(1); if (++t > 5000) $fatal(1, "configuration not taken %s", when); end
    waitc(2000);
    for (int i = 0; i < 8; i++) if (cfg[i] != ipcfg[i]) $fatal(1, "cfg word %0d = %h %s", i, cfg[i], when);
  endtask

  function automatic byte fb(int i, int s);
    return byte'(s + i * 13);
  endfunction

  // the TX ring slot n holds f
  task automatic check_tx(int n, byte f[$]);
    int base = TXS + 'h100 * (n % 8);
    if (w(base) != 64'(f.size())) $fatal(1, "TX slot %0d length %0d want %0d", n, w(base), f.size());
    foreach (f[i]) if (ram[base + 1 + i / 8][8 * (i % 8) +: 8] != f[i])
      $fatal(1, "TX slot %0d byte %0d", n, i);
  endtask

  // Main puts f in RX slot n
  task automatic put_rx(int n, byte f[$]);
    int base = RXS + 'h100 * (n % 8);
    ram[base] = 64'(f.size());
    for (int i = 0; i < 256; i++) ram[base + 1 + i] = '0;
    foreach (f[i]) ram[base + 1 + i / 8][8 * (i % 8) +: 8] = f[i];
    ram[3] = 64'(n + 1);
  endtask

  // a received frame: f padded to 60, then a good FCS
  task automatic check_rx(byte g[$], byte f[$]);
    logic [31:0] c;
    int n = f.size() < 60 ? 60 : f.size();
    if (g.size() != n + 4) $fatal(1, "RX frame of %0d bytes, want %0d", g.size(), n + 4);
    c = '1;
    foreach (g[i]) begin
      if (i < n && g[i] != (i < f.size() ? f[i] : 8'h00)) $fatal(1, "RX byte %0d", i);
      c = crc_byte(c, g[i]);
    end
    if (c != RESIDUE) $fatal(1, "RX frame FCS");
  endtask

  initial begin
    byte a[$], b[$], d[$], e[$];
    int  t;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    foreach (ram[i]) ram[i] = {$urandom, $urandom};
    ram[2] = 64'd57; ram[3] = 64'd9;         // stale counters
    ram[5] = 64'd0;
    ram[8] = 64'd0;
    waitc(10);
    rst_n = 1'b1;
    waitc(100);
    if (dut.rd_q || dut.we_q) $fatal(1, "DDR used with the card off");
    card_on = 1'b1;

    // header: words 1-4 cleared, then word 0
    t = 0;
    while (w(0) != {32'h4339_454E, 32'd1}) begin waitc(1); if (++t > 20000) $fatal(1, "no header"); end
    for (int i = 1; i < 5; i++) if (w(i) != 64'd0) $fatal(1, "header word %0d = %h", i, w(i));
    waitc(3000);
    if (mac_ok) $fatal(1, "MAC without word 5");

    // Main opens the interface and writes the MAC
    ram[5] = macword(HOSTMAC);
    t = 0;
    while (!mac_ok) begin waitc(1); if (++t > 5000) $fatal(1, "MAC not taken"); end
    if (mac != HOSTMAC) $fatal(1, "MAC %h", mac);
    if (cfg_ok) $fatal(1, "configuration valid without word 8");
    for (int i = 0; i < 8; i++) ipcfg[i] = {$urandom, $urandom};
    ipcfg[0][63] = 1'b1;
    for (int i = 7; i >= 0; i--) ram[8 + i] = ipcfg[i];
    check_cfg("");

    // TX: a frame with its FCS, then one without
    for (int i = 0; i < 60; i++) a.push_back(fb(i, 3));
    for (int i = 0; i < 100; i++) b.push_back(fb(i, 7));
    send(a, 1);
    t = 0;
    while (w(1) != 64'd1) begin waitc(1); if (++t > 20000) $fatal(1, "TX frame 1 not put"); end
    check_tx(0, a);
    repeat (200) @(posedge clk iff tclk_rise);
    send(b, 0);
    t = 0;
    while (w(1) != 64'd2) begin waitc(1); if (++t > 20000) $fatal(1, "TX frame 2 not put"); end
    check_tx(1, b);
    if (hb_lo != 10 || hb_hi != 19) $fatal(1, "heartbeat %0d-%0d bit times after TENA", hb_lo, hb_hi);

    // RX: a short frame (padded), then a long one
    for (int i = 0; i < 20; i++) d.push_back(fb(i, 11));
    for (int i = 0; i < 300; i++) e.push_back(fb(i, 5));
    ram[2] = 64'd2;
    put_rx(0, d);
    t = 0;
    while (rxf.size() == 0) begin waitc(1); if (++t > 100000) $fatal(1, "RX frame 1 not sent"); end
    check_rx(rxf.pop_front(), d);
    t = 0;
    while (w(4) != 64'd1) begin waitc(1); if (++t > 20000) $fatal(1, "rx_rd not bumped"); end

    // a collision: the chip starts while the second frame goes out
    put_rx(1, e);
    @(posedge clk iff rena && dut.p_q != 0);
    repeat (300) @(posedge clk iff tclk_rise);
    fork send(a, 1); join_none
    @(posedge clk iff dut.p_q == 2);
    if (!clsn) $fatal(1, "no CLSN with both sending");
    t = 0;
    while (dut.p_q != 0) begin @(posedge clk iff tclk_fall); #1; t++; end
    if (t != 32) $fatal(1, "jam of %0d bits", t);
    wait (!tena);
    t = 0;
    while (rxf.size() == 0) begin waitc(1); if (++t > 200000) $fatal(1, "RX frame 2 not sent again"); end
    check_rx(rxf.pop_front(), e);
    t = 0;
    while (w(4) != 64'd2) begin waitc(1); if (++t > 20000) $fatal(1, "rx_rd not bumped"); end
    if (w(1) != 64'd2) $fatal(1, "a collided TX frame was put");

    // a frame from Main sent while a long TX copy runs: sent once
    a.delete();
    for (int i = 0; i < 1500; i++) a.push_back(fb(i, 9));
    d.delete();
    for (int i = 0; i < 30; i++) d.push_back(fb(i, 2));
    fork send(a, 1); join_none
    @(posedge clk iff tena);
    put_rx(2, d);
    slow = 1'b1;
    @(posedge clk iff !tena);
    @(posedge clk iff dut.p_done);
    if (!dut.pend) $fatal(1, "the TX copy ended before the RX frame");
    t = 0;
    while (w(1) != 64'd3) begin waitc(1); if (++t > 50000) $fatal(1, "TX frame 3 not put"); end
    slow = 1'b0;
    check_tx(2, a);
    t = 0;
    while (w(4) != 64'd3) begin waitc(1); if (++t > 20000) $fatal(1, "rx_rd not bumped"); end
    waitc(5000);
    if (rxf.size() != 1) $fatal(1, "RX frame 3 sent %0d times", rxf.size());
    check_rx(rxf.pop_front(), d);

    // card off and on (a machine reset): a new epoch, Main's MAC kept
    card_on = 1'b0;
    waitc(2000);
    if (mac_ok) $fatal(1, "MAC held with the card off");
    if (cfg_ok) $fatal(1, "configuration held with the card off");
    card_on = 1'b1;
    t = 0;
    while (w(0) != {32'h4339_454E, 32'd2}) begin waitc(1); if (++t > 20000) $fatal(1, "no second header"); end
    if (w(1) != 64'd0) $fatal(1, "tx_wr not cleared");
    if (w(5) != macword(HOSTMAC)) $fatal(1, "word 5 overwritten: %h", w(5));
    t = 0;
    while (!mac_ok) begin waitc(1); if (++t > 5000) $fatal(1, "MAC not taken again"); end
    if (mac != HOSTMAC) $fatal(1, "MAC %h after the restart", mac);
    check_cfg("after the restart");
    $display("PASS tb_link seed %0d (%0d DDR write beats)", seed, nwr);
    $finish;
  end

  initial begin
    #50ms $fatal(1, "timeout");
  end
endmodule
`default_nettype wire
