// Host adapter (no C900 part): MiSTer ps2_key events (PS/2 set 2) -> the
// C900 key matrix and modifier inputs (c900_keyboard).  Each set-2 code is
// taken to its PC XT make code and from there to the first matrix slot the
// keyboard firmware's scancode table (0x0F8C) gives that code.  Shift,
// CapsLock, Ctrl and Alt are the keyboard's separate modifier inputs (both
// Ctrl keys -> Ctrl, both Alt keys -> LAlt).  The E0 cursor keys, Delete,
// keypad / and keypad Enter, and the keypad '.', reach the C900's own keys
// (codes 0x5F-0x62, 0x55, 0x5A, 0x5E, 0x59).  The other E0 navigation keys
// are the XT keypad keys they replaced.  Codes 0x53 (keypad 00), 0x54
// (Help) and 0x5B-0x5D (W1-W3) have no PC key and are not reachable.  While
// the OSD is open every key is released and events are ignored.
//
// The firmware scans every 20 ms: it reads the modifier pins just after
// PC5 rises, then strobes columns PB0..PC4 Low one at a time, and reports
// a change seen in one scan.  Per scan it sends modifier changes first,
// then breaks, then makes in matrix order.  A make is applied at once, as
// a key closing.  A change counts as seen once its column has been strobed
// from start to end after it (modifiers: PC5 rise, then the PB0 strobe).
// A break waits until its key is seen; any change waits until the scan
// that saw the last make has ended; a make or modifier change waits for an
// unseen modifier change; a modifier make waits for unseen breaks.  That
// keeps PS/2 order (only adjacent breaks may swap).  Each change is one
// byte in the firmware's 11-byte send queue, which empties only when the
// host acks; bytes leaving are counted on PA7 (nine falling edges each).
// A make goes in only if its byte, its break and the breaks of every key
// still down fit in 10, so a held-off host cannot leave a key down long
// enough to auto-repeat.  A make that would hold more than 10 matrix keys
// is dropped (the firmware stops its scan at 10).
`default_nettype none
module ps2_kbd_matrix #(
  parameter int QAW = 5                   // event queue: 2**QAW entries
) (
  input  logic         clk,
  input  logic         rst_n,
  input  logic [10:0]  ps2_key,     // [10] toggles per event, [9] pressed, [8] E0, [7:0] code
  input  logic         osd,
  input  logic [7:0]   kbd_pb,      // 6500/1 PB0-7, PC0-4: column strobes, Low while strobed
  input  logic [5:0]   kbd_pc,      // PC5 rises as a scan starts
  input  logic         kbd_pa7,     // 6500/1 PA7: cable clock driver
  output logic [103:0] keys,
  output logic [4:0]   mods         // [0] LShift, [1] CapsLock, [2] RShift, [3] Ctrl, [4] LAlt
);
  localparam int QD   = 1 << QAW;
  localparam int QMAX = 10;         // firmware queue bytes allowed, breaks of held keys included
  localparam int KMAX = 10;         // matrix keys the firmware scan holds

  logic       hit;
  logic [6:0] idx;

  always_comb begin
    hit = 1'b0;
    idx = 7'd0;
    unique case ({ps2_key[8], ps2_key[7:0]})
      {1'b0, 8'h01}: begin hit = 1'b1; idx = 7'd82; end  // XT 43
      {1'b0, 8'h03}: begin hit = 1'b1; idx = 7'd50; end  // XT 3F
      {1'b0, 8'h04}: begin hit = 1'b1; idx = 7'd34; end  // XT 3D
      {1'b0, 8'h05}: begin hit = 1'b1; idx = 7'd18; end  // XT 3B
      {1'b0, 8'h06}: begin hit = 1'b1; idx = 7'd26; end  // XT 3C
      {1'b0, 8'h07}: begin hit = 1'b1; idx = 7'd95; end  // XT 58
      {1'b0, 8'h09}: begin hit = 1'b1; idx = 7'd90; end  // XT 44
      {1'b0, 8'h0A}: begin hit = 1'b1; idx = 7'd74; end  // XT 42
      {1'b0, 8'h0B}: begin hit = 1'b1; idx = 7'd58; end  // XT 40
      {1'b0, 8'h0C}: begin hit = 1'b1; idx = 7'd42; end  // XT 3E
      {1'b0, 8'h0D}: begin hit = 1'b1; idx = 7'd4; end  // XT 0F
      {1'b0, 8'h0E}: begin hit = 1'b1; idx = 7'd16; end  // XT 29
      {1'b0, 8'h15}: begin hit = 1'b1; idx = 7'd12; end  // XT 10
      {1'b0, 8'h16}: begin hit = 1'b1; idx = 7'd3; end  // XT 02
      {1'b0, 8'h1A}: begin hit = 1'b1; idx = 7'd22; end  // XT 2C
      {1'b0, 8'h1B}: begin hit = 1'b1; idx = 7'd13; end  // XT 1F
      {1'b0, 8'h1C}: begin hit = 1'b1; idx = 7'd5; end  // XT 1E
      {1'b0, 8'h1D}: begin hit = 1'b1; idx = 7'd20; end  // XT 11
      {1'b0, 8'h1E}: begin hit = 1'b1; idx = 7'd11; end  // XT 03
      {1'b0, 8'h21}: begin hit = 1'b1; idx = 7'd38; end  // XT 2E
      {1'b0, 8'h22}: begin hit = 1'b1; idx = 7'd30; end  // XT 2D
      {1'b0, 8'h23}: begin hit = 1'b1; idx = 7'd8; end  // XT 20
      {1'b0, 8'h24}: begin hit = 1'b1; idx = 7'd28; end  // XT 12
      {1'b0, 8'h25}: begin hit = 1'b1; idx = 7'd27; end  // XT 05
      {1'b0, 8'h26}: begin hit = 1'b1; idx = 7'd19; end  // XT 04
      {1'b0, 8'h29}: begin hit = 1'b1; idx = 7'd62; end  // XT 39
      {1'b0, 8'h2A}: begin hit = 1'b1; idx = 7'd46; end  // XT 2F
      {1'b0, 8'h2B}: begin hit = 1'b1; idx = 7'd29; end  // XT 21
      {1'b0, 8'h2C}: begin hit = 1'b1; idx = 7'd44; end  // XT 14
      {1'b0, 8'h2D}: begin hit = 1'b1; idx = 7'd36; end  // XT 13
      {1'b0, 8'h2E}: begin hit = 1'b1; idx = 7'd35; end  // XT 06
      {1'b0, 8'h31}: begin hit = 1'b1; idx = 7'd70; end  // XT 31
      {1'b0, 8'h32}: begin hit = 1'b1; idx = 7'd54; end  // XT 30
      {1'b0, 8'h33}: begin hit = 1'b1; idx = 7'd45; end  // XT 23
      {1'b0, 8'h34}: begin hit = 1'b1; idx = 7'd37; end  // XT 22
      {1'b0, 8'h35}: begin hit = 1'b1; idx = 7'd52; end  // XT 15
      {1'b0, 8'h36}: begin hit = 1'b1; idx = 7'd43; end  // XT 07
      {1'b0, 8'h3A}: begin hit = 1'b1; idx = 7'd78; end  // XT 32
      {1'b0, 8'h3B}: begin hit = 1'b1; idx = 7'd53; end  // XT 24
      {1'b0, 8'h3C}: begin hit = 1'b1; idx = 7'd60; end  // XT 16
      {1'b0, 8'h3D}: begin hit = 1'b1; idx = 7'd51; end  // XT 08
      {1'b0, 8'h3E}: begin hit = 1'b1; idx = 7'd59; end  // XT 09
      {1'b0, 8'h41}: begin hit = 1'b1; idx = 7'd86; end  // XT 33
      {1'b0, 8'h42}: begin hit = 1'b1; idx = 7'd61; end  // XT 25
      {1'b0, 8'h43}: begin hit = 1'b1; idx = 7'd68; end  // XT 17
      {1'b0, 8'h44}: begin hit = 1'b1; idx = 7'd76; end  // XT 18
      {1'b0, 8'h45}: begin hit = 1'b1; idx = 7'd75; end  // XT 0B
      {1'b0, 8'h46}: begin hit = 1'b1; idx = 7'd67; end  // XT 0A
      {1'b0, 8'h49}: begin hit = 1'b1; idx = 7'd94; end  // XT 34
      {1'b0, 8'h4A}: begin hit = 1'b1; idx = 7'd102; end  // XT 35
      {1'b0, 8'h4B}: begin hit = 1'b1; idx = 7'd69; end  // XT 26
      {1'b0, 8'h4C}: begin hit = 1'b1; idx = 7'd77; end  // XT 27
      {1'b0, 8'h4D}: begin hit = 1'b1; idx = 7'd84; end  // XT 19
      {1'b0, 8'h4E}: begin hit = 1'b1; idx = 7'd83; end  // XT 0C
      {1'b0, 8'h52}: begin hit = 1'b1; idx = 7'd85; end  // XT 28
      {1'b0, 8'h54}: begin hit = 1'b1; idx = 7'd92; end  // XT 1A
      {1'b0, 8'h55}: begin hit = 1'b1; idx = 7'd91; end  // XT 0D
      {1'b0, 8'h5A}: begin hit = 1'b1; idx = 7'd101; end  // XT 1C
      {1'b0, 8'h5B}: begin hit = 1'b1; idx = 7'd100; end  // XT 1B
      {1'b0, 8'h5D}: begin hit = 1'b1; idx = 7'd99; end  // XT 2B
      {1'b0, 8'h61}: begin hit = 1'b1; idx = 7'd24; end  // XT 56
      {1'b0, 8'h66}: begin hit = 1'b1; idx = 7'd96; end  // XT 0E
      {1'b0, 8'h69}: begin hit = 1'b1; idx = 7'd15; end  // XT 4F
      {1'b0, 8'h6B}: begin hit = 1'b1; idx = 7'd57; end  // XT 4B
      {1'b0, 8'h6C}: begin hit = 1'b1; idx = 7'd97; end  // XT 47
      {1'b0, 8'h70}: begin hit = 1'b1; idx = 7'd14; end  // XT 52
      {1'b0, 8'h71}: begin hit = 1'b1; idx = 7'd87; end  // C900 59
      {1'b0, 8'h72}: begin hit = 1'b1; idx = 7'd41; end  // XT 50
      {1'b0, 8'h73}: begin hit = 1'b1; idx = 7'd0; end  // XT 4C
      {1'b0, 8'h74}: begin hit = 1'b1; idx = 7'd73; end  // XT 4D
      {1'b0, 8'h75}: begin hit = 1'b1; idx = 7'd89; end  // XT 48
      {1'b0, 8'h76}: begin hit = 1'b1; idx = 7'd10; end  // XT 01
      {1'b0, 8'h77}: begin hit = 1'b1; idx = 7'd40; end  // XT 45
      {1'b0, 8'h78}: begin hit = 1'b1; idx = 7'd32; end  // XT 57
      {1'b0, 8'h79}: begin hit = 1'b1; idx = 7'd71; end  // XT 4E
      {1'b0, 8'h7A}: begin hit = 1'b1; idx = 7'd33; end  // XT 51
      {1'b0, 8'h7B}: begin hit = 1'b1; idx = 7'd9; end  // XT 4A
      {1'b0, 8'h7C}: begin hit = 1'b1; idx = 7'd103; end  // XT 37
      {1'b0, 8'h7D}: begin hit = 1'b1; idx = 7'd2; end  // XT 49
      {1'b0, 8'h7E}: begin hit = 1'b1; idx = 7'd48; end  // XT 46
      {1'b0, 8'h83}: begin hit = 1'b1; idx = 7'd7; end  // XT 41
      {1'b1, 8'h4A}: begin hit = 1'b1; idx = 7'd79; end  // C900 5A
      {1'b1, 8'h5A}: begin hit = 1'b1; idx = 7'd1; end  // C900 5E
      {1'b1, 8'h69}: begin hit = 1'b1; idx = 7'd15; end  // XT 4F
      {1'b1, 8'h6B}: begin hit = 1'b1; idx = 7'd72; end  // C900 60
      {1'b1, 8'h6C}: begin hit = 1'b1; idx = 7'd97; end  // XT 47
      {1'b1, 8'h70}: begin hit = 1'b1; idx = 7'd14; end  // XT 52
      {1'b1, 8'h71}: begin hit = 1'b1; idx = 7'd98; end  // C900 55
      {1'b1, 8'h72}: begin hit = 1'b1; idx = 7'd56; end  // C900 62
      {1'b1, 8'h74}: begin hit = 1'b1; idx = 7'd64; end  // C900 61
      {1'b1, 8'h75}: begin hit = 1'b1; idx = 7'd80; end  // C900 5F
      {1'b1, 8'h7A}: begin hit = 1'b1; idx = 7'd33; end  // XT 51
      {1'b1, 8'h7D}: begin hit = 1'b1; idx = 7'd2; end  // XT 49
      default: ;
    endcase
  end

  logic [4:0] mod_sel;
  logic [2:0] mod_n;
  always_comb begin
    unique case ({ps2_key[8], ps2_key[7:0]})
      {1'b0, 8'h12}: mod_sel = 5'b00001;
      {1'b0, 8'h58}: mod_sel = 5'b00010;
      {1'b0, 8'h59}: mod_sel = 5'b00100;
      {1'b0, 8'h14}, {1'b1, 8'h14}: mod_sel = 5'b01000;
      {1'b0, 8'h11}, {1'b1, 8'h11}: mod_sel = 5'b10000;
      default: mod_sel = 5'b00000;
    endcase
  end

  always_comb begin
    unique case (mod_sel)
      5'b00010: mod_n = 3'd1;
      5'b00100: mod_n = 3'd2;
      5'b01000: mod_n = 3'd3;
      5'b10000: mod_n = 3'd4;
      default:  mod_n = 3'd0;
    endcase
  end

  // Target state: what the PS/2 keyboard holds, as queued.  Repeated makes
  // and unmapped codes change nothing and are not queued.
  // Justification: (reg-a) event edge, target image, matrix key count.
  logic         tgl_q;
  logic [103:0] keys_t;
  logic [4:0]   mods_t;
  logic [3:0]   nkeys_t;
  logic         ev, is_mod, chg, enq;
  logic [8:0]   ev_e;               // {pressed, modifier, index}
  assign ev     = (ps2_key[10] != tgl_q) && !osd;
  assign is_mod = |mod_sel;
  assign ev_e   = {ps2_key[9], is_mod, is_mod ? {4'd0, mod_n} : idx};

  // Event queue.
  // Justification: (reg-a) events waiting for a scan.
  (* ramstyle = "MLAB" *) logic [8:0] q [QD];
  logic [QAW:0] wp, rp;
  logic         q_empty, q_full;
  assign q_empty = (wp == rp);
  assign q_full  = (wp == (rp ^ {1'b1, {QAW{1'b0}}}));

  always_ff @(posedge clk) if (enq) q[wp[QAW-1:0]] <= ev_e;

  always_comb begin
    chg = 1'b0;
    if (is_mod)   chg = (ps2_key[9] != |(mods_t & mod_sel));
    else if (hit) chg = (ps2_key[9] != keys_t[idx]) && (!ps2_key[9] || nkeys_t < 4'(KMAX));
  end
  assign enq = ev && chg && !q_full;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      tgl_q   <= 1'b0;
      keys_t  <= '0;
      mods_t  <= '0;
      nkeys_t <= '0;
      wp      <= '0;
    end else begin
      tgl_q <= ps2_key[10];
      if (osd) begin
        keys_t  <= '0;
        mods_t  <= '0;
        nkeys_t <= '0;
      end else if (enq) begin
        wp <= wp + 1'b1;
        if (is_mod) mods_t <= ps2_key[9] ? (mods_t | mod_sel) : (mods_t & ~mod_sel);
        else begin
          keys_t[idx] <= ps2_key[9];
          nkeys_t     <= ps2_key[9] ? nkeys_t + 4'd1 : nkeys_t - 4'd1;
        end
      end
    end
  end

  // Bytes sent: nine PA7 falls each.
  // Justification: (reg-a) pin history, bit count, outstanding and queued bytes.
  logic        pa7_q, pc5_q, sent;
  logic [12:0] col_q, col_fall, col_rise;
  logic [3:0]  nfall, pend, qcnt;
  assign sent     = !kbd_pa7 && pa7_q && nfall == 4'd8;
  assign col_fall = col_q & ~{kbd_pc[4:0], kbd_pb};
  assign col_rise = ~col_q & {kbd_pc[4:0], kbd_pb};
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pa7_q <= 1'b1;
      pc5_q <= 1'b1;
      col_q <= '1;
      nfall <= '0;
    end else begin
      pa7_q <= kbd_pa7;
      pc5_q <= kbd_pc[5];
      col_q <= {kbd_pc[4:0], kbd_pb};
      if (!kbd_pa7 && pa7_q) nfall <= (nfall == 4'd8) ? 4'd0 : nfall + 4'd1;
    end
  end

  // Unseen changes: breaks per key, at most one matrix make, at most one
  // modifier change.  A column strobe counts only if it began after the
  // last change in that column.
  // Justification: (reg-a) unseen changes and strobe progress.
  logic [103:0] brk_un;
  logic         mk_un, mk_rd, md_un, md_scan;
  logic [3:0]   mk_col;
  logic [12:0]  col_arm, col_seen;
  logic [8:0]   hd;
  logic         take;
  logic [3:0]   hd_col;
  logic [4:0]   nheld;              // applied keys and modifiers down: breaks still to come
  assign hd       = q[rp[QAW-1:0]];
  assign hd_col   = hd[6:3];
  assign col_seen = col_rise & col_arm;
  always_comb begin
    take = 1'b0;
    if (!osd && !q_empty && !mk_un) begin
      if (!hd[8])     take = 5'(qcnt) < 5'(QMAX) && (hd[7] ? !md_un : 1'b1);
      else if (5'(qcnt) + nheld + 5'd2 > 5'(QMAX)) take = 1'b0;
      else if (hd[7]) take = !md_un && !(|brk_un);
      else            take = !md_un && !brk_un[hd[6:0]];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rp      <= '0;
      keys    <= '0;
      mods    <= '0;
      brk_un  <= '0;
      mk_un   <= 1'b0;
      mk_rd   <= 1'b0;
      mk_col  <= '0;
      md_un   <= 1'b0;
      md_scan <= 1'b0;
      col_arm <= '0;
      nheld   <= '0;
    end else if (osd) begin
      nheld  <= '0;
      rp     <= wp;
      keys   <= '0;
      mods   <= '0;
      brk_un <= '0;
      mk_un  <= 1'b0;
      md_un  <= 1'b0;
    end else begin
      col_arm <= (col_arm | col_fall) & ~col_rise;
      for (int c = 0; c < 13; c++)
        if (col_seen[c]) brk_un[8*c +: 8] <= '0;
      if (mk_un && (mk_rd || col_seen[mk_col])) begin
        mk_rd <= 1'b1;
        if (col_rise[12]) begin
          mk_un <= 1'b0;
          mk_rd <= 1'b0;
        end
      end
      if (kbd_pc[5] && !pc5_q) md_scan <= 1'b1;
      if (md_scan && col_fall[0]) begin
        md_un   <= 1'b0;
        md_scan <= 1'b0;
      end
      if (take) begin
        rp    <= rp + 1'b1;
        nheld <= hd[8] ? nheld + 5'd1 : nheld - 5'd1;
        if (hd[7]) begin
          mods[hd[2:0]] <= hd[8];
          md_un         <= 1'b1;
          md_scan       <= 1'b0;
        end else begin
          keys[hd[6:0]]   <= hd[8];
          col_arm[hd_col] <= 1'b0;
          if (hd[8]) begin
            mk_un  <= 1'b1;
            mk_col <= hd_col;
          end else brk_un[hd[6:0]] <= 1'b1;
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pend <= '0;
      qcnt <= '0;
    end else if (sent && !take && pend <= 4'd1) begin
      pend <= '0;
      qcnt <= '0;
    end else begin
      pend <= pend + {3'd0, take} - {3'd0, sent && pend != 4'd0};
      qcnt <= qcnt + {3'd0, take};
    end
  end
endmodule
`default_nettype wire
