// HR card FN#4 bitmap: sixteen M5M4416 (16K x 4) as one 16K x 64 block
// RAM; byte b of a row (bits 8b+7..8b) is the pair of chips on CAS
// strobe b (1H, 1L, 2H, 2L, 3H, 3L, 4H, 4L).  Port A is the CPU slot
// (row LA16-LA3, early write of the strobed bytes), port B the display
// fetch (row XP).  One read port serves both on alternate clks, so a_q
// and b_q each follow their row within three clks.  The ZMEMC/ZCAS
// program keeps the slots apart: the only write is at the CPU CAS edge
// (count 3), the reads are taken at -CDONE (count 6, LA held for the
// whole bus cycle) and at the fetch CAS (count 11, XP last changed at
// count 0), so neither the latency nor read-during-write shows; a
// program change that moves these must re-check it.
// The block RAM sits outside the card (m_*): write row, byte strobes and
// data, read row, and the row read at the last clk.
`default_nettype none

module hr_fn4_dram (
  input  logic        clk,
  input  logic [13:0] a_row,
  input  logic [7:0]  a_we,     // byte strobes of a CPU write
  input  logic [63:0] a_wd,
  output logic [63:0] a_q,
  input  logic [13:0] b_row,
  output logic [63:0] b_q,
  output logic [13:0] m_wrow,
  output logic [7:0]  m_we,
  output logic [63:0] m_wd,
  output logic [13:0] m_rrow,
  input  logic [63:0] m_q
);
  // Justification: read slot and the two output rows (reg-a).
  logic        sel, sel_q;
  logic [63:0] aq, bq;

  initial begin
    sel = 1'b0; sel_q = 1'b0;
    aq = '0; bq = '0;
  end
  assign m_wrow = a_row;
  assign m_we   = a_we;
  assign m_wd   = a_wd;
  assign m_rrow = sel ? b_row : a_row;
  always_ff @(posedge clk) begin
    sel   <= ~sel;
    sel_q <= sel;
    if (sel_q) bq <= m_q;
    else       aq <= m_q;
  end

  assign a_q = aq;
  assign b_q = bq;
endmodule

`default_nettype wire
