// 5.25" drive emulator: decoder of a raw record (D11), run when a write
// burst ends.  It reads the track as the 8723 does (10-bit shifter, ten
// ones = sync, two GCR quintets per byte, a field ends at an invalid
// quintet or the next sync) once around: ten cells of warm-up before
// cell 0, every field that starts in the revolution, and the last field
// to its end past cell 0.  Then the firmware's FindSector rule: each ID
// field (08 CYL SEC XOR) must be followed by a data field (07, 512
// bytes, XOR) with a good checksum, for this cylinder, every sector of
// the track exactly once; the pairing wraps (the last ID's data field
// is the first field).  A data field that follows an ID is written to
// staging slot SEC, the first field of the revolution to slot 16.
//
// `clean` with `done`: the record holds the track's sector set; `map16`
// names the sector whose data is in slot 16.  The record word is read one
// clk after `r_addr` once `r_ok`; `stall` holds the scan (staging busy).
`default_nettype none

module fd_scan (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        start,
  input  logic        abort,
  input  logic        side,
  input  logic [6:0]  track,
  output logic        busy,
  output logic        done,
  output logic        clean,
  output logic [4:0]  map16,           // {valid, sector}
  input  logic        stall,
  // raw record of `side` (one clk after r_addr, once r_ok)
  output logic [12:0] r_addr,
  input  logic        r_ok,
  input  logic [31:0] r_q,
  // cylinder buffer (via the layout walker)
  output logic        req,
  output logic [13:0] raddr,
  input  logic        gnt,
  input  logic [7:0]  rdata,
  output logic        need,
  output logic [4:0]  ck_idx,
  input  logic [7:0]  ck_q,
  output logic [4:0]  lsec,
  output logic        lsec_ok,
  // staging
  output logic        st_we,
  output logic [13:0] st_addr,
  output logic [7:0]  st_d
);
  import fd_pkg::*;

  typedef enum logic [2:0] {SIdle, SSeek, SWord, SBit, SEnd} sst_e;

  // Justification: scan sequencer, position, phase counters (reg-a).
  sst_e        st_q;
  logic [16:0] p_q, nb_q;
  logic [17:0] left_q;
  logic [1:0]  ph_q;                  // 0 warm-up, 1 window, 2 tail
  logic [12:0] wi_q;
  logic        wok_q;
  // Justification: read path state (reg-a).
  logic [9:0]  sh_q;
  logic [3:0]  n_q;
  logic        open_q;
  logic [9:0]  len_q;
  // Justification: current field contents (reg-a).
  logic        idc_q, dc_q;
  logic [7:0]  b1_q, b2_q, b3_q, ckc_q, ckr_q;
  logic [4:0]  slot_q;                // staging slot, 31 = none
  // Justification: pairing state (reg-a).
  logic        pend_q, nfirst_q, fdat_q, fail_q;
  logic [3:0]  psec_q;
  logic [15:0] found_q;
  logic        done_q, clean_q;
  logic [4:0]  map_q;

  logic        lrdy, lbit_c, lseek, ladv, lwrap, llost, lahead;
  logic [0:0]  lbits;

  // Justification: side and track of the record being decoded (reg-a).
  logic       side_q;
  logic [6:0] trk_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                       begin side_q <= 1'b0; trk_q <= 7'd0; end
    else if (st_q == SIdle && start) begin side_q <= side; trk_q <= track; end
  end

  fd_layout #(.NS(1)) u_lay (
    .clk, .rst_n, .track(st_q == SIdle ? track : trk_q), .side0(st_q == SIdle ? side : side_q), .seek(lseek), .pos(nbits_of(zone_of(track)) - 17'd10), .adv(ladv),
    .rdy(lrdy), .ahead(lahead), .bit_q(lbits), .req, .raddr, .need, .gnt, .rdata, .ck_idx, .ck_q,
    .sec(lsec), .sec_ok(lsec_ok), .lost(llost)
  );
  assign lbit_c = lbits[0];

  logic unused_ok;
  assign unused_ok = &{1'b0, sh_q[9], llost, lahead};

  logic [1:0]  z_c;
  logic [4:0]  nsec_c;
  assign z_c    = zone_of(trk_q);
  assign nsec_c = spt_of(z_c);

  logic        bit_c, sync_c, byte_c, bad_c;
  logic [9:0]  sh_n;
  logic [4:0]  dhi_c, dlo_c;
  logic [7:0]  bv_c;
  assign bit_c  = r_q[16 + p_q[3:0]] ? r_q[{1'b0, p_q[3:0]}] : lbit_c;
  assign sh_n   = {sh_q[8:0], bit_c};
  assign sync_c = sh_n == 10'h3FF;
  assign byte_c = !sync_c && n_q == 4'd9;
  assign dhi_c  = gcr_dec(sh_n[9:5]);
  assign dlo_c  = gcr_dec(sh_n[4:0]);
  assign bad_c  = !(dhi_c[4] && dlo_c[4]);
  assign bv_c   = {dhi_c[3:0], dlo_c[3:0]};

  logic step_c;
  assign step_c = st_q == SBit && lrdy && wok_q && wi_q == 13'(p_q >> 4) && !stall;
  assign lseek  = st_q == SIdle && start;
  assign ladv   = step_c;
  assign lwrap  = p_q == nb_q - 17'd1;
  assign r_addr = 13'(p_q >> 4);

  // field end: the open field closes this bit (sync, bad quintet)
  logic fend_c;
  assign fend_c = step_c && open_q && (sync_c || (byte_c && bad_c));

  // the closing field's verdict
  logic is_id_c, dok_c;
  assign is_id_c = idc_q && len_q >= 10'd4;
  assign dok_c   = dc_q && len_q >= 10'd514 && ckc_q == ckr_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_q <= SIdle;  p_q <= 17'd0;  nb_q <= 17'd0;  left_q <= 18'd0;  ph_q <= 2'd0;
      wi_q <= 13'd0;  wok_q <= 1'b0;  sh_q <= 10'd0;  n_q <= 4'd0;  open_q <= 1'b0;  len_q <= 10'd0;
      idc_q <= 1'b0;  dc_q <= 1'b0;  b1_q <= 8'd0;  b2_q <= 8'd0;  b3_q <= 8'd0;  ckc_q <= 8'd0;  ckr_q <= 8'd0;
      slot_q <= 5'd31;  pend_q <= 1'b0;  nfirst_q <= 1'b0;  fdat_q <= 1'b0;  fail_q <= 1'b0;  psec_q <= 4'd0;
      found_q <= 16'd0;  done_q <= 1'b0;  clean_q <= 1'b0;  map_q <= 5'd0;
    end else if (abort) begin
      st_q <= SIdle;  done_q <= 1'b0;
    end else begin
      done_q <= 1'b0;
      unique case (st_q)
        SIdle: if (start) begin
          nb_q <= nbits_of(zone_of(track));
          p_q  <= nbits_of(zone_of(track)) - 17'd10;
          left_q <= 18'd10;  ph_q <= 2'd0;  wok_q <= 1'b0;
          sh_q <= 10'd0;  n_q <= 4'd0;  open_q <= 1'b0;
          pend_q <= 1'b0;  nfirst_q <= 1'b0;  fdat_q <= 1'b0;  fail_q <= 1'b0;  found_q <= 16'd0;
          map_q <= 5'd0;  clean_q <= 1'b0;
          st_q <= SSeek;
        end
        SSeek: if (lrdy) st_q <= SBit;
        SWord: if (r_ok) begin wi_q <= 13'(p_q >> 4); wok_q <= 1'b1; st_q <= SBit; end
        SBit: begin
          if (!(wok_q && wi_q == 13'(p_q >> 4))) begin
            wok_q <= 1'b0;  st_q <= SWord;
          end else if (lrdy && !stall) begin
            // one cell
            sh_q <= sh_n;
            p_q  <= lwrap ? 17'd0 : p_q + 17'd1;
            if (sync_c) begin
              n_q <= 4'd0;
              open_q <= ph_q == 2'd1;
              len_q <= 10'd0;  idc_q <= 1'b0;  dc_q <= 1'b0;  slot_q <= 5'd31;
            end else if (n_q == 4'd9) begin
              n_q <= 4'd0;
              if (open_q) begin
                if (bad_c) begin
                  open_q <= 1'b0;
                end else begin
                  if (len_q != 10'h3FF) len_q <= len_q + 10'd1;
                  case (len_q)
                    10'd0: begin
                      idc_q <= bv_c == 8'h08;  dc_q <= bv_c == 8'h07;  ckc_q <= 8'h07;
                      slot_q <= pend_q ? {1'b0, psec_q} : !nfirst_q ? 5'd16 : 5'd31;
                    end
                    10'd1: b1_q <= bv_c;
                    10'd2: b2_q <= bv_c;
                    10'd3: b3_q <= bv_c;
                    default: ;
                  endcase
                  if (len_q >= 10'd1 && len_q <= 10'd512) ckc_q <= ckc_q ^ bv_c;
                  if (len_q == 10'd513) ckr_q <= bv_c;
                end
              end
            end else begin
              n_q <= n_q + 4'd1;
            end
            // phase bookkeeping
            if (ph_q == 2'd0) begin
              if (left_q == 18'd1) begin ph_q <= 2'd1; left_q <= {1'b0, nb_q}; end
              else left_q <= left_q - 18'd1;
            end else if (ph_q == 2'd1) begin
              if (left_q == 18'd1) begin ph_q <= 2'd2; left_q <= {1'b0, nb_q}; end
              else left_q <= left_q - 18'd1;
            end else begin
              left_q <= left_q - 18'd1;
              if (sync_c || (byte_c && bad_c) || !open_q || left_q == 18'd1) st_q <= SEnd;
            end
          end
        end
        SEnd: begin
          // the last ID pairs with the first field
          if (pend_q) begin
            if (!fdat_q) fail_q <= 1'b1;
            else         map_q <= {1'b1, psec_q};
          end
          clean_q <= 1'b1;
          done_q  <= 1'b1;
          st_q    <= SIdle;
        end
        default: st_q <= SIdle;
      endcase

      // a field closes: pair it
      if (fend_c && len_q != 10'd0) begin
        nfirst_q <= 1'b1;
        if (!nfirst_q) fdat_q <= dok_c;
        if (pend_q && !dok_c) fail_q <= 1'b1;
        if (is_id_c) begin
          if (b3_q != (8'h08 ^ b1_q ^ b2_q) || b1_q != {1'b0, trk_q} || b2_q >= {3'd0, nsec_c} ||
              found_q[b2_q[3:0]])
            fail_q <= 1'b1;
          found_q[b2_q[3:0]] <= 1'b1;
          pend_q <= 1'b1;  psec_q <= b2_q[3:0];
        end else begin
          pend_q <= 1'b0;
        end
      end
    end
  end

  // staging writes: data bytes 1..512 of a field with a slot
  assign st_we   = step_c && open_q && byte_c && !bad_c && slot_q != 5'd31 && dc_q &&
                   len_q >= 10'd1 && len_q <= 10'd512;
  assign st_addr = {slot_q, 9'(len_q - 10'd1)};
  assign st_d    = bv_c;

  logic [15:0] need_c;
  assign need_c = 16'hFFFF >> (5'd16 - nsec_c);

  assign busy  = st_q != SIdle;
  assign done  = done_q;
  assign clean = clean_q && !fail_q && found_q == need_c;
  assign map16 = map_q;

endmodule

`default_nettype wire
