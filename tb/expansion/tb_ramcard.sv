// c900_ramcard: every segment, every size and no card, with the strobe
// terms of a CPU word read, a byte write, a refresh and an idle bus.  The
// map is counted out (from 18 up, less 37, 3E, 3F and FF, until 31, 64,
// 128 or 256 segments); 15M also against the Go card's 16M decode
// (ramcard_sel.txt, made by ramcard_sel.go.txt).
`default_nettype none
module tb_ramcard;
  logic [2:0] size;
  logic [7:0] seg;
  logic       a0, ras_timing, ras_enable, cas_timing, cas13, ras14;
  logic       ras_n, casl_n, cash_n;

  c900_ramcard dut (.size, .a23_16(seg), .a0, .ras_timing, .ras_enable, .cas_timing,
    .cas13, .ras14, .ras_n, .casl_n, .cash_n);

  int fd, n, s, g3, g16, errors, checks;
  logic want [0:7][0:255];
  logic go16 [0:255];

  task automatic check(input string what, input logic got, input logic exp);
    checks++;
    if (got !== exp) begin
      errors++;
      if (errors < 20) $display("FAIL %s size=%0d seg=%02x got=%b want=%b", what, size, seg, got, exp);
    end
  endtask

  initial begin
    errors = 0; checks = 0;
    fd = $fopen("ramcard_sel.txt", "r");
    if (fd == 0) $fatal(1, "no ramcard_sel.txt");
    for (int i = 0; i < 256; i++) begin
      n = $fscanf(fd, "%h %d %d\n", s, g3, g16);
      if (n != 3 || s != i) $fatal(1, "bad vector line %0d", i);
      go16[i] = g16[0];
    end
    $fclose(fd);
    for (int z = 0; z < 8; z++) begin
      n = z == 1 ? 31 : (z >= 2 && z <= 4) ? 16 << z : 0;
      for (int i = 0; i < 256; i++) begin
        want[z][i] = n > 0 && i >= 'h18 && i != 'h37 && i != 'h3E && i != 'h3F && i != 'hFF;
        if (want[z][i]) n--;
      end
    end
    for (int i = 0; i < 256; i++)
      if (go16[i] !== want[4][i]) $fatal(1, "15M map differs from the Go 16M decode at %02x", i);
    for (int z = 0; z < 8; z++) begin
      size = z[2:0];
      for (int i = 0; i < 256; i++) begin
        seg = i[7:0];
        // word read: /MREQ Low, no refresh, MMU on, CAS timing Low
        {ras_enable, ras_timing, ras14, cas13, cas_timing, a0} = 6'b0_1_1_0_0_0;
        #1;
        check("read ras", ras_n, ~want[z][i]);
        check("read casl", casl_n, ~want[z][i]);
        check("read cash", cash_n, ~want[z][i]);
        // byte write to an odd address: low lane only
        {cas_timing, a0} = 2'b1_1;
        #1;
        check("byte casl", casl_n, ~want[z][i]);
        check("byte cash", cash_n, 1'b1);
        // column strobe timing High (/SUP or before /DS): no column strobe
        cas13 = 1'b1;
        #1;
        check("sup casl", casl_n, 1'b1);
        check("sup cash", cash_n, 1'b1);
        // refresh: row strobe on a fitted card whatever the segment
        {ras_timing, cas13} = 2'b0_1;
        #1;
        check("refresh ras", ras_n, z == 0 || z > 4);
        // idle bus
        ras_enable = 1'b1;
        #1;
        check("idle ras", ras_n, 1'b1);
      end
    end
    if (errors) $fatal(1, "tb_ramcard FAIL: %0d of %0d checks", errors, checks);
    $display("tb_ramcard PASS: %0d checks (segments: 2M %0d, 4M %0d, 8M %0d, 15M %0d)", checks,
             count(1), count(2), count(3), count(4));
    $finish;
  end

  function automatic int count(input int z);
    int c = 0;
    for (int i = 0; i < 256; i++) c += want[z][i];
    return c;
  endfunction
endmodule
`default_nettype wire
