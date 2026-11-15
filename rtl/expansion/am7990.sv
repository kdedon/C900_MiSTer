// AMD Am7990 LANCE.  Pins only; three-state pins split into _i/_o/_oe,
// open-drain outputs as a pull-low bit _pd.  TCLK is the chip clock:
// tclk_rise/tclk_fall are one-clock pulses at its edges, as rclk_rise is
// for RCLK.
//
// Host side: RAP/RDP select CSR0-3.  The ring sequencer reads the
// 12-word init block, walks the receive and transmit descriptor rings
// and moves frame data between memory and the silos.  Descriptor and
// init-block words take one bus tenure each, buffer data bursts of up
// to eight words (TM p.1-16).  A ring poll reads the status word first,
// then the low address and byte count if the chip owns the entry
// (TM p.1-15).  From idle it serves INIT, then receive, then transmit;
// between bursts it returns to idle.  Status flags are raised once the
// bus is released.  One silo, half duplex: transmit data is loaded only
// while nothing is being received (TM p.1-16), and a frame is polled
// for and started only while the line is inactive (TM p.1-15).
//
// Collisions (TM p.1-11): up to 16 attempts, one with DRTY (TM p.1-24),
// each retry after r slot times, r uniform in [0, 2^min(n,10)).  A
// retry reloads the frame from its first buffer (TM p.4-6).  RTRY and
// LCOL end the frame; the rest of its buffers are released with TINT
// (TM p.1-15).
`default_nettype none
module am7990 (
  input  logic        clk,
  input  logic        reset_n,     // RESET pin
  input  logic        tclk_rise,
  input  logic        tclk_fall,
  // bus
  input  logic [15:0] dal_i,
  output logic [15:0] dal_o,
  output logic        dal_oe,
  output logic [7:0]  a_o,         // A23:A16
  output logic        a_oe,
  input  logic        read_i,
  output logic        read_o,
  input  logic        das_n_i,
  output logic        das_n_o,
  output logic        ale_o,       // ALE, or /AS with ACON=1
  output logic        pin15_o,     // BM0 / BYTE
  output logic        pin16_o,     // BM1 / /BUSAKO
  output logic        pin16_oe,
  output logic        hold_pd,     // /HOLD or /BUSRQ, open drain
  input  logic        hold_i,      // pin 17 line level
  input  logic        hlda_n,
  input  logic        cs_n,
  input  logic        adr,
  input  logic        ready_n_i,
  output logic        ready_pd,    // slave /READY, open drain
  output logic        intr_pd,     // /INTR, open drain
  output logic        dali_n_o,
  output logic        dalo_n_o,
  // serial
  output logic        tx,
  output logic        tena,
  input  logic        rclk_rise,
  input  logic        rx,
  input  logic        rena,
  input  logic        clsn
);
  localparam logic [15:0] RMD1_STP = 16'h0200, RMD1_ENP = 16'h0100;
  localparam logic [15:0] RMD1_CRC = 16'h0800, RMD1_BUFF = 16'h0400, RMD1_ERR = 16'h4000;
  localparam logic [15:0] RMD1_OFLO = 16'h1000;
  localparam logic [15:0] TMD1_KEEP = 16'h03FF;     // OWN ERR RES MORE ONE DEF cleared (TM p.1-27)
  localparam logic [15:0] TMD1_ERR = 16'h4000, TMD1_MORE = 16'h1000, TMD1_ONE = 16'h0800;
  localparam logic [15:0] TMD1_DEF = 16'h0400;
  localparam logic [15:0] TMD3_UFLO = 16'h4000, TMD3_LCOL = 16'h1000, TMD3_LCAR = 16'h0800;
  localparam logic [15:0] TMD3_RTRY = 16'h0400, TMD3_BUFF = 16'h8000;
  localparam logic [15:0] LFSR_SEED = 16'hACE1;
  localparam logic [4:0]  HBEAT = 5'd20;              // 2.0 us (TM p.1-12)
  localparam logic [1:0]  T_CRC = 2'b01, T_OFLO = 2'b10, T_RUNT = 2'b11;
  localparam logic [14:0] POLL = 15'd16384;

  typedef enum logic [2:0] {
    Q_IDLE, Q_INIT, Q_RXDESC, Q_RXCOPY, Q_RXUPD, Q_TXDESC, Q_TXCOPY, Q_TXUPD
  } qst_e;

  // ---- registers ----
  // Justification: (reg-a) CSR0-3, the init block, ring and buffer state.
  logic [1:0]  rap;
  logic [23:1] iadr;
  logic        bswp, acon, bcon;
  logic        stop, strt, init, txon, rxon, inea, tdmd, idon, rint, tint, miss, cerr;
  logic        init_pend, strt_pend;
  logic        m_prom, m_intl, m_drty, m_dtcr, m_loop, m_dtx, m_drx;
  logic [47:0] padr;
  logic [63:0] ladrf;
  logic [23:3] rdra, tdra, rdesc, tdesc;
  logic [2:0]  rlen, tlen;
  logic [6:0]  rcpt, tcpt;
  logic [14:0] poll;
  // receive buffer
  logic        rx_act, rskip, berr, rlast;
  logic [1:0]  rtag;
  logic [23:0] radr;
  logic [7:0]  rhadr;
  logic        rown;
  logic [11:0] rbcnt, rcnt, rmc;
  // transmit buffer; the frame's first buffer, kept for a retry
  logic        tx_act, tmid, terr, tdrop, trew, tfin, tpoll, tabort;
  logic        tsent, tdef, tlcar;
  logic        tla, tbuff;          // looking ahead at the next buffer; BUFF
  logic [23:3] tdescp;              // the buffer being sent while looking ahead
  logic [6:0]  tcptp;
  logic [15:0] tmd1p;
  logic [3:0]  tret;
  logic [15:0] t3;
  logic [23:0] tptr, tptr0;
  logic [15:0] tmd1, tmd10;
  logic [11:0] tbcnt, tcnt, tbcnt0;
  logic [23:3] tdesc0;
  logic [6:0]  tcpt0;
  logic [15:0] lfsr;
  logic        bo_load;
  logic [9:0]  bo_slots;
  logic [4:0]  hbw;
  logic        ttena_q;
  // sequencer and DMA request
  qst_e        q;
  logic        first, fin;
  logic [3:0]  widx, tn;
  logic        dreq, dwr, dbyte, dhi;
  logic [23:0] da;
  logic [15:0] dwd;
  logic        tpush;
  logic [7:0]  tb0, tb1;
  logic        ttwo, tlast, tfcs;

  // ---- DMA engine ----
  logic        dd, dheld, ddrive;
  logic [15:0] drd, ddal_o;
  logic        ddal_oe;
  am7990_dma u_dma (
    .clk(clk), .clr(stop), .tclk_rise(tclk_rise), .tclk_fall(tclk_fall),
    .acon(acon), .bcon(bcon),
    .req(dreq), .addr(da), .wr(dwr), .byte_cyc(dbyte), .hi_lane(dhi), .wdata(dwd),
    .done(dd), .rdata(drd), .held(dheld),
    .hold_pd(hold_pd), .hold_i(hold_i), .hlda_n(hlda_n), .ready_n(ready_n_i), .dal_i(dal_i),
    .drive(ddrive), .dal_o(ddal_o), .dal_oe(ddal_oe), .a_o(a_o), .read_o(read_o),
    .das_n_o(das_n_o), .ale_o(ale_o), .pin15_o(pin15_o), .pin16_o(pin16_o),
    .pin16_oe(pin16_oe), .dali_n_o(dali_n_o), .dalo_n_o(dalo_n_o)
  );
  assign a_oe = ddrive;

  // ---- silo and serial side ----
  logic       mclr, sflush;
  assign mclr = stop || init;

  logic        intl;
  assign intl = m_loop && m_intl;

  logic        shv, sfull, stframe;
  logic [11:0] shd;
  logic [5:0]  tfree, stbytes, srbytes;
  logic        ttake, rhtake;
  logic        swe, slast, scommit, srewind, smark;
  logic [7:0]  sbyte;
  logic [1:0]  stag;
  am7990_silo u_silo (
    .clk(clk), .clr(mclr || sflush),
    .tpush(tpush && !tdrop), .tb0(tb0), .tb1(tb1), .ttwo(ttwo), .tlast(tlast), .tfcs(tfcs),
    .rwe(swe), .rbyte(sbyte), .rlast(slast), .rtag(stag),
    .rcommit(scommit), .rrewind(srewind), .rmark(smark),
    .hv(shv), .hd(shd), .take(ttake || rhtake),
    .free(tfree), .full(sfull), .tbytes(stbytes), .tframe(stframe), .rbytes(srbytes)
  );

  logic ttx, ttena, tuflo_p, tipg, tdone, tcol, tlate, tlcar_p, tdefer, tbo;
  am7990_tx u_tx (
    .clk(clk), .clr(mclr), .tclk_rise(tclk_rise), .loop(m_loop), .rena(rena), .clsn(clsn),
    .hv(shv && !shd[11]), .hb(shd[7:0]), .hlast(shd[8]), .hfcs(shd[9]), .tframe(stframe),
    .pend(tx_act && !tsent && t3 == 16'h0000), .bo_load(bo_load), .bo_slots(bo_slots),
    .take(ttake), .uflo(tuflo_p), .done(tdone), .col(tcol), .late(tlate), .lcar(tlcar_p),
    .deferring(tdefer), .backoff(tbo), .ipg_wait(tipg), .tx(ttx), .tena(ttena)
  );
  // internal loopback: the transmit stream feeds the receiver; pins stay idle
  assign tx   = ttx && !intl;
  assign tena = ttena && !intl;

  logic        rwv, rtwo, rl0, rl1, rany, rburst, rend, rpop, rone, rtake, rbusy;
  logic [7:0]  rb0, rb1;
  logic [1:0]  rt0, rt1;
  logic        txbusy;
  assign txbusy = stbytes != 6'd0 || q == Q_TXCOPY || tdrop;
  am7990_rx u_rx (
    .clk(clk), .clr(mclr), .tclk_rise(tclk_rise),
    .rclk_rise(intl ? tclk_rise : rclk_rise),
    .rx(intl ? ttx : rx), .rena(intl ? ttena : rena), .clsn(!intl && clsn),
    .on(strt && rxon), .loop(m_loop), .tena(ttena), .ipg_wait(tipg), .txbusy(txbusy),
    .backoff(tbo),
    .rtake(rtake), .busy(rbusy),
    .padr(padr), .ladrf(ladrf), .prom(m_prom), .nocheck(m_loop && !m_dtcr),
    .swe(swe), .sbyte(sbyte), .slast(slast), .stag(stag), .scommit(scommit),
    .srewind(srewind), .smark(smark), .sfull(sfull),
    .hv(shv && shd[11]), .hd(shd[10:0]), .rbytes(srbytes), .htake(rhtake),
    .wv(rwv), .b0(rb0), .b1(rb1), .two(rtwo), .l0(rl0), .l1(rl1), .t0(rt0), .t1(rt1),
    .wpop(rpop), .wone(rone), .any(rany), .burst(rburst), .ended(rend)
  );

  // the silo is given up: a reception during a backoff takes it from
  // waiting transmit bytes, the transmitter ran dry, or a collision.
  // Only transmit bytes are dropped (TM p.1-16): a second reception in
  // the same backoff finds the first one's data, not transmit bytes.
  assign sflush = (rtake && !rany) || tuflo_p || tcol;

  // ---- host register cycles ----
  // Justification: (reg-a) /DAS seen low last clock; this access done.
  logic das_q, hdone;
  logic hw;
  assign hw = !cs_n && !das_n_i && das_q && !read_i && !hdone && !ddrive;
  always_ff @(posedge clk) begin
    das_q <= !das_n_i;
    if (das_n_i)  hdone <= 1'b0;
    else if (hw)  hdone <= 1'b1;
    ready_pd <= !cs_n && !das_n_i && !ddrive;
  end

  logic intr;
  assign intr    = miss || rint || tint || idon;   // not CERR (TM p.1-12)
  assign intr_pd = inea && intr;

  logic [15:0] rv;
  always_comb begin
    rv = 16'h0000;
    if (adr) rv = {14'd0, rap};
    else begin
      unique case (rap)
        2'd0: rv = {miss || cerr, 1'b0, cerr, miss, 1'b0, rint, tint, idon, intr, inea, rxon, txon, tdmd, stop, strt, init};
        2'd1: rv = {iadr[15:1], 1'b0};
        2'd2: rv = {8'h00, iadr[23:16]};
        default: rv = {13'd0, bswp, acon, bcon};
      endcase
    end
  end
  assign dal_o  = ddrive ? ddal_o : rv;
  assign dal_oe = ddrive ? ddal_oe : (!cs_n && !das_n_i && read_i);

  // ---- sequencer helpers ----
  logic [6:0]  rmask, tmask, rnext, tnext;
  assign rmask = 7'((8'd1 << rlen) - 8'd1);
  assign tmask = 7'((8'd1 << tlen) - 8'd1);
  assign rnext = (rcpt + 7'd1) & rmask;
  assign tnext = (tcpt + 7'd1) & tmask;

  // receive word: one byte for an odd address or a lone last byte
  logic        rsone, rslast, rfits, rstore;
  logic [1:0]  rstag;
  logic [11:0] rneed;
  logic [15:0] rwd;
  assign rsone  = radr[0] || !rtwo;
  assign rslast = rsone ? rl0 : rl1;
  assign rstag  = rsone ? rt0 : rt1;
  assign rneed  = rsone ? 12'd1 : 12'd2;
  assign rfits  = rcnt + rneed <= rbcnt;
  assign rstore = !rskip && !berr && rfits;
  assign rwd    = rsone ? {rb0, rb0} : bswp ? {rb0, rb1} : {rb1, rb0};

  // transmit word: a byte cycle for an odd address or the last byte
  logic [11:0] tleft, tstep, tleft_n;
  logic [23:0] tptr_n;
  logic [5:0]  troom;
  assign tleft   = tbcnt - tcnt;
  assign tstep   = dbyte ? 12'd1 : 12'd2;
  assign tleft_n = tleft - tstep;
  assign tptr_n  = tptr + 24'(tstep);
  assign troom   = (tleft >= 12'd16) ? 6'd16 : 6'({tleft[4:1] + 4'(tleft[0]), 1'b0});

  logic busy;                  // the bus is ours or a word is wanted
  assign busy = dreq || dheld;

  // a word taken from the receiver last clock is still shown this clock
  logic rok;
  assign rok = rwv && !rpop && !rone;

  // in loopback the received frame moves to memory only once it has
  // ended (TM p.1-12)
  logic rgo;
  assign rgo = !m_loop || rend;

  // transmit data waits while a frame is received (half duplex)
  logic tgo;
  assign tgo = m_loop || (!rbusy && !rany);

  // no carrier: a new frame may be polled for and loaded (TM p.1-15)
  logic lineoff;
  assign lineoff = !rena && !clsn;

  // before transmission starts the silo takes 32 bytes (TM p.1-16, p.4-6)
  logic tcap;
  assign tcap = ttena || 7'(stbytes) + 7'(troom) <= 7'd32;

  // TMD1 status: ERR with any TMD3 error, retries and deferral on a
  // frame's last write (TM p.1-27)
  logic [15:0] tstat, t1;
  assign tstat = (tret > 4'd1 ? TMD1_MORE : 16'h0000) | (tret == 4'd1 ? TMD1_ONE : 16'h0000) |
                 (tdef ? TMD1_DEF : 16'h0000);
  assign t1 = (tmd1 & TMD1_KEEP) | (t3 != 16'h0000 ? TMD1_ERR : 16'h0000) |
              (tfin ? tstat : 16'h0000);

  // backoff slots: r in [0, 2^k), k = min(retry, 10) (TM p.1-11)
  logic [9:0] bomask;
  assign bomask = (tret >= 4'd9) ? 10'h3FF : 10'((11'd2 << tret) - 11'd1);

  // ---- control: reset, STOP, host writes, sequencer ----
  logic hcsr0, hstop;
  assign hcsr0 = hw && !adr && rap == 2'd0;
  assign hstop = hcsr0 && dal_i[2];

  always_ff @(posedge clk) begin
    tpush   <= 1'b0;
    rpop    <= 1'b0;
    rone    <= 1'b0;
    bo_load <= 1'b0;
    ttena_q <= ttena && !intl;
    if (!reset_n || hstop) begin
      stop <= 1'b1;
      {strt, init, txon, rxon, inea, tdmd, idon, rint, tint, miss, cerr} <= '0;
      {init_pend, strt_pend, rx_act, tx_act, rskip, berr, rlast} <= '0;
      {tmid, terr, tdrop, trew, tfin, tpoll, tabort, tsent, tla, tbuff} <= '0;
      t3   <= 16'h0000;
      {dreq, first, fin} <= '0;
      poll <= '0;
      hbw  <= 5'd0;
      lfsr <= LFSR_SEED;
      q    <= Q_IDLE;
      {bswp, acon, bcon} <= '0;          // STOP clears CSR3 (TM p.1-22)
      if (!reset_n) begin
        rap  <= 2'd0;
        iadr <= '0;
      end
    end else begin
      // transmit poll: TDMD every 16384 TCLKs while the transmitter is on
      if (tclk_rise && strt && txon) begin
        if (tdmd)              poll <= '0;
        else if (poll != POLL) poll <= poll + 15'd1;
        else begin
          tdmd <= 1'b1;
          poll <= '0;
        end
      end

      // Heartbeat: CLSN within 2 us after TENA falls, else CERR
      // (TM p.1-12)
      if (ttena_q && !ttena) begin
        hbw <= HBEAT;
      end else if (tclk_rise && hbw != 5'd0) begin
        if (clsn) hbw <= 5'd0;
        else begin
          hbw <= hbw - 5'd1;
          if (hbw == 5'd1) cerr <= 1'b1;
        end
      end

      if (tdefer && tx_act) tdef <= 1'b1;
      if (tdone) begin
        tsent <= 1'b1;
        tlcar <= tlcar_p && !intl;
      end

      // A reception during a backoff took the silo: drop the rest of the
      // burst, then reload the frame from its start.  An underflow ends
      // the frame.
      if (rtake) begin
        tdrop <= 1'b1;
        trew  <= 1'b1;
      end
      if (tuflo_p && txon) begin
        tdrop <= 1'b1;
        terr  <= 1'b1;
        t3    <= tbuff ? TMD3_UFLO | TMD3_BUFF : TMD3_UFLO;
      end
      // A collided attempt: late ends the frame, the 16th (or with DRTY
      // the first) gives RTRY, else back off and reload (TM p.1-11).
      if (tcol) begin
        tdrop <= 1'b1;
        if (tlate) begin
          terr <= 1'b1;
          t3   <= TMD3_LCOL;
        end else if (m_drty || tret == 4'd15) begin
          terr <= 1'b1;
          trew <= 1'b1;
          t3   <= TMD3_RTRY;
        end else begin
          trew     <= 1'b1;
          tret     <= tret + 4'd1;
          bo_load  <= 1'b1;
          bo_slots <= lfsr[9:0] & bomask;
          lfsr     <= {1'b0, lfsr[15:1]} ^ (lfsr[0] ? 16'hB400 : 16'h0000);
        end
      end

      unique case (q)
        Q_IDLE: if (!busy && !rpop && !rone) begin
          widx  <= 4'd0;
          tn    <= 4'd0;
          dwr   <= 1'b0;
          dbyte <= 1'b0;
          if (init_pend) begin
            q     <= Q_INIT;
            da    <= {iadr, 1'b0};
            first <= 1'b1;
          end else if (strt && rxon && !rx_act && rany && rgo) begin
            q     <= Q_RXDESC;
            da    <= {rdesc, 3'd2};
            first <= 1'b1;
          end else if (strt && rxon && rx_act && rgo && (rburst || ((rskip || berr) && rok))) begin
            q <= Q_RXCOPY;
          end else if (trew) begin
            trew   <= 1'b0;
            tdrop  <= 1'b0;
            tsent  <= 1'b0;
            tbuff  <= 1'b0;
            tdesc  <= tdesc0;
            tcpt   <= tcpt0;
            tptr   <= tptr0;
            tbcnt  <= tbcnt0;
            tmd1   <= tmd10;
            tcnt   <= 12'd0;
            tmid   <= 1'b0;
            tx_act <= 1'b1;
          end else if (terr) begin
            terr  <= 1'b0;
            tfin  <= 1'b1;
            q     <= Q_TXUPD;
            da    <= {tdesc, 3'd6};
            dwr   <= 1'b1;
            dwd   <= t3;
            first <= tx_act;
            fin   <= !tx_act;
          end else if (strt && txon && !tx_act && (tdmd || tpoll) && lineoff) begin
            q     <= Q_TXDESC;
            tdmd  <= 1'b0;
            tpoll <= 1'b0;
            da    <= {tdesc, 3'd2};
            first <= 1'b1;
          // A chained buffer is in the silo: poll the next one before
          // releasing it (TM p.1-15).
          end else if (strt && txon && tx_act && tcnt >= tbcnt && !tmd1[8] && !tbuff) begin
            q      <= Q_TXDESC;
            tla    <= 1'b1;
            tmid   <= 1'b1;
            tdescp <= tdesc;
            tcptp  <= tcpt;
            tmd1p  <= tmd1;
            tcpt   <= tnext;
            tdesc  <= (tnext == 7'd0) ? tdra : tdesc + 21'd1;
            da     <= {(tnext == 7'd0) ? tdra : tdesc + 21'd1, 3'd2};
            first  <= 1'b1;
          // a frame's last TMD1 waits until the frame is off the wire (TM p.1-15)
          end else if (strt && txon && tx_act && tcnt >= tbcnt && tmd1[8] &&
                       tsent && stbytes == 6'd0 && !tpush) begin
            q     <= Q_TXUPD;
            dwr   <= 1'b1;
            first <= 1'b1;
            tfin  <= tmd1[8];
            tsent <= 1'b0;
            if (tmd1[8] && tlcar) begin
              t3    <= TMD3_LCAR;
              da    <= {tdesc, 3'd6};
              dwd   <= TMD3_LCAR;
            end else begin
              da    <= {tdesc, 3'd2};
              widx  <= 4'd1;
              dwd   <= (tmd1 & TMD1_KEEP) | (tmd1[8] ? tstat : 16'h0000);
            end
          // more than 16 bytes free before the bus is requested; a frame
          // may load while the cable is busy (TM p.1-16, p.4-6)
          end else if (strt && txon && tx_act && tcnt < tbcnt && tgo && tfree > 6'd16 && tcap) begin
            q     <= Q_TXCOPY;
            da    <= tptr;
            first <= 1'b1;
          end
        end

        Q_INIT: begin
          if (first && !busy) begin
            dreq  <= 1'b1;
            first <= 1'b0;
          end
          if (dd) begin
            unique case (widx)
              4'd0: {m_prom, m_intl, m_drty, m_dtcr, m_loop, m_dtx, m_drx} <=
                      {drd[15], drd[6], drd[5], drd[3], drd[2], drd[1], drd[0]};
              4'd1: padr[15:0]   <= drd;
              4'd2: padr[31:16]  <= drd;
              4'd3: padr[47:32]  <= drd;
              4'd4: ladrf[15:0]  <= drd;
              4'd5: ladrf[31:16] <= drd;
              4'd6: ladrf[47:32] <= drd;
              4'd7: ladrf[63:48] <= drd;
              4'd8: rdra[15:3]   <= drd[15:3];
              4'd9: {rlen, rdra[23:16]} <= {drd[15:13], drd[7:0]};
              4'd10: tdra[15:3]  <= drd[15:3];
              default: {tlen, tdra[23:16]} <= {drd[15:13], drd[7:0]};
            endcase
            widx <= widx + 4'd1;
            da   <= da + 24'd2;
            dreq <= 1'b0;
            if (widx == 4'd11) fin   <= 1'b1;
            else               first <= 1'b1;
          end
          if (fin && !busy) begin
            fin       <= 1'b0;
            rcpt      <= 7'd0;
            tcpt      <= 7'd0;
            rdesc     <= rdra;
            tdesc     <= tdra;
            rx_act    <= 1'b0;
            tx_act    <= 1'b0;
            rskip     <= 1'b0;
            {tmid, terr, tdrop, trew, tfin, tpoll, tabort, tsent, tla, tbuff} <= '0;
            t3        <= 16'h0000;
            idon      <= 1'b1;
            init_pend <= 1'b0;
            if (strt_pend) begin
              strt_pend <= 1'b0;
              {strt, init, stop} <= 3'b100;
              txon <= !m_dtx;
              rxon <= !m_drx;
            end
            q <= Q_IDLE;
          end
        end

        Q_RXDESC: begin
          if (first && !busy) begin
            dreq  <= 1'b1;
            first <= 1'b0;
          end
          // RMD1, then RMD0 and RMD2 if owned
          if (dd) begin
            dreq <= 1'b0;
            widx <= widx + 4'd1;
            unique case (widx[1:0])
              2'd0: begin
                {rown, rhadr, radr[23:16]} <= {drd[15], drd[7:0], drd[7:0]};
                da <= {rdesc, 3'd0};
                if (drd[15]) first <= 1'b1;
                else         fin   <= 1'b1;
              end
              2'd1: begin
                radr[15:0] <= drd;
                da    <= {rdesc, 3'd4};
                first <= 1'b1;
              end
              default: begin
                rbcnt <= 12'd0 - drd[11:0];
                fin   <= 1'b1;
              end
            endcase
          end
          if (fin && !busy) begin
            fin    <= 1'b0;
            rx_act <= 1'b1;
            rcnt   <= 12'd0;
            rmc    <= 12'd0;
            berr   <= 1'b0;
            if (!rown) begin
              miss  <= 1'b1;
              rskip <= 1'b1;
            end
            q <= Q_IDLE;
          end
        end

        // Each word is taken from the receiver as it is issued, so the next
        // one is staged by the time this one is done.  A frame ends at its
        // last byte's tag: a runt leaves the buffer for the next frame
        // (TM p.1-19), otherwise the descriptor is written.
        Q_RXCOPY: begin
          if (!dreq && !dheld) begin
            if (rlast) begin
              rlast <= 1'b0;
              if (rtag == T_RUNT || rskip) begin
                radr  <= radr - 24'(rcnt);
                rcnt  <= 12'd0;
                rmc   <= 12'd0;
                berr  <= 1'b0;
                if (rskip) begin
                  rskip  <= 1'b0;
                  rx_act <= 1'b0;
                end
                q <= Q_IDLE;
              end else begin
                q     <= Q_RXUPD;
                da    <= {rdesc, 3'd6};
                dwr   <= 1'b1;
                dbyte <= 1'b0;
                dwd   <= {4'd0, rmc};
                widx  <= 4'd0;
                first <= 1'b1;
              end
            end else if (rok) begin
              rpop  <= !rsone || rslast;
              rone  <= rsone && !rslast;
              rmc   <= rmc + rneed;
              rlast <= rslast;
              rtag  <= rstag;
              if (!rskip && !rfits) berr <= 1'b1;
              if (rstore) begin
                dreq  <= 1'b1;
                tn    <= 4'd1;
                da    <= radr;
                dwr   <= 1'b1;
                dbyte <= rsone;
                dhi   <= bswp ^ radr[0];
                dwd   <= rwd;
                radr  <= radr + 24'(rneed);
                rcnt  <= rcnt + rneed;
              end
            end else if (!rpop && !rone) begin
              q <= Q_IDLE;
            end
          end
          if (dd) begin
            if (rlast) dreq <= 1'b0;
            else if (tn == 4'd8 || !rok) begin
              dreq <= 1'b0;
              q    <= Q_IDLE;
            end else begin
              rpop  <= !rsone || rslast;
              rone  <= rsone && !rslast;
              rmc   <= rmc + rneed;
              rlast <= rslast;
              rtag  <= rstag;
              if (!rfits) berr <= 1'b1;
              if (rstore) begin
                tn    <= tn + 4'd1;
                da    <= radr;
                dbyte <= rsone;
                dhi   <= bswp ^ radr[0];
                dwd   <= rwd;
                radr  <= radr + 24'(rneed);
                rcnt  <= rcnt + rneed;
              end else begin
                dreq <= 1'b0;
              end
            end
          end
        end

        // RMD3, then RMD1: clearing OWN is the last write (TM p.1-26).
        // An overflowed frame has OFLO and no ENP; CRC only with ENP.
        Q_RXUPD: begin
          if (first && !busy) begin
            dreq  <= 1'b1;
            first <= 1'b0;
          end
          if (dd) begin
            dreq <= 1'b0;
            widx <= 4'd1;
            if (widx == 4'd0) begin
              da    <= {rdesc, 3'd2};
              dwd   <= RMD1_STP | {8'h00, rhadr} |
                       (rtag == T_OFLO ? RMD1_OFLO | RMD1_ERR :
                        rtag == T_CRC  ? RMD1_ENP | RMD1_CRC | RMD1_ERR : RMD1_ENP) |
                       (berr ? RMD1_BUFF | RMD1_ERR : 16'h0000);
              first <= 1'b1;
            end else begin
              fin <= 1'b1;
            end
          end
          if (fin && !busy) begin
            fin    <= 1'b0;
            rcpt   <= rnext;
            rdesc  <= (rnext == 7'd0) ? rdra : rdesc + 21'd1;
            rx_act <= 1'b0;
            rint   <= 1'b1;
            q      <= Q_IDLE;
          end
        end

        // TMD1, then TMD0 and TMD2 if owned and a frame start (STP) or a
        // chained buffer.  An owned entry without STP at a frame start is
        // skipped and the next one polled (TM p.1-27).
        Q_TXDESC: begin
          if (first && !busy) begin
            dreq  <= 1'b1;
            first <= 1'b0;
          end
          if (dd) begin
            dreq <= 1'b0;
            widx <= widx + 4'd1;
            unique case (widx[1:0])
              2'd0: begin
                {tmd1, tptr[23:16]} <= {drd, drd[7:0]};
                da <= {tdesc, 3'd0};
                if (drd[15] && (drd[9] || tmid)) first <= 1'b1;
                else                             fin   <= 1'b1;
              end
              2'd1: begin
                tptr[15:0] <= drd;
                da    <= {tdesc, 3'd4};
                first <= 1'b1;
              end
              default: begin
                tbcnt <= 12'd0 - drd[11:0];
                fin   <= 1'b1;
              end
            endcase
          end
          if (fin && !busy) begin
            fin  <= 1'b0;
            tcnt <= 12'd0;
            if (tla) begin
              tla <= 1'b0;
              if (trew) begin
                q <= Q_IDLE;
              end else if (terr || !tmd1[15]) begin
                // Not ours, or the silo ran dry first: the buffer being
                // sent keeps the status, BUFF with UFLO (TM p.1-15, p.1-28).
                tdesc  <= tdescp;
                tcpt   <= tcptp;
                tmd1   <= tmd1p;
                tcnt   <= tbcnt;
                tx_act <= 1'b1;
                if (!terr || t3 == TMD3_UFLO) tbuff <= 1'b1;
                if (t3 == TMD3_UFLO) t3 <= TMD3_UFLO | TMD3_BUFF;
                q <= Q_IDLE;
              end else begin
                // ours: release the one in the silo, then load this one
                q      <= Q_TXUPD;
                tx_act <= 1'b1;
                tfin   <= 1'b0;
                da     <= {tdescp, 3'd2};
                dwr    <= 1'b1;
                dwd    <= tmd1p & TMD1_KEEP;
                widx   <= 4'd1;
                first  <= 1'b1;
              end
            end else if (tmd1[15] && !tmd1[9] && !tmid && tabort) begin
              // the rest of a frame ended by RTRY or LCOL (TM p.1-15)
              q      <= Q_TXUPD;
              tx_act <= 1'b1;
              tfin   <= 1'b0;
              da     <= {tdesc, 3'd2};
              dwr    <= 1'b1;
              dwd    <= tmd1 & TMD1_KEEP;
              widx   <= 4'd1;
              first  <= 1'b1;
            end else if (tmd1[15] && !tmd1[9] && !tmid) begin
              tcpt  <= tnext;
              tdesc <= (tnext == 7'd0) ? tdra : tdesc + 21'd1;
              widx  <= 4'd0;
              da    <= {(tnext == 7'd0) ? tdra : tdesc + 21'd1, 3'd2};
              first <= 1'b1;
            end else begin
              tx_act <= tmd1[15];
              if (tmd1[15] && tmd1[9] && !tmid) begin
                tabort <= 1'b0;
                tret   <= 4'd0;
                tdef   <= 1'b0;
                tsent  <= 1'b0;
                tdesc0 <= tdesc;
                tcpt0  <= tcpt;
                tptr0  <= tptr;
                tbcnt0 <= tbcnt;
                tmd10  <= tmd1;
              end
              q      <= Q_IDLE;
            end
          end
        end

        // Byte cycles for an odd address or the last byte, on the lane
        // Table 1-2 gives (TM p.1-16, p.1-17).
        Q_TXCOPY: begin
          if (first && !busy) begin
            dreq  <= 1'b1;
            first <= 1'b0;
            tn    <= 4'd0;
            dbyte <= tptr[0] || tleft == 12'd1;
            dhi   <= bswp ^ tptr[0];
          end
          if (dd) begin
            tpush <= 1'b1;
            tb0   <= (dbyte ? dhi : bswp) ? drd[15:8] : drd[7:0];
            tb1   <= bswp ? drd[7:0] : drd[15:8];
            ttwo  <= !dbyte;
            tlast <= tmd1[8] && tleft_n == 12'd0;
            tfcs  <= !m_dtcr;                      // TM p.1-12; TMD1 bit 13 reserved
            dbyte <= tptr_n[0] || tleft_n == 12'd1;
            dhi   <= bswp ^ tptr_n[0];
            tcnt  <= tcnt + tstep;
            tptr  <= tptr_n;
            da    <= tptr_n;
            tn    <= tn + 4'd1;
            if (tleft_n == 12'd0 || tn == 4'd7 || tdrop) begin
              dreq <= 1'b0;
              q    <= Q_IDLE;
            end
          end
        end

        // TMD1 (after TMD3 on an error).  At a frame's end poll the ring
        // again at once, once the line is inactive (TM p.1-15).  An
        // underflow turns the transmitter off (TM p.1-21, p.1-28).
        Q_TXUPD: begin
          if (first && !busy) begin
            dreq  <= 1'b1;
            first <= 1'b0;
          end
          if (dd) begin
            dreq <= 1'b0;
            widx <= 4'd1;
            if (widx == 4'd0) begin
              da    <= {tdesc, 3'd2};
              dwd   <= t1;
              first <= 1'b1;
            end else begin
              fin <= 1'b1;
            end
          end
          if (fin && !busy) begin
            fin   <= 1'b0;
            dwr   <= 1'b0;
            widx  <= 4'd0;
            if (tfin || tabort) begin
              if (tx_act) begin
                tcpt  <= tnext;
                tdesc <= (tnext == 7'd0) ? tdra : tdesc + 21'd1;
              end
              tx_act <= 1'b0;
              tint   <= 1'b1;
              tfin   <= 1'b0;
              if (tfin) begin
                t3     <= 16'h0000;
                tmid   <= 1'b0;
                tdrop  <= 1'b0;
                tbuff  <= 1'b0;
                tabort <= t3 != 16'h0000 && t3 != TMD3_LCAR && !tmd1[8];
              end
              if (tfin && t3[14]) begin
                txon <= 1'b0;
                q    <= Q_IDLE;
              end else if (lineoff) begin
                q     <= Q_TXDESC;
                tdmd  <= 1'b0;
                da    <= {(tnext == 7'd0) ? tdra : tdesc + 21'd1, 3'd2};
                first <= 1'b1;
              end else begin
                tpoll <= 1'b1;
                q     <= Q_IDLE;
              end
            end else begin
              q <= Q_IDLE;                 // a chained buffer released
            end
          end
        end

        default: q <= Q_IDLE;
      endcase

      // host writes land last: a write and a flag update in one clock
      // leave the write's value
      if (hw && adr) rap <= dal_i[1:0];
      if (hcsr0) begin
        if (dal_i[8])  idon <= 1'b0;
        if (dal_i[9])  tint <= 1'b0;
        if (dal_i[10]) rint <= 1'b0;
        if (dal_i[12]) miss <= 1'b0;
        if (dal_i[13]) cerr <= 1'b0;
        // INEA cannot be set while STOP=1, only with INIT or STRT (TM p.1-21)
        if (!stop || dal_i[0] || dal_i[1]) inea <= dal_i[6];
        if (dal_i[0] && stop) begin
          {init, strt, stop} <= 3'b100;
          init_pend <= 1'b1;
          strt_pend <= dal_i[1];
        end else if (dal_i[1] && (stop || init)) begin
          {strt, init, stop} <= 3'b100;
          txon <= !m_dtx;
          rxon <= !m_drx;
        end
        if (dal_i[3] && !(stop && !dal_i[0] && !dal_i[1])) tdmd <= 1'b1;
      end
      if (hw && !adr && stop) begin
        if (rap == 2'd1) iadr[15:1]  <= dal_i[15:1];
        if (rap == 2'd2) iadr[23:16] <= dal_i[7:0];
        if (rap == 2'd3) {bswp, acon, bcon} <= dal_i[2:0];
      end
    end
  end
endmodule
`default_nettype wire
