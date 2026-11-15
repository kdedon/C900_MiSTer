// The floppy board (c900_fdc: 6508, firmware, 8723, drives) with the
// 8716 and U80-U83 of the motherboard, disk_stream and a zero-wait
// memory, and the hard disk card sharing the 8716 (OMAD, the strobes,
// IREQ, INTEN) unless hdc_off.  The C++ driver plays the Z8001 (the command block, the WDIO
// write that raises IREQ) and Main_MiSTer's side of the sd_* slots.
// One clk = 48 MHz; _CLK (6 MHz) rises every 8 clks.
`default_nettype none
module tb_fdboard (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              board_reset_n,
  input  logic              hdc_off,      // card held in reset, INTEN High
  input  logic [3:0]        grant_dly,    // _CLK samples from /BUSREQ to /BAI, minus 1
  // firmware loader
  input  logic              rom_we,
  input  logic              hrom_we,
  input  logic [12:0]       rom_addr,
  input  logic [7:0]        rom_data,
  // the Z8001's I/O write to the 8716 (WDIO): io6 plus /DS with AD
  input  logic              io6,
  input  logic              io_ds_n,
  input  logic [15:0]       io_ad,
  // host access to memory (bytes)
  input  logic              m_we,
  input  logic [20:0]       m_addr,
  input  logic [7:0]        m_wdata,
  output logic [7:0]        m_rdata,
  // observation
  output logic              ireq_n,
  output logic              vi_n,
  output logic              late,
  output logic [1:0]        mtron,
  output logic              sync_det,
  output logic [15:0]       cpu_pc,
  output logic              wb_busy,
  output logic [6:0]        trk0_cyl,
  output logic              inten_o,
  // hps_io side
  input  logic [3:0]        img_mounted,
  input  logic              img_readonly,
  input  logic [63:0]       img_size,
  output logic [3:0][31:0]  h_lba,
  output logic [3:0][5:0]   h_blk_cnt,
  output logic [3:0]        h_rd,
  output logic [3:0]        h_wr,
  input  logic [3:0]        h_ack,
  input  logic [13:0]       h_buff_addr,
  input  logic [7:0]        h_buff_dout,
  output logic [7:0]        h_buff_din,
  input  logic              h_buff_wr
);
  // ---- _CLK: rise every 8 clks, fall 4 later --------------------------------------------
  logic [2:0] div;
  logic       zr, zf;
  always_ff @(posedge clk) begin
    if (!rst_n) div <= 3'd0;
    else        div <= div + 3'd1;
  end
  assign zr = (div == 3'd7);
  assign zf = (div == 3'd3);

  // ---- disk_stream ------------------------------------------------------------------------
  logic [3:0]        d_mounted, d_rd, d_wr, d_ack, d_scr, resident;
  logic              d_readonly, d_buff_wr, busy, fmt_full;
  logic [63:0]       d_size;
  logic [3:0][31:0]  d_lba;
  logic [8:0]        d_buff_addr;
  logic [7:0]        d_buff_dout;
  logic [3:0][7:0]   d_buff_din;
  logic [1:0][15:0]  ld_min, ld_max;
  logic [1:0][31:0]  f_lba;
  logic [1:0][7:0]   f_din;
  logic [1:0]        f_rd, f_wr, f_scr;

  logic [1:0][11:0] hd_bpc;
  logic [1:0][31:0] hd_lba;
  logic [1:0][7:0]  hd_din;
  logic [1:0]       hd_rd, hd_wr, hd_fmt, hd_sel;

  disk_stream u_ds (
    .clk(clk), .rst_n(rst_n), .core_rst_n(rst_n), .bpc(hd_bpc),
    .img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
    .h_lba(h_lba), .h_blk_cnt(h_blk_cnt), .h_rd(h_rd), .h_wr(h_wr), .h_ack(h_ack),
    .h_buff_addr(h_buff_addr), .h_buff_dout(h_buff_dout), .h_buff_din(h_buff_din), .h_buff_wr(h_buff_wr),
    .d_mounted(d_mounted), .d_readonly(d_readonly), .d_size(d_size), .d_lba(d_lba), .d_scr(d_scr),
    .d_rd(d_rd), .d_wr(d_wr), .d_ack(d_ack), .d_buff_addr(d_buff_addr), .d_buff_dout(d_buff_dout),
    .d_buff_din(d_buff_din), .d_buff_wr(d_buff_wr), .resident(resident), .busy(busy), .wb_busy(wb_busy),
    .fmt_full(fmt_full), .ld_min(ld_min), .ld_max(ld_max)
  );
  assign d_lba      = {hd_lba, f_lba};
  assign d_scr      = {hd_fmt, f_scr};
  assign d_rd       = {hd_rd, f_rd};
  assign d_wr       = {hd_wr, f_wr};
  assign d_buff_din = {hd_din, f_din};

  // ---- floppy board -----------------------------------------------------------------------
  logic [7:0] bd_wire, bd_q, fdc_bd_out, dma_bd_out;
  logic       fdc_bd_oe, dma_bd_oe, fdc_pcss_n, fdc_pcsd_n, fdc_strobe_oe, pcss_n_q, pcsd_n_q;
  logic [1:0] led;

  c900_fdc u_fdc (
    .clk(clk), .rst_n(rst_n), .board_reset_n(board_reset_n), .clkin(zr),
    .rom_we(rom_we), .rom_addr(rom_addr), .rom_data(rom_data),
    .bd_in(bd_q), .bd_out(fdc_bd_out), .bd_oe(fdc_bd_oe),
    .pcss_n(fdc_pcss_n), .pcsd_n(fdc_pcsd_n), .strobe_oe(fdc_strobe_oe),
    .ireq_n(ireq_n), .inten(inten), .led(led),
    .img_mounted(d_mounted[1:0]), .img_readonly(d_readonly), .img_size(d_size),
    .sd_lba(f_lba), .sd_rd(f_rd), .sd_wr(f_wr), .sd_scr(f_scr),
    .sd_ack(d_ack[1:0]), .sd_buff_addr(d_buff_addr), .sd_buff_dout(d_buff_dout),
    .sd_buff_din(f_din), .sd_buff_wr(d_buff_wr), .late(late)
  );

  // ---- hard disk card ------------------------------------------------------------------------
  logic       hdc_rise, hdc_fall, kbd_rise, rtc_rise, hdc_inten, hdc_led, hdc_late;
  logic [7:0] hdc_bd_out;
  logic       hdc_bd_oe, hdc_pcss_n, hdc_pcsd_n, inten;

  fantdiv u_fantdiv (.clk(clk), .hdc_rise(hdc_rise), .hdc_fall(hdc_fall), .kbd_rise(kbd_rise), .rtc_rise(rtc_rise));

  c900_hdc_card u_hdc (
    .clk(clk), .rst_n(rst_n), .host_clk_rise(zr), .host_clk_fall(zf), .y101_rise(hdc_rise), .y101_fall(hdc_fall),
    .rom_we(hrom_we), .rom_addr(rom_addr[10:0]), .rom_data(rom_data),
    .reset_n(board_reset_n & ~hdc_off),
    .bd_in(bd_q), .bd_out(hdc_bd_out), .bd_oe(hdc_bd_oe),
    .pcss_n(hdc_pcss_n), .pcsd_n(hdc_pcsd_n), .ireq_n(ireq_n), .est_n(est_n),
    .inten(hdc_inten), .led(hdc_led),
    .img_mounted(d_mounted[3:2]), .img_readonly(d_readonly), .img_size(d_size),
    .sd_lba(hd_lba), .sd_rd(hd_rd), .sd_wr(hd_wr), .sd_fmt(hd_fmt), .sd_ack(d_ack[3:2]),
    .sd_buff_addr(d_buff_addr), .sd_buff_dout(d_buff_dout), .sd_buff_din(hd_din),
    .sd_buff_wr(d_buff_wr), .drv_sel(hd_sel), .drv_bpc(hd_bpc), .late(hdc_late)
  );
  assign inten   = hdc_off | hdc_inten;
  assign inten_o = inten;

  // OMAD and the strobes, registered as in c900_core
  assign bd_wire = (dma_bd_oe ? dma_bd_out : 8'hFF) & (fdc_bd_oe ? fdc_bd_out : 8'hFF) &
                   (hdc_bd_oe ? hdc_bd_out : 8'hFF);
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      bd_q <= 8'hFF; {pcss_n_q, pcsd_n_q} <= 2'b11;
    end else begin
      bd_q <= bd_wire;
      {pcss_n_q, pcsd_n_q} <= {(fdc_strobe_oe ? fdc_pcss_n : 1'b1) & hdc_pcss_n,
                               (fdc_strobe_oe ? fdc_pcsd_n : 1'b1) & hdc_pcsd_n};
    end
  end

  // ---- 8716 and U80-U83 -------------------------------------------------------------------
  logic [15:0] ad_in, dma_ad_out;
  logic        dma_ad_oe, dma_mreq_n, dma_mreq_oe, dma_ds_n, dma_ds_oe, busreq_n, bao_n, ieo_n, dmaen_n;
  logic        ld0, ld1_rise, ld1_fall, ld2_rise, ld2_fall, clkadr_rise, clkadr_fall, est_n;
  logic        bai_n;
  logic [22:0] wa;
  logic        dir;
  logic [7:0]  bd_8716_q;

  pdmac u79_pdmac (
    .clk(clk),
    .ad_in(ad_in), .ad_out(dma_ad_out), .ad_oe(dma_ad_oe),
    .wait_n(1'b1), .clk_pin_rise(zr), .clk_pin_fall(zf), .bai_n(bai_n), .iack_n(1'b1), .iei(1'b1),
    .io6(io6), .ds_n_in(dma_ds_oe ? dma_ds_n : io_ds_n),
    .mreq_n(dma_mreq_n), .mreq_oe(dma_mreq_oe), .ds_n(dma_ds_n), .ds_oe(dma_ds_oe),
    .busreq_n(busreq_n), .bao_n(bao_n), .vi_n(vi_n), .ieo_n(ieo_n), .dmaen_n(dmaen_n),
    .bd_in(bd_q), .bd_out(dma_bd_out), .bd_oe(dma_bd_oe), .pcss(~pcss_n_q), .pcsd(~pcsd_n_q),
    .reset_n(board_reset_n), .ireq_n(ireq_n), .ld0(ld0),
    .ld1_rise(ld1_rise), .ld1_fall(ld1_fall), .ld2_rise(ld2_rise), .ld2_fall(ld2_fall),
    .clkadr_rise(clkadr_rise), .clkadr_fall(clkadr_fall), .est_n(est_n)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) bd_8716_q <= 8'hFF;
    else        bd_8716_q <= bd_q;
  end

  dma_addr u80_u83 (
    .clk(clk), .bd_in(bd_8716_q), .ld0(ld0), .ld1(ld1_rise), .ld2(ld2_rise),
    .clkadr_rise(clkadr_rise), .clkadr_fall(clkadr_fall), .wa(wa), .dir(dir)
  );

  // The CPU grants the bus grant_dly+1 _CLK samples after the request and
  // takes it back as many after the release.
  logic [15:0] grant_q;
  always_ff @(posedge clk) begin
    if (!rst_n)        grant_q <= 16'hFFFF;
    else if (zr || zf) grant_q <= {grant_q[14:0], busreq_n};
  end
  assign bai_n = grant_q[grant_dly] | busreq_n;

  // ---- zero-wait memory (2 MB) ------------------------------------------------------------
  logic [7:0] mem [0:(1<<21)-1];
  logic       dma_ds, dma_ds_q;
  logic [20:0] ba;
  assign dma_ds = !dmaen_n && dma_ds_oe && !dma_ds_n;
  assign ba     = {wa[19:0], 1'b0};
  always_ff @(posedge clk) begin
    dma_ds_q <= dma_ds;
    if (m_we) mem[m_addr] <= m_wdata;
    else if (dma_ds && !dma_ds_q && !dir && dma_ad_oe) begin
      mem[ba]        <= dma_ad_out[15:8];
      mem[ba | 21'd1] <= dma_ad_out[7:0];
    end
  end
  assign m_rdata = mem[m_addr];
  assign ad_in   = (dma_ds && dir) ? {mem[ba], mem[ba | 21'd1]} :
                   (!io_ds_n)      ? io_ad : 16'hFFFF;

  // ---- observation --------------------------------------------------------------------------
  assign mtron    = {u_fdc.mtron};
  assign sync_det = 1'b0;
  assign cpu_pc   = u_fdc.cpu_addr;
  assign trk0_cyl = 7'd0;

  logic unused_ok;
  assign unused_ok = &{1'b0, kbd_rise, rtc_rise, hdc_led, hdc_late, hd_sel, resident, busy, fmt_full, ld_min, ld_max, led, ld1_fall, ld2_fall, est_n,
                       bao_n, ieo_n, dma_mreq_n, dma_mreq_oe, wa[22:20]};

  // ---- record events (bench log) -------------------------------------------------------------
  longint unsigned clkn;
  always_ff @(posedge clk) clkn <= rst_n ? clkn + 64'd1 : 64'd0;
  for (genvar d = 0; d < 2; d++) begin : g_mon
    always_ff @(posedge clk) if (rst_n) begin
      if (u_fdc.u_drives.g_drv[d].u_head.ce && u_fdc.u_drives.g_drv[d].u_head.wstart_c)
        $display("  %9.3f ms EV fd%0d burst start trk %0d side %0d%s", real'(clkn) / 48000.0, d,
                 u_fdc.u_drives.g_drv[d].u_head.trk_n, u_fdc.u_drives.g_drv[d].u_head.side_c,
                 (u_fdc.u_drives.g_drv[d].u_head.rv_q[u_fdc.u_drives.g_drv[d].u_head.side_c] &&
                  u_fdc.u_drives.g_drv[d].u_head.rtag_q[u_fdc.u_drives.g_drv[d].u_head.side_c] != u_fdc.u_drives.g_drv[d].u_head.trk_n)
                 ? $sformatf(" DROPS record trk %0d (pdec %0d)", u_fdc.u_drives.g_drv[d].u_head.rtag_q[u_fdc.u_drives.g_drv[d].u_head.side_c],
                             u_fdc.u_drives.g_drv[d].u_head.pdec_q[u_fdc.u_drives.g_drv[d].u_head.side_c]) : "");
      if (u_fdc.u_drives.g_drv[d].u_head.ce && u_fdc.u_drives.g_drv[d].u_head.wron_q && u_fdc.u_drives.g_drv[d].u_head.wend_c)
        $display("  %9.3f ms EV fd%0d burst end", real'(clkn) / 48000.0, d);
      if (u_fdc.u_drives.dgo[d])
        $display("  %9.3f ms EV fd%0d decode trk %0d side %0d", real'(clkn) / 48000.0, d,
                 u_fdc.u_drives.g_drv[d].u_head.dq_trk, u_fdc.u_drives.g_drv[d].u_head.dq_side);
      if (u_fdc.u_drives.ddone[d])
        $display("  %9.3f ms EV fd%0d decode done clean %0d", real'(clkn) / 48000.0, d, u_fdc.u_drives.dec_clean);
      if (u_fdc.u_drives.dabort[d] && u_fdc.u_drives.dec_busy)
        $display("  %9.3f ms EV fd%0d decode ABORT", real'(clkn) / 48000.0, d);
      if (u_fdc.u_drives.g_drv[d].u_head.await_q && !u_fdc.u_drives.cm_busy && !u_fdc.u_drives.g_drv[d].u_head.cm_req_q)
        $display("  %9.3f ms EV fd%0d commit done", real'(clkn) / 48000.0, d);
    end
  end
endmodule
`default_nettype wire
