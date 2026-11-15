// C900 keyboard: a MOS 6500/1 (2 MHz crystal on XTLI, 2 KB mask ROM)
// scanning the 13x8 key matrix, bit-banging each
// XT scancode over the cable: CLK = PA7, DATA = PA6.
//
// Matrix (the firmware's scan at 0x09E3): PB and PC0-PC4 drive 13 columns
// (one bit Low at a time), PD senses 8 rows; a pressed key pulls its row
// Low while its column is driven.  keys[8*col + row] is the key at column
// col (PB0..PB7 = 0..7, PC0..PC4 = 8..12) and row row (PD0..PD7); the
// firmware's scancode table at 0x0F8C is indexed the same way.  The
// modifier keys are separate inputs, Low when pressed: LShift PA2,
// CapsLock PA4, RShift PA5, Ctrl PC6, LAlt PC7.  PA0 and PA1 read the
// cable's CLK and DATA lines back through 7407 buffers.
`default_nettype none
module c900_keyboard (
  input  logic         clk,          // master clock
  input  logic         rst_n,        // 6500/1 RES
  input  logic         xtli,         // XTLI rises now (2 MHz keyboard crystal)
  // ROM loader
  input  logic         rom_we,
  input  logic [10:0]  rom_addr,
  input  logic [7:0]   rom_data,
  // keys: matrix and the modifier inputs ([0] LShift, [1] CapsLock,
  // [2] RShift, [3] Ctrl, [4] LAlt); 1 = pressed
  input  logic [103:0] keys,
  input  logic [4:0]   mods,
  // cable: drivers (open collector) and line levels
  output logic         kbclk,
  output logic         kbdat,
  input  logic         kbclk_line,
  input  logic         kbdat_line,
  output logic [7:0]   pb,           // column pins PB0-7, PC0-4 (Low = strobed), PC5
  output logic [5:0]   pc
);
// Phase 2 is XTLI / 2: the chip steps at every second XTLI rise (1 MHz
// from the 2 MHz crystal).  RES is taken at that step.
  // Justification: (reg-a) the Phase 2 divider, the RES sample.
  logic ph_q   = 1'b0;
  logic res_q  = 1'b0;
  logic ph2_en;
  assign ph2_en = xtli & ph_q;
  always_ff @(posedge clk) begin
    if (xtli)   ph_q  <= ~ph_q;
    if (ph2_en) res_q <= rst_n;
  end

  logic [15:0] addr;
  logic [7:0]  dout, din, rom_q;
  logic [10:0] mrom_addr;
  logic        rw_n, sync, irq_n, cntr_out;
  logic [63:0] regs;
  logic [7:0]  pa_out, pb_out, pc_out, pd_out;

  logic [23:0] addr24;
  logic        ef, mf, xf, ml_n, vp_n, vda, vpa, nmi_ack;

// T65 DEBUG port left open (the netlist splits it into DEBUG_I..DEBUG_P).
  /* verilator lint_off PINMISSING */
  T65 u_cpu (
    .Mode(2'b00), .BCD_en(1'b1), .Res_n(res_q), .Enable(ph2_en), .Clk(clk), .Rdy(1'b1),
    .Abort_n(1'b1), .IRQ_n(irq_n), .NMI_n(1'b1), .SO_n(1'b1), .DI(din),
    .R_W_n(rw_n), .Sync(sync), .EF(ef), .MF(mf), .XF(xf), .ML_n(ml_n), .VP_n(vp_n),
    .VDA(vda), .VPA(vpa), .A(addr24), .DO(dout), .Regs(regs), .NMI_ack(nmi_ack)
  );
  /* verilator lint_on PINMISSING */
  assign addr = addr24[15:0];

  c900_rom #(.AW(11)) u_mrom (
    .clk(clk), .addr(mrom_addr), .q(rom_q),
    .ld_we(rom_we), .ld_addr(rom_addr), .ld_data(rom_data)
  );

  // Row sense: a row reads Low when a pressed key sits on it in a driven
  // column.  The pin levels are registered (the port reads them as levels).
  logic [12:0] col_drv;
  logic [7:0]  rows, pa_in_q, pc_in_q, pd_in_q;
  assign col_drv = ~{pc_out[4:0], pb_out};
  always_comb begin
    rows = 8'hFF;
    for (int c = 0; c < 13; c++)
      if (col_drv[c]) rows = rows & ~keys[8*c +: 8];
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pa_in_q <= 8'hFF;
      pc_in_q <= 8'hFF;
      pd_in_q <= 8'hFF;
    end else begin
      pa_in_q <= {2'b11, ~mods[2], ~mods[1], 1'b1, ~mods[0], kbdat_line, kbclk_line};
      pc_in_q <= {~mods[4], ~mods[3], 6'h3F};
      pd_in_q <= rows;
    end
  end

  mos6500_1_io u_io (
    .clk(clk), .en(ph2_en), .rst_n(res_q), .addr(addr), .rw_n(rw_n), .d_in(dout),
    .d_out(din), .rom_addr(mrom_addr), .rom_q(rom_q), .irq_n(irq_n),
    .cntr_in(1'b0), .cntr_out(cntr_out),
    .pa_in(pa_in_q), .pb_in(8'hFF), .pc_in(pc_in_q), .pd_in(pd_in_q),
    .pa_out(pa_out), .pb_out(pb_out), .pc_out(pc_out), .pd_out(pd_out)
  );

  assign kbclk = pa_out[7];
  assign kbdat = pa_out[6];
  assign pb    = pb_out;
  assign pc    = pc_out[5:0];

  logic unused_ok;
  assign unused_ok = &{1'b0, sync, regs, addr24[23:16],
                       ef, mf, xf, ml_n, vp_n, vda, vpa, nmi_ack, pa_out[5:0], pc_out[7:6],
                       pd_out, cntr_out};
endmodule
`default_nettype wire
