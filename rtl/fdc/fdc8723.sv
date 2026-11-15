// MOS 8723 Z8000 floppy disk controller (U204), drawing 315017.
//
// Ports are the chip's pins, drive side as the
// chip's real pins (spec Figure 1, sec 1.3).  `clk` is the fabric clock:
// one posedge per sample of the board's pins.  `clkin` is the 6 MHz
// CLKIN pin (37) as a one-clk pulse on each of its rising edges (only
// the rising edge is used): it steps the GCR state machine and the PH
// divider.  `ph2_rise`/`ph2_fall` are one-clk pulses on the edges of
// PH2 (the 6508's Phi2), in the clk in which a PH2 level would first
// show the new value.  `reset_n` is the RESET pin (36), the only reset;
// registers power up at their initialisers.  `cs_n` is the board's
// 0x4000-0x400F decode of A15/A14.
//
// /SO goes Low the clk after a BRDY and stays Low up to and including
// the clk of the next `ph2_rise`: the 6508 samples S.O. at the trailing
// edge of phi1, so a shorter /SO could fall between samples.  The
// drawing gives no /SO width.
//
// A bus cycle latches address and direction at the CS_n fall (reads
// drive D from then until the rise) and commits a write at the CS_n
// rise.  After each posedge the pins show the sample just taken; they
// come from registers, and D_OE, DMADIR and NWD are simple gates of
// registers.  RESET releases D (sec 1.3.1: it resets the output
// registers) but not PH2, so the PH divider's power-up phase is never
// reset: OPEN (the spec gives no power-up state; the initialiser is 0).
`default_nettype none

module fdc8723 (
  input  logic       clk,
  // 6508 side
  input  logic       clkin,
  input  logic       reset_n,
  input  logic       cs_n,
  input  logic       r_w,
  input  logic [3:0] a,
  input  logic [7:0] d_in,
  output logic [7:0] d_out,
  output logic       d_oe,
  output logic       so_n,
  output logic       ph2_rise,
  output logic       ph2_fall,
  // 8716 side (through U202)
  output logic       buffen_n,
  output logic       dmadir,
  output logic       pcss_n,
  output logic       pcsd_n,
  output logic       strobe_oe,
  // drive side
  input  logic       rdata,
  input  logic [1:0] trk0_n,
  input  logic [1:0] wrpt_n,
  output logic [1:0] mtron,
  output logic [1:0] led,
  output logic [3:0] step0,
  output logic [3:0] step1,
  output logic       hdsel,
  output logic       wrgt,
  output logic       erase,
  output logic       wd,
  output logic       nwd
);

  typedef enum logic [1:0] {HostNone, HostPcss, HostPcsdOut, HostPcsdIn} host_e;

  localparam logic [3:0] RegDrive0 = 4'h0, RegDrive1 = 4'h1, RegCtrl = 4'h2, RegPcss = 4'h3,
                         RegData = 4'h4, RegDataPcsd = 4'h5, RegPcsd = 4'h6, RegMisc = 4'h7,
                         RegTest = 4'hC;
  localparam logic [7:0] MiscRwMask = 8'hEE;   // 0x4007 bits 4 (CRC error) and 0 (BRDY) read only

  // Justification: 0x4000/0x4001/0x4002/0x4007 register contents (reg-a).
  logic [7:0] drv0_q, drv0_d, drv1_q, drv1_d, ctrl_q, ctrl_d, misc_q, misc_d;
  // Justification: BRDY (Misc S, /SO source) (reg-a).
  logic       brdy_q, brdy_d;
  // Justification: CS_n edge detection (reg-a).
  logic       cs_q;
  // Justification: strobe kind of the cycle, latched at the CS_n fall; strobe last sample (reg-a).
  host_e      host_q, host_d;
  logic       hprev_q, hprev_d;
  // Justification: read data held on D from the CS_n fall to the rise (reg-a).
  logic       live_q, live_d;
  logic [7:0] rval_q, rval_d;
  // Justification: TRK0/WRPT sampled for the next read (reg-a).
  logic [1:0] trk0_q, wrpt_q;
  // Justification: CLKIN / 4 for PH1/PH2 (reg-a).
  logic [1:0] ph_q, ph_d;
  // Justification: PH2 edge pulses, registered with ph_q (reg-d).
  logic       ph2_rise_q, ph2_fall_q;
  // Justification: registered pins; so_q also holds /SO to the PH2 rise (reg-a).
  logic       so_q, buf_q, pcss_q, pcsd_q;

  logic       pin_rst, cs_fall, cs_rise, step;
  host_e      host_fall;
  logic       rd_ok, rd_take, strobe;
  logic [7:0] rd_val;
  logic       wr_restart, wrp_set, cap;
  logic       fire, shift_ones, eng_wd;
  logic [7:0] data_byte;

  assign pin_rst = ~reset_n;
  assign cs_fall = cs_q & ~cs_n;
  assign cs_rise = ~cs_q & cs_n;
  assign step    = clkin;

  // Strobe made by a cycle at `a`: writes to 4003 (PCSS) and 4005/4006
  // (PCSD out); a 4005 read is PCSD out with the write gate off and
  // PCSD in with it on; a 4006 read is PCSD in.
  always_comb begin
    host_fall = HostNone;
    if (!r_w) begin
      if (a == RegPcss)                         host_fall = HostPcss;
      else if (a == RegPcsd || a == RegDataPcsd) host_fall = HostPcsdOut;
    end else begin
      if (a == RegDataPcsd && !ctrl_q[5])       host_fall = HostPcsdOut;
      else if (a == RegDataPcsd || a == RegPcsd) host_fall = HostPcsdIn;
    end
  end

  // Register read mux.  Drive bit 7 = write protected, bit 6 = TRK0
  // pin High (off track 0); 0x4002 bit 7 = live sync (ten ones, write
  // gate off); 0x4007 bit 0 = BRDY, bit 4 (CRC error) reads 0.
  always_comb begin
    rd_ok  = 1'b1;
    rd_val = 8'h00;
    case (a)
      RegDrive0:   rd_val = {~wrpt_q[0], trk0_q[0], drv0_q[5:0]};
      RegDrive1:   rd_val = {~wrpt_q[1], trk0_q[1], drv1_q[5:0]};
      RegCtrl:     rd_val = {shift_ones & ~ctrl_q[5], ctrl_q[6:0]};
      RegData:     rd_val = data_byte;
      RegDataPcsd: rd_val = data_byte;
      RegMisc:     rd_val = {misc_q[7:1], brdy_q};
      RegTest:     rd_val = 8'h00;
      default:     rd_ok  = 1'b0;
    endcase
  end
  assign rd_take = cs_fall & r_w & (host_fall != HostPcsdIn) & rd_ok;

  // Bus side.
  always_comb begin
    drv0_d = drv0_q;  drv1_d = drv1_q;  ctrl_d = ctrl_q;  misc_d = misc_q;
    brdy_d = brdy_q;  host_d = host_q;  live_d = live_q;  rval_d = rval_q;
    wr_restart = 1'b0;
    wrp_set    = 1'b0;
    if (cs_fall) begin
      host_d = host_fall;
      if (host_fall == HostPcsdIn && a == RegDataPcsd) brdy_d = 1'b0;
      if (rd_take) begin
        live_d = 1'b1;
        rval_d = rd_val;
        if (a == RegData || a == RegDataPcsd) brdy_d = 1'b0;
      end
    end
    if (cs_rise) begin
      live_d = 1'b0;
      if (!r_w) begin
        case (a)
          RegDrive0: drv0_d = d_in;
          RegDrive1: drv1_d = d_in;
          RegCtrl: begin
            ctrl_d     = d_in;
            wr_restart = d_in[5] & ~ctrl_q[5];
          end
          RegData, RegDataPcsd: begin
            wrp_set = ctrl_q[5] | ctrl_q[7];
            brdy_d  = 1'b0;
          end
          RegMisc: misc_d = d_in & MiscRwMask;
          default: ;
        endcase
      end
    end
    if (fire) brdy_d = 1'b1;
    if (pin_rst) begin
      drv0_d = 8'h00;  drv1_d = 8'h00;  ctrl_d = 8'h00;  misc_d = 8'h00;
      brdy_d = 1'b0;   host_d = HostNone;
      live_d = 1'b0;   rval_d = rval_q;
    end
  end

  assign strobe  = ~cs_n & (host_d != HostNone) & ctrl_d[2];
  assign hprev_d = pin_rst ? 1'b0 : strobe;

  // The PH divider keeps running through RESET (spec sec 1.3.1).
  assign ph_d = step ? ph_q + 2'd1 : ph_q;

  // CMD_WRITE (fw e373-e380): on a 0x4005 PCSD-in cycle the 8716's
  // byte on D enters the write shifter at the PH2 fall.
  assign cap = ~pin_rst & ph_q[1] & ~ph_d[1] & ~cs_n & (host_d == HostPcsdIn) & (a == RegDataPcsd);

  gcr_engine u_gcr (
    .clk(clk), .pin_rst(pin_rst), .step(step & ~pin_rst),
    .rdata(rdata), .gg(ctrl_d[1:0]), .wg(ctrl_d[5]), .syncgen(ctrl_d[7]),
    .wr_restart(wr_restart), .wrp_set(wrp_set), .wrp_val(d_in),
    .cap(cap), .cap_val(d_in),
    .fire(fire), .data_byte(data_byte), .shift_ones(shift_ones), .wd(eng_wd)
  );

  // Registers 0x4000-0x4002, 0x4007 and BRDY.
  initial begin
    drv0_q = 8'h00;  drv1_q = 8'h00;  ctrl_q = 8'h00;  misc_q = 8'h00;  brdy_q = 1'b0;
  end
  always_ff @(posedge clk) begin
    drv0_q <= drv0_d;  drv1_q <= drv1_d;  ctrl_q <= ctrl_d;  misc_q <= misc_d;  brdy_q <= brdy_d;
  end

  // Bus cycle: strobe kind, read data hold.
  initial begin
    host_q = HostNone;  hprev_q = 1'b0;  live_q = 1'b0;  rval_q = 8'h00;
  end
  always_ff @(posedge clk) begin
    host_q <= host_d;    hprev_q <= hprev_d; live_q <= live_d; rval_q <= rval_d;
  end

  // CS_n sampler and the PH divider.
  initial begin
    cs_q = 1'b1;  ph_q = 2'd0;  ph2_rise_q = 1'b0;  ph2_fall_q = 1'b0;
  end
  always_ff @(posedge clk) begin
    cs_q <= cs_n;  ph_q <= ph_d;  ph2_rise_q <= ph_d[1] & ~ph_q[1];  ph2_fall_q <= ~ph_d[1] & ph_q[1];
  end

  initial begin
    trk0_q = 2'b00;  wrpt_q = 2'b00;
  end
  always_ff @(posedge clk) begin
    if (!pin_rst) begin
      trk0_q <= trk0_n; wrpt_q <= wrpt_n;
    end
  end

  // Strobe pins.
  initial begin
    so_q = 1'b1;  buf_q = 1'b1;  pcss_q = 1'b1;  pcsd_q = 1'b1;
  end
  always_ff @(posedge clk) begin
    so_q   <= pin_rst | (~fire & (so_q | ph2_rise_q));
    buf_q  <= pin_rst | ~(strobe | hprev_q);
    pcss_q <= pin_rst | ~(strobe & host_d == HostPcss);
    pcsd_q <= pin_rst | ~(strobe & (host_d == HostPcsdOut || host_d == HostPcsdIn));
  end

  // Pins.  /RESET Low forces the idle levels (registered: pin_rst_q).
  // Justification: RESET sampled for the registered pin levels (reg-d).
  logic pin_rst_q;
  initial begin
    pin_rst_q = 1'b0;
  end
  always_ff @(posedge clk) begin
    pin_rst_q <= pin_rst;
  end

  assign so_n      = so_q;
  assign ph2_rise  = ph2_rise_q;
  assign ph2_fall  = ph2_fall_q;
  assign d_out     = rval_q;
  assign d_oe      = live_q & ~pin_rst_q;
  assign buffen_n  = buf_q;
  assign pcss_n    = pcss_q;
  assign pcsd_n    = pcsd_q;
  assign strobe_oe = ctrl_q[2];
  assign dmadir    = ~pin_rst_q & (host_q == HostPcsdIn);
  assign mtron     = {drv1_q[5], drv0_q[5]};
  assign led       = {drv1_q[4], drv0_q[4]};
  assign step0     = drv0_q[3:0];
  assign step1     = drv1_q[3:0];
  assign hdsel     = ctrl_q[3];
  assign wrgt      = ctrl_q[5];
  assign erase     = ctrl_q[4];
  assign wd        = eng_wd;
  assign nwd       = ~eng_wd;

endmodule

`default_nettype wire
