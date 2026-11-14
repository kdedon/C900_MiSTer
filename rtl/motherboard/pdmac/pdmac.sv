// MOS 8716 PDMAC (U79, symbol U790 on motherboard sheet 18), drawing 315046.
//
// Shared lines are value + drive pairs.  `clk` is the fabric clock: one posedge
// per vector record.  The chip's CLK input (pin 47) arrives as one-clock
// edge pulses `clk_pin_rise`/`clk_pin_fall`.  LD1, LD2 and CLKADR are clock
// inputs of U81/U80/U83: each leaves as a rise/fall pulse pair, high in the
// clock where the pin first shows the new level.  `reset_n` is the /RESET
// pin (32), the only reset; registers power up at their initialisers.
// The FIFO depth of 64 is inferred from sheet 6 ("16usecs at most for a
// 64 byte deep FIFO"), not transcribed.
`default_nettype none

module pdmac (
  input  logic        clk,
  // Z-Bus side
  input  logic [15:0] ad_in,
  output logic [15:0] ad_out,
  output logic        ad_oe,
  input  logic        wait_n,
  input  logic        clk_pin_rise,
  input  logic        clk_pin_fall,
  input  logic        bai_n,
  input  logic        iack_n,
  input  logic        iei,
  input  logic        io6,
  input  logic        ds_n_in,
  output logic        mreq_n,
  output logic        mreq_oe,
  output logic        ds_n,
  output logic        ds_oe,
  output logic        busreq_n,
  output logic        bao_n,
  output logic        vi_n,
  output logic        ieo_n,
  output logic        dmaen_n,
  // controller (B bus) side
  input  logic [7:0]  bd_in,
  output logic [7:0]  bd_out,
  output logic        bd_oe,
  input  logic        pcss,
  input  logic        pcsd,
  input  logic        reset_n,
  output logic        ireq_n,
  output logic        ld0,
  output logic        ld1_rise,
  output logic        ld1_fall,
  output logic        ld2_rise,
  output logic        ld2_fall,
  output logic        clkadr_rise,
  output logic        clkadr_fall,
  output logic        est_n
);

  // Unit interconnect.
  logic       chip_rst, reset_hold, cmd_rst;
  logic       cmd_stb;
  logic [7:0] cmd;
  logic       pcsd_ld2, pcsd_ld0, pcsd_ss;
  logic       pcsd_dir;
  logic [7:0] status;
  logic       dir;
  logic       fifo_clr, fifo_hold_clr;
  logic       bd_push, bd_pop, ld0_latch;
  logic [7:0] bd_wdata, fifo_b_rdata;
  logic       fifo_b_empty, fifo_b_full, fifo_mid_empty;
  logic       fifo_w_push, fifo_w_pop;
  logic [15:0] fifo_w_wdata, fifo_w_rdata;
  logic [6:0] fifo_w_used;
  logic       blk_done, blk_commit, blk_sector;
  logic [15:0] mem_ad;
  logic        mem_ad_oe, vec_oe;

  // /RESET (pin 32): the falling edge runs the edge clears, the Low level
  // holds the FIFO, the DMA cycle and ERROR clear.
  // Justification: /RESET edge detection (reg-a).
  logic reset_n_q;
  initial begin
    reset_n_q = 1'b1;
  end
  always_ff @(posedge clk) begin
    reset_n_q <= reset_n;
  end
  assign chip_rst   = reset_n_q & ~reset_n;
  assign reset_hold = ~reset_n;

  pcss_unit u_pcss (
    .clk(clk), .chip_rst(chip_rst),
    .pcss(pcss), .pcsd(pcsd), .bd_in(bd_in),
    .dir(dir), .status(status), .fifo_rdata(fifo_b_rdata),
    .fifo_empty(fifo_b_empty), .fifo_full(fifo_b_full),
    .cmd_stb(cmd_stb), .cmd(cmd), .pcsd_ld2(pcsd_ld2), .pcsd_ld0(pcsd_ld0), .pcsd_ss(pcsd_ss),
    .ld0_latch(ld0_latch), .pcsd_dir(pcsd_dir),
    .fifo_push(bd_push), .fifo_pop(bd_pop), .fifo_wdata(bd_wdata),
    .ld0(ld0), .ld1_rise(ld1_rise), .ld1_fall(ld1_fall),
    .ld2_rise(ld2_rise), .ld2_fall(ld2_fall), .bd_out(bd_out), .bd_oe(bd_oe)
  );

  // B side on the byte port, Z side on the word port.
  fifo64 #(.DEPTH(64)) u_fifo (
    .clk(clk), .clr(fifo_clr),
    .b_push(bd_push), .b_wdata(bd_wdata), .b_pop(bd_pop), .b_rdata(fifo_b_rdata),
    .b_empty(fifo_b_empty), .b_full(fifo_b_full), .mid_empty(fifo_mid_empty),
    .hold_clr(fifo_hold_clr),
    .w_push(fifo_w_push), .w_wdata(fifo_w_wdata), .w_pop(fifo_w_pop), .w_rdata(fifo_w_rdata),
    .w_used(fifo_w_used)
  );

  dma_fsm u_dma (
    .clk(clk), .chip_rst(chip_rst), .reset_hold(reset_hold),
    .cmd_stb(cmd_stb), .cmd(cmd), .pcsd_ld2(pcsd_ld2), .pcsd_ld0(pcsd_ld0), .pcsd_ss(pcsd_ss),
    .pcsd_dir(pcsd_dir), .ld0_latch(ld0_latch), .bd_push(bd_push), .bd_pop(bd_pop),
    .clk_pin_rise(clk_pin_rise), .clk_pin_fall(clk_pin_fall),
    .bai_n(bai_n), .wait_n(wait_n), .ad_in(ad_in),
    .fifo_mid_empty(fifo_mid_empty), .fifo_w_used(fifo_w_used), .fifo_w_rdata(fifo_w_rdata),
    .fifo_clr(fifo_clr), .fifo_hold_clr(fifo_hold_clr),
    .fifo_w_push(fifo_w_push), .fifo_w_pop(fifo_w_pop), .fifo_w_wdata(fifo_w_wdata),
    .dir(dir), .status(status), .cmd_rst(cmd_rst), .blk_done(blk_done),
    .blk_commit(blk_commit), .blk_sector(blk_sector),
    .mreq_n(mreq_n), .ds_n(ds_n), .dmaen_n(dmaen_n), .busreq_n(busreq_n), .bao_n(bao_n),
    .ad_out(mem_ad), .ad_oe(mem_ad_oe), .clkadr_rise(clkadr_rise), .clkadr_fall(clkadr_fall)
  );

  int_unit u_int (
    .clk(clk), .chip_rst(chip_rst), .reset_hold(reset_hold),
    .cmd_stb(cmd_stb), .cmd(cmd), .ld0_latch(ld0_latch),
    .blk_done(blk_done), .blk_commit(blk_commit), .blk_sector(blk_sector),
    .io6(io6), .ds_n_in(ds_n_in), .iack_n(iack_n), .iei(iei), .ad_lo(ad_in[7:0]),
    .vi_n(vi_n), .ieo_n(ieo_n), .ireq_n(ireq_n), .vec_oe(vec_oe)
  );

  // /MREQ and /DS share _BMREQ/_BDS with the CPU's buffer (sheet 18):
  // driven only while /DMAEN is Low.
  assign mreq_oe = ~dmaen_n;
  assign ds_oe   = ~dmaen_n;

  // The vector wins over the write word.
  localparam logic [15:0] VECTOR = 16'h0080;
  assign ad_out = vec_oe ? VECTOR : mem_ad;
  assign ad_oe  = vec_oe | mem_ad_oe;

  est_latch u_est (
    .clk(clk), .est_set(chip_rst | cmd_rst),
    .ld0_latch(ld0_latch), .blk_done(blk_done), .est_n(est_n)
  );

endmodule

`default_nettype wire
