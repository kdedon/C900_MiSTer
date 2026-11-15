// HD6545 CRTC (LR display board U9): the vendored MC6845 core behind the
// chip's own pins.  Pin-compatible with the MC6845.
//
// `clk` is the master clock.  The CLK and E pins arrive as one-master-clock
// edge pulses from the board's divider; the core steps on them:
//   - cclk: CLK falls now; the character clock.  MA, RA, HSYNC, VSYNC,
//     DISPTMG and CURSOR change after it (MC6845 data sheet, CRTC timing).
//   - e_fall: E falls now, with /CS Low and R/W Low the register write (6800
//     bus).  e_rise and e_fall never fire on the same master clock.
//   - E High with /CS Low and R/W High: the data bus is driven (d_oe); only
//     R14-R17 are readable on a type 2 CRTC.  The E level is rebuilt from
//     the E pulses (Low at power-up).
// C900 wiring: RS is Z-Bus A1 (0x0410 address register, 0x0412 data
// register); CLK is the 16.257 MHz dot crystal / 9; LPSTB is not connected
// on the board (tie Low).
`default_nettype none

module mc6845_lrdisp (
    input  logic        clk,        // master clock
    input  logic        reset_n,    // /RESET
    input  logic        cclk,       // CLK falls now (character clock)
    input  logic        e_rise,     // E rises now
    input  logic        e_fall,     // E falls now
    input  logic        cs_n,       // /CS
    input  logic        rs,         // RS
    input  logic        r_w,        // R/W: 1 read, 0 write
    input  logic  [7:0] d_in,
    output logic  [7:0] d_out,
    output logic        d_oe,
    input  logic        lpstb,
    output logic        hsync,
    output logic        vsync,
    output logic        de,         // DISPTMG
    output logic        cursor,
    output logic [13:0] ma,
    output logic  [4:0] ra
);

    // Justification: E level rebuilt from its edge pulses for d_oe (reg-a).
    // E is a bus input: /RESET does not touch it; Low at power-up.
    logic e_q = 1'b0;
    always_ff @(posedge clk) begin
        if (e_rise)      e_q <= 1'b1;
        else if (e_fall) e_q <= 1'b0;
    end

    logic e_lvl;
    assign e_lvl = e_rise | (e_q & ~e_fall);

    logic [7:0] core_do;
    logic       core_do_valid;
    logic [3:0] core_test;
    logic [7:0] core_r1;
    logic       core_hdisp, core_vdisp;

    mc6845 crtc (
        .CLOCK       (clk),
        .CLKEN       (cclk),
        .CLKEN_CPU   (e_fall),
        .nRESET      (reset_n),
        .ENABLE      (~cs_n),
        .R_nW        (r_w),
        .RS          (rs),
        .DI          (d_in),
        .DO          (core_do),
        .DO_VALID    (core_do_valid),
        .VSYNC       (vsync),
        .HSYNC       (hsync),
        .DE          (de),
        .CURSOR      (cursor),
        .LPSTB       (lpstb),
        .VGA         (1'b0),
        .MA          (ma),
        .RA          (ra),
        .test        (core_test),
        .R1_ACTIVE   (core_r1),
        .H_DISPLAY_O (core_hdisp),
        .V_DISPLAY_O (core_vdisp)
    );

    assign d_out = core_do;
    assign d_oe  = core_do_valid & e_lvl & ~cs_n & r_w;

    logic unused_ok;
    assign unused_ok = &{1'b0, core_test, core_r1, core_hdisp, core_vdisp};

endmodule

`default_nettype wire
