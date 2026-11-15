// tb_lance: the LANCE card against vectors recorded from the Go Am7990
// and its board (tb/lance/vec/*.vec, see docs/theory/LANCE_CARD.md sec. 8).
//
// Z-Bus side: a CPU model runs the script's I/O and acknowledge cycles,
// grants /BUSREQ through /BAI when it is between cycles, and a memory
// answers the card's master cycles with a random /WAIT.  Cable side, as
// a transceiver presents it: RENA echoes TENA, CLSN while the card
// transmits over a frame arriving, a heartbeat on CLSN 1-2 us after
// TENA falls.  Frames the card sends come back on RX after a 100-bit
// gap; a peer frame hit by a collision is cut after 32 jam bits and
// sent again (internal loopback: the chip's own stream is watched
// instead).  Bus events are
// compared in order with the X lines, and so are the interrupt pin's
// (as two streams: the Go model takes a frame whole, the chip as it
// comes, which moves the pin against the bus), every frame with the Y lines,
// memory at the end with the Z lines.  A transmission must start 96 bit
// times after the card's last one, and in recorded vectors with the
// cable quiet as long.
//   +vec=<file>  +seed=<n>  +grant_delay=<clocks before a bus grant>
// Directed vectors (N 1: no event check, N 2: no frame check either)
// add script ops: G n grant delay, J frame sent at once, A wait for
// TENA, B wait for a frame arriving, C wait for a transmit copy, D cable
// idle, K n peer gap, U n CLSN from bit n of every transmission,
// L n RENA echo lost from bit n, H 0/1 heartbeat, Q n transmissions so
// far, Z n CLSN from bit n of the next arriving frame.  A collided
// transmission must jam 32 bits, not its CRC (TM p.1-11); a retry
// waits its backoff slots; before TENA the silo holds at most 32
// transmit bytes (TM p.4-6).
// TINT must not rise while the frame is still on the wire (TM p.1-15).
`timescale 1ns/1ps
`default_nettype none
module tb_lance;
  localparam logic [3:0] ST_IO = 4'b0010, ST_VI_ACK = 4'b0111;

  logic clk = 1'b0;
  always #10.417 clk = ~clk;

  // ---- Z-Bus ----
  logic [15:0] cpu_ad = 16'hFFFF, mem_ad;
  logic        cpu_ad_oe = 1'b0, mem_ad_oe;
  logic        cpu_as_n = 1'b1, cpu_ds_n = 1'b1, cpu_rw = 1'b1, cpu_bw = 1'b0;
  logic [3:0]  cpu_st = 4'b0000;
  logic        bai_n = 1'b1, iei = 1'b1, mem_wait_n;
  logic        rst_n = 1'b0;

  logic [15:0] c_ad_out, c_ad_oe, ad_wire, ad_q;
  logic        c_bao_n, c_busreq_n, c_bus_oe, c_vi_n, c_ieo;
  logic        c_as_n, c_ds_n, c_rw, c_bw, c_mreq_n;
  logic [3:0]  c_st;
  logic [7:0]  c_ahi;
  logic        tclk_rise, tclk_fall, c_tx, c_tena;
  logic        rx = 1'b0, prena = 1'b0, echo = 1'b0, rena, clsn;

  logic as_n, ds_n, r_w, b_w;
  logic [3:0] st;
  assign as_n = c_bus_oe ? c_as_n : cpu_as_n;
  assign ds_n = c_bus_oe ? c_ds_n : cpu_ds_n;
  assign r_w  = c_bus_oe ? c_rw : cpu_rw;
  assign b_w  = c_bus_oe ? c_bw : cpu_bw;
  assign st   = c_bus_oe ? c_st : cpu_st;
  assign ad_wire = (c_ad_oe & c_ad_out | ~c_ad_oe) & (cpu_ad_oe ? cpu_ad : 16'hFFFF) &
                   (mem_ad_oe ? mem_ad : 16'hFFFF);
  always_ff @(posedge clk) ad_q <= ad_wire;

  am7990_lance_card dut (
    .clk(clk), .rst_n(rst_n), .enable(1'b1),
    .ad_bus(ad_q), .as_n(as_n), .ds_n(ds_n), .r_w(r_w), .b_w(b_w), .st(st),
    .intack_n(st != ST_VI_ACK), .iei(iei), .bai_n(bai_n), .bao_n(c_bao_n),
    .busreq_n(c_busreq_n), .ad_out(c_ad_out), .ad_oe(c_ad_oe), .bus_oe(c_bus_oe),
    .vi_n(c_vi_n), .ieo(c_ieo), .wait_n(mem_wait_n), .busreq_in_n(c_busreq_n),
    .wait_pd(), .mac_ok(1'b0), .mac(48'd0),
    .rom_ok(1'b0), .rom_wr(1'b0), .rom_addr(14'd0), .rom_data(8'd0),
    .cfg_ok(1'b0), .cfg_wr(1'b0), .cfg_addr(5'd0), .cfg_data(16'd0),
    .as_n_o(c_as_n), .ds_n_o(c_ds_n), .r_w_o(c_rw), .b_w_o(c_bw), .mreq_n_o(c_mreq_n),
    .st_o(c_st), .a_hi_o(c_ahi),
    .tclk_rise(tclk_rise), .tclk_fall(tclk_fall), .tx(c_tx), .tena(c_tena),
    .rclk_rise(tclk_rise), .rx(rx), .rena(rena), .clsn(clsn)
  );

  // ---- vectors ----
  string  vfile;
  int     intl = 0;
  int     noev = 0;
  string  scr[$];
  string  xev[$], xint[$];
  string  yfr[$];
  logic [7:0] mem [int];
  logic [7:0] zmem [int];
  int     ei = 0, ii = 0, yi = 0, nev = 0;
  int     board_mode = 0;
  string  dl[$];

  task automatic load(string f);
    int fd, a, d;
    string line, tag;
    fd = $fopen(f, "r");
    if (fd == 0) $fatal(1, "cannot open %s", f);
    while ($fgets(line, fd)) begin
      if (line.len() > 0 && line[line.len()-1] == "\n") line = line.substr(0, line.len()-2);
      if (line.len() < 1 || line[0] == "#") continue;
      tag = line.substr(0, 0);
      case (tag)
        "O": void'($sscanf(line, "O %d", intl));
        "N": void'($sscanf(line, "N %d", noev));
        "M": begin void'($sscanf(line, "M %h %h", a, d)); mem[a] = 8'(d); end
        "Z": begin void'($sscanf(line, "Z %h %h", a, d)); zmem[a] = 8'(d); end
        "S": scr.push_back(line.substr(2, line.len()-1));
        "X": if (line[2] == "I") xint.push_back(line.substr(2, line.len()-1));
             else xev.push_back(line.substr(2, line.len()-1));
        "Y": yfr.push_back(line.substr(2, line.len()-1));
        "D": begin board_mode = 1; dl.push_back(line); end
        "V": board_mode = 1;
        default: $fatal(1, "bad line: %s", line);
      endcase
    end
    $fclose(fd);
  endtask

  function automatic logic [7:0] rdm(int a);
    return mem.exists(a) ? mem[a] : 8'hFF;
  endfunction

  // ---- event check ----
  task automatic ev(string s);
    nev++;
    if (board_mode || noev != 0) return;
    s = s.toupper();
    if (s[0] == "I") begin
      if (ii >= xint.size()) $fatal(1, "%s: extra pin event %0d '%s'", vfile, nev, s);
      if (s != xint[ii]) $fatal(1, "%s: pin event %0d: got '%s' want '%s'", vfile, ii, s, xint[ii]);
      ii++;
      return;
    end
    if (ei >= xev.size()) $fatal(1, "%s: extra event %0d '%s'", vfile, nev, s);
    if (s != xev[ei]) $fatal(1, "%s: event %0d: got '%s' want '%s'", vfile, ei, s, xev[ei]);
    ei++;
  endtask

  logic breq_q = 1'b1, vi_q = 1'b1;
  always @(posedge clk) begin
    if (rst_n) begin
      if (c_busreq_n != breq_q) ev(c_busreq_n ? "L" : "Q");
      if (c_vi_n != vi_q) ev(c_vi_n ? "I 0" : "I 1");
    end
    breq_q <= c_busreq_n;
    vi_q   <= c_vi_n;
  end

  // ---- bus grant: only between CPU cycles, +grant_delay clocks at the earliest ----
  logic cpu_busy = 1'b0;
  int   grant_delay = 0, gwait = 0;
  always @(posedge clk) begin
    if (c_busreq_n) begin
      bai_n <= 1'b1;
      gwait <= 0;
    end else if (gwait < grant_delay) gwait <= gwait + 1;
    else if (!cpu_busy && $urandom_range(3) == 0) bai_n <= 1'b0;
  end

  // ---- memory: answers the card's master cycles ----
  logic [23:0] maddr;
  logic [15:0] mwd;
  logic        mds_q = 1'b1;
  int          mwait;
  always @(posedge clk) begin
    if (c_bus_oe && !c_as_n) maddr <= {c_ahi, ad_wire};
    if (c_bus_oe && !c_as_n && !c_bw && ad_wire[0]) $fatal(1, "%s: word cycle at odd %h", vfile, ad_wire);
    if (c_bus_oe && !c_ds_n) begin
      if (mds_q) mwait = $urandom_range(14);
      else if (mwait > 0) mwait--;
      if (!c_rw) mwd <= ad_wire;
    end
    mds_q <= !(c_bus_oe && !c_ds_n) ? 1'b1 : 1'b0;
    if (!mds_q && !(c_bus_oe && !c_ds_n)) begin
      int a;
      a = int'(maddr);
      if (c_rw && c_bw) ev($sformatf("C %06X %02X", maddr, rdm(a)));
      else if (c_rw) ev($sformatf("R %06X %02X%02X", maddr, rdm(a), rdm(a + 1)));
      else if (c_bw) begin
        mem[a] = a[0] ? mwd[7:0] : mwd[15:8];
        ev($sformatf("B %06X %02X", maddr, mem[a]));
      end else begin
        mem[a] = mwd[15:8];
        mem[a + 1] = mwd[7:0];
        ev($sformatf("W %06X %04X", maddr, mwd));
      end
    end
  end
  always_comb begin
    mem_wait_n = !(c_bus_oe && !c_ds_n && (mds_q || mwait > 0));
    mem_ad_oe  = c_bus_oe && !c_ds_n && c_rw && !mds_q && mwait == 0;
    mem_ad     = {rdm(int'(maddr) & ~1), rdm(int'(maddr) | 1)};
  end

  // ---- CPU cycles ----
  task automatic grab();
    forever begin
      @(posedge clk); #1;
      if (bai_n && c_busreq_n) begin
        cpu_busy = 1'b1;
        @(posedge clk); #1;
        if (bai_n) return;
        cpu_busy = 1'b0;
      end
    end
  endtask

  task automatic cyc(input logic [3:0] stv, input logic [15:0] port, input logic rd,
                     input logic [15:0] wd, output logic [15:0] rdv, output logic [15:0] oe);
    grab();
    cpu_st = stv; cpu_rw = rd; cpu_bw = 1'b0; cpu_ad = port; cpu_ad_oe = stv != ST_VI_ACK;
    @(posedge clk); #1 cpu_as_n = 1'b0;
    repeat (3) @(posedge clk);
    #1 cpu_as_n = 1'b1;
    @(posedge clk); #1;
    if (rd) cpu_ad_oe = 1'b0; else cpu_ad = wd;
    @(posedge clk); #1 cpu_ds_n = 1'b0;
    repeat (12) @(posedge clk);
    rdv = ad_wire;
    oe  = c_ad_oe;
    #1 cpu_ds_n = 1'b1;
    @(posedge clk); #1 cpu_ad_oe = 1'b0; cpu_st = 4'b0000;
    @(posedge clk); #1 cpu_busy = 1'b0;
  endtask

  task automatic wr(input logic [15:0] port, input logic [15:0] d);
    logic [15:0] r, o;
    cyc(ST_IO, port, 1'b0, d, r, o);
  endtask

  // ---- cable: capture TX, loop it back on RX ----
  byte    rxq[$][$];
  bit     txb[$];
  logic   tena_q = 1'b0;
  int     quiet = 0;
  logic   wtx, wtena;
  assign wtx   = intl ? dut.u_chip.ttx : c_tx;
  assign wtena = intl ? dut.u_chip.ttena : c_tena;

  always @(posedge clk) if (tclk_fall) begin
    if (wtena) txb.push_back(wtx);
    if (tena_q && !wtena && !tx_col) begin
      byte f[$];
      int  i, k;
      string h;
      f.delete();
      for (i = 1; i < txb.size() && !(txb[i-1] && txb[i]); i++) ;
      for (k = i + 1; k + 7 < txb.size(); k += 8) begin
        byte b;
        for (int j = 0; j < 8; j++) b[j] = txb[k + j];
        f.push_back(b);
      end
      h = "";
      foreach (f[j]) h = {h, $sformatf("%02X", f[j])};
      h = h.toupper();
      if (noev < 2) begin
        if (yi >= yfr.size()) $fatal(1, "%s: extra frame %s", vfile, h);
        if (h != yfr[yi]) $fatal(1, "%s: frame %0d: got %s want %s", vfile, yi, h, yfr[yi]);
      end
      yi++;
      if (!intl) rxq.push_back(f);
      txb.delete();
    end
    // a jam is any 32 bits but the frame's CRC (TM p.1-11)
    if (tena_q && !wtena && tx_col) begin
      int  i;
      logic [31:0] crc, jam;
      crc = '1;
      for (i = 1; i < txb.size() && !(txb[i-1] && txb[i]); i++) ;
      for (int k = i + 1; k < txb.size() - 32; k++)
        crc = (crc >> 1) ^ ((crc[0] ^ txb[k]) ? 32'hEDB88320 : 32'd0);
      for (int k = 0; k < 32; k++) jam[k] = txb[txb.size() - 32 + k];
      if (jam == ~crc) $fatal(1, "%s: the jam is the CRC", vfile);
    end
    if (tena_q && !wtena) txb.delete();
    tena_q <= wtena;
  end

  always @(posedge clk) if (tclk_rise) quiet <= (wtena || rena) ? 0 : quiet + 1;

  // transceiver: RENA echo, collision, heartbeat
  int peer_gap = 100, fault_at = 0, lose_at = 0, hb_on = 1;
  int txbits = 0, hbc = 255, ntx = 0, own = 999, col_at = 0, rcol = 0;
  logic hb, tx_col = 1'b0, pcol = 1'b0;
  assign hb   = hb_on != 0 && hbc >= 10 && hbc < 20;
  assign clsn = !intl && ((c_tena && prena) || (fault_at != 0 && c_tena && txbits >= fault_at) || hb || pcol);
  assign rena = prena || echo;
  always @(posedge clk) if (tclk_fall) begin
    echo   <= c_tena && !(lose_at != 0 && txbits >= lose_at);
    txbits <= c_tena ? txbits + 1 : 0;
    hbc    <= c_tena ? 0 : (hbc < 255 ? hbc + 1 : hbc);
  end
  always @(posedge clk) if (tclk_rise) own <= wtena ? 0 : own + 1;

  // a transmission starts the gap after the last (TM p.1-17)
  logic tena_r = 1'b0;
  always @(posedge clk) begin
    if (wtena && !tena_r) begin
      ntx++;
      if (!intl && own < 95) $fatal(1, "%s: TENA rose %0d bit times after the last", vfile, own);
      if (!intl && noev == 0 && (prena || quiet < 95))
        $fatal(1, "%s: TENA rose with RENA %b after %0d quiet bit times", vfile, prena, quiet);
    end
    if (wtena && !tena_r) tx_col <= 1'b0;
    else if (wtena && clsn && !hb && !tx_col) begin
      tx_col <= 1'b1;
      col_at <= txbits;
    end
    if (!wtena && tena_r && tx_col && txbits - col_at < 32)
      $fatal(1, "%s: jam of %0d bits", vfile, txbits - col_at);
    if (!dut.u_chip.ttena && dut.u_chip.stbytes > 6'd32)
      $fatal(1, "%s: %0d transmit bytes before TENA", vfile, dut.u_chip.stbytes);
    tena_r <= wtena;
  end
  logic tint_r = 1'b0;
  // retry n waits r slot times, r uniform in [0, 2^min(n,10))
  // (TM p.1-11), from the chip's generator (LFSR ACE1, taps B400)
  logic [15:0] lfsr_m = 16'hACE1;
  int   bo_r = -1, ncol = 0;
  logic bo_rena = 1'b0;
  always @(posedge clk) begin
    if (dut.u_chip.stop) lfsr_m <= 16'hACE1;
    if (wtena && !tena_r) begin
      if (bo_r >= 0 && own < bo_r * 512 - 2)
        $fatal(1, "%s: retry %0d bit times after the jam, backoff %0d slots", vfile, own, bo_r);
      if (bo_r >= 0 && !bo_rena && grant_delay == 0 && own > (bo_r * 512 > 96 ? bo_r * 512 : 96) + 4)
        $fatal(1, "%s: retry %0d bit times after the jam, backoff %0d slots", vfile, own, bo_r);
      bo_r    <= -1;
      bo_rena <= 1'b0;
    end
    if (!wtena && rena) bo_rena <= 1'b1;
    if (wtena && clsn && !hb && !tx_col) ncol <= ncol + 1;
    else if ((!wtena && tena_r && !tx_col) || (dut.u_chip.tint && !tint_r)) ncol <= 0;
    if (dut.u_chip.bo_load) begin
      int k;
      k = ncol > 10 ? 10 : ncol;
      if (k == 0) $fatal(1, "%s: backoff without a collision", vfile);
      if (int'(dut.u_chip.bo_slots) >= (1 << k) || dut.u_chip.bo_slots != (lfsr_m[9:0] & 10'((1 << k) - 1)))
        $fatal(1, "%s: backoff %0d slots, retry %0d", vfile, dut.u_chip.bo_slots, k);
      lfsr_m <= {1'b0, lfsr_m[15:1]} ^ (lfsr_m[0] ? 16'hB400 : 16'h0000);
      bo_r   <= int'(dut.u_chip.bo_slots);
    end
  end
  always @(posedge clk) begin
    if (dut.u_chip.tint && !tint_r && wtena) $fatal(1, "%s: TINT with the frame on the wire", vfile);
    tint_r <= dut.u_chip.tint;
  end

  // wait states the memory caused
  int tw = 0;
  always @(posedge clk)
    if (tclk_rise && dut.u_chip.u_dma.st_q == 2'd2 && dut.u_chip.u_dma.h_q == 4'd7 && !mem_wait_n) tw++;

  byte jq[$][$];
  initial begin : rxdrv
    forever begin
      byte f[$];
      int  jam;
      @(posedge clk);
      if (jq.size() != 0) f = jq.pop_front();
      else if (rxq.size() == 0 || quiet < peer_gap) continue;
      else f = rxq.pop_front();
      jam = -1;
      for (int i = 0; i < 64 + 8 * f.size() && jam < 32; i++) begin
        @(posedge clk iff tclk_fall); #1;
        if (jam < 0 && c_tena && !intl) jam = 0;
        if (jam < 0 && rcol != 0 && i >= rcol) begin
          jam  = 0;
          pcol = 1'b1;
          rcol = 0;
        end
        prena = 1'b1;
        if (jam >= 0) begin
          rx = jam[0];
          jam++;
        end else rx = (i < 64) ? ((i >= 62) || (i % 2 == 0)) : f[(i - 64) / 8][(i - 64) % 8];
      end
      @(posedge clk iff tclk_fall); #1;
      prena = 1'b0;
      rx    = 1'b0;
      pcol  = 1'b0;
      if (jam >= 0) rxq.push_front(f);
    end
  end

  // ---- script ----
  task automatic tticks(int n);
    repeat (n) @(posedge clk iff tclk_rise);
  endtask

  function automatic int hex2(string s, int i);
    return s.substr(i, i + 1).atohex();
  endfunction

  initial begin
    int seed;
    logic [15:0] r, o;
    if (!$value$plusargs("vec=%s", vfile)) $fatal(1, "+vec= missing");
    if ($value$plusargs("seed=%d", seed)) void'($urandom(seed));
    void'($value$plusargs("grant_delay=%d", grant_delay));
    load(vfile);
    repeat (8) @(posedge clk);
    #1 rst_n = 1'b1;
    repeat (8) @(posedge clk);

    if (board_mode) begin
      int p, s, bw, drv, v;
      wr(16'h0702, 16'h0002);
      foreach (dl[i]) begin
        void'($sscanf(dl[i], "D %h %h %d %d %h", p, s, bw, drv, v));
        begin
          logic [3:0] stv;
          stv = 4'(s);
          grab();
          cpu_st = stv; cpu_rw = 1'b1; cpu_bw = 1'(bw); cpu_ad = 16'(p); cpu_ad_oe = 1'b1;
          @(posedge clk); #1 cpu_as_n = 1'b0;
          repeat (3) @(posedge clk);
          #1 cpu_as_n = 1'b1;
          @(posedge clk); #1 cpu_ad_oe = 1'b0;
          @(posedge clk); #1 cpu_ds_n = 1'b0;
          repeat (12) @(posedge clk);
          r = ad_wire;
          o = c_ad_oe;
          #1 cpu_ds_n = 1'b1;
          @(posedge clk); #1 cpu_st = 4'b0000; cpu_bw = 1'b0;
          @(posedge clk); #1 cpu_busy = 1'b0;
        end
        if ((o != 16'h0000) != (drv != 0) || (drv != 0 && r != 16'(v)))
          $fatal(1, "board: %s: drive %h value %h", dl[i], o, r);
      end
      if (dut.VECTOR != 8'h88) $fatal(1, "board: vector strap %h", dut.VECTOR);
      $display("PASS board (%0d cycles)", dl.size());
      $finish;
    end

    foreach (scr[k]) begin
      string op;
      int a, d, n;
      op = scr[k].substr(0, 0);
      case (op)
        "W": begin
          void'($sscanf(scr[k], "W %d %h", a, d));
          wr(a ? 16'h0702 : 16'h0700, 16'(d));
        end
        "R": begin
          void'($sscanf(scr[k], "R %d %h", a, d));
          cyc(ST_IO, a ? 16'h0702 : 16'h0700, 1'b1, 16'h0000, r, o);
          if (o != 16'hFFFF || r != 16'(d))
            $fatal(1, "%s: script %0d '%s': read %h (oe %h)", vfile, k, scr[k], r, o);
        end
        "I": begin
          n = 0;
          while (c_vi_n) begin
            @(posedge clk);
            n++; if (n > 40000000) $fatal(1, "%s: script %0d: no interrupt (event %0d of %0d)",
                                      vfile, k, ei, xev.size());
          end
        end
        "V": begin
          void'($sscanf(scr[k], "V %h", d));
          iei = 1'b0;
          cyc(ST_VI_ACK, 16'h0000, 1'b1, 16'h0000, r, o);
          if (o != 16'h0000) $fatal(1, "%s: acknowledge answered with IEI low", vfile);
          if (c_ieo) $fatal(1, "%s: IEO high while interrupting", vfile);
          iei = 1'b1;
          cyc(ST_VI_ACK, 16'h0000, 1'b1, 16'h0000, r, o);
          if (o != 16'h00FF || r[7:0] != 8'(d)) $fatal(1, "%s: vector %h oe %h", vfile, r, o);
        end
        "F", "J": begin
          byte f[$];
          string h;
          f.delete();
          h = scr[k].substr(2, scr[k].len() - 1);
          for (int i = 0; i < h.len(); i += 2) f.push_back(8'(hex2(h, i)));
          if (op == "J") jq.push_back(f);
          else rxq.push_back(f);
        end
        "G": void'($sscanf(scr[k], "G %d", grant_delay));
        "A": wait (wtena);
        "B": wait (prena);
        "K": void'($sscanf(scr[k], "K %d", peer_gap));
        "U": void'($sscanf(scr[k], "U %d", fault_at));
        "L": void'($sscanf(scr[k], "L %d", lose_at));
        "H": void'($sscanf(scr[k], "H %d", hb_on));
        "Z": void'($sscanf(scr[k], "Z %d", rcol));
        "Q": begin
          void'($sscanf(scr[k], "Q %d", n));
          if (ntx != n) $fatal(1, "%s: script %0d: %0d transmissions, want %0d", vfile, k, ntx, n);
        end
        "C": wait (dut.u_chip.q == 3'd6);
        "D": if (wtena || rena) $fatal(1, "%s: script %0d: cable busy", vfile, k);
        "P": begin
          void'($sscanf(scr[k], "P %h %h", a, d));
          mem[a] = 8'(d >> 8);
          mem[a + 1] = 8'(d);
        end
        "T": begin
          void'($sscanf(scr[k], "T %d", n));
          tticks(n);
        end
        "E": begin
          int last;
          n = 0;
          while (ei < xev.size() || ii < xint.size()) begin
            @(posedge clk);
            n++; if (n > 4000000) $fatal(1, "%s: stalled at event %0d of %0d (want '%s')",
                                      vfile, ei, xev.size(), xev[ei]);
          end
          last = nev;
          tticks(4000);
          if (noev == 0 && nev != last) $fatal(1, "%s: events after the end", vfile);
          if (noev < 2 && yi != yfr.size()) $fatal(1, "%s: %0d frames of %0d", vfile, yi, yfr.size());
          n = 0;
          foreach (zmem[z])
            if (rdm(z) != zmem[z]) begin
              $display("%s: memory %06X = %02X want %02X", vfile, z, rdm(z), zmem[z]);
              n++;
            end
          if (n != 0) $fatal(1, "%s: %0d memory mismatches", vfile, n);
        end
        default: $fatal(1, "bad op %s", scr[k]);
      endcase
    end
    $display("PASS %s (%0d events, %0d frames, %0d wait states)", vfile, ei + ii, yi, tw);
    $finish;
  end
`ifdef DBG
  dbg u_dbg ();
`endif
endmodule
`default_nettype wire
