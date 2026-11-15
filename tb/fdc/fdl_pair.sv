// Two fd_layout walks of one track for tb_fdlseek: `a` seeks once and
// always has its fetches granted, `b` reseeks with delayed grants.
`default_nettype none
module fdl_pair (
  input  logic        clk, rst_n,
  input  logic [6:0]  track,
  input  logic        seek_a, seek_b,
  input  logic [16:0] pos,
  input  logic        adv,
  input  logic        gnt_a, gnt_b,
  input  logic [7:0]  rdata_a, rdata_b, ck_a, ck_b,
  output logic        rdy_a, rdy_b, req_a, req_b, lost_b,
  output logic [1:0]  bit_a, bit_b,
  output logic [13:0] raddr_a, raddr_b,
  output logic [4:0]  ckix_a, ckix_b
);
  logic na, nb, sa, sb, la;
  logic [4:0] seca, secb;
  fd_layout #(.NS(2)) u_a (.clk, .rst_n, .track, .side0(1'b0), .seek(seek_a), .pos, .adv,
    .rdy(rdy_a), .bit_q(bit_a), .req(req_a), .raddr(raddr_a), .need(na), .gnt(gnt_a),
    .rdata(rdata_a), .ck_idx(ckix_a), .ck_q(ck_a), .sec(seca), .sec_ok(sa), .lost(la));
  fd_layout #(.NS(2)) u_b (.clk, .rst_n, .track, .side0(1'b0), .seek(seek_b), .pos, .adv,
    .rdy(rdy_b), .bit_q(bit_b), .req(req_b), .raddr(raddr_b), .need(nb), .gnt(gnt_b),
    .rdata(rdata_b), .ck_idx(ckix_b), .ck_q(ck_b), .sec(secb), .sec_ok(sb), .lost(lost_b));
endmodule
