// disk_stream: synthetic images on two floppy slots and two hard disk slots,
// an hps_io model with random latency, and drive clients that speak the
// hps_io sd_* protocol as the drive emulators do.  Checks: every drive
// read returns the image with the drive's earlier writes; a unit is
// loaded with requests of at most 16 KB, a floppy cylinder in one; a
// dirty unit reaches the file before the next unit loads, and after the
// quiet time without a load; blocks past the file's end read as zero
// and are never written to it; a read-only image is never written; a
// request to an empty slot completes at once; img_mounted held for a whole
// command is one mount; a remount drops the old unit and its dirty
// blocks; scratch blocks read back and never reach the file; a floppy
// side's records written by the other drive read as zero, the staging is
// shared; hard disk formats read back exactly, tracks formatted alike
// share an entry, distinct formats beyond the entries are dropped
// (fmt_full); each hard disk keeps its cylinder while the other one loads
// and reads (no reload when the controller moves between drives); a hard
// disk slot
// without a geometry is served block by block; an 8-head cylinder (136
// blocks) is held whole and written back; other slots are served
// while one loads; after a machine reset each drive with a medium hears
// of it again, and the unit is still resident.
`timescale 1ns/1ps
`default_nettype none
module tb_disk_stream;
  localparam int NSLOT = 4;
  localparam int QUIET = 20000;
  logic clk = 1'b0, rst_n = 1'b0, core_rst_n = 1'b1;
  always #10 clk = ~clk;

  // ---- DUT ---------------------------------------------------------------------------
  logic [1:0][11:0]       bpc = '0;
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

  disk_stream #(.NFMT(4), .QUIET(QUIET)) dut (.*);

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
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    // an empty slot answers at once
    begin
      longint t0 = $time;
      set_lba(1, 32'd5); d_rd[1] = 1'b1;
      while (!d_ack[1]) @(posedge clk);
      d_rd[1] = 1'b0;
      while (d_ack[1]) @(posedge clk);
      if (($time - t0) / 20 > 10) fail("empty slot not at once");
      if (|h_rd) fail("empty slot reached the HPS");
    end
    // floppy 0 (short: 2314 blocks, tracks 77-79 past the end), floppy 1, hard disk
    mount(0, 2314 * 512, 1'b0, 3);
    mount(1, 1224704, 1'b0, 7);
    mount(2, 612 * 4 * 17 * 512, 1'b0, 11);
    // the hard disk's probe: no geometry yet, one block from the file
    drive_read(2, 612 * 68 - 1);
    if (nreq_rd[2] != 1 || blk_rd[2] != 1) fail($sformatf("probe: %0d requests, %0d blocks", nreq_rd[2], blk_rd[2]));
    bpc = {12'd0, 12'd68};   // whole vector: a part-select write from here is not seen
    // floppy cylinder 0: one request of 32 blocks, then hits
    r0 = nreq_rd[0];
    drive_read(0, 3);
    for (int k = 0; k < 10; k++) drive_read(0, $urandom_range(0, 31));
    if (nreq_rd[0] - r0 != 1 || blk_rd[0] != 32) fail($sformatf("floppy cyl 0: %0d requests %0d blocks", nreq_rd[0] - r0, blk_rd[0]));
    // cylinder 45 (zone 1, 30 blocks: 1428-1457)
    r0 = blk_rd[0];
    drive_read(0, 1450); drive_read(0, 1428); drive_read(0, 1457);
    if (blk_rd[0] - r0 != 30) fail($sformatf("floppy cyl 45: %0d blocks", blk_rd[0] - r0));
    // past the end: zeros, a write there stays in the unit only
    drive_read(0, 2320, 1'b0, 1'b1);
    drive_write(0, 2330, 4);
    drive_read(0, 2330);
    // hard disk cylinder 10: 68 blocks in 3 requests, other slots served meanwhile
    r0 = nreq_rd[2];
    fork
      drive_read(2, 10 * 68 + 40);
      begin repeat (50) @(posedge clk); for (int k = 0; k < 5; k++) drive_read(1, $urandom_range(0, 31)); end
    join
    if (nreq_rd[2] - r0 != 3) fail($sformatf("hd cylinder: %0d requests", nreq_rd[2] - r0));
    for (int k = 0; k < 20; k++) drive_read(2, 10 * 68 + $urandom_range(0, 67));
    // writes, interleaved with reads, on all slots at once
    fork
      begin for (int k = 0; k < 8; k++) begin drive_write(0, 1430 + k * 3, k); drive_read(0, 1430 + k * 3); end end
      begin for (int k = 0; k < 6; k++) begin drive_write(2, 10 * 68 + k * 9, 50 + k); drive_read(2, 10 * 68 + $urandom_range(0, 67)); end end
      begin for (int k = 0; k < 4; k++) begin drive_write(1, k * 2, 90 + k); drive_read(1, k); end end
    join
    // the quiet time flushes them
    quiet();
    if (wb_busy) fail("wb_busy High after the flush");
    check_file(0, "idle flush");
    check_file(1, "idle flush");
    check_file(2, "idle flush");
    // a dirty unit reaches the file before the next unit loads
    hps_wr_delay = 500;
    drive_write(2, 10 * 68 + 3, 33);
    drive_write(2, 10 * 68 + 4, 34);
    drive_read(2, 500 * 68 + 7);
    check_file(2, "flush before load");
    drive_read(2, 10 * 68 + 3);
    hps_wr_delay = 0;
    for (int k = 0; k < 30; k++) drive_read(2, $urandom_range(0, 612 * 68 - 1));
    // scratch: floppy records and staging, hard disk formats by tag
    for (int k = 0; k < 6; k++) begin
      drive_write(0, (k < 2) ? k * 20 : (k < 4) ? 64 + k * 10 : 128 + k, 200 + k, 1'b1);
      drive_write(2, 1000 + k * 8, 210 + k, 1'b1);
    end
    if (!fmt_full) fail("format table not full after 6 tags in 4 entries");
    scr.delete(2 * 65536 + 1000 + 4 * 8);
    scr.delete(2 * 65536 + 1000 + 5 * 8);
    for (int k = 0; k < 6; k++) begin
      drive_read(0, (k < 2) ? k * 20 : (k < 4) ? 64 + k * 10 : 128 + k, 1'b1);
      drive_read(2, 1000 + k * 8, 1'b1);
    end
    drive_read(0, 77, 1'b1);
    quiet();
    check_file(0, "scratch");
    check_file(2, "scratch");
    // a floppy side's records belong to the drive that wrote them last;
    // the staging is one set
    drive_write(1, 7, 300, 1'b1);
    drive_read(0, 0, 1'b1);
    drive_read(0, 20, 1'b1);
    drive_read(0, 64 + 20, 1'b1);
    drive_read(1, 7, 1'b1);
    drive_read(0, 7, 1'b1);
    drive_read(1, 132, 1'b1);
    // the second hard disk: probe, then its own cylinder; the first one's
    // stays resident through it
    mount(3, 306 * 4 * 17 * 512, 1'b0, 13);
    drive_read(3, 306 * 68 - 1);
    bpc = {12'd68, 12'd68};
    drive_read(2, 10 * 68 + 1);
    r0 = nreq_rd[2];
    drive_read(3, 5 * 68 + 3);
    if (!resident[2] || !resident[3]) fail("both hard disks resident");
    for (int k = 0; k < 20; k++) begin
      drive_read(3, 5 * 68 + $urandom_range(0, 67));
      drive_read(2, 10 * 68 + $urandom_range(0, 67));
    end
    for (int k = 0; k < 3; k++) begin
      drive_write(3, 5 * 68 + 10 + k, 120 + k);
      drive_write(2, 10 * 68 + 20 + k, 130 + k);
    end
    drive_read(2, 10 * 68 + 21);
    drive_read(3, 5 * 68 + 11);
    if (nreq_rd[2] != r0) fail("first hard disk reloaded while the second one ran");
    quiet();
    check_file(2, "both hard disks written");
    check_file(3, "both hard disks written");
    // formats: tracks formatted alike share an entry
    for (int c = 0; c < 5; c++) for (int h = 0; h < 4; h++) drive_put_fmt(3, c, h, 3);
    for (int c = 0; c < 5; c++) for (int h = 0; h < 4; h++) drive_read(3, c * 8 + h, 1'b1);
    if (fmt_used(1) != 1) fail($sformatf("one layout in %0d entries", fmt_used(1)));
    drive_put_fmt(3, 2, 1, 1);
    if (fmt_used(1) != 2) fail($sformatf("two layouts in %0d entries", fmt_used(1)));
    drive_put_fmt(3, 2, 1, 3);
    if (fmt_used(1) != 1) fail($sformatf("back to one layout: %0d entries", fmt_used(1)));
    drive_read(3, 2 * 8 + 1, 1'b1);
    for (int k = 0; k < 3; k++) drive_write(3, 600 * 8 + k, 400 + k, 1'b1);
    if (fmt_used(1) != 4 || fmt_full) fail($sformatf("four entries: %0d, full %0d", fmt_used(1), fmt_full));
    drive_write(3, 601 * 8, 410, 1'b1);
    if (!fmt_full) fail("a fifth format kept");
    scr.delete(skey(3, 601 * 8));
    drive_write(3, 600 * 8 + 1, 420, 1'b1);                  // its own entry, rewritten in place
    for (int k = 0; k < 3; k++) drive_read(3, 600 * 8 + k, 1'b1);
    drive_read(3, 601 * 8, 1'b1);
    drive_read(3, 4 * 8 + 3, 1'b1);
    quiet();
    check_file(3, "formats");
    // formats on cylinders 1024 and up stay apart from cylinder - 1024
    mount(3, 306 * 4 * 17 * 512, 1'b0, 15);
    drive_put_fmt(3, 1030, 2, 1);
    drive_put_fmt(3, 6, 2, 5);
    drive_put_fmt(3, 2047, 7, 2);
    drive_put_fmt(3, 1023, 7, 4);
    if (fmt_used(1) != 4 || fmt_full) fail($sformatf("high cylinders: %0d entries, full %0d", fmt_used(1), fmt_full));
    drive_read(3, 1030 * 8 + 2, 1'b1);
    drive_read(3, 6 * 8 + 2, 1'b1);
    drive_read(3, 2047 * 8 + 7, 1'b1);
    drive_read(3, 1023 * 8 + 7, 1'b1);
    // read-only remount of floppy 1: writes stay in the unit, never in the file
    mount(1, 1224704, 1'b1, 21);
    drive_write(1, 40, 9);
    drive_read(1, 40);
    quiet();
    for (int i = 0; i < 512; i++) shadow[1][40 * 512 + i] = file[1][40 * 512 + i];
    // a remount drops the unit and its dirty blocks
    hps_wr_delay = 0;
    drive_write(0, 1440, 77);
    mount(0, 2392 * 512, 1'b0, 99);
    drive_read(0, 1440);
    quiet();
    check_file(0, "remount");
    // machine reset: the drives hear again; the unit stays (no new load)
    nmount = '{0, 0, 0, 0};
    r0 = nreq_rd[0];
    core_rst_n = 1'b0;
    repeat (50) @(posedge clk);
    core_rst_n = 1'b1;
    repeat (50) @(posedge clk);
    if (nmount[0] != 1 || nmount[1] != 1 || nmount[2] != 1 || nmount[3] != 1)
      fail($sformatf("replay after reset: %0d %0d %0d %0d pulses", nmount[0], nmount[1], nmount[2], nmount[3]));
    if (dsize[1] != 64'(1224704) || !dro[1]) fail("replay size or readonly");
    drive_read(0, 1441);
    if (nreq_rd[0] != r0) fail("unit lost in a machine reset");
    // both hard disks mounted and spinning up together: each loads its
    // cylinder once and keeps it
    begin
      int n2;
      logic stop2, done2;
      n2 = 0; stop2 = 1'b0; done2 = 1'b0;
      mount(2, 612 * 4 * 17 * 512, 1'b0, 31);
      mount(3, 306 * 4 * 17 * 512, 1'b0, 37);
      r0 = nreq_rd[2] + nreq_rd[3];
      fork
        begin while (!stop2) begin drive_read(2, $urandom_range(0, 67)); n2++; end done2 = 1'b1; end
      join_none
      for (int k = 0; k < 200; k++) drive_read(3, $urandom_range(0, 67));
      stop2 = 1'b1;
      while (!done2) @(posedge clk);
      if (n2 < 100) fail($sformatf("first disk served %0d reads while the second ran", n2));
      if (nreq_rd[2] + nreq_rd[3] - r0 != 6)
        fail($sformatf("spin-up of both: %0d load requests, want 3 each", nreq_rd[2] + nreq_rd[3] - r0));
    end
    // 8 heads x 17: a 12-cylinder image and a VHD footer block
    begin
      localparam int C8 = 136;
      mount(3, (12 * C8 + 1) * 512, 1'b0, 41);
      bpc = {12'(C8), 12'd68};
      r0 = nreq_rd[3];
      drive_read(3, 5 * C8 + 130);
      if (nreq_rd[3] - r0 != 5 || !resident[3])
        fail($sformatf("8-head cylinder: %0d requests, resident %0d", nreq_rd[3] - r0, resident[3]));
      for (int k = 0; k < 20; k++) drive_read(3, 5 * C8 + $urandom_range(0, C8 - 1));
      for (int c = 3; c < 12; c += 4)
        for (int k = 0; k < 4; k++) begin
          drive_write(3, c * C8 + 118 + k * 5, 500 + c + k);
          drive_read(3, c * C8 + $urandom_range(0, C8 - 1));
          drive_read(3, c * C8 + 118 + k * 5);
        end
      quiet();
      check_file(3, "8-head cylinders");
      bpc = {12'd68, 12'd68};
    end
    // eject: requests complete at once
    mount(2, 0, 1'b0, 0);
    begin
      longint t0 = $time;
      set_lba(2, 32'd5); d_rd[2] = 1'b1;
      while (!d_ack[2]) @(posedge clk);
      d_rd[2] = 1'b0;
      while (d_ack[2]) begin @(posedge clk); if (d_buff_wr) fail("data from an ejected slot"); end
      if (($time - t0) / 20 > 10) fail("ejected slot not at once");
    end
    $display("unit load clk/1024: floppy %0d-%0d, hard disk %0d-%0d", ld_min[0], ld_max[0], ld_min[1], ld_max[1]);
    $display("longest drive read %0d clocks", rd_max);
    if (errors == 0) $display("tb_disk_stream: PASS");
    else             $display("tb_disk_stream: FAIL (%0d)", errors);
    $finish;
  end

  initial begin
    #2s;
    $fatal(1, "timeout");
  end
endmodule
`default_nettype wire
