// ST-506 drive emulator: track byte generator.  Given a byte position of
// the revolution and a head, it produces the recorded byte there from
// the track's format (default or recorded by a Write Format) and the
// cylinder buffer, as the C900 leaves a track (st506_pkg layout):
//
//   GAP1 4E x gap1, then per slot k < nslots: 14 x 00, A1* IDENT CYL
//   HEAD SEC CRC CRC, 15 x 00, A1* F8 data[size] ECC x 4, 3 x 00,
//   GAP3 4E x gap; 4E after the last slot.  (* = missing clock)
//
// One request at a time; the result is ready within 30 clks (the drive
// asks one disk byte = 32 steps ahead).  The slot of a position is found
// by repeated subtraction, continued from the last request with the
// same GAP1 and slot length (one step for the next byte; heads with the
// default format share it).  A head whose recorded format differs from
// the last one searches from slot 0: up to 19 steps at 512 B sectors,
// more for 256/128 B, where the read-nothing window after such a head
// change grows past three bytes at one clk per step.  A data or ECC byte
// whose sector is not in the buffer (or, for data, not yet filled that
// far; ECC needs the whole sector) is a miss: `miss` comes with `done`.
`default_nettype none

module st506_walker #(
  parameter int unsigned MAX_L2    = 9,      // log2 of the largest sector size
  parameter int unsigned FMT_SLOTS = 64
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        start,
  input  logic [13:0] pos_byte,     // byte of the revolution
  input  logic [2:0]  head,
  input  logic        hint_clr,     // the format of some head changed
  output logic [2:0]  fhead,        // head of the request in flight (selects fmt_*)
  // format of fhead
  input  logic        fmt_custom,
  input  logic [15:0] fmt_gap1,
  input  logic [15:0] fmt_gap,
  input  logic [7:0]  fmt_nslots,
  // geometry
  input  logic [10:0] cyl,
  input  logic [7:0]  spt,
  input  logic [1:0]  ssz,
  // recorded ID table, one clk latency
  output logic [$clog2(8*FMT_SLOTS)-1:0] id_raddr,
  input  logic [24:0] id_q,          // {bad, size[1:0], head[2:0], cyl[10:0], sec[7:0]}
  output logic        id_use,        // the ID table read port is used this clk
  // sector buffer lookup (combinational) for head lk_head, sector lk_sec
  output logic [2:0]  lk_head,
  output logic [7:0]  lk_sec,
  input  logic        lk_hit,        // an entry holds or is filling the sector
  input  logic [3:0]  lk_ent,
  input  logic        lk_full,       // the entry is complete
  input  logic [10:0] lk_cnt,        // bytes filled so far, when not complete
  // sector buffer and ECC table, one clk latency
  output logic [MAX_L2+3:0] wk_addr,
  input  logic [7:0]        wk_q,
  output logic [3:0]        ek_idx,
  input  logic [31:0]       ek_q,
  // result
  output logic        done,          // result valid (held until the next start)
  output logic [7:0]  val,
  output logic        mark,          // an A1 address mark
  output logic        miss           // a data or ECC byte not in the buffer
);
  import st506_pkg::*;

  localparam int unsigned IW = $clog2(8 * FMT_SLOTS);
  localparam int unsigned KW = $clog2(FMT_SLOTS);
  localparam logic [31:0] EccZ128  = ecc_zero(128);
  localparam logic [31:0] EccZ256  = ecc_zero(256);
  localparam logic [31:0] EccZ512  = ecc_zero(512);
  localparam logic [31:0] EccZ1024 = ecc_zero(1024);

  typedef enum logic [3:0] {WIdle, WPos, WDiv, WId, WIdv, WRd, WRdv, WCrc, WDone} wk_e;

  // Justification: request state, position, slot and remainder (reg-a).
  wk_e         st_q;
  logic [13:0] m_q;
  logic [2:0]  h_q;
  logic [15:0] rem_q, base_q;
  logic [7:0]  k_q;
  // Justification: continuation of the slot search for the same layout (reg-a).
  logic        hv_q;
  logic [15:0] hg1_q, hsl_q;
  logic [7:0]  hk_q;
  logic [15:0] hbase_q;
  // Justification: the slot's ID (reg-a).
  logic [10:0] icyl_q;
  logic [7:0]  ihb_q, isec_q;
  // Justification: CRC over the ID, byte counter (reg-a).
  logic [15:0] crc_q;
  logic [2:0]  ci_q;
  // Justification: buffer/ECC read addresses, which byte is wanted, and
  // whether it is in the buffer (reg-a).
  logic [MAX_L2+3:0] addr_q;
  logic [3:0]        eidx_q;
  logic              is_ecc_q;
  logic [1:0]        eb_q;
  logic              miss_q;
  // Justification: result (reg-a).
  logic [7:0]  val_q;
  logic        mark_q;
  logic        wmiss_q;

  logic [10:0] size_c, slen_lo_c;
  logic [15:0] slen_c, g1_c;
  logic [16:0] pos_c;
  logic [7:0]  hmod_c, dsec_c, nsl_c;
  logic [10:0] o_c;
  logic [7:0]  crc_byte_c, sec_c;
  logic [15:0] crc_n_c;
  logic [31:0] ezero_c;

  assign size_c    = 11'd1 << size_log2(ssz);
  assign slen_lo_c = SlotFixed0 + size_c;
  assign slen_c    = {5'd0, slen_lo_c} + (fmt_custom ? fmt_gap : Gap3Def);
  assign nsl_c     = fmt_custom ? fmt_nslots : spt;
  assign g1_c      = fmt_custom ? fmt_gap1 : Gap1Def;
  assign pos_c     = {3'd0, m_q} - {1'b0, g1_c};
  assign o_c       = rem_q[10:0];

  always_comb begin
    case (ssz)
      2'b00:   ezero_c = EccZ256;
      2'b01:   ezero_c = EccZ512;
      2'b10:   ezero_c = EccZ1024;
      default: ezero_c = EccZ128;
    endcase
  end

  // head mod spt (head <= 7), registered: h_q is set in WPos and read
  // from WIdv on; then the default slot -> sector map.
  // Justification: breaks the spt -> lookup path (reg-b).
  logic [7:0] hmod_q;
  always_comb begin
    hmod_c = head_mod(h_q, spt);
  end
  always_ff @(posedge clk) hmod_q <= hmod_c;
  assign dsec_c = (k_q >= hmod_q) ? k_q - hmod_q : k_q + spt - hmod_q;

  always_comb begin
    case (ci_q)
      3'd0:    crc_byte_c = 8'hA1;
      3'd1:    crc_byte_c = ident_of(icyl_q[10:8]);
      3'd2:    crc_byte_c = icyl_q[7:0];
      3'd3:    crc_byte_c = ihb_q;
      default: crc_byte_c = isec_q;
    endcase
  end

  assign id_raddr = IW'({h_q, k_q[KW-1:0]});
  assign crc_n_c  = crc16_byte(crc_q, crc_byte_c);
  assign sec_c    = fmt_custom ? id_q[7:0] : dsec_c;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_q <= WIdle;  m_q <= 14'd0;  h_q <= 3'd0;  rem_q <= 16'd0;  base_q <= 16'd0;  k_q <= 8'd0;
      hv_q <= 1'b0;  hg1_q <= 16'd0;  hsl_q <= 16'd0;  hk_q <= 8'd0;  hbase_q <= 16'd0;
      icyl_q <= 11'd0;  ihb_q <= 8'd0;  isec_q <= 8'd0;  crc_q <= 16'hFFFF;  ci_q <= 3'd0;
      val_q <= 8'h4E;  mark_q <= 1'b0;  wmiss_q <= 1'b0;
    end else begin
      if (hint_clr) hv_q <= 1'b0;
      unique case (st_q)
        WIdle, WDone: begin
          if (start) begin
            wmiss_q <= 1'b0;
            m_q <= pos_byte;  h_q <= head;  st_q <= WPos;
          end
        end
        WPos: begin
          if (pos_c[16]) begin
            val_q <= 8'h4E;  mark_q <= 1'b0;  st_q <= WDone;
          end else if (hv_q && !hint_clr && hg1_q == g1_c && hsl_q == slen_c && pos_c[15:0] >= hbase_q) begin
            rem_q <= pos_c[15:0] - hbase_q;  k_q <= hk_q;  base_q <= hbase_q;  st_q <= WDiv;
          end else begin
            rem_q <= pos_c[15:0];  k_q <= 8'd0;  base_q <= 16'd0;  st_q <= WDiv;
          end
        end
        WDiv: begin
          if (rem_q >= slen_c) begin
            rem_q  <= rem_q - slen_c;
            k_q    <= k_q + 8'd1;
            base_q <= base_q + slen_c;
          end else begin
            hv_q <= !hint_clr;  hg1_q <= g1_c;  hsl_q <= slen_c;  hk_q <= k_q;  hbase_q <= base_q;
            if (k_q >= nsl_c) begin
              val_q <= 8'h4E;  mark_q <= 1'b0;  st_q <= WDone;
            end else begin
              st_q <= WId;
            end
          end
        end
        WId: st_q <= WIdv;
        WIdv: begin
          if (fmt_custom) begin
            icyl_q <= id_q[18:8];
            ihb_q  <= {id_q[24], id_q[23:22], 2'b00, id_q[21:19]};
            isec_q <= id_q[7:0];
          end else begin
            icyl_q <= cyl;
            ihb_q  <= {1'b0, ssz, 2'b00, h_q};
            isec_q <= dsec_c;
          end
          crc_q  <= 16'hFFFF;  ci_q <= 3'd0;  mark_q <= 1'b0;  val_q <= 8'h00;
          st_q   <= WDone;
          if (o_c == OffId || o_c == OffData) begin
            val_q <= 8'hA1;  mark_q <= 1'b1;
          end else if (o_c == OffId + 11'd1) begin
            val_q <= ident_of(fmt_custom ? id_q[18:16] : cyl[10:8]);
          end else if (o_c == OffId + 11'd2) begin
            val_q <= fmt_custom ? id_q[15:8] : cyl[7:0];
          end else if (o_c == OffId + 11'd3) begin
            val_q <= fmt_custom ? {id_q[24], id_q[23:22], 2'b00, id_q[21:19]} : {1'b0, ssz, 2'b00, h_q};
          end else if (o_c == OffId + 11'd4) begin
            val_q <= fmt_custom ? id_q[7:0] : dsec_c;
          end else if (o_c == OffId + 11'd5 || o_c == OffId + 11'd6) begin
            st_q <= WCrc;
          end else if (o_c == OffData + 11'd1) begin
            val_q <= 8'hF8;
          end else if (o_c >= OffData + 11'd2 && o_c < OffData + 11'd6 + size_c) begin
            // data byte or ECC byte; addresses use the ID's sector
            st_q <= WRd;
          end else if (o_c >= slen_lo_c) begin
            val_q <= 8'h4E;
          end
        end
        WRd: st_q <= WRdv;
        WRdv: begin
          if (isec_q >= spt) begin
            val_q <= is_ecc_q ? ezero_c[{~eb_q, 3'b000} +: 8] : 8'h00;
          end else begin
            val_q   <= is_ecc_q ? ek_q[{~eb_q, 3'b000} +: 8] : wk_q;
            wmiss_q <= miss_q;
          end
          st_q <= WDone;
        end
        WCrc: begin
          crc_q <= crc_n_c;
          ci_q  <= ci_q + 3'd1;
          if (ci_q == 3'd4) begin
            val_q <= (o_c == OffId + 11'd5) ? crc_n_c[15:8] : crc_n_c[7:0];
            st_q  <= WDone;
          end
        end
        default: st_q <= WIdle;
      endcase
    end
  end

  // Buffer entry and ECC read addresses, from the slot's sector, in WIdv;
  // the data is there in WRdv.
  logic [10:0] di_c;
  logic        is_ecc_c;
  assign di_c     = o_c - (OffData + 11'd2);
  assign is_ecc_c = di_c >= size_c;
  assign lk_head  = h_q;
  assign lk_sec   = sec_c;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      addr_q <= '0;  eidx_q <= '0;  is_ecc_q <= 1'b0;  eb_q <= 2'd0;  miss_q <= 1'b0;
    end else if (st_q == WIdv) begin
      is_ecc_q <= is_ecc_c;
      eb_q     <= 2'(di_c - size_c);
      eidx_q   <= lk_ent;
      addr_q   <= {lk_ent, di_c[MAX_L2-1:0]};
      miss_q   <= !(lk_hit && (lk_full || (!is_ecc_c && di_c < lk_cnt)));
    end
  end

  assign fhead   = h_q;
  assign id_use  = st_q == WId;
  assign wk_addr = addr_q;
  assign ek_idx  = eidx_q;
  assign done    = st_q == WDone;
  assign val     = val_q;
  assign mark    = mark_q;
  assign miss    = wmiss_q;

endmodule

`default_nettype wire
