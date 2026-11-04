// Short disk_stream case for netlist runs: a hard disk probe and a
// streaming client on slot 2 while floppy 1 reads, writes record and
// staging scratch blocks and an image block, then the idle flush.  About
// 0.2 s on the RTL; prints progress every 200 us of sim time.
`timescale 1ns/1ps
`default_nettype none
module tb_disk_stream;
  localparam int NSLOT = 4;
  localparam int QUIET = 20000;
  logic clk = 1'b0, rst_n = 1'b0, core_rst_n = 1'b1;
  always #10 clk = ~clk;

  // ---- DUT ---------------------------------------------------------------------------
  logic [1:0][11:0]       bpc = '0;
  logic [1:0]             hd_sel = 2'b01;
  logic [NSLOT-1:0]       img_mounted = '0;
  logic                   img_readonly = 1'b0;
  logic [63:0]            img_size = 64'd0;
  logic [NSLOT-1:0][31:0] h_lba;
  logic [NSLOT-1:0][5:0]  h_blk_cnt;
  logic [NSLOT-1:0]       h_rd, h_wr, h_ack = '0;
  logic [13:0]            h_buff_addr = 14'd0;
  logic [7:0]             h_buff_dout = 8'h00, h_buff_din;
  logic                   h_buff_wr = 1'b0;
  logic [NSLOT-1:0]       d_mounted;
  logic                   d_readonly;
  logic [63:0]            d_size;
  logic [NSLOT-1:0][31:0] d_lba = '0;
  logic [NSLOT-1:0]       d_rd = '0, d_wr = '0, d_ack, d_scr = '0;
  logic [8:0]             d_buff_addr;
  logic [7:0]             d_buff_dout;
  logic [NSLOT-1:0][7:0]  d_buff_din;
  logic                   d_buff_wr;
  logic                   busy, wb_busy, fmt_full;
  logic [NSLOT-1:0]       resident;
  logic [1:0][15:0]       ld_min, ld_max;

  disk_stream #(.UMAX(136), .NFMT(4), .QUIET(QUIET)) dut (.*);

  int errors = 0;
  task automatic fail(input string m);
    errors++;
    $display("FAIL %s (at %0t)", m, $time);
    if (errors > 20) $fatal(1, "too many errors");
  endtask

  // ---- images: the file (hps side) and the expected medium (shadow) ---------------
  localparam int MAXB = 2400 * 512;
  byte    file   [NSLOT][MAXB];
  byte    shadow [NSLOT][MAXB];
  int     fsize  [NSLOT];
  logic   fro    [NSLOT];

  // ---- hps_io model ---------------------------------------------------------------
  int hps_wr_delay = 0;
  int nreq_rd [NSLOT] = '{0, 0, 0, 0}, nreq_wr [NSLOT] = '{0, 0, 0, 0};
  int blk_rd  [NSLOT] = '{0, 0, 0, 0};
  initial forever begin
    @(posedge clk);
    for (int s = 0; s < NSLOT; s++) begin
      if (h_rd[s] || h_wr[s]) begin
        int lba, n, rd;
        repeat ($urandom_range(20, 300) + (h_rd[s] ? 0 : hps_wr_delay)) @(posedge clk);
        if (!(h_rd[s] || h_wr[s])) continue;
        if (h_rd[s] && h_wr[s]) fail("rd and wr together");
        lba = h_lba[s]; n = (h_blk_cnt[s] + 1) * 512; rd = h_rd[s];
        if (n > 16384) fail($sformatf("request of %0d bytes", n));
        if (rd) begin nreq_rd[s]++; blk_rd[s] += n / 512; end else nreq_wr[s]++;
        h_ack[s] <= 1'b1;
        h_buff_addr <= 14'd0;
        @(posedge clk);
        for (int i = 0; i < n; i++) begin
          h_buff_addr <= 14'(i);
          repeat ($urandom_range(2, 5)) @(posedge clk);
          if (rd) begin
            h_buff_dout <= (lba * 512 + i < fsize[s]) ? file[s][lba * 512 + i] : 8'h00;
            h_buff_wr   <= 1'b1;
            @(posedge clk);
            h_buff_wr   <= 1'b0;
          end else begin
            if (lba * 512 + i >= fsize[s]) begin fail($sformatf("slot %0d write past the end", s)); break; end
            if (fro[s]) begin fail("write to a read-only image"); break; end
            file[s][lba * 512 + i] = h_buff_din;
            @(posedge clk);
          end
        end
        h_ack[s] <= 1'b0;
        @(posedge clk);
      end
    end
  end

  // ---- drive clients ----------------------------------------------------------------
  // whole-vector write: a part-select write from a timed process does not
  // wake the logic reading it (Verilator)
  task automatic set_lba(input int s, input logic [31:0] lba);
    logic [NSLOT-1:0][31:0] t;
    t = d_lba;
    t[s] = lba;
    d_lba = t;
  endtask

  byte  wbuf [NSLOT][512];
  logic dmounted_seen [NSLOT];
  logic [63:0] dsize [NSLOT];
  logic        dro   [NSLOT];
  always_ff @(posedge clk)
    for (int s = 0; s < NSLOT; s++) d_buff_din[s] <= wbuf[s][d_buff_addr];
  int nmount [NSLOT] = '{0, 0, 0, 0};
  always @(posedge clk)
    for (int s = 0; s < NSLOT; s++)
      if (d_mounted[s]) begin
        if (core_rst_n) nmount[s]++;
        dmounted_seen[s] = 1'b1; dsize[s] = d_size; dro[s] = d_readonly;
      end

  // scratch model: floppy staging (LBA 128 up) is one set for both drives
  byte scr [int][512];
  int  f_own [2] = '{0, 0};
  logic got;
  function automatic int skey(input int s, input int lba);
    return (s < 2 && lba >= 128) ? 9 * 65536 + lba : s * 65536 + lba;
  endfunction

  longint rd_max = 0;
  task automatic drive_read(input int s, input int lba, input logic sc = 1'b0, input logic expect_zero = 1'b0);
    byte got [512];
    longint t0 = $time;
    set_lba(s, 32'(lba));
    d_scr[s] = sc;
    d_rd[s]  = 1'b1;
    while (!d_ack[s]) @(posedge clk);
    d_rd[s] = 1'b0;
    for (int i = 0; i < 512; i++) got[i] = 8'h5A;
    while (d_ack[s]) begin
      @(posedge clk);
      if (d_buff_wr && d_ack[s]) got[d_buff_addr] = d_buff_dout;
    end
    d_scr[s] = 1'b0;
    if (($time - t0) / 20 > rd_max) rd_max = ($time - t0) / 20;
    for (int i = 0; i < 512; i++) begin
      byte want;
      want = expect_zero ? 8'h00 : sc ? (scr.exists(skey(s, lba)) ? scr[skey(s, lba)][i] : 8'h00)
                                      : shadow[s][lba * 512 + i];
      if (got[i] != want) begin
        fail($sformatf("read slot %0d lba %0d%s byte %0d: %02h want %02h", s, lba, sc ? " scratch" : "", i,
                       got[i], want));
        break;
      end
    end
  endtask

  task automatic drive_write(input int s, input int lba, input int seed, input logic sc = 1'b0);
    for (int i = 0; i < 512; i++) wbuf[s][i] = byte'(seed * 7 + i * 13 + (i >> 4));
    set_lba(s, 32'(lba));
    d_scr[s] = sc;
    d_wr[s]  = 1'b1;
    while (!d_ack[s]) @(posedge clk);
    d_wr[s] = 1'b0;
    while (d_ack[s]) @(posedge clk);
    d_scr[s] = 1'b0;
    if (sc && s < 2 && lba < 128 && f_own[lba >= 64] != s) begin
      for (int k = 0; k < 64; k++) if (scr.exists(skey(1 - s, (lba & 64) + k))) scr.delete(skey(1 - s, (lba & 64) + k));
      f_own[lba >= 64] = s;
    end
    if (sc) for (int i = 0; i < 512; i++) scr[skey(s, lba)][i] = wbuf[s][i];
    else    for (int i = 0; i < 512; i++) shadow[s][lba * 512 + i] = wbuf[s][i];
  endtask

  // a recorded track format: IDs {bad, size 512, head, cyl, sec} in
  // interleave il order, gaps, count; into wbuf[s]
  task automatic fmt_block(input int s, input int cyl, input int head, input int il, input int nsec);
    int sec [64];
    int pos;
    for (int i = 0; i < 64; i++) sec[i] = -1;
    pos = 0;
    for (int n = 0; n < nsec; n++) begin
      while (sec[pos] != -1) pos = (pos + 1) % nsec;
      sec[pos] = n;
      pos = (pos + il) % nsec;
    end
    for (int i = 0; i < 512; i++) wbuf[s][i] = 8'h00;
    for (int w = 0; w < nsec; w++) begin
      logic [31:0] id;
      id = {7'd0, 1'b0, 2'b01, 3'(head), 11'(cyl), 8'(sec[w])};
      for (int b = 0; b < 4; b++) wbuf[s][4 * w + b] = id[31 - 8 * b -: 8];
    end
    {wbuf[s][504], wbuf[s][505], wbuf[s][506], wbuf[s][507]} = {16'd16, 16'(10 + il)};
    wbuf[s][511] = 8'(nsec);
  endtask

  task automatic drive_put_fmt(input int s, input int cyl, input int head, input int il);
    fmt_block(s, cyl, head, il, 17);
    set_lba(s, 32'(cyl * 8 + head));
    d_scr[s] = 1'b1;
    d_wr[s]  = 1'b1;
    while (!d_ack[s]) @(posedge clk);
    d_wr[s] = 1'b0;
    while (d_ack[s]) @(posedge clk);
    d_scr[s] = 1'b0;
    for (int i = 0; i < 512; i++) scr[skey(s, cyl * 8 + head)][i] = wbuf[s][i];
  endtask

  function automatic int fmt_used(input int k);
    int n = 0;
    for (int e = 0; e < 4; e++) if (dut.rc[k][e] != 0) n++;
    return n;
  endfunction

  task automatic mount(input int s, input int size, input logic ro, input int seed);
    fsize[s] = size; fro[s] = ro;
    for (int i = 0; i < MAXB; i++) begin
      file[s][i]   = (i < size) ? byte'(seed + i * 31 + (i >> 9) * 5) : 8'h00;
      shadow[s][i] = file[s][i];
    end
    for (int k = 0; k < (s < 2 ? 128 : 16384); k++) if (scr.exists(s * 65536 + k)) scr.delete(s * 65536 + k);
    dmounted_seen[s] = 1'b0;
    nmount[s] = 0;
    @(posedge clk);
    img_mounted[s] <= 1'b1; img_size <= 64'(size); img_readonly <= ro;
    repeat (40) @(posedge clk);   // hps_io holds it until the command ends
    img_mounted[s] <= 1'b0;
    repeat (5) @(posedge clk);
    if (nmount[s] != 1) fail($sformatf("mount slot %0d: %0d pulses", s, nmount[s]));
    if (dsize[s] != 64'(size)) fail($sformatf("size %0d", dsize[s]));
    if (dro[s] != ro) fail("readonly");
  endtask

  task automatic quiet();
    repeat (QUIET + 2000) @(posedge clk);
    while (wb_busy || busy || |h_ack) @(posedge clk);
    repeat (100) @(posedge clk);
  endtask

  task automatic check_file(input int s, input string what);
    for (int i = 0; i < fsize[s]; i++)
      if (file[s][i] != shadow[s][i]) begin
        fail($sformatf("%s: slot %0d file byte %0d %02h want %02h", what, s, i, file[s][i], shadow[s][i]));
        break;
      end
  endtask

  initial begin
    int r0;
    logic hd_stop, hd_done;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    mount(1, 1224704, 1'b0, 7);
    mount(2, 612 * 4 * 17 * 512, 1'b0, 11);
    drive_read(2, 612 * 68 - 1);
    bpc = {12'd0, 12'd68};
    $display("small: mounted");
    hd_stop = 1'b0; hd_done = 1'b0;
    fork
      begin while (!hd_stop) drive_read(2, $urandom_range(0, 67)); hd_done = 1'b1; end
    join_none
    drive_read(1, 13);
    $display("small: fd read");
    for (int k = 0; k < 46; k += 5) drive_write(1, k, 50 + k, 1'b1);
    for (int k = 0; k < 46; k += 5) drive_read(1, k, 1'b1);
    for (int k = 0; k < 46; k += 7) drive_read(1, k, 1'b1);
    $display("small: records");
    for (int k = 128; k < 145; k += 4) drive_write(1, k, 90 + k, 1'b1);
    for (int k = 128; k < 145; k += 4) drive_read(1, k, 1'b1);
    drive_write(1, 13, 333);
    drive_read(1, 13);
    drive_read(1, 12);
    drive_read(1, 14);
    $display("small: image write");
    hd_stop = 1'b1;
    while (!hd_done) @(posedge clk);
    quiet();
    check_file(1, "floppy write-back");
    if (errors == 0) $display("tb_ds_small: PASS");
    else             $display("tb_ds_small: FAIL (%0d)", errors);
    $finish;
  end

  initial forever begin #200us; $display("t=%0t h_rd=%b h_ack=%b d_rd=%b d_ack=%b busy=%b", $time, h_rd, h_ack, d_rd, d_ack, busy); end
  initial begin
    #2s;
    $fatal(1, "timeout");
  end
endmodule
`default_nettype wire
