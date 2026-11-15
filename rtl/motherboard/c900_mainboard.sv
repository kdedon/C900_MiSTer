// C900 CPU board: Y1 + U14 clock chain, Z8001 CPU,
// Z8010 MMU U2, CIO U70 (keyboard/RTC, chain head), SCC U74, CIO U66
// (system), MOS 8716 PDMAC U79 + U80-U83 DMA address, I/O decode, U54,
// boot ROM U17/U18, DRAM, system latch, RTC U16.  The floppy controller
// (sheets 13-16) is its own module, c900_fdc.
//
// The CPU is the Z-Bus master unless it grants the bus (bus_drive Low);
// the board drives a value + per-line drive for AD and resolves its own
// control lines.  Lines nothing drives read High.
`default_nettype none
module c900_mainboard
  import z8000_zbus_pkg::*;
(
  input  logic        clk,            // 48 MHz fabric clock
  input  logic        rst_n,          // fabric power-on reset
  input  logic        s1,             // manual reset switch S1 held
  input  logic        ram_512k,
  input  logic [2:0]  ram_card,
  input  logic [1:0]  cpu_speed,

  // ZCLK (U14 QA, 6 MHz; CN9/CN11 _CLK) edges, one-master-clock pulses
  output logic        zclk_rise,
  output logic        zclk_fall,

  // backplane: AD and the resolved control lines
  input  logic [15:0] ad_bus,         // resolved AD, registered by the core
  input  logic [15:0] ad_live,        // resolved AD as the wires carry it now
  output logic [15:0] ad_out,
  output logic [15:0] ad_oe,
  output logic        ad_own,         // the CPU's transceivers drive BAD: its word wins
  output logic [15:0] dram_ad,        // the DRAM's read word (resolved with ad_out by the core)
  output logic        dram_ad_oe,
  output logic        as_n,
  output logic        ds_n,
  output logic        mreq_n,
  output logic        r_w,
  output logic        b_w,
  output logic        n_s,
  output logic [3:0]  st,
  output logic [23:0] pa,             // physical address
  output logic        io3_n,          // U57 /I-O3 to CN11 (LR SCCs)
  output logic        io4_n,          // U57 /I-O4 to CN11 (display card registers)
  output logic        sup_n,          // Z8010 /SUP (CN12)
  output logic        board_reset_n,  // -MRESET
  input  logic        wait_n,         // resolved /WAIT
  input  logic        wait_nx,        // NON-STOCK: the cards' /WAIT one clock ahead
  input  logic        vi_ext_n,       // /VI from the cards
  input  logic        nvi_ext_n,      // CN11 pin 37 _NVI from the cards
  input  logic        busreq_ext_n,   // /BUSREQ from other masters
  output logic        busreq_line_n,  // the resolved /BUSREQ line
  // a CN11 bus master: its strobes while it drives them (ext_drive), and
  // the physical address A23:16 plus AD while it holds the grant (ext_hold)
  input  logic        ext_drive,
  input  logic        ext_hold,
  input  logic        ext_as_n,
  input  logic        ext_ds_n,
  input  logic        ext_mreq_n,
  input  logic        ext_r_w,
  input  logic        ext_b_w,
  input  logic [3:0]  ext_st,
  input  logic [7:0]  ext_a_hi,
  output logic        busack_n,
  output logic        bao_n,          // 8716 /BAO: bus grant to the next master
  output logic        ieo,            // PDMAC IEO to CN11 pin 33
  input  logic        mi_n,           // multi-micro in
  output logic        mo_n,
  input  logic        stop_n,         // EPU /STOP (resolved)
  input  logic        iea,            // CN13 IEA: CIO U70 IEI (IEI through the CN13 link when no APU)

  // CN13 APU connector: the CPU's own pins, ahead of the U3-U5 buffers
  output logic        apu_clk_rise,   // CPU CLK
  output logic        apu_clk_fall,
  output logic        apu_as_n,
  output logic        apu_ds_n,
  output logic        apu_r_w,
  output logic        apu_b_w,
  output logic        apu_n_s,
  output logic [3:0]  apu_st,
  output logic [6:0]  apu_sn,
  output logic        apu_busack_n,

  // 8716 controller (B) bus: CN9 and the floppy controller
  input  logic [7:0]  bd_in,
  output logic [7:0]  bd_out,
  output logic        bd_oe,
  input  logic        pcss,
  input  logic        pcsd,
  output logic        ireq_n,
  output logic        est_n,

  // CIO U70 keyboard pins (311075 daughterboard)
  input  logic [7:0]  kbd_pa,         // PA6:0 byte, PA7 DAV
  input  logic        kbd_updown,     // PC2
  output logic        kbd_clr,        // PC3 level
  output logic        kbd_clk204,     // 311075 CN2-1: the U63 port 0x204-0x207 write clock
  output logic        kbd_bad1,       // 311075 socket pin 38 (AD1)

  // RTC crystal (rise pulse); HPS time, the battery stand-in (rtc_seed)
  input  logic        rtc_xt_rise,
  input  logic [64:0] rtc_hps,

  // SCC U74 serial lines, [0] = channel A
  input  logic [1:0]  scc_rxd,
  output logic [1:0]  scc_txd,
  input  logic [1:0]  scc_cts_n,
  input  logic [1:0]  scc_dcd_n,
  output logic [1:0]  scc_rts_n,
  output logic [1:0]  scc_dtr_n,

  // CN5 Centronics (sheet 11), connector levels
  output logic [7:0]  cn5_data,       // pins 2-9
  output logic        cn5_strobe_n,   // pin 1
  input  logic        cn5_ack_n,      // pin 10
  input  logic        cn5_busy,       // pin 11

  // CN4 IEEE-488 (sheet 10): resolved bus levels in, this board's pulls
  // out.  ctl = {SRQ, ATN, EOI, DAV, NRFD, NDAC, IFC, REN}.
  input  logic [7:0]  cn4_dio,
  input  logic [7:0]  cn4_ctl,
  output logic [7:0]  cn4_dio_pull,
  output logic [7:0]  cn4_ctl_pull,

  // CN3 speaker: U69 7407s sinking the coil current (PB0 Low)
  output logic        spk_on,

  // memory port to the platform RAM controller
  output logic [23:1] mem_addr,
  output logic        mem_rd,
  output logic        mem_wr,
  output logic [1:0]  mem_be,
  output logic [15:0] mem_wdata,
  input  logic [15:0] mem_rdata,
  input  logic        mem_rvalid,
  input  logic        mem_ack,
  output logic        mem_refresh_ok   // SDRAM refresh window (no request within 4 clocks)
`ifdef C900_DISK_DEBUG
  , output logic [55:0] dbg
`endif
);
  // ---- clock chain (sheet 2) ---------------------------------------------------
  // Y1 -> U14 74LS93 CKA, QA tied to CKB (R0 inputs Low): QA 6 MHz, QB
  // 3 MHz, QC 1.5 MHz DCLK, QD 750 kHz SNDCLK.  Every clock pin below
  // takes one-master-clock pulses at the edges of its net.
  logic y1_rise, y1_fall, qa_rise, qa_fall, qd_rise, qd_fall, cpu_clk_rise, cpu_clk_fall;

  osc12 y1_osc (.clk(clk), .ck_rise(y1_rise), .ck_fall(y1_fall));
  ls93 u14 (
    .clk(clk), .cka_fall(y1_fall), .r0_1(1'b0), .r0_2(1'b0),
    .qa_rise(qa_rise), .qa_fall(qa_fall), .qd_rise(qd_rise), .qd_fall(qd_fall)
  );
  // CLK: U13 inverts QA (CLK rises when QA falls); it clocks U53 and is
  // PCLK of CIO U70 and SCC U74 (sheets 5, 11, 12).  ZCLK: QA through the
  // U15 H3006A driver to the Z8001 and Z8010 CLK pins (one net).
  assign zclk_rise = qa_rise;
  assign zclk_fall = qa_fall;

  // Power-on reset (sheet 6): U59 NE556 section 2 pulls both _MRESET and
  // _PRESET Low at power-on; the core's reset is that power-on.  _PRESET
  // gates the buffered strobes Low (U11, sheet 1), which is how the board
  // resets the SCCs and CIOs: /AS and /DS Low together.
  logic preset_n;
  assign preset_n = rst_n;

  // ---- CPU ----------------------------------------------------------------
  logic [15:0] cpu_ad_out;
  logic        cpu_ad_drive, cpu_bus_drive;
  logic [6:0]  cpu_sn;
  logic        cpu_as_n, cpu_ds_n, cpu_mreq_n, cpu_r_w, cpu_b_w, cpu_n_s;
  logic [3:0]  cpu_st;
  logic        segt_n, vi_n, nvi_n, busreq_n, cpu_busreq_n, cpu_busack_n;

  // NON-STOCK: the CPU's CLK pin edges (stock: the ZCLK edges).
  // NON-STOCK: above 6 MHz it also drives /WAIT (wire-AND with the cards'),
  // the stock board drives none of its own.
  // NON-STOCK: above 6 MHz it holds a grant back after an I/O-class cycle.
  // NON-STOCK: at 48 MHz it drives the CPU's /WAIT from a flop.
  logic turbo_wait_n, wait_line_n, cpu_wait_n, u53_clk_rise, cas_hold, scc_sel, cio_sel;
  c900_turbo u_turbo (
    .clk(clk), .rst_n(rst_n), .speed(cpu_speed), .zclk_rise(qa_rise), .zclk_fall(qa_fall),
    .cpu_clk_rise(cpu_clk_rise), .cpu_clk_fall(cpu_clk_fall), .u53_clk_rise(u53_clk_rise),
    .bus_drive(cpu_bus_drive), .as_n(cpu_as_n), .ds_n(cpu_ds_n), .mreq_n(cpu_mreq_n), .st(cpu_st),
    .r_w(cpu_r_w), .card_wait_n(wait_n), .card_wait_nx(wait_nx), .cas_hold(cas_hold),
    .scc_sel(scc_sel), .cio_sel(cio_sel),
    .mem_req(mem_rd | mem_wr), .mem_ack(mem_ack), .wait_n(turbo_wait_n),
    .cpu_wait_n(cpu_wait_n),
    .busreq_n(busreq_n), .cpu_busreq_n(cpu_busreq_n), .cpu_busack_n(cpu_busack_n), .busack_n(busack_n)
  );
  assign wait_line_n = wait_n & turbo_wait_n;

  z8000_cpu #(.SEGMENTED(1'b1), .VMPU(1'b0)) u1_cpu (
    .clk(clk), .clk_rise(cpu_clk_rise), .clk_fall(cpu_clk_fall), .reset_n(board_reset_n),
    .ad_in(ad_bus), .stop_n(stop_n), .wait_n(cpu_wait_n), .busreq_n(cpu_busreq_n),
    .nmi_n(1'b1), .nvi_n(nvi_n), .vi_n(vi_n), .segt_n(segt_n), .abort_n(1'b1), .mi_n(mi_n),
    .ad_out(cpu_ad_out), .ad_drive(cpu_ad_drive), .bus_drive(cpu_bus_drive), .sn(cpu_sn),
    .as_n(cpu_as_n), .ds_n(cpu_ds_n), .mreq_n(cpu_mreq_n), .r_w(cpu_r_w), .b_w(cpu_b_w),
    .n_s(cpu_n_s), .st(cpu_st), .busack_n(cpu_busack_n), .mo_n(mo_n)
  );

  assign apu_clk_rise = cpu_clk_rise;
  assign apu_clk_fall = cpu_clk_fall;
  assign {apu_as_n, apu_ds_n, apu_r_w, apu_b_w, apu_n_s} = {cpu_as_n, cpu_ds_n, cpu_r_w, cpu_b_w, cpu_n_s};
  assign apu_st       = cpu_st;
  assign apu_sn       = cpu_sn;
  assign apu_busack_n = cpu_busack_n;

  // ---- interrupt daisy chain: CIO U70 -> SCC U74 -> CIO U66 -> PDMAC --------
  logic cio1_int_n, cio1_ieo, scc_int_n, scc_ieo, cio2_int_n, cio2_ieo;

  // ---- 8716 PDMAC + U80-U83 ------------------------------------------------
  logic [15:0] dma_ad_out;
  logic        dma_ad_oe, dma_mreq_n, dma_mreq_oe, dma_ds_n, dma_ds_oe;
  logic        dma_busreq_n, dma_bao_n, dma_vi_n, dma_ieo_n, dmaen_n;
  logic        ld0, ld1_rise, ld1_fall, ld2_rise, ld2_fall, clkadr_rise, clkadr_fall, dma_dir;
  logic [22:0] dma_wa;
  logic        io6, intack_n;

  // Control lines: the CPU while it holds the bus, else the 8716's
  // three-state /MREQ and /DS.  While /DMAEN is Low, U84 drives ST, /NOMMU
  // and BB/W (word) and U80 Q7 (DIR, 1 = memory read) drives BR/W (sheet
  // 18).  ST during DMA: SP reads 1000 (data memory), the Design Review
  // says 0100; 1000 is used.  N/S and /AS are
  // undriven during DMA and read High.
  // as_w/ds_w: the strobes on the CPU side of U5 (the CPU and MMU pins);
  // the buffered bus carries them ANDed with _PRESET (U11).
  logic       as_w, ds_w, mreq_w, r_w_w, b_w_w, n_s_w;
  logic [3:0] st_w;
  logic       m_as_w, m_ds_w, m_r_w_w;      // the MMU's pins: no CN11 master
  logic [3:0] m_st_w;
  logic [6:0] sn_q;                  // SN as the bus shows it, for the benches
  logic       a7;                    // A7 on the A bus, for the CS1 pins
  logic [23:0] pa_w;                 // the A bus at the MMU and U54
  // A CN11 master (the LANCE card) drives the buffered side; the MMU on
  // the CPU side does not see it.
  assign m_as_w  = cpu_bus_drive ? cpu_as_n   : 1'b1;
  assign m_ds_w  = cpu_bus_drive ? cpu_ds_n   : (dma_ds_oe   ? dma_ds_n   : 1'b1);
  assign m_r_w_w = cpu_bus_drive ? cpu_r_w    : (dmaen_n ? 1'b1 : dma_dir);
  assign m_st_w  = cpu_bus_drive ? cpu_st     : (dmaen_n ? 4'hF : ST_DATA_MEM);
  assign as_w   = cpu_bus_drive ? cpu_as_n   : (ext_drive ? ext_as_n : 1'b1);
  assign ds_w   = cpu_bus_drive || dma_ds_oe || !ext_drive ? m_ds_w : ext_ds_n;
  assign mreq_w = cpu_bus_drive ? cpu_mreq_n : (dma_mreq_oe ? dma_mreq_n : ext_mreq_n);
  assign r_w_w  = cpu_bus_drive || !dmaen_n || !ext_drive ? m_r_w_w : ext_r_w;
  assign b_w_w  = cpu_bus_drive ? cpu_b_w    : (!dmaen_n ? 1'b0 : (ext_drive ? ext_b_w : 1'b1));
  assign n_s_w  = cpu_bus_drive ? cpu_n_s    : 1'b1;
  assign st_w   = cpu_bus_drive || !dmaen_n || !ext_drive ? m_st_w : ext_st;

  // The bus as every chip sees it: the control lines are registered in the
  // same fabric clock as the AD capture register (c900_core ad_q), so each
  // chip samples a coherent bus, one fabric clock (20.8 ns) behind the
  // drivers.  The CPU alone reads AD from that register directly.  The A
  // bus and _SUP reach the cards the same way (the Z8010A drives them 70 to
  // 90 ns after the /AS edges); U54, the ROMs and the DRAM take them live.
  always_ff @(posedge clk) begin
    {as_n, ds_n} <= {as_w & preset_n, ds_w & preset_n};
    pa    <= pa_w;
    sup_n <= mmu_sup_n;
    a7 <= pa_w[7];
    if (!rst_n) begin
      {mreq_n, r_w, b_w, n_s} <= 4'b1111;
      st   <= 4'hF;
      sn_q <= 7'h7F;
    end else begin
      {mreq_n, r_w, b_w, n_s} <= {mreq_w, r_w_w, b_w_w, n_s_w};
      st   <= st_w;
      sn_q <= cpu_sn;
    end
  end

  assign intack_n = ~(st == ST_VI_ACK);

  pdmac u79_pdmac (
    .clk(clk),
    .ad_in(ad_bus), .ad_out(dma_ad_out), .ad_oe(dma_ad_oe),
    .wait_n(wait_line_n), .clk_pin_rise(qa_rise), .clk_pin_fall(qa_fall), .bai_n(busack_n), .iack_n(intack_n), .iei(cio2_ieo),
    .io6(io6), .ds_n_in(ds_n),
    .mreq_n(dma_mreq_n), .mreq_oe(dma_mreq_oe), .ds_n(dma_ds_n), .ds_oe(dma_ds_oe),
    .busreq_n(dma_busreq_n), .bao_n(dma_bao_n), .vi_n(dma_vi_n), .ieo_n(dma_ieo_n), .dmaen_n(dmaen_n),
    .bd_in(bd_in), .bd_out(bd_out), .bd_oe(bd_oe), .pcss(pcss), .pcsd(pcsd),
    .reset_n(board_reset_n), .ireq_n(ireq_n), .ld0(ld0),
    .ld1_rise(ld1_rise), .ld1_fall(ld1_fall), .ld2_rise(ld2_rise), .ld2_fall(ld2_fall),
    .clkadr_rise(clkadr_rise), .clkadr_fall(clkadr_fall), .est_n(est_n)
  );
  assign ieo   = ~dma_ieo_n;
  assign bao_n = dma_bao_n;

  // U80-U83 take OMAD as the 8716 sampled it in the clock it drove the LD
  // and CLKADR edges (its pins are registered: they change one clock after
  // the sample); the byte stays on OMAD past the strobe on the board (the
  // 8723 holds BUFFEN- a sample longer, U5 follows the 8049's RD-/WR-).
  logic [7:0] bd_8716_q;
  always_ff @(posedge clk) begin
    if (!rst_n) bd_8716_q <= 8'hFF;
    else        bd_8716_q <= bd_in;
  end

  dma_addr u80_u83 (
    .clk(clk), .bd_in(bd_8716_q), .ld0(ld0), .ld1(ld1_rise), .ld2(ld2_rise),
    .clkadr_rise(clkadr_rise), .clkadr_fall(clkadr_fall), .wa(dma_wa), .dir(dma_dir)
  );

  assign busreq_n = dma_busreq_n & busreq_ext_n;
  assign busreq_line_n = busreq_n;

  // ---- I/O decode ---------------------------------------------------------
  logic [15:0] adr;
  logic [7:0]  io_n;
  logic        mmu_cs_n;

  c900_iodecode u56_u57_u58 (
    .clk(clk), .rst_n(rst_n), .mreset_n(board_reset_n), .ad(ad_bus), .as_n(as_n), .ds_n(ds_n),
    .r_w(r_w), .st(st),
    .adr(adr), .io_n(io_n), .mmu_cs_n(mmu_cs_n), .io6(io6)
  );
  // SCC U74, the LR card's U31/U36; CIOs U70, U66.
  assign scc_sel = (!io_n[1] && !a7) || !io_n[3];
  assign cio_sel = !io_n[0];

  // ---- MMU and the physical address ---------------------------------------
  logic [15:0] mmu_pa;               // A23..A8
  logic        mmu_pa_drive, mmu_sup_n;
  logic [7:0]  mmu_data;             // AD15..AD8
  logic [7:0]  mmu_data_drive;
  // The MMU's pins are on the wires (AD, SN, ST and the strobes as driven
  // now), not on the registered copy of the bus.  Its AD pins are on the
  // CPU side of the U3/U4 transceivers: the CPU's word while it drives,
  // else the buffered bus coming back through them.
  logic [15:0] mmu_ad;
  assign mmu_ad = ad_own ? cpu_ad_out : ad_bus;
  // CLK is the Z8001's net (U1.35, U2.36).  The Z8010 takes the offset
  // and status at its /AS rise (data sheet p.571).

  z8010_mmu u2_mmu (
    .clk(clk), .clk_in(cpu_clk_rise), .reset_n(board_reset_n),
    .ad(mmu_ad[15:8]), .sn(cpu_sn), .st(m_st_w), .as_n(m_as_w), .ds_n(m_ds_w), .r_w(m_r_w_w), .n_s(n_s_w),
    .cs_n(mmu_cs_n), .dmasync(1'b0),
    .pa(mmu_pa), .pa_drive(mmu_pa_drive), .segt_n(segt_n), .sup_n(mmu_sup_n),
    .data(mmu_data), .data_drive(mmu_data_drive)
  );

  // A23:A10 from the MMU, A9:A8 bypass the MMU from the address latch while
  // the CPU owns the bus (1 KB granularity), A7:A0 from the latch.  During
  // DMA the U80-U83 word address.  The latch is on the CPU side of the
  // transceivers, as the MMU's AD pins: transparent while /AS is Low, it
  // holds the offset from the /AS rise (with a CPU above 6 MHz the row
  // strobe can follow the /AS rise in the next master clock).
  logic [9:0] a_lo_q, a_lo;
  always_ff @(posedge clk) begin
    if (!rst_n)       a_lo_q <= 10'h000;
    else if (!m_as_w) a_lo_q <= mmu_ad[9:0];
  end
  assign a_lo = m_as_w ? a_lo_q : mmu_ad[9:0];
  // A CN11 master's A15:A0 come from its multiplexed AD, latched while its
  // /AS is Low, as the board latches the CPU's.
  logic [15:0] ext_a_q, ext_a;
  always_ff @(posedge clk) begin
    if (!rst_n)                     ext_a_q <= 16'h0000;
    else if (ext_drive && !ext_as_n) ext_a_q <= ad_bus;
  end
  assign ext_a = (ext_drive && !ext_as_n) ? ad_bus : ext_a_q;
  always_comb begin
    if (!dmaen_n)            pa_w = {dma_wa, 1'b0};
    else if (ext_hold)       pa_w = {ext_a_hi, ext_a};
    else if (mmu_pa_drive)   pa_w = {mmu_pa[15:2], a_lo};
    else                     pa_w = {14'h3FFF, a_lo};
  end

  // ---- U54, boot ROM, DRAM -------------------------------------------------
  logic ras0_n, cas0l_n, cas0h_n, ras1_n, cas1l_n, cas1h_n, romcs_n, ma8;
  logic ras2_n, cas2l_n, cas2h_n;
  logic rfsh_n, nommu_n, cas_ff, cas_n_q, mux;

  // U54 inputs (sheet 5): A18 (i0), A17 (i1), A16 (i2), A19-A23, A0, _RFSH
  // (U58, status 0001), _BMREQ (buffered /MREQ), BR/W, BB/W, _CAS and MUX
  // from U53, _NOMMU (Low while the 8716 drives the address).  Which of
  // A16/A17/A18 sits on i0/i1/i2 is undetermined; the ROM select needs A16
  // and A17 Low either way, and MA8 does not reach the SDRAM-backed banks.
  assign rfsh_n  = ~(st_w == ST_REFRESH);
  assign nommu_n = dmaen_n & ~ext_hold;

  // U53 74S74, CLK = U13 inverted QA.  A: D = /CLR = _BDS, /PRE = _SUP:
  // _CAS falls with _BDS and rises on the first CLK rise after _BDS rises;
  // _SUP Low holds it High.  B: D = _BMREQ, MUX = /Q: the column address
  // from the first CLK rise after _BMREQ falls.
  // The 8716 drops _BDS on the same CLK edge that clocks U53 (its chained
  // cycles hold /DS High from one CLK fall to the next), so U53 takes the
  // High and _CAS rises until the 8716's /DS fall reaches /CLR: a short
  // _CAS High that precharges the column strobe between the DMA words.
  // cas_clk_q keeps that High for one fabric clock.
  // NON-STOCK: above 6 MHz cas_hold keeps _CAS High through an EPU store's
  // wait (c900_turbo).
  logic clk_rise, cas_clk_q;
  assign clk_rise = u53_clk_rise;   // stock: CLK rise = QA fall
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cas_ff    <= 1'b1;
      cas_clk_q <= 1'b0;
      mux       <= 1'b0;
    end else begin
      if (!mmu_sup_n)       cas_ff <= 1'b1;
      else if (!ds_w && !cas_hold) cas_ff <= 1'b0;
      else if (clk_rise)    cas_ff <= 1'b1;
      cas_clk_q <= clk_rise & ds_w;
      if (clk_rise)         mux    <= ~mreq_w;
    end
  end
  // The asynchronous clear and preset act at once (the clear after the
  // CLK edge that clocked a High); preset wins when both are Low (both
  // 74S74 outputs High).
  assign cas_n_q = ~mmu_sup_n | ((ds_w | cas_clk_q | cas_hold) & cas_ff);

  c900_u54_fpla u54 (
    .mux_col_bit(pa_w[18]), .a17(pa_w[17]), .mux_row_bit(pa_w[16]), .a19(pa_w[19]), .a20(pa_w[20]),
    .a21(pa_w[21]), .a22(pa_w[22]), .a23(pa_w[23]), .a0(pa_w[0]),
    .ras_timing(rfsh_n), .ras_enable(mreq_w), .rom_enable(r_w_w), .cas_timing(b_w_w),
    .cas13(cas_n_q), .ras14(nommu_n), .mux_sel(mux),
    .ras0_n(ras0_n), .cas0l_n(cas0l_n), .cas0h_n(cas0h_n), .ras1_n(ras1_n),
    .cas1l_n(cas1l_n), .cas1h_n(cas1h_n), .romcs_n(romcs_n), .ma8(ma8)
  );

  // NON-STOCK RAM card on the expansion bus.
  c900_ramcard u_ramcard (
    .size(ram_card),
    .a23_16(pa_w[23:16]), .a0(pa_w[0]), .ras_timing(rfsh_n), .ras_enable(mreq_w),
    .cas_timing(b_w_w), .cas13(cas_n_q), .ras14(nommu_n),
    .ras_n(ras2_n), .casl_n(cas2l_n), .cash_n(cas2h_n)
  );

  // Boot ROM U17 (D15:D8) and U18 (D7:D0): held with the DRAM (c900_dram).
  logic rom_oe;
  assign rom_oe = ~romcs_n & ~ds_w & r_w_w;

  logic [15:0] dram_d_out;
  logic        dram_d_oe;

  c900_dram u_dram (
    .clk(clk), .rst_n(rst_n), .ram_512k(ram_512k), .card_fit(ram_card != 3'd0), .pa(pa_w),
    .ras0_n(ras0_n), .cas0l_n(cas0l_n), .cas0h_n(cas0h_n), .ras1_n(ras1_n),
    .cas1l_n(cas1l_n), .cas1h_n(cas1h_n), .ras2_n(ras2_n), .cas2l_n(cas2l_n),
    .cas2h_n(cas2h_n), .romcs_n(romcs_n), .rom_oe(rom_oe), .as_n(as_w), .rfsh_n(rfsh_n),
    .we_n(r_w_w), .d_in(ad_live),
    .d_out(dram_d_out), .d_oe(dram_d_oe),
    .mem_addr(mem_addr), .mem_rd(mem_rd), .mem_wr(mem_wr), .mem_be(mem_be),
    .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_rvalid(mem_rvalid), .mem_ack(mem_ack)
  );
  logic mem_rd_idle;
  assign mem_rd_idle = ~mem_rd & ~mem_wr;


  // SDRAM refresh window, with no request outstanding, and all of reset.
  // Each request must come 4 or more clocks after a window clock.  At
  // 6 MHz the CPU requests a read 5 clocks after a ZCLK rise pulse (its
  // /MREQ falls at T1's CLK fall) and a write 7 (/DS at T2's fall): window
  // in the pulse clock and the one after.  The 8716 requests a read 1 clock
  // after the pulse and a write 7: window 2 and 3 clocks after, while the
  // bus is granted.
  logic [2:0] rise_dly_q;
  always_ff @(posedge clk) begin
    if (!rst_n) rise_dly_q <= 3'b000;
    else        rise_dly_q <= {rise_dly_q[1:0], qa_rise};
  end
  assign mem_refresh_ok = (~rst_n | (busack_n ? qa_rise | rise_dly_q[0] : rise_dly_q[1] | rise_dly_q[2]))
                          & mem_rd_idle;

  // ---- CIO U70: keyboard, RTC, Centronics status ---------------------------
  logic [7:0] cio1_ad_out, cio1_pa_out, cio1_pa_oe, cio1_pb_out, cio1_pb_oe;
  logic [3:0] cio1_pc_out, cio1_pc_oe;
  logic       cio1_ad_drive;
  logic [7:0] cio1_pa_pin, cio1_pb_pin;
  logic [3:0] cio1_pc_pin;
  logic [3:0] rtc_d_out;
  logic       rtc_d_oe, rtc_busy_n;

  // Pin level: the CIO where it drives, else the outside world: the
  // keyboard, the RTC, and BUSY through U73 13->12.  The pins are registered: the
  // CIO samples its port inputs combinationally, so an unregistered pin
  // would close a loop through its own output stage.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cio1_pa_pin <= 8'hFF;
      cio1_pb_pin <= 8'hFF;
      cio1_pc_pin <= 4'hF;
    end else begin
      cio1_pa_pin <= (cio1_pa_oe & cio1_pa_out) | (~cio1_pa_oe & kbd_pa);
      cio1_pb_pin <= (cio1_pb_oe & cio1_pb_out) |
                     (~cio1_pb_oe & {4'hF, rtc_d_oe ? rtc_d_out : 4'hF});
      cio1_pc_pin <= (cio1_pc_oe & cio1_pc_out) |
                     (~cio1_pc_oe & {1'b1, kbd_updown, 1'b1, cn5_busy});
    end
  end
  assign kbd_clr = cio1_pc_pin[3];

  // U63 NAND(SS_WR, A2), the system latch's REN clock, also clocks the
  // 311075 keyboard enable (bit 1 of a write to 0x205).
  assign kbd_clk204 = ~(~io_n[2] & ~ds_n & adr[2]);
  assign kbd_bad1   = ad_bus[1];
  // U72/U73 7407s, open collector with pull-ups: CN5 data follows the pins.
  assign cn5_data = cio1_pb_pin;

  z8036_cio u70_cio1 (
    .clk(clk),
    .ad_in(ad_bus[7:0]), .as_n(as_n), .ds_n(ds_n), .r_w(r_w), .cs0_n(io_n[0]), .cs1(~a7),   // LS04
    .intack_n(intack_n), .iei(iea), .pclk_fall(qa_rise),
    .pa_in(cio1_pa_pin), .pb_in(cio1_pb_pin), .pc_in(cio1_pc_pin),
    .ad_out(cio1_ad_out), .ad_drive(cio1_ad_drive), .int_n(cio1_int_n), .ieo(cio1_ieo),
    .pa_out(cio1_pa_out), .pa_oe(cio1_pa_oe),
    .pb_out(cio1_pb_out), .pb_oe(cio1_pb_oe),
    .pc_out(cio1_pc_out), .pc_oe(cio1_pc_oe)
  );

  // CS1 = NOT PC1 (U63), CS2 = the battery rail.  While the board is in
  // reset the seed owns the pins instead (NON-STOCK).
  logic       seed_on, seed_cs1, seed_stop, seed_aw, seed_wr;
  logic [3:0] seed_d;
  rtc_seed u_rtc_seed (
    .clk(clk), .mreset_n(board_reset_n), .rtc(rtc_hps), .active(seed_on), .d(seed_d),
    .cs1(seed_cs1), .stop(seed_stop), .addr_write(seed_aw), .write(seed_wr)
  );

  msm58321 u16_rtc (
    .clk(clk),
    .cs1(seed_on ? seed_cs1 : ~cio1_pc_pin[1]), .cs2(1'b1),
    .read(seed_on ? 1'b0 : cio1_pb_pin[4]), .write(seed_on ? seed_wr : cio1_pb_pin[5]),
    .addr_write(seed_on ? seed_aw : cio1_pb_pin[6]), .stop(seed_on ? seed_stop : cio1_pb_pin[7]),
    .test(1'b0), .xt_rise(rtc_xt_rise),
    .d_in(seed_on ? seed_d : cio1_pb_pin[3:0]), .d_out(rtc_d_out), .d_oe(rtc_d_oe), .busy_n(rtc_busy_n)
  );

  // ---- SCC U74 ----------------------------------------------------------------
  logic [7:0] scc_ad_out;
  logic       scc_ad_drive;
  logic [1:0] scc_trxc_out, scc_trxc_drive, scc_sync_out, scc_sync_drive;

  // /RTxCA and /RTxCB = CLK (sheet 12, no baud crystal); /TRxC pins go to
  // the MC1488 drivers only (inputs read High); /SYNC = DSR through the
  // MC1489, not brought out here (High).
  z8030_scc u74_scc (
    .clk(clk),
    .ad_in(ad_bus[7:0]), .as_n(as_n), .ds_n(ds_n), .r_w(r_w), .cs0_n(io_n[1]), .cs1(~a7),   // LS27
    .intack_n(intack_n), .iei(cio1_ieo), .pclk_rise(qa_fall),
    .rxd(scc_rxd), .cts_n(scc_cts_n), .dcd_n(scc_dcd_n),
    .trxc_rise(2'b00), .trxc_fall(2'b00), .rxc_rise({2{qa_fall}}), .rxc_fall({2{qa_rise}}),
    .sync_in(2'b11),
    .ad_out(scc_ad_out), .ad_drive(scc_ad_drive), .int_n(scc_int_n), .ieo(scc_ieo),
    .txd(scc_txd), .rts_n(scc_rts_n), .dtr_n(scc_dtr_n),
    .trxc_out(scc_trxc_out), .trxc_drive(scc_trxc_drive),
    .sync_out(scc_sync_out), .sync_drive(scc_sync_drive)
  );

  // ---- CIO U66: system (IEEE-488 / Centronics / sound) --------------------------
  logic [7:0] cio2_ad_out, cio2_pa_out, cio2_pa_oe, cio2_pb_out, cio2_pb_oe;
  logic [3:0] cio2_pc_out, cio2_pc_oe;
  logic       cio2_ad_drive;
  logic [7:0] cio2_pa_pin, cio2_pb_pin;
  logic [3:0] cio2_pc_pin;

  // U67 (data) and U68 (control) between U66 and CN4.  TE = PC1 to both,
  // DC = PC2 to U68, PE of U67 = GND; REN comes from the system latch.
  logic [7:0] u67_term_out, u67_drv_hi, u68_term_in, u68_term_out, u68_term_oe;
  logic       u67_term_oe;
  logic       ieee_ren;

  sn75160 u67 (
    .te(cio2_pc_pin[1]), .pe(1'b0), .term_in(cio2_pa_pin), .bus_in(cn4_dio),
    .bus_pull(cn4_dio_pull), .bus_drv_hi(u67_drv_hi), .term_out(u67_term_out), .term_oe(u67_term_oe)
  );
  // {SRQ, ATN, EOI, DAV, NRFD, NDAC, IFC, REN} <- PB2, PB3, PB5, PB4, PB7, PB6, PC0, REN
  assign u68_term_in = {cio2_pb_pin[2], cio2_pb_pin[3], cio2_pb_pin[5], cio2_pb_pin[4],
                        cio2_pb_pin[7], cio2_pb_pin[6], cio2_pc_pin[0], ieee_ren};
  sn75161 u68 (
    .te(cio2_pc_pin[1]), .dc(cio2_pc_pin[2]), .term_in(u68_term_in), .bus_in(cn4_ctl),
    .bus_pull(cn4_ctl_pull), .term_out(u68_term_out), .term_oe(u68_term_oe)
  );

  // U66 pins, registered as for U70.  Undriven by both ends a line reads
  // High.  PB0 = SND, PB1 = _CACK (U73 1->2 from CN5.10), PC3 = _CDS.
  logic [7:0] ieee_pa, ieee_pb;
  logic       ieee_pc0;
  assign ieee_pa  = u67_term_oe ? u67_term_out : 8'hFF;
  assign ieee_pb  = {u68_term_oe[3] ? u68_term_out[3] : 1'b1,   // PB7 NRFD
                     u68_term_oe[2] ? u68_term_out[2] : 1'b1,   // PB6 NDAC
                     u68_term_oe[5] ? u68_term_out[5] : 1'b1,   // PB5 EOI
                     u68_term_oe[4] ? u68_term_out[4] : 1'b1,   // PB4 DAV
                     u68_term_oe[6] ? u68_term_out[6] : 1'b1,   // PB3 ATN
                     u68_term_oe[7] ? u68_term_out[7] : 1'b1,   // PB2 SRQ
                     cn5_ack_n, 1'b1};
  assign ieee_pc0 = u68_term_oe[1] ? u68_term_out[1] : 1'b1;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cio2_pa_pin <= 8'hFF;
      cio2_pb_pin <= 8'hFF;
      cio2_pc_pin <= 4'hF;
    end else begin
      cio2_pa_pin <= (cio2_pa_oe & cio2_pa_out) | (~cio2_pa_oe & ieee_pa);
      cio2_pb_pin <= (cio2_pb_oe & cio2_pb_out) | (~cio2_pb_oe & ieee_pb);
      cio2_pc_pin <= (cio2_pc_oe & cio2_pc_out) | (~cio2_pc_oe & {3'b111, ieee_pc0});
    end
  end
  assign cn5_strobe_n = cio2_pc_pin[3];   // U73 3->4
  assign spk_on       = ~cio2_pb_pin[0];  // U69, three sections in parallel

  z8036_cio u66_cio2 (
    .clk(clk),
    .ad_in(ad_bus[7:0]), .as_n(as_n), .ds_n(ds_n), .r_w(r_w), .cs0_n(io_n[0]), .cs1(a7),
    .intack_n(intack_n), .iei(scc_ieo), .pclk_fall(qd_fall),
    .pa_in(cio2_pa_pin), .pb_in(cio2_pb_pin), .pc_in(cio2_pc_pin),
    .ad_out(cio2_ad_out), .ad_drive(cio2_ad_drive), .int_n(cio2_int_n), .ieo(cio2_ieo),
    .pa_out(cio2_pa_out), .pa_oe(cio2_pa_oe),
    .pb_out(cio2_pb_out), .pb_oe(cio2_pb_oe),
    .pc_out(cio2_pc_out), .pc_oe(cio2_pc_oe)
  );

  // ---- system latch + single step ---------------------------------------------
  // CLK (U13) is inverted QA; _NVIACK and _IF1 are U58 status decodes.
  logic ss_step, u62_nvi_n;

  c900_syslatch u_syslatch (
    .clk(clk), .io2_n(io_n[2]), .bds_n(ds_n), .a1(adr[1]), .a2(adr[2]), .bad8(ad_bus[8]),
    .mreset_n(board_reset_n), .nviack_n(st != ST_NVI_ACK), .bas_n(as_n),
    .clk_pin_rise(qa_fall), .clk_pin_fall(qa_rise), .if1_n(st != ST_INSTR_FETCH_FIRST),
    .step(ss_step), .ren(ieee_ren), .nvi_n(u62_nvi_n)
  );
  // _NVI net: U62 /Q2 (sheet 6) and CN11 pin 37 (sheet 19), wired AND.
  assign nvi_n = u62_nvi_n & nvi_ext_n;

  // _MRESET (sheet 6): U60 wire-ORs U59 OUT1 (S1) and OUT2 (power-on, the
  // core reset).  S1 reaches TRG1 through C86, so a press fires section 1
  // once however long it is held; OUT1 then stays High for 1.1 x R23 x C87.
  localparam int U59_CLKS = 26_928_000;   // 1.1 x 510K x 1uF = 0.561 s at 48 MHz
  // Justification: (reg-a) S1 last clock; OUT1 and its timing count.
  logic        s1_q, out1_q;
  logic [24:0] u59_cnt_q;
  // S1 held through power-on is no press.
  always_ff @(posedge clk) begin
    if (!rst_n) s1_q <= 1'b1;
    else        s1_q <= s1;
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      out1_q    <= 1'b0;
      u59_cnt_q <= 25'd0;
    end else if (out1_q) begin
      out1_q    <= u59_cnt_q != 25'd1;
      u59_cnt_q <= u59_cnt_q - 25'd1;
    end else if (s1 && !s1_q) begin
      out1_q    <= 1'b1;
      u59_cnt_q <= 25'(U59_CLKS);
    end
  end
  assign board_reset_n = rst_n & ~out1_q;

  assign vi_n = cio1_int_n & scc_int_n & cio2_int_n & dma_vi_n & vi_ext_n;

  // ---- AD drive: per line, wired (a line driven by several reads Low if any
  // driver drives Low) -----------------------------------------------------------
  logic [15:0] dma_oe, mmu_oe, per_oe;
  logic [15:0] per_val;

  assign dma_oe    = {16{dma_ad_oe}};
  assign mmu_oe    = {mmu_data_drive, 8'h00};
  assign per_oe    = {8'h00, {8{cio1_ad_drive | scc_ad_drive | cio2_ad_drive}}};
  assign per_val   = {8'hFF, (cio1_ad_drive ? cio1_ad_out : 8'hFF) &
                             (scc_ad_drive  ? scc_ad_out  : 8'hFF) &
                             (cio2_ad_drive ? cio2_ad_out : 8'hFF)};

  // U3/U4 transceivers: while the CPU drives AD (address, write data) the
  // buffered bus carries its word; a responder still releasing the bus
  // after /DS rose (the chips see the registered bus one clock late) is
  // overridden, as the transceiver overrides a floating responder on the
  // board.
  assign ad_own = cpu_ad_drive & cpu_bus_drive;
  assign ad_oe  = ad_own ? 16'hFFFF : (dma_oe | mmu_oe | per_oe);
  assign ad_out = ad_own ? cpu_ad_out :
                  (dma_oe    & dma_ad_out | ~dma_oe)    &
                  (mmu_oe    & {mmu_data, 8'hFF} | ~mmu_oe) &
                  per_val;
  // The DRAM's and the ROM's word leaves separately: it comes from the SDRAM controller's
  // falling-edge capture, a half-cycle path to the AD register, so the core
  // resolves it last.
  assign dram_ad    = dram_d_out;
  assign dram_ad_oe = dram_d_oe & ~ad_own;

  assign io3_n = io_n[3];
  assign io4_n = io_n[4];

`ifdef C900_DISK_DEBUG
  assign dbg = {dma_wa, vi_n, nvi_n, r_w_w, ds_w, dmaen_n, st_w, as_w, mmu_ad, cpu_sn};
`endif

  // Outputs not consumed yet: kept visible to lint as one sink.
  logic unused_ok;
  assign unused_ok = &{1'b0, y1_rise, qd_rise, ld1_fall, ld2_fall, ma8, rtc_busy_n,
                       scc_trxc_out, scc_trxc_drive,
                       scc_sync_out, scc_sync_drive, ss_step, u67_drv_hi, u68_term_out[0], u68_term_oe[0], io_n[7:5],
                       adr[15:3], adr[0], mmu_pa[1:0], sn_q, mmu_ad[15:10]};
endmodule
`default_nettype wire
