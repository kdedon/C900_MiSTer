// NON-STOCK: Am7990 LANCE Ethernet card on CN11.
//   I/O 0x0700  RDP (ADR = A1 = 0)      0x0702  RAP
//   I/O 0x0710/0x0712/0x0714  station address PROM, MAC bytes 0-5,
//       the earlier byte in D15:8
//   I/O 0x0718  ROMA (W): window word address, 14 bits
//   I/O 0x071A  ROMD (R): the word at ROMA; ROMA counts up after each read
// Window: words 0000-17FF the boot ROM (rom_ok, else FFFF), 3FE0-3FFF the
// IP configuration, ring words 8-15 with byte 0 of each in D15:8 (cfg_ok,
// else FFFF), the rest FFFF.
// Word cycles only, ST 0010 or 0011; the port address is latched from AD
// while /AS is low.  /INTR drives /VI; an interrupt acknowledge with IEI
// high at the /DS fall reads the vector strap on AD7:0; IEO = IEI while
// /INTR is high.  The card is last in the IEI/IEO chain.
//
// As bus master the chip's pins map onto the Z-Bus (CSR3 = 7: ACON,
// BCON, BSWP): /AS = AS, /DS = /DAS, R/W = READ, B/W = BYTE, /BUSREQ =
// /BUSRQ, /HLDA = /BAI, /BAO = /BUSAKO, /READY = /WAIT.  The address is
// physical: A23:16 go out on the lines the 8716's DMA address uses and
// bypass the MMU, as the 8716 does.  ST reads 1000.  /MREQ is low for the
// whole grant, as the Z8K90 PAL's M = HLDA, while the chip's own /BUSRQ
// is low (a grant passed down the chain is not ours).  The PAL's
// /WAIT = /READY: a slave access holds /WAIT until the chip's /READY.
// The PROM holds mac when mac_ok, else MAC.
// TCLK is the on-card SIA's 20 MHz crystal halved: 5 edges per 12 clocks.
// The serial pins go to the cable side (SIA and network) outside.
`default_nettype none
module am7990_lance_card #(
  parameter logic [47:0] MAC    = 48'h02_60_8C_0C_09_00,  // byte 0 in 47:40
  parameter logic [7:0]  VECTOR = 8'h88
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        enable,
  input  logic [15:0] ad_bus,      // BAD15:0, one clock behind the pins
  input  logic        as_n,
  input  logic        ds_n,
  input  logic        r_w,
  input  logic        b_w,
  input  logic [3:0]  st,
  input  logic        intack_n,
  input  logic        iei,
  input  logic        bai_n,       // bus grant in
  output logic        bao_n,       // bus grant out
  output logic        busreq_n,
  output logic [15:0] ad_out,
  output logic [15:0] ad_oe,
  output logic        bus_oe,      // drives /AS /DS /MREQ R/W B/W ST A23:16 while master
  output logic        vi_n,
  output logic        ieo,
  input  logic        wait_n,      // /WAIT
  input  logic        busreq_in_n, // the /BUSREQ line
  output logic        wait_pd,     // /WAIT, open drain
  input  logic        mac_ok,
  input  logic [47:0] mac,         // byte 0 in 47:40
  // boot ROM bytes, the earlier byte of each word in D15:8
  input  logic        rom_ok,
  input  logic        rom_wr,
  input  logic [13:0] rom_addr,
  input  logic [7:0]  rom_data,
  // IP configuration: ring words 8-15
  input  logic        cfg_ok,
  input  logic        cfg_wr,
  input  logic [4:0]  cfg_addr,    // ring word 8 + addr/4, half addr%4
  input  logic [15:0] cfg_data,
  output logic        as_n_o,
  output logic        ds_n_o,
  output logic        r_w_o,
  output logic        b_w_o,
  output logic        mreq_n_o,
  output logic [3:0]  st_o,
  output logic [7:0]  a_hi_o,
  // cable side: the Am7990 serial pins
  output logic        tclk_rise,
  output logic        tclk_fall,
  output logic        tx,
  output logic        tena,
  input  logic        rclk_rise,
  input  logic        rx,
  input  logic        rena,
  input  logic        clsn
);
  localparam logic [3:0] ST_IO = 4'b0010, ST_SPECIAL_IO = 4'b0011, ST_DATA_MEM = 4'b1000;

  // ---- SIA crystal stand-in: 10 MHz TCLK ----
  // Justification: (reg-a) phase accumulator, clock level, edge pulses.
  logic [3:0] acc_q;
  logic       ck_q, rise_q, fall_q;
  logic [4:0] acc_s;
  logic       acc_t;
  assign acc_s = 5'(acc_q) + 5'd5;
  assign acc_t = acc_s >= 5'd12;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      acc_q  <= 4'd0;
      ck_q   <= 1'b0;
      rise_q <= 1'b0;
      fall_q <= 1'b0;
    end else begin
      acc_q  <= acc_t ? 4'(acc_s - 5'd12) : acc_s[3:0];
      if (acc_t) ck_q <= ~ck_q;
      rise_q <= acc_t && !ck_q;
      fall_q <= acc_t && ck_q;
    end
  end
  assign tclk_rise = rise_q && enable;
  assign tclk_fall = fall_q && enable;

  // ---- slave decode ----
  // Justification: (reg-a) port address latch: the last /AS-low clock.
  logic [15:0] pa;
  always_ff @(posedge clk) begin
    if (!as_n) pa <= ad_bus;
  end

  logic io, cs, prom, roma, romd;
  assign io   = enable && (st == ST_IO || st == ST_SPECIAL_IO) && !b_w && pa[15:8] == 8'h07;
  assign cs   = io && (pa[7:0] == 8'h00 || pa[7:0] == 8'h02);
  assign prom = io && r_w && !ds_n && (pa[7:0] == 8'h10 || pa[7:0] == 8'h12 || pa[7:0] == 8'h14);
  assign roma = io && !r_w && !ds_n && pa[7:0] == 8'h18;
  assign romd = io && r_w && !ds_n && pa[7:0] == 8'h1A;

  logic [47:0] mac_w;
  logic [15:0] prom_w;
  assign mac_w = mac_ok ? mac : MAC;
  always_comb begin
    unique case (pa[2:1])
      2'd0:    prom_w = mac_w[47:32];
      2'd1:    prom_w = mac_w[31:16];
      default: prom_w = mac_w[15:0];
    endcase
  end

  // ---- boot ROM and configuration window ----
  // Justification: (reg-a) the window address; a ROMD read in progress.
  logic [13:0] wa_q;
  logic        rd_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wa_q <= 14'd0;
      rd_q <= 1'b0;
    end else begin
      rd_q <= romd;
      if (roma)               wa_q <= ad_bus[13:0];
      else if (rd_q && !romd) wa_q <= wa_q + 14'd1;
    end
  end

  localparam int ROM_WORDS = 6144;
  logic        rom_in, rom_wa_in;
  logic [15:0] rom_q, cfg_q;
  assign rom_in    = wa_q < 14'(ROM_WORDS);
  assign rom_wa_in = rom_addr[13:1] < 13'(ROM_WORDS);
  // 2048 deep: 3 x 4 blocks; the default 8192 x 1 slicing takes 16.
  (* ramstyle = "M10K, no_rw_check", max_depth = 2048 *) logic [1:0][7:0] rom [0:ROM_WORDS-1];
  (* ramstyle = "MLAB, no_rw_check" *) logic [15:0] cfg [0:31];
  always_ff @(posedge clk) begin
    if (rom_wr && rom_wa_in && !rom_addr[0]) rom[rom_addr[13:1]][1] <= rom_data;
    if (rom_wr && rom_wa_in &&  rom_addr[0]) rom[rom_addr[13:1]][0] <= rom_data;
    rom_q <= rom[wa_q[12:0]];
  end
  always_ff @(posedge clk) begin
    if (cfg_wr) cfg[cfg_addr] <= {cfg_data[7:0], cfg_data[15:8]};
    cfg_q <= cfg[wa_q[4:0]];
  end

  logic [15:0] win_w;
  always_comb begin
    win_w = 16'hFFFF;
    if (rom_in && rom_ok) win_w = rom_q;
    else if (wa_q[13:5] == 9'h1FF && cfg_ok) win_w = cfg_q;
  end

  // ---- the chip ----
  logic [15:0] dal_o;
  logic        dal_oe, read_o, das_n_o, ale_o, pin15_o, pin16_o, pin16_oe;
  logic        hold_pd, intr_pd, ready_pd, dali_n, dalo_n, a_oe;
  logic [7:0]  a_o;
  am7990 u_chip (
    .clk(clk), .reset_n(rst_n && enable), .tclk_rise(tclk_rise), .tclk_fall(tclk_fall),
    .dal_i(ad_bus), .dal_o(dal_o), .dal_oe(dal_oe), .a_o(a_o), .a_oe(a_oe),
    .read_i(r_w), .read_o(read_o), .das_n_i(ds_n), .das_n_o(das_n_o), .ale_o(ale_o),
    .pin15_o(pin15_o), .pin16_o(pin16_o), .pin16_oe(pin16_oe),
    .hold_pd(hold_pd), .hold_i(busreq_in_n), .hlda_n(bai_n), .cs_n(!cs), .adr(pa[1]),
    .ready_n_i(!wait_n), .ready_pd(ready_pd), .intr_pd(intr_pd),
    .dali_n_o(dali_n), .dalo_n_o(dalo_n),
    .tx(tx), .tena(tena), .rclk_rise(rclk_rise), .rx(rx), .rena(rena), .clsn(clsn)
  );

  // ---- interrupt acknowledge: the strap answers when IEI is high at /DS fall ----
  // Justification: (reg-a) /DS level last clock; this acknowledge is ours.
  logic ds_q, ack_q;
  always_ff @(posedge clk) begin
    ds_q <= ds_n;
    if (ds_n)                                  ack_q <= 1'b0;
    else if (ds_q && !intack_n && iei && intr_pd && enable) ack_q <= 1'b1;
  end

  // ---- AD drivers ----
  logic slave_rd;
  assign slave_rd = cs && dal_oe && !a_oe;
  always_comb begin
    ad_out = 16'hFFFF;
    ad_oe  = 16'h0000;
    if (a_oe) begin
      ad_out = dal_o;
      ad_oe  = {16{dal_oe}};
    end else if (slave_rd) begin
      ad_out = dal_o;
      ad_oe  = 16'hFFFF;
    end else if (prom) begin
      ad_out = prom_w;
      ad_oe  = 16'hFFFF;
    end else if (romd) begin
      ad_out = win_w;
      ad_oe  = 16'hFFFF;
    end else if (ack_q && !ds_n && !intack_n) begin
      ad_out = {8'hFF, VECTOR};
      ad_oe  = 16'h00FF;
    end
  end

  assign bus_oe   = a_oe;
  assign as_n_o   = ale_o;
  assign ds_n_o   = das_n_o;
  assign r_w_o    = read_o;
  assign b_w_o    = pin15_o;
  assign mreq_n_o = !(hold_pd && !bai_n && enable);
  assign wait_pd  = cs && !ds_n && !ready_pd;
  assign st_o     = ST_DATA_MEM;
  assign a_hi_o   = a_o;
  assign busreq_n = !hold_pd;
  assign bao_n    = !enable ? bai_n : (pin16_oe ? pin16_o : 1'b1);
  assign vi_n     = !intr_pd;
  assign ieo      = iei && !intr_pd;

  logic unused_ok;
  assign unused_ok = &{1'b0, dali_n, dalo_n};
endmodule
`default_nettype wire
