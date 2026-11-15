// cpu6508.sv - SystemVerilog wrapper for the MOS 6508 sub-CPU on the C900 FDC board.
//
// The MOS 6508 is a 6502-compatible CPU with on-chip peripherals:
//   - 8-bit bidirectional I/O port at 0x0000 (DDR) / 0x0001 (data)
//   - 256 bytes of internal static RAM, appearing at BOTH page 0 (0x0000-0x00FF)
//     and page 1 (0x0100-0x01FF) simultaneously (the two pages are mirrors of the
//     same 256-byte array). This allows zero-page addressing AND stack operations
//     with no external RAM.
//   - Set Overflow (SO) pin - asserted active-low by BRDY from the MOS 8723 FDC
//
// Internal address space: 0x0000-0x01FF (both pages map to the same 256-byte array)
//   0x0000 / 0x0100   DDR register (direction: 1=output, 0=input)
//   0x0001 / 0x0101   I/O port (reads: DDR-muxed from port_in; writes: output latch)
//   0x0002-0x00FF     General-purpose zero-page RAM (also at 0x0102-0x01FF)
//   0x01FF            Stack top (SP initialised to 0xFF by reset sequence, so stack
//                     starts at 0x01FF = physical same byte as 0x00FF)
//
// External address space: 0x0200-0xFFFF (the board's decode)
//   On the C900 FDC board this covers:
//     0x4000-0x400F   MOS 8723 FDC registers
//     0xE000-0xFFFF   8 KB ROM (reset/IRQ vectors at 0xFFFC/0xFFFE/0xFFFA)
//
// Clocking: `clk` is the master clock; Phi2 IN (phi2) is a one-master-clock
// pulse meaning "Phi2 rises now".  The T65 steps (Enable) on that pulse;
// /RES and /SO reach the core only at that edge, so the core sees them at the
// Phi2 rise as the 6502 does.  Phi1 IN is not used (the T65 is single-phase).
//
// Reset: Phi2 cycle 0 is the one whose rise first takes /RES High.  The
// sequence begins there; FFFC is read in Phi2 cycle 6, FFFD in 7, the first
// opcode fetched in 8 (data sheet, Reset: six cycles, then the vector; the
// 6502 transistor-level trace has three PC-page reads, three stack reads,
// FFFC, FFFD).  The T65 reaches FFFC on its fourth step after its reset
// releases, so its first step is the cycle-3 Phi2 rise: its Res_n (a
// register) rises after the cycle-1 rise, which its own two-clock
// synchroniser has passed by cycle 3, and its Enable is held off up to
// and including the cycle-2 rise.  Both hold for any Phi2 spacing of two or
// more master clocks.

`default_nettype none

module cpu6508 (
    input  logic        clk,        // master clock
    input  logic        phi2,       // Phi2 IN rises now (from the 8723 PH2)
    input  logic        reset_n,    // /RES
    input  logic        irq_n,      // /IRQ
    input  logic        so_n,       // /SO, BRDY from the 8723

    input  logic  [7:0] data_in,    // DB0-7 as read
    output logic  [7:0] data_out,   // DB0-7 as driven on a write
    output logic [15:0] addr,       // A0-A15
    output logic        rw_n,       // R/W

    input  logic  [7:0] port_in,    // P0-P7 levels
    output logic  [7:0] port_out,   // P0-P7 driven (DDR=1 bits)
    output logic  [7:0] port_dir    // P0-P7 drive (DDR)
);

    // Justification: the /SO sample, /RES at the last Phi2 rise, the core's
    // Res_n and its step enable, all taken at Phi2 rises (reg-a).
    logic res1_q = 1'b0, res_q = 1'b0, step_q = 1'b0, so_q = 1'b1;
    logic en, en_core;
    assign en      = phi2;
    assign en_core = en & step_q;

    always_ff @(posedge clk) begin
        if (en) begin
            res1_q <= reset_n;
            res_q  <= reset_n & res1_q;
            step_q <= reset_n & res_q;
            so_q   <= so_n;
        end
    end

    // /SO reaches the core at the Phi2 rise: the T65 edge-detects SO_n on
    // every clk, so between rises it sees the level taken at the last one.
    logic so_core;
    assign so_core = en ? so_n : so_q;

    wire  [23:0] addr24;
    wire   [7:0] cpu_do;
    logic  [7:0] cpu_di;
    wire         cpu_rw_n;
    wire         cpu_sync /*verilator public_flat_rd*/;
    wire  [63:0] regs /*verilator public_flat_rd*/;

    // Internal space 0x0000-0x01FF; A23-A16 of the T65 are not on the 6508.
    wire       int_sel = (addr24[15:9] == 7'h0);
    wire [7:0] int_idx = addr24[7:0];

    reg [7:0] int_ddr  /*verilator public_flat_rd*/ = 8'h00;
    reg [7:0] int_port /*verilator public_flat_rd*/ = 8'h00;

    // The RAM is one MLAB-inferred array, written at the Phi2 rise that
    // ends a write cycle and read on every master clock.  The T65 address
    // changes only at a Phi2 pulse, so with Phi2 pulses at least two master
    // clocks apart (the 8723 PH divider gives four or more) the registered
    // read holds the byte at the current address when the core samples DI.
    // Bytes 0 and 1 are written but never read (the port registers answer
    // there).
    // Justification: on-chip RAM (reg-a); registered read port (reg-a).
    (* ramstyle = "no_rw_check, mlab" *)
    reg [7:0] int_ram  [0:255] /*verilator public_flat_rd*/;
    reg [7:0] ram_q;
    logic     ram_we;
    assign ram_we = en && !cpu_rw_n && int_sel;

    always @(posedge clk) begin
        if (ram_we) int_ram[int_idx] <= cpu_do;
        ram_q <= int_ram[int_idx];
    end

`ifndef SYNTHESIS
    // Phi2 pulses on adjacent clocks would read the previous address.
    logic en_q = 1'b0;
    always_ff @(posedge clk) begin
        en_q <= en;
        if (en && en_q) $error("cpu6508: Phi2 pulses on adjacent master clocks");
    end
`endif

    always_comb begin
        if (int_sel) begin
            case (int_idx)
                8'h00:   cpu_di = int_ddr;
                8'h01:   cpu_di = (int_port & int_ddr) | (port_in & ~int_ddr);
                default: cpu_di = ram_q;
            endcase
        end else begin
            cpu_di = data_in;
        end
    end

    always_ff @(posedge clk) begin
        if (ram_we && int_idx == 8'h00) int_ddr  <= cpu_do;
    end

    always_ff @(posedge clk) begin
        if (ram_we && int_idx == 8'h01) int_port <= cpu_do;
    end

    wire        unused_ef, unused_mf, unused_xf, unused_ml_n, unused_vp_n, unused_vda, unused_vpa;
    wire        unused_nmi_ack;
    wire        unused_ok = &{1'b0, addr24[23:16]};

    // DEBUG (a record port in the VHDL entity) is left unconnected.
    /* verilator lint_off PINMISSING */
    T65 cpu (
        .Mode    (2'b00),
        .BCD_en  (1'b1),
        .Res_n   (res_q),
        .Enable  (en_core),
        .Clk     (clk),
        .Rdy     (1'b1),
        .Abort_n (1'b1),
        .IRQ_n   (irq_n),
        .NMI_n   (1'b1),
        .SO_n    (so_core),
        .R_W_n   (cpu_rw_n),
        .Sync    (cpu_sync),
        .EF      (unused_ef),
        .MF      (unused_mf),
        .XF      (unused_xf),
        .ML_n    (unused_ml_n),
        .VP_n    (unused_vp_n),
        .VDA     (unused_vda),
        .VPA     (unused_vpa),
        .A       (addr24),
        .DI      (cpu_di),
        .DO      (cpu_do),
        .Regs    (regs),
        .NMI_ack (unused_nmi_ack)
    );
    /* verilator lint_on PINMISSING */

    assign addr     = addr24[15:0];
    assign rw_n     = cpu_rw_n;
    assign data_out = cpu_do;
    assign port_out = int_port & int_ddr;
    assign port_dir = int_ddr;

endmodule

`default_nettype wire
