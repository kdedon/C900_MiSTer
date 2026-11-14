// 8716 DMA engine: transfer control (DIR, arm, single-step mode, DMADONE,
// ERROR), the /S.Busreq and /R.Busreq envelope (sheet 8), the word funnel
// (sheet 9) and the T1/T2/TW/T3 memory cycle (sheet 10), stepped one half
// T-state per CLK pin edge: clk_pin_rise and clk_pin_fall are one-clock
// edge pulses on the fabric clock.  clkadr_rise/clkadr_fall are the CLKADR
// edges as pulses.
//
// Same-sample order: /RESET edge (chip_rst), PCSS command, PCSD dispatch,
// the /RESET level hold, then the CLK step.  `dir` and `status` are this
// sample's values after the PCSS/PCSD effects and before the hold;
// pcss_unit captures them at the PCSD edge.  The CLK step reads the FIFO
// occupancy after this sample's B-side access.
//
// Memory cycle: nine half-states.  A cycle starts on a CLK fall (so A
// halves begin on falls, B halves on rises) with /BUSREQ held, /BAI Low
// and a word of room (read) or a full word (write).  T2A/TWA sample /WAIT;
// /WAIT High there takes the R.Busreq decision.  T3B commits: the read
// word is taken from AD, CLKADR rises, and a new T1A follows at once while
// the tenure, the word gate and the envelope all hold.  CmdReset and
// /RESET Low abort the cycle.  Outputs are decoded from the registered
// state (combinational, not registered outputs).
`default_nettype none

module dma_fsm (
  input  logic        clk,
  input  logic        chip_rst,
  input  logic        reset_hold,
  input  logic        cmd_stb,
  input  logic [7:0]  cmd,
  input  logic        pcsd_ld2,
  input  logic        pcsd_ld0,
  input  logic        pcsd_ss,
  input  logic        pcsd_dir,
  input  logic        ld0_latch,
  input  logic        bd_push,
  input  logic        bd_pop,
  input  logic        clk_pin_rise,
  input  logic        clk_pin_fall,
  input  logic        bai_n,
  input  logic        wait_n,
  input  logic [15:0] ad_in,
  input  logic        fifo_mid_empty,
  input  logic [6:0]  fifo_w_used,
  input  logic [15:0] fifo_w_rdata,
  output logic        fifo_clr,
  output logic        fifo_hold_clr,
  output logic        fifo_w_push,
  output logic        fifo_w_pop,
  output logic [15:0] fifo_w_wdata,
  output logic        dir,
  output logic [7:0]  status,
  output logic        cmd_rst,
  output logic        blk_done,
  output logic        blk_commit,
  output logic        blk_sector,
  output logic        mreq_n,
  output logic        ds_n,
  output logic        dmaen_n,
  output logic        busreq_n,
  output logic        bao_n,
  output logic [15:0] ad_out,
  output logic        ad_oe,
  output logic        clkadr_rise,
  output logic        clkadr_fall
);

  localparam logic [7:0] CMD_RESET = 8'h7F, CMD_MOVE = 8'hF7;
  localparam logic       DIR_READ = 1'b1, DIR_WRITE = 1'b0;
  localparam logic [9:0] BD_SECTOR = 10'd512, BD_WORD = 10'd2;

  // Justification: transfer control flags (reg-a): DIR (LD2 PCSD bit 7),
  // DMADONE (status BD7), counter primed, armed, single-step mode and
  // the single-step word in flight.
  logic dir_q, dir_d;
  logic dmadone_q, dmadone_pcsd;
  logic primed_q, primed_d;
  logic armed_q, armed_d;
  logic ss_mode_q, ss_mode_d;
  logic ss_act_q, ss_act_d;
  // Justification: B-side byte count since the LD0 latch or the arm,
  // saturating at one sector; the block length it is compared with (reg-a).
  logic [9:0] bd_cnt_q, bd_cnt_d;
  logic       lim_set_q, lim_set_d, lim_sector_q, lim_sector_d;
  // Justification: /BUSREQ tenure (reg-a); words moved since the arm (reg-a).
  logic busreq_q, busreq_d;
  logic [8:0] words_q, words_d;

  typedef enum logic [3:0] {
    IDLE = 4'd0,
    T1A  = 4'd1,
    T1B  = 4'd2,
    T2A  = 4'd3,
    T2B  = 4'd4,
    TWA  = 4'd5,
    TWB  = 4'd6,
    T3A  = 4'd7,
    T3B  = 4'd8
  } mem_state_e;

  // Justification: memory-cycle half-state (reg-a); the word in the
  // data latches, memLo in [15:8] (reg-a); CLKADR level, its previous
  // value for the edge pulses, and its second CLK edge pending (reg-a).
  mem_state_e state_q, state_pre, state_d;
  logic [15:0] word_q, word_d;
  logic clkadr_q, clkadr_more_q, clkadr_prev_q;

  logic primed_rst, ss_mode_rst, arm_f7, bd_at_limit;
  logic ck_edge, busreq_pre;
  logic commit, last_word, ss_done, start_idle, chain, start, wants_after;
  logic e_armed, e_dmadone, e_ss;
  logic [8:0] e_words, e_lim;
  logic [6:0] e_used;
  logic want, gate;

  assign cmd_rst = cmd_stb && cmd == CMD_RESET;

  // Effects in the same-sample order: /RESET edge, PCSS command (CmdReset,
  // the F7 arm), PCSD (LD2, LD0, SS), then the /RESET level hold.
  assign primed_rst  = primed_q & ~chip_rst & ~cmd_rst;
  assign ss_mode_rst = ss_mode_q & ~chip_rst & ~cmd_rst;
  assign arm_f7      = cmd_stb && cmd == CMD_MOVE && !primed_rst;

  always_comb begin
    dir_d = chip_rst ? DIR_WRITE : dir_q;
    if (pcsd_ld2) dir_d = pcsd_dir;
  end

  always_comb begin
    primed_d = primed_rst | arm_f7;
    if (pcsd_ld2 && pcsd_dir != dir_q) primed_d = 1'b0;
    if (pcsd_ld0) primed_d = 1'b0;
    if (pcsd_ss)  primed_d = 1'b1;
  end

  always_comb begin
    armed_d = (armed_q & ~chip_rst & ~cmd_rst) | arm_f7;
    if (pcsd_ld0) armed_d = 1'b0;
    if (pcsd_ss)  armed_d = 1'b1;
    if (reset_hold) armed_d = 1'b0;
  end

  always_comb begin
    ss_mode_d = ss_mode_rst;
    if (pcsd_ld2) ss_mode_d = 1'b0;
    if (pcsd_ss)  ss_mode_d = 1'b1;
  end

  always_comb begin
    ss_act_d = ss_act_q & ~chip_rst & ~cmd_rst;
    if (arm_f7)     ss_act_d = ss_mode_rst;
    if (pcsd_ss)    ss_act_d = 1'b1;
    if (reset_hold) ss_act_d = 1'b0;
  end

  // DMADONE before the /RESET level hold.
  always_comb begin
    dmadone_pcsd = dmadone_q;
    if (chip_rst || cmd_rst) dmadone_pcsd = 1'b1;
    if (arm_f7 || pcsd_ss)   dmadone_pcsd = 1'b0;
  end

  // B-side count: zeroed at the LD0 latch and at either arm, then counts
  // this sample's accepted push or pop.
  always_comb begin
    bd_cnt_d     = (ld0_latch || arm_f7 || pcsd_ss) ? 10'd0 : bd_cnt_q;
    lim_set_d    = lim_set_q | arm_f7 | pcsd_ss;
    lim_sector_d = lim_sector_q;
    if (arm_f7)  lim_sector_d = !ss_mode_rst;
    if (pcsd_ss) lim_sector_d = 1'b0;
    if ((bd_push || bd_pop) && bd_cnt_d != BD_SECTOR) bd_cnt_d = bd_cnt_d + 10'd1;
  end

  // No arm yet: the block length is zero.
  assign bd_at_limit = !lim_set_d || bd_cnt_d >= (lim_sector_d ? BD_SECTOR : BD_WORD);

  // CLK step.  The cycle and the tenure are aborted first.
  assign ck_edge    = clk_pin_rise | clk_pin_fall;
  assign state_pre  = (cmd_rst || reset_hold) ? IDLE : state_q;
  assign busreq_pre = busreq_q & ~cmd_rst & ~reset_hold;
  assign words_d    = (arm_f7 || pcsd_ss) ? 9'd0 : words_q;

  // Commit (T3B): the word lands; the single step ends with it.
  assign commit    = ck_edge && state_pre == T3B;
  assign last_word = words_d + 9'd1 >= (ss_act_d ? 9'd1 : 9'd256);
  assign ss_done   = commit & ss_act_d;

  // Transfer state the envelope and the word gate see: this sample's
  // values, or the post-commit ones at T3B.
  assign e_armed   = armed_d & ~ss_done;
  assign e_ss      = ss_act_d & ~ss_done;
  assign e_dmadone = dmadone_pcsd | reset_hold | (commit & last_word);
  assign e_words   = commit ? words_d + 9'd1 : words_d;
  assign e_lim     = e_ss ? 9'd1 : 9'd256;
  assign e_used    = (commit && dir_d == DIR_READ) ? fifo_w_used + 7'd2 : fifo_w_used;

  // Request envelope (sheet 8): assert and hold conditions differ.
  always_comb begin
    want = 1'b0;
    if (e_armed && primed_d && !e_dmadone && e_words < e_lim) begin
      if (dir_d == DIR_READ)
        want = busreq_pre ? e_used != 7'd64 : e_used < 7'd32;
      else if (busreq_pre)
        want = e_used >= 7'd2;
      else
        want = e_used >= 7'd32 || (e_lim - e_words <= 9'd16 && e_used >= 7'd2);
    end
  end

  // Word gate (L.Ready): a word of FIFO room or a full word.
  assign gate = e_armed && primed_d && e_words < e_lim &&
                (dir_d == DIR_READ ? e_used <= 7'd62 : e_used >= 7'd2);

  // R.Busreq: does the envelope still want the bus once this word lands.
  assign wants_after = !last_word &&
                       (dir_d == DIR_READ ? fifo_w_used + 7'd2 < 7'd64 : fifo_w_used >= 7'd2);

  assign start_idle = clk_pin_fall && state_pre == IDLE && busreq_d && !bai_n && gate;
  assign chain      = commit && busreq_pre && want && gate;
  assign start      = start_idle | chain;

  // /BUSREQ: re-evaluated on each CLK edge while idle and at the commit;
  // a new request starts only while /BAI is High; released at the T2
  // /WAIT sample when no word is wanted after this one.
  always_comb begin
    busreq_d = busreq_pre;
    if (ck_edge) begin
      if (state_pre == IDLE || commit)
        busreq_d = want && (busreq_pre || bai_n);
      else if ((state_pre == T2A || state_pre == TWA) && wait_n && !wants_after)
        busreq_d = 1'b0;
    end
  end

  always_comb begin
    state_d = state_pre;
    if (ck_edge) begin
      unique case (state_pre)
        IDLE:     if (start_idle) state_d = T1A;
        T1A:      state_d = T1B;
        T1B:      state_d = T2A;
        T2A, TWA: state_d = wait_n ? T2B : TWB;
        TWB:      state_d = TWA;
        T2B:      state_d = T3A;
        T3A:      state_d = T3B;
        T3B:      state_d = chain ? T1A : IDLE;
        default:  state_d = IDLE;
      endcase
    end
  end

  // Data latches: the write word from the FIFO at the start, the read
  // word from AD at the commit (even byte on AD15:8).
  always_comb begin
    word_d = word_q;
    if (commit && dir_d == DIR_READ) word_d = ad_in;
    if (start && dir_d == DIR_WRITE) word_d = fifo_w_rdata;
  end

  // DIR=read: the last B-side pop ends the block; DIR=write: the last
  // commit.
  assign blk_done = bd_at_limit &&
                    ((bd_pop && dmadone_pcsd) || (commit && last_word));
  // The block end came with the commit (CLK step), not a B-side pop; the
  // block was a continuous (sector-long) one.
  assign blk_commit = bd_at_limit && commit && last_word;
  assign blk_sector = lim_sector_d;

  initial begin
    dir_q        = DIR_WRITE;
    dmadone_q    = 1'b1;
    primed_q     = 1'b0;
    armed_q      = 1'b0;
    ss_mode_q    = 1'b0;
    ss_act_q     = 1'b0;
    bd_cnt_q     = 10'd0;
    lim_set_q    = 1'b0;
    lim_sector_q = 1'b0;
    busreq_q     = 1'b0;
    words_q      = 9'd0;
  end
  always_ff @(posedge clk) begin
    dir_q        <= dir_d;
    dmadone_q    <= e_dmadone;
    primed_q     <= primed_d;
    armed_q      <= e_armed;
    ss_mode_q    <= ss_mode_d;
    ss_act_q     <= e_ss;
    bd_cnt_q     <= bd_cnt_d;
    lim_set_q    <= lim_set_d;
    lim_sector_q <= lim_sector_d;
    busreq_q     <= busreq_d;
    words_q      <= e_words;
  end

  initial begin
    state_q = IDLE;
  end
  always_ff @(posedge clk) begin
    state_q <= state_d;
  end

  initial begin
    word_q = 16'h0000;
  end
  always_ff @(posedge clk) begin
    word_q <= word_d;
  end

  // CLKADR: High from the commit through the next CLK edge (two edges).
  initial begin
    clkadr_q      = 1'b0;
    clkadr_prev_q = 1'b0;
    clkadr_more_q = 1'b0;
  end
  always_ff @(posedge clk) begin
    clkadr_prev_q <= clkadr_q;
    clkadr_q      <= commit | (clkadr_more_q & ~reset_hold);
    clkadr_more_q <= commit | (clkadr_more_q & ~reset_hold & ~ck_edge);
  end

  assign dir         = dir_d;
  // BD7 DMADONE, BD6 BYTERDY (read: FIFO not empty; write: FIFO empty)
  // after this sample's B-side access, BD5 ERROR active low (never set),
  // BD4-0 zero.
  assign status = {dmadone_pcsd, (dir_d == DIR_READ) ? !fifo_mid_empty : fifo_mid_empty,
                   1'b1, 5'b00000};

  assign fifo_clr      = chip_rst | cmd_rst | pcsd_ss;
  assign fifo_hold_clr = reset_hold;
  assign fifo_w_push   = commit && dir_d == DIR_READ;
  assign fifo_w_pop    = start && dir_d == DIR_WRITE;
  assign fifo_w_wdata  = ad_in;

  // Pin decode (sheet 10).
  always_comb begin
    dmaen_n = 1'b0;
    mreq_n  = 1'b0;
    ds_n    = 1'b0;
    unique case (state_q)
      IDLE: begin dmaen_n = 1'b1; mreq_n = 1'b1; ds_n = 1'b1; end
      T1A:  begin mreq_n = 1'b1; ds_n = 1'b1; end
      T1B:  ds_n = 1'b1;
      T2A, T2B, TWA, TWB, T3A: ;
      T3B:  mreq_n = 1'b1;
      default: begin dmaen_n = 1'b1; mreq_n = 1'b1; ds_n = 1'b1; end
    endcase
  end

  // DIR=write drives the word T2..T3.  The pins decode the registered
  // sample result (state_q, word_q, dir_q); the _d values are the next
  // sample's.
  assign ad_oe    = dir_q == DIR_WRITE && !ds_n;
  assign ad_out   = ad_oe ? word_q : 16'h0000;
  assign busreq_n = !busreq_q;
  assign bao_n    = bai_n | busreq_q;
  assign clkadr_rise = clkadr_q & ~clkadr_prev_q;
  assign clkadr_fall = ~clkadr_q & clkadr_prev_q;

endmodule

`default_nettype wire
