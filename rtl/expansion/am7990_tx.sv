// Am7990 transmit serializer.  A frame on TX: 62 bits 1010..., "11",
// the bytes LSB first, then the complemented CRC-32 when the frame's
// last byte asks for it.  TENA covers all of it.
//
// Start (TM p.1-17): a byte in the silo (with loop: the whole frame,
// TM p.1-24), no carrier (RENA, CLSN), the gap over and, on a retry,
// the backoff over.  The gap runs from the end of a transmission or
// from carrier going away; carrier seen while idle defers, carrier
// during the gap is ignored.  A silo empty mid-frame cuts the frame
// without FCS (UFLO, TM p.1-28).
//
// CLSN while transmitting (TM p.1-11): the preamble, or the current
// byte, is finished, then 32 jam bits; no FCS.  A collision more than
// 512 bit times after the destination address started is late.
// LCAR: RENA not high, or dropping, while TENA is high (TM p.4-9).
`default_nettype none
module am7990_tx (
  input  logic       clk,
  input  logic       clr,
  input  logic       tclk_rise,
  input  logic       loop,
  input  logic       rena,
  input  logic       clsn,
  // silo head, when it is a transmit byte
  input  logic       hv,
  input  logic [7:0] hb,
  input  logic       hlast,
  input  logic       hfcs,
  input  logic       tframe,      // a whole frame in the silo
  input  logic       pend,        // a frame waits to be sent
  // backoff: bo_slots slot times of 512 bits, loaded with bo_load
  input  logic       bo_load,
  input  logic [9:0] bo_slots,
  output logic       take,
  output logic       uflo,        // one clock: the silo ran dry mid-frame
  output logic       done,        // one clock: a frame ended without collision
  output logic       col,         // one clock: a collided attempt ended
  output logic       late,        // with col: after the slot time
  output logic       lcar,        // with done: carrier lost
  output logic       deferring,   // a frame waits for carrier to go away
  output logic       backoff,     // backoff running
  output logic       ipg_wait,    // a frame waits for the gap to end
  output logic       tx,
  output logic       tena
);
  localparam logic [31:0] POLY = 32'hEDB8_8320;
  localparam logic [6:0]  GAP  = 7'd95;
  localparam logic [9:0]  SLOT = 10'd512;

  typedef enum logic [2:0] {S_GAP, S_PRE, S_DATA, S_FCS, S_JAM} sst_e;
  // Justification: (reg-a) serializer state, bit counter, shift register,
  // CRC, gap counter and its mode, slot-time count, collision and
  // carrier tracking, backoff counters.
  sst_e       s_q;
  logic [6:0] n_q;             // preamble / data / FCS / jam bit count
  logic [6:0] g_q;             // gap bit count
  logic       ipg_q;           // timing a gap
  logic       dfr_q;           // carrier seen while idle
  logic [7:0] sr_q;
  logic       sl_q, sf_q;      // byte in sr is the frame's last; FCS follows
  logic [31:0] crc_q;
  logic       tx_q;
  logic [9:0] st_q;            // bits since the destination address, to 512
  logic       c_q, cl_q;       // collision this attempt; late
  logic       rs_q, rl_q;      // RENA seen; RENA lost after it was seen
  logic [9:0] bs_q;            // backoff slots left
  logic [8:0] bb_q;            // bits left in the current slot

  logic ready;
  assign ready = hv && (!loop || tframe);

  logic bo;
  assign bo = bs_q != 10'd0;

  logic on_wire, cnow;
  assign on_wire = s_q != S_GAP;
  assign cnow    = c_q || (clsn && on_wire && s_q != S_JAM);

  always_comb begin
    take = 1'b0;
    if (tclk_rise && hv && !cnow) begin
      if (s_q == S_PRE && n_q == 7'd62) take = 1'b1;
      if (s_q == S_DATA && n_q[2:0] == 3'd7 && !sl_q) take = 1'b1;
    end
  end

  assign uflo = tclk_rise && s_q == S_DATA && n_q[2:0] == 3'd7 && !sl_q && !hv && !cnow;

  logic fb;
  assign fb = crc_q[0] ^ sr_q[0];

  logic go;
  always_comb begin
    go = 1'b0;
    if (s_q == S_GAP && ready && !bo) begin
      if (ipg_q) go = g_q == GAP;
      else       go = !clsn && !rena && !dfr_q;
    end
  end

  always_ff @(posedge clk) begin
    done <= 1'b0;
    col  <= 1'b0;
    if (clr) begin
      s_q   <= S_GAP;
      n_q   <= 7'd0;
      g_q   <= 7'd0;
      ipg_q <= 1'b1;
      dfr_q <= 1'b0;
      tx_q  <= 1'b0;
      tena  <= 1'b0;
      sl_q  <= 1'b0;
      sf_q  <= 1'b0;
      crc_q <= '1;
      c_q   <= 1'b0;
      bs_q  <= 10'd0;
    end else begin
      if (bo_load) begin
        bs_q <= bo_slots;
        bb_q <= 9'd511;
      end else if (tclk_rise && bo) begin
        bb_q <= bb_q - 9'd1;
        if (bb_q == 9'd0) bs_q <= bs_q - 10'd1;
      end
      if (tclk_rise) begin
        if (tena) begin
          if (rena)      rs_q <= 1'b1;
          else if (rs_q) rl_q <= 1'b1;
        end
        if (cnow && !c_q) begin
          c_q  <= 1'b1;
          cl_q <= st_q == SLOT;
        end
        if ((s_q == S_DATA || s_q == S_FCS) && st_q != SLOT) st_q <= st_q + 10'd1;
        unique case (s_q)
          S_GAP: begin
            tena <= 1'b0;
            tx_q <= 1'b0;
            if (go) begin
              s_q   <= S_PRE;
              n_q   <= 7'd0;
              ipg_q <= 1'b0;
              tena  <= 1'b1;
              tx_q  <= 1'b1;
              st_q  <= 10'd0;
              c_q   <= 1'b0;
              rs_q  <= 1'b0;
              rl_q  <= 1'b0;
            end else if (ipg_q) begin
              if (g_q != GAP) g_q <= g_q + 7'd1;
              else            ipg_q <= 1'b0;
            end else if (clsn || rena) begin
              dfr_q <= 1'b1;
            end else if (dfr_q) begin
              dfr_q <= 1'b0;
              ipg_q <= 1'b1;
              g_q   <= 7'd0;
            end
          end
          S_PRE: begin
            n_q  <= n_q + 7'd1;
            tx_q <= (n_q >= 7'd61) || n_q[0];
            if (n_q == 7'd62) begin
              s_q   <= cnow ? S_JAM : S_DATA;
              n_q   <= 7'd0;
              sr_q  <= hb;
              sl_q  <= hlast;
              sf_q  <= hfcs;
              crc_q <= '1;
            end
          end
          S_DATA: begin
            tx_q  <= sr_q[0];
            crc_q <= (crc_q >> 1) ^ (fb ? POLY : 32'd0);
            n_q   <= n_q + 7'd1;
            if (n_q[2:0] == 3'd7) begin
              if (cnow) begin
                s_q <= S_JAM;
                n_q <= 7'd0;
              end else if (sl_q || !hv) begin
                s_q   <= (sl_q && sf_q) ? S_FCS : S_GAP;
                n_q   <= 7'd0;
                g_q   <= 7'd0;
                ipg_q <= 1'b1;
                if (sl_q && !sf_q) done <= 1'b1;
              end else begin
                sr_q <= hb;
                sl_q <= hlast;
                sf_q <= hfcs;
              end
            end else begin
              sr_q <= sr_q >> 1;
            end
          end
          S_FCS: begin
            tx_q  <= ~crc_q[0];
            crc_q <= crc_q >> 1;
            n_q   <= n_q + 7'd1;
            if (n_q[2:0] == 3'd7 && cnow) begin
              s_q <= S_JAM;
              n_q <= 7'd0;
            end else if (n_q == 7'd31) begin
              s_q   <= S_GAP;
              n_q   <= 7'd0;
              g_q   <= 7'd0;
              ipg_q <= 1'b1;
              done  <= 1'b1;
            end
          end
          S_JAM: begin
            tx_q <= !n_q[0];
            n_q  <= n_q + 7'd1;
            if (n_q == 7'd31) begin
              s_q   <= S_GAP;
              n_q   <= 7'd0;
              g_q   <= 7'd0;
              ipg_q <= 1'b1;
              col   <= 1'b1;
            end
          end
          default: s_q <= S_GAP;
        endcase
      end
    end
  end

  assign tx        = tx_q;
  assign late      = cl_q;
  assign lcar      = !rs_q || rl_q;
  assign deferring = s_q == S_GAP && pend && !bo && !ipg_q && (clsn || rena || dfr_q);
  assign backoff   = bo;
  assign ipg_wait  = s_q == S_GAP && ipg_q && ready && !bo;
endmodule
`default_nettype wire
