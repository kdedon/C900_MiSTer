// Am7990 receive side: deserializer, address filter, FCS check, and the
// word staging that reads received bytes out of the silo.
//
// RENA high: after 8 RCLKs hunt for "011" (the end of the preamble and
// sync, TM p.1-17); then bytes LSB first.  The 6 destination bytes are
// compared as they come: PADR, broadcast, or (group bit) the LADRF bit
// picked by the reflected CRC register's top 6 bits after 48 bits
// (TM p.1-24, App. B).  A rejected frame is rewound out of the silo.
// RENA low ends the frame; dribble bits are dropped.  The FCS is good
// when the register held the CRC-32 residue at the last byte boundary.
//
// Half duplex: no reception while transmitting, while a frame waits
// out the interpacket gap, or while transmit bytes wait, except during
// a backoff: then reception takes the silo from them (rtake,
// TM p.1-16).  CLSN ends a reception at once (TM p.1-11); the runt and
// FCS rules then decide the fragment.  For 4.1 us after TENA
// or a reception ends, RENA is masked: after a transmission the hunt
// starts once the window is over, after a reception the frame is not
// received (TM p.1-17, p.1-19).  Without loop, frames under 64 bytes
// are runts (TM p.1-19).
`default_nettype none
module am7990_rx (
  input  logic        clk,
  input  logic        clr,
  input  logic        tclk_rise,
  input  logic        rclk_rise,
  input  logic        rx,
  input  logic        rena,
  input  logic        clsn,
  input  logic        on,          // receiver on: STRT and RXON
  input  logic        loop,        // MODE.LOOP
  input  logic        tena,
  input  logic        ipg_wait,    // a transmission waits for the gap
  input  logic        txbusy,      // transmit bytes in the silo or on their way
  input  logic        backoff,
  output logic        rtake,
  output logic        busy,        // a frame is coming in
  input  logic [47:0] padr,        // byte 0 first on the wire in [7:0]
  input  logic [63:0] ladrf,
  input  logic        prom,
  input  logic        nocheck,     // LOOP without DTCR: FCS not checked
  // silo write side
  output logic        swe,
  output logic [7:0]  sbyte,
  output logic        slast,
  output logic [1:0]  stag,
  output logic        scommit,
  output logic        srewind,
  output logic        smark,
  input  logic        sfull,
  // silo head, when it is a receive byte
  input  logic        hv,
  input  logic [10:0] hd,
  input  logic [5:0]  rbytes,
  output logic        htake,
  // staged bytes for the DMA: one or two, the first in b0
  output logic        wv,
  output logic [7:0]  b0,
  output logic [7:0]  b1,
  output logic        two,
  output logic        l0,
  output logic        l1,
  output logic [1:0]  t0,
  output logic [1:0]  t1,
  input  logic        wpop,        // take both staged bytes
  input  logic        wone,        // take b0 only
  output logic        any,         // frame data waits
  output logic        burst,       // 16 bytes wait, or a frame end
  output logic        ended        // a frame end waits
);
  localparam logic [31:0] POLY    = 32'hEDB8_8320;
  localparam logic [31:0] RESIDUE = 32'hDEBB_20E3;
  localparam logic [5:0]  MASK    = 6'd41;          // 4.1 us in TCLKs
  localparam logic [11:0] RUNT    = 12'd64;
  localparam logic [1:0]  T_GOOD = 2'b00, T_CRC = 2'b01, T_RUNT = 2'b11;

  // ---- deserializer ----
  typedef enum logic [1:0] {R_IDLE, R_HUNT, R_DATA, R_DROP} rst_e;
  // Justification: (reg-a) receive state, counters, shift register, CRC,
  // filter partials, the byte waiting for its successor, the RENA mask.
  rst_e        r_q;
  logic [3:0]  hn_q;            // RCLKs since RENA
  logic [1:0]  hb_q;            // last two bits while hunting
  logic [2:0]  bn_q;
  logic [6:0]  sr_q;            // bits 7:1 of the byte so far
  logic [11:0] len_q;
  logic [31:0] crc_q;
  logic        phys_q, bc_q, mc_q, acc_q;
  logic        okb_q;           // FCS residue at the last byte boundary
  logic        pv_q;
  logic [7:0]  pd_q;
  logic [5:0]  w_q;             // mask TCLKs left
  logic        wrx_q;           // the mask follows a reception
  logic        tena_q;

  logic [7:0]  byte_n;
  logic [31:0] crc_n;
  logic        fb;
  assign byte_n = {rx, sr_q};
  assign fb     = crc_q[0] ^ rx;
  assign crc_n  = (crc_q >> 1) ^ (fb ? POLY : 32'd0);

  // filter on the byte just completed
  logic [7:0] pb;
  always_comb begin
    unique case (len_q[2:0])
      3'd0:    pb = padr[7:0];
      3'd1:    pb = padr[15:8];
      3'd2:    pb = padr[23:16];
      3'd3:    pb = padr[31:24];
      3'd4:    pb = padr[39:32];
      default: pb = padr[47:40];
    endcase
  end
  logic phys_n, bc_n, mc_n, hit;
  assign phys_n = (len_q == 12'd0 || phys_q) && byte_n == pb;
  assign bc_n   = (len_q == 12'd0 || bc_q) && byte_n == 8'hFF;
  assign mc_n   = (len_q == 12'd0) ? byte_n[0] : mc_q;
  assign hit    = prom || bc_n || (mc_n ? ladrf[crc_n[31:26]] : phys_n);

  // start of a reception
  logic allow, start;
  assign allow = loop || (!tena && !ipg_wait && (!txbusy || backoff));
  assign start = rclk_rise && r_q == R_IDLE && rena && !clsn && on && allow && w_q == 6'd0;
  assign rtake = start && !loop && txbusy;

  // silo writes, all on an RCLK
  logic rend, byte_done, data_end, accept, ovf;
  assign rend      = !rena || clsn;
  assign byte_done = rclk_rise && r_q == R_DATA && !rend && bn_q == 3'd7;
  assign data_end  = rclk_rise && r_q == R_DATA && rend;
  assign accept    = byte_done && len_q == 12'd5 && hit;
  assign swe       = (byte_done || (data_end && acc_q)) && pv_q;
  assign ovf       = swe && sfull;
  assign scommit   = acc_q || accept;
  assign smark     = ovf && scommit;
  assign srewind   = (byte_done && len_q == 12'd5 && !hit) || (data_end && !acc_q) ||
                     (ovf && !scommit);
  assign sbyte     = pd_q;
  assign slast     = data_end;
  assign stag      = (!loop && len_q < RUNT) ? T_RUNT : (nocheck || okb_q) ? T_GOOD : T_CRC;

  always_ff @(posedge clk) begin
    if (clr) begin
      r_q  <= R_IDLE;
      pv_q <= 1'b0;
    end else if (rclk_rise) begin
      unique case (r_q)
        R_IDLE: if (start) begin
          r_q  <= R_HUNT;
          hn_q <= 4'd0;
          hb_q <= 2'b11;
        end else if (rena && on && allow && wrx_q && w_q != 6'd0) begin
          r_q <= R_DROP;
        end
        R_HUNT: begin
          if (rend) r_q <= rena ? R_DROP : R_IDLE;
          else begin
            if (hn_q != 4'd8) hn_q <= hn_q + 4'd1;
            hb_q <= {hb_q[0], rx};
            if (hn_q == 4'd8 && hb_q == 2'b01 && rx) begin
              r_q    <= R_DATA;
              bn_q   <= 3'd0;
              len_q  <= 12'd0;
              crc_q  <= '1;
              pv_q   <= 1'b0;
              acc_q  <= 1'b0;
              okb_q  <= 1'b0;
            end
          end
        end
        R_DATA: begin
          if (rend) begin
            r_q  <= rena ? R_DROP : R_IDLE;
            pv_q <= 1'b0;
          end else begin
            sr_q  <= byte_n[7:1];
            crc_q <= crc_n;
            bn_q  <= bn_q + 3'd1;
            if (bn_q == 3'd7) begin
              len_q  <= len_q + 12'd1;
              phys_q <= phys_n;
              bc_q   <= bc_n;
              mc_q   <= mc_n;
              pv_q   <= 1'b1;
              pd_q   <= byte_n;
              okb_q  <= crc_n == RESIDUE;
              if (accept) acc_q <= 1'b1;
              if (srewind || ovf) r_q <= R_DROP;
            end
          end
        end
        R_DROP: if (!rena) r_q <= R_IDLE;
        default: r_q <= R_IDLE;
      endcase
    end
  end

  // RENA mask after a transmission or a reception
  always_ff @(posedge clk) begin
    tena_q <= tena;
    if (clr) begin
      w_q   <= 6'd0;
      wrx_q <= 1'b0;
    end else if (tena_q && !tena) begin
      w_q   <= MASK;
      wrx_q <= 1'b0;
    end else if (rclk_rise && r_q != R_IDLE && !rena) begin
      w_q   <= MASK;
      wrx_q <= 1'b1;
    end else if (tclk_rise && w_q != 6'd0) begin
      w_q <= w_q - 6'd1;
    end
  end

  assign busy = r_q != R_IDLE;

  // ---- word staging: up to two bytes from the silo head ----
  // Justification: (reg-a) the staged bytes, their last flags and tags.
  logic [1:0] n_q;
  logic [7:0] s0_q, s1_q;
  logic       l0_q, l1_q;
  logic [1:0] t0_q, t1_q;
  assign htake = hv && !wpop && !wone && (n_q == 2'd0 || (n_q == 2'd1 && !l0_q));

  always_ff @(posedge clk) begin
    if (clr) begin
      n_q <= 2'd0;
    end else if (wpop) begin
      n_q <= 2'd0;
    end else if (wone) begin
      n_q  <= n_q - 2'd1;
      s0_q <= s1_q;
      l0_q <= l1_q;
      t0_q <= t1_q;
    end else if (htake) begin
      if (n_q == 2'd0) begin
        s0_q <= hd[7:0];
        l0_q <= hd[8];
        t0_q <= hd[10:9];
      end else begin
        s1_q <= hd[7:0];
        l1_q <= hd[8];
        t1_q <= hd[10:9];
      end
      n_q <= n_q + 2'd1;
    end
  end

  // frame ends committed and not yet taken
  // Justification: (reg-a) count of last bytes in the silo or staged.
  logic [3:0] ends_q;
  logic       end_in, end_out;
  assign end_in  = (swe && slast && !sfull) || smark;
  assign end_out = (wpop && (two ? l1_q : l0_q)) || (wone && l0_q);
  always_ff @(posedge clk) begin
    if (clr) ends_q <= 4'd0;
    else ends_q <= ends_q + 4'(end_in) - 4'(end_out);
  end

  assign wv    = n_q == 2'd2 || (n_q == 2'd1 && l0_q);
  assign b0    = s0_q;
  assign b1    = s1_q;
  assign two   = n_q == 2'd2;
  assign l0    = l0_q;
  assign l1    = l1_q;
  assign t0    = t0_q;
  assign t1    = t1_q;
  assign any   = rbytes != 6'd0 || n_q != 2'd0 || ends_q != 4'd0;
  assign ended = ends_q != 4'd0;
  assign burst = ends_q != 4'd0 || 6'(rbytes) + 6'(n_q) >= 6'd16;
endmodule
`default_nettype wire
