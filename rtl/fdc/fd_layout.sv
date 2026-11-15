// 5.25" drive emulator: recorded bit generator.  Walks the firmware
// layout of one track (fd_pkg) cell by cell and gives the recorded bit
// at the current cell for NS sides, from the cylinder buffer and the
// per-sector checksums; nothing is held encoded.
//
// `seek` puts the walk at cell `pos` (division by repeated subtraction,
// then the byte values are fetched); `adv` moves one cell on, to cell 0
// after the track's last.  Cells the platter moves during a seek are
// walked after it (up to 16,383 cells, a whole off-track time; `lost`
// says more were owed).  Each byte's value is fetched while the byte
// before it is out (one buffer read per side), so `adv` may come every
// clk only inside a byte; an `adv` at a byte boundary before the next
// byte is there is owed.  `rdy` is low while a seek or a fetch the next
// byte boundary needs is still running, or a cell is owed; `ahead` adds
// that the next byte is fetched, so the walk has a whole byte for the one
// after.  A fetch waits for `gnt`; only data bytes and the checksum byte
// (`need`) read the buffer.  `sec` is the slot under the walk, valid
// while `sec_ok`.
`default_nettype none

module fd_layout #(
  parameter int unsigned NS = 2
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [6:0]  track,
  input  logic        side0,           // side of lane 0 when NS = 1
  input  logic        seek,
  input  logic [16:0] pos,
  input  logic        adv,
  output logic        rdy,
  output logic        ahead,
  output logic [NS-1:0] bit_q,         // recorded bit of the current cell, per side
  // buffer read (one clk after gnt) and checksum lookup
  output logic        req,
  output logic [13:0] raddr,           // {side, sector, byte}
  output logic        need,            // the fetch reads the buffer or the checksum
  input  logic        gnt,
  input  logic [7:0]  rdata,
  output logic [4:0]  ck_idx,          // {side, sector}
  input  logic [7:0]  ck_q,
  output logic [4:0]  sec,
  output logic        sec_ok,
  output logic        lost
);
  import fd_pkg::*;

  // Justification: walk position: sector, stream byte, bit (reg-a).
  logic [4:0]  sec_q;
  logic [9:0]  n_q;
  logic [3:0]  b_q;
  // Justification: current and next byte codes per side (reg-a).
  logic [9:0]  cur_q [NS];
  logic [9:0]  nxt_q [NS];
  logic        nok_q;                 // nxt holds the next byte
  // Justification: seek divider and fetch sequencer (reg-a).
  typedef enum logic [2:0] {LIdle, LDivS, LDivN, LFetchCur, LFetch, LWait} lst_e;
  lst_e        st_q;
  logic [16:0] rem_q;
  logic [9:0]  dq_q;
  logic [3:0]  di_q;
  logic        fcur_q;               // the fetch is for the current byte (after a seek)
  logic        fside_q;
  logic [9:0]  fn_q;
  logic [4:0]  fsec_q;
  // Justification: cells the platter moved during a seek, walked after it (reg-a).
  logic [13:0] lag_q;
  // Justification: the walk's cell of the revolution (reg-a).
  logic [16:0] i_q;

  logic [1:0]  z_c;
  logic [4:0]  spt_c;
  logic [9:0]  nn_c;
  logic        seeking_c, step_c;
  assign seeking_c = st_q == LDivS || st_q == LDivN || st_q == LFetchCur ||
                     ((st_q == LFetch || st_q == LWait) && fcur_q);
  // a walk step: the platter's, or one owed from a seek or a late byte
  logic ok_c, wrap_c;
  assign ok_c   = b_q != 4'd9 || nok_q;
  assign step_c = !seeking_c && ok_c && (adv || lag_q != 14'd0);
  assign wrap_c = i_q == nbits_of(z_c) - 17'd1;
  logic [4:0]  ns_c;
  logic        last_c, nslot_c;

  assign z_c   = zone_of(track);
  assign spt_c = spt_of(z_c);
  // the byte after the current one; the last slot runs to the wrap
  assign last_c  = sec_q == spt_c - 5'd1;
  assign nslot_c = n_q == slot_bytes_of(z_c) - 10'd1 && !last_c;
  assign nn_c    = nslot_c ? 10'd0 : n_q + 10'd1;
  assign ns_c    = nslot_c ? sec_q + 5'd1 : sec_q;

  // side of fetch lane
  function automatic logic lane_side(input logic l);
    return (NS == 1) ? side0 : l;
  endfunction

  assign raddr  = {fside_q, fsec_q[3:0], fn_q[8:0] - 9'd27};
  assign ck_idx = {fside_q, fsec_q[3:0]};
  assign req    = st_q == LFetch;
  assign need   = is_data(fn_q) || fn_q == 10'd539;
  assign sec    = sec_q;
  assign sec_ok = st_q != LDivS && st_q != LDivN;

  logic unused_ok;
  assign unused_ok = &{1'b0, fsec_q[4]};

  logic [7:0] fval_c;
  assign fval_c = is_data(fn_q) ? rdata : slot_byte(fn_q, track, fsec_q[3:0], ck_q);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sec_q <= 5'd0;  n_q <= 10'd0;  b_q <= 4'd0;
      for (int s = 0; s < NS; s++) begin cur_q[s] <= 10'd0; nxt_q[s] <= 10'd0; end
      nok_q <= 1'b0;  st_q <= LIdle;  rem_q <= 17'd0;  dq_q <= 10'd0;  di_q <= 4'd0;
      fcur_q <= 1'b0;  fside_q <= 1'b0;  fn_q <= 10'd0;  fsec_q <= 5'd0;  lag_q <= 14'd0;  i_q <= 17'd0;
    end else if (seek) begin
      st_q <= LDivS;  rem_q <= pos;  sec_q <= 5'd0;  nok_q <= 1'b0;  lag_q <= 14'd0;  i_q <= pos;
    end else begin
      lag_q <= lag_q + ((adv && !(step_c && lag_q == 14'd0)) ? 14'd1 : 14'd0)
                     - ((step_c && lag_q != 14'd0) ? 14'd1 : 14'd0);
      if (step_c) i_q <= wrap_c ? 17'd0 : i_q + 17'd1;
      // walk
      if (step_c) begin
        if (wrap_c) begin
          sec_q <= 5'd0;  n_q <= 10'd0;  b_q <= 4'd0;  nok_q <= 1'b0;
        end else if (b_q != 4'd9) begin
          b_q <= b_q + 4'd1;
        end else begin
          b_q <= 4'd0;  n_q <= nn_c;  sec_q <= ns_c;  nok_q <= 1'b0;
          for (int s = 0; s < NS; s++) cur_q[s] <= nxt_q[s];
        end
      end
      unique case (st_q)
        LIdle: begin
          // fetch the next byte while this one is out
          if (!nok_q && !(step_c && (wrap_c || b_q == 4'd9))) begin
            fn_q <= nn_c;  fsec_q <= ns_c;  fside_q <= lane_side(1'b0);  fcur_q <= 1'b0;
            st_q <= LFetch;
          end
        end
        LDivS: begin
          if (rem_q >= {4'd0, slot_bits_of(z_c)} && !last_c) begin
            rem_q <= rem_q - {4'd0, slot_bits_of(z_c)};  sec_q <= sec_q + 5'd1;
          end else begin
            dq_q <= 10'd0;  di_q <= 4'd12;  st_q <= LDivN;
          end
        end
        LDivN: begin
          // restoring division of rem (< 7100) by 10, 13 quotient bits
          if (rem_q >= (17'd10 << di_q)) begin
            rem_q <= rem_q - (17'd10 << di_q);
            dq_q  <= dq_q | (10'd1 << di_q);
          end
          if (di_q == 4'd0) st_q <= LFetchCur;
          else              di_q <= di_q - 4'd1;
        end
        LFetchCur: begin
          n_q <= dq_q;  b_q <= rem_q[3:0];
          fn_q <= dq_q;  fsec_q <= sec_q;  fside_q <= lane_side(1'b0);  fcur_q <= 1'b1;
          st_q <= LFetch;
        end
        LFetch: if (gnt) st_q <= LWait;
        LWait: begin
          for (int s = 0; s < NS; s++)
            if (lane_side(1'(s)) == fside_q) begin
              if (fcur_q) cur_q[s] <= gcr_byte(fval_c);
              else        nxt_q[s] <= gcr_byte(fval_c);
            end
          if (NS == 2 && !fside_q) begin
            fside_q <= 1'b1;  st_q <= LFetch;
          end else if (fcur_q) begin
            st_q <= LIdle;
          end else begin
            nok_q <= 1'b1;  st_q <= LIdle;
          end
        end
        default: st_q <= LIdle;
      endcase
    end
  end

  // ready: no seek in progress, and the next byte is there before it is needed
  assign lost = adv && &lag_q;
  assign rdy = !seeking_c && lag_q == 14'd0 && ok_c;
  assign ahead = rdy && nok_q;

  always_comb begin
    for (int s = 0; s < NS; s++) begin
      if (is_sync(n_q)) bit_q[s] = 1'b1;
      else              bit_q[s] = cur_q[s][4'd9 - b_q];
    end
  end

endmodule

`default_nettype wire
