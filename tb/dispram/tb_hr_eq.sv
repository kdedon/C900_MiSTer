// HR bitmap through the shared display RAM against the card's own block
// RAM (hr_fn4_old, the bitmap before it moved out): random CPU writes and
// both read slots every clk, rows in a small window so reads meet writes;
// a_q and b_q compared every clk.
`timescale 1ns/1ps
module tb_hr_eq;
  logic clk = 1'b0;
  always #10.4167 clk = ~clk;

  logic [13:0] a_row = '0, b_row = '0;
  logic [7:0]  a_we = '0;
  logic [63:0] a_wd = '0;
  logic [63:0] aq_o, bq_o, aq_n, bq_n;

  hr_fn4_old u_old (.clk, .a_row, .a_we, .a_wd, .a_q(aq_o), .b_row, .b_q(bq_o));

  logic [13:0] m_wrow, m_rrow;
  logic [7:0]  m_we;
  logic [63:0] m_wd, m_q;
  hr_fn4_dram u_new (.clk, .a_row, .a_we, .a_wd, .a_q(aq_n), .b_row, .b_q(bq_n),
    .m_wrow, .m_we, .m_wd, .m_rrow, .m_q);
  logic [7:0] lc_do;
  c900_dispram u_ram (.clk, .lc_sel(1'b0),
    .hr_wrow(m_wrow), .hr_we(m_we), .hr_wd(m_wd), .hr_rrow(m_rrow), .hr_q(m_q),
    .lc_rd(1'b1), .lc_we(1'b1), .lc_addr(16'h1234), .lc_di(8'h5A), .lc_do(lc_do));

  longint cyc = 0, diffs = 0, writes = 0;
  int unsigned mask;
  initial begin
    for (int k = 0; k < 4; k++) begin
      mask = k == 0 ? 32'h7 : k == 1 ? 32'h3F : k == 2 ? 32'h3FF : 32'h3FFF;
      repeat (250000) begin
        @(negedge clk);
        a_row = 14'($urandom & mask);
        b_row = 14'($urandom & mask);
        a_we  = ($urandom % 3 == 0) ? 8'($urandom) : 8'h00;
        a_wd  = {$urandom, $urandom};
        if (a_we != 0) writes++;
      end
    end
    $display("RESULT cyc %0d writes %0d diffs %0d", cyc, writes, diffs);
    if (diffs != 0) $fatal(1, "FAIL tb_hr_eq: %0d clocks differ", diffs);
    $display("PASS tb_hr_eq");
    $finish;
  end
  always @(posedge clk) begin
    cyc <= cyc + 1;
    if ({aq_o, bq_o} !== {aq_n, bq_n}) begin
      if (diffs < 10) $display("DIFF cyc %0d a %h/%h b %h/%h", cyc, aq_o, aq_n, bq_o, bq_n);
      diffs <= diffs + 1;
    end
  end
endmodule
