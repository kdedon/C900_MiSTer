// 8716 FIFO between the B bus and the Z-Bus: 64 x 8, one clock,
// first-word-fall-through.  The depth is inferred from sheet 6 ("16usecs
// at most for a 64 byte deep FIFO"), not transcribed; DEPTH keeps it a
// parameter.
//
// Ports: a byte port for the B side and a word port for the Z side (the
// even byte first), both usable in the same clock.  One posedge applies,
// in order: clr, the byte push or pop, hold_clr, the word push or pop.
// Each stage sees the occupancy the earlier stages left:
//   b_*      after clr (the byte access gate and the head byte),
//   mid_empty after the byte access (status BYTERDY),
//   w_*      after hold_clr (the word gate and the two head bytes).
// Push on full drops the byte; pop on empty takes nothing.  A word access
// moves each byte separately; a missing word byte reads 0.
//
// Storage is four banks interleaved by address (bank = address mod 4),
// each one MLAB with one write and one asynchronous read.  The three
// accesses of a clock are to consecutive addresses, so each lands in its
// own bank.  Under hold_clr the word port is idle (the DMA engine is held
// in IDLE) and its read is of an empty FIFO, so the byte access takes
// the bank.
`default_nettype none

module fifo64 #(
  parameter int DEPTH = 64
) (
  input  logic        clk,
  input  logic        clr,
  input  logic        b_push,
  input  logic [7:0]  b_wdata,
  input  logic        b_pop,
  output logic [7:0]  b_rdata,
  output logic        b_empty,
  output logic        b_full,
  output logic        mid_empty,
  input  logic        hold_clr,
  input  logic        w_push,
  input  logic [15:0] w_wdata,
  input  logic        w_pop,
  output logic [15:0] w_rdata,
  output logic [$clog2(DEPTH):0] w_used
);

  localparam int AW = $clog2(DEPTH);
  localparam int UW = AW + 1;
  localparam int NB = 4;                 // banks
  localparam int BW = AW - 2;            // index inside a bank
  localparam int BD = DEPTH / NB;
  localparam logic [UW-1:0] U_ZERO = '0;
  localparam logic [UW-1:0] U_ONE  = UW'(1);
  localparam logic [UW-1:0] U_TWO  = UW'(2);
  localparam logic [UW-1:0] U_FULL = UW'(DEPTH);
  localparam logic [AW-1:0] P_ONE  = AW'(1);

  // Justification: read/write pointers, occupancy (reg-a).
  logic [AW-1:0] rd_q, wr_q;
  logic [UW-1:0] used_q;

  // Stage pointers and counts: a = after clr, b = after the byte access,
  // c = after hold_clr, d = after the word access.
  logic [AW-1:0] rd_a, wr_a, rd_b, wr_b, rd_c, wr_c, rd_d, wr_d;
  logic [UW-1:0] used_a, used_b, used_c, used_d;
  logic          b_push_ok, b_pop_ok;
  logic          w_push_lo, w_push_hi, w_pop_lo, w_pop_hi;

  assign rd_a   = clr ? '0 : rd_q;
  assign wr_a   = clr ? '0 : wr_q;
  assign used_a = clr ? U_ZERO : used_q;

  assign b_push_ok = b_push && used_a != U_FULL;
  assign b_pop_ok  = b_pop && used_a != U_ZERO;
  assign rd_b      = b_pop_ok ? rd_a + P_ONE : rd_a;
  assign wr_b      = b_push_ok ? wr_a + P_ONE : wr_a;
  assign used_b    = used_a + (b_push_ok ? U_ONE : U_ZERO) - (b_pop_ok ? U_ONE : U_ZERO);

  assign rd_c   = hold_clr ? '0 : rd_b;
  assign wr_c   = hold_clr ? '0 : wr_b;
  assign used_c = hold_clr ? U_ZERO : used_b;

  assign w_push_lo = w_push && used_c != U_FULL;
  assign w_push_hi = w_push && used_c < U_FULL - U_ONE;
  assign w_pop_lo  = w_pop && used_c != U_ZERO;
  assign w_pop_hi  = w_pop && used_c >= U_TWO;

  assign rd_d   = rd_c + AW'(w_pop_lo) + AW'(w_pop_hi);
  assign wr_d   = wr_c + AW'(w_push_lo) + AW'(w_push_hi);
  assign used_d = used_c + UW'(w_push_lo) + UW'(w_push_hi) - UW'(w_pop_lo) - UW'(w_pop_hi);

  initial begin
    rd_q   = '0;
    wr_q   = '0;
    used_q = U_ZERO;
  end
  always_ff @(posedge clk) begin
    rd_q   <= rd_d;
    wr_q   <= wr_d;
    used_q <= used_d;
  end

  // The three accesses of a clock: byte (b), word low (l), word high (h).
  logic [AW-1:0] wr_h, rd_h;
  assign wr_h = wr_c + P_ONE;
  assign rd_h = rd_c + P_ONE;

  logic [BW-1:0] bank_wa [NB];
  logic [7:0]    bank_wd [NB];
  logic          bank_we [NB];
  logic [BW-1:0] bank_ra [NB];
  logic [7:0]    bank_rq [NB];

  genvar j;
  generate for (j = 0; j < NB; j++) begin : g_bank
    // The word bytes come later in the sample: they win a same-address
    // collision with the byte push, as the single store did.
    always_comb begin
      bank_we[j] = 1'b0;
      bank_wa[j] = wr_a[AW-1:2];
      bank_wd[j] = b_wdata;
      if (b_push_ok && wr_a[1:0] == 2'(j)) begin
        bank_we[j] = 1'b1;
      end
      if (w_push_lo && wr_c[1:0] == 2'(j)) begin
        bank_we[j] = 1'b1;
        bank_wa[j] = wr_c[AW-1:2];
        bank_wd[j] = w_wdata[15:8];
      end
      if (w_push_hi && wr_h[1:0] == 2'(j)) begin
        bank_we[j] = 1'b1;
        bank_wa[j] = wr_h[AW-1:2];
        bank_wd[j] = w_wdata[7:0];
      end
    end

    fifo64_bank #(.DEPTH(BD), .AW(BW)) u_mem (
      .clk(clk), .we(bank_we[j]), .wa(bank_wa[j]), .wd(bank_wd[j]),
      .ra(bank_ra[j]), .rq(bank_rq[j])
    );

    always_comb begin
      bank_ra[j] = rd_h[AW-1:2];
      if (rd_c[1:0] == 2'(j)) bank_ra[j] = rd_c[AW-1:2];
      if (rd_a[1:0] == 2'(j)) bank_ra[j] = rd_a[AW-1:2];
    end
  end endgenerate

  assign b_rdata   = bank_rq[rd_a[1:0]];
  assign b_empty   = used_a == U_ZERO;
  assign b_full    = used_a == U_FULL;
  assign mid_empty = used_b == U_ZERO;
  assign w_rdata   = {used_c != U_ZERO ? bank_rq[rd_c[1:0]] : 8'h00,
                      used_c >= U_TWO ? bank_rq[rd_h[1:0]] : 8'h00};
  assign w_used    = used_c;

endmodule

`default_nettype wire
