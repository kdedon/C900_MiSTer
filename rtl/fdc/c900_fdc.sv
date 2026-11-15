// Floppy controller, motherboard sheets 13-16: MOS 6508 CPU, 8 KB U203
// firmware EPROM (2764 at 0xE000-0xFFFF), MOS 8723, U202 74LS245 to the
// 8716's OMAD bus, and two drives.  The 6508's Phi2 IN is the 8723's PH2;
// both clock pins take one-master-clock edge pulses.
`default_nettype none
module c900_fdc (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              board_reset_n,
  input  logic              clkin,         // 6 MHz _CLK rises now
  // ROM loader
  input  logic              rom_we,
  input  logic [12:0]       rom_addr,
  input  logic [7:0]        rom_data,
  // 8716 controller bus
  input  logic [7:0]        bd_in,
  output logic [7:0]        bd_out,
  output logic              bd_oe,
  output logic              pcss_n,
  output logic              pcsd_n,
  output logic              strobe_oe,
  input  logic              ireq_n,        // _IREQ net -> 6508 /IRQ
  input  logic              inten,         // CN9 34 INTEN -> 6508 P7
  output logic [1:0]        led,
  // track servers for fd0/fd1
  input  logic [1:0]        img_mounted,
  input  logic              img_readonly,
  input  logic [63:0]       img_size,
  output logic [1:0][31:0]  sd_lba,
  output logic [1:0]        sd_rd,
  output logic [1:0]        sd_wr,
  output logic [1:0]        sd_scr,        // block is in the slot's scratch region
  input  logic [1:0]        sd_ack,
  input  logic [8:0]        sd_buff_addr,
  input  logic [7:0]        sd_buff_dout,
  output logic [1:0][7:0]   sd_buff_din,
  input  logic              sd_buff_wr,
  output logic              late           // a head's data arrived too late (sticky)
);
  // ---- 6508 ------------------------------------------------------------------
  logic        ph2_rise, ph2_fall, ph2_q, so_n;
  logic [7:0]  cpu_dout, cpu_din, port_out, port_dir;
  logic [15:0] cpu_addr;
  logic        cpu_rw_n;

  // PH2 level, for the board glue that is qualified by it (set by the rise
  // pulse, cleared by the fall pulse): High from the clock after the rise
  // pulse through the fall pulse.
  always_ff @(posedge clk) begin
    if (!rst_n)        ph2_q <= 1'b0;
    else if (ph2_rise) ph2_q <= 1'b1;
    else if (ph2_fall) ph2_q <= 1'b0;
  end

  // RES: the board reset (which net drives it is untraced).
  // The 6508 takes RES at a Phi2 rise, so its first Phi2 rise after
  // the board reset is still a reset cycle.
  cpu6508 u201_cpu (
    .clk(clk), .phi2(ph2_rise), .reset_n(board_reset_n), .irq_n(ireq_n), .so_n(so_n),
    .data_in(cpu_din), .data_out(cpu_dout), .addr(cpu_addr), .rw_n(cpu_rw_n),
    .port_in({inten, 7'h7F}), .port_out(port_out), .port_dir(port_dir)
  );

  // ---- firmware EPROM and 8723 decode ----------------------------------------
  logic [7:0] rom_q, fdc_dout;
  logic       fdc_doe, fdc_cs_n, rom_sel;

  c900_rom #(.AW(13)) u203_fw (
    .clk(clk), .addr(cpu_addr[12:0]), .q(rom_q),
    .ld_we(rom_we), .ld_addr(rom_addr), .ld_data(rom_data)
  );

  // The 8723 select is the 0x4000-0x400F decode qualified by PH2: Low
  // from the clock after the PH2 rise (the 6508's new cycle) through the
  // clock before the PH2 fall; the 6508 holds address, R/W and write data
  // until its next PH2 rise, so a write commits at the CS rise with its
  // own data.
  assign fdc_cs_n = ~((cpu_addr[15:4] == 12'h400) & ph2_q & ~ph2_fall);
  assign rom_sel  = (cpu_addr[15:13] == 3'b111);

  // ---- 8723 + drives -----------------------------------------------------------
  logic [3:0] step0, step1;
  logic [1:0] mtron, tak0_n, wrpt_n;
  logic       rdata;
  logic       hosel, wrgt, erase, wd, nwd, buffen_n, dmadir;

  // U204 (drawing 315017).  CLKIN = the 6 MHz _CLK
  // rise pulse; RDATA is the one shared read-amp net (the head matrix picks
  // the drive).  Its D pins see the D bus: in a PCSD-in read the 8716's
  // byte through U202 is what enters the write shifter.
  logic [7:0] d_bus, d_latch, d_pins;
  assign d_pins = cpu_rw_n ? d_bus : cpu_dout;

  fdc8723 u204_fdc (
    .clk(clk), .clkin(clkin), .reset_n(board_reset_n),
    .cs_n(fdc_cs_n), .r_w(cpu_rw_n), .a(cpu_addr[3:0]), .d_in(d_pins),
    .d_out(fdc_dout), .d_oe(fdc_doe), .so_n(so_n), .ph2_rise(ph2_rise), .ph2_fall(ph2_fall),
    .buffen_n(buffen_n), .dmadir(dmadir), .pcss_n(pcss_n), .pcsd_n(pcsd_n),
    .strobe_oe(strobe_oe),
    .rdata(rdata), .trk0_n(tak0_n), .wrpt_n(wrpt_n),
    .mtron(mtron), .led(led), .step0(step0), .step1(step1), .hdsel(hosel),
    .wrgt(wrgt), .erase(erase), .wd(wd), .nwd(nwd)
  );

  // 6508 read data: on-chip space is inside the 6508; external
  // space is the 8723 when selected, the EPROM, or the OMAD bus through U202
  // when the 8716 sources it (DMADIR High, polarity unconfirmed); else the
  // bus floats High.
  always_comb begin
    if (fdc_doe)                   d_bus = fdc_dout;
    else if (rom_sel)              d_bus = rom_q;
    else if (!buffen_n && dmadir)  d_bus = bd_in;
    else                           d_bus = 8'hFF;
  end

  // The 6508 takes read data at the PH2 fall (its input latch); the T65
  // advances at the next PH2 rise, so it is given the D bus as latched at
  // that fall.
  always_ff @(posedge clk) begin
    if (!rst_n)              d_latch <= 8'hFF;
    else if (ph2_fall)       d_latch <= d_bus;
  end
  assign cpu_din = d_latch;

  // U202: 6508 D bus toward OMAD while enabled and DMADIR Low.
  assign bd_out = (fdc_doe ? fdc_dout : cpu_dout);
  assign bd_oe  = ~buffen_n & ~dmadir;

  // Both drives on the cable: one module with
  // the U205 head matrix inside.  The stepper coil inputs are registered
  // first (one master clock against a 3 ms step).
  logic [1:0][3:0] ph_q;
  logic [1:0]      trk0, wrpt;
  always_ff @(posedge clk) ph_q <= {step1, step0};

  fd_drive u_drives (
    .clk(clk), .rst_n(rst_n), .clkin(clkin),
    .ph(ph_q), .mtron(mtron), .led(led), .hosel(hosel), .wrgt(wrgt), .erase(erase),
    .wd(wd), .nwd(nwd), .rdata(rdata), .trk0(trk0), .wrpt(wrpt),
    .img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
    .sd_lba(sd_lba), .sd_scr(sd_scr), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
    .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din),
    .sd_buff_wr(sd_buff_wr), .late(late)
  );
  assign tak0_n = ~trk0;
  assign wrpt_n = ~wrpt;

  logic unused_ok;
  assign unused_ok = &{1'b0, port_out, port_dir};
endmodule
`default_nettype wire
