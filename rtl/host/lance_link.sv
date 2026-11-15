// NON-STOCK: the LANCE card's cable side.  It plays the transceiver and
// the network: frames go to and from Main through a ring in DDR3.
//
// Transceiver, always while the card is on: RENA and RX echo TX while
// TENA is high (half a bit later), CLSN while TENA is high and a frame
// from Main is going out, and a heartbeat on CLSN from 1.0 to 2.0 us
// after TENA falls.  RCLK = TCLK.
//
// Link to Main: 64 KB at byte 0x30400000, 64-bit words,
// little-endian, byte i of a word in bits 8i+7:8i.
//   word 0       core  'C9EN' in 63:32, epoch in 7:0 (new at each start)
//   word 1       core  tx_wr: frames put in the TX ring
//   word 2       Main  tx_rd: frames taken
//   word 3       Main  rx_wr: frames put in the RX ring
//   word 4       core  rx_rd: frames taken
//   word 5       Main  MAC bytes 0-5 in 47:0, bit 63 valid
//   words 8-15   Main  IP configuration, 64 bytes, word 8 bit 63 valid
//   0x200+0x100n core  TX slot n (n = count mod 8): length, then bytes
//   0xA00+0x100n Main  RX slot n, likewise
// At a start words 1-4 are cleared, then word 0 is written.  Words 2-15
// are read every 20 us: 2-7 in one burst, then 8-15 one at a time, each
// passed to the cfg port as four 16-bit halves, low half first.
//
//   chip TX -> capture (2 KB) -> DDR TX slot      Main RX slot -> 2 KB -> chip RX
//
// TX: a frame is captured whole, then copied.  When the last 4 bytes
// leave the CRC-32 residue they are its FCS and are not copied.  A
// frame that collided, finds the ring full, or meets a copy still
// running is dropped.  RX: a frame is fetched whole, padded with zeros
// to 60 bytes and sent with a computed FCS, 100 quiet bit times after
// the cable was last busy and never while TENA is high.  A collision
// cuts it after 32 jam bits and it is sent again.
//
// DDR bursts are never cut: the DDR side resets only with the PLL.
`default_nettype none
module lance_link #(
  parameter logic [28:0] BASE = 29'h0608_0000     // byte 0x30400000
) (
  input  logic        clk,
  input  logic        rst_n,       // PLL lock only
  input  logic        card_on,     // the card is fitted and out of reset
  // the Am7990 serial pins
  input  logic        tclk_rise,
  input  logic        tclk_fall,
  input  logic        tx,
  input  logic        tena,
  output logic        rclk_rise,
  output logic        rx,
  output logic        rena,
  output logic        clsn,
  // station address from Main
  output logic        mac_ok,
  output logic [47:0] mac,         // byte 0 in 47:40
  // IP configuration from Main: ring words 8-15 as read
  output logic        cfg_ok,
  output logic        cfg_wr,
  output logic [4:0]  cfg_addr,    // ring word 8 + addr/4, half addr%4
  output logic [15:0] cfg_data,
  // DDRAM
  input  logic        ddr_busy,
  output logic [7:0]  ddr_burstcnt,
  output logic [28:0] ddr_addr,
  input  logic [63:0] ddr_dout,
  input  logic        ddr_dout_ready,
  output logic        ddr_rd,
  output logic [63:0] ddr_din,
  output logic [7:0]  ddr_be,
  output logic        ddr_we
);
  localparam logic [31:0] POLY    = 32'hEDB8_8320;
  localparam logic [31:0] RESIDUE = 32'hDEBB_20E3;
  localparam logic [31:0] MAGIC   = 32'h4339_454E;  // 'C9EN'
  localparam logic [10:0] MAXLEN  = 11'd1536;
  localparam logic [9:0]  POLL    = 10'd959;        // 20 us
  localparam logic [6:0]  QUIET   = 7'd100;

  // ---- transceiver ----
  // Justification: (reg-a) echo of TENA and TX; bit times since TENA fell.
  logic       echo_q, rxe_q, tena_q;
  logic [4:0] hb_q;
  always_ff @(posedge clk) begin
    if (!card_on) begin
      echo_q <= 1'b0;
      rxe_q  <= 1'b0;
      hb_q   <= 5'd31;
    end else if (tclk_fall) begin
      echo_q <= tena;
      rxe_q  <= tx;
      hb_q   <= tena ? 5'd0 : (hb_q != 5'd31 ? hb_q + 5'd1 : hb_q);
    end
  end
  logic hb;
  assign hb = hb_q >= 5'd10 && hb_q < 5'd20;

  // ---- frame buffers: 256 x 64 each ----
  logic [7:0]  tb_wa, tb_ra, rb_wa, rb_ra;
  logic        tb_we, rb_we;
  logic [63:0] tb_wd, tb_q, rb_wd, rb_q;
  (* ramstyle = "M10K, no_rw_check" *) logic [63:0] tmem [0:255];
  (* ramstyle = "M10K, no_rw_check" *) logic [63:0] rmem [0:255];
  always_ff @(posedge clk) begin
    if (tb_we) tmem[tb_wa] <= tb_wd;
    tb_q <= tmem[tb_ra];
  end
  always_ff @(posedge clk) begin
    if (rb_we) rmem[rb_wa] <= rb_wd;
    rb_q <= rmem[rb_ra];
  end

  // ---- peer: a frame from Main on RX ----
  typedef enum logic [1:0] {P_IDLE, P_SEND, P_JAM} pst_e;
  // Justification: (reg-a) sender state, bit index, current byte, CRC,
  // quiet bit times, the frame done.
  pst_e        p_q;
  logic [13:0] pi_q;            // bit index from the preamble start
  logic [7:0]  pb_q;            // byte going out
  logic [31:0] pc_q;
  logic        pbit_q;
  logic [6:0]  quiet_q;
  logic        p_done;          // one clock: the frame went out whole
  logic        p_done_q;        // DDR side: that frame not yet counted
  logic        rxb_full;        // DDR side: a fetched frame waits
  logic [10:0] rxb_len;

  logic [10:0] pnb;             // bytes before the FCS: the frame padded to 60
  assign pnb = rxb_len < 11'd60 ? 11'd60 : rxb_len;
  logic [13:0] pend_bit;
  assign pend_bit = 14'd64 + {pnb, 3'd0} + 14'd32;

  logic [13:0] pdi;             // data bit index
  logic [10:0] pk;              // byte index of the bit going out next
  assign pdi = pi_q - 14'd64;
  assign pk  = pdi[13:3];
  assign rb_ra = 8'(pk >> 3);

  logic [7:0] pbyte;
  logic       pdb;              // the data bit going out
  always_comb begin
    pbyte = rb_q[8*pk[2:0] +: 8];
    if (pk >= rxb_len) pbyte = 8'h00;
  end
  assign pdb = (pdi[2:0] == 3'd0) ? pbyte[0] : pb_q[pdi[2:0]];

  always_ff @(posedge clk) begin
    p_done <= 1'b0;
    if (!card_on) begin
      p_q     <= P_IDLE;
      pbit_q  <= 1'b0;
      quiet_q <= 7'd0;
    end else if (tclk_fall) begin
      if (tena || p_q != P_IDLE || echo_q) quiet_q <= 7'd0;
      else if (quiet_q != QUIET)           quiet_q <= quiet_q + 7'd1;
      unique case (p_q)
        P_IDLE: if (rxb_full && !p_done_q && !tena && quiet_q == QUIET) begin
          p_q    <= P_SEND;
          pi_q   <= 14'd1;
          pbit_q <= 1'b1;
          pc_q   <= '1;
        end
        P_SEND: begin
          if (tena) begin
            p_q    <= P_JAM;
            pi_q   <= 14'd1;
            pbit_q <= 1'b1;
          end else if (pi_q == pend_bit) begin
            p_q    <= P_IDLE;
            pbit_q <= 1'b0;
            p_done <= 1'b1;
          end else begin
            pi_q <= pi_q + 14'd1;
            if (pi_q < 14'd64) begin
              pbit_q <= pi_q >= 14'd62 || !pi_q[0];
            end else if (pk < pnb) begin
              if (pdi[2:0] == 3'd0) pb_q <= pbyte;
              pbit_q <= pdb;
              pc_q   <= (pc_q >> 1) ^ ((pc_q[0] ^ pdb) ? POLY : 32'd0);
            end else begin
              pbit_q <= ~pc_q[0];
              pc_q   <= pc_q >> 1;
            end
          end
        end
        P_JAM: begin
          if (pi_q == 14'd32) begin
            p_q    <= P_IDLE;
            pbit_q <= 1'b0;
          end else begin
            pi_q   <= pi_q + 14'd1;
            pbit_q <= !pi_q[0];
          end
        end
        default: p_q <= P_IDLE;
      endcase
    end
  end

  assign rclk_rise = tclk_rise;
  assign rena      = echo_q || p_q != P_IDLE;
  assign rx        = p_q != P_IDLE ? pbit_q : rxe_q;
  assign clsn      = (tena && p_q != P_IDLE) || hb;

  // ---- capture: the chip's frame into the TX buffer ----
  typedef enum logic [1:0] {C_IDLE, C_PRE, C_DATA, C_DROP} cst_e;
  // Justification: (reg-a) capture state, bit and byte counts, the byte
  // so far, CRC, residue at the last byte boundary, the last bit,
  // collision seen.  Bytes gather into tb_wd and go to the buffer a
  // word at a time.
  cst_e        c_q;
  logic [2:0]  cb_q;
  logic [11:0] cn_q;
  logic [7:1]  cs_q;
  logic [31:0] cc_q;
  logic        cok_q, cl_q, ccol_q;
  logic        cap_done;        // one clock: a frame to copy, cap_len bytes
  logic [10:0] cap_len;
  logic        pend;            // DDR side: a captured frame is being copied
  logic [7:0]  crd;             // DDR side: words of it copied

  logic [7:0]  cbyte;
  logic [31:0] cc_n;
  assign cbyte = {tx, cs_q[7:1]};
  assign cc_n  = (cc_q >> 1) ^ ((cc_q[0] ^ tx) ? POLY : 32'd0);

  always_ff @(posedge clk) begin
    tena_q   <= tena;
    cap_done <= 1'b0;
    tb_we    <= 1'b0;
    if (!card_on) begin
      c_q <= C_IDLE;
    end else begin
      if (tena && clsn && !hb) ccol_q <= 1'b1;
      if (tena && !tena_q) begin
        c_q    <= C_PRE;
        cl_q   <= 1'b0;
        ccol_q <= 1'b0;
      end else if (!tena && tena_q) begin
        c_q <= C_IDLE;
        if (c_q == C_DATA && cn_q[2:0] != 3'd0 && !(pend && cn_q[10:3] >= crd)) begin
          tb_we <= 1'b1;                  // the last, partial word
          tb_wa <= cn_q[10:3];
        end
        if (c_q == C_DATA && !ccol_q && !pend && cn_q != 12'd0 && cn_q <= 12'(MAXLEN) + 12'd4) begin
          cap_done <= 1'b1;
          cap_len  <= (cok_q && cn_q >= 12'd4) ? 11'(cn_q - 12'd4) : 11'(cn_q);
        end
      end else if (tclk_fall && tena) begin
        unique case (c_q)
          C_PRE: begin
            cl_q <= tx;
            if (cl_q && tx) begin
              c_q   <= C_DATA;
              cb_q  <= 3'd0;
              cn_q  <= 12'd0;
              cc_q  <= '1;
              cok_q <= 1'b0;
            end
          end
          C_DATA: begin
            cs_q  <= cbyte[7:1];
            cc_q  <= cc_n;
            cb_q  <= cb_q + 3'd1;
            if (cb_q == 3'd7) begin
              // a byte: kept unless the copy has not yet read its word
              if (cn_q[11] || (pend && cn_q[10:3] >= crd)) c_q <= C_DROP;
              else if (cn_q[2:0] == 3'd7) tb_we <= 1'b1;
              tb_wa <= cn_q[10:3];
              tb_wd[8*cn_q[2:0] +: 8] <= cbyte;
              cn_q  <= cn_q + 12'd1;
              cok_q <= cc_n == RESIDUE;
            end
          end
          default: ;
        endcase
      end
    end
  end

  // ---- DDR side ----
  typedef enum logic [3:0] {
    D_IDLE, D_HDR, D_HDR0, D_POLL, D_CFG, D_CFGW, D_TRD, D_TWR, D_TLEN, D_TCNT, D_RLEN, D_RDAT, D_RCNT
  } dst_e;
  // Justification: (reg-a) DDR state, counters shared with Main, epoch,
  // poll timer, beat counts, the command held until accepted.
  dst_e        d_q;
  logic [31:0] tx_wr, tx_rd, rx_wr, rx_rd;
  logic [7:0]  epoch;
  logic        started;
  logic [9:0]  poll_q;
  logic [7:0]  beats;
  logic [10:0] tlen;
  logic        cfg_v;           // word 8 bit 63 of this poll
  logic        rd_q, we_q;
  logic [28:0] a_q;
  logic [7:0]  bc_q;
  logic [63:0] dn_q;

  logic [7:0] twords;           // TX words to copy
  assign twords = 8'((tlen + 11'd7) >> 3);

  logic [28:0] tslot, rslot;
  assign tslot = BASE + 29'h200 + {18'd0, tx_wr[2:0], 8'd0};
  assign rslot = BASE + 29'hA00 + {18'd0, rx_rd[2:0], 8'd0};

  logic accepted;
  assign accepted = (rd_q || we_q) && !ddr_busy;

  always_ff @(posedge clk) begin
    rb_we  <= 1'b0;
    cfg_wr <= 1'b0;
    if (cap_done) begin
      pend <= 1'b1;
      crd  <= 8'd0;
      tlen <= cap_len;
    end
    if (p_done) p_done_q <= 1'b1;
    if (!rst_n) begin
      d_q      <= D_IDLE;
      rd_q     <= 1'b0;
      we_q     <= 1'b0;
      started  <= 1'b0;
      epoch    <= 8'd0;
      pend     <= 1'b0;
      rxb_full <= 1'b0;
      mac_ok   <= 1'b0;
      cfg_ok   <= 1'b0;
      p_done_q <= 1'b0;
      poll_q   <= 10'd0;
    end else begin
      if (!card_on) begin
        mac_ok <= 1'b0;
        cfg_ok <= 1'b0;
        if (d_q == D_IDLE) begin
          started  <= 1'b0;
          pend     <= 1'b0;
          rxb_full <= 1'b0;
          p_done_q <= 1'b0;
        end
      end
      if (poll_q != 10'd0) poll_q <= poll_q - 10'd1;
      if (accepted) begin
        rd_q <= 1'b0;
        we_q <= 1'b0;
      end
      unique case (d_q)
        D_IDLE: begin
          if (card_on && !started) begin
            started <= 1'b1;
            epoch   <= epoch + 8'd1;
            {tx_wr, tx_rd, rx_wr, rx_rd} <= '0;
            d_q   <= D_HDR;
            we_q  <= 1'b1;
            a_q   <= BASE + 29'd1;
            bc_q  <= 8'd4;
            dn_q  <= 64'd0;
            beats <= 8'd4;
          end else if (card_on && started && pend) begin
            if (tx_wr - tx_rd >= 32'd8) pend <= 1'b0;   // ring full: dropped
            else begin
              d_q   <= D_TRD;
              beats <= 8'd0;
            end
          end else if (card_on && started && p_done_q) begin
            p_done_q <= 1'b0;
            rxb_full <= 1'b0;
            rx_rd    <= rx_rd + 32'd1;
            d_q      <= D_RCNT;
            we_q     <= 1'b1;
            a_q      <= BASE + 29'd4;
            bc_q     <= 8'd1;
            dn_q     <= {32'd0, rx_rd + 32'd1};
          end else if (card_on && started && !rxb_full && rx_wr != rx_rd) begin
            d_q  <= D_RLEN;
            rd_q <= 1'b1;
            a_q  <= rslot;
            bc_q <= 8'd1;
          end else if (card_on && started && poll_q == 10'd0) begin
            d_q    <= D_POLL;
            rd_q   <= 1'b1;
            a_q    <= BASE + 29'd2;
            bc_q   <= 8'd6;
            beats  <= 8'd0;
            poll_q <= POLL;
          end
        end
        // a burst of zeros, one beat accepted per clock without BUSY
        D_HDR: if (we_q && !ddr_busy) begin
          beats <= beats - 8'd1;
          if (beats == 8'd1) begin
            d_q  <= D_HDR0;
            we_q <= 1'b1;
            a_q  <= BASE;
            bc_q <= 8'd1;
            dn_q <= {MAGIC, 24'd0, epoch};
          end else begin
            we_q <= 1'b1;
          end
        end
        D_HDR0: if (accepted) d_q <= D_IDLE;
        D_POLL: if (ddr_dout_ready) begin
          beats <= beats + 8'd1;
          unique case (beats[3:0])
            4'd0: tx_rd <= ddr_dout[31:0];
            4'd1: rx_wr <= ddr_dout[31:0];
            4'd3: begin
              mac_ok <= ddr_dout[63];
              for (int i = 0; i < 6; i++) mac[47 - 8*i -: 8] <= ddr_dout[8*i +: 8];
            end
            default: ;
          endcase
          if (beats[3:0] == 4'd5) begin
            d_q   <= D_CFG;
            rd_q  <= 1'b1;
            a_q   <= BASE + 29'd8;
            bc_q  <= 8'd1;
            beats <= 8'd0;
          end
        end
        // beats[4:2] the configuration word, beats[1:0] the half
        D_CFG: if (ddr_dout_ready) begin
          dn_q <= ddr_dout;
          if (beats[4:2] == 3'd0) cfg_v <= ddr_dout[63];
          d_q  <= D_CFGW;
        end
        D_CFGW: begin
          cfg_wr   <= 1'b1;
          cfg_addr <= beats[4:0];
          cfg_data <= dn_q[15:0];
          dn_q     <= dn_q >> 16;
          beats    <= beats + 8'd1;
          if (beats[1:0] == 2'd3) begin
            if (beats[4:2] == 3'd7) begin
              cfg_ok <= cfg_v;
              d_q    <= D_IDLE;
            end else begin
              d_q  <= D_CFG;
              rd_q <= 1'b1;
              a_q  <= BASE + 29'd9 + {26'd0, beats[4:2]};
            end
          end
        end
        // copy word by word: read the buffer, then write while held
        D_TRD: begin
          if (!we_q) begin
            if (beats[1]) begin
              d_q   <= D_TWR;
              we_q  <= 1'b1;
              a_q   <= tslot + 29'd1 + {21'd0, crd};
              bc_q  <= 8'd1;
              dn_q  <= tb_q;
            end else beats <= beats + 8'd1;
          end
        end
        D_TWR: if (accepted) begin
          crd   <= crd + 8'd1;
          beats <= 8'd0;
          if (crd + 8'd1 == twords) begin
            d_q  <= D_TLEN;
            we_q <= 1'b1;
            a_q  <= tslot;
            dn_q <= {53'd0, tlen};
          end else d_q <= D_TRD;
        end
        D_TLEN: if (accepted) begin
          d_q   <= D_TCNT;
          we_q  <= 1'b1;
          a_q   <= BASE + 29'd1;
          dn_q  <= {32'd0, tx_wr + 32'd1};
          tx_wr <= tx_wr + 32'd1;
        end
        D_TCNT: if (accepted) begin
          d_q  <= D_IDLE;
          pend <= 1'b0;
        end
        D_RLEN: if (ddr_dout_ready) begin
          if (ddr_dout[15:0] == 16'd0 || ddr_dout[15:0] > 16'(MAXLEN)) begin
            rx_rd <= rx_rd + 32'd1;           // nothing to send: skipped
            d_q   <= D_RCNT;
            we_q  <= 1'b1;
            a_q   <= BASE + 29'd4;
            dn_q  <= {32'd0, rx_rd + 32'd1};
          end else begin
            rxb_len <= ddr_dout[10:0];
            d_q     <= D_RDAT;
            rd_q    <= 1'b1;
            a_q     <= rslot + 29'd1;
            bc_q    <= 8'((ddr_dout[10:0] + 11'd7) >> 3);
            beats   <= 8'd0;
          end
        end
        D_RDAT: if (ddr_dout_ready) begin
          rb_we <= 1'b1;
          rb_wa <= beats;
          rb_wd <= ddr_dout;
          beats <= beats + 8'd1;
          if (beats + 8'd1 == bc_q) begin
            rxb_full <= 1'b1;
            d_q      <= D_IDLE;
          end
        end
        D_RCNT: if (accepted) d_q <= D_IDLE;
        default: d_q <= D_IDLE;
      endcase
    end
  end
  assign tb_ra = (d_q == D_TRD || d_q == D_TWR) ? crd : 8'd0;

  assign ddr_rd       = rd_q;
  assign ddr_we       = we_q;
  assign ddr_addr     = a_q;
  assign ddr_burstcnt = bc_q;
  assign ddr_din      = dn_q;
  assign ddr_be       = 8'hFF;
endmodule
`default_nettype wire
