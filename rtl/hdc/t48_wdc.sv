// Intel 8049 (U10 on the WD1003-CMD card): the vendored T48 core behind the
// chip's own pins, with its 2 KB mask ROM and 128-byte data RAM inside.
//
// `clk` is the master clock; XTAL1 is a one-clock pulse at each rise
// (`xtal_rise`) and at each fall (`xtal_fall`), never both on one clock.
// The netlist is built with the core's XTAL divider (clock_ctrl
// xtal_div_3_g = 1) and the local pin-phase patch: xtal_en_i takes
// every XTAL rise, xtal_fall_en_i every fall and en_clk_i the core's
// xtal3_o (the third XTAL rise of each state), so ALE, RD- and WR- move on
// both XTAL edges at the data sheet phases, the first XTAL rise after
// RESET- opens S1 and T0 as ENT0 CLK output is XTAL/3.
//
// The 2 KB mask ROM is the separate t48_wdc_rom beside the core; its ld_*
// port loads the programmed part from outside (the MiSTer download path)
// and is not a chip pin.  In simulation ROM_FILE ($readmemh) preloads it.
// The ROM word and the data RAM word are registered on every XTAL rise.
// An unregistered RAM read closes a loop through the core (an indirect
// access takes its address from the RAM output).
//
// EA is Low on the card (internal ROM) and SS- High; neither is a port.
// P1 and P2 are quasi-bidirectional: pN_out is the port latch, pN_in the
// pin level the core reads.
`default_nettype none

module t48_wdc_rom #(
    parameter ROM_FILE = ""
) (
    input  logic        clk,
    input  logic        en,         // read strobe
    input  logic [10:0] addr,
    output logic [7:0]  q,
    input  logic        ld_we,      // loader write (not a chip pin)
    input  logic [10:0] ld_addr,
    input  logic [7:0]  ld_data
);
    (* ramstyle = "M10K" *) logic [7:0] mem [0:2047];

`ifndef SYNTHESIS
    initial begin
        if (ROM_FILE != "") $readmemh(ROM_FILE, mem);
    end
`endif

    always_ff @(posedge clk) begin
        if (ld_we) mem[ld_addr] <= ld_data;
        if (en) q <= mem[addr];
    end
endmodule

module t48_wdc #(
    parameter ROM_FILE = ""
) (
    input  logic        clk,        // master clock
    input  logic        xtal_rise,  // XTAL1 rises now
    input  logic        xtal_fall,  // XTAL1 falls now
    input  logic        reset_n,    // RESET-
    input  logic        int_n,      // INT-
    input  logic        t0_in,      // T0 level
    output logic        t0_out,     // T0 driven (ENT0 CLK)
    output logic        t0_oe,
    input  logic        t1_in,      // T1
    input  logic [7:0]  db_in,      // DB0-7 level
    output logic [7:0]  db_out,     // DB0-7 driven
    output logic        db_oe,
    output logic        ale,        // ALE
    output logic        psen_n,     // PSEN-
    output logic        rd_n,       // RD-
    output logic        wr_n,       // WR-
    output logic        prog_n,     // PROG-
    input  logic [7:0]  p1_in,      // P1 pin levels
    output logic [7:0]  p1_out,     // P1 latch
    input  logic [7:0]  p2_in,      // P2 pin levels
    output logic [7:0]  p2_out,     // P2 latch

    // Mask ROM loader (the programmed part, not 8049 pins).
    input  logic        rom_we,
    input  logic [10:0] rom_addr,
    input  logic [7:0]  rom_data
);

    // Mask ROM, word registered on the XTAL rise.
    logic [11:0] pmem_addr;
    logic [7:0]  pmem_q;

    t48_wdc_rom #(.ROM_FILE(ROM_FILE)) u_rom (
        .clk(clk), .en(xtal_rise), .addr(pmem_addr[10:0]), .q(pmem_q),
        .ld_we(rom_we), .ld_addr(rom_addr), .ld_data(rom_data)
    );

    // Data RAM, 128 bytes, read and written at one address on the XTAL
    // rise.  The core sees the byte at that address after the write: the
    // old-data read, or the written byte when there was a write.
    // Justification: on-chip RAM, read word, write bypass (reg-a).
    (* ramstyle = "no_rw_check, mlab" *)
    logic [7:0] dmem [0:127];
    logic [7:0] dmem_addr, dmem_wdata;
    logic       dmem_we;
    logic [7:0] dmem_q, dmem_wd_q;
    logic       dmem_we_q;

    always_ff @(posedge clk) begin
        if (xtal_rise) begin
            if (dmem_we) dmem[dmem_addr[6:0]] <= dmem_wdata;
            dmem_q    <= dmem[dmem_addr[6:0]];
            dmem_we_q <= dmem_we;
            dmem_wd_q <= dmem_wdata;
        end
    end

    logic [7:0] dmem_rdata;
    assign dmem_rdata = dmem_we_q ? dmem_wd_q : dmem_q;

    logic xtal3, p1_low_imp, p2l_low_imp, p2h_low_imp;

    // The simulation builds use the GHDL netlist, which has
    // xtal_div_3_g = 1 built in and no generic.
`ifdef VERILATOR
    t48_core core (
`else
    t48_core #(.xtal_div_3_g(1)) core (
`endif
        .xtal_i        (clk),
        .xtal_en_i     (xtal_rise),
        .xtal_fall_en_i(xtal_fall),
        .reset_i       (reset_n),
        .t0_i          (t0_in),
        .int_n_i       (int_n),
        .ea_i          (1'b0),
        .db_i          (db_in),
        .t1_i          (t1_in),
        .p2_i          (p2_in),
        .p1_i          (p1_in),
        .clk_i         (clk),
        .en_clk_i      (xtal3),
        .dmem_data_i   (dmem_rdata),
        .pmem_data_i   (pmem_q),
        .t0_o          (t0_out),
        .t0_dir_o      (t0_oe),
        .rd_n_o        (rd_n),
        .psen_n_o      (psen_n),
        .wr_n_o        (wr_n),
        .ale_o         (ale),
        .db_o          (db_out),
        .db_dir_o      (db_oe),
        .p2_o          (p2_out),
        .p2l_low_imp_o (p2l_low_imp),
        .p2h_low_imp_o (p2h_low_imp),
        .p1_o          (p1_out),
        .p1_low_imp_o  (p1_low_imp),
        .prog_n_o      (prog_n),
        .xtal3_o       (xtal3),
        .dmem_addr_o   (dmem_addr),
        .dmem_we_o     (dmem_we),
        .dmem_data_o   (dmem_wdata),
        .pmem_addr_o   (pmem_addr)
    );

    logic unused_ok;
    assign unused_ok = &{1'b0, dmem_addr[7], pmem_addr[11], p1_low_imp, p2l_low_imp, p2h_low_imp};

endmodule

`default_nettype wire
