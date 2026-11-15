// uart_sel: for every option, the UART pins follow the selected line and
// every other line idles High; SWAP_U74 exchanges options 0 and 1.
`default_nettype none
module tb_uart_sel;
  logic       clk = 1'b0;
  logic [2:0] sel;
  logic       rxd, cts, dsr;
  logic [5:0] txd, rts_n, dtr_n;
  logic       u_txd [2], u_rts [2], u_dtr [2];
  logic [5:0] s_rxd [2], s_cts [2], s_dcd [2], s_dsr [2];
  int         errors = 0;

  always #5 clk = ~clk;

  uart_sel dut (.clk(clk), .sel(sel), .uart_rxd(rxd), .uart_cts(cts), .uart_dsr(dsr),
    .uart_txd(u_txd[0]), .uart_rts(u_rts[0]), .uart_dtr(u_dtr[0]),
    .ser_rxd(s_rxd[0]), .ser_cts_n(s_cts[0]), .ser_dcd_n(s_dcd[0]), .ser_dsr_n(s_dsr[0]),
    .ser_txd(txd), .ser_rts_n(rts_n), .ser_dtr_n(dtr_n));
  uart_sel #(.SWAP_U74(1'b1)) dut_swap (.clk(clk), .sel(sel), .uart_rxd(rxd), .uart_cts(cts), .uart_dsr(dsr),
    .uart_txd(u_txd[1]), .uart_rts(u_rts[1]), .uart_dtr(u_dtr[1]),
    .ser_rxd(s_rxd[1]), .ser_cts_n(s_cts[1]), .ser_dcd_n(s_dcd[1]), .ser_dsr_n(s_dsr[1]),
    .ser_txd(txd), .ser_rts_n(rts_n), .ser_dtr_n(dtr_n));

  // Option to line: 0 U74 A, 1 U74 B, 2..5 the LR SCCs.
  function automatic int line_of(int opt, bit swap);
    if (opt < 2) return (opt == 0) != swap ? 1 : 0;
    return opt;
  endfunction

  task automatic check(int d, int ln, string what);
    for (int l = 0; l < 6; l++) begin
      logic er = (l == ln) ? rxd : 1'b1;
      logic ec = (l == ln) ? cts : 1'b1;
      logic ed = (l == ln) ? dsr : 1'b1;
      if (s_rxd[d][l] !== er || s_cts[d][l] !== ec || s_dcd[d][l] !== ed || s_dsr[d][l] !== ed) begin
        $display("FAIL %s: line %0d in rxd %b cts %b dcd %b dsr %b", what, l,
          s_rxd[d][l], s_cts[d][l], s_dcd[d][l], s_dsr[d][l]);
        errors++;
      end
    end
    if (u_txd[d] !== txd[ln] || u_rts[d] !== rts_n[ln] || u_dtr[d] !== dtr_n[ln]) begin
      $display("FAIL %s: UART out txd %b rts %b dtr %b, line %0d", what, u_txd[d], u_rts[d], u_dtr[d], ln);
      errors++;
    end
  endtask

  initial begin
    for (int opt = 0; opt < 6; opt++) begin
      sel = 3'(opt);
      @(posedge clk); #1;
      // Every line gets each value of its own bit while the others hold the opposite.
      for (int k = 0; k < 64; k++) begin
        {rxd, cts, dsr} = 3'($urandom);
        txd = 6'($urandom); rts_n = 6'($urandom); dtr_n = 6'($urandom);
        #1;
        for (int d = 0; d < 2; d++)
          check(d, line_of(opt, d[0]), $sformatf("option %0d%s", opt, d != 0 ? " swapped" : ""));
      end
    end
    if (errors == 0) $display("tb_uart_sel: PASS");
    else $fatal(1, "tb_uart_sel: %0d errors", errors);
    $finish;
  end
endmodule
`default_nettype wire
