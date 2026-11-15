// Disk-image path bench: the core behind the MiSTer framework's own hps_io
// and disk_stream, as in the emu.  The C++ driver plays Main_MiSTer on the
// HPS bus (mount: SDINFO then SDSTAT; sector service: SDSTAT poll, a
// latency, then SECTOR_RD/WR of up to 16 KB) from image files it holds in
// memory, and decides when the machine leaves reset.  The DRAM is
// c900_sdram with the dual-chip model, as in tb_core.  No display card.
//
// Plusargs (here; the driver has its own):
//   +rom=<boot0.rom>  32 KB, required
//   +rom1=<boot1.rom> 16 KB, required
//   +patch=<file>     boot0.rom patch lines "<hex offset> <hex byte>"
//   +maxcyc=<n>       stop after n Z8001 clocks
//   +speed=<n>        CPU clock: 0 6 MHz (default), 1 10, 2 12, 3 48 MHz (non-stock)
//   +dmalog=<file>    DMA memory cycles ("D <clock> <addr> R|W [word]")
//   +ram=<file>       RAM bytes "<hex byte address> <hex byte>", stored into
//                     the DRAM when the Z8001 clock count reaches +ramat=<n>
`default_nettype none
module tb_disk (
  input  logic        clk,
  input  logic        clk_ram,
  input  logic        hold,        // driver: keep the machine in reset
  input  logic        io_enable,
  input  logic        io_strobe,
  input  logic [15:0] io_din,
  output logic [15:0] io_dout,
  output logic        core_rst_n,
  output logic        loading_busy,
  output logic [3:0]  resident,
  output logic        done
);
  logic clk_vid;
  assign clk_vid = clk;

  // ---- boot ROM ---------------------------------------------------------------
  logic [7:0] image [0:49151];
  longint     maxcyc;
  logic [1:0] speed;
  initial begin
    string p;
    int fd, n, off, val;
    if (!$value$plusargs("rom=%s", p)) $fatal(1, "need +rom=<boot0.rom>");
    fd = $fopen(p, "rb");
    if (fd == 0) $fatal(1, "cannot open %s", p);
    n = $fread(image, fd, 0, 32768);
    $fclose(fd);
    if (n != 32768) $fatal(1, "%s: %0d bytes, want 32768", p, n);
    // boot1.rom follows boot0.rom, as Main loads them
    if (!$value$plusargs("rom1=%s", p)) $fatal(1, "need +rom1=<boot1.rom>");
    fd = $fopen(p, "rb");
    if (fd == 0) $fatal(1, "cannot open %s", p);
    n = $fread(image, fd, 32768, 16384);
    $fclose(fd);
    if (n != 16384) $fatal(1, "%s: %0d bytes, want 16384", p, n);
    if ($value$plusargs("patch=%s", p)) begin
      fd = $fopen(p, "r");
      if (fd == 0) $fatal(1, "cannot open %s", p);
      while ($fscanf(fd, "%h %h\n", off, val) == 2) image[off] = val[7:0];
      $fclose(fd);
    end
    if (!$value$plusargs("maxcyc=%d", maxcyc)) maxcyc = 64'd40000000;
    if (!$value$plusargs("speed=%d", speed)) speed = 2'd0;
  end

  // ---- reset: as tb_core, plus the driver's hold ----------------------------------
  logic        rst_n, pwr_q, loading, ld_wr, rom_busy;
  logic [15:0] ld_addr;
  int          rst_hold;
  longint      mclk, zcyc;
  initial begin loading = 1'b1; ld_addr = 16'h0000; rst_hold = 0; mclk = 0; pwr_q = 1'b0; zcyc = 0; end
  always_ff @(posedge clk) begin
    pwr_q <= 1'b1;
    mclk  <= mclk + 1;
    if (loading) begin
      if (ld_wr) begin
        if (ld_addr == 16'hBFFF) loading <= 1'b0;
        ld_addr <= ld_addr + 16'd1;
      end
    end else if (hold || rom_busy) begin
      rst_hold <= 0;
    end else if (rst_hold < 64 || (mclk % 192) != 191 || !sd_ready) begin
      rst_hold <= (rst_hold < 64) ? rst_hold + 1 : rst_hold;
    end else begin
      rst_hold <= 65;
    end
  end
  assign ld_wr      = loading && pwr_q && !rom_busy;
  assign rst_n      = ~pwr_q || (~loading && !rom_busy && (rst_hold > 64));
  assign core_rst_n = rst_n;

  // ---- hps_io (the framework's) ---------------------------------------------------
  wire [45:0] hps_bus;
  assign hps_bus[35:33] = {1'b0, io_enable, io_strobe};
  assign hps_bus[31:16] = io_din;
  assign hps_bus[45:38] = 8'd0;
  assign io_dout        = hps_bus[15:0];

  localparam CONF_STR = {"C900;;", "S0,IMG,Floppy 0;", "S1,IMG,Floppy 1;", "S2,IMGHDF,Hard Disk 0;",
                         "S3,IMGHDF,Hard Disk 1;"};
  logic [3:0]  img_mounted, sd_rd, sd_wr, sd_ack;
  logic        img_readonly, sd_buff_wr;
  logic [63:0] img_size;
  logic [31:0] sd_lba [4];
  logic [5:0]  sd_blk_cnt [4];
  logic [13:0] sd_buff_addr;
  logic [7:0]  sd_buff_dout, st_h_din;
  logic [7:0]  sd_buff_din [4];
  logic [3:0][31:0] st_h_lba;
  logic [3:0][5:0]  st_h_blk_cnt;
  for (genvar k = 0; k < 4; k++) begin : g_sd
    assign sd_lba[k]      = st_h_lba[k];
    assign sd_blk_cnt[k]  = st_h_blk_cnt[k];
    assign sd_buff_din[k] = st_h_din;
  end

  hps_io #(.CONF_STR(CONF_STR), .VDNUM(4)) u_hps_io (
    .clk_sys(clk), .HPS_BUS(hps_bus), .EXT_BUS(), .gamma_bus(),
    .img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
    .sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(sd_rd), .sd_wr(sd_wr),
    .sd_ack(sd_ack), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
    .sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr)
  );

  // ---- disk_stream -----------------------------------------------------------------
  logic [3:0][31:0] d_lba;
  logic [3:0]       d_mounted, d_rd, d_wr, d_ack, d_scr;
  logic             d_readonly, d_buff_wr, wb_busy, fmt_full;
  logic [63:0]      d_size;
  logic [8:0]       d_buff_addr;
  logic [7:0]       d_buff_dout;
  logic [3:0][7:0]  d_buff_din;
  logic [1:0]       hd_sel;
  logic [1:0][11:0] hd_bpc;
  logic [1:0][15:0] ld_min, ld_max;

  disk_stream u_disk_stream (
    .clk(clk), .rst_n(pwr_q), .core_rst_n(rst_n), .bpc(hd_bpc),
    .img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
    .h_lba(st_h_lba), .h_blk_cnt(st_h_blk_cnt), .h_rd(sd_rd), .h_wr(sd_wr), .h_ack(sd_ack),
    .h_buff_addr(sd_buff_addr), .h_buff_dout(sd_buff_dout), .h_buff_din(st_h_din), .h_buff_wr(sd_buff_wr),
    .d_mounted(d_mounted), .d_readonly(d_readonly), .d_size(d_size),
    .d_lba(d_lba), .d_scr(d_scr), .d_rd(d_rd), .d_wr(d_wr), .d_ack(d_ack),
    .d_buff_addr(d_buff_addr), .d_buff_dout(d_buff_dout), .d_buff_din(d_buff_din), .d_buff_wr(d_buff_wr),
    .resident(resident), .busy(loading_busy), .wb_busy(wb_busy), .fmt_full(fmt_full),
    .ld_min(ld_min), .ld_max(ld_max)
  );
  final $display("unit load clk/1024: floppy %0d-%0d, hard disk %0d-%0d", ld_min[0], ld_max[0], ld_min[1], ld_max[1]);

  // ---- DRAM: c900_sdram and the chip model, as tb_core ------------------------------
  logic [23:1] mem_addr;
  logic        mem_rd, mem_wr, mem_ack, mem_rvalid, mem_refresh_ok, sd_ready;
  logic [1:0]  mem_be;
  logic [15:0] mem_wdata, mem_rdata;

  // The boot ROM loader owns the port while it loads (as C900.sv).
  logic [23:1] ld_maddr;
  logic        ld_sel, ld_mrd, ld_mwr, p_ack, p_rvalid;
  logic [1:0]  ld_be;
  logic [15:0] ld_wdata;
  boot_rom_load u_rom_load (
    .clk(clk), .rst_n(pwr_q), .wr(ld_wr && !ld_addr[15]), .addr(ld_addr), .data(image[ld_addr]),
    .busy(rom_busy), .mem_addr(ld_maddr), .mem_rd(ld_mrd), .mem_wr(ld_mwr), .mem_be(ld_be), .mem_wdata(ld_wdata),
    .mem_rdata(mem_rdata[7:0]), .mem_ack(p_ack)
  );
  assign ld_sel  = loading | rom_busy;
  assign mem_ack    = p_ack & ~ld_sel;
  assign mem_rvalid = p_rvalid & ~ld_sel;
  wire         s_clk, s_cke, s_dqml, s_dqmh, s_ncs, s_nras, s_ncas, s_nwe;
  wire  [12:0] s_a;
  wire  [1:0]  s_ba;
  tri   [15:0] s_dq;
  logic        rst_ram_n;
  initial rst_ram_n = 1'b0;
  always_ff @(posedge clk_ram) rst_ram_n <= pwr_q;
  c900_sdram u_sdram (
    .clk(clk), .clk_ram(clk_ram), .rst_n(pwr_q), .rst_ram_n(rst_ram_n), .refresh_ok(mem_refresh_ok | ld_sel),
    .ready(sd_ready), .addr(ld_sel ? ld_maddr : mem_addr), .rd(ld_sel ? ld_mrd : mem_rd),
    .wr(ld_sel ? ld_mwr : mem_wr), .be(ld_sel ? ld_be : mem_be), .wdata(ld_sel ? ld_wdata : mem_wdata),
    .rdata(mem_rdata), .rvalid(p_rvalid), .ack(p_ack),
    .sdram_clk(s_clk), .sdram_cke(s_cke), .sdram_a(s_a), .sdram_ba(s_ba), .sdram_dq(s_dq),
    .sdram_dqml(s_dqml), .sdram_dqmh(s_dqmh), .sdram_ncs(s_ncs), .sdram_nras(s_nras),
    .sdram_ncas(s_ncas), .sdram_nwe(s_nwe)
  );
  sdram_cycle_model #(.DUAL(1'b1), .REFI_CLKS(750)) u_chips (
    .clk(s_clk), .cke(s_cke), .a(s_a), .ba(s_ba), .dq(s_dq), .dqml(s_dqml), .dqmh(s_dqmh),
    .ncs(s_ncs), .nras(s_nras), .ncas(s_ncas), .nwe(s_nwe)
  );
  final $display("SDRAM: %0d errors", u_chips.errors);

  // ---- the machine, no display card --------------------------------------------------
  logic [1:0] disk_late, disk_late_q;
  logic [5:0] ser_txd, ser_rts_n, ser_dtr_n;
  logic       ce_pix, hsync, vsync, de, hblank, vblank, led_fdd, led_hdd, lr_vid, lr_intens;
  logic       hr_ck24, hr_hsync, hr_hsync_n, hr_vsync_n, hr_de, hr_de_dly, hr_vblank_n, hr_mono_en, hr_mono_i;
  logic [3:0] hr_rgbi, hr_vout;

  c900_core u_core (
    .clk(clk), .clk_vid(clk_vid), .clk_vdc(1'b0), .rst_n(rst_n), .s1(1'b0), .mreset_n(),
    .card_fitted(1'b0), .display_hr(1'b0), .display_lc(1'b0), .hr_mode(2'd0), .ram_512k(1'b0), .ram_card(3'd0), .cpu_speed(speed),
    .lance_en(1'b0), .fpu_en(1'b0), .rtc_hps(65'd0),
    .rom_wr(ld_wr && ld_addr[15]), .rom_addr(ld_addr[13:0]), .rom_data(image[ld_addr]),
    .img_mounted(d_mounted), .img_readonly(d_readonly), .img_size(d_size),
    .sd_lba(d_lba), .sd_rd(d_rd), .sd_wr(d_wr), .sd_scr(d_scr), .sd_ack(d_ack),
    .sd_buff_addr(d_buff_addr), .sd_buff_dout(d_buff_dout), .sd_buff_din(d_buff_din), .sd_buff_wr(d_buff_wr),
    .hd_sel(hd_sel), .hd_bpc(hd_bpc),
    .keys(104'd0), .kbd_mods(5'd0), .m_h(1'b0), .m_hq(1'b0), .m_v(1'b0), .m_vq(1'b0), .m_b_n(3'b111),
    .ser_rxd(6'h3F), .ser_txd(ser_txd), .ser_cts_n(6'h00), .ser_dcd_n(6'h00), .ser_dsr_n(6'h00),
    .ser_rts_n(ser_rts_n), .ser_dtr_n(ser_dtr_n),
    .mem_addr(mem_addr), .mem_rd(mem_rd), .mem_wr(mem_wr), .mem_be(mem_be),
    .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_rvalid(mem_rvalid), .mem_ack(mem_ack),
    .mem_refresh_ok(mem_refresh_ok),
    .ce_pix(ce_pix), .hsync(hsync), .vsync(vsync), .de(de), .hblank(hblank), .vblank(vblank),
    .lr_vid(lr_vid), .lr_intens(lr_intens),
    .hr_ck24(hr_ck24), .hr_hsync(hr_hsync), .hr_hsync_n(hr_hsync_n), .hr_vsync_n(hr_vsync_n),
    .hr_de(hr_de), .hr_de_dly(hr_de_dly), .hr_vblank_n(hr_vblank_n),
    .hr_rgbi(hr_rgbi), .hr_vout(hr_vout), .hr_mono_en(hr_mono_en), .hr_mono_i(hr_mono_i),
    .lc_rgbi(), .lc_hsync(), .lc_vsync(), .lc_pixel_ce(), .lc_active_h(), .lc_active_v(),
    .lan_rclk_rise(1'b0), .lan_rx(1'b0), .lan_rena(1'b0), .lan_clsn(1'b0), .lan_mac_ok(1'b0), .lan_mac(48'd0),
    .led_fdd(led_fdd), .led_hdd(led_hdd), .disk_late(disk_late)
  );

  // ---- monitors ----------------------------------------------------------------------
  always_ff @(posedge clk) if (rst_n && u_core.zclk_rise) zcyc <= zcyc + 1;
  assign done = zcyc >= maxcyc;

  always_ff @(posedge clk) begin
    disk_late_q <= disk_late;
    if (disk_late[0] && !disk_late_q[0]) $display("LATE floppy at %0d", zcyc);
    if (disk_late[1] && !disk_late_q[1]) $display("LATE hard disk at %0d", zcyc);
    for (int s = 0; s < 4; s++)
      if (d_mounted[s])
        $display("DRIVE %0d told: size %0d ro %0d, machine %s, mclk %0d", s, d_size, d_readonly,
                 rst_n ? "running" : "in reset", mclk);
  end

  // drive block requests (image blocks only), drive selects
  logic [3:0] dack_q;
  logic [1:0] hd_sel_q;
  logic [5:0] wd_st, wd_st_q;
  assign wd_st = 6'(u_core.u_hdc.u12_wd2010.st_q);
  always_ff @(posedge clk) begin
    wd_st_q <= wd_st;
    dack_q <= d_ack;
    hd_sel_q <= hd_sel;
    if (hd_sel != hd_sel_q) $display("HDSEL %b at %0d", hd_sel, zcyc);
    if (wd_st != wd_st_q && wd_st == 6'd1)
      $display("WD cmd %02h sel %b drdy %b sc %b at %0d", u_core.u_hdc.u12_wd2010.cmd_q, hd_sel,
               u_core.u_hdc.drdy, u_core.u_hdc.sc, zcyc);
    if (wd_st != wd_st_q && wd_st == 6'd0)
      $display("WD end err %02h at %0d", u_core.u_hdc.u12_wd2010.err_q, zcyc);
    if (hd_sel != 2'b00 && zcyc % 200000 == 0 && u_core.zclk_rise)
      $display("WDST %0d sel %b drdy %b sc %b rdy %b st %0d pc %03h at %0d", wd_st, hd_sel, u_core.u_hdc.drdy,
               u_core.u_hdc.sc, {u_core.u_hdc.g_drive[1].u_drive.u_drive.m_ready,
               u_core.u_hdc.g_drive[0].u_drive.u_drive.m_ready}, u_disk_stream.h_st,
               u_core.u_hdc.u10_cccp.pmem_addr, zcyc);
    for (int s = 0; s < 4; s++)
      if (d_ack[s] && !dack_q[s] && !d_scr[s])
        $display("BLK %0d slot %0d %s lba %0d", zcyc, s, d_wr[s] ? "W" : "R", d_lba[s]);
  end

  // SCC U74 transmit and DMA, as tb_core.
  logic        as_q, ds_q, dma_ds_q, t_rw;
  logic [3:0]  t_st;
  logic [15:0] t_off, t_data;
  longint      t_cyc;
  initial begin as_q = 1'b1; ds_q = 1'b1; dma_ds_q = 1'b1; end
  string dma_path;
  int    dma_fd;
  initial begin
    dma_fd = 0;
    if ($value$plusargs("dmalog=%s", dma_path)) dma_fd = $fopen(dma_path, "w");
  end
  string ram_path;
  longint ramat;
  initial if (!$value$plusargs("ramat=%d", ramat)) ramat = -1;
  always_ff @(posedge clk) if (zcyc == ramat && u_core.zclk_rise && $value$plusargs("ram=%s", ram_path)) begin
    int rfd, ra, rv;
    ramat <= -1;
    rfd = $fopen(ram_path, "r");
    if (rfd == 0) $fatal(1, "cannot open %s", ram_path);
    while ($fscanf(rfd, "%h %h\n", ra, rv) == 2) begin
      if (ra[0]) u_chips.mem[ra[24:1]][7:0] = rv[7:0];
      else       u_chips.mem[ra[24:1]][15:8] = rv[7:0];
    end
    $fclose(rfd);
  end
  always_ff @(posedge clk) begin
    as_q <= u_core.as_n;
    ds_q <= u_core.ds_n;
    if (!u_core.ds_n) t_data <= u_core.ad_q;
    if (rst_n && !as_q && u_core.as_n) begin
      t_st <= u_core.st; t_off <= u_core.u_mb.adr; t_rw <= u_core.r_w; t_cyc <= zcyc;
    end
    if (rst_n && !ds_q && u_core.ds_n && t_st == 4'h2 && !t_rw &&
        (t_off == 16'h0111 || t_off == 16'h0131))
      $display("SCC %s @%0d: %02h", t_off[5] ? "A" : "B", t_cyc, t_data[7:0]);
    dma_ds_q <= u_core.ds_n | u_core.u_mb.dmaen_n;
    if (dma_fd != 0 && rst_n && dma_ds_q && !(u_core.ds_n | u_core.u_mb.dmaen_n)) begin
      if (u_core.r_w) $fwrite(dma_fd, "D %0d %06h R\n", zcyc, {u_core.u_mb.dma_wa, 1'b0});
      else            $fwrite(dma_fd, "D %0d %06h W %04h\n", zcyc, {u_core.u_mb.dma_wa, 1'b0}, u_core.u_mb.dma_ad_out);
    end
  end
endmodule
`default_nettype wire
