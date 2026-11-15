// 5.25" drive emulator: raw record of one side (D11).  One entry per
// bit cell: a mask bit (the cell was written since the record began)
// and the written value; an unmasked cell reads as the layout walker's
// bit, so a new record needs no copy of the track.  Cells are kept 16
// to a 32-bit word {mask[15:0], value[15:0]}, 128 words to a 512-byte
// block.
//
// The lane is shared by two drives and serves the drive `own`; the
// records of both live on the image side (block jobs over sd_*, each for
// the drive `own` was at its issue).  The lane holds the head's block
// and the two after it in a four-slot ring.  `written`, per drive,
// marks the blocks the image side holds; any other block reads as zero
// and is never fetched.  A slot given such a block is zeroed in the RAM
// one word per clk (fill and head write-back first); until then its
// words not yet zeroed read as zero, a head write-back to one waits, and
// the slot is not written back.  While `act` (the record is for the
// head's track) the ring keeps the head's block and the two after it; dirty
// slots are written back when they leave the ring, and at once while no
// burst writes the record (`hold` low).  The ring works from the head's
// cell and track as registered (`h_cell`, `nwords`, `act`); a new record
// (`clr`) seeds the ring one clk later, with the blocks of the cell the
// head stood on at the `clr` (the cell of `h_cell` then, or after an
// `h_load` the new one).  `oclr` drops the other drive's record, `inv`
// empties the ring for a new owner (clean, no job and no seed, `busy`
// low).
//
// The word under the head (W) and the next one (Wn) sit in registers;
// writes go into W, and W is written into the ring when the head leaves
// it.  `h_rdy` is low while W is being loaded; `h_late` pulses when the
// head reaches a word before it was loaded (the ring was late).
//
// RAM: 512 x 32 with byte enables, one write port (block fill, which
// cannot wait, then the head's write-back, then the zeroing) and one read
// port (the image side's drain of a block when it moves to a new word,
// then the head).
`default_nettype none

module fd_raw
  import fd_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  input  logic [12:0] nwords,          // words of the head's track
  input  logic        act,
  input  logic        hold,
  // head
  input  logic        h_load,          // reload W and Wn for h_cell (from the next clk)
  input  logic [16:0] h_cell,          // the head's cell, registered
  input  logic        h_adv,           // the head leaves h_cell for the next cell
  input  logic        h_wrap,          // ... which is cell 0
  input  logic        h_set,           // write h_val into h_cell (with h_adv: the cell left)
  input  logic        h_val,
  input  logic        h_flush,         // write W back now
  output logic        h_mask,          // current cell
  output logic        h_data,
  output logic        h_rdy,
  output logic        h_late,
  output logic        h_full,          // W and Wn loaded, the ring holds its blocks
  input  logic        clr,
  input  logic        own,             // drive served
  input  logic        oclr,
  input  logic        inv,
  output logic        clean,           // the image side holds every write
  output logic        busy,            // a block job or a seed is under way
  output logic [1:0][RawBlocks-1:0] written,
  // block jobs (one at a time; payload held from rq to take)
  output logic        rq,
  output logic        rq_wr,
  output logic [5:0]  rq_blk,
  input  logic        take,
  input  logic        done,
  input  logic        pb_we,           // fill byte
  input  logic        pb_rd,           // drain: read port follows pb_addr
  input  logic [8:0]  pb_addr,
  input  logic [7:0]  pb_d,
  output logic [7:0]  pb_q
);

  typedef enum logic [2:0] {HIdle, HRdW, HGotW, HRdWn, HGetWn, HPre, HGetW} hst_e;

  // Justification: head words, their indices, pending write-back, reload state (reg-a).
  logic [31:0] w_q, wn_q;
  logic [12:0] wi_q, wni_q, rw_q;
  logic        wdirty_q;
  logic        wb_q, fl_q;
  logic [12:0] wbi_q;
  logic [31:0] wbd_q;
  hst_e        hs_q;
  // Justification: ring slots: valid, block, dirty, zero pending (reg-a).
  logic [3:0]   tv_q, td_q, pz_q;
  logic [5:0]   tb_q [4];
  // Justification: zeroing: active, slot, next word (reg-a).
  logic         sc_q;
  logic [1:0]   sck_q;
  logic [6:0]   scw_q;
  // Justification: a new record seeds the ring next clk; the head's blocks
  // at the clr and whether it came with an h_load (reg-a).
  logic         clr_q, hl_q;
  logic [5:0]   bs_q [3];
  // Justification: blocks the image side holds, per drive (reg-a).
  logic [1:0][RawBlocks-1:0] wr_q;
  // Justification: block job: pending, taken, slot, direction, block, cancelled, drive (reg-a).
  logic         jact_q, jtk_q, jwr_q, jcan_q, jd_q;
  logic [1:0]   jslot_q;
  logic [5:0]   jblk_q;
  // Justification: fill word assembly (reg-a).
  logic [3:0]   fa_be_q;
  logic [6:0]   fa_w_q;
  logic [31:0]  fa_d_q;
  // Justification: read port source, zero flag, drain word held, drain byte (reg-a).
  logic         rsrc_q, zq_q, drv_q;
  logic [6:0]   drw_q;
  logic [31:0]  drh_q, ram_q;
  logic [1:0]   pba_q;

  function automatic logic [12:0] after(input logic [12:0] w, input logic [12:0] n);
    return (w + 13'd1 >= n) ? 13'd0 : w + 13'd1;
  endfunction

  logic [12:0] hw_c;
  logic [3:0]  hb_c;
  logic [5:0]  lastb_c, b0_c, b1_c;
  assign hw_c    = 13'(h_cell >> 4);
  assign hb_c    = h_cell[3:0];
  assign lastb_c = 6'((nwords - 13'd1) >> 7);
  assign b0_c    = hw_c[12:7];
  assign b1_c    = (b0_c == lastb_c) ? 6'd0 : b0_c + 6'd1;

  // the word reads as zero: its slot waits for zeroing and the zeroing
  // has not reached it
  function automatic logic zw(input logic [1:0] k, input logic [6:0] w, input logic [3:0] pz,
                              input logic sc, input logic [1:0] sck, input logic [6:0] scw);
    return pz[k] && !(sc && sck == k && w < scw);
  endfunction

  // slots holding block b (one-hot or none) and the index of the hit
  function automatic logic [3:0] hits(input logic [5:0] b, input logic [3:0] tv, input logic [5:0] t [4]);
    for (int k = 0; k < 4; k++) hits[k] = tv[k] && t[k] == b;
  endfunction
  function automatic logic [1:0] enc(input logic [3:0] h);
    enc = 2'd0;
    for (int k = 0; k < 4; k++) if (h[k]) enc = 2'(k);
  endfunction

  // ------------------------------------------------------------------
  // Read port

  logic        drn_c;            // the drain needs the port
  logic [12:0] rdw_c;            // the head's word to read
  logic [3:0]  rh_c;
  logic [1:0]  rk_c;
  logic        rd_ok_c;
  assign drn_c = pb_rd && (!drv_q || pb_addr[8:2] != drw_q);
  always_comb begin
    unique case (hs_q)
      HRdWn:   rdw_c = after(wi_q, nwords);
      HPre:    rdw_c = wni_q;
      default: rdw_c = hw_c;
    endcase
  end
  assign rh_c    = hits(rdw_c[12:7], tv_q, tb_q);
  assign rk_c    = enc(rh_c);
  assign rd_ok_c = !wb_q && !drn_c && !clr_q && (!act || |rh_c);

  logic [8:0] raddr_c;
  logic       rz_c;
  assign raddr_c = drn_c ? {jslot_q, pb_addr[8:2]} : {rk_c, rdw_c[6:0]};
  assign rz_c    = drn_c ? zw(jslot_q, pb_addr[8:2], pz_q, sc_q, sck_q, scw_q) :
                   (!act || !(|rh_c) || zw(rk_c, rdw_c[6:0], pz_q, sc_q, sck_q, scw_q));


  logic [31:0] a_eff;
  assign a_eff = zq_q ? 32'd0 : ram_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rsrc_q <= 1'b0;  zq_q <= 1'b1;  drv_q <= 1'b0;  drw_q <= 7'd0;  drh_q <= 32'd0;  pba_q <= 2'd0;
    end else begin
      rsrc_q <= drn_c;
      zq_q   <= rz_c;
      pba_q  <= pb_addr[1:0];
      if (rsrc_q) drh_q <= a_eff;
      if (!pb_rd) drv_q <= 1'b0;
      else if (drn_c) begin drv_q <= 1'b1; drw_q <= pb_addr[8:2]; end
    end
  end

  logic [31:0] drw_word;
  assign drw_word = rsrc_q ? a_eff : drh_q;
  assign pb_q     = drw_word[8 * pba_q +: 8];

  // ------------------------------------------------------------------
  // Write port: fill words first, then the head's write-back.

  logic        fill_c, fwe_c, fnew_c;
  logic [3:0]  fbe_c, bsel_c;
  logic [31:0] fd_c;
  logic [6:0]  fw_c;
  assign fill_c = pb_we && jact_q && jtk_q && !jwr_q && !jcan_q;
  assign bsel_c = 4'b0001 << pb_addr[1:0];
  always_comb begin
    fwe_c  = 1'b0;  fnew_c = 1'b0;  fbe_c = fa_be_q;  fd_c = fa_d_q;  fw_c = fa_w_q;
    if (fill_c) begin
      if (fa_be_q != 4'd0 && pb_addr[8:2] != fa_w_q) begin
        fwe_c = 1'b1;  fnew_c = 1'b1;          // write the word assembled so far
      end else begin
        fbe_c = fa_be_q | bsel_c;
        fd_c  = fa_d_q;
        fd_c[8 * pb_addr[1:0] +: 8] = pb_d;
        fw_c  = pb_addr[8:2];
        fwe_c = fbe_c == 4'hF;
      end
    end else if (done && jact_q && !jwr_q && !jcan_q && fa_be_q != 4'd0) begin
      fwe_c = 1'b1;
    end
  end

  logic        wb_go_c, wz_c, scwe_c;
  logic [3:0]  wh_c;
  assign wh_c    = hits(wbi_q[12:7], tv_q, tb_q);
  assign wz_c    = |wh_c && zw(enc(wh_c), wbi_q[6:0], pz_q, sc_q, sck_q, scw_q);
  assign wb_go_c = wb_q && !fwe_c && !clr && !clr_q && !wz_c;
  assign scwe_c  = sc_q && !fwe_c && !(wb_go_c && |wh_c);

  logic [8:0]  waddr_c;
  logic [31:0] wdata_c;
  logic [3:0]  wbe_c;
  logic        we_c;
  always_comb begin
    waddr_c = {sck_q, scw_q};  wdata_c = 32'd0;  wbe_c = 4'hF;  we_c = scwe_c;
    if (fwe_c) begin
      waddr_c = {jslot_q, fw_c};  wdata_c = fd_c;  wbe_c = fbe_c;  we_c = 1'b1;
    end else if (wb_go_c && |wh_c) begin
      waddr_c = {enc(wh_c), wbi_q[6:0]};  wdata_c = wbd_q;  we_c = 1'b1;
    end
  end

  // simple dual port with byte enables (Quartus byte-enabled RAM template)
  (* ramstyle = "M10K" *) logic [3:0][7:0] mem [0:511];
  always_ff @(posedge clk) begin
    if (we_c) begin
      if (wbe_c[0]) mem[waddr_c][0] <= wdata_c[7:0];
      if (wbe_c[1]) mem[waddr_c][1] <= wdata_c[15:8];
      if (wbe_c[2]) mem[waddr_c][2] <= wdata_c[23:16];
      if (wbe_c[3]) mem[waddr_c][3] <= wdata_c[31:24];
    end
    ram_q <= mem[raddr_c];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fa_be_q <= 4'd0;  fa_w_q <= 7'd0;  fa_d_q <= 32'd0;
    end else if (fill_c && fnew_c) begin
      fa_be_q <= bsel_c;  fa_w_q <= pb_addr[8:2];
      fa_d_q  <= {24'd0, pb_d} << (8 * pb_addr[1:0]);
    end else if (fill_c) begin
      fa_be_q <= fwe_c ? 4'd0 : fbe_c;  fa_w_q <= fw_c;  fa_d_q <= fd_c;
    end else if (fwe_c || (jact_q && jcan_q)) begin
      fa_be_q <= 4'd0;
    end
  end

  // ------------------------------------------------------------------
  // Head

  logic [31:0] wb_c, wset_c;
  logic        bnd_c, hlate_c;
  assign wb_c    = clr ? {16'h0000, w_q[15:0]} : w_q;
  assign wset_c  = h_set ? ((wb_c | (32'd1 << (16 + hb_c))) & ~(32'd1 << hb_c)) | ({31'd0, h_val} << hb_c) : wb_c;
  assign bnd_c   = h_adv && (h_wrap || hb_c == 4'd15) && !h_load;
  // W is valid (writes and flushes allowed) except while it is being loaded
  logic wok_c;
  assign wok_c   = hs_q == HIdle || hs_q == HPre || hs_q == HGetW;
  // (a word left while W loads matters only while the head reads the record)
  assign hlate_c = (bnd_c && hs_q != HIdle && act) || (h_set && !wok_c && !h_load);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      w_q <= 32'd0;  wn_q <= 32'd0;  wi_q <= 13'd0;  wni_q <= 13'd0;  rw_q <= 13'd0;  wdirty_q <= 1'b0;
      wb_q <= 1'b0;  fl_q <= 1'b0;  wbi_q <= 13'd0;  wbd_q <= 32'd0;  hs_q <= HIdle;
    end else begin
      if (h_flush) fl_q <= 1'b1;
      if (wb_go_c || clr) wb_q <= 1'b0;
      if (h_load) begin
        hs_q <= HRdW;  wdirty_q <= 1'b0;  fl_q <= 1'b0;
        if (wdirty_q && !clr) begin wb_q <= 1'b1;  wbi_q <= wi_q;  wbd_q <= w_q; end
      end else begin
        unique case (hs_q)
          HRdW:   if (rd_ok_c) begin rw_q <= hw_c; hs_q <= HGotW; end
          HGotW:  begin w_q <= a_eff; wi_q <= rw_q; hs_q <= HRdWn; end
          HRdWn:  if (hw_c != wi_q) hs_q <= HRdW;
                  else if (rd_ok_c) hs_q <= HGetWn;
          HGetWn: begin
            wn_q <= a_eff;  wni_q <= after(wi_q, nwords);
            // the head crossed a word while loading: load again
            hs_q <= (hw_c != wi_q) ? HRdW : HIdle;
          end
          HPre:   if (rd_ok_c) hs_q <= HGetW;
          HGetW:  begin wn_q <= a_eff; hs_q <= HIdle; end
          default: hs_q <= HIdle;
        endcase
      end
      // a clear drops the masks of W and Wn; reads under way load again
      if (clr) begin
        w_q[31:16] <= 16'h0000;  wn_q[31:16] <= 16'h0000;  wdirty_q <= 1'b0;
        if (!h_load) begin
          if (hs_q == HRdW || hs_q == HGotW || hs_q == HRdWn || hs_q == HGetWn) hs_q <= HRdW;
          if (hs_q == HPre || hs_q == HGetW) hs_q <= HPre;
        end
      end
      // writes into the current word (after the clear: a write in the same clk wins)
      if (h_set && wok_c) begin
        w_q[16 + hb_c]    <= 1'b1;
        w_q[{1'b0, hb_c}] <= h_val;
        wdirty_q          <= 1'b1;
      end
      // the head leaves the word: W <- Wn, write W back, fetch the next Wn
      if (bnd_c && hs_q == HIdle) begin
        fl_q <= 1'b0;
        if (wdirty_q || h_set) begin wb_q <= 1'b1;  wbi_q <= wi_q;  wbd_q <= wset_c; end
        w_q  <= clr ? {16'h0000, wn_q[15:0]} : wn_q;  wi_q <= wni_q;  wdirty_q <= 1'b0;
        wni_q <= after(wni_q, nwords);
        hs_q <= HPre;
      end else if (bnd_c) begin
        if (wdirty_q || h_set) begin wb_q <= 1'b1;  wbi_q <= wi_q;  wbd_q <= wset_c; end
        wdirty_q <= 1'b0;
        hs_q <= HRdW;  fl_q <= 1'b0;
      end else if ((h_flush || fl_q) && wok_c && !wb_q && !h_load) begin
        // a flush waits for a write-back under way (it would replace it)
        fl_q <= 1'b0;
        if (wdirty_q || h_set) begin
          wb_q  <= 1'b1;  wbi_q <= wi_q;  wbd_q <= wset_c;
          wdirty_q <= 1'b0;
        end
      end
    end
  end

  // ------------------------------------------------------------------
  // Ring: keep the head's block and the next; write dirty slots back.

  // keep the head's block and the two after it (the last block of a track
  // can be a few words long, so one block of look-ahead is not enough)
  logic [5:0] b2_c;
  assign b2_c = (b1_c == lastb_c) ? 6'd0 : b1_c + 6'd1;
  logic [3:0] h0_c, h1_c, h2_c, want_c, evict_c, free_c;
  assign h0_c = hits(b0_c, tv_q, tb_q);
  assign h1_c = hits(b1_c, tv_q, tb_q);
  assign h2_c = hits(b2_c, tv_q, tb_q);
  assign want_c = act ? (h0_c | h1_c | h2_c) : 4'd0;
  always_comb
    for (int k = 0; k < 4; k++) begin
      evict_c[k] = tv_q[k] && td_q[k] && (!want_c[k] || !hold) && !pz_q[k];
      free_c[k]  = !want_c[k] && !(tv_q[k] && td_q[k]);
    end
  // the blocks a new record seeds
  logic [5:0] sb_c [3];
  assign sb_c[0] = hl_q ? b0_c : bs_q[0];
  assign sb_c[1] = hl_q ? b1_c : bs_q[1];
  assign sb_c[2] = hl_q ? b2_c : bs_q[2];
  // lowest set bit
  function automatic logic [1:0] first(input logic [3:0] v);
    first = 2'd0;
    for (int k = 3; k >= 0; k--) if (v[k]) first = 2'(k);
  endfunction

  logic       mgr_c, iss_c, iwr_c, izero_c, need_c;
  logic [1:0] ik_c;
  logic [5:0] iblk_c;
  always_comb begin
    mgr_c = !jact_q && !wb_q && !clr_q;
    iss_c = 1'b0;  iwr_c = 1'b0;  ik_c = first(free_c);  iblk_c = b0_c;  izero_c = 1'b0;  need_c = 1'b0;
    if (act && !(|h0_c))      begin need_c = 1'b1; iblk_c = b0_c; end
    else if (act && !(|h1_c)) begin need_c = 1'b1; iblk_c = b1_c; end
    else if (act && !(|h2_c)) begin need_c = 1'b1; iblk_c = b2_c; end
    if (mgr_c) begin
      if (|evict_c) begin
        iss_c = 1'b1;  iwr_c = 1'b1;  ik_c = first(evict_c);  iblk_c = tb_q[first(evict_c)];
      end else if (need_c && |free_c) begin
        if (iblk_c < 6'(RawBlocks) && wr_q[own][iblk_c]) iss_c = 1'b1; else izero_c = 1'b1;
      end
    end
  end

  logic jfill_c;   // a read job completes into its slot
  assign jfill_c = done && jact_q && !jwr_q && !jcan_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      clr_q <= 1'b0;  hl_q <= 1'b0;
      for (int i = 0; i < 3; i++) bs_q[i] <= 6'd0;
    end else begin
      clr_q <= clr;  hl_q <= h_load;
      bs_q[0] <= b0_c;  bs_q[1] <= b1_c;  bs_q[2] <= b2_c;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tv_q <= 4'd0;  td_q <= 4'd0;  pz_q <= 4'd0;
      for (int k = 0; k < 4; k++) tb_q[k] <= 6'd0;
      sc_q <= 1'b0;  sck_q <= 2'd0;  scw_q <= 7'd0;
      wr_q <= '0;
      jact_q <= 1'b0;  jtk_q <= 1'b0;  jslot_q <= 2'd0;  jwr_q <= 1'b0;  jcan_q <= 1'b0;  jblk_q <= 6'd0;
      jd_q <= 1'b0;
    end else begin
      if (take) jtk_q <= 1'b1;
      if (done) begin
        jact_q <= 1'b0;  jtk_q <= 1'b0;
        if (jwr_q && !jcan_q && jblk_q < 6'(RawBlocks)) wr_q[jd_q][jblk_q] <= 1'b1;
      end
      if (jfill_c) tv_q[jslot_q] <= 1'b1;
      // zeroing: one word per write-port clk; the next pending slot, the
      // head's block first
      if (scwe_c) begin
        scw_q <= scw_q + 7'd1;
        if (scw_q == 7'd127) begin sc_q <= 1'b0; pz_q[sck_q] <= 1'b0; end
      end
      if (!sc_q && |pz_q && !iss_c) begin
        sc_q <= 1'b1;  sck_q <= |(pz_q & h0_c) ? first(pz_q & h0_c) : first(pz_q);  scw_q <= 7'd0;
      end
      if (iss_c) begin
        jact_q <= 1'b1;  jtk_q <= 1'b0;  jslot_q <= ik_c;  jwr_q <= iwr_c;  jblk_q <= iblk_c;  jcan_q <= 1'b0;
        jd_q   <= own;
        if (iwr_c) td_q[ik_c] <= 1'b0;
        else begin
          tv_q[ik_c] <= 1'b0;  tb_q[ik_c] <= iblk_c;  td_q[ik_c] <= 1'b0;  pz_q[ik_c] <= 1'b0;
          if (sc_q && sck_q == ik_c) sc_q <= 1'b0;
        end
      end
      if (izero_c) begin
        tv_q[ik_c] <= 1'b1;  tb_q[ik_c] <= iblk_c;  td_q[ik_c] <= 1'b0;  pz_q[ik_c] <= 1'b1;
        if (sc_q && sck_q == ik_c) scw_q <= 7'd0;
      end
      // the head's write-back lands in its slot
      if (wb_go_c && |wh_c) td_q[enc(wh_c)] <= 1'b1;
      // a new record: the blocks are empty and a job under way is void ...
      if (clr) begin
        wr_q[own] <= '0;
        if (jact_q && !done) jcan_q <= 1'b1;
      end
      if (oclr) wr_q[!own] <= '0;
      if (inv) begin
        tv_q <= 4'd0;  td_q <= 4'd0;  pz_q <= 4'd0;  sc_q <= 1'b0;
      end
      // ... then three slots hold the head's blocks, zeroed head block first
      if (clr_q) begin
        tv_q <= 4'b0111;  td_q <= 4'd0;  pz_q <= 4'b0111;
        for (int i = 0; i < 3; i++) tb_q[i] <= sb_c[i];
        sc_q <= 1'b1;  sck_q <= 2'd0;  scw_q <= 7'd0;
        if (jact_q && !done) jcan_q <= 1'b1;
      end
    end
  end

  assign rq      = jact_q && !jtk_q;
  assign rq_wr   = jwr_q;
  assign rq_blk  = jblk_q;
  assign clean   = !wdirty_q && !wb_q && !(|(td_q & tv_q)) && !(jact_q && jwr_q);
  assign busy    = jact_q || clr_q;
  assign written = wr_q;

  assign h_mask = w_q[16 + hb_c];
  assign h_data = w_q[{1'b0, hb_c}];
  assign h_rdy  = !(hs_q == HRdW || hs_q == HGotW || hs_q == HRdWn || hs_q == HGetWn);
  assign h_late = hlate_c || (wb_go_c && !(|wh_c));
  assign h_full = hs_q == HIdle && !need_c;

endmodule

`default_nettype wire
