// Single-step pin monitor for tb_core: bound into tb_core, logs one line per
// event with the Z8001 clock count.  Enabled by +ssmon.
//   IF1  first-word instruction fetch (at /AS falling)
//   ABORT the last IF1 ended with no /DS (the fetch that opens an interrupt)
//   IO   I/O access in the 0x2xx page (at /DS rising): address, read or write
//   STEP U64 output edge
//   NVI  _NVI pin edge
//   ACK  NVI acknowledge cycle
module ssmon (
  input logic        clk,
  input logic        rst_n,
  input longint      zcyc,
  input logic        as_n,
  input logic        ds_n,
  input logic [3:0]  st,
  input logic [15:0] adr,
  input logic        io2_n,
  input logic        r_w,
  input logic        step,
  input logic        nvi_n,
  input logic [4:0]  dbg
);
  logic as_q, ds_q, step_q, nvi_q;
  logic [3:0]  st_q;
  logic [15:0] adr_q;
  logic        rw_q, io2_q, if1_open;
  logic on;
  initial on = $test$plusargs("ssmon");
  initial begin as_q = 1'b1; ds_q = 1'b1; step_q = 1'b0; nvi_q = 1'b1; if1_open = 1'b0; end

  always_ff @(posedge clk) if (rst_n && on) begin
    as_q <= as_n;
    ds_q <= ds_n;
    step_q <= step;
    nvi_q  <= nvi_n;
    if (!ds_n) begin rw_q <= r_w; io2_q <= io2_n; adr_q <= adr; end
    if (as_q && !as_n) begin
      if (if1_open) $display("SS %0d ABORT", zcyc);
      if1_open <= st == 4'b1101;
      if (st == 4'b1101) $display("SS %0d IF1", zcyc);
    end else if (ds_q && !ds_n) if1_open <= 1'b0;
    if (!as_q && as_n && st == 4'b0110) $display("SS %0d ACK", zcyc);
    if (!ds_q && ds_n && !io2_q) $display("SS %0d IO %04h %s", zcyc, adr_q, rw_q ? "R" : "W");
    if (step != step_q) $display("SS %0d STEP %0d", zcyc, step);
    if ($test$plusargs("ssdbg") && zcyc > 175 && zcyc < 200) $display("D %0d as=%b st=%b ck=%b nclk=%b q1=%b q2=%b step=%b", zcyc, as_n, st, dbg[4], dbg[3], dbg[2], dbg[1], dbg[0]);
    if (nvi_n != nvi_q) $display("SS %0d NVI %0d", zcyc, nvi_n);
  end
endmodule

bind tb_core ssmon u_ssmon (
  .clk(clk), .rst_n(rst_n), .zcyc(zcyc),
  .as_n(u_core.as_n), .ds_n(u_core.ds_n), .st(u_core.st), .adr(u_core.u_mb.adr),
  .io2_n(u_core.u_mb.io_n[2]), .r_w(u_core.r_w),
  .step(u_core.u_mb.ss_step), .nvi_n(u_core.u_mb.nvi_n),
  .dbg({u_core.u_mb.u_syslatch.ck, u_core.u_mb.u_syslatch.nvi_clk, u_core.u_mb.u_syslatch.q1_q, u_core.u_mb.u_syslatch.q2_q, u_core.u_mb.u_syslatch.step_q})
);
