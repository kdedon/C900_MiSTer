// 5.25" drive emulator: one drive (stepper, spindle, write bursts and
// the state of its raw records) on the digital drive port.  The walk of
// both heads (fd_layout) and the records' rings (fd_raw) are shared by
// the drives and follow this drive while `own`; the decode comes from
// the shared fd_scan: this drive asks for a decode (`dq_*`) and the
// controller starts it (`dgo`).
//
// `wrgt` and `wd` are this drive's: the head matrix gives the write
// current to the selected drive only.  A burst starts only while `own`
// and the walk is ready after `resk`; WRGT otherwise records nothing and
// sets `late`.  RDATA is low while not `own`, and after `resk` until the
// walk and the rings are ready.
// `late` pulses at a tick where the head should read (medium in, motor
// turning, on track) but its data is not there; after a mount, from the
// walk's first ready tick, after `resk` from RDATA's.  A mount or `resk` puts
// the walk back on the platter (as a step does, without the off-track
// time).
//
// The tick's decisions use the phases, the spindle and the medium at that
// tick; the walk, the raw records and the image side take the track and
// cell as registered at the tick.
`default_nettype none

module fd_head #(
  parameter int unsigned STEP_TICKS   = 18000,
  parameter int unsigned SETTLE_TICKS = 90000,
  parameter int unsigned SPINUP_TICKS = 2400000
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        ce,
  // drive port
  input  logic [3:0]  ph,
  input  logic        mtron,
  input  logic        hosel,
  input  logic        wrgt,
  input  logic        wd,
  output logic        rdata,
  output logic        trk0,
  output logic        wrpt,
  output logic        late,
  // medium
  input  logic        mount_ev,
  input  logic        present_q,
  input  logic        ro_q,
  // shared walk: this drive owns it (no switch pending); reseek
  input  logic        own,
  input  logic        resk,
  output logic [6:0]  trk,
  output logic        l_seek,
  output logic [16:0] l_pos,
  output logic        l_adv,
  input  logic        l_rdy,
  input  logic        l_ahead,         // and the next byte is fetched
  input  logic        l_lost,
  input  logic [1:0]  l_bits,
  input  logic        l_warm,          // the walk's sectors are buffered
  // shared raw record rings, per side
  output logic [12:0] r_nwords,
  output logic [1:0]  r_act,
  output logic [1:0]  r_hold,
  output logic        r_load,
  output logic [16:0] r_cell,
  output logic        r_adv,
  output logic        r_wrap,
  output logic [1:0]  r_set,
  output logic [1:0]  r_val,
  output logic [1:0]  r_flush,
  output logic [1:0]  r_clr,
  input  logic [1:0]  r_mask,
  input  logic [1:0]  r_data,
  input  logic [1:0]  r_rdy,
  input  logic [1:0]  r_late,
  input  logic [1:0]  r_full,
  input  logic [1:0]  r_clean,
  output logic        wron,
  // decode and commit
  output logic        dq_v,            // a record waits for a decode and may start
  output logic        dq_side,
  output logic [6:0]  dq_trk,
  input  logic        dgo,
  input  logic        downs,           // the decode under way is this drive's
  output logic        dabort,
  input  logic        ddone,
  input  logic        dclean,
  input  logic        cm_busy,
  output logic        cm_req
);
  import fd_pkg::*;

  localparam logic [23:0] OffTicks = 24'(STEP_TICKS + SETTLE_TICKS);
  localparam logic [22:0] Full     = 23'(SPINUP_TICKS);

  logic writable_c, ready_c;
  assign writable_c = present_q && !ro_q;
  assign ready_c    = present_q;

  // Justification: commit request (reg-a).
  logic cm_req_q;

  // ------------------------------------------------------------------
  // Stepper

  // Justification: last phase nibble, step table index, head track, off-track time (reg-a).
  logic [3:0]  nib_q;
  logic [1:0]  sidx_q;
  logic [6:0]  trk_q;
  logic [23:0] off_q;

  logic        hit_c, chg_c, up_c, dn_c, moved_c;
  logic [1:0]  pidx_c, sidx_n;
  logic [6:0]  trk_n;
  always_comb begin
    hit_c = 1'b1;
    case (ph)
      4'h5:    pidx_c = 2'd0;
      4'h6:    pidx_c = 2'd1;
      4'hA:    pidx_c = 2'd2;
      4'h9:    pidx_c = 2'd3;
      default: begin pidx_c = 2'd0; hit_c = 1'b0; end
    endcase
  end
  assign chg_c   = ph != nib_q && hit_c;
  assign up_c    = chg_c && pidx_c - sidx_q == 2'd1 && trk_q < 7'd79;
  assign dn_c    = chg_c && pidx_c - sidx_q == 2'd3 && trk_q > 7'd0;
  assign moved_c = up_c || dn_c;
  assign sidx_n  = chg_c ? pidx_c : sidx_q;
  assign trk_n   = up_c ? trk_q + 7'd1 : dn_c ? trk_q - 7'd1 : trk_q;

  logic [23:0] off_n;
  assign off_n = moved_c ? OffTicks - 24'd1 : (off_q != 24'd0 ? off_q - 24'd1 : 24'd0);

  // ------------------------------------------------------------------
  // Spindle

  // Justification: spindle speed and its accumulator (reg-a).
  logic [22:0] lvl_q;
  logic [23:0] acc_q;
  logic        adv_c;
  logic [22:0] lvl_n;
  logic [23:0] acc_n;
  always_comb begin
    lvl_n = lvl_q;  acc_n = acc_q;  adv_c = mtron;
    if (Full != 23'd0) begin
      if (mtron && lvl_q < Full)       lvl_n = lvl_q + 23'd1;
      else if (!mtron && lvl_q != 23'd0) lvl_n = lvl_q - 23'd1;
      acc_n = acc_q + {1'b0, lvl_n};
      adv_c = acc_n >= {1'b0, Full};
      if (adv_c) acc_n = acc_n - {1'b0, Full};
    end
  end

  // ------------------------------------------------------------------
  // Rotation: ticks into the revolution, and per zone the cell and the
  // tick in the cell.

  // Justification: platter angle; per-zone cell index and phase (reg-a).
  logic [20:0] pos_q;
  logic [16:0] zq_q [4];
  logic [4:0]  zr_q [4];

  // The revolution is rev_of(zone) with a medium, RevTicksNom without
  // (index 4).  Every comparison of the angle is made for each of them and
  // the tick's track picks one.  The angle is below the longest revolution,
  // so past a shorter one it is under 32 ticks over.
  logic [1:0]  z_c, zq_c;
  logic [2:0]  ri_c;
  logic [4:0]  ge_c, gm_c;
  logic [4:0]  d5_c [5];
  logic [4:0]  d5m_c;
  logic [20:0] pos_m;
  logic [16:0] zq_m [4];
  logic [4:0]  zr_m [4];
  logic        modj_c, wrapn_c;
  always_comb
    for (int i = 0; i < 5; i++) begin : revs
      logic [20:0] r;
      r        = (i == 4) ? RevTicksNom : rev_of(2'(i));
      ge_c[i]  = pos_q >= r;
      gm_c[i]  = pos_q >= r - 21'd1;
      d5_c[i]  = pos_q[4:0] - r[4:0];
    end
  assign zq_c   = zone_of(trk_q);
  assign z_c    = up_c ? zone_of(trk_q + 7'd1) : dn_c ? zone_of(trk_q - 7'd1) : zq_c;
  assign ri_c   = present_q ? {1'b0, z_c} : 3'd4;
  // the angle modulo this track's revolution (a step into a shorter one)
  assign modj_c = present_q && ge_c[{1'b0, z_c}];
  assign d5m_c  = d5_c[{1'b0, z_c}];
  always_comb begin
    pos_m = modj_c ? {16'd0, d5m_c} : pos_q;
    for (int z = 0; z < 4; z++) begin
      zq_m[z] = zq_q[z];  zr_m[z] = zr_q[z];
      if (modj_c) begin
        zq_m[z] = (d5m_c >= cell_of(2'(z))) ? 17'd1 : 17'd0;
        zr_m[z] = (d5m_c >= cell_of(2'(z))) ? d5m_c - cell_of(2'(z)) : d5m_c;
      end
    end
  end

  logic [16:0] cell_c;
  logic [4:0]  cph_c;
  assign cell_c = zq_m[z_c];
  assign cph_c  = zr_m[z_c];

  // ------------------------------------------------------------------
  // Head position bookkeeping for the walker and the raw records.

  // Justification: the cell and track the walker and raw trackers stand on;
  // a mount puts the walk back on the platter (reg-a).
  logic [16:0] lc_q;
  logic [6:0]  ltrk_q;
  logic        rsk_q;
  logic        jump_c, cadv_c, cwrap_c, cend_c;
  logic [16:0] cell_n;
  logic [20:0] pos_n;

  // the platter passes the revolution's end (never right after a modulo)
  assign wrapn_c = adv_c && !modj_c && gm_c[ri_c];
  always_comb begin
    pos_n = pos_m;
    if (wrapn_c)     pos_n = 21'd0;
    else if (adv_c)  pos_n = modj_c ? {16'd0, d5m_c} + 21'd1 : pos_q + 21'd1;
  end
  // the cell after this tick
  assign cend_c  = adv_c && cph_c == cell_of(z_c) - 5'd1;
  assign cell_n  = wrapn_c ? 17'd0 : cend_c ? cell_c + 17'd1 : cell_c;
  // without a jump the cell is lc_q, so the head moves on iff the cell ends
  assign jump_c  = moved_c || trk_q != ltrk_q || modj_c || rsk_q;
  assign cadv_c  = !jump_c && (wrapn_c || cend_c);
  assign cwrap_c = wrapn_c;

  logic        lay_rdy, lay_lost;
  logic [1:0]  lbits;
  assign l_seek  = ce && jump_c;
  assign l_pos   = cell_n;
  assign l_adv   = ce && cadv_c;
  assign lay_rdy = l_rdy;
  assign lay_lost = l_lost;
  assign lbits   = l_bits;
  assign trk     = trk_q;

  // ------------------------------------------------------------------
  // Write bursts and raw records.

  // Justification: write burst state, cell hit, WD level (reg-a).
  logic        wron_q, wrside_q, chit_q, wd_q;
  logic [6:0]  wrtrk_q;
  // Justification: raw records per side: valid, track, RAM clean, touched since decode (reg-a).
  logic [1:0]  rv_q, rclean_q, touch_q, pdec_q;
  logic [6:0]  rtag_q [2];
  logic        side_c, edge_c, wtick_c, wstart_c, wend_c, hit_now_c;

  assign side_c    = hosel;
  assign edge_c    = wd != wd_q;
  assign wend_c    = wron_q && (!wrgt || !(mtron && present_q) || !writable_c ||
                                trk_n != wrtrk_q || side_c != wrside_q);
  assign wtick_c   = adv_c && wrgt && mtron && ready_c && writable_c && own && !swait_q;
  assign wstart_c  = wtick_c && (!wron_q || wend_c);
  assign hit_now_c = wtick_c && edge_c;

  logic [12:0] nwords_c;
  assign nwords_c = 13'((nbits_of(zq_c) + 17'd15) >> 4);

  logic [1:0]  r_clr_q, r_clr_c, raw_on, raw_onq;

  // A burst that starts a new record clears the RAM in the same clk
  // (its first cell is written in the same clk and wins).
  always_comb begin
    r_clr_c = 2'b00;
    if (ce && wstart_c && !(rv_q[side_c] && rtag_q[side_c] == trk_n) && (rv_q[side_c] || !rclean_q[side_c]))
      r_clr_c[side_c] = 1'b1;
  end
  assign r_clr = r_clr_q | r_clr_c;

  // Leaving a cell inside a burst writes it (1 = a WD edge in it); the
  // end of a burst writes the current cell only if it had an edge.
  always_comb begin
    r_set = 2'b00;  r_flush = 2'b00;  r_val = 2'b11;
    if (ce && wron_q && wend_c) begin
      r_set[wrside_q]   = chit_q;
      r_flush[wrside_q] = 1'b1;
    end else if (ce && wron_q && cadv_c) begin
      r_set[wrside_q] = 1'b1;
      r_val[wrside_q] = chit_q || hit_now_c;
    end
    // a burst that starts in the last tick of a cell writes that cell too
    if (ce && wstart_c && cadv_c && !(wend_c && side_c == wrside_q)) begin
      r_set[side_c] = 1'b1;
      r_val[side_c] = hit_now_c;
    end
  end

  genvar gs;
  generate
  for (gs = 0; gs < 2; gs++) begin : g_raw
    assign raw_on[gs]  = rv_q[gs] && rtag_q[gs] == trk_n;
    assign raw_onq[gs] = rv_q[gs] && rtag_q[gs] == trk_q;
    assign r_hold[gs]  = wron_q && wrside_q == 1'(gs);
  end
  endgenerate
  assign r_nwords = nwords_c;
  assign r_act    = raw_onq;
  assign r_load   = ce && jump_c;
  assign r_cell   = lc_q;
  assign r_adv    = ce && cadv_c;
  assign r_wrap   = cwrap_c;
  assign wron     = wron_q;

  // ------------------------------------------------------------------
  // Read output

  logic moving_c, raw_on_c, rec_c;
  assign moving_c = lvl_n != 23'd0 || (Full == 23'd0 && mtron);
  assign raw_on_c = raw_on[side_c];
  assign rec_c    = (ce && wstart_c && hit_now_c) ? 1'b1 :
                    !raw_on_c ? lbits[side_c] :
                    (wron_q && !wend_c && side_c == wrside_q && (chit_q || hit_now_c)) ? 1'b1 :
                    r_mask[side_c] ? r_data[side_c] : lbits[side_c];


  // ------------------------------------------------------------------
  // Decode requests

  logic        dside_q, await_q;
  logic        dside_c;
  assign dside_c = pdec_q[0] ? 1'b0 : 1'b1;
  assign dq_v    = |pdec_q && !cm_req_q && !await_q && !(ce && wstart_c) && r_clean[dside_c];
  assign dq_side = dside_c;
  assign dq_trk  = rtag_q[dside_c];
  assign dabort  = ce && wstart_c && downs && side_c == dside_q;
  assign cm_req  = cm_req_q;

  // ------------------------------------------------------------------
  // Tick registers

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      nib_q <= 4'h0;  sidx_q <= 2'd0;  trk_q <= 7'd0;  off_q <= 24'd0;
      lvl_q <= 23'd0;  acc_q <= 24'd0;  pos_q <= 21'd0;
      for (int z = 0; z < 4; z++) begin zq_q[z] <= 17'd0; zr_q[z] <= 5'd0; end
      lc_q <= 17'd0;  ltrk_q <= 7'd127;  rsk_q <= 1'b0;
    end else if (ce) begin
      nib_q <= ph;  sidx_q <= sidx_n;  trk_q <= trk_n;  off_q <= off_n;
      lvl_q <= lvl_n;  acc_q <= acc_n;  pos_q <= pos_n;
      rsk_q <= mount_ev || resk;
      for (int z = 0; z < 4; z++) begin
        if (wrapn_c) begin
          zq_q[z] <= 17'd0;  zr_q[z] <= 5'd0;
        end else if (adv_c && zr_m[z] == cell_of(2'(z)) - 5'd1) begin
          zq_q[z] <= zq_m[z] + 17'd1;  zr_q[z] <= 5'd0;
        end else if (adv_c) begin
          zq_q[z] <= zq_m[z];  zr_q[z] <= zr_m[z] + 5'd1;
        end else begin
          zq_q[z] <= zq_m[z];  zr_q[z] <= zr_m[z];
        end
      end
      lc_q   <= cell_n;
      ltrk_q <= trk_n;
    end else if (mount_ev || resk) begin
      rsk_q <= 1'b1;
    end
  end

  // write bursts
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wron_q <= 1'b0;  wrside_q <= 1'b0;  chit_q <= 1'b0;  wd_q <= 1'b0;  wrtrk_q <= 7'd0;
    end else if (mount_ev) begin
      wron_q <= 1'b0;
    end else if (ce) begin
      wd_q <= wd;
      if (wend_c) wron_q <= 1'b0;
      if (wstart_c) begin
        wron_q <= 1'b1;  wrside_q <= side_c;  wrtrk_q <= trk_n;
      end
      if (wtick_c && cadv_c) chit_q <= 1'b0;
      else if (hit_now_c)    chit_q <= 1'b1;
      if (wstart_c && !hit_now_c) chit_q <= 1'b0;
      if (wstart_c && cadv_c)     chit_q <= 1'b0;
    end
  end

  // raw records, decodes and commits
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rv_q <= 2'b00;  rclean_q <= 2'b00;  touch_q <= 2'b00;  pdec_q <= 2'b00;
      rtag_q[0] <= 7'd0;  rtag_q[1] <= 7'd0;  r_clr_q <= 2'b00;
      dside_q <= 1'b0;  await_q <= 1'b0;  cm_req_q <= 1'b0;
    end else if (mount_ev) begin
      rv_q <= 2'b00;  pdec_q <= 2'b00;  touch_q <= 2'b00;  await_q <= 1'b0;  cm_req_q <= 1'b0;
      rclean_q <= 2'b00;  r_clr_q <= 2'b11;
    end else begin
      r_clr_q  <= 2'b00;
      cm_req_q <= 1'b0;
      if (ce && wend_c) pdec_q[wrside_q] <= 1'b1;
      if (ce && wstart_c) begin
        touch_q[side_c] <= 1'b1;
        pdec_q[side_c]  <= 1'b0;
        if (!(rv_q[side_c] && rtag_q[side_c] == trk_n)) begin
          rv_q[side_c] <= 1'b1;  rtag_q[side_c] <= trk_n;  rclean_q[side_c] <= 1'b0;
        end
      end
      if (dgo) begin
        dside_q <= dside_c;  pdec_q[dside_c] <= 1'b0;  touch_q[dside_c] <= 1'b0;
      end
      if (ddone && dclean && writable_c) begin
        cm_req_q <= 1'b1;  await_q <= 1'b1;
      end
      if (await_q && !cm_busy && !cm_req_q) begin
        await_q <= 1'b0;
        if (!touch_q[dside_q] && !pdec_q[dside_q] && !(wron_q && wrside_q == dside_q)) begin
          rv_q[dside_q] <= 1'b0;  r_clr_q[dside_q] <= 1'b1;
        end
      end
      for (int s = 0; s < 2; s++)
        if (!rv_q[s] && !r_clr_q[s] && !(ce && wstart_c && side_c == 1'(s))) rclean_q[s] <= 1'b1;
    end
  end

  // ------------------------------------------------------------------
  // Outputs

  // Justification: drive port outputs, one per pin; data-late flag; no
  // data deadlines from a mount to the walk's first ready tick, no RDATA
  // and no deadlines from a reseek until walk and rings are ready (reg-a).
  logic rdata_q, trk0_q, wrpt_q, late_q, mwait_q, swait_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rdata_q <= 1'b0;  trk0_q <= 1'b1;  wrpt_q <= 1'b0;  late_q <= 1'b0;  mwait_q <= 1'b0;  swait_q <= 1'b0;
    end else begin
      if (mount_ev)                       mwait_q <= 1'b1;
      else if (ce && !jump_c && lay_rdy)  mwait_q <= 1'b0;
      if (resk) swait_q <= 1'b1;
      else if (ce && (!present_q || (!jump_c && l_ahead && l_warm && (!raw_on[0] || r_full[0]) && (!raw_on[1] || r_full[1]))))
        swait_q <= 1'b0;
      late_q <= (own && present_q && !mwait_q && !swait_q &&
                 (|r_late || lay_lost || (ce && moving_c && off_n == 24'd0 && !jump_c &&
                  (!lay_rdy || (raw_on[0] && !r_rdy[0]) || (raw_on[1] && !r_rdy[1]))))) ||
                (ce && (!own || swait_q) && adv_c && wrgt && mtron && ready_c && writable_c);
      if (ce) begin
        trk0_q  <= trk_n == 7'd0;
        wrpt_q  <= present_q && ro_q;
        rdata_q <= own && !swait_q && present_q && moving_c && ready_c && off_n == 24'd0 && cph_c < 5'd2 && rec_c && lay_rdy &&
                   !jump_c;
      end
    end
  end

  assign rdata = rdata_q;
  assign trk0  = trk0_q;
  assign wrpt  = wrpt_q;
  assign late  = late_q;

endmodule

`default_nettype wire
