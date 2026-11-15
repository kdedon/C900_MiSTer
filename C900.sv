//============================================================================
//  Commodore 900 for MiSTer: the emu shell around c900_core.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_SL      = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

wire [15:0] spk_sample;          // SPEAKER below
assign AUDIO_S   = 1;
assign AUDIO_L   = spk_sample;
assign AUDIO_R   = spk_sample;
assign AUDIO_MIX = 0;

assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////
// Status bit map
//   0       reset
//   1       reserved
//   3:2     HR JP3 mode: 1024x800, 1024x1024, 640x400 RGBI
//   4       motherboard RAM: 1M, 512K
//   5       free
//   7:6     CPU clock: 6 MHz, 10, 12 (non-stock), 48 MHz (non-stock)
//   8       free
//   9       Z8070 FPU (non-stock)
//   10      free
//   12:11   display card: 0 LR, 1 HR, 2 none (headless), 3 LC 8563
//   15:13   serial port on the HPS UART: U74 B, U74 A, LR U31 A, U31 B, U36 A, U36 B
//   16      free
//   19:17   network interface: None (no LANCE card), eth0, eth1, wlan0, tap0
//           (non-stock; Main reads it too)
//   22:20   RAM card (non-stock): None, 2M, 4M, 8M, 15M
//   23      serial mouse on U74 A (non-stock, hidden with HR)
//   31:24   free
//   122:121 aspect ratio
//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

assign VIDEO_ARX = (ar == 2'd0) ? 13'd4 : {11'd0, ar - 2'd1};
assign VIDEO_ARY = (ar == 2'd0) ? 13'd3 : 13'd0;

`include "build_id.v"
localparam CONF_STR = {
	"C900;UART9600:4800:2400:1200:300;",
	"-;",
	"S0,IMG,Floppy 0;",
	"S1,IMG,Floppy 1;",
	"S2,IMGHDF,Hard Disk 0;",
	"S3,IMGHDF,Hard Disk 1;",
	"-;",
	"O[12:11],Display Card,LR,HR,None,LC 8563;",
	"H0O[3:2],HR Mode,1024x800,1024x1024,640x400 RGBI;",
	"O[4],Motherboard RAM,1M,512K;",
	"O[7:6],CPU Clock,6 MHz,10 MHz (non-stock),12 MHz (non-stock),48 MHz (non-stock);",
	"O[15:13],Serial Port,U74 B (console),U74 A,LR U31 A,LR U31 B,LR U36 A,LR U36 B;",
	"-;",
	"-;",
	"P1,Expansion (non-stock);",
	"P1-;",
	"P1-,Cards that never shipped;",
	"P1O[19:17],Network interface,None,eth0,eth1,wlan0,tap0;",
	"P1O[9],FPU,None,Z8070;",
	"P1O[22:20],RAM card,None,2M,4M,8M,15M;",
	"h0P1O[23],Serial mouse,Off,U74 A;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"-;",
	"R[0],Reset;",
	"v,12;",
	"V,v",`BUILD_DATE
};

wire        forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;
wire [24:0] ps2_mouse;

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        rom_busy;

wire  [3:0] img_mounted;
wire        img_readonly;
wire [63:0] img_size;
wire [31:0] sd_lba[4];
wire  [5:0] sd_blk_cnt[4];
wire  [3:0] sd_rd;
wire  [3:0] sd_wr;
wire  [3:0] sd_ack;
wire [13:0] sd_buff_addr;
wire  [7:0] sd_buff_dout;
wire  [7:0] sd_buff_din[4];
wire        sd_buff_wr;

wire [64:0] rtc_hps;

hps_io #(.CONF_STR(CONF_STR), .CONF_STR_BRAM(1), .VDNUM(4)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_in(128'd0),
	.status_set(1'b0),
	.status_menumask({15'd0, status[12:11] != 2'd1}),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),
	.RTC(rtc_hps),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(rom_busy),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba('{sd_lba[0], sd_lba[1], sd_lba[2], sd_lba[3]}),
	.sd_blk_cnt('{sd_blk_cnt[0], sd_blk_cnt[1], sd_blk_cnt[2], sd_blk_cnt[3]}),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din('{sd_buff_din[0], sd_buff_din[1], sd_buff_din[2], sd_buff_din[3]}),
	.sd_buff_wr(sd_buff_wr)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys, clk_ram, clk_vdc;
wire pll_locked;

// clk_sys: the one machine clock, 48 MHz.  clk_ram: 96 MHz for the SDRAM
// controller, rising edges with clk_sys.  clk_vdc: 32 MHz for the LC
// card's 8563; its rises meet clk_sys's every 62.5 ns.
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_ram),
	.outclk_2(clk_vdc),
	.locked(pll_locked)
);

// clk_vid (CLK_VIDEO) follows the card in the slot: LR 65.028 MHz = 4 x its
// 16.257 MHz crystal, HR 96 MHz = four mono pixels per 24M, LC 64 MHz = 4 x
// the 8563's 16 MHz dot.  pll_vid is
// built for HR and reprogrammed here (M, N, C, charge pump, bandwidth, K,
// as the framework's HDMI PLL is) whenever the card changes, which happens
// only in reset.  The machine stays in reset until clk_vid is right.
wire clk_vid;
wire pll_vid_locked;
wire [63:0] vid_to_pll, vid_from_pll;
pll_vid pll_vid
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_vid),
	.locked(pll_vid_locked),
	.reconfig_to_pll(vid_to_pll),
	.reconfig_from_pll(vid_from_pll)
);

wire        vcfg_wait;
reg         vcfg_write = 0;
reg   [5:0] vcfg_addr = 0;
reg  [31:0] vcfg_data = 0;
pll_cfg_hdmi pll_vid_cfg
(
	.mgmt_clk(CLK_50M),
	.mgmt_reset(0),
	.mgmt_waitrequest(vcfg_wait),
	.mgmt_write(vcfg_write),
	.mgmt_address(vcfg_addr),
	.mgmt_writedata(vcfg_data),
	.reconfig_to_pll(vid_to_pll),
	.reconfig_from_pll(vid_from_pll)
);

reg  cfg_hr = 0;          // RESET below: the card in the slot, taken in reset
reg  cfg_lc = 0;
reg  cfg_nocard = 0;      // no card: pll_vid stays at the LR setting
// pll_vid setting: 0 LR, 1 HR, 2 LC.  The two bits are quasi-static; a
// setting counts once two samples agree.
wire [1:0] cfg_vid = {cfg_lc, cfg_hr};
wire [1:0] vid_want_s;
c900_sync2 u_vid_want0 (.clk(CLK_50M), .d(cfg_vid[0]), .q(vid_want_s[0]));
c900_sync2 u_vid_want1 (.clk(CLK_50M), .d(cfg_vid[1]), .q(vid_want_s[1]));
reg  [1:0] vid_want_q = 2'd1;
always @(posedge CLK_50M) vid_want_q <= vid_want_s;
wire [1:0] vid_want = vid_want_q;
wire vid_want_ok = vid_want_s == vid_want_q;
wire vid_locked;
c900_sync2 u_vid_locked (.clk(CLK_50M), .d(pll_vid_locked), .q(vid_locked));

reg [1:0] vid_sel = 2'd1; // pll_vid's setting; built for HR
reg vid_ok = 1'b0;        // pll_vid is at vid_sel and locked
always @(posedge CLK_50M) begin : vid_reconfig
	reg  [3:0] state = 0;
	reg [16:0] settle = 0;
	if (!vcfg_wait) begin
		vcfg_write <= 0;
		if (state != 4'd0) state <= state + 1'd1;
		case (state)
			0: if (vid_want_ok && vid_want != vid_sel) begin vid_ok <= 0; state <= 1; end
			1:  begin vcfg_addr <= 0; vcfg_data <= 0;           vcfg_write <= 1; end // waitrequest mode
			2:  vid_sel <= vid_want;  // after vid_ok has fallen
			3:  begin vcfg_addr <= 4; vcfg_data <= 32'h00020A09; vcfg_write <= 1; end // M 19
			5:  begin vcfg_addr <= 3; vcfg_data <= 32'h00010000; vcfg_write <= 1; end // N bypassed
			7:  begin vcfg_addr <= 5; vcfg_data <= vid_sel == 2'd1 ? 32'h00000505 : 32'h00020807; vcfg_write <= 1; end // C0 10 / 15
			9:  begin vcfg_addr <= 9; vcfg_data <= 2;            vcfg_write <= 1; end // charge pump
			11: begin vcfg_addr <= 8; vcfg_data <= 7;            vcfg_write <= 1; end // bandwidth
			13: begin vcfg_addr <= 7; vcfg_data <= vid_sel != 2'd0 ? 32'h33333333 : 32'h8226809D; vcfg_write <= 1; end // K 0.2 / 0.5084
			15: begin vcfg_addr <= 2; vcfg_data <= 0;            vcfg_write <= 1; end // start
			default: ;
		endcase
	end
	// Lock counts only 2.6 ms after the start, once the PLL has dropped it.
	// Once set, vid_ok holds until the next reconfiguration (state 0 -> 1):
	// a lock glitch must not reset the machine.
	if (state == 0 && vid_want == vid_sel && vid_locked && settle == 0) vid_ok <= 1'b1;
	if (state == 15) settle <= 17'h1FFFF;
	else if (settle != 0) settle <= settle - 1'd1;
end

wire vid_ok_s;
wire [1:0] vid_sel_s;
c900_sync2 u_vid_ok (.clk(clk_sys), .d(vid_ok), .q(vid_ok_s));
c900_sync2 #(.INIT(1'b1)) u_vid_sel0 (.clk(clk_sys), .d(vid_sel[0]), .q(vid_sel_s[0]));
c900_sync2 u_vid_sel1 (.clk(clk_sys), .d(vid_sel[1]), .q(vid_sel_s[1]));
wire vid_ready = vid_ok_s && (vid_sel_s == cfg_vid);

///////////////////////   RESET   ////////////////////////////////

// RESET is asynchronous; synchronise it, then register every reset request
// so the asynchronous clear of the release synchroniser comes from a flop.
wire reset_in;
c900_sync2 #(.INIT(1'b1)) u_reset_sync (.clk(clk_sys), .d(RESET), .q(reset_in));

// Main holds status[0] from the core load until the options, the ROMs, the
// mounts and the time are in: that is power-on, not an S1 press.
reg hps_rst = 1'b1, hps_seen = 1'b0;
always @(posedge clk_sys) begin
	if (status[0]) hps_seen <= 1'b1;
	if (hps_seen && !status[0]) hps_rst <= 1'b0;
end

wire sdram_ready;
reg reset_req = 1'b1;
// While S1 holds _MRESET Low, pll_vid may follow a new display card; the card
// stays out of the slot until it locks (card_fitted below).
wire rst_n, mreset_n;
wire vid_hold = ~vid_ready & ~(rst_n & ~mreset_n);
`ifdef C900_DISK_DEBUG
wire [2:0] img_resident;
// debug: one machine reset when the first medium is mounted
reg dbg_rr = 0, dbg_rr_done = 0;
reg [2:0] dbg_res_q = 0;
always @(posedge clk_sys) begin
	dbg_res_q <= img_resident;
	dbg_rr <= 0;
	if (|(img_resident & ~dbg_res_q) && !dbg_rr_done) begin dbg_rr <= 1; dbg_rr_done <= 1; end
end
always @(posedge clk_sys) reset_req <= reset_in | hps_rst | ioctl_download | rom_busy | vid_hold | ~sdram_ready | dbg_rr;
`else
always @(posedge clk_sys) reset_req <= reset_in | hps_rst | ioctl_download | rom_busy | vid_hold | ~sdram_ready;
`endif

c900_rst_sync u_rst (.clk(clk_sys), .arst(reset_req), .pll_locked(pll_locked), .rst_n(rst_n));

// Configuration is sampled while _MRESET is Low (power-on or S1, the OSD
// Reset): on the real machine these are fitted cards, jumpers and chips.
reg [1:0] cfg_hr_mode, cfg_speed;
reg [2:0] cfg_card;
reg       cfg_512k, cfg_lance, cfg_fpu;
always @(posedge clk_sys) begin
	if (!mreset_n) begin
`ifdef C900_DISK_DEBUG
		cfg_hr      <= (status[12:11] ^ 2'd2) == 2'd1;
		cfg_lc      <= 1'b0;
		cfg_nocard  <= !status[12];
`else
		cfg_hr      <= status[12:11] == 2'd1;
		cfg_lc      <= status[12:11] == 2'd3;
		cfg_nocard  <= status[12:11] == 2'd2;
`endif
		cfg_hr_mode <= status[3:2];
		cfg_512k    <= status[4];
		cfg_card    <= status[22:20];
		cfg_speed   <= status[7:6];
		cfg_lance   <= status[19:17] != 3'd0;
		cfg_fpu     <= status[9];
		// A card left out of the build reads as an empty slot.
`ifdef C900_NO_LR
		if (status[12:11] == 2'd0) cfg_nocard <= 1'b1;
`endif
`ifdef C900_NO_HR
		if (status[12:11] == 2'd1) begin cfg_hr <= 1'b0; cfg_nocard <= 1'b1; end
`endif
`ifdef C900_NO_LC
		if (status[12:11] == 2'd3) begin cfg_lc <= 1'b0; cfg_nocard <= 1'b1; end
`endif
`ifdef C900_NO_TURBO
		cfg_speed   <= 2'd0;
`endif
`ifdef C900_NO_LANCE
		cfg_lance   <= 1'b0;
`endif
`ifdef C900_NO_APU
		cfg_fpu     <= 1'b0;
`endif
	end
end

///////////////////////   FIRMWARE   /////////////////////////////

// boot0.rom (ioctl index 0): the boot ROM, to SDRAM (boot_rom_load).
// boot1.rom (0x40): the peripheral ROMs, to the core.  boot2.rom (0x80):
// card ROMs in 16 KB slots; slot 0 is the LANCE card's.
wire rom_load = ioctl_download && (ioctl_index == 16'h0000);
wire rom_wr   = ioctl_download && (ioctl_index == 16'h0040) && ioctl_wr && (ioctl_addr[26:14] == 13'd0);
wire lan_rom_wr = ioctl_download && (ioctl_index == 16'h0080) && ioctl_wr && (ioctl_addr[26:14] == 13'd0);

///////////////////////   INPUT   ////////////////////////////////

wire [103:0] keys;
wire   [4:0] kbd_mods;
wire   [7:0] kbd_pb;
wire   [5:0] kbd_pc;
wire         kbd_pa7;
ps2_kbd_matrix u_kbd_host (.clk(clk_sys), .rst_n(rst_n), .ps2_key(ps2_key), .osd(OSD_STATUS),
	.kbd_pb(kbd_pb), .kbd_pc(kbd_pc), .kbd_pa7(kbd_pa7), .keys(keys), .mods(kbd_mods));

wire       m_h, m_hq, m_v, m_vq;
wire [2:0] m_b_n;
ps2_mouse_quad u_mouse_host (
	.clk(clk_sys), .rst_n(rst_n), .ps2_mouse(ps2_mouse), .osd(OSD_STATUS),
	.m_h(m_h), .m_hq(m_hq), .m_v(m_v), .m_vq(m_vq), .m_b_n(m_b_n)
);

// The OSD's Serial Port picks the SCC line on the HPS UART (U74 B, the
// console, by default); the UART dialog sets its mode and speed.
wire uart_rxd_s, uart_cts_s, uart_dsr_s;
c900_sync2 #(.INIT(1'b1)) u_rxd_sync (.clk(clk_sys), .d(UART_RXD), .q(uart_rxd_s));
c900_sync2 #(.INIT(1'b1)) u_cts_sync (.clk(clk_sys), .d(UART_CTS), .q(uart_cts_s));
c900_sync2 #(.INIT(1'b1)) u_dsr_sync (.clk(clk_sys), .d(UART_DSR), .q(uart_dsr_s));

wire [5:0] ser_txd, ser_rts_n, ser_dtr_n;
wire [5:0] ser_rxd, ser_cts_n, ser_dcd_n, ser_dsr_n;
// The disk-debug build also exchanges the U74 B and U74 A options.
`ifdef C900_DISK_DEBUG
uart_sel #(.SWAP_U74(1'b1)) u_uart_sel (
`else
uart_sel u_uart_sel (
`endif
	.clk(clk_sys), .sel(status[15:13]),
	.uart_rxd(uart_rxd_s), .uart_cts(uart_cts_s), .uart_dsr(uart_dsr_s),
	.uart_txd(UART_TXD), .uart_rts(UART_RTS), .uart_dtr(UART_DTR),
	.ser_rxd(ser_rxd), .ser_cts_n(ser_cts_n), .ser_dcd_n(ser_dcd_n), .ser_dsr_n(ser_dsr_n),
	.ser_txd(ser_txd), .ser_rts_n(ser_rts_n), .ser_dtr_n(ser_dtr_n)
);
assign USER_OUT = 7'h7F;

// A Mouse Systems mouse on U74 A's RxD, never with the HR card (it has its
// own mouse port).  It takes RxD over from the HPS UART when both are on
// U74 A; the modem inputs stay as the Serial Port option leaves them.
wire ms_active, ms_rxd;
ps2_mouse_msys u_mouse_ser (
	.clk(clk_sys), .rst_n(rst_n), .ps2_mouse(ps2_mouse), .osd(OSD_STATUS),
	.on(status[23]), .hr(cfg_hr), .active(ms_active), .rxd(ms_rxd)
);
wire [5:0] scc_rxd = {ser_rxd[5:1], ms_active ? ms_rxd : ser_rxd[0]};

///////////////////////   MEMORY   ///////////////////////////////

wire [23:1] mem_addr;
wire        mem_rd, mem_wr, mem_rvalid, mem_ack, mem_refresh_ok;

// The SDRAM keeps its init and refresh through a machine reset (the C900's
// DRAM keeps its contents across the reset switch): it follows PLL lock only.
wire sdram_rst_n, sdram_ram_rst_n;
c900_rst_sync u_sdram_rst (.clk(clk_sys), .arst(1'b0), .pll_locked(pll_locked), .rst_n(sdram_rst_n));
// The card's boot ROM stays loaded through a machine reset.
reg  lan_rom_ok;
always @(posedge clk_sys) begin
	if (!sdram_rst_n)    lan_rom_ok <= 1'b0;
	else if (lan_rom_wr) lan_rom_ok <= 1'b1;
end
c900_rst_sync u_sdram_ram_rst (.clk(clk_ram), .arst(1'b0), .pll_locked(pll_locked), .rst_n(sdram_ram_rst_n));
wire  [1:0] mem_be;
wire [15:0] mem_wdata, mem_rdata;

// The loader owns the port from the download's start (the machine is held
// in reset) until its last write is acknowledged.
wire [23:1] ld_addr;
wire        ld_rd, ld_wr, ld_sel, ram_ack, ram_rvalid;
wire  [1:0] ld_be;
wire [15:0] ld_wdata;
boot_rom_load u_rom_load (
	.clk(clk_sys), .rst_n(sdram_rst_n),
	.wr(rom_load && ioctl_wr && (ioctl_addr[26:16] == 11'd0)), .addr(ioctl_addr[15:0]), .data(ioctl_dout),
	.busy(rom_busy), .mem_addr(ld_addr), .mem_rd(ld_rd), .mem_wr(ld_wr), .mem_be(ld_be), .mem_wdata(ld_wdata),
	.mem_rdata(mem_rdata[7:0]), .mem_ack(ram_ack)
);
assign ld_sel  = rom_load | rom_busy;
assign mem_ack    = ram_ack & ~ld_sel;
assign mem_rvalid = ram_rvalid & ~ld_sel;

c900_sdram u_sdram (
	.clk(clk_sys), .clk_ram(clk_ram), .rst_n(sdram_rst_n), .rst_ram_n(sdram_ram_rst_n),
	.refresh_ok(mem_refresh_ok | ld_sel), .ready(sdram_ready),
	.addr(ld_sel ? ld_addr : mem_addr), .rd(ld_sel ? ld_rd : mem_rd), .wr(ld_sel ? ld_wr : mem_wr),
	.be(ld_sel ? ld_be : mem_be), .wdata(ld_sel ? ld_wdata : mem_wdata),
	.rdata(mem_rdata), .rvalid(ram_rvalid), .ack(ram_ack),
	.sdram_clk(SDRAM_CLK), .sdram_cke(SDRAM_CKE), .sdram_a(SDRAM_A), .sdram_ba(SDRAM_BA),
	.sdram_dq(SDRAM_DQ), .sdram_dqml(SDRAM_DQML), .sdram_dqmh(SDRAM_DQMH),
	.sdram_ncs(SDRAM_nCS), .sdram_nras(SDRAM_nRAS), .sdram_ncas(SDRAM_nCAS), .sdram_nwe(SDRAM_nWE)
);

///////////////////////   CORE   /////////////////////////////////

///////////////////////   DISK IMAGES   //////////////////////////

// The drives' block requests are served from BRAM, one cylinder per
// slot (the two hard disks share one), loaded from the image file on
// demand; their writes go back to the file in the background
// (disk_stream).

wire [3:0][31:0] st_h_lba;
wire [3:0][5:0]  st_h_blk_cnt;
wire  [7:0]      st_h_din;
genvar gs;
generate
	for (gs = 0; gs < 4; gs = gs + 1) begin : g_sd
		assign sd_lba[gs]      = st_h_lba[gs];
		assign sd_blk_cnt[gs]  = st_h_blk_cnt[gs];
		assign sd_buff_din[gs] = st_h_din;
	end
endgenerate

wire  [3:0]      core_img_mounted;
wire             core_img_readonly;
wire [63:0]      core_img_size;
wire [3:0][31:0] core_sd_lba;
wire  [3:0]      core_sd_rd, core_sd_wr, core_sd_ack, core_sd_scr;
wire  [8:0]      core_sd_buff_addr;
wire  [7:0]      core_sd_buff_dout;
wire [3:0][7:0]  core_sd_buff_din;
wire             core_sd_buff_wr;
wire  [1:0]      hd_sel;
wire [1:0][11:0] hd_bpc;
wire  [3:0]      ds_resident;
wire             img_loading, img_wb_busy, fmt_full;
wire [1:0][15:0] ld_min, ld_max;
`ifdef C900_DISK_DEBUG
wire [55:0]      dbg_cpu;
wire [15:0]      dbg_st = {6'd0, ds_resident, hd_sel, img_loading, img_wb_busy, fmt_full, 1'b0};
// debug: slots with a medium
reg  [2:0]       dbg_med = 0;
always @(posedge clk_sys) begin
	if (core_img_mounted[0]) dbg_med[0] <= core_img_size != 0;
	if (core_img_mounted[1]) dbg_med[1] <= core_img_size != 0;
	if (core_img_mounted[2]) dbg_med[2] <= core_img_size != 0;
end
assign img_resident = dbg_med;
`endif

disk_stream u_disk_stream (
	.clk(clk_sys), .rst_n(sdram_rst_n), .core_rst_n(rst_n), .bpc(hd_bpc),
	.img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
	.h_lba(st_h_lba), .h_blk_cnt(st_h_blk_cnt), .h_rd(sd_rd), .h_wr(sd_wr), .h_ack(sd_ack),
	.h_buff_addr(sd_buff_addr), .h_buff_dout(sd_buff_dout), .h_buff_din(st_h_din),
	.h_buff_wr(sd_buff_wr),
	.d_mounted(core_img_mounted), .d_readonly(core_img_readonly), .d_size(core_img_size),
	.d_lba(core_sd_lba), .d_scr(core_sd_scr), .d_rd(core_sd_rd), .d_wr(core_sd_wr), .d_ack(core_sd_ack),
	.d_buff_addr(core_sd_buff_addr), .d_buff_dout(core_sd_buff_dout), .d_buff_din(core_sd_buff_din),
	.d_buff_wr(core_sd_buff_wr),
	.resident(ds_resident), .busy(img_loading), .wb_busy(img_wb_busy), .fmt_full(fmt_full),
	.ld_min(ld_min), .ld_max(ld_max)
);

wire        lan_on, lan_tclk_rise, lan_tclk_fall, lan_tx, lan_tena;
wire        lan_rclk_rise, lan_rx, lan_rena, lan_clsn, lan_mac_ok;
wire [47:0] lan_mac;
wire        lan_cfg_ok, lan_cfg_wr;
wire  [4:0] lan_cfg_addr;
wire [15:0] lan_cfg_data;
wire       ce_pix, hsync, vsync, de, hblank, vblank;
wire       lr_vid, lr_intens;
wire       hr_ck24, hr_hsync, hr_hsync_n, hr_vsync_n, hr_de, hr_de_dly, hr_vblank_n, hr_mono_en, hr_mono_i;
wire [3:0] hr_rgbi, hr_vout;
wire [3:0] lc_rgbi;
wire       lc_hsync, lc_vsync, lc_pixel_ce, lc_active_h, lc_active_v;
wire       led_fdd, led_hdd;
wire [1:0] disk_late;

c900_core u_core (
	.clk(clk_sys), .clk_vid(clk_vid), .clk_vdc(clk_vdc), .rst_n(rst_n), .s1(status[0] | buttons[1]), .mreset_n(mreset_n),
	.card_fitted(!cfg_nocard & vid_ready), .display_hr(cfg_hr), .display_lc(cfg_lc), .hr_mode(cfg_hr_mode), .ram_512k(cfg_512k), .ram_card(cfg_card), .cpu_speed(cfg_speed),
	.lance_en(cfg_lance), .fpu_en(cfg_fpu),
	.rtc_hps(rtc_hps),
	.rom_wr(rom_wr), .rom_addr(ioctl_addr[13:0]), .rom_data(ioctl_dout),
	.img_mounted(core_img_mounted), .img_readonly(core_img_readonly), .img_size(core_img_size),
	.sd_lba(core_sd_lba), .sd_rd(core_sd_rd), .sd_wr(core_sd_wr), .sd_scr(core_sd_scr), .sd_ack(core_sd_ack),
	.sd_buff_addr(core_sd_buff_addr), .sd_buff_dout(core_sd_buff_dout), .sd_buff_din(core_sd_buff_din),
	.sd_buff_wr(core_sd_buff_wr), .hd_sel(hd_sel), .hd_bpc(hd_bpc),
	.keys(keys), .kbd_mods(kbd_mods), .kbd_pb(kbd_pb), .kbd_pc(kbd_pc), .kbd_pa7(kbd_pa7), .m_h(m_h), .m_hq(m_hq), .m_v(m_v), .m_vq(m_vq), .m_b_n(m_b_n),
	.ser_rxd(scc_rxd), .ser_txd(ser_txd), .ser_cts_n(ser_cts_n), .ser_dcd_n(ser_dcd_n), .ser_dsr_n(ser_dsr_n),
	.ser_rts_n(ser_rts_n), .ser_dtr_n(ser_dtr_n),
	.mem_addr(mem_addr), .mem_rd(mem_rd), .mem_wr(mem_wr), .mem_be(mem_be),
	.mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_rvalid(mem_rvalid), .mem_ack(mem_ack),
	.mem_refresh_ok(mem_refresh_ok),
	.ce_pix(ce_pix), .hsync(hsync), .vsync(vsync), .de(de), .hblank(hblank), .vblank(vblank),
	.lr_vid(lr_vid), .lr_intens(lr_intens),
	.hr_ck24(hr_ck24), .hr_hsync(hr_hsync), .hr_hsync_n(hr_hsync_n), .hr_vsync_n(hr_vsync_n),
	.hr_de(hr_de), .hr_de_dly(hr_de_dly), .hr_vblank_n(hr_vblank_n),
	.hr_rgbi(hr_rgbi), .hr_vout(hr_vout), .hr_mono_en(hr_mono_en), .hr_mono_i(hr_mono_i),
	.lc_rgbi(lc_rgbi), .lc_hsync(lc_hsync), .lc_vsync(lc_vsync), .lc_pixel_ce(lc_pixel_ce),
	.lc_active_h(lc_active_h), .lc_active_v(lc_active_v),
	.cent_data(cent_data), .cent_strobe_n(cent_strobe_n), .cent_ack_n(1'b1), .cent_busy(1'b1),
	.spk_on(spk_on),
	.lan_on(lan_on), .lan_tclk_rise(lan_tclk_rise), .lan_tclk_fall(lan_tclk_fall), .lan_tx(lan_tx), .lan_tena(lan_tena),
	.lan_rclk_rise(lan_rclk_rise), .lan_rx(lan_rx), .lan_rena(lan_rena), .lan_clsn(lan_clsn),
	.lan_mac_ok(lan_mac_ok), .lan_mac(lan_mac), .lan_rom_ok(lan_rom_ok), .lan_rom_wr(lan_rom_wr),
	.lan_rom_addr(ioctl_addr[13:0]), .lan_rom_data(ioctl_dout),
	.lan_cfg_ok(lan_cfg_ok), .lan_cfg_wr(lan_cfg_wr), .lan_cfg_addr(lan_cfg_addr), .lan_cfg_data(lan_cfg_data),
	.led_fdd(led_fdd), .led_hdd(led_hdd), .disk_late(disk_late)
`ifdef C900_DISK_DEBUG
	, .dbg(dbg_cpu)
`endif
);

///////////////////////   LANCE CABLE   //////////////////////

// The LANCE card's cable: the transceiver, and frames to and from Main
// through a ring in DDR3 (the only DDRAM user).
`ifndef C900_NO_LANCE
assign DDRAM_CLK = clk_sys;
lance_link u_lance_link (
	.clk(clk_sys), .rst_n(sdram_rst_n), .card_on(lan_on),
	.tclk_rise(lan_tclk_rise), .tclk_fall(lan_tclk_fall), .tx(lan_tx), .tena(lan_tena),
	.rclk_rise(lan_rclk_rise), .rx(lan_rx), .rena(lan_rena), .clsn(lan_clsn),
	.mac_ok(lan_mac_ok), .mac(lan_mac),
	.cfg_ok(lan_cfg_ok), .cfg_wr(lan_cfg_wr), .cfg_addr(lan_cfg_addr), .cfg_data(lan_cfg_data),
	.ddr_busy(DDRAM_BUSY), .ddr_burstcnt(DDRAM_BURSTCNT), .ddr_addr(DDRAM_ADDR), .ddr_dout(DDRAM_DOUT),
	.ddr_dout_ready(DDRAM_DOUT_READY), .ddr_rd(DDRAM_RD), .ddr_din(DDRAM_DIN), .ddr_be(DDRAM_BE), .ddr_we(DDRAM_WE)
);
`else
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;
assign {lan_rclk_rise, lan_rx, lan_rena, lan_clsn, lan_mac_ok} = 5'b0;
assign lan_mac = 48'd0;
assign {lan_cfg_ok, lan_cfg_wr, lan_cfg_addr, lan_cfg_data} = '0;
`endif

///////////////////////   CN5 AND SPEAKER   //////////////////

// CN5 has no printer: /ACK and BUSY float High on the board pull-ups.
wire [7:0] cent_data;
wire       cent_strobe_n;

// CN3 speaker: the coil drive as a level through a gentle low-pass.
wire        spk_on;
speaker_audio u_speaker (.clk(clk_sys), .rst_n(rst_n), .spk_on(spk_on), .sample(spk_sample));

///////////////////////   VIDEO   ////////////////////////////////

// Each card's own pins, one for one, at its own pixel rate in clk_vid:
// video_mixer feeds the scaler (HDMI) and the analog output.  The LR line
// (18.4 kHz) can use the scandoubler; the HR line (53.6 kHz) does not.
assign CLK_VIDEO = clk_vid;

wire       hr_ce, hr_hs, hr_vs, hr_hb, hr_vb;
wire [7:0] hr_r, hr_g, hr_b;
`ifndef C900_NO_HR
hr_video u_hr_video (
	.clk(clk_sys), .ck24(hr_ck24), .colour(cfg_hr_mode[1]),
	.hsync(hr_hsync), .vsync_n(hr_vsync_n), .de(hr_de), .de_dly(hr_de_dly), .vblank_n(hr_vblank_n),
	.rgbi(hr_rgbi), .u104(hr_vout), .mono_en(hr_mono_en), .mono_i(hr_mono_i),
	.clk_vid(clk_vid), .ce_pix(hr_ce), .r(hr_r), .g(hr_g), .b(hr_b),
	.hs(hr_hs), .vs(hr_vs), .hblank(hr_hb), .vblank(hr_vb)
);
`else
assign {hr_ce, hr_hs, hr_vs, hr_hb, hr_vb} = 5'b0;
assign {hr_r, hr_g, hr_b} = 24'd0;
`endif

wire       lc_ce, lc_hs, lc_vs, lc_hb, lc_vb, lc_f1;
wire [7:0] lc_r, lc_g, lc_b;
wire hr_v, nc_v, lc_v;
c900_sync2 u_hr_v (.clk(clk_vid), .d(cfg_hr), .q(hr_v));
c900_sync2 u_nc_v (.clk(clk_vid), .d(cfg_nocard), .q(nc_v));
`ifndef C900_NO_LC
lc_video u_lc_video (
	.clk_vdc(clk_vdc), .rgbi(lc_rgbi), .hsync(lc_hsync), .vsync(lc_vsync), .pixel_ce(lc_pixel_ce),
	.active_h(lc_active_h), .active_v(lc_active_v),
	.clk_vid(clk_vid), .ce_pix(lc_ce), .r(lc_r), .g(lc_g), .b(lc_b),
	.hs(lc_hs), .vs(lc_vs), .hblank(lc_hb), .vblank(lc_vb), .field(lc_f1)
);
`else
assign {lc_ce, lc_hs, lc_vs, lc_hb, lc_vb, lc_f1} = 6'b0;
assign {lc_r, lc_g, lc_b} = 24'd0;
`endif
c900_sync2 u_lc_v (.clk(clk_vid), .d(cfg_lc), .q(lc_v));

// The scaler weaves the LC card's interlaced fields; scandoubled lines
// would weave out of order, so they go as progressive frames.
assign VGA_F1 = lc_v & ~forced_scandoubler & lc_f1;

// No card: a black 1024x768 60 Hz frame (VESA timing, 65 MHz pixel clock)
// keeps the scaler locked.
reg [10:0] nc_x = 0;
reg  [9:0] nc_y = 0;
always @(posedge clk_vid) begin
	nc_x <= (nc_x == 11'd1343) ? 11'd0 : nc_x + 11'd1;
	if (nc_x == 11'd1343) nc_y <= (nc_y == 10'd805) ? 10'd0 : nc_y + 10'd1;
end
wire nc_hb = nc_x >= 11'd1024;
wire nc_vb = nc_y >= 10'd768;
wire nc_hs = nc_x >= 11'd1048 && nc_x < 11'd1184;
wire nc_vs = nc_y >= 10'd771 && nc_y < 10'd777;

// LR video bit on = white, two thirds without the intensity bit.
wire [7:0] lv = lr_vid ? (lr_intens ? 8'hFF : 8'hAA) : 8'h00;

// The LC card and the LR card share the 15 kHz path.
wire       sl_ce = lc_v ? lc_ce : ce_pix;
wire [7:0] sl_r  = lc_v ? lc_r : lv;
wire [7:0] sl_g  = lc_v ? lc_g : lv;
wire [7:0] sl_b  = lc_v ? lc_b : lv;
wire       sl_hs = lc_v ? lc_hs : hsync;
wire       sl_vs = lc_v ? lc_vs : vsync;
wire       sl_hb = lc_v ? lc_hb : hblank;
wire       sl_vb = lc_v ? lc_vb : vblank;

wire [7:0] mix_r, mix_g, mix_b;
`ifdef C900_DISK_DEBUG
disk_dbg u_disk_dbg (
	.clk(clk_sys), .rst_n(rst_n), .reset_in(reset_in), .pll_locked(pll_locked), .ioctl_download(ioctl_download),
	.img_mounted(img_mounted[2:0]), .img_size(img_size), .h_rd(sd_rd[2:0]), .h_wr(sd_wr[2:0]), .h_ack(sd_ack[2:0]),
	.h_buff_wr(sd_buff_wr), .h_buff_dout(sd_buff_dout),
	.d_mounted(core_img_mounted[2:0]), .d_size(core_img_size), .d_lba(core_sd_lba[2:0]), .d_rd(core_sd_rd[2:0]),
	.d_wr(core_sd_wr[2:0]), .d_scr(core_sd_scr[2:0]), .d_ack(core_sd_ack[2:0]), .d_buff_wr(core_sd_buff_wr),
	.d_buff_dout(core_sd_buff_dout), .resident(ds_resident[2:0]), .loading(img_loading), .wb_busy(img_wb_busy),
	.late(disk_late), .st(dbg_st), .cpu(dbg_cpu), .txd(ser_txd[1:0]),
	.hd_sel(hd_sel), .fmt_full(fmt_full), .ld_min(ld_min), .ld_max(ld_max),
	.clk_vid(CLK_VIDEO), .ce_pix(CE_PIXEL), .de(VGA_DE), .vs(VGA_VS),
	.r_in(mix_r), .g_in(mix_g), .b_in(mix_b), .r(VGA_R), .g(VGA_G), .b(VGA_B)
);
`else
assign {VGA_R, VGA_G, VGA_B} = {mix_r, mix_g, mix_b};
`endif

video_mixer #(.LINE_LENGTH(800), .HALF_DEPTH(0), .GAMMA(0)) video_mixer
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.ce_pix(nc_v ? 1'b1 : hr_v ? hr_ce : sl_ce),
	.scandoubler(forced_scandoubler & ~hr_v & ~nc_v),
	.hq2x(1'b0),
	.gamma_bus(),
	.R(nc_v ? 8'h00 : hr_v ? hr_r : sl_r), .G(nc_v ? 8'h00 : hr_v ? hr_g : sl_g), .B(nc_v ? 8'h00 : hr_v ? hr_b : sl_b),
	.HSync(nc_v ? nc_hs : hr_v ? hr_hs : sl_hs), .VSync(nc_v ? nc_vs : hr_v ? hr_vs : sl_vs),
	.HBlank(nc_v ? nc_hb : hr_v ? hr_hb : sl_hb), .VBlank(nc_v ? nc_vb : hr_v ? hr_vb : sl_vb),
	.HDMI_FREEZE(HDMI_FREEZE),
	.freeze_sync(),
	.VGA_R(mix_r), .VGA_G(mix_g), .VGA_B(mix_b),
	.VGA_VS(VGA_VS), .VGA_HS(VGA_HS), .VGA_DE(VGA_DE)
);

///////////////////////   LEDS   /////////////////////////////////

// The disk LED also stays on while written sectors are still queued for
// the image file: eject only once it is off.
assign LED_DISK = {1'b0, led_fdd | led_hdd | img_loading | img_wb_busy};
assign LED_USER = ~pll_locked;

endmodule
