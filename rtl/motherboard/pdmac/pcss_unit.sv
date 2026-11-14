// 8716 controller interface: /PCSS command latch, /PCSD dispatch, LD0-LD2
// and the B-bus driver (sheets 4, 7).
//
// PCSS and PCSD are fabric-domain levels; edges are taken against their
// registered copies.  One posedge applies, in order: the /RESET falling
// edge (chip_rst), the PCSS assertion edge, then the PCSD edges.  State
// registers update on the posedge; the pins are decoded from them, so a
// strobe edge shows on LD/BD in the same sample.
//
// Two command registers: last_cmd selects what the next PCSD does and is
// consumed by the LD2/LD1/LD0/SS/status PCSD; pcss_state persists and
// selects the BD drive.  0xFF touches neither, nor the LD lines.
//
// The pcsd_* strobes and the FIFO access are combinational for this
// sample; `dir` and `status` come back combinationally from dma_fsm with
// this sample's effects applied.
//
// Bytes the chip drives (status, a DIR=read FIFO byte) go out at the PCSD
// assertion edge (sheet 7).  Bytes it takes from BD -- the LD2 direction
// and a DIR=write FIFO byte -- are taken at the release edge, from the
// last asserted sample: sheet 7, DIR is BD7 at the LD2 rise and LD2 rises
// with /PCSD; sheet 10, /BDCLKIN latches BD at the CREQ rise; sheet 16
// Table I T6/T7 and T10/T11.
`default_nettype none

module pcss_unit (
  input  logic       clk,
  input  logic       chip_rst,
  input  logic       pcss,
  input  logic       pcsd,
  input  logic [7:0] bd_in,
  input  logic       dir,
  input  logic [7:0] status,
  input  logic [7:0] fifo_rdata,
  input  logic       fifo_empty,
  input  logic       fifo_full,
  output logic       cmd_stb,
  output logic [7:0] cmd,
  output logic       pcsd_ld2,
  output logic       pcsd_ld0,
  output logic       pcsd_ss,
  output logic       ld0_latch,
  output logic       pcsd_dir,
  output logic       fifo_push,
  output logic       fifo_pop,
  output logic [7:0] fifo_wdata,
  output logic       ld0,
  output logic       ld1_rise,
  output logic       ld1_fall,
  output logic       ld2_rise,
  output logic       ld2_fall,
  output logic [7:0] bd_out,
  output logic       bd_oe
);

  localparam logic [7:0] CMD_POWERON = 8'hFF, CMD_RESET = 8'h7F, CMD_LD2 = 8'hFB,
                         CMD_LD1 = 8'hFD, CMD_LD0 = 8'hFE, CMD_MOVE = 8'hF7,
                         CMD_STATUS = 8'hEF, CMD_IRQHI = 8'h9F, CMD_VI = 8'hBF,
                         CMD_SS = 8'hDE;
  localparam logic       DIR_READ = 1'b1;

  // Justification: strobe edge detection (reg-a).
  logic       pcss_q, pcsd_q;
  // Justification: command state across strobes (reg-a).
  logic [7:0] last_cmd_q, last_cmd_d;
  logic [7:0] pcss_state_q, pcss_state_d;
  // Justification: LD lines held Low from PCSS to the PCSD release (reg-a).
  logic [2:0] ld_low_q, ld_low_d;
  // Justification: LD1/LD2 Low-state of the previous sample, for the edge pulses (reg-a).
  logic [2:1] ld_low_prev_q;
  // Justification: BD byte held while PCSD stays asserted (reg-a).
  logic [7:0] bd_hold_q, bd_hold_d;
  logic       bd_oe_q, bd_oe_d;
  // Justification: BD at the last PCSD-asserted sample, and which taking
  // PCSD is in progress, for the release-edge effects (reg-a).
  logic [7:0] bd_last_q;
  logic       take_ld2_q, take_push_q;

  logic       pcss_rise, pcsd_rise, pcsd_fall, is_ss;
  logic [7:0] cmd_norm, sel;
  logic [2:0] ld_pcss;

  assign pcss_rise = pcss & ~pcss_q;
  assign pcsd_rise = pcsd & ~pcsd_q;
  assign pcsd_fall = ~pcsd & pcsd_q;
  assign is_ss     = (bd_in[7:1] == CMD_SS[7:1]);
  assign cmd_norm  = is_ss ? CMD_SS : bd_in;

  assign cmd_stb   = pcss_rise;
  assign cmd       = bd_in;
  assign pcsd_dir  = bd_last_q[7];

  // Command latch after this sample's /RESET edge and PCSS edge: `sel` is
  // what the PCSD dispatches on.
  always_comb begin
    sel          = chip_rst ? 8'h00 : last_cmd_q;
    pcss_state_d = chip_rst ? 8'h00 : pcss_state_q;
    ld_pcss      = chip_rst ? 3'b000 : ld_low_q;
    if (pcss_rise && bd_in != CMD_POWERON) begin
      pcss_state_d = cmd_norm;
      ld_pcss      = {bd_in == CMD_LD2, bd_in == CMD_LD1, bd_in == CMD_LD0 || is_ss};
      unique case (bd_in)
        CMD_RESET:         sel = 8'h00;
        CMD_IRQHI, CMD_VI: ;
        default:           sel = cmd_norm;
      endcase
    end
  end

  // The LD2/LD1/LD0/SS/status PCSD consumes last_cmd; the release edge
  // raises the LD lines.
  always_comb begin
    last_cmd_d = sel;
    if (pcsd_rise) begin
      unique case (sel)
        CMD_LD2, CMD_LD1, CMD_LD0, CMD_SS, CMD_STATUS: last_cmd_d = 8'h00;
        default: ;
      endcase
    end
  end

  assign ld_low_d = pcsd_fall ? 3'b000 : ld_pcss;

  assign pcsd_ld2   = pcsd_fall && take_ld2_q && !chip_rst;
  assign pcsd_ld0   = pcsd_rise && sel == CMD_LD0;
  assign pcsd_ss    = pcsd_rise && sel == CMD_SS;
  assign ld0_latch  = pcss_rise && (bd_in == CMD_LD0 || is_ss);
  assign fifo_pop   = pcsd_rise && sel == CMD_MOVE && dir == DIR_READ && !fifo_empty;
  assign fifo_push  = pcsd_fall && take_push_q && !fifo_full && !chip_rst;
  assign fifo_wdata = bd_last_q;

  // BD capture at the PCSD assertion edge; released at the PCSD release.
  always_comb begin
    bd_hold_d = bd_hold_q;
    bd_oe_d   = chip_rst ? 1'b0 : bd_oe_q;
    if (pcsd_rise) begin
      if (sel == CMD_MOVE && dir == DIR_READ) bd_hold_d = fifo_empty ? 8'hFF : fifo_rdata;
      else                                    bd_hold_d = status;
      bd_oe_d = pcss_state_d == CMD_STATUS || (pcss_state_d == CMD_MOVE && dir == DIR_READ);
    end
    if (pcsd_fall) bd_oe_d = 1'b0;
  end

  initial begin
    pcss_q       = 1'b0;
    pcsd_q       = 1'b0;
    last_cmd_q   = 8'h00;
    pcss_state_q = 8'h00;
    ld_low_q     = 3'b000;
    ld_low_prev_q = 2'b00;
    bd_hold_q    = 8'h00;
    bd_oe_q      = 1'b0;
    bd_last_q    = 8'h00;
    take_ld2_q   = 1'b0;
    take_push_q  = 1'b0;
  end
  always_ff @(posedge clk) begin
    pcss_q       <= pcss;
    pcsd_q       <= pcsd;
    last_cmd_q   <= last_cmd_d;
    pcss_state_q <= pcss_state_d;
    ld_low_q     <= ld_low_d;
    ld_low_prev_q <= ld_low_q[2:1];
    bd_hold_q    <= bd_hold_d;
    bd_oe_q      <= bd_oe_d;
    if (pcsd) bd_last_q <= bd_in;
    if (chip_rst || pcsd_fall) begin
      take_ld2_q  <= 1'b0;
      take_push_q <= 1'b0;
    end else if (pcsd_rise) begin
      take_ld2_q  <= sel == CMD_LD2;
      take_push_q <= sel == CMD_MOVE && dir != DIR_READ;
    end
  end

  assign ld0      = ~ld_low_q[0];
  assign ld1_rise = ~ld_low_q[1] &  ld_low_prev_q[1];
  assign ld1_fall =  ld_low_q[1] & ~ld_low_prev_q[1];
  assign ld2_rise = ~ld_low_q[2] &  ld_low_prev_q[2];
  assign ld2_fall =  ld_low_q[2] & ~ld_low_prev_q[2];
  assign bd_out = bd_hold_q;
  assign bd_oe  = bd_oe_q;

endmodule

`default_nettype wire
