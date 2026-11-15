// MOS 6500/1 on-chip resources around the T65 core: 64 B RAM with the
// page-1 stack folded onto it, the 2 KB mask
// ROM at 0x800-0xFFF (image on rom_q), four open-drain ports PA..PD, the
// 16-bit counter/latch with its four modes, PA0 rising / PA1 falling edge
// detects, and the IRQ from the control register.  12-bit internal decode.
//
// clk is the master clock; en marks the Phase 2 step (one per CPU cycle,
// the edge at which the T65 takes DI).  At each step the cycle the CPU
// addressed is applied (a write, or a read's side effect: reading LC
// clears CTRO), then the counter steps and the PA edge detects sample;
// IRQ for that edge is the result.
`default_nettype none
module mos6500_1_io (
  input  logic        clk,
  input  logic        en,           // Phase 2 step
  input  logic        rst_n,        // RES as taken at the step
  input  logic [15:0] addr,
  input  logic        rw_n,
  input  logic [7:0]  d_in,         // CPU write data
  output logic [7:0]  d_out,        // CPU read data
  output logic [10:0] rom_addr,
  input  logic [7:0]  rom_q,
  output logic        irq_n,
  input  logic        cntr_in,      // CNTR pin level
  output logic        cntr_out,
  input  logic [7:0]  pa_in,        // external pin levels (1 = released)
  input  logic [7:0]  pb_in,
  input  logic [7:0]  pc_in,
  input  logic [7:0]  pd_in,
  output logic [7:0]  pa_out,       // port latches: 0 pulls the pin Low
  output logic [7:0]  pb_out,
  output logic [7:0]  pc_out,
  output logic [7:0]  pd_out
);
  localparam logic [11:0] A_PA = 12'h080, A_PB = 12'h081, A_PC = 12'h082, A_PD = 12'h083;
  localparam logic [11:0] A_UL = 12'h084, A_LL = 12'h085, A_UC = 12'h086, A_LC = 12'h087;
  localparam logic [11:0] A_XFR = 12'h088, A_CA0 = 12'h089, A_CA1 = 12'h08A, A_CR = 12'h08F;

  localparam int CR_A1IE = 2, CR_A0IE = 3, CR_CIE = 4, CR_A1ED = 5, CR_A0ED = 6, CR_CTRO = 7;

  // Internal address: 12 bits, with page 1 (the stack) folded onto the RAM.
  logic [11:0] a;
  always_comb begin
    a = addr[11:0];
    if (a[11:8] == 4'h1) a = {6'h00, a[5:0]};
  end
  assign rom_addr = a[10:0];

  // On-chip RAM: read registered every master clock (the address is held
  // for the whole Phase 2 cycle, many master clocks), so it fits LUT RAM.
  (* ramstyle = "no_rw_check, mlab" *) logic [7:0] ram [0:63];
  logic [7:0]  ram_q;
  logic [7:0]  port_q [0:3];
  logic [15:0] latch_q, cnt_q;
  logic [7:0]  cr_q;
  logic        cntr_in_q, cntr_out_q, pa0_q, pa1_q;

  logic [7:0] pin_lvl [0:3];
  assign pin_lvl[0] = port_q[0] & pa_in;
  assign pin_lvl[1] = port_q[1] & pb_in;
  assign pin_lvl[2] = port_q[2] & pc_in;
  assign pin_lvl[3] = port_q[3] & pd_in;

  // Read data for the addressed cycle.
  always_comb begin
    d_out = 8'hFF;
    if (a[11])                          d_out = rom_q;
    else if (a[11:6] == 6'h00)          d_out = ram_q;
    else unique case (a)
      A_PA, A_PB, A_PC, A_PD: d_out = pin_lvl[a[1:0]];
      A_UC:                   d_out = cnt_q[15:8];
      A_LC:                   d_out = cnt_q[7:0];
      A_CR:                   d_out = cr_q;
      default:                d_out = 8'hFF;
    endcase
  end

  // The addressed cycle applied to the registers.
  logic        wr;
  logic [7:0]  cr_a;
  logic [15:0] latch_a, cnt_a;
  assign wr = ~rw_n;
  always_comb begin
    cr_a    = cr_q;
    latch_a = latch_q;
    cnt_a   = cnt_q;
    if (rw_n) begin
      if (a == A_LC) cr_a[CR_CTRO] = 1'b0;
    end else begin
      unique case (a)
        A_UL:  latch_a[15:8] = d_in;
        A_LL:  latch_a[7:0]  = d_in;
        A_XFR: begin
          latch_a[15:8]  = d_in;
          cnt_a          = {d_in, latch_q[7:0]};
          cr_a[CR_CTRO]  = 1'b0;
        end
        A_CA0: cr_a[CR_A0ED] = 1'b0;
        A_CA1: cr_a[CR_A1ED] = 1'b0;
        A_CR:  cr_a[4:0] = d_in[4:0];
        default: ;
      endcase
    end
  end

  // Counter step: modes 0 and 1 every cycle, mode 3 while CNTR is Low,
  // mode 2 on a CNTR rising edge.  Underflow (a step from 0) reloads the
  // latch, sets CTRO and, in mode 1, toggles the CNTR output.
  logic        step, uflow;
  logic [7:0]  cr_d;
  logic [15:0] cnt_d;
  logic [1:0]  pa_lvl_d;
  always_comb begin
    unique case (cr_a[1:0])
      2'd0, 2'd1: step = 1'b1;
      2'd2:       step = cntr_in & ~cntr_in_q;
      default:    step = ~cntr_in;
    endcase
    uflow = step && (cnt_a == 16'h0000);
    cnt_d = cnt_a;
    cr_d  = cr_a;
    if (step) cnt_d = uflow ? latch_a : cnt_a - 16'd1;
    if (uflow) cr_d[CR_CTRO] = 1'b1;
    // PA edge detects on the pin level after this cycle's port write.
    pa_lvl_d = ((wr && a == A_PA) ? d_in[1:0] : port_q[0][1:0]) & pa_in[1:0];
    if (!pa0_q && pa_lvl_d[0]) cr_d[CR_A0ED] = 1'b1;
    if (pa1_q && !pa_lvl_d[1]) cr_d[CR_A1ED] = 1'b1;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      port_q[0]  <= 8'hFF;
      port_q[1]  <= 8'hFF;
      port_q[2]  <= 8'hFF;
      port_q[3]  <= 8'hFF;
      cr_q       <= 8'h00;
      cntr_out_q <= 1'b1;
      cntr_in_q  <= 1'b0;
      pa0_q      <= 1'b1;
      pa1_q      <= 1'b1;
    end else if (en) begin
      if (wr && a[11:2] == A_PA[11:2]) port_q[a[1:0]] <= d_in;
      cr_q      <= cr_d;
      cntr_in_q <= cntr_in;
      if (uflow && cr_a[1:0] == 2'd1) cntr_out_q <= ~cntr_out_q;
      pa0_q     <= pa_lvl_d[0];
      pa1_q     <= pa_lvl_d[1];
    end
  end

  // Reset leaves the latch and counter as they were.
  always_ff @(posedge clk) begin
    if (en) begin
      latch_q <= latch_a;
      cnt_q   <= cnt_d;
    end
  end

  always_ff @(posedge clk) begin
    if (en && wr && a[11:6] == 6'h00) ram[a[5:0]] <= d_in;
    ram_q <= ram[a[5:0]];
  end

  // IRQ as of this edge: each status bit with its enable four places lower.
  assign irq_n = ~|(cr_d[7:5] & {cr_d[CR_CIE], cr_d[CR_A0IE], cr_d[CR_A1IE]});

  assign cntr_out = cntr_out_q;
  assign pa_out   = port_q[0];
  assign pb_out   = port_q[1];
  assign pc_out   = port_q[2];
  assign pd_out   = port_q[3];

  logic unused_ok;
  assign unused_ok = &{1'b0, addr[15:12]};
endmodule
`default_nettype wire
