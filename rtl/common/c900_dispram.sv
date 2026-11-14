// Display-card RAM: the HR card's bitmap (sixteen M5M4416, 16K x 64) and
// the LC card's 64 KB (behind its 8568) in one block RAM.  One card is in
// the display slot at a time (lc_sel changes only in reset), and that card
// owns the array.
//
// HR side: the bitmap's ports, clk domain: byte writes, a row read one clk
// after its row.
//
// LC side: the VDC RAM pins, clk_vdc registers (same VCO as clk, rises
// coincide every 62.5 ns; STA times the paths).  The VDC sets rd or we
// with the address at the start of a column and holds the address to the
// next column.  The array takes them at every clk, so a write may land
// twice (the same byte).  The byte read one clk after a clk that saw rd is
// held until the next read, as the VDC RAM output is.  It is ready
// within 52 ns of the column start; the VDC takes it 62.5 ns or more
// after.  LC byte A is row A15:2, lane A1:0.
`default_nettype none
module c900_dispram (
  input  logic        clk,
  input  logic        lc_sel,          // the LC card owns the array
  // HR card bitmap
  input  logic [13:0] hr_wrow,
  input  logic [7:0]  hr_we,           // byte strobes
  input  logic [63:0] hr_wd,
  input  logic [13:0] hr_rrow,
  output logic [63:0] hr_q,
  // LC card 8563 RAM pins, clk_vdc domain
  input  logic        lc_rd,
  input  logic        lc_we,
  input  logic [15:0] lc_addr,
  input  logic [7:0]  lc_di,
  output logic [7:0]  lc_do
);
  logic [13:0] wrow, rrow;
  logic [7:0]  we;
  logic [63:0] wd;
  always_comb begin
    wrow = hr_wrow;
    rrow = hr_rrow;
    we   = hr_we;
    wd   = hr_wd;
    if (lc_sel) begin
      wrow = lc_addr[15:2];
      rrow = lc_addr[15:2];
      we   = {4'h0, {3'b000, lc_we} << lc_addr[1:0]};
      wd   = {8{lc_di}};
    end
  end

  // Justification: the 128 KB array and its read register (ram-a).
  (* ramstyle = "M10K, no_rw_check" *) logic [63:0] mem [16384];
  logic [63:0] q;
  initial begin
    mem = '{default: '0};
    q = '0;
  end
  always_ff @(posedge clk) begin
    for (int b = 0; b < 8; b++)
      if (we[b]) mem[wrow][8*b +: 8] <= wd[8*b +: 8];
    q <= mem[rrow];
  end
  assign hr_q = q;

  // Justification: the clk that took a read and its lane (reg-a), and the
  // 8563's held read byte (reg-a).
  logic       rd_q;
  logic [1:0] lane_q;
  logic [7:0] do_q;
  initial do_q = 8'h00;
  always_ff @(posedge clk) begin
    rd_q   <= lc_rd;
    lane_q <= lc_addr[1:0];
    if (rd_q) do_q <= q[8*lane_q +: 8];
  end
  assign lc_do = do_q;
endmodule
`default_nettype wire
