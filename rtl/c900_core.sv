// Commodore 900: the machine, independent of the platform shell.
//
// One master clock (48 MHz) for the whole machine: Y1, the U14 74LS93 and
// the off-board crystal stand-ins (fantdiv) drive every chip clock pin
// with one-master-clock pulses at the pin's edges.  The core is
// the backplane: it resolves the Z-Bus AD lines (value + drive per line;
// undriven lines read High, contending drivers resolve Low-wins), the
// wire-AND lines (/VI, /WAIT, /BUSREQ), the interrupt daisy chain, and the
// 8716's controller (B) bus shared by the floppy controller and the hard
// disk card on CN9.
//
// Non-stock options (lance_en, fpu_en, ram_card, cpu_speed
// 1/2) default off and leave the stock machine untouched when off.
`default_nettype none
module c900_core
  import z8000_zbus_pkg::*;
(
  input  logic                 clk,           // 48 MHz
  input  logic                 clk_vid,       // 65.028 MHz: LR dot side (4 x 16.257 MHz)
  input  logic                 clk_vdc,       // 32 MHz: LC 8563, rises with clk every 62.5 ns
  input  logic                 rst_n,
  input  logic                 s1,            // manual reset switch S1 held
  output logic                 mreset_n,      // backplane _MRESET

  // configuration (OSD); changes take effect at reset
  input  logic                 card_fitted,   // a display card is in its slot (0: none)
  input  logic                 display_hr,    // the card in the slot: 0 LR, 1 HR
  input  logic                 display_lc,    // the card in the slot is LC (display_hr 0)
  input  logic [1:0]           hr_mode,       // HR JP3 jumper: 0 1024x800, 1 1024x1024, 2/3 colour
  input  logic                 ram_512k,      // motherboard 512K (bank 1 unfitted), else 1M
  input  logic [2:0]           ram_card,      // RAM card (non-stock): 0 none, 1 2M, 2 4M, 3 8M, 4 15M
  input  logic [1:0]           cpu_speed,     // 0 6 MHz, 1 10, 2 12, 3 48 MHz (1-3 non-stock)
  input  logic                 lance_en,      // non-stock
  input  logic                 fpu_en,        // non-stock
  input  logic [64:0]          rtc_hps,       // HPS time, seeds the RTC (non-stock)

  // peripheral ROM loader: 6508, 8049, 6500/1, character ROM
  input  logic                 rom_wr,
  input  logic [13:0]          rom_addr,
  input  logic [7:0]           rom_data,

  // disk images: [0] fd0, [1] fd1, [2] hd0, [3] hd1 (hps_io sd_* shape, 512 B blocks)
  input  logic [3:0]           img_mounted,
  input  logic                 img_readonly,
  input  logic [63:0]          img_size,
  output logic [3:0][31:0]     sd_lba,
  output logic [3:0]           sd_rd,
  output logic [3:0]           sd_wr,
  output logic [3:0]           sd_scr,      // scratch (fd0/fd1) or format (hd0/hd1) block, never the image file
  input  logic [3:0]           sd_ack,
  input  logic [8:0]           sd_buff_addr,
  input  logic [7:0]           sd_buff_dout,
  output logic [3:0][7:0]      sd_buff_din,
  input  logic                 sd_buff_wr,
  output logic [1:0]           hd_sel,      // hard disk drive select lines
  output logic [1:0][11:0]     hd_bpc,      // hard disk blocks per cylinder, 0 unknown

  // keyboard matrix image and HR J2 mouse port
  input  logic [103:0]         keys,
  input  logic [4:0]           kbd_mods,      // LShift, CapsLock, RShift, Ctrl, LAlt
  output logic [7:0]           kbd_pb,        // keyboard 6500/1 PB, PC0-5 (column strobes) and PA7 (cable clock)
  output logic [5:0]           kbd_pc,
  output logic                 kbd_pa7,
  input  logic                 m_h,
  input  logic                 m_hq,
  input  logic                 m_v,
  input  logic                 m_vq,
  input  logic [2:0]           m_b_n,

  // SCC serial lines (RS-232 side, logic levels), channel A even:
  // [1:0] U74, [3:2] LR U31, [5:4] LR U36.  /DSR reaches only the LR SCCs.
  input  logic [5:0]           ser_rxd,
  output logic [5:0]           ser_txd,
  input  logic [5:0]           ser_cts_n,
  input  logic [5:0]           ser_dcd_n,
  input  logic [5:0]           ser_dsr_n,
  output logic [5:0]           ser_rts_n,
  output logic [5:0]           ser_dtr_n,

  // DRAM port to the platform RAM controller (16-bit words)
  output logic [23:1]          mem_addr,
  output logic                 mem_rd,
  output logic                 mem_wr,
  output logic [1:0]           mem_be,
  output logic [15:0]          mem_wdata,
  input  logic [15:0]          mem_rdata,
  input  logic                 mem_rvalid,    // mem_rdata valid from mid-cycle, before mem_ack
  input  logic                 mem_ack,
  output logic                 mem_refresh_ok,

  // LR card video (clk_vid domain): sync, blanking and the digital pixel bits
  output logic                 ce_pix,
  output logic                 hsync,
  output logic                 vsync,
  output logic                 de,
  output logic                 hblank,
  output logic                 vblank,
  output logic                 lr_vid,        // LR video bit
  output logic                 lr_intens,     // LR intensity bit
  // HR card video pins (clk domain), and its 24M as the dot-clock reference
  output logic                 hr_ck24,       // 24M rise pulse (U103: the 96 MHz VCO / 4)
  output logic                 hr_hsync,      // U262 F1, positive
  output logic                 hr_hsync_n,    // U262 F3
  output logic                 hr_vsync_n,    // U262 F4
  output logic [3:0]           hr_rgbi,       // 74S299 QH': I, R, G, B (one colour pixel per 24M)
  output logic [3:0]           hr_vout,       // U104: four mono pixels per 24M, bit 3 first
  output logic                 hr_de,         // U262 F0
  output logic                 hr_de_dly,     // U262 F6
  output logic                 hr_vblank_n,   // U262 F5
  output logic                 hr_mono_en,    // U312 MONO EN (404H B2)
  output logic                 hr_mono_i,     // U312 intensity (404H B3)
  // LC card 8563 video pins and display window (clk_vdc domain)
  output logic [3:0]           lc_rgbi,       // R, G, B, I
  output logic                 lc_hsync,
  output logic                 lc_vsync,
  output logic                 lc_pixel_ce,
  output logic                 lc_active_h,
  output logic                 lc_active_v,

  // CN5 Centronics printer port, connector levels
  output logic [7:0]           cent_data,
  output logic                 cent_strobe_n,
  input  logic                 cent_ack_n,    // High when no printer (pull-up)
  input  logic                 cent_busy,     // High when no printer (pull-up)

  // CN3 internal speaker: coil current on
  output logic                 spk_on,

  // LANCE card serial pins (Am7990) and its station address (non-stock)
  output logic                 lan_on,        // the card is fitted and out of reset
  output logic                 lan_tclk_rise,
  output logic                 lan_tclk_fall,
  output logic                 lan_tx,
  output logic                 lan_tena,
  input  logic                 lan_rclk_rise,
  input  logic                 lan_rx,
  input  logic                 lan_rena,
  input  logic                 lan_clsn,
  input  logic                 lan_mac_ok,
  input  logic [47:0]          lan_mac,
  input  logic                 lan_rom_ok,    // the card's boot ROM is loaded
  input  logic                 lan_rom_wr,
  input  logic [13:0]          lan_rom_addr,
  input  logic [7:0]           lan_rom_data,
  input  logic                 lan_cfg_ok,
  input  logic                 lan_cfg_wr,
  input  logic [4:0]           lan_cfg_addr,
  input  logic [15:0]          lan_cfg_data,

  output logic                 led_fdd,
  output logic                 led_hdd,
  output logic [1:0]           disk_late    // drive stream late: [0] floppy, [1] hard disk
`ifdef C900_DISK_DEBUG
  , output logic [55:0]        dbg
`endif
);
  logic lr_present, hr_present, lc_present;
  assign lr_present = card_fitted & ~display_hr & ~display_lc;
  assign lc_present = card_fitted & display_lc;
  assign hr_present = card_fitted &  display_hr;

  // ROM loader decode
  logic rom_fdc, rom_hdc, rom_kbd, rom_chr;
  assign rom_fdc = rom_wr && (rom_addr[13] == 1'b0);
  assign rom_hdc = rom_wr && (rom_addr[13:11] == 3'b100);
  assign rom_kbd = rom_wr && (rom_addr[13:11] == 3'b101);
  assign rom_chr = rom_wr && (rom_addr[13:12] == 2'b11);

  // ---- backplane wires ---------------------------------------------------------
  logic [15:0] ad_wire, ad_q;
  logic [15:0] mb_ad_out, mb_ad_oe, lr_ad_out, lr_ad_oe, hr_ad_out, hr_ad_oe;
  logic [15:0] ln_ad_out, ln_ad_oe, ep_ad_out, ep_ad_oe, lc_ad_out, lc_ad_oe;
  logic        as_n, ds_n, mreq_n, r_w, b_w, intack_n;
  // N/S reaches only the MMU on the board and the unfitted CN13; no card here reads it.
  /* verilator lint_off UNUSEDSIGNAL */
  logic        n_s;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [3:0]  st;
  logic [23:0] pa;
  logic        io3_n, io4_n, sup_n;
  logic        board_reset_n, zclk_rise, zclk_fall;
  assign mreset_n = board_reset_n;
  logic        wait_n, wait_nx, vi_ext_n, busreq_ext_n, busack_n, mb_bao_n, mb_ieo, mi_n, mo_n, stop_n;
  logic        lr_wait_n, lr_vi_n, lr_ieo, hr_wait_n, hr_ieo, lc_wait_n, lc_nvi_n, lc_ieo;
  logic        lr_wait_nx, hr_wait_nx, lc_wait_nx;
  logic        ln_bao_n, ln_busreq_n, ln_bus_oe, ln_vi_n, ln_ieo, ln_wait_n, busreq_line_n;
  logic        ln_m_as_n, ln_m_ds_n, ln_m_r_w, ln_m_b_w, ln_m_mreq_n;
  logic [3:0]  ln_m_st;
  logic [7:0]  ln_m_a_hi;
  logic        ln_drive_q, ln_mreq_q, ln_as_q, ln_ds_q, ln_r_w_q, ln_b_w_q;
  logic [3:0]  ln_st_q;
  logic [7:0]  ln_a_hi_q;
  logic        ep_stop_n, ep_wait_n, ep_int_n, ep_iea;
  logic        apu_clk_rise, apu_clk_fall, apu_as_n, apu_ds_n, apu_r_w, apu_b_w, apu_n_s, apu_busack_n;
  logic [3:0]  apu_st;
  logic [6:0]  apu_sn;

  // Low wins on every line any card drives; undriven lines read High.  While
  // the CPU drives AD through its transceivers its word is the bus.
  logic        mb_ad_own, dram_ad_oe;
  logic [15:0] dram_ad, ad_rest;
  assign ad_rest = mb_ad_own ? mb_ad_out :
                   (mb_ad_oe & mb_ad_out | ~mb_ad_oe) &
                   (lr_ad_oe & lr_ad_out | ~lr_ad_oe) &
                   (hr_ad_oe & hr_ad_out | ~hr_ad_oe) &
                   (lc_ad_oe & lc_ad_out | ~lc_ad_oe) &
                   (ln_ad_oe & ln_ad_out | ~ln_ad_oe) &
                   (ep_ad_oe & ep_ad_out | ~ep_ad_oe);
  // The DRAM's word joins last (one AND level after its half-cycle path).
  assign ad_wire = ad_rest & (dram_ad_oe ? dram_ad : 16'hFFFF);

  // The read-data capture register (the CPU's ad_in must come from a flop).
  always_ff @(posedge clk) begin
    if (!rst_n) ad_q <= 16'hFFFF;
    else        ad_q <= ad_wire;
  end

  assign intack_n     = ~(st == ST_VI_ACK);
  assign wait_n       = lr_wait_n & hr_wait_n & lc_wait_n & ep_wait_n & ln_wait_n;
  assign wait_nx      = lr_wait_nx & hr_wait_nx & lc_wait_nx & ep_wait_n & ln_wait_n;
  assign vi_ext_n     = lr_vi_n & ln_vi_n & ep_int_n;
  assign busreq_ext_n = ln_busreq_n;
  assign mi_n         = 1'b1;
  assign stop_n       = ep_stop_n;

  logic [7:0] kbd_pa;
  logic [6:0] kbd_data;
  logic       kbd_dav, kbd_clr, kbd_updown, kbclk, kbdat, kbd_clk204, kbd_bad1;
  logic       kbclk_low, kbdat_low, kbclk_line, kbdat_line;
  logic hdc_rise, hdc_fall, kbd_rise, rtc_rise;

  // ---- 8716 controller bus (OMAD) ---------------------------------------------------
  logic [7:0] bd_wire, bd_q, mb_bd_out, fdc_bd_out, hdc_bd_out;
  logic       mb_bd_oe, fdc_bd_oe, hdc_bd_oe;
  logic       fdc_pcss_n, fdc_pcsd_n, fdc_strobe_oe, hdc_pcss_n, hdc_pcsd_n;
  logic       pcss_n_wire, pcsd_n_wire, ireq_n, est_n, inten;

  assign bd_wire = (mb_bd_oe  ? mb_bd_out  : 8'hFF) &
                   (fdc_bd_oe ? fdc_bd_out : 8'hFF) &
                   (hdc_bd_oe ? hdc_bd_out : 8'hFF);
  always_ff @(posedge clk) begin
    if (!rst_n) bd_q <= 8'hFF;
    else        bd_q <= bd_wire;
  end

  assign pcss_n_wire = (fdc_strobe_oe ? fdc_pcss_n : 1'b1) & hdc_pcss_n;
  assign pcsd_n_wire = (fdc_strobe_oe ? fdc_pcsd_n : 1'b1) & hdc_pcsd_n;

  // The strobes are registered with the bus word, so the 8716 samples a
  // coherent controller bus (a strobe and the byte the same driver puts on
  // the bus with it arrive in the same clock).
  logic pcss_n_q, pcsd_n_q;
  always_ff @(posedge clk) begin
    if (!rst_n) {pcss_n_q, pcsd_n_q} <= 2'b11;
    else        {pcss_n_q, pcsd_n_q} <= {pcss_n_wire, pcsd_n_wire};
  end

  // ---- CN4 IEEE-488 bus: wired-AND, released lines High (U67/U68
  // terminations).  Nothing is attached yet.  Registered, so the
  // transceivers' direction logic sees no loop through the bus.
  logic [7:0] cn4_dio, cn4_ctl, cn4_dio_pull, cn4_ctl_pull;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cn4_dio <= 8'hFF;
      cn4_ctl <= 8'hFF;
    end else begin
      cn4_dio <= ~cn4_dio_pull;
      cn4_ctl <= ~cn4_ctl_pull;
    end
  end

  // ---- CPU board -----------------------------------------------------------------------
  c900_mainboard u_mb (
    .clk(clk), .rst_n(rst_n), .s1(s1), .ram_512k(ram_512k), .ram_card(ram_card), .cpu_speed(cpu_speed),
    .zclk_rise(zclk_rise), .zclk_fall(zclk_fall),
    .ad_bus(ad_q), .ad_live(ad_wire), .ad_out(mb_ad_out), .ad_oe(mb_ad_oe), .ad_own(mb_ad_own),
    .dram_ad(dram_ad), .dram_ad_oe(dram_ad_oe),
    .as_n(as_n), .ds_n(ds_n), .mreq_n(mreq_n), .r_w(r_w), .b_w(b_w), .n_s(n_s), .st(st), .pa(pa),
    .io3_n(io3_n), .io4_n(io4_n), .sup_n(sup_n),
    .board_reset_n(board_reset_n), .wait_n(wait_n), .wait_nx(wait_nx), .vi_ext_n(vi_ext_n), .nvi_ext_n(lc_nvi_n),
    .busreq_ext_n(busreq_ext_n), .busreq_line_n(busreq_line_n),
    .ext_drive(ln_drive_q), .ext_hold(!ln_mreq_q), .ext_as_n(ln_as_q), .ext_ds_n(ln_ds_q),
    .ext_mreq_n(ln_mreq_q), .ext_r_w(ln_r_w_q), .ext_b_w(ln_b_w_q), .ext_st(ln_st_q), .ext_a_hi(ln_a_hi_q),
    .busack_n(busack_n), .bao_n(mb_bao_n), .ieo(mb_ieo),
    .mi_n(mi_n), .mo_n(mo_n), .stop_n(stop_n), .iea(ep_iea),
    .apu_clk_rise(apu_clk_rise), .apu_clk_fall(apu_clk_fall), .apu_as_n(apu_as_n), .apu_ds_n(apu_ds_n),
    .apu_r_w(apu_r_w), .apu_b_w(apu_b_w), .apu_n_s(apu_n_s), .apu_st(apu_st), .apu_sn(apu_sn),
    .apu_busack_n(apu_busack_n),
    .bd_in(bd_q), .bd_out(mb_bd_out), .bd_oe(mb_bd_oe),
    .pcss(~pcss_n_q), .pcsd(~pcsd_n_q), .ireq_n(ireq_n), .est_n(est_n),
    .kbd_pa(kbd_pa), .kbd_updown(kbd_updown), .kbd_clr(kbd_clr),
    .kbd_clk204(kbd_clk204), .kbd_bad1(kbd_bad1),
    .rtc_xt_rise(rtc_rise), .rtc_hps(rtc_hps),
    .scc_rxd(ser_rxd[1:0]), .scc_txd(ser_txd[1:0]), .scc_cts_n(ser_cts_n[1:0]), .scc_dcd_n(ser_dcd_n[1:0]),
    .scc_rts_n(ser_rts_n[1:0]), .scc_dtr_n(ser_dtr_n[1:0]),
    .cn5_data(cent_data), .cn5_strobe_n(cent_strobe_n), .cn5_ack_n(cent_ack_n), .cn5_busy(cent_busy),
    .cn4_dio(cn4_dio), .cn4_ctl(cn4_ctl), .cn4_dio_pull(cn4_dio_pull), .cn4_ctl_pull(cn4_ctl_pull),
    .spk_on(spk_on),
    .mem_addr(mem_addr), .mem_rd(mem_rd), .mem_wr(mem_wr), .mem_be(mem_be),
    .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_rvalid(mem_rvalid), .mem_ack(mem_ack),
    .mem_refresh_ok(mem_refresh_ok)
`ifdef C900_DISK_DEBUG
    , .dbg(dbg)
`endif
  );

  // Off-board crystals: HDC card Y101 10 MHz, keyboard 2 MHz, RTC
  // 32.768 kHz, phase accumulators on the master clock.
  fantdiv u_fantdiv (.clk(clk), .hdc_rise(hdc_rise), .hdc_fall(hdc_fall), .kbd_rise(kbd_rise),
                     .rtc_rise(rtc_rise));

  // ---- keyboard + 311075 daughterboard ----------------------------------------------

  c900_keyboard u_kbd (
    .clk(clk), .rst_n(rst_n), .xtli(kbd_rise), .rom_we(rom_kbd), .rom_addr(rom_addr[10:0]), .rom_data(rom_data),
    .keys(keys), .mods(kbd_mods), .kbclk(kbclk), .kbdat(kbdat),
    .kbclk_line(kbclk_line), .kbdat_line(kbdat_line), .pb(kbd_pb), .pc(kbd_pc)
  );
  assign kbd_pa7 = kbclk;

  // Keyboard cable: open-collector lines, pulled up.
  assign kbclk_line = kbclk & ~kbclk_low;
  assign kbdat_line = kbdat & ~kbdat_low;

  kbdshifter u_311075 (
    .clk(clk), .rst_n(board_reset_n), .kbclk(kbclk_line), .kbdat(kbdat_line), .kbdclr(kbd_clr),
    .clk204(kbd_clk204), .bad1(kbd_bad1),
    .data(kbd_data), .dav(kbd_dav), .updown(kbd_updown), .kbclk_low(kbclk_low), .kbdat_low(kbdat_low)
  );
  assign kbd_pa = {kbd_dav, kbd_data};

  // ---- floppy controller (CPU board sheets 13-16) -----------------------------------
  logic [1:0] fdc_led;

  c900_fdc u_fdc (
    .clk(clk), .rst_n(rst_n), .board_reset_n(board_reset_n), .clkin(zclk_rise),
    .rom_we(rom_fdc), .rom_addr(rom_addr[12:0]), .rom_data(rom_data),
    .bd_in(bd_q), .bd_out(fdc_bd_out), .bd_oe(fdc_bd_oe),
    .pcss_n(fdc_pcss_n), .pcsd_n(fdc_pcsd_n), .strobe_oe(fdc_strobe_oe),
    .ireq_n(ireq_n), .inten(inten), .led(fdc_led),
    .img_mounted(img_mounted[1:0]), .img_readonly(img_readonly), .img_size(img_size),
    .sd_lba(sd_lba[1:0]), .sd_rd(sd_rd[1:0]), .sd_wr(sd_wr[1:0]), .sd_scr(sd_scr[1:0]),
    .sd_ack(sd_ack[1:0]), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
    .sd_buff_din(sd_buff_din[1:0]), .sd_buff_wr(sd_buff_wr), .late(disk_late[0])
  );
  assign led_fdd = |fdc_led;

  // ---- hard disk card on CN9 ---------------------------------------------------------
  c900_hdc_card u_hdc (
    .clk(clk), .rst_n(rst_n), .host_clk_rise(zclk_rise), .host_clk_fall(zclk_fall), .y101_rise(hdc_rise), .y101_fall(hdc_fall),
    .rom_we(rom_hdc), .rom_addr(rom_addr[10:0]), .rom_data(rom_data),
    .reset_n(board_reset_n),
    .bd_in(bd_q), .bd_out(hdc_bd_out), .bd_oe(hdc_bd_oe),
    .pcss_n(hdc_pcss_n), .pcsd_n(hdc_pcsd_n), .ireq_n(ireq_n), .est_n(est_n),
    .inten(inten), .led(led_hdd),
    .img_mounted(img_mounted[3:2]), .img_readonly(img_readonly), .img_size(img_size),
    .sd_lba(sd_lba[3:2]), .sd_rd(sd_rd[3:2]), .sd_wr(sd_wr[3:2]), .sd_fmt(sd_scr[3:2]), .sd_ack(sd_ack[3:2]),
    .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din[3:2]),
    .sd_buff_wr(sd_buff_wr), .drv_sel(hd_sel), .drv_bpc(hd_bpc), .late(disk_late[1])
  );

  // ---- display cards: the one not in the slot is held in reset, bus outputs masked ----
  logic [15:0] lr_ad_out_c, lr_ad_oe_c, hr_ad_out_c, hr_ad_oe_c;
  logic        lr_wait_c, lr_vi_c, lr_ieo_c, hr_wait_c, lr_wait_xc, hr_wait_xc;

  logic [3:0] lr_txd, lr_rts_n, lr_dtr_n;
`ifndef C900_NO_LR
  c900_lr_card u_lr (
    .clk(clk), .rst_n(rst_n & lr_present), .mreset_n(board_reset_n), .clk_vid(clk_vid),
    .rom_we(rom_chr), .rom_addr(rom_addr[11:0]), .rom_data(rom_data),
    .clk_pin_rise(zclk_fall), .clk_pin_fall(zclk_rise), .ad_bus(ad_q), .pa(pa), .as_n(as_n), .ds_n(ds_n), .mreq_n(mreq_n), .r_w(r_w),
    .b_w(b_w), .io3_n(io3_n), .io4_n(io4_n), .sup_n(sup_n),
    .intack_n(intack_n), .iei(mb_ieo),
    .ad_out(lr_ad_out_c), .ad_oe(lr_ad_oe_c), .wait_n(lr_wait_c), .wait_nx(lr_wait_xc), .vi_n(lr_vi_c), .ieo(lr_ieo_c),
    .scc_rxd(ser_rxd[5:2]), .scc_cts_n(ser_cts_n[5:2]), .scc_dcd_n(ser_dcd_n[5:2]),
    .scc_dsr_n(ser_dsr_n[5:2]), .scc_txd(lr_txd), .scc_rts_n(lr_rts_n), .scc_dtr_n(lr_dtr_n),
    .ce_pix(ce_pix), .hsync(hsync), .vsync(vsync), .de(de), .hblank(hblank), .vblank(vblank),
    .vid(lr_vid), .intens(lr_intens)
  );
`else
  assign lr_ad_out_c = 16'hFFFF;
  assign lr_ad_oe_c  = 16'h0000;
  assign lr_wait_c   = 1'b1;
  assign lr_wait_xc  = 1'b1;
  assign lr_vi_c     = 1'b1;
  assign lr_ieo_c    = mb_ieo;
  assign lr_txd      = 4'hF;
  assign lr_rts_n    = 4'hF;
  assign lr_dtr_n    = 4'hF;
  assign {ce_pix, hsync, vsync, de, lr_vid, lr_intens} = 6'b0;
  assign {hblank, vblank} = 2'b11;
  logic unused_lr;
  assign unused_lr = &{1'b0, rom_chr, io3_n, sup_n, clk_vid, ser_rxd[5:2], ser_cts_n[5:2], ser_dcd_n[5:2],
                       ser_dsr_n[5:2], as_n, ds_n, r_w, b_w, intack_n, io4_n, mreq_n, pa};
`endif
  assign ser_txd[5:2]   = lr_present ? lr_txd   : 4'hF;
  assign ser_rts_n[5:2] = lr_present ? lr_rts_n : 4'hF;
  assign ser_dtr_n[5:2] = lr_present ? lr_dtr_n : 4'hF;
  logic unused_dsr;
  assign unused_dsr = ^ser_dsr_n[1:0];

  // 24M = U101 96 MHz VCO / 4.  INFERRED exactly 96 MHz (trimmed VCO,
  // measured near 95.7): a rise every second master clock.
  logic ck24_q = 1'b0;
  always_ff @(posedge clk) ck24_q <= ~ck24_q;
  assign hr_ck24 = ck24_q;

  // ZCLK level (U755 MCLK) rebuilt from its edge pulses, registered like
  // the bus lines the card sees.
  logic zclk_q = 1'b0;
  logic zclk_lvl;
  assign zclk_lvl = zclk_rise | (zclk_q & ~zclk_fall);
  always_ff @(posedge clk) zclk_q <= zclk_lvl;

  // JP3, high = open: 1024x800 both open, 1024x1024 4PC linked,
  // colour M/C and 4PC linked.
  logic jp3_mc, jp3_pc4;
  assign jp3_mc  = ~hr_mode[1];
  assign jp3_pc4 = (hr_mode == 2'd0);

  logic        hr_drive;
  logic [13:0] hr_m_wrow, hr_m_rrow;
  logic [7:0]  hr_m_we;
  logic [63:0] hr_m_wd, hr_m_q;
`ifndef C900_NO_HR
  hr_card u_hr (
    .clk(clk), .ck24_rise(ck24_q),
    .io4_n(io4_n), .bmreq_n(mreq_n), .a(pa[23:17]), .la(pa[16:0]),
    .ad_in(ad_q), .ad_out(hr_ad_out_c), .ad_drive(hr_drive),
    .brw(r_w), .lbw(b_w), .bds_n(ds_n), .zclk(zclk_q), .reset_n(board_reset_n & hr_present),
    .wait_n(hr_wait_c), .wait_nx(hr_wait_xc),
    .b1_n(m_b_n[0]), .b2_n(m_b_n[1]), .b3_n(m_b_n[2]),
    .xa(m_h), .xb(m_hq), .ya(m_v), .yb(m_vq),
    .mc(jp3_mc), .pc4(jp3_pc4),
    .hsync(hr_hsync), .hsync_n(hr_hsync_n), .vsync_n(hr_vsync_n),
    .de(hr_de), .de_dly(hr_de_dly), .vblank_n(hr_vblank_n),
    .rgbi(hr_rgbi), .u104(hr_vout), .mono_en(hr_mono_en), .mono_i(hr_mono_i),
    .m_wrow(hr_m_wrow), .m_we(hr_m_we), .m_wd(hr_m_wd), .m_rrow(hr_m_rrow), .m_q(hr_m_q)
  );
`else
  assign hr_ad_out_c = 16'hFFFF;
  assign hr_drive    = 1'b0;
  assign hr_wait_c   = 1'b1;
  assign hr_wait_xc  = 1'b1;
  assign {hr_hsync, hr_hsync_n, hr_vsync_n, hr_de, hr_de_dly, hr_vblank_n, hr_mono_en, hr_mono_i} = 8'b0;
  assign hr_rgbi  = 4'h0;
  assign hr_vout  = 4'h0;
  assign hr_m_wrow = 14'd0;
  assign hr_m_we   = 8'h00;
  assign hr_m_wd   = 64'd0;
  assign hr_m_rrow = 14'd0;
  logic unused_hr;
  assign unused_hr = &{1'b0, jp3_mc, jp3_pc4, m_h, m_hq, m_v, m_vq, m_b_n, hr_m_q};
`endif
  assign hr_ad_oe_c = {16{hr_drive}};

  assign lr_ad_out = lr_ad_out_c;
  assign lr_ad_oe  = lr_present ? lr_ad_oe_c : 16'h0000;
  assign lr_wait_n = lr_wait_c | ~lr_present;
  assign lr_wait_nx = lr_wait_xc | ~lr_present;
  assign lr_vi_n   = lr_vi_c   | ~lr_present;
  assign lr_ieo    = lr_present ? lr_ieo_c : mb_ieo;
  // No interrupt source on the HR card: IEI goes straight to IEO.
  assign hr_ad_out = hr_ad_out_c;
  assign hr_ad_oe  = hr_present ? hr_ad_oe_c : 16'h0000;
  assign hr_wait_n = hr_wait_c | ~hr_present;
  assign hr_wait_nx = hr_wait_xc | ~hr_present;
  assign hr_ieo    = mb_ieo;

  logic [15:0] lc_ad_out_c, lc_ad_oe_c;
  logic        lc_wait_c, lc_wait_xc, lc_nvi_c;
  logic        lc_ram_rd, lc_ram_we;
  logic [15:0] lc_ram_addr;
  logic [7:0]  lc_ram_di, lc_ram_do;
`ifndef C900_NO_LC
  c900_lc_card u_lc (
    .clk(clk), .rst_n(rst_n & lc_present), .mreset_n(board_reset_n), .clk_vdc(clk_vdc),
    .ad_bus(ad_q), .as_n(as_n), .ds_n(ds_n), .r_w(r_w), .b_w(b_w), .st(st),
    .ad_out(lc_ad_out_c), .ad_oe(lc_ad_oe_c), .wait_n(lc_wait_c), .wait_nx(lc_wait_xc), .nvi_n(lc_nvi_c),
    .rgbi(lc_rgbi), .hsync(lc_hsync), .vsync(lc_vsync), .pixel_ce(lc_pixel_ce),
    .active_h(lc_active_h), .active_v(lc_active_v),
    .ram_rd(lc_ram_rd), .ram_we(lc_ram_we), .ram_addr(lc_ram_addr), .ram_di(lc_ram_di), .ram_do(lc_ram_do)
  );
`else
  assign lc_ad_out_c = 16'hFFFF;
  assign lc_ad_oe_c  = 16'h0000;
  assign lc_wait_c   = 1'b1;
  assign lc_wait_xc  = 1'b1;
  assign lc_nvi_c    = 1'b1;
  assign lc_rgbi     = 4'h0;
  assign {lc_hsync, lc_vsync, lc_pixel_ce, lc_active_h, lc_active_v} = 5'b0;
  assign lc_ram_rd   = 1'b0;
  assign lc_ram_we   = 1'b0;
  assign lc_ram_addr = 16'd0;
  assign lc_ram_di   = 8'h00;
  logic unused_lc;
  assign unused_lc = &{1'b0, clk_vdc, lc_ram_do};
`endif

  // One display RAM: the HR bitmap or the LC card's 64 KB, as the slot holds.
`ifdef C900_NO_HR
`ifdef C900_NO_LC
`define C900_NO_DISPRAM
`endif
`endif
`ifdef C900_NO_DISPRAM
  assign hr_m_q    = 64'd0;
  assign lc_ram_do = 8'h00;
  logic unused_dispram;
  assign unused_dispram = &{1'b0, hr_m_wrow, hr_m_we, hr_m_wd, hr_m_rrow, lc_ram_rd, lc_ram_we, lc_ram_addr,
                            lc_ram_di};
`else
  c900_dispram u_dispram (
    .clk(clk), .lc_sel(lc_present),
    .hr_wrow(hr_m_wrow), .hr_we(hr_m_we), .hr_wd(hr_m_wd), .hr_rrow(hr_m_rrow), .hr_q(hr_m_q),
    .lc_rd(lc_ram_rd), .lc_we(lc_ram_we), .lc_addr(lc_ram_addr), .lc_di(lc_ram_di), .lc_do(lc_ram_do)
  );
`endif
  assign lc_ad_out = lc_ad_out_c;
  assign lc_ad_oe  = lc_present ? lc_ad_oe_c : 16'h0000;
  assign lc_wait_n = lc_wait_c | ~lc_present;
  assign lc_wait_nx = lc_wait_xc | ~lc_present;
  assign lc_nvi_n  = lc_nvi_c  | ~lc_present;
  // The LC card's INTR is non-vectored: IEI goes straight to IEO.
  assign lc_ieo    = mb_ieo;

  // ---- non-stock expansion ---------------------------------------------------------------
  logic [15:0] ln_ad_out_c, ln_ad_oe_c, ep_ad_out_c, ep_ad_oe_c;
  logic        ln_bus_oe_c, ln_wait_pd;

  // The card is last in the IEI/IEO chain.
`ifndef C900_NO_LANCE
  am7990_lance_card u_lance (
    .clk(clk), .rst_n(board_reset_n & lance_en), .enable(lance_en),
    .ad_bus(ad_q), .as_n(as_n), .ds_n(ds_n), .r_w(r_w), .b_w(b_w), .st(st),
    .intack_n(intack_n), .iei(hr_present ? hr_ieo : lc_present ? lc_ieo : lr_ieo), .bai_n(mb_bao_n), .bao_n(ln_bao_n),
    .busreq_n(ln_busreq_n), .ad_out(ln_ad_out_c), .ad_oe(ln_ad_oe_c), .bus_oe(ln_bus_oe_c),
    .vi_n(ln_vi_n), .ieo(ln_ieo),
    .wait_n(wait_n), .busreq_in_n(busreq_line_n), .wait_pd(ln_wait_pd), .mac_ok(lan_mac_ok), .mac(lan_mac),
    .rom_ok(lan_rom_ok), .rom_wr(lan_rom_wr), .rom_addr(lan_rom_addr), .rom_data(lan_rom_data),
    .cfg_ok(lan_cfg_ok), .cfg_wr(lan_cfg_wr), .cfg_addr(lan_cfg_addr), .cfg_data(lan_cfg_data),
    .as_n_o(ln_m_as_n), .ds_n_o(ln_m_ds_n), .r_w_o(ln_m_r_w), .b_w_o(ln_m_b_w), .mreq_n_o(ln_m_mreq_n),
    .st_o(ln_m_st), .a_hi_o(ln_m_a_hi),
    .tclk_rise(lan_tclk_rise), .tclk_fall(lan_tclk_fall), .tx(lan_tx), .tena(lan_tena),
    .rclk_rise(lan_rclk_rise), .rx(lan_rx), .rena(lan_rena), .clsn(lan_clsn)
  );
  assign lan_on = lance_en & board_reset_n;
`else
  assign ln_bao_n    = mb_bao_n;
  assign ln_busreq_n = 1'b1;
  assign ln_ad_out_c = 16'hFFFF;
  assign ln_ad_oe_c  = 16'h0000;
  assign ln_bus_oe_c = 1'b0;
  assign ln_wait_pd  = 1'b0;
  assign ln_vi_n     = 1'b1;
  assign ln_ieo      = hr_present ? hr_ieo : lc_present ? lc_ieo : lr_ieo;
  assign {ln_m_as_n, ln_m_ds_n, ln_m_r_w, ln_m_b_w, ln_m_mreq_n} = 5'b11111;
  assign ln_m_st     = 4'hF;
  assign ln_m_a_hi   = 8'hFF;
  assign {lan_on, lan_tclk_rise, lan_tclk_fall, lan_tx, lan_tena} = 5'b0;
  logic unused_lan;
  assign unused_lan = &{1'b0, lan_rclk_rise, lan_rx, lan_rena, lan_clsn, lan_mac_ok, lan_mac, busreq_line_n,
                        lan_rom_ok, lan_rom_wr, lan_rom_addr, lan_rom_data, lan_cfg_ok, lan_cfg_wr, lan_cfg_addr, lan_cfg_data};
`endif
  assign ln_ad_out = ln_ad_out_c;
  assign ln_ad_oe  = lance_en ? ln_ad_oe_c : 16'h0000;
  assign ln_bus_oe = lance_en & ln_bus_oe_c;
  assign ln_wait_n = ~(lance_en & ln_wait_pd);

  // The card's master strobes reach the board registered, as its AD does
  // (ad_q): the board takes the address from AD while /AS is Low.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      {ln_drive_q, ln_mreq_q, ln_as_q, ln_ds_q, ln_r_w_q, ln_b_w_q} <= 6'b011111;
      ln_st_q   <= 4'hF;
      ln_a_hi_q <= 8'hFF;
    end else begin
      {ln_drive_q, ln_mreq_q, ln_as_q, ln_ds_q, ln_r_w_q, ln_b_w_q} <=
        {ln_bus_oe, ln_m_mreq_n | ~lance_en, ln_m_as_n, ln_m_ds_n, ln_m_r_w, ln_m_b_w};
      ln_st_q   <= ln_m_st;
      ln_a_hi_q <= ln_m_a_hi;
    end
  end

  // APU CLK.D: 24 MHz at 6 MHz; a turbo board runs it at the master clock.
  logic apu_ck24_q = 1'b0;
  logic apu_clkd_rise;
  always_ff @(posedge clk) apu_ck24_q <= ~apu_ck24_q;
  assign apu_clkd_rise = (cpu_speed == 2'd0) ? apu_ck24_q : 1'b1;

  // CN13: the chain-top IEI (High) enters the APU; IEA feeds CIO U70.
`ifndef C900_NO_APU
  z8070_epu u_epu (
    .clk(clk), .mreset_n(board_reset_n), .enable(fpu_en),
    .clki_rise(apu_clk_rise), .clki_fall(apu_clk_fall), .clkd_rise(apu_clkd_rise),
    .ad_bus(ad_q), .as_n(apu_as_n), .ds_n(apu_ds_n), .r_w(apu_r_w), .b_w(apu_b_w), .n_s(apu_n_s),
    .sn(apu_sn), .st(apu_st), .busack_n(apu_busack_n), .iei(1'b1),
    .ad_out(ep_ad_out_c), .ad_oe(ep_ad_oe_c), .stop_n(ep_stop_n), .wait_n(ep_wait_n), .int_n(ep_int_n),
    .iea(ep_iea)
  );
`else
  assign ep_ad_out_c = 16'hFFFF;
  assign ep_ad_oe_c  = 16'h0000;
  assign ep_stop_n   = 1'b1;
  assign ep_wait_n   = 1'b1;
  assign ep_int_n    = 1'b1;
  assign ep_iea      = 1'b1;
  logic unused_apu;
  assign unused_apu = &{1'b0, apu_clk_rise, apu_clk_fall, apu_clkd_rise, apu_as_n, apu_ds_n, apu_r_w, apu_b_w,
                        apu_n_s, apu_busack_n, apu_st, apu_sn};
`endif
  assign ep_ad_out = ep_ad_out_c;
  assign ep_ad_oe  = fpu_en ? ep_ad_oe_c : 16'h0000;

  logic unused_ok;
  assign unused_ok = &{1'b0, busack_n, ln_bao_n, ln_ieo, mo_n};
endmodule
`default_nettype wire
