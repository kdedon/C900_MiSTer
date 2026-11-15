// NON-STOCK: the CPU's CLK pin (6 MHz stock; 10, 12 and 48 MHz turbo) and
// the wait states a faster CPU needs.  Kept apart from the Y1/U14 clock tree.
//
// CLK is a train of rise and fall pulses on the master clock:
//   6 MHz:  the ZCLK edges;
//   10 MHz: edges from a phase accumulator, 2.4 master clocks apart on
//           average (spacing 3,2,3,2,2);
//   12 MHz: rises at every ZCLK edge, falls 2 master clocks later;
//   48 MHz: a rise and a fall in every master clock (the CPU takes the
//           pair as the fall, then the rise).
// Above 6 MHz each half lasts at least 2 master clocks, except at 48 MHz.
// While the status pins show an I/O, special I/O or acknowledge cycle, CLK
// falls back to the ZCLK edges, so the peripherals see stock strobes: the
// SCC and CIOs take /AS and /DS at their PCLK and need a PCLK edge between
// one cycle's /DS rise and the next one's /DS fall.  T1 opens on a fast
// rise; its fall, and the /AS rise with it, comes at a ZCLK fall at least
// 4 master clocks later, as at 6 MHz.  The selects (U56 latches the
// address while /AS is Low, one clock behind it) need that: with /AS Low
// for 2 master clocks the MMU takes /CS from the previous address.
// CLK also runs at the ZCLK edges while the bus is granted and up to the
// first ZCLK rise after it comes back: the 8716 drops /BUSREQ in its last
// cycle's T2, and a CPU that raised /BUSACK two fast clocks later would
// take the bus back in the middle of that cycle.
// The single-step circuit counts CLK cycles of the stock net; at 48 MHz it
// steps twice (unsupported).
//
// The stock board inserts no wait states on its own: /WAIT is driven only
// by the display cards (LR U13, the HR PALs), and the DRAM, the boot ROM
// and the peripherals meet 6 MHz timing without them.  Above 6 MHz this
// block drives the same /WAIT line (wire-AND, as an expansion card would)
// while the CPU owns the bus; at 6 MHz it never drives it.  The CPU
// samples /WAIT at its CLK falls from T2 on, so the line is driven from
// the CPU's own pins in the clock its cycle starts:
//   DRAM cycle (the memory port was used): until the controller's ack
//     (the read word is then on AD and taken one master clock later; a
//     write is complete, so the next cycle never meets a pending write);
//   other memory (boot ROM, unmapped, the LR CDR with its own /WAIT):
//     MEM_CLKS master clocks from the /DS fall;
//   a read at 48 MHz: one master clock past the cards' /WAIT release.
//     The CPU samples /WAIT and takes the word in that one clock, and its
//     AD is the bus capture register, a clock behind the card's word.
// At 48 MHz /MREQ is High for one master clock between cycles; the HR card
// ends a cycle only when its 24M edge sees the select (/MREQ) High.  After
// a cycle in which a card held /WAIT, CLK pauses one master clock there.
// A memory cycle with /MREQ High is never stretched: the aborted fetch
// that opens an interrupt has no data strobe and would wait forever.
// EPU transfers (ST 1110, /MREQ High) get MEM_CLKS: the APU drives AD
// from its /DS, too late for a one-clock 48 MHz T2.
// I/O-class, refresh (ST 0001) and internal (ST 0000) cycles are not
// stretched.
// The SCCs and CIOs need /DS High between two accesses to one chip for a
// recovery time (SCC 6 PCLK + 200 ns = SCC_CLKS, CIO 1000 ns = CIO_CLKS).
// A faster CPU reaches the next I/O cycle sooner, so above 6 MHz every
// cycle in that window waits until it has passed.  An instruction fetch
// always lies between two I/O cycles.
//
// An EPU store (ST 1010/1011 write) can start before the APU has its word:
// the APU holds the cards' /WAIT Low until it drives AD, but a write's
// column strobe falls with /DS and the DRAM takes AD then.  Above 6 MHz
// the column strobe is held off (cas_hold) while the cards' /WAIT is Low
// in such a cycle, and MEM_CLKS count from its release.
//
// U53 (the DRAM CAS and MUX flip-flops) is clocked by CLK on the board:
// CAS rises at the first CLK rise after /DS rises.  A CPU faster than CLK
// starts its next /DS before that, CAS never rises and the DRAM misses the
// next column strobe.  Above 6 MHz U53 is therefore clocked every master
// clock (u53_clk_rise) while the CPU drives the bus, as a speeded-up board
// would clock it from the CPU's faster clock.  The 8716 runs on the stock
// CLK and keeps the stock U53 clock: its read word is taken while _CAS is
// Low, and a fast U53 raised _CAS before that (the 8049 read FF from RAM).
//
// DMA guard.  The SCC, the CIOs and the MMU keep the select they latched at
// the last /AS rise, and the 8716 has no /AS: a DMA /DS right after an I/O,
// special I/O or acknowledge cycle reaches the chip that cycle selected
// (48 MHz: an HD status word landed in SCC WR0).  The first /AS rise with
// any other status deselects them all (U57 is off).  Until that rise the
// board does not see /BUSACK and the CPU does not see /BUSREQ.  The CPU
// samples /BUSREQ at T1, so it may still grant after an I/O cycle; it then
// sees /BUSREQ High, takes the bus back and runs its next cycle first.
//
// At 48 MHz the CPU takes /WAIT in the master clock that brings it, so it
// reaches it from a flop loaded with next clock's line: each card gives its
// own one clock ahead (wait_nx).
`default_nettype none
module c900_turbo
  import z8000_zbus_pkg::*;
#(
  parameter int MEM_CLKS = 4,
  parameter int SCC_CLKS = 58,
  parameter int CIO_CLKS = 48
) (
  input  logic       clk,
  input  logic       rst_n,
  input  logic [1:0] speed,          // 0 = 6 MHz stock, 1 = 10, 2 = 12, 3 = 48 MHz
  input  logic       zclk_rise,      // U14 QA rises now
  input  logic       zclk_fall,
  output logic       cpu_clk_rise,
  output logic       cpu_clk_fall,
  output logic       u53_clk_rise,   // U53 CLK rises now
  // the CPU's pins
  input  logic       bus_drive,
  input  logic       as_n,
  input  logic       ds_n,
  input  logic       mreq_n,
  input  logic [3:0] st,
  input  logic       r_w,
  input  logic       card_wait_n,    // /WAIT as the cards drive it
  input  logic       card_wait_nx,   // ... as they will drive it next clock
  input  logic       scc_sel,        // the bus cycle selects an SCC
  input  logic       cio_sel,        // ... a CIO
  output logic       cas_hold,       // hold the column strobe High
  // the DRAM port
  input  logic       mem_req,        // mem_rd | mem_wr
  input  logic       mem_ack,
  output logic       wait_n,
  output logic       cpu_wait_n,     // the CPU's /WAIT pin
  // bus request
  input  logic       busreq_n,       // the board's /BUSREQ
  output logic       cpu_busreq_n,
  input  logic       cpu_busack_n,
  output logic       busack_n        // the board's /BUSACK
);
  logic mem_cyc, io_cyc;
  assign mem_cyc = st[3];
  assign io_cyc  = (st[3:1] == 3'b001) || (st[3:2] == 2'b01);

  // Justification: (reg-a) master clocks since the last CLK rise, to 8,
  // and since the last CLK edge, to 3; the CLK level; the 10 MHz phase in
  // twelfths of a master clock; the bus granted, or back since the last
  // ZCLK rise.
  logic [3:0] gap_q, acc_q;
  logic [1:0] half_q;
  logic       clk_q, held_q;
  always_ff @(posedge clk) begin
    if (!rst_n)              gap_q <= 4'd0;
    else if (cpu_clk_rise)   gap_q <= 4'd1;
    else if (gap_q != 4'd8)  gap_q <= gap_q + 4'd1;
  end
  always_ff @(posedge clk) begin
    if (!rst_n)                           half_q <= 2'd0;
    else if (cpu_clk_rise | cpu_clk_fall) half_q <= 2'd1;
    else if (half_q != 2'd3)              half_q <= half_q + 2'd1;
  end
  always_ff @(posedge clk) begin
    if (!rst_n)            clk_q <= 1'b0;
    else if (cpu_clk_rise) clk_q <= 1'b1;
    else if (cpu_clk_fall) clk_q <= 1'b0;
  end
  logic held_d;
  assign held_d = !bus_drive || (held_q && !zclk_rise);
  always_ff @(posedge clk) begin
    if (!rst_n) held_q <= 1'b0;
    else        held_q <= held_d;
  end

  // Justification: (reg-a) the cards' /WAIT one clock back, as ad_q is AD;
  // /MREQ last clock; a card held /WAIT in this cycle.
  logic card_wait_q, mreq_q, card_cyc_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      card_wait_q <= 1'b1;
      mreq_q      <= 1'b1;
    end else begin
      card_wait_q <= card_wait_n;
      mreq_q      <= mreq_n;
    end
  end

  // 48 MHz: no CLK edge in the first clock /MREQ is High after a card's
  // cycle, so the card sees its select drop across a 24M rise.
  logic gap48;
  assign gap48 = mreq_n && !mreq_q && card_cyc_q;

  // 10 MHz: 5/12 of an edge per master clock, so 5 edges in 12 clocks.
  // A ZCLK edge restarts the phase, keeping the next half 2 clocks or more.
  logic acc_wrap, acc_edge;
  assign acc_wrap = acc_q >= 4'd7;
  always_ff @(posedge clk) begin
    if (!rst_n || (cpu_clk_rise | cpu_clk_fall) && !acc_edge) acc_q <= 4'd0;
    else if (acc_wrap)                                        acc_q <= acc_q - 4'd7;
    else                                                      acc_q <= acc_q + 4'd5;
  end

  logic stock, half_ok, fast_edge;
  assign stock   = io_cyc || !bus_drive || held_q;
  assign half_ok = half_q >= 2'd2;
  always_comb begin
    unique case (speed)
      2'd1:    fast_edge = acc_wrap;
      2'd2:    fast_edge = clk_q || zclk_rise || zclk_fall;
      default: fast_edge = 1'b0;
    endcase
  end
  assign acc_edge = speed == 2'd1 && !stock && fast_edge;
  always_comb begin
    if (speed == 2'd0) begin
      cpu_clk_rise = zclk_rise;
      cpu_clk_fall = zclk_fall;
    end else if (stock) begin
      cpu_clk_rise = !clk_q && zclk_rise && gap_q == 4'd8 && half_ok;
      cpu_clk_fall = clk_q && zclk_fall && gap_q >= 4'd4;
    end else if (speed == 2'd3) begin
      cpu_clk_rise = !gap48;
      cpu_clk_fall = clk_q && !gap48;
    end else begin
      cpu_clk_rise = !clk_q && fast_edge && half_ok;
      cpu_clk_fall = clk_q && fast_edge && half_ok;
    end
  end
  assign u53_clk_rise = (speed == 2'd0 || !bus_drive) ? zclk_fall : 1'b1;

  // Justification: (reg-a) cycle state since the /AS fall: strobe history,
  // in a cycle (from the /AS fall to the /DS rise), DRAM used and
  // acknowledged, master clocks since the /DS fall.
  logic       as_q, ds_q, cyc_q, dram_q, ack_q, as_fall, cyc_d, dram_d, ack_d;
  logic [2:0] mclk_q, mclk_d;
  assign as_fall = as_q && !as_n;
  assign cyc_d   = as_fall || (cyc_q && !(!ds_q && ds_n));
  assign dram_d  = !as_fall && (dram_q || mem_req);
  assign ack_d   = !as_fall && (ack_q || mem_ack);
  assign mclk_d  = (ds_n || cas_hold) ? 3'd0 : (mclk_q == 3'(MEM_CLKS)) ? mclk_q : mclk_q + 3'd1;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      as_q   <= 1'b1;
      ds_q   <= 1'b1;
      cyc_q  <= 1'b0;
      dram_q <= 1'b0;
      ack_q  <= 1'b0;
      mclk_q <= 3'd0;
    end else begin
      as_q   <= as_n;
      ds_q   <= ds_n;
      cyc_q  <= cyc_d;
      dram_q <= dram_d;
      ack_q  <= ack_d;
      mclk_q <= mclk_d;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n || (as_q && !as_n))  card_cyc_q <= 1'b0;
    else if (cyc_q && !card_wait_n) card_cyc_q <= 1'b1;
  end

  // Justification: (reg-a) the last /AS carried an I/O-class status.
  logic io_sel_q;
  always_ff @(posedge clk) begin
    if (!rst_n)                io_sel_q <= 1'b0;
    else if (!as_n && io_cyc)  io_sel_q <= 1'b1;
    else if (!as_q && as_n)    io_sel_q <= io_cyc;
  end

  logic guard;
  assign guard        = speed != 2'd0 && io_sel_q;
  assign cpu_busreq_n = busreq_n | guard;
  assign busack_n     = cpu_busack_n | guard;

  assign cas_hold = speed != 2'd0 && bus_drive && st[3:1] == 3'b101 && !r_w && !card_wait_n;

  // Justification: (reg-a) this cycle selected an SCC or a CIO; master
  // clocks of its recovery left.
  logic       rscc_q, rcio_q;
  logic [5:0] rec_q;
  always_ff @(posedge clk) begin
    if (!rst_n || (as_q && !as_n)) begin
      rscc_q <= 1'b0;
      rcio_q <= 1'b0;
    end else if (!ds_n) begin
      if (scc_sel) rscc_q <= 1'b1;
      if (cio_sel) rcio_q <= 1'b1;
    end
  end
  logic [5:0] rec_d;
  always_comb begin
    if (!ds_q && ds_n && rscc_q)                              rec_d = 6'(SCC_CLKS);
    else if (!ds_q && ds_n && rcio_q && rec_q < 6'(CIO_CLKS)) rec_d = 6'(CIO_CLKS);
    else if (rec_q != 6'd0)                                   rec_d = rec_q - 6'd1;
    else                                                      rec_d = 6'd0;
  end
  always_ff @(posedge clk) begin
    if (!rst_n) rec_q <= 6'd0;
    else        rec_q <= rec_d;
  end

  logic card_ok;
  assign card_ok = card_wait_q || speed != 2'd3 || stock || !r_w;

  // dram_q selects the ack: a DRAM request first comes with /DS Low for
  // at most one clock (a read at the row strobe, a write at the column
  // strobe), so in that clock the other term is Low too.
  logic ready;
  assign ready = card_ok && rec_q == 6'd0 && (!mem_cyc || (mreq_n && st != 4'b1110) || (dram_q ? ack_q : (!ds_n && mclk_q == 3'(MEM_CLKS))));
  assign wait_n = (speed == 2'd0) || !bus_drive || !cyc_q || ready;

  // 48 MHz: the CPU takes /WAIT in the clock it arrives, so it comes from
  // a flop.  /WAIT is loaded with next clock's line: the cards'
  // look-ahead, this block's state one clock on, the pins as now but /MREQ,
  // which falls after a T1 rise.  An aborted fetch keeps /MREQ High and
  // waits one clock more.
  logic stock_x, ready_x, wait_x;
  assign stock_x = io_cyc || !bus_drive || held_d;
  assign ready_x = (card_wait_n || stock_x || !r_w) && rec_d == 6'd0 &&
                   (!mem_cyc || (mreq_n && !(!as_n && cpu_clk_rise) && st != 4'b1110) || (dram_d ? ack_d : mclk_d == 3'(MEM_CLKS)));
  assign wait_x  = card_wait_nx && (!bus_drive || !cyc_d || ready_x);

  // Justification: (reg-b) the CPU's /WAIT at 48 MHz.
  logic wait48_q;
  always_ff @(posedge clk) begin
    if (!rst_n) wait48_q <= 1'b1;
    else        wait48_q <= wait_x;
  end
  assign cpu_wait_n = (speed == 2'd3) ? wait48_q : card_wait_n && wait_n;
endmodule
`default_nettype wire
