// Field-1 vsync column, unpatched expression against the 9-bit one, every R0, R2, column.
module tb_patch_expr;
  initial begin
    int bad = 0, n = 0, z = 0;
    for (int h = 0; h < 256; h++)
      for (int p = 0; p < 256; p++) begin
        logic [7:0] reg_ht, reg_hp, hp, vsF1Col;
        logic [8:0] vsF1Sum;
        reg_ht = 8'(h); reg_hp = 8'(p);
        hp = (reg_hp ? reg_hp-8'd1 : reg_ht);
        vsF1Sum = 9'(hp) + 9'(reg_ht[7:1]) - 9'd1;
        vsF1Col = reg_ht < 8'd2 ? 8'd0 : 8'(vsF1Sum % 9'(reg_ht));
        for (int c = 0; c < 256; c++) begin
          logic [7:0] col;
          logic o, q;
          col = 8'(c);
          o = col==(hp + (reg_ht>>1) - 1) % reg_ht;
          q = col==vsF1Col;
          n++;
          if (o !== q) begin
            if (h == 0) z++;
            else begin bad++; if (bad < 10) $display("DIFF ht=%0d hp=%0d col=%0d o=%b q=%b", h, p, c, o, q); end
          end
        end
      end
    $display("checked %0d (ht,hp,col) triples: %0d differ with R0>0, %0d with R0=0", n, bad, z);
    if (bad != 0 || z != 0) $fatal(1, "FAIL");
    $display("PASS tb_patch_expr");
    $finish;
  end
endmodule
