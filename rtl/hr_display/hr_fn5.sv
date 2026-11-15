// HR card FN#5 CPU data path: the read latches catch the 64-bit row when
// ZMEMC -CDONE rises on a read (all eight LS373s are transparent latches
// closed as the read completes) and drive the addressed word onto BAD
// while ZSEL -RE1/-RE2 are low; a write passes BAD straight to the DRAM
// (transparent write latches, early write).  The board glue makes
// one-master-clock pulses from -CDONE rising and the CAS strobes
// asserting.
`default_nettype none

module hr_fn5 (
  input  logic        clk,
  input  logic        cyc,
  input  logic        cdone,
  input  logic        we,
  input  logic [7:0]  cas,
  input  logic        lrw,       // high = read
  input  logic        re,
  input  logic [2:1]  la,
  input  logic [15:0] ad_in,
  input  logic [63:0] row_q,     // the CPU row from FN#4
  output logic [7:0]  dram_we,
  output logic [63:0] dram_wd,
  output logic [15:0] ad_out,
  output logic        ad_drive
);
  // Justification: last -CDONE and CAS levels, read latches (reg-a).
  logic        cdone_q;
  logic [7:0]  cas_q;
  logic [63:0] rd;

  assign dram_we = (cyc && we && cas != 8'h00 && cas_q == 8'h00) ? cas : 8'h00;
  assign dram_wd = {4{ad_in[7:0], ad_in[15:8]}};

  initial begin
    cdone_q = 1'b0; cas_q = '0; rd = '0;
  end
  always_ff @(posedge clk) begin
    cdone_q <= cdone;
    cas_q   <= cas;
    if (cyc && cdone && !cdone_q && lrw) rd <= row_q;
  end

  logic [15:0] w;
  always_comb begin
    case (la)
      2'd0: w = {rd[7:0],   rd[15:8]};
      2'd1: w = {rd[23:16], rd[31:24]};
      2'd2: w = {rd[39:32], rd[47:40]};
      default: w = {rd[55:48], rd[63:56]};
    endcase
  end
  assign ad_out   = re ? w : 16'h0000;
  assign ad_drive = re;
endmodule

`default_nettype wire
