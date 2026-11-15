// Whole-machine bench: c900_core with the ROM files loaded as by the HPS, the DRAM in SDRAM through c900_sdram and the vendored
// controller on clk_ram (a cycle-level dual-chip SDRAM model), and monitors
// that log Z-bus transactions and SCC transmit bytes.
//
// Plusargs:
//   +rom=<boot0.rom>      the boot ROM, 32 KB (23128 pair) or 64 KB (27256
//                         pair), required
//   +rom1=<boot1.rom>     the peripheral ROMs, 16 KB, required
//   +patch=<file>         optional ROM patch: lines "<hex offset> <hex byte>"
//                         applied to boot0.rom before loading (bench only)
//   +nocard               no display card in the slot
//   +hr                   the HR card in the slot (default LR)
//   +lc                   the LC (8563) card in the slot (default LR); I/O
//                         cycles to 0180-01FF are logged (LCMON lines)
//   +hrvram=<file.pbm>    HR card: the 1024x800 bitmap at the end of the run
//                         (with +hr the bitmap accesses are also checked: HRMON lines)
//   +speed=<n>            CPU clock option: 0 6 MHz (default), 1 10, 2 12, 3 48 MHz (non-stock)
//   +fpu                  the Z8070 APU on CN13 (non-stock)
//   +ram=<0..3>           motherboard RAM: 0 1M, 1 512K; 2, 3: 1M with the
//                         2M or 15M card
//   +card=<0..4>          RAM card (non-stock): 0 none, 1 2M, 2 4M, 3 8M, 4 15M
//   +benchram             a behavioural RAM with fixed latency instead of the SDRAM
//   +lat=<n>              its latency in fabric clocks (default 8)
//   +trace=<file>         log Z-bus transactions
//   +tracemax=<n>         stop logging after n transactions
//   +maxcyc=<n>           stop after n Z8001 clocks (default 20M)
//   +idle=<n>             stop n Z8001 clocks after the last SCC byte
//   +scctx=<file>         SCC U74 data writes ("WR <clock> <port> <byte>")
//   +fd0=, +fd1=, +hd=<file>  disk images, mounted
//                         one clock after reset, served as hps_io does
//   +dmalog=<file>        DMA memory cycles ("D <clock> <addr> R|W [word]")
//   +fdctrace=, +hdctrace=, +cbus=<file>  6508 bus, 8049 pins, 8716
//                         controller bus, one line per change; windows
//                         +fdcfrom/+fdcto, +hdcfrom/+hdcto, +cfrom/+cto
//   +tracefrom=<n>        start the Z-bus trace at Z8001 clock n
//   +dbg, +dbghdc, +dbgfdc, +dbg8049  per-clock debug prints (+dbglo/+dbghi)
//   +prn=<file>           a printer on CN5 (centronics_printer); bytes to the file
//   +spk                  report the speaker's tone (coil on edges) at the end
//   +relphase=<n>         release reset at master clock n mod 192 (default 191)
//   +prerun=<n>           run n master clocks on an empty ROM before the load
//   +s1=<n>               press the reset switch S1 at Z8001 clock n (held 1 ms)
//   +hdcyl=<n>            hard disk 0's head starts at cylinder n (as S1 finds it)
//   +s1hold=<n>           S1 held from power-up to Z8001 clock n (the HPS holds
//                         status[0] through its load sequence)
//   +s1ram=<n>, +s1lr     with the press, the OSD sets +ram=<n> or the LR card
//   +stopbytes=<n>        stop after the n-th SCC U74 data write
//   +stopstr=<text>       stop once SCC U74 B has written text
//   +serin=<file>         typing on U74 B RxD, after given output
//   +landma=<file>        the LANCE card's bus-master cycles
//   +netpeer=<dir>        Main and a host on the LANCE ring (netpeer.cpp):
//                         10.0.9.1 answers ARP and serves dir by TFTP
//   +netlog=<file>        with +netpeer: every frame, pcap (Ethernet)
//   +rom2=<boot2.rom>     card ROMs; slot 0 (its first 16 KB) is the LANCE
//                         card's boot ROM
//   +ndcfg=static|bootp   with +netpeer: Main's IP configuration words, a
//                         static 10.0.9.2/24 server 10.0.9.1, or BOOTP
//                         (10.0.9.1 answers it); +ndfile=<name> the boot file
//   +memdump=<file>       SDRAM at the end, +memlen=<n> bytes from physical
//                         +memfrom=<hex>
//   +forks=<file>         children forked from this run (tb_core.cpp); a child
//                         takes its own +maxcyc, +idle, +stopbytes, +key*, +s1*,
//                         +scctx, +dmalog, +trace and mounts its +fd0/+fd1/+hd
`default_nettype none
module tb_core (
  input  logic clk,
  input  logic clk_ram,
  input  logic clk_vid,
  input  logic clk_vdc
);
  // ---- configuration --------------------------------------------------------
  string  rom_path, rom1_path, patch_path, trace_path;
  logic   cfg_nocard, cfg_hr, cfg_lc, cfg_benchram, cfg_fpu, cfg_lance;
  logic [1:0] cfg_speed;
  logic       cfg_512k;
  logic [2:0] cfg_card;
  logic   osd_nocard;     // OSD values; the host takes them while _MRESET is Low
  logic       osd_512k;
  logic [2:0] osd_card;
  int     lat, tracemax, idle;
  longint maxcyc;
  int     trace_fd;
  longint dbg_lo, dbg_hi, trace_from;

  logic [7:0] image [0:65535];
  logic [7:0] rom1 [0:16383];
  int         image_n;

  initial begin
    int fd, n, off, val;
    if (!$value$plusargs("rom=%s", rom_path)) $fatal(1, "need +rom=<boot.rom>");
    fd = $fopen(rom_path, "rb");
    if (fd == 0) $fatal(1, "cannot open %s", rom_path);
    n = $fread(image, fd);
    $fclose(fd);
    if (n != 32768 && n != 65536) $fatal(1, "%s: %0d bytes, want 32768 or 65536", rom_path, n);
    image_n = n;
    if (!$value$plusargs("rom1=%s", rom1_path)) $fatal(1, "need +rom1=<boot1.rom>");
    fd = $fopen(rom1_path, "rb");
    if (fd == 0) $fatal(1, "cannot open %s", rom1_path);
    n = $fread(rom1, fd);
    $fclose(fd);
    if (n != 16384) $fatal(1, "%s: %0d bytes, want 16384", rom1_path, n);
    if ($value$plusargs("patch=%s", patch_path)) begin
      fd = $fopen(patch_path, "r");
      if (fd == 0) $fatal(1, "cannot open %s", patch_path);
      while ($fscanf(fd, "%h %h\n", off, val) == 2) begin
        $display("patch: image[%05h] %02h -> %02h", off, image[off], val[7:0]);
        image[off] = val[7:0];
      end
      $fclose(fd);
    end
    osd_nocard = $test$plusargs("nocard");
    cfg_hr     = $test$plusargs("hr");
    cfg_lc     = $test$plusargs("lc");
    cfg_benchram = $test$plusargs("benchram");
    cfg_fpu      = $test$plusargs("fpu");
    cfg_lance    = $test$plusargs("lance");
    if (!$value$plusargs("speed=%d", cfg_speed)) cfg_speed = 2'd0;
    if (!$value$plusargs("ram=%d", n)) n = 0;
    osd_512k = n == 1;
    osd_card = n == 2 ? 3'd1 : n == 3 ? 3'd4 : 3'd0;
    if ($value$plusargs("card=%d", n)) osd_card = n[2:0];
    if (!$value$plusargs("lat=%d", lat)) lat = 8;
    if (!$value$plusargs("maxcyc=%d", maxcyc)) maxcyc = 64'd20000000;
    if (!$value$plusargs("idle=%d", idle)) idle = 0;
    if (!$value$plusargs("tracemax=%d", tracemax)) tracemax = 200000;
    trace_fd = 0;
    if (!$value$plusargs("dbglo=%d", dbg_lo)) dbg_lo = 0;
    if (!$value$plusargs("tracefrom=%d", trace_from)) trace_from = 0;
    if (!$value$plusargs("dbghi=%d", dbg_hi)) dbg_hi = 12;
    if ($value$plusargs("trace=%s", trace_path)) begin
      trace_fd = $fopen(trace_path, "w");
      if (trace_fd == 0) $fatal(1, "cannot open %s", trace_path);
    end
  end

  // ---- reset and loader: hold reset while the image is written ------------------
  logic        rst_n, pwr_q, rom_wr, ld_wr, rom_busy, mreset_n, s1;
  logic        sd_ready;   // SDRAM initialised (as C900.sv holds the machine in reset)
  logic [15:0] ld_addr;
  logic        loading, ld_per;   // ld_per: boot1.rom, after boot0.rom
  int          rst_hold;

  int          relphase, prerun, pre_cnt;
  initial begin
    if (!$value$plusargs("relphase=%d", relphase)) relphase = 191;
    if (!$value$plusargs("prerun=%d", prerun)) prerun = 0;
    pre_cnt  = 0;
    loading  = prerun == 0;
    ld_addr  = 16'h0000;
    ld_per   = 1'b0;
    rst_hold = 0;
  end

  // The clock tree runs from power-up (time 0).  Reset is released at a
  // fixed phase of it (master clock count 191 mod 192: Y1, U14 and the
  // fantdiv outputs back in their power-up phase relation), so the Z8001
  // clock count is reproducible and the first Z8001 clock comes three
  // master clocks after the release.
  longint mclk;
  initial mclk = 0;
  always_ff @(posedge clk) begin
    mclk <= mclk + 1;
    if (pre_cnt < prerun) begin
      pre_cnt <= pre_cnt + 1;
      if (pre_cnt == prerun - 1) loading <= 1'b1;
    end else if (loading) begin
      if (ld_wr) begin
        if (!ld_per && 32'(ld_addr) == image_n - 1) begin
          ld_per  <= 1'b1;
          ld_addr <= 16'h0000;
        end else begin
          if (ld_per && ld_addr == 16'h3FFF) loading <= 1'b0;
          ld_addr <= ld_addr + 16'd1;
        end
      end
    end else if (rom_busy || rst_hold < 64 || (mclk % 192) != relphase || !sd_ready) begin
      rst_hold <= (rst_hold < 64) ? rst_hold + 1 : rst_hold;
    end else begin
      rst_hold <= 65;
    end
  end
  // A byte per clock, held off by the boot ROM loader as by the HPS.
  assign ld_wr  = loading && pwr_q && !rom_busy;
  assign rom_wr = ld_wr && ld_per;
  // Reset asserts with an edge one clock after time 0: the asynchronous
  // clears (the Z8001's, whose clock does not run during reset) act on
  // that edge in simulation, as the clear level does in silicon.
  initial pwr_q = 1'b0;
  always_ff @(posedge clk) pwr_q <= 1'b1;
  assign rst_n  = ~pwr_q || (pre_cnt < prerun ? pre_cnt > 64 : ~loading && !rom_busy && (rst_hold > 64));

  longint zcyc /*verilator public_flat_rd*/;   // Z8001 clocks since reset release

  // ---- memory port: SDRAM, or the behavioural RAM with +benchram -------------------
  logic [23:1] mem_addr;
  logic        mem_rd, mem_wr, mem_ack, mem_rvalid;
  logic [1:0]  mem_be;
  logic [15:0] mem_wdata, mem_rdata;
  logic        b_ack, b_rvalid, s_ack, s_rvalid, s_ready;
  logic [15:0] b_rdata, s_rdata;
  // The port as C900.sv drives it: the boot ROM loader's while it loads.
  logic [23:1] p_addr, ld_maddr;
  logic        p_rd, p_wr, p_ack, ld_sel, ld_mrd, ld_mwr;
  logic [1:0]  p_be, ld_be;
  logic [15:0] p_wdata, ld_wdata;
  boot_rom_load u_rom_load (
    .clk(clk), .rst_n(pwr_q), .wr(ld_wr && !ld_per), .addr(ld_addr), .data(image[ld_addr]),
    .busy(rom_busy), .mem_addr(ld_maddr), .mem_rd(ld_mrd), .mem_wr(ld_mwr), .mem_be(ld_be), .mem_wdata(ld_wdata),
    .mem_rdata(mem_rdata[7:0]), .mem_ack(p_ack)
  );
  assign ld_sel  = loading | rom_busy;
  assign p_addr  = ld_sel ? ld_maddr : mem_addr;
  assign p_rd    = ld_sel ? ld_mrd : mem_rd;
  assign p_wr    = ld_sel ? ld_mwr : mem_wr;
  assign p_be    = ld_sel ? ld_be : mem_be;
  assign p_wdata = ld_sel ? ld_wdata : mem_wdata;
  assign p_ack   = cfg_benchram ? b_ack : s_ack;
  assign mem_ack = p_ack & ~ld_sel;
  assign mem_rvalid = (cfg_benchram ? b_rvalid : s_rvalid) & ~ld_sel;
  assign mem_rdata  = cfg_benchram ? b_rdata  : s_rdata;
  assign sd_ready   = cfg_benchram || s_ready;
  logic [15:0] ram [0:(1<<21)-1];   // 4 MB
  int          busy;

  int          watchw;   // +watchw=<hex byte address / 2>: log the RAM writes to that word
  initial begin
    busy = 0;
    if (!$value$plusargs("watchw=%h", watchw)) watchw = -1;
  end

  // Read data is presented in the clock before ack (mem_rvalid);
  // c900_dram also takes it in the ack clock.
  always_ff @(posedge clk) begin
    b_ack    <= 1'b0;
    b_rvalid <= 1'b0;
    if ((p_rd || p_wr) && !b_ack) begin
      if (p_rd && !p_wr && busy == lat - 2) begin
        b_rvalid <= 1'b1;
        b_rdata  <= ram[p_addr[21:1]];
      end
      if (busy == lat - 1) begin
        busy    <= 0;
        b_ack   <= 1'b1;
        if (p_wr) begin
          if (p_be[1]) ram[p_addr[21:1]][15:8] <= p_wdata[15:8];
          if (p_be[0]) ram[p_addr[21:1]][7:0]  <= p_wdata[7:0];
        end
      end else begin
        busy <= busy + 1;
      end
    end
  end

  // ---- keyboard matrix driven by the bench ----------------------------------------
  // +key=<n> presses matrix key n (8*column + row) at Z8001 clock +keyat=<c>
  // for +keyhold=<c> clocks.
  logic [103:0] tb_keys;
  logic [4:0]   tb_mods;
  int           key_idx;
  longint       key_at, key_hold;
  initial begin
    tb_keys = '0; tb_mods = '0;
    if (!$value$plusargs("key=%d", key_idx)) key_idx = -1;
    if (!$value$plusargs("keyat=%d", key_at)) key_at = 0;
    if (!$value$plusargs("keyhold=%d", key_hold)) key_hold = 100000;
  end

  // ---- disk images: +fd0=, +fd1=, +hd=<file> --------
  // Mounted one clock after reset release; block requests answered as
  // disk_stream does (ack, then a byte every clock) from the image in memory.
  // Writes go to the image in memory.
  localparam int FDMAX = 1224704, HDMAX = 44 * 1024 * 1024;
  logic [7:0]  fd0img [FDMAX];
  logic [7:0]  fd1img [FDMAX];
  logic [7:0]  hdimg [HDMAX];
  longint      isize [3];
  logic [2:0]  tb_mounted, tb_ack;
  logic [63:0] tb_size;
  logic [8:0]  tb_baddr;
  logic [7:0]  tb_bdout;
  logic        tb_bwr;
  logic [2:0]  mnt_want;   // slots the next mount sequence announces
  int          mnt_gen;    // a forked child's mount request
  task automatic load_images();
    string p;
    int fd, n;
    mnt_want = 3'b000;
    if ($value$plusargs("fd0=%s", p)) begin
      fd = $fopen(p, "rb");
      if (fd == 0) $fatal(1, "cannot open %s", p);
      n = $fread(fd0img, fd);
      $fclose(fd);
      isize[0] = n; mnt_want[0] = 1'b1;
    end
    if ($value$plusargs("fd1=%s", p)) begin
      fd = $fopen(p, "rb");
      if (fd == 0) $fatal(1, "cannot open %s", p);
      n = $fread(fd1img, fd);
      $fclose(fd);
      isize[1] = n; mnt_want[1] = 1'b1;
    end
    if ($value$plusargs("hd=%s", p)) begin
      fd = $fopen(p, "rb");
      if (fd == 0) $fatal(1, "cannot open %s", p);
      n = $fread(hdimg, fd);
      $fclose(fd);
      isize[2] = n; mnt_want[2] = 1'b1;
    end
  endtask
  initial begin
    isize[0] = 0; isize[1] = 0; isize[2] = 0;
    mnt_gen = 0;
    load_images();
  end

  typedef enum logic [2:0] {SdIdle, SdMount, SdWait, SdRead, SdWrite, SdEnd} sd_e;
  sd_e        sd_st;
  logic [1:0] sd_slot, mnt_slot;
  logic [9:0] sd_i;
  logic [3:0] sd_dly;
  logic       sd_isrd, sd_isscr;
  int         mnt_seen;
  logic [31:0] sd_lba_q;
  // scratch (floppy) and format (hard disk) blocks: RAM only, keyed by
  // {slot, block}; a read of a block never written is an error
  logic [7:0] scrmem [longint];
  bit         scrblk [longint];
  function automatic longint scr_key(input logic [1:0] sl, input logic [31:0] lba, input logic [9:0] i);
    return (longint'(sl) << 40) | (longint'(lba) << 9) | longint'(i[8:0]);
  endfunction
  initial begin
    sd_st = SdMount; mnt_slot = 2'd0; mnt_seen = 0; tb_mounted = 3'b000; tb_ack = 3'b000; tb_bwr = 1'b0;
    tb_baddr = 9'd0; tb_bdout = 8'h00; tb_size = 64'd0;
  end
  function automatic logic [7:0] img_byte(input logic [1:0] sl, input longint off);
    if (off >= isize[sl]) return 8'h00;
    return (sl == 2'd2) ? hdimg[off] : sl[0] ? fd1img[off] : fd0img[off];
  endfunction
  always_ff @(posedge clk) begin
    tb_mounted <= 3'b000;
    tb_bwr     <= 1'b0;
    if (rst_n) unique case (sd_st)
      SdMount: begin   // one slot per clock, those with an image
        if (mnt_want[mnt_slot] && isize[mnt_slot] != 0) begin
          tb_mounted[mnt_slot] <= 1'b1;
          tb_size <= 64'(isize[mnt_slot]);
        end
        if (mnt_slot == 2'd2) sd_st <= SdIdle;
        mnt_slot <= mnt_slot + 2'd1;
      end
      SdIdle: if (mnt_seen != mnt_gen) begin
        mnt_seen <= mnt_gen;
        mnt_slot <= 2'd0;
        sd_st    <= SdMount;
      end else begin
        for (int k = 2; k >= 0; k--)
          if (sd_rd[k] || sd_wr[k]) begin
            sd_slot <= 2'(k); sd_isrd <= sd_rd[k]; sd_lba_q <= sd_lba[k]; sd_isscr <= sd_scr[k];
            if (sd_rd[k] && sd_scr[k] && !scrblk.exists(scr_key(2'(k), sd_lba[k], 10'd0)))
              $display("SCRATCH read before write: slot %0d block %0d at %0d", k, sd_lba[k], zcyc);
          end
        if (|(sd_rd | sd_wr)) begin sd_st <= SdWait; sd_dly <= 4'd0; end
      end
      SdWait: begin
        sd_dly <= sd_dly + 4'd1;
        if (sd_dly == 4'd8) begin
          tb_ack[sd_slot] <= 1'b1;
          sd_i <= 10'd0; sd_dly <= 4'd0;
          sd_st <= sd_isrd ? SdRead : SdWrite;
        end
      end
      SdRead: begin   // a byte every clock, as disk_stream streams a block
        begin
          tb_baddr <= sd_i[8:0];
          tb_bdout <= !sd_isscr ? img_byte(sd_slot, longint'(sd_lba_q) * 512 + longint'(sd_i)) :
                      scrmem.exists(scr_key(sd_slot, sd_lba_q, sd_i)) ? scrmem[scr_key(sd_slot, sd_lba_q, sd_i)] : 8'h00;
          tb_bwr   <= 1'b1;
          if (sd_i == 10'd511) sd_st <= SdEnd;
          sd_i <= sd_i + 10'd1;
        end
      end
      SdWrite: begin   // address, then the drive's registered byte two clocks later
        if (sd_dly == 4'd0) tb_baddr <= sd_i[8:0];
        sd_dly <= sd_dly + 4'd1;
        if (sd_dly == 4'd2) begin
          sd_dly <= 4'd0;
          if (sd_isscr) begin
            scrmem[scr_key(sd_slot, sd_lba_q, sd_i)] <= sd_buff_din[sd_slot];
            scrblk[scr_key(sd_slot, sd_lba_q, 10'd0)] = 1'b1;
          end else if (longint'(sd_lba_q) * 512 + longint'(sd_i) < isize[sd_slot]) begin
            if (sd_slot == 2'd2) hdimg[longint'(sd_lba_q) * 512 + longint'(sd_i)] <= sd_buff_din[2];
            else if (sd_slot[0]) fd1img[longint'(sd_lba_q) * 512 + longint'(sd_i)] <= sd_buff_din[1];
            else fd0img[longint'(sd_lba_q) * 512 + longint'(sd_i)] <= sd_buff_din[0];
          end
          if (sd_i == 10'd511) sd_st <= SdEnd;
          sd_i <= sd_i + 10'd1;
        end
      end
      SdEnd: begin
        sd_dly <= sd_dly + 4'd1;
        if (sd_dly == 4'd2) begin tb_ack <= 3'b000; sd_st <= SdIdle; end
      end
      default: sd_st <= SdIdle;
    endcase
  end

  always_ff @(posedge clk)
    if (mem_wr && mem_ack && watchw >= 0 && mem_addr[21:1] == 21'(watchw))
      $display("RAMW %0d word %06h be %b data %04h", zcyc, {mem_addr[21:1], 1'b0}, mem_be, mem_wdata);

  wire         s_clk, s_cke, s_dqml, s_dqmh, s_ncs, s_nras, s_ncas, s_nwe;
  wire  [12:0] s_a;
  wire  [1:0]  s_ba;
  tri   [15:0] s_dq;
  logic        rst_ram_n;
  initial rst_ram_n = 1'b0;
  always_ff @(posedge clk_ram) rst_ram_n <= pwr_q;

  c900_sdram u_sdram (
    .clk(clk), .clk_ram(clk_ram), .rst_n(pwr_q), .rst_ram_n(rst_ram_n), .refresh_ok(mem_refresh_ok | ld_sel),
    .ready(s_ready), .addr(p_addr), .rd(p_rd && !cfg_benchram), .wr(p_wr && !cfg_benchram),
    .be(p_be), .wdata(p_wdata), .rdata(s_rdata), .rvalid(s_rvalid), .ack(s_ack),
    .sdram_clk(s_clk), .sdram_cke(s_cke), .sdram_a(s_a), .sdram_ba(s_ba), .sdram_dq(s_dq),
    .sdram_dqml(s_dqml), .sdram_dqmh(s_dqmh), .sdram_ncs(s_ncs), .sdram_nras(s_nras),
    .sdram_ncas(s_ncas), .sdram_nwe(s_nwe)
  );

  // 7.8125 us at 96 MHz
  sdram_cycle_model #(.DUAL(1'b1), .REFI_CLKS(750)) u_chips (
    .clk(s_clk), .cke(s_cke), .a(s_a), .ba(s_ba), .dq(s_dq), .dqml(s_dqml), .dqmh(s_dqmh),
    .ncs(s_ncs), .nras(s_nras), .ncas(s_ncas), .nwe(s_nwe)
  );

  // C900 deadline: every machine read acked 4 clocks after the controller takes it.
  longint sd_start = 0;
  int     sd_reads = 0, sd_late = 0, sd_forced = 0, sd_ackslot = 0, sd_inreset = 0;
  always_ff @(posedge clk) begin
    if (u_sdram.start && !mem_wr) sd_start <= mclk;
    if (u_sdram.ref_go) begin
      if (!rst_n)               sd_inreset <= sd_inreset + 1;
      else if (!mem_refresh_ok) sd_ackslot <= sd_ackslot + 1;
      if (!mem_refresh_ok && !u_sdram.ack_q) sd_forced <= sd_forced + 1;
    end
    if (!cfg_benchram && s_ack && s_rvalid && !ld_sel) begin
      sd_reads <= sd_reads + 1;
      if (mclk - sd_start != 5) begin   // ack rose at the previous edge
        sd_late <= sd_late + 1;
        if (sd_late < 10) $display("SDRAM LATE read at Z8001 clock %0d: %0d clocks", zcyc, mclk - sd_start - 1);
      end
    end
  end

  // Refresh scheduling: clocks from a refresh falling due to its start
  // (go), from go to the next request's first clock (on time from 4), and
  // between request first clocks; request phase = first clock - ZCLK rise
  // pulse clock, per kind.  +reflog=<n> prints the bus around the first n
  // refreshes that waited more than 13 clocks.
  int     ref_wait = 0, ref_wait_max = 0, ref_late_log = 0, reflog;
  longint ref_at = -1000, ref_next_min = 1000, req_gap_min = 1000, req_last = -1000, qa_at = 0;
  int     req_phase [3][8];   // CPU read, CPU write, DMA
  logic [63:0][13:0] bus_hist;
  localparam string HIST_NAME [14] = '{"go    ", "due   ", "ref_ok", "ack   ", "wr    ", "rd    ", "", "", "",
                                       "st    ", "/mreq ", "/ds   ", "/as   ", "zclk  "};
  initial foreach (req_phase[i, j]) req_phase[i][j] = 0;
  initial if (!$value$plusargs("reflog=%d", reflog)) reflog = 0;
  always_ff @(posedge clk) begin
    bus_hist <= {bus_hist[62:0], {u_core.u_mb.qa_rise, u_core.as_n, u_core.ds_n, u_core.mreq_n,
                 u_core.st, mem_rd, mem_wr, mem_ack, mem_refresh_ok, u_sdram.ref_due_q, u_sdram.ref_go}};
    if (u_sdram.ref_go) begin
      ref_at   <= mclk;
      ref_wait <= 0;
      if (rst_n && ref_wait > ref_wait_max) ref_wait_max <= ref_wait;
      if (rst_n && ref_wait > 13 && ref_late_log < reflog) begin
        ref_late_log <= ref_late_log + 1;
        $display("REFRESH %0d clocks after due, Z8001 clock %0d; last 63 clocks, oldest left:", ref_wait, zcyc);
        for (int b = 13; b >= 0; b--) begin
          string line;
          line = "";
          if (b > 5 && b < 9) continue;
          for (int i = 62; i >= 0; i--)
            line = {line, (b == 9) ? $sformatf("%h", bus_hist[i][9:6]) : bus_hist[i][b] ? "1" : "."};
          $display("  %s %s", HIST_NAME[b], line);
        end
      end
    end else if (u_sdram.ref_due_q) ref_wait <= ref_wait + 1;
    if (u_core.u_mb.qa_rise) qa_at <= mclk;
    if (u_sdram.start) begin
      req_last <= mclk;
      if (rst_n) begin
        automatic int ph = int'(mclk - qa_at) & 7;
        automatic int k  = !u_core.u_mb.dmaen_n ? 2 : mem_wr ? 1 : 0;
        req_phase[k][ph] <= req_phase[k][ph] + 1;
        if (mclk - req_last < req_gap_min) req_gap_min <= mclk - req_last;
        if (mclk - ref_at < ref_next_min)  ref_next_min <= mclk - ref_at;
      end
    end
  end

  final if (!cfg_benchram) begin
    $display("SDRAM scheduling: refresh waited at most %0d clocks; next request at least %0d clocks after a refresh start; requests at least %0d clocks apart",
             ref_wait_max, ref_next_min, req_gap_min);
    for (int k = 0; k < 3; k++)
      $display("SDRAM request phase, %s: %0d %0d %0d %0d %0d %0d %0d %0d", (k == 0) ? "read " : (k == 1) ? "write" : "DMA  ",
               req_phase[k][0], req_phase[k][1], req_phase[k][2], req_phase[k][3],
               req_phase[k][4], req_phase[k][5], req_phase[k][6], req_phase[k][7]);
  end

  final if (!cfg_benchram)
    $display("SDRAM: %0d reads (%0d late), %0d writes, refreshes %0d/%0d (%0d in reset, %0d after an ack, %0d forced), max gap %0d clocks, %0d errors",
             sd_reads, sd_late, u_chips.n_wr, u_chips.n_ref[0], u_chips.n_ref[1], sd_inreset, sd_ackslot, sd_forced,
             u_chips.max_ref_gap[0], u_chips.errors);

  // 64 KB segments of the RAM address the machine wrote, once each:
  // "MEMSEG 08 09 ..."
  logic [255:0] wseg;
  always_ff @(posedge clk)
    if (!rst_n)                wseg <= '0;
    else if (mem_wr && mem_ack) wseg[mem_addr[23:16]] <= 1'b1;
  final begin
    $write("MEMSEG");
    for (int i = 0; i < 256; i++) if (wseg[i]) $write(" %02x", i);
    $write("\n");
  end

  // ---- the machine -----------------------------------------------------------------
  logic [3:0][31:0] sd_lba;
  logic [3:0]       sd_rd, sd_wr, sd_scr;
  logic [3:0][7:0]  sd_buff_din;
  logic [1:0]       disk_late, disk_late_q;
  logic [5:0]       ser_txd, ser_rts_n, ser_dtr_n;
  logic             sin_rxd;
  logic             ce_pix, hsync, vsync, de, hblank, vblank, led_fdd, led_hdd, mem_refresh_ok;
  logic             lr_vid, lr_intens;
  logic             hr_ck24, hr_hsync, hr_hsync_n, hr_vsync_n, hr_de, hr_de_dly, hr_vblank_n, hr_mono_en, hr_mono_i;
  logic [3:0]       hr_rgbi, hr_vout, lc_rgbi;
  logic             lc_hsync, lc_vsync, lc_pixel_ce, lc_active_h, lc_active_v;
  logic [7:0]       r;
  assign r = lr_vid ? (lr_intens ? 8'hFF : 8'hAA) : 8'h00;   // C900.sv's LR levels

  c900_core u_core (
    .clk(clk), .clk_vid(clk_vid), .clk_vdc(clk_vdc), .rst_n(rst_n), .s1(s1), .mreset_n(mreset_n),
    .card_fitted(!cfg_nocard), .display_hr(cfg_hr), .display_lc(cfg_lc), .hr_mode(2'd0), .ram_512k(cfg_512k), .ram_card(cfg_card), .cpu_speed(cfg_speed),
    .lance_en(cfg_lance), .fpu_en(cfg_fpu),
    .rom_wr(rom_wr), .rom_addr(ld_addr[13:0]), .rom_data(rom1[ld_addr[13:0]]),
    .img_mounted({1'b0, tb_mounted}), .img_readonly(1'b0), .img_size(tb_size),
    .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_scr(sd_scr), .sd_ack({1'b0, tb_ack}),
    .sd_buff_addr(tb_baddr), .sd_buff_dout(tb_bdout), .sd_buff_din(sd_buff_din), .sd_buff_wr(tb_bwr),
    .hd_sel(), .hd_bpc(),
    .keys(tb_keys), .kbd_mods(tb_mods), .m_h(1'b0), .m_hq(1'b0), .m_v(1'b0), .m_vq(1'b0), .m_b_n(3'b111),
    .ser_rxd({4'hF, sin_rxd, 1'b1}), .ser_txd(ser_txd), .ser_cts_n(6'h00), .ser_dcd_n(6'h00), .ser_dsr_n(6'h00),
    .ser_rts_n(ser_rts_n), .ser_dtr_n(ser_dtr_n),
    .mem_addr(mem_addr), .mem_rd(mem_rd), .mem_wr(mem_wr), .mem_be(mem_be),
    .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_rvalid(mem_rvalid), .mem_ack(mem_ack),
    .ce_pix(ce_pix), .hsync(hsync), .vsync(vsync), .de(de), .hblank(hblank), .vblank(vblank),
    .lr_vid(lr_vid), .lr_intens(lr_intens), .mem_refresh_ok(mem_refresh_ok),
    .hr_ck24(hr_ck24), .hr_hsync(hr_hsync), .hr_hsync_n(hr_hsync_n), .hr_vsync_n(hr_vsync_n),
    .hr_de(hr_de), .hr_de_dly(hr_de_dly), .hr_vblank_n(hr_vblank_n),
    .hr_rgbi(hr_rgbi), .hr_vout(hr_vout), .hr_mono_en(hr_mono_en), .hr_mono_i(hr_mono_i),
    .lc_rgbi(lc_rgbi), .lc_hsync(lc_hsync), .lc_vsync(lc_vsync), .lc_pixel_ce(lc_pixel_ce),
    .lc_active_h(lc_active_h), .lc_active_v(lc_active_v),
    .cent_data(cent_data), .cent_strobe_n(cent_strobe_n), .cent_ack_n(cent_ack_n), .cent_busy(cent_busy),
    .spk_on(spk_on),
    .lan_on(lan_on), .lan_tclk_rise(lan_tclk_rise), .lan_tclk_fall(lan_tclk_fall), .lan_tx(lan_tx), .lan_tena(lan_tena),
    .lan_rclk_rise(lan_rclk_rise), .lan_rx(lan_rx), .lan_rena(lan_rena), .lan_clsn(lan_clsn),
    .lan_mac_ok(lan_mac_ok), .lan_mac(lan_mac),
    .lan_rom_ok(crom_ok), .lan_rom_wr(crom_wr), .lan_rom_addr(crom_a), .lan_rom_data(crom[crom_a]),
    .lan_cfg_ok(lan_cfg_ok), .lan_cfg_wr(lan_cfg_wr), .lan_cfg_addr(lan_cfg_addr), .lan_cfg_data(lan_cfg_data),
    .led_fdd(led_fdd), .led_hdd(led_hdd), .disk_late(disk_late)
  );

  // ---- the LANCE card's cable: the transceiver and the DDR ring ---------------------
  // Without +netpeer DDR never answers.  With it, a DDR model with random
  // BUSY and read latency, and Main with a host on the far side
  // (netpeer.cpp): +netpeer=<dir> serves the files in dir by TFTP,
  // +netlog=<file.pcap> logs every frame.
  logic        lan_on, lan_tclk_rise, lan_tclk_fall, lan_tx, lan_tena;
  logic        lan_rclk_rise, lan_rx, lan_rena, lan_clsn, lan_mac_ok;
  logic [47:0] lan_mac;
  logic        lan_cfg_ok, lan_cfg_wr;
  logic [4:0]  lan_cfg_addr;
  logic [15:0] lan_cfg_data;
  logic        ddr_busy, ddr_rd, ddr_we, ddr_dready;
  logic [7:0]  ddr_bc, ddr_be;
  logic [28:0] ddr_addr;
  logic [63:0] ddr_din, ddr_dout;
  lance_link u_lance_link (
    .clk(clk), .rst_n(rst_n), .card_on(lan_on),
    .tclk_rise(lan_tclk_rise), .tclk_fall(lan_tclk_fall), .tx(lan_tx), .tena(lan_tena),
    .rclk_rise(lan_rclk_rise), .rx(lan_rx), .rena(lan_rena), .clsn(lan_clsn),
    .mac_ok(lan_mac_ok), .mac(lan_mac),
    .cfg_ok(lan_cfg_ok), .cfg_wr(lan_cfg_wr), .cfg_addr(lan_cfg_addr), .cfg_data(lan_cfg_data),
    .ddr_busy(ddr_busy), .ddr_burstcnt(ddr_bc), .ddr_addr(ddr_addr), .ddr_dout(ddr_dout),
    .ddr_dout_ready(ddr_dready), .ddr_rd(ddr_rd), .ddr_din(ddr_din), .ddr_be(ddr_be), .ddr_we(ddr_we)
  );

  import "DPI-C" function int     np_init(input string dir, input string log);
  import "DPI-C" function longint np_rd(input int idx);
  import "DPI-C" function void    np_wr(input int idx, input longint d, input byte be);
  import "DPI-C" function void    np_poll(input longint ns);
  import "DPI-C" function void    np_final();
  import "DPI-C" function void    np_ipcfg(input int mode, input string file);
  logic        np_on;
  int          np_wbeats, np_rn, np_ra, np_rat;
  logic [28:0] np_wa;
  longint      np_clk;
  initial begin
    string d, l;
    np_on = 1'b0; np_wbeats = 0; np_rn = 0; np_clk = 0;
    if ($value$plusargs("netpeer=%s", d)) begin
      if (!$value$plusargs("netlog=%s", l)) l = "";
      np_on = np_init(d, l) != 0;
      if ($value$plusargs("ndcfg=%s", d)) begin
        if (!$value$plusargs("ndfile=%s", l)) l = "";
        np_ipcfg(d == "static" ? 1 : d == "bootp" ? 2 : 0, l);
      end
    end
  end

  // ---- +rom2: slot 0, the LANCE card's boot ROM, a byte a clock from power-up ----
  logic [7:0]  crom [0:16383];
  logic [13:0] crom_a;
  logic        crom_wr, crom_ok;
  int          crom_n, crom_i;
  initial begin
    string p;
    int    fd;
    crom_n = 0; crom_i = 0; crom_ok = 1'b0;
    if ($value$plusargs("rom2=%s", p)) begin
      fd = $fopen(p, "rb");
      if (fd == 0) $fatal(1, "cannot open %s", p);
      crom_n = $fread(crom, fd);
      $fclose(fd);
    end
  end
  assign crom_wr = pwr_q && crom_i < crom_n;
  assign crom_a  = 14'(crom_i);
  always_ff @(posedge clk) if (crom_wr) begin
    crom_i <= crom_i + 1;
    if (crom_i == crom_n - 1) crom_ok <= 1'b1;
  end
  final if (np_on) np_final();
  function automatic int np_idx(input logic [28:0] a);
    if (a < 29'h0608_0000 || a >= 29'h0608_2000) $fatal(1, "DDR access outside the ring window: %h", a);
    return int'(a - 29'h0608_0000);
  endfunction
  // One read in flight: the bridge waits for its data before the next command.
  always @(posedge clk) begin
    np_clk <= np_clk + 1;
    ddr_dready <= 1'b0;
    if (!np_on) ddr_busy <= 1'b1;
    else begin
      if (ddr_we && !ddr_busy) begin
        if (np_wbeats == 0) begin
          if (ddr_bc == 8'd0) $fatal(1, "DDR burst count 0");
          np_wbeats = int'(ddr_bc);
          np_wa     = ddr_addr;
        end
        np_wr(np_idx(np_wa), ddr_din, ddr_be);
        np_wa     = np_wa + 29'd1;
        np_wbeats = np_wbeats - 1;
      end
      if (ddr_rd && !ddr_busy) begin
        if (np_wbeats != 0 || np_rn != 0) $fatal(1, "DDR read inside a burst");
        np_ra  <= np_idx(ddr_addr);
        np_rn  <= int'(ddr_bc);
        np_rat <= 4 + int'($urandom_range(0, 40));
      end else if (np_rn != 0) begin
        if (np_rat != 0) np_rat <= np_rat - 1;
        else if ($urandom_range(0, 3) != 0) begin
          ddr_dready <= 1'b1;
          ddr_dout   <= np_rd(np_ra);
          np_ra      <= np_ra + 1;
          np_rn      <= np_rn - 1;
        end
      end
      ddr_busy <= $urandom_range(0, 3) == 0;
      if (np_clk % 64'd4800 == 0) np_poll(np_clk * 125 / 6);   // Main every 100 us
    end
  end

  // +memdump=<file>: +memlen=<n> bytes of SDRAM from physical +memfrom=<hex>
  // at the end of the run.
  final begin
    string p;
    int    fd, from, len;
    if ($value$plusargs("memdump=%s", p)) begin
      if (!$value$plusargs("memfrom=%h", from)) from = 0;
      if (!$value$plusargs("memlen=%d", len)) len = 65536;
      fd = $fopen(p, "wb");
      for (int i = from & ~1; i < from + len; i += 2)
        $fwrite(fd, "%c%c", u_chips.mem[i >> 1][15:8], u_chips.mem[i >> 1][7:0]);
      $fclose(fd);
    end
  end

  // ---- CN5 printer and CN3 speaker -------------------------------------------------
  logic [7:0] cent_data, prn_byte;
  logic       cent_strobe_n, cent_ack_n, cent_busy, prn_valid, prn_on, spk_on;
  int         prn_fd;
  initial begin
    string p;
    prn_fd = 0;
    prn_on = $value$plusargs("prn=%s", p);
    if (prn_on) prn_fd = $fopen(p, "wb");
  end
  centronics_printer u_prn (
    .clk(clk), .rst_n(rst_n), .attached(prn_on), .data(cent_data), .strobe_n(cent_strobe_n),
    .ack_n(cent_ack_n), .busy(cent_busy), .byte_valid(prn_valid), .byte_data(prn_byte), .byte_ready(1'b1)
  );
  always_ff @(posedge clk) if (prn_valid) begin
    $display("PRN %0d %02h %s", zcyc, prn_byte, printable(prn_byte));
    if (prn_fd != 0) $fwrite(prn_fd, "%c", prn_byte);
  end
  final if (prn_fd != 0) $fclose(prn_fd);

  logic   spk_q;
  longint spk_n, spk_first, spk_last;
  initial begin spk_n = 0; spk_first = 0; spk_last = 0; end
  always_ff @(posedge clk) begin
    spk_q <= spk_on;
    if (rst_n && spk_on && !spk_q) begin
      if (spk_n == 1) spk_first <= zcyc;   // the first edge is the PB0 setup
      spk_last <= zcyc;
      spk_n    <= spk_n + 1;
    end
  end
  final if ($test$plusargs("spk"))
    $display("SPK %0d coil-on edges, second %0d last %0d Z8001 clocks: %0d Hz", spk_n, spk_first, spk_last,
             spk_n > 2 ? 64'd6000000 * (spk_n - 2) / (spk_last - spk_first) : 0);

  // ---- monitors ----------------------------------------------------------------------
  always_ff @(posedge clk) begin
    disk_late_q <= disk_late;
    if (disk_late[0] && !disk_late_q[0]) $display("LATE floppy at %0d", zcyc);
    if (disk_late[1] && !disk_late_q[1]) $display("LATE hard disk at %0d", zcyc);
    // The CPU traps an undefined first word; C900 software must never fetch one.
    if (u_core.u_mb.u1_cpu.clk_en && u_core.u_mb.u1_cpu.ex_word && !u_core.u_mb.u1_cpu.ctrl.valid)
      $display("UNDEF first word %04h pc %08h fcw %04h at %0d", u_core.u_mb.u1_cpu.dec_w0,
               u_core.u_mb.u1_cpu.pc, u_core.u_mb.u1_cpu.fcw, zcyc);
  end
  logic   zrise;          // the ZCLK rise pulse (the Z8001 acts at the next master clock)
  assign zrise = u_core.zclk_rise;
  longint ntrans;
  longint last_tx;
  logic   as_q, ds_q;
  logic [3:0]  t_st;
  logic [6:0]  t_sn;
  logic [15:0] t_off;
  logic        t_rw, t_bw, t_ns;
  longint      t_cyc;

  initial begin
    zcyc = 0; ntrans = 0; last_tx = -1;
    as_q = 1'b1; ds_q = 1'b1;
  end

  always_ff @(posedge clk) begin
    if (rst_n && zrise) zcyc <= zcyc + 1;
  end

  // A transaction opens at /AS rising (address latched) and closes at /DS
  // rising; the data is the registered bus value of the last /DS-Low clock.
  logic [15:0] t_data;
  logic [23:0] t_pa;
  always_ff @(posedge clk) begin
    as_q <= u_core.as_n;
    ds_q <= u_core.ds_n;
    if (!u_core.ds_n) begin t_data <= u_core.ad_q; t_pa <= u_core.pa; end
    if (rst_n && !as_q && u_core.as_n) begin
      t_st  <= u_core.st;
      t_sn  <= u_core.u_mb.sn_q;
      t_off <= u_core.u_mb.adr;
      t_rw  <= u_core.r_w;
      t_bw  <= u_core.b_w;
      t_ns  <= u_core.n_s;
      t_cyc <= zcyc;
    end
    if (rst_n && !ds_q && u_core.ds_n && trace_fd != 0 && ntrans < tracemax && t_cyc >= trace_from) begin
      $fwrite(trace_fd, "%0d st=%h %02h:%04h %s %s n=%0d d=%04h pa=%06h\n", t_cyc, t_st, t_sn, t_off,
              t_rw ? "R" : "W", t_bw ? "B" : "W", t_ns, t_data, t_pa);
      ntrans <= ntrans + 1;
    end
  end

  // CPUMON: the word the CPU takes on each read against the bus word of the
  // cycle's last /DS-Low clock (the byte lane only for a byte read).
  logic        cm_pend = 1'b0, cm_byte, cm_odd;
  logic [15:0] cm_take;
  int          cm_rd = 0, cm_err = 0;
  always_ff @(posedge clk) begin
    if (u_core.u_mb.u1_cpu.u_bus.clk_en && u_core.u_mb.u1_cpu.u_bus.done &&
        !u_core.u_mb.u1_cpu.u_bus.cyc_write_q && !u_core.u_mb.u1_cpu.u_bus.cyc_nod_q &&
        u_core.u_mb.u1_cpu.u_bus.cyc_st_q != 4'b0001 && u_core.u_mb.u1_cpu.u_bus.cyc_st_q != 4'b0000) begin
      cm_pend <= 1'b1;
      cm_take <= u_core.u_mb.u1_cpu.u_bus.rdata;
      cm_byte <= t_bw;
      cm_odd  <= t_off[0];
    end
    if (rst_n && !ds_q && u_core.ds_n && cm_pend) begin
      cm_pend <= 1'b0;
      cm_rd   <= cm_rd + 1;
      if (cm_byte ? (cm_odd ? cm_take[7:0] != t_data[7:0] : cm_take[15:8] != t_data[15:8]) : cm_take != t_data) begin
        cm_err <= cm_err + 1;
        if (cm_err < 20)
          $display("CPUMON z%0d st=%h pa=%06h %s took %04h, bus %04h", t_cyc, t_st, t_pa, cm_byte ? "B" : "W", cm_take, t_data);
      end
    end
  end
  final $display("CPUMON: %0d reads, %0d mismatches", cm_rd, cm_err);

  // IOREC: /DS High time between two accesses to one SCC or CIO (U74, U70,
  // U66, U31, U36), in master clocks, against the valid access recovery
  // time: SCC 6 PCLK + 200 ns (57.6 clocks at the 6 MHz PCLK), CIO 1000 ns.
  logic [4:0]  rc_sel, rc_cap = 5'd0;
  longint      rc_mclk = 0;
  longint      rc_rise [5];
  int          rc_n [5], rc_bad [5], rc_min [5];
  initial for (int i = 0; i < 5; i++) begin rc_rise[i] = -1; rc_n[i] = 0; rc_bad[i] = 0; rc_min[i] = 1 << 30; end
  assign rc_sel = {!u_core.u_mb.io_n[3] && u_core.u_mb.a7, !u_core.u_mb.io_n[3] && !u_core.u_mb.a7,
                   !u_core.u_mb.io_n[0] && u_core.u_mb.a7, !u_core.u_mb.io_n[0] && !u_core.u_mb.a7,
                   !u_core.u_mb.io_n[1] && !u_core.u_mb.a7};
  always_ff @(posedge clk) begin
    rc_mclk <= rc_mclk + 1;
    if (!u_core.ds_n) rc_cap <= rc_cap | rc_sel;
    if (rst_n && !ds_q && u_core.ds_n) begin
      for (int i = 0; i < 5; i++) if (rc_cap[i]) rc_rise[i] <= rc_mclk;
      rc_cap <= 5'd0;
    end
    if (rst_n && ds_q && !u_core.ds_n)
      for (int i = 0; i < 5; i++)
        if (rc_sel[i] && rc_rise[i] >= 0) begin
          int g;
          g = int'(rc_mclk - rc_rise[i]);
          rc_n[i]++;
          if (g < rc_min[i]) rc_min[i] = g;
          if (g < (i == 1 || i == 2 ? 48 : 58)) rc_bad[i]++;
        end
  end
  final begin
    string nm [5] = '{"U74", "U70", "U66", "U31", "U36"};
    for (int i = 0; i < 5; i++)
      if (rc_n[i] > 0)
        $display("IOREC: %s %0d gaps, min %0d clocks, %0d short", nm[i], rc_n[i], rc_min[i], rc_bad[i]);
  end

  // LC card ports 0180-01FF: standard I/O byte cycles as the bus carries
  // them.
  always_ff @(posedge clk) begin
    if (rst_n && !ds_q && u_core.ds_n && t_st == 4'b0010 && t_bw && t_off[15:7] == 9'h003)
      $display("LCMON z%0d %s %04h %02h", t_cyc, t_rw ? "R" : "W", t_off, t_data[7:0]);
  end

  // +lc: the CPU's _NVI pin on every change, with its two drivers, U62 /Q2
  // and the card's 8568 INTR on CN11 pin 37.
  logic nvi_pin_q = 1'b1, lc_nvi_q = 1'b1;
  always_ff @(posedge clk) begin
    nvi_pin_q <= u_core.u_mb.nvi_n;
    lc_nvi_q  <= u_core.lc_nvi_n;
    if (cfg_lc && (u_core.u_mb.nvi_n != nvi_pin_q || u_core.lc_nvi_n != lc_nvi_q))
      $display("LCNVI z%0d cpu %b u62 %b cn11 %b", zcyc, u_core.u_mb.nvi_n, u_core.u_mb.u62_nvi_n, u_core.lc_nvi_n);
  end

  // HR bitmap shadow (+hr): every CPU or DMA write to 3E0000-3FFFFF as the
  // bus carries it, every read checked against it, and the card's bitmap
  // against it at the end.  The address is taken in the first /DS-Low clock.
  logic [7:0]  hr_shadow [0:131071];
  logic [16:0] hm_a;
  logic        hm_on, hm_first;
  int          hm_err, hm_rd, hm_wr;
  initial begin
    for (int i = 0; i < 131072; i++) hr_shadow[i] = 8'h00;
    hm_on = 1'b0; hm_first = 1'b1; hm_err = 0; hm_rd = 0; hm_wr = 0;
  end
  always_ff @(posedge clk) begin
    if (!u_core.ds_n && hm_first) begin
      hm_first <= 1'b0;
      hm_on    <= cfg_hr && u_core.pa[23:17] == 7'h1F && !u_core.mreq_n;
      hm_a     <= u_core.pa[16:0];
    end
    if (rst_n && !ds_q && u_core.ds_n) begin
      hm_first <= 1'b1;
      if (hm_on) begin
        logic [16:0] wa;
        logic        bad;
        wa = {hm_a[16:1], 1'b0};
        if (!t_rw) begin
          hm_wr <= hm_wr + 1;
          if (!t_bw || !hm_a[0]) hr_shadow[wa]     = t_data[15:8];
          if (!t_bw ||  hm_a[0]) hr_shadow[wa + 1] = t_data[7:0];
        end else begin
          hm_rd <= hm_rd + 1;
          bad = ((!t_bw || !hm_a[0]) && t_data[15:8] != hr_shadow[wa]) ||
                ((!t_bw ||  hm_a[0]) && t_data[7:0] != hr_shadow[wa + 1]);
          if (bad) begin
            hm_err <= hm_err + 1;
            if (hm_err < 20)
              $display("HRMON z%0d read %05h %s got %04h, written %02h%02h", t_cyc, hm_a, t_bw ? "B" : "W",
                       t_data, hr_shadow[wa], hr_shadow[wa + 1]);
          end
        end
      end
    end
  end
  final if (cfg_hr) begin
    int nd;
    nd = 0;
    for (int a = 0; a < 131072; a++)
      if (u_core.u_dispram.mem[a >> 3][8 * (a & 7) +: 8] != hr_shadow[a]) begin
        if (nd < 20) $display("HRMON bitmap %05h card %02h written %02h", a, u_core.u_dispram.mem[a >> 3][8 * (a & 7) +: 8], hr_shadow[a]);
        nd++;
      end
    $display("HRMON: %0d reads, %0d writes, %0d read mismatches, %0d bitmap bytes differ", hm_rd, hm_wr, hm_err, nd);
  end

  // SCC U74 transmit: a CPU byte write to a channel's data register (port
  // 0x0111 channel B, 0x0131 channel A; AD5 selects the channel).
  // +scctx=<file> also writes them.
  string scc_path;
  int    scc_fd, scc_n, stopbytes;
  string stop_str, stop_hist;
  logic  stop_hit;
  initial begin
    scc_n = 0; stop_hist = ""; stop_hit = 1'b0;
    if (!$value$plusargs("stopbytes=%d", stopbytes)) stopbytes = 0;
    if (!$value$plusargs("stopstr=%s", stop_str)) stop_str = "";
  end
  initial begin
    scc_fd = 0;
    if ($value$plusargs("scctx=%s", scc_path)) scc_fd = $fopen(scc_path, "w");
  end
  always_ff @(posedge clk) begin
    if (rst_n && !ds_q && u_core.ds_n && t_st == 4'h2 && !t_rw &&
        (t_off == 16'h0111 || t_off == 16'h0131)) begin
      $display("SCC %s @%0d: %02h '%s'", t_off[5] ? "A" : "B", t_cyc, t_data[7:0],
               printable(t_data[7:0]));
      if (scc_fd != 0) $fwrite(scc_fd, "WR %0d %04h %02h\n", t_cyc - 1, t_off, t_data[7:0]);
      last_tx <= zcyc;
      scc_n <= scc_n + 1;
      if (!t_off[5] && stop_str.len() > 0) begin
        stop_hist = $sformatf("%s%c", stop_hist, t_data[7:0]);
        if (stop_hist.len() > 80) stop_hist = stop_hist.substr(stop_hist.len() - 80, stop_hist.len() - 1);
        if (stop_hist.len() >= stop_str.len() &&
            stop_hist.substr(stop_hist.len() - stop_str.len(), stop_hist.len() - 1) == stop_str)
          stop_hit <= 1'b1;
      end
    end
  end

  // U74 B TxD and the HPS UART TxD (uart_sel at its default, U74 B)
  // decoded at +txbit=<n> PCLKs per bit (default 608: x16, TC 17):
  // "TXD <pin> @<clock>: <byte>" lines.
  logic uart_txd, uart_rts, uart_dtr;
  uart_sel u_uart_sel (
    .clk(clk), .sel(3'd0), .uart_rxd(1'b1), .uart_cts(1'b0), .uart_dsr(1'b0),
    .uart_txd(uart_txd), .uart_rts(uart_rts), .uart_dtr(uart_dtr),
    .ser_rxd(), .ser_cts_n(), .ser_dcd_n(), .ser_dsr_n(),
    .ser_txd(ser_txd), .ser_rts_n(ser_rts_n), .ser_dtr_n(ser_dtr_n)
  );
  int txbit;
  initial if (!$value$plusargs("txbit=%d", txbit)) txbit = 608;
  logic [1:0] rx_line;
  assign rx_line = {uart_txd, ser_txd[1]};
  int         rx_cnt [2];
  logic [8:0] rx_sr  [2];
  logic [3:0] rx_bit [2];
  initial for (int i = 0; i < 2; i++) begin rx_cnt[i] = 0; rx_bit[i] = 4'd0; end
  always_ff @(posedge clk) if (rst_n && zrise) begin
    for (int i = 0; i < 2; i++) begin
      if (rx_bit[i] == 4'd0) begin
        if (!rx_line[i]) begin rx_bit[i] <= 4'd1; rx_cnt[i] <= txbit / 2; end
      end else if (rx_cnt[i] == txbit - 1) begin
        rx_cnt[i] <= 0;
        if (rx_bit[i] == 4'd10) begin
          rx_bit[i] <= 4'd0;
          $display("TXD %s @%0d: %02h '%s'%s", i ? "UART" : "U74B", zcyc, rx_sr[i][8:1],
                   printable(rx_sr[i][8:1]), rx_line[i] ? "" : " framing");
        end else begin
          rx_bit[i] <= rx_bit[i] + 4'd1;
          rx_sr[i]  <= {rx_line[i], rx_sr[i][8:1]};
        end
      end else rx_cnt[i] <= rx_cnt[i] + 1;
    end
  end

  // +serin=<file>: scripted typing on U74 B RxD.  Each line is
  // "<expect> <send>" in hex: once channel B has written <expect>, <send>
  // goes out 8N1 at +txbit clocks per bit, two idle bits after each byte.
  int         sin_fd, sin_cnt, sin_i;
  logic [3:0] sin_bit;
  logic       sin_go;
  string      sin_exp, sin_send, sin_hist;
  function automatic string unhex(input string h);
    string s;
    int    b;
    s = "";
    for (int i = 0; i + 1 < h.len(); i += 2) begin
      void'($sscanf(h.substr(i, i + 1), "%h", b));
      s = $sformatf("%s%c", s, b[7:0]);
    end
    return s;
  endfunction
  // $fscanf in its own statement: inside the && it returns nothing after
  // the first line (Verilator).
  task automatic sin_next();
    string e, s;
    int    r;
    sin_exp = ""; sin_send = "";
    if (sin_fd == 0) return;
    r = $fscanf(sin_fd, "%s %s\n", e, s);
    if (r == 2) begin
      sin_exp = unhex(e); sin_send = unhex(s);
    end
  endtask
  initial begin
    string p;
    sin_fd = 0; sin_rxd = 1'b1; sin_go = 1'b0; sin_bit = 4'd0; sin_cnt = 0; sin_i = 0; sin_hist = "";
    if ($value$plusargs("serin=%s", p)) begin
      sin_fd = $fopen(p, "r");
      if (sin_fd == 0) $fatal(1, "cannot open %s", p);
    end
    sin_next();
  end
  always_ff @(posedge clk) if (sin_fd != 0) begin
    if (!sin_go && rst_n && !ds_q && u_core.ds_n && t_st == 4'h2 && !t_rw && t_off == 16'h0111 &&
        sin_send.len() > 0) begin
      sin_hist = $sformatf("%s%c", sin_hist, t_data[7:0]);
      if (sin_hist.len() > 64) sin_hist = sin_hist.substr(sin_hist.len() - 64, sin_hist.len() - 1);
      if (sin_hist.len() >= sin_exp.len() &&
          sin_hist.substr(sin_hist.len() - sin_exp.len(), sin_hist.len() - 1) == sin_exp) begin
        $display("SERIN @%0d: %0d bytes", zcyc, sin_send.len());
        sin_go <= 1'b1; sin_i <= 0; sin_bit <= 4'd0; sin_cnt <= 0;
        sin_hist = "";
      end
    end
    if (sin_go && zrise) begin
      if (sin_cnt != txbit - 1) sin_cnt <= sin_cnt + 1;
      else begin
        sin_cnt <= 0;
        if (sin_bit == 4'd11) begin
          sin_bit <= 4'd0;
          if (sin_i + 1 < sin_send.len()) sin_i <= sin_i + 1;
          else begin sin_go <= 1'b0; sin_next(); end
        end else sin_bit <= sin_bit + 4'd1;
      end
      case (sin_bit)
        4'd0:          sin_rxd <= 1'b0;
        4'd9, 4'd10, 4'd11: sin_rxd <= 1'b1;
        default:       sin_rxd <= sin_send[sin_i][sin_bit - 4'd1];
      endcase
    end
  end

  // Key press/release, and CPU reads of CIO U70 PACAS (0x0011, when it
  // changes), PADATA (0x001B) and PCDATA (0x001F).
  logic [7:0] pacas_last;
  logic       dav_prev;
  initial begin pacas_last = 8'h00; dav_prev = 1'b0; end
  always_ff @(posedge clk) begin
    if (rst_n && key_idx >= 0 && zrise) begin
      if (zcyc == key_at) begin
        tb_keys[key_idx] <= 1'b1;
        $display("KEY press %0d @%0d", key_idx, zcyc);
      end
      if (zcyc == key_at + key_hold) begin
        tb_keys[key_idx] <= 1'b0;
        $display("KEY release %0d @%0d", key_idx, zcyc);
      end
    end
    if (rst_n && !ds_q && u_core.ds_n && t_st == 4'h2 && t_rw &&
        (t_off == 16'h001B || t_off == 16'h001F ||
         (t_off == 16'h0011 && t_data[7:0] != pacas_last))) begin
      $display("IORD %0d %04h %02h", t_cyc, t_off, t_data[7:0]);
      if (t_off == 16'h0011) pacas_last <= t_data[7:0];
    end
    dav_prev <= u_core.u_311075.dav;
    if (rst_n && u_core.u_311075.dav && !dav_prev)
      $display("KBD byte %02h @%0d", {u_core.u_311075.updown, u_core.u_311075.data}, zcyc);
  end

  // 6508 bus cycles (+fdctrace=<file>, from +fdcfrom=<n> to +fdcto=<n>
  // Z8001 clocks), one line per change of the pins.
  string  fdc_path, fdc_prev;
  int     fdc_fd;
  longint fdc_from, fdc_to;
  initial begin
    fdc_fd = 0; fdc_prev = "";
    if (!$value$plusargs("fdcfrom=%d", fdc_from)) fdc_from = 0;
    if (!$value$plusargs("fdcto=%d", fdc_to)) fdc_to = 64'h7FFFFFFFFFFFFFFF;
    if ($value$plusargs("fdctrace=%s", fdc_path)) fdc_fd = $fopen(fdc_path, "w");
  end
  always_ff @(posedge clk) begin
    if (fdc_fd != 0 && rst_n && zcyc >= fdc_from && zcyc < fdc_to) begin
      string f;
      if (u_core.u_fdc.cpu_rw_n)
        f = $sformatf("%04h R s=%0d i=%0d", u_core.u_fdc.cpu_addr, u_core.u_fdc.u201_cpu.cpu_sync,
                      u_core.u_fdc.ireq_n);
      else
        f = $sformatf("%04h W %02h i=%0d", u_core.u_fdc.cpu_addr, u_core.u_fdc.cpu_dout,
                      u_core.u_fdc.ireq_n);
      if (f != fdc_prev) begin
        $fwrite(fdc_fd, "F %0d %s\n", zcyc, f);
        fdc_prev = f;
      end
    end
  end

  // 8049 program address and ports (+hdctrace=<file>, +hdcfrom/+hdcto), one
  // line per change.
  string  hdc_path, hdc_prev;
  int     hdc_fd;
  longint hdc_from, hdc_to;
  initial begin
    hdc_fd = 0; hdc_prev = "";
    if (!$value$plusargs("hdcfrom=%d", hdc_from)) hdc_from = 0;
    if (!$value$plusargs("hdcto=%d", hdc_to)) hdc_to = 64'h7FFFFFFFFFFFFFFF;
    if ($value$plusargs("hdctrace=%s", hdc_path)) hdc_fd = $fopen(hdc_path, "w");
  end
  always_ff @(posedge clk) begin
    if (hdc_fd != 0 && rst_n && zcyc >= hdc_from && zcyc < hdc_to) begin
      string h;
      h = $sformatf("%03h p1=%02h p2=%02h ale=%0d rd=%0d wr=%0d", u_core.u_hdc.u10_cccp.pmem_addr[10:0],
                    u_core.u_hdc.p1, u_core.u_hdc.p2, u_core.u_hdc.ale, u_core.u_hdc.rd_n,
                    u_core.u_hdc.wr_n);
      if (h != hdc_prev) begin
        $fwrite(hdc_fd, "H %0d %s\n", zcyc, h);
        hdc_prev = h;
      end
    end
  end

  logic [7:0] t48_a_q;
  always_ff @(posedge clk) t48_a_q <= u_core.u_hdc.u10_cccp.dmem_addr;
  always_ff @(posedge clk) if ($test$plusargs("dbg8049") && rst_n && zcyc >= dbg_lo && zcyc < dbg_hi &&
                              (u_core.u_hdc.u10_cccp.dmem_we || t48_a_q != u_core.u_hdc.u10_cccp.dmem_addr))
    $display("t48 z%0d we=%b a=%02h wd=%02h pm=%03h", zcyc, u_core.u_hdc.u10_cccp.dmem_we,
             u_core.u_hdc.u10_cccp.dmem_addr, u_core.u_hdc.u10_cccp.dmem_wdata,
             u_core.u_hdc.u10_cccp.pmem_addr);

  // DMA memory cycles (+dmalog=<file>): clock, word address and
  // direction at the /DS fall; the 8716's word on a write to memory.
  string dma_path;
  int    dma_fd;
  initial begin
    dma_fd = 0;
    if ($value$plusargs("dmalog=%s", dma_path)) dma_fd = $fopen(dma_path, "w");
  end
  logic dma_ds_q;
  always_ff @(posedge clk) begin
    dma_ds_q <= u_core.ds_n | u_core.u_mb.dmaen_n;
    if (dma_fd != 0 && rst_n && dma_ds_q && !(u_core.ds_n | u_core.u_mb.dmaen_n)) begin
      if (u_core.u_mb.dma_dir)
        $fwrite(dma_fd, "D %0d %06h R\n", zcyc, {u_core.u_mb.dma_wa, 1'b0});
      else
        $fwrite(dma_fd, "D %0d %06h W %04h\n", zcyc, {u_core.u_mb.dma_wa, 1'b0}, u_core.u_mb.dma_ad_out);
    end
  end

  // LANCE bus-master cycles (+landma=<file>): clock, physical address,
  // direction, the bus word at the /DS rise.
  int          ld_fd;
  logic        ld_as_q, ld_ds_q, ld_rw, ld_v;
  logic [23:0] ld_a;
  logic [15:0] ld_d;
  initial begin
    string p;
    ld_fd = 0; ld_v = 1'b0;
    if ($value$plusargs("landma=%s", p)) ld_fd = $fopen(p, "w");
  end
  always_ff @(posedge clk) if (ld_fd != 0) begin
    ld_as_q <= u_core.as_n;
    ld_ds_q <= u_core.ds_n;
    if (!u_core.ds_n) ld_d <= u_core.ad_q;
    if (u_core.ln_bus_oe_c && !ld_as_q && u_core.as_n) begin
      ld_a  <= {u_core.ln_m_a_hi, u_core.ad_q};
      ld_rw <= u_core.r_w;
      ld_v  <= 1'b1;
    end
    if (ld_v && !ld_ds_q && u_core.ds_n) begin
      ld_v <= 1'b0;
      $fwrite(ld_fd, "L %0d %06h %s %04h\n", zcyc, ld_a, ld_rw ? "R" : "W", ld_d);
    end
  end
  final if (ld_fd != 0) $fclose(ld_fd);

  // VI acknowledges, and those no device answered (the vector reads FFFF).
  int vi_ack, vi_ffff;
  initial begin
    vi_ack = 0; vi_ffff = 0;
  end
  always_ff @(posedge clk) begin
    if (rst_n && !ds_q && u_core.ds_n && u_core.u_mb.dmaen_n && t_st == 4'h7) begin
      vi_ack <= vi_ack + 1;
      if (t_data == 16'hFFFF) begin
        vi_ffff <= vi_ffff + 1;
        $display("VIACK FFFF @%0d", t_cyc);
      end
    end
  end
  final $display("VIACK: %0d acknowledges, %0d read FFFF", vi_ack, vi_ffff);

  // A register access taken by the SCC or a CIO while the 8716 has the bus;
  // DMASEL: a DMA /DS fall while a chip still holds the select of its /AS.
  int   dma_io;
  logic dmasel_ds_q;
  initial dma_io = 0;
  always_ff @(posedge clk) begin
    dmasel_ds_q <= u_core.ds_n | u_core.u_mb.dmaen_n;
    if (rst_n && dmasel_ds_q && !(u_core.ds_n | u_core.u_mb.dmaen_n)) begin
      if (u_core.u_mb.u74_scc.bus_active)
        $display("DMASEL SCC U74 @%0d %06h", zcyc, {u_core.u_mb.dma_wa, 1'b0});
      if (u_core.u_mb.u70_cio1.owned)
        $display("DMASEL CIO U70 @%0d %06h", zcyc, {u_core.u_mb.dma_wa, 1'b0});
      if (u_core.u_mb.u66_cio2.owned)
        $display("DMASEL CIO U66 @%0d %06h", zcyc, {u_core.u_mb.dma_wa, 1'b0});
      if (u_core.u_lr.u31_scc.bus_active)
        $display("DMASEL SCC U31 @%0d %06h", zcyc, {u_core.u_mb.dma_wa, 1'b0});
      if (u_core.u_lr.u36_scc.bus_active)
        $display("DMASEL SCC U36 @%0d %06h", zcyc, {u_core.u_mb.dma_wa, 1'b0});
    end
    if (rst_n && !u_core.u_mb.dmaen_n) begin
      if (u_core.u_mb.u74_scc.bus_cycle) begin
        $display("DMAIO SCC U74 @%0d %06h r/w %0d reg %0d data %02h", zcyc, {u_core.u_mb.dma_wa, 1'b0},
                 u_core.u_mb.u74_scc.ds_rw_now, u_core.u_mb.u74_scc.bus_reg_n, u_core.u_mb.u74_scc.ad_wr);
        dma_io <= dma_io + 1;
      end
      if (u_core.u_lr.u31_scc.bus_cycle) begin
        $display("DMAIO SCC U31 @%0d %06h r/w %0d reg %0d data %02h", zcyc, {u_core.u_mb.dma_wa, 1'b0},
                 u_core.u_lr.u31_scc.ds_rw_now, u_core.u_lr.u31_scc.bus_reg_n, u_core.u_lr.u31_scc.ad_wr);
        dma_io <= dma_io + 1;
      end
      if (u_core.u_lr.u36_scc.bus_cycle) begin
        $display("DMAIO SCC U36 @%0d %06h r/w %0d reg %0d data %02h", zcyc, {u_core.u_mb.dma_wa, 1'b0},
                 u_core.u_lr.u36_scc.ds_rw_now, u_core.u_lr.u36_scc.bus_reg_n, u_core.u_lr.u36_scc.ad_wr);
        dma_io <= dma_io + 1;
      end
      if (u_core.u_mb.u70_cio1.ds_fall && u_core.u_mb.u70_cio1.as_intack_n &&
          u_core.u_mb.u70_cio1.cs1 && u_core.u_mb.u70_cio1.owned) begin
        $display("DMAIO CIO U70 @%0d %06h", zcyc, {u_core.u_mb.dma_wa, 1'b0});
        dma_io <= dma_io + 1;
      end
      if (u_core.u_mb.u66_cio2.ds_fall && u_core.u_mb.u66_cio2.as_intack_n &&
          u_core.u_mb.u66_cio2.cs1 && u_core.u_mb.u66_cio2.owned) begin
        $display("DMAIO CIO U66 @%0d %06h", zcyc, {u_core.u_mb.dma_wa, 1'b0});
        dma_io <= dma_io + 1;
      end
    end
  end
  final $display("DMAIO: %0d peripheral accesses during DMA", dma_io);

  // S1: pressed at +s1=<n> for 6000 Z8001 clocks; the OSD changes with the
  // press (+s1ram, +s1lr).  _MRESET and _PRESET edges are reported.
  longint s1_at;
  int     s1_ram;
  logic   s1_done, mres_q, pres_q;
  int hd_cyl;
  initial if (!$value$plusargs("hdcyl=%d", hd_cyl)) hd_cyl = -1;
  always_ff @(posedge clk) if (hd_cyl >= 0 && zrise && zcyc == 1) begin
    force u_core.u_hdc.g_drive[0].u_drive.u_drive.cyl_q = 11'(hd_cyl);
    release u_core.u_hdc.g_drive[0].u_drive.u_drive.cyl_q;
  end

  longint s1_hold;
  initial begin
    if (!$value$plusargs("s1hold=%d", s1_hold)) s1_hold = 0;
    s1 = s1_hold > 0;
    s1_done = 1'b0;
    if (!$value$plusargs("s1=%d", s1_at)) s1_at = -1;
    if (!$value$plusargs("s1ram=%d", s1_ram)) s1_ram = -1;
  end
  always_ff @(posedge clk) begin
    if (zrise && zcyc == s1_at)        {s1, s1_done} <= 2'b11;
    if (zrise && zcyc == s1_at + 6000) s1 <= 1'b0;
    if (zrise && zcyc == s1_hold)      s1 <= 1'b0;
    mres_q <= mreset_n;
    pres_q <= u_core.u_mb.preset_n;
    if (rst_n && zcyc != 0 && mres_q != mreset_n)
      $display("MRESET %s @%0d (PRESET %0d)", mreset_n ? "High" : "Low", zcyc, u_core.u_mb.preset_n);
    if (rst_n && pres_q && !u_core.u_mb.preset_n) $display("PRESET Low @%0d", zcyc);
  end
  always_ff @(posedge clk) begin
    if (!mreset_n) begin
      cfg_nocard <= osd_nocard && !(s1_done && $test$plusargs("s1lr"));
      cfg_512k   <= (s1_done && s1_ram >= 0) ? s1_ram == 1 : osd_512k;
      cfg_card   <= (s1_done && s1_ram >= 0) ? (s1_ram == 2 ? 3'd1 : s1_ram == 3 ? 3'd4 : 3'd0) : osd_card;
    end
  end
  final $display("CONFIG: ram %0d ramcard %0d card %0d", cfg_512k, cfg_card, !cfg_nocard);

  always_ff @(posedge clk) if ($test$plusargs("dbgfdc") && zcyc < dbg_hi && zrise)
    $display("Q %0d ph2=%0d fa=%04h rstn=%0d", zcyc, u_core.u_fdc.ph2_q, u_core.u_fdc.cpu_addr, rst_n);

  // 8716 controller bus (+cbus=<file>, +cfrom/+cto).
  string  cb_path, cb_prev;
  int     cb_fd;
  longint cb_from, cb_to;
  initial begin
    cb_fd = 0; cb_prev = "";
    if (!$value$plusargs("cfrom=%d", cb_from)) cb_from = 0;
    if (!$value$plusargs("cto=%d", cb_to)) cb_to = 64'h7FFFFFFFFFFFFFFF;
    if ($value$plusargs("cbus=%s", cb_path)) cb_fd = $fopen(cb_path, "w");
  end
  always_ff @(posedge clk) begin
    if (cb_fd != 0 && rst_n && zcyc >= cb_from && zcyc < cb_to) begin
      string c;
      c = $sformatf("ss=%0d sd=%0d bd=%02h ireq=%0d est=%0d breq=%0d", u_core.u_mb.pcss, u_core.u_mb.pcsd,
                    u_core.bd_q, u_core.ireq_n, u_core.est_n, u_core.u_mb.dma_busreq_n);
      if (c != cb_prev) begin
        $fwrite(cb_fd, "C %0d %s\n", zcyc, c);
        cb_prev = c;
      end
    end
  end

  always_ff @(posedge clk) if ($test$plusargs("dbghdc") && zcyc >= dbg_lo && zcyc < dbg_hi)
    $display("hdc z%0d ce=%b x3=%0d rd=%b wr=%b pcsd=%b bdq=%02h cbus=%02h ale=%b dbdir=%b pm=%03h", zcyc,
             zrise, u_core.u_hdc.u10_cccp.xtal3, u_core.u_hdc.rd_n, u_core.u_hdc.wr_n,
             u_core.u_hdc.pcsd_n, u_core.bd_q, u_core.u_hdc.cbus, u_core.u_hdc.ale, u_core.u_hdc.db_dir,
             u_core.u_hdc.u10_cccp.pmem_addr);
  always_ff @(posedge clk) if ($test$plusargs("dbghdc") && zcyc >= dbg_lo && zcyc < dbg_hi && zrise)
    $display("t48i z%0d x3=%b ms=%0d c2=%b rb=%b dout=%02h", zcyc,
             u_core.u_hdc.u10_cccp.core.xtal3_s, u_core.u_hdc.u10_cccp.core.clk_mstate_s,
             u_core.u_hdc.u10_cccp.core.clk_second_cycle_s, u_core.u_hdc.u10_cccp.core.bus_read_bus_s,
             u_core.u_hdc.u10_cccp.core.bus_data_s);

  function automatic string printable(input logic [7:0] c);
    if (c >= 8'h20 && c < 8'h7F) return $sformatf("%c", c);
    return $sformatf("\\x%02h", c);
  endfunction

  // Progress and stop.
  always_ff @(posedge clk) begin
    if (rst_n && zrise) begin
      if ((zcyc % 64'd1000000) == 0)
        $display("progress: %0d Z8001 clocks, PC fetch seg %02h", zcyc, u_core.u_mb.sn_q);
      if (zcyc >= maxcyc) begin
        $display("stop: %0d Z8001 clocks", zcyc);
        if (trace_fd != 0) $fclose(trace_fd);
        $finish;
      end
      if (stopbytes != 0 && scc_n >= stopbytes) begin
        $display("stop: %0d SCC bytes, %0d Z8001 clocks", scc_n, zcyc);
        if (trace_fd != 0) $fclose(trace_fd);
        $finish;
      end
      if (stop_hit) begin
        $display("stop: \"%s\" on SCC B, %0d Z8001 clocks", stop_str, zcyc);
        if (trace_fd != 0) $fclose(trace_fd);
        $finish;
      end
      if (idle != 0 && last_tx >= 0 && zcyc >= last_tx + idle) begin
        $display("stop: idle %0d clocks after the last SCC byte (%0d)", idle, zcyc);
        if (trace_fd != 0) $fclose(trace_fd);
        $finish;
      end
    end
  end

  // A child forked by tb_core.cpp closes the parent's output files and takes
  // its own options.  It forks before its stimulus clocks.
  export "DPI-C" function tb_child_cfg;
  // The child's log opens with the parent's lines so far.
  function automatic int fork_open(input string path, input string parent);
    int fd, pf;
    string line;
    fd = $fopen(path, "w");
    if (fd == 0) $fatal(1, "cannot open %s", path);
    pf = 0;
    if (parent.len() > 0) pf = $fopen(parent, "r");
    if (pf == 0) $display("fork: %s starts at the fork (no parent log)", path);
    else begin
      while ($fgets(line, pf) > 0) $fwrite(fd, "%s", line);
      $fclose(pf);
    end
    return fd;
  endfunction
  function automatic void tb_child_cfg();
    begin
      string p;
      $display("fork: child at Z8001 clock %0d", zcyc);
      if (!$value$plusargs("maxcyc=%d", maxcyc)) maxcyc = 64'd20000000;
      if (!$value$plusargs("idle=%d", idle)) idle = 0;
      if (!$value$plusargs("stopbytes=%d", stopbytes)) stopbytes = 0;
      if (!$value$plusargs("key=%d", key_idx)) key_idx = -1;
      if (!$value$plusargs("keyat=%d", key_at)) key_at = 0;
      if (!$value$plusargs("keyhold=%d", key_hold)) key_hold = 100000;
      if (!$value$plusargs("s1=%d", s1_at)) s1_at = -1;
      if (!$value$plusargs("s1ram=%d", s1_ram)) s1_ram = -1;
      if (scc_fd != 0) $fclose(scc_fd);
      if (dma_fd != 0) $fclose(dma_fd);
      if (trace_fd != 0) $fclose(trace_fd);
      if (prn_fd != 0) $fclose(prn_fd);
      if (fdc_fd != 0) $fclose(fdc_fd);
      if (hdc_fd != 0) $fclose(hdc_fd);
      if (cb_fd != 0) $fclose(cb_fd);
      {scc_fd, dma_fd, trace_fd, prn_fd, fdc_fd, hdc_fd, cb_fd} = '0;
      if ($value$plusargs("scctx=%s", p)) scc_fd = fork_open(p, scc_path);
      if ($value$plusargs("dmalog=%s", p)) dma_fd = fork_open(p, dma_path);
      if ($value$plusargs("trace=%s", p)) trace_fd = $fopen(p, "w");
      load_images();
      if (mnt_want != 3'b000) mnt_gen = mnt_gen + 1;
    end
  endfunction

  always_ff @(posedge clk) if ($test$plusargs("dbg") && rst_n && zcyc >= dbg_lo && zcyc < dbg_hi)
    $display("z%0d qar=%b as=%b ds=%b mreq=%b st=%h pa=%06h drv=%b romcs=%b ad_q=%04h romq=%04h adr=%04h mpa=%06h cpuad=%04h/%b ras=%b%b cas=%b%b%b%b mrd=%b mwr=%b ack=%b doe=%b sccdrv=%b sccout=%02h cpuds=%b ot=%b r4=%04h | sel=%b wt=%b acc=%b slot=%b ad_in=%04h breq=%b back=%b dmaen=%b",
      zcyc, u_core.u_mb.qa_rise, u_core.as_n, u_core.ds_n, u_core.mreq_n, u_core.st, u_core.pa,
      u_core.u_mb.mmu_pa_drive, u_core.u_mb.romcs_n, u_core.ad_q, u_core.u_mb.dram_d_out, u_core.u_mb.adr, u_core.u_mb.mmu_pa, u_core.u_mb.cpu_ad_out, u_core.u_mb.cpu_clk_rise, u_core.u_mb.ras0_n, u_core.u_mb.ras1_n, u_core.u_mb.cas0h_n, u_core.u_mb.cas0l_n, u_core.u_mb.cas1h_n, u_core.u_mb.cas1l_n, mem_rd, mem_wr, mem_ack, u_core.u_mb.dram_d_oe, u_core.u_mb.scc_ad_drive, u_core.u_mb.scc_ad_out, u_core.u_mb.cpu_ds_n, u_core.u_mb.u1_cpu.opnd_take, u_core.u_mb.u1_cpu.u_regfile.r[4], u_core.u_lr.u5_u6.cdr_sel, u_core.u_lr.u5_u6.wait_n, u_core.u_lr.u5_u6.access, u_core.u_lr.u5_u6.slot, u_core.u_lr.u5_u6.ad_in, u_core.u_mb.busreq_n, u_core.u_mb.busack_n, u_core.u_mb.dmaen_n);

  // LR screen: the character SRAM U5 as 25 rows of 80 at the end of the
  // run (+screen), and the clock of the last CPU write into it.
  longint vram_last;
  initial vram_last = -1;
  always_ff @(posedge clk) if (rst_n && u_core.u_lr.u5_u6.we_chr) vram_last <= zcyc;
  final begin
    if ($test$plusargs("screen") && !cfg_nocard && !cfg_hr) begin
      $display("--- LR screen (U5), last CPU write at Z8001 clock %0d ---", vram_last);
      for (int row = 0; row < 25; row++) begin
        string line;
        line = "";
        for (int col = 0; col < 80; col++) begin
          logic [7:0] c;
          c = u_core.u_lr.u5_u6.u5_mem[row * 80 + col];
          line = {line, (c >= 8'h20 && c < 8'h7F) ? string'(c) : " "};
        end
        $display("%02d|%s|", row, line);
      end
    end
  end

  // LR video frame: +frame=<file.pgm> writes the first full frame (DE area)
  // that starts after Z8001 clock +frameat=<n>, as the core outputs it.
  string  frame_path;
  longint frame_at;
  int     fx, fy, frame_state;   // 0 waiting, 1 armed (next vsync), 2 capturing, 3 done
  logic   vs_q, de_q2;
  logic [7:0] frame [0:399][0:799];
  initial begin
    frame_state = 3;
    if ($value$plusargs("frame=%s", frame_path)) frame_state = 0;
    if (!$value$plusargs("frameat=%d", frame_at)) frame_at = 0;
    fx = 0; fy = 0; vs_q = 1'b0; de_q2 = 1'b0;
  end
  logic crtc_e_q;
  always_ff @(posedge clk) crtc_e_q <= u_core.u_lr.ph2;
  always_ff @(posedge clk) if ($test$plusargs("crtclog") && crtc_e_q && !u_core.u_lr.ph2 &&
                              !u_core.u_lr.e_cs_n_q && !u_core.u_lr.e_rw_q)
    $display("crtc wr @%0d rs=%b d=%02h", zcyc, u_core.u_lr.e_rs_q, u_core.u_lr.e_d_q);
  int n_de, n_vs, n_hs, n_ce;
  initial begin n_de = 0; n_vs = 0; n_hs = 0; n_ce = 0; end
  final if ($test$plusargs("vstat")) $display("video: ce %0d de %0d vsync-clocks %0d hsync-clocks %0d", n_ce, n_de, n_vs, n_hs);
  always @(posedge clk_vid) begin
    if (ce_pix) begin
      n_ce++; if (de) n_de++; if (vsync) n_vs++; if (hsync) n_hs++;
      vs_q  <= vsync;
      de_q2 <= de;
      if (frame_state == 0 && zcyc >= frame_at) frame_state = 1;
      if (vsync && !vs_q) begin
        if ($test$plusargs("vstat")) $display("vsync rise at Z8001 clock %0d, %0d lines since last", zcyc, fy);
        if (frame_state == 1) begin frame_state = 2; fx = 0; fy = 0; end
        else if (frame_state == 2) begin
          int fd;
          fd = $fopen(frame_path, "w");
          $fwrite(fd, "P2\n720 350\n255\n");
          for (int y = 0; y < 350; y++) begin
            for (int x = 0; x < 720; x++) $fwrite(fd, "%0d ", frame[y][x]);
            $fwrite(fd, "\n");
          end
          $fclose(fd);
          $display("frame: wrote %s (%0d lines seen)", frame_path, fy);
          frame_state = 3;
        end
      end
      if (frame_state == 2) begin
        if (de) begin
          if (fy < 400 && fx < 800) frame[fy][fx] = r;
          fx = fx + 1;
        end else if (de_q2) begin
          fx = 0; fy = fy + 1;
        end
      end
    end
  end

  // HR bitmap at the end of the run: 128-byte rows, bit 7 leftmost.
  final begin
    string p;
    if ($value$plusargs("hrvram=%s", p)) begin
      int fd;
      fd = $fopen(p, "w");
      $fwrite(fd, "P1\n1024 800\n");
      for (int a = 0; a < 800 * 128; a++) begin
        logic [7:0] bt;
        bt = u_core.u_dispram.mem[a >> 3][8 * (a & 7) +: 8];
        for (int i = 7; i >= 0; i--) $fwrite(fd, "%0d", bt[i]);
        if (a % 128 == 127) $fwrite(fd, "\n");
      end
      $fclose(fd);
    end
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, sd_lba, sd_rd, sd_wr, sd_buff_din, ser_txd, ser_rts_n, ser_dtr_n,
                       ce_pix, hsync, vsync, de, hblank, vblank, led_fdd, led_hdd, r, hr_ck24, hr_hsync, hr_hsync_n, hr_vsync_n,
                       hr_rgbi, hr_vout, hr_de, hr_de_dly, hr_vblank_n, hr_mono_en, hr_mono_i, mem_refresh_ok};
endmodule
`default_nettype wire
