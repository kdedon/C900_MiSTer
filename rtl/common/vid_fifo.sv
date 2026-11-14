// Video pins from a card clock into clk_vid: a 16-entry dual-clock FIFO.
// Gray pointers cross one bit per c900_sync2; full is decided in the write
// domain, fill in the read domain.  Reading starts at half full and takes
// one entry every fourth clk_vid (ph == 3); it stops if the FIFO runs dry.
// cur holds the entry shown, cur_ok that it was popped this period.
`default_nettype none

module vid_fifo #(
  parameter int W = 9
) (
  input  logic         clk_src,
  input  logic         push,
  input  logic [W-1:0] word,
  input  logic         clk_vid,
  output logic [1:0]   ph = '0,
  output logic [W-1:0] cur = '0,
  output logic         cur_ok = 1'b0
);
  localparam int AW = 4;
  localparam logic [AW:0] HALF = 5'd8;

  // Justification: FIFO storage and pointers (reg-a, reg-c).
  (* ramstyle = "MLAB, no_rw_check" *) logic [W-1:0] mem [2**AW];
  logic [AW:0] wbin = '0, wgray = '0, rbin = '0, rgray = '0;
  logic [AW:0] rgray_s, wgray_s;

  genvar gi;
  generate for (gi = 0; gi <= AW; gi++) begin : g_sync
    c900_sync2 u_r (.clk(clk_src), .d(rgray[gi]), .q(rgray_s[gi]));
    c900_sync2 u_w (.clk(clk_vid), .d(wgray[gi]), .q(wgray_s[gi]));
  end endgenerate

  logic        full;
  logic [AW:0] wbin_n;
  assign full   = wgray == {~rgray_s[AW:AW-1], rgray_s[AW-2:0]};
  assign wbin_n = wbin + 1'b1;
  always_ff @(posedge clk_src) begin
    if (push && !full) begin
      mem[wbin[AW-1:0]] <= word;
      wbin  <= wbin_n;
      wgray <= wbin_n ^ (wbin_n >> 1);
    end
  end

  function automatic logic [AW:0] gray2bin(input logic [AW:0] gr);
    for (int i = AW; i >= 0; i--) gray2bin[i] = ^(gr >> i);
  endfunction

  logic [AW:0] fill, rbin_n;
  assign fill   = gray2bin(wgray_s) - rbin;
  assign rbin_n = rbin + 1'b1;

  // Justification: phase in the source period, running flag (reg-a).
  logic run = 1'b0;
  logic pop;
  assign pop = (ph == 2'd3) && run && (fill != '0);

  always_ff @(posedge clk_vid) begin
    ph <= ph + 2'd1;
    if (ph == 2'd3) begin
      if (!run) run <= fill >= HALF;
      else if (fill == '0) run <= 1'b0;
      cur_ok <= pop;
    end
    if (pop) begin
      cur   <= mem[rbin[AW-1:0]];
      rbin  <= rbin_n;
      rgray <= rbin_n ^ (rbin_n >> 1);
    end
  end
endmodule

`default_nettype wire
