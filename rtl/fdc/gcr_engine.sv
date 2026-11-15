// MOS 8723 GCR state machine, data separator and shifters (drawing
// 315017 sec 1.5 and 1.8, Figures 3 and 4).
//
// One state per CLKIN rise (`step`), 16 states per bit cell less the
// GG skips (Figures 3 and 4 arc labels: 3 for GG 01/10/11, 13 for GG
// 10/11, 5 for GG 11).  Read: a rising RDATA sample with the data latch
// clear sets it and moves the state toward 8 (the Data=1 row of Figure
// 3 has no RP arcs, so later pulses in the cell do nothing); state 15
// clocks the latch into the 10-bit shifter, state 0 clears it.  Ten ones are sync and
// hold the divide-by-10 counter clear; every tenth bit otherwise
// decodes two quintets into the read latch and fires BRDY.  Write: WD
// toggles in state 8 of a 1-cell; the shifter reloads from the pending
// byte and fires BRDY.  Sync generate forces the PLA outputs High except
// the two pass-through bits 7 and 2, which carry data bits 6 and 2
// (sec 1.5); with no byte pending the shifter streams ones.
//
// Bus effects of the same sample (`wr_restart`, `wrp_set`) are applied
// before the step, the PH2-fall capture (`cap`) after it.
`default_nettype none

module gcr_engine (
  input  logic       clk,
  input  logic       pin_rst,      // /RESET Low this sample
  input  logic       step,         // CLKIN rise this sample
  input  logic       rdata,
  input  logic [1:0] gg,
  input  logic       wg,           // write gate (0x4002 bit 5)
  input  logic       syncgen,      // sync generate (0x4002 bit 7)
  input  logic       wr_restart,   // write gate opened by this sample's write
  input  logic       wrp_set,      // 0x4004/0x4005 write with WG or sync generate
  input  logic [7:0] wrp_val,
  input  logic       cap,          // 0x4005 PCSD-in byte captured at the PH2 fall
  input  logic [7:0] cap_val,
  output logic       fire,         // BRDY this sample
  output logic [7:0] data_byte,    // read latch (registered)
  output logic       shift_ones,   // read shifter all ones (registered)
  output logic       wd            // write-current level (registered)
);

  // Justification: state machine, data latch and RDATA edge (reg-a).
  logic [3:0] state_q, state_d;
  logic       rd_one_q, rd_one_d;
  logic       prev_rd_q, prev_rd_d;
  // Justification: read shifter, divide-by-10, read latch (reg-a).
  logic [9:0] rd_sh_q, rd_sh_d;
  logic [3:0] rd_bits_q, rd_bits_d;
  logic [7:0] db_q, db_d;
  // Justification: write shifter, bit counter, cell bit, WD level, pending byte (reg-a).
  logic [9:0] wr_sh_q, wr_sh_d;
  logic [3:0] wr_bits_q, wr_bits_d;
  logic       wr_bit_q, wr_bit_d;
  logic       wd_q, wd_d;
  logic [7:0] wrp_q, wrp_d;
  logic       wrp_v_q, wrp_v_d;

  function automatic logic [4:0] gcr_enc(input logic [3:0] n);
    case (n)
      4'h0: gcr_enc = 5'b01010;  4'h1: gcr_enc = 5'b01011;
      4'h2: gcr_enc = 5'b10010;  4'h3: gcr_enc = 5'b10011;
      4'h4: gcr_enc = 5'b01110;  4'h5: gcr_enc = 5'b01111;
      4'h6: gcr_enc = 5'b10110;  4'h7: gcr_enc = 5'b10111;
      4'h8: gcr_enc = 5'b01001;  4'h9: gcr_enc = 5'b11001;
      4'hA: gcr_enc = 5'b11010;  4'hB: gcr_enc = 5'b11011;
      4'hC: gcr_enc = 5'b01101;  4'hD: gcr_enc = 5'b11101;
      4'hE: gcr_enc = 5'b11110;  default: gcr_enc = 5'b10101;
    endcase
  endfunction

  // {valid, nibble}
  function automatic logic [4:0] gcr_dec(input logic [4:0] q);
    case (q)
      5'b01010: gcr_dec = 5'h10;  5'b01011: gcr_dec = 5'h11;
      5'b10010: gcr_dec = 5'h12;  5'b10011: gcr_dec = 5'h13;
      5'b01110: gcr_dec = 5'h14;  5'b01111: gcr_dec = 5'h15;
      5'b10110: gcr_dec = 5'h16;  5'b10111: gcr_dec = 5'h17;
      5'b01001: gcr_dec = 5'h18;  5'b11001: gcr_dec = 5'h19;
      5'b11010: gcr_dec = 5'h1A;  5'b11011: gcr_dec = 5'h1B;
      5'b01101: gcr_dec = 5'h1C;  5'b11101: gcr_dec = 5'h1D;
      5'b11110: gcr_dec = 5'h1E;  5'b10101: gcr_dec = 5'h1F;
      default:  gcr_dec = 5'h00;
    endcase
  endfunction

  // Next state for a read pulse in state s: s + 1 + jump, jump from the
  // Figure 3 label row +2 +2 +1 +1 +1 +1 +1 0 0 0 -1 -1 -1 -1 -2 -2.
  function automatic logic [3:0] rp_next(input logic [3:0] s);
    case (s)
      4'd0:  rp_next = 4'd3;   4'd1:  rp_next = 4'd4;
      4'd2:  rp_next = 4'd4;   4'd3:  rp_next = 4'd5;
      4'd4:  rp_next = 4'd6;   4'd5:  rp_next = 4'd7;
      4'd6:  rp_next = 4'd8;   4'd7:  rp_next = 4'd8;
      4'd8:  rp_next = 4'd9;   4'd9:  rp_next = 4'd10;
      4'd10: rp_next = 4'd10;  4'd11: rp_next = 4'd11;
      4'd12: rp_next = 4'd12;  4'd13: rp_next = 4'd13;
      4'd14: rp_next = 4'd13;  default: rp_next = 4'd14;
    endcase
  endfunction

  localparam logic [3:0] StWdToggle = 4'd8;    // Figure 4 nominal flux-change state
  localparam logic [3:0] StShift    = 4'd15;   // shifter clock
  localparam logic [3:0] BitsPerByte = 4'd10;
  localparam logic [9:0] AllOnes    = 10'h3FF;

  // GG=01 skips 3; GG=10 skips 3, 13; GG=11 skips 3, 5, 13.
  function automatic logic skipped(input logic [1:0] g, input logic [3:0] s);
    skipped = (s == 4'd3  && g != 2'd0) ||
              (s == 4'd5  && g == 2'd3) ||
              (s == 4'd13 && g[1]);
  endfunction

  logic       rp, latch;
  logic [4:0] nxt;
  logic [4:0] dec_hi, dec_lo;
  logic [3:0] wb;

  always_comb begin
    state_d   = state_q;   rd_one_d  = rd_one_q;  prev_rd_d = prev_rd_q;
    rd_sh_d   = rd_sh_q;   rd_bits_d = rd_bits_q; db_d      = db_q;
    wr_sh_d   = wr_sh_q;   wr_bits_d = wr_bits_q; wr_bit_d  = wr_bit_q;
    wd_d      = wd_q;      wrp_d     = wrp_q;     wrp_v_d   = wrp_v_q;
    fire      = 1'b0;
    rp        = 1'b0;
    latch     = rd_one_q;
    nxt       = 5'd0;
    dec_hi    = 5'd0;
    dec_lo    = 5'd0;
    wb        = 4'd0;

    // Bus effects of this sample.
    if (wrp_set) begin
      wrp_d   = wrp_val;
      wrp_v_d = 1'b1;
    end
    if (wr_restart) begin
      wr_sh_d   = 10'd0;
      wr_bits_d = 4'd0;
      wr_bit_d  = 1'b0;
      wrp_v_d   = 1'b0;
    end

    if (step) begin
      rp        = rdata & ~prev_rd_q;
      prev_rd_d = rdata;
      if (wg && state_q == StWdToggle && wr_bit_d) wd_d = ~wd_q;
      nxt = {1'b0, state_q} + 5'd1;
      if (rp && !wg && !rd_one_q) begin
        rd_one_d = 1'b1;
        nxt      = {1'b0, rp_next(state_q)};
      end
      if (state_q == StShift) begin
        // Shifter clock.
        if (wg) begin
          wb = wr_bits_d;
          if (wr_bits_d == 4'd0) begin
            if (!wrp_v_d)
              wr_sh_d = AllOnes;
            else if (syncgen)
              wr_sh_d = {2'b11, wrp_d[6], 4'b1111, wrp_d[2], 2'b11};
            else
              wr_sh_d = {gcr_enc(wrp_d[7:4]), gcr_enc(wrp_d[3:0])};
            wrp_v_d = 1'b0;
            wb      = BitsPerByte;
            fire    = 1'b1;
          end
          wr_bits_d = wb - 4'd1;
          wr_bit_d  = wr_sh_d[wr_bits_d];
        end else begin
          rd_sh_d = {rd_sh_q[8:0], latch};
          if (rd_sh_d == AllOnes) begin
            rd_bits_d = 4'd0;
          end else if (rd_bits_q == BitsPerByte - 4'd1) begin
            rd_bits_d = 4'd0;
            dec_hi    = gcr_dec(rd_sh_d[9:5]);
            dec_lo    = gcr_dec(rd_sh_d[4:0]);
            db_d      = (dec_hi[4] && dec_lo[4]) ? {dec_hi[3:0], dec_lo[3:0]} : 8'h00;
            fire      = 1'b1;
          end else begin
            rd_bits_d = rd_bits_q + 4'd1;
          end
        end
        if (nxt == 5'd16) begin
          nxt      = 5'd0;
          rd_one_d = 1'b0;
        end
      end
      if (skipped(gg, nxt[3:0])) nxt = nxt + 5'd1;
      state_d = nxt[3:0];
    end

    if (cap) begin
      wrp_d   = cap_val;
      wrp_v_d = 1'b1;
    end

    if (pin_rst) begin
      state_d   = 4'd0;   rd_one_d  = 1'b0;  prev_rd_d = 1'b0;
      rd_sh_d   = 10'd0;  rd_bits_d = 4'd0;  db_d      = 8'h00;
      wr_sh_d   = 10'd0;  wr_bits_d = 4'd0;  wr_bit_d  = 1'b0;
      wd_d      = 1'b0;   wrp_v_d   = 1'b0;  wrp_d     = wrp_q;
      fire      = 1'b0;
    end
  end

  initial begin
    state_q   = 4'd0;   rd_one_q  = 1'b0;  prev_rd_q = 1'b0;
    rd_sh_q   = 10'd0;  rd_bits_q = 4'd0;  db_q      = 8'h00;
    wr_sh_q   = 10'd0;  wr_bits_q = 4'd0;  wr_bit_q  = 1'b0;
    wd_q      = 1'b0;   wrp_q     = 8'h00; wrp_v_q   = 1'b0;
  end
  always_ff @(posedge clk) begin
    state_q   <= state_d;   rd_one_q  <= rd_one_d;  prev_rd_q <= prev_rd_d;
    rd_sh_q   <= rd_sh_d;   rd_bits_q <= rd_bits_d; db_q      <= db_d;
    wr_sh_q   <= wr_sh_d;   wr_bits_q <= wr_bits_d; wr_bit_q  <= wr_bit_d;
    wd_q      <= wd_d;      wrp_q     <= wrp_d;     wrp_v_q   <= wrp_v_d;
  end

  assign data_byte  = db_q;
  assign shift_ones = rd_sh_q == AllOnes;
  assign wd         = wd_q;

endmodule

`default_nettype wire
