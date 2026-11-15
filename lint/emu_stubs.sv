// Port shells of the Altera PLL and reconfiguration IP, for linting the
// MiSTer shell (C900.sv) with Verilator.
`default_nettype none
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNDRIVEN */
module pll (
  input  wire refclk,
  input  wire rst,
  output wire outclk_0,
  output wire outclk_1,
  output wire outclk_2,
  output wire locked
);
endmodule

module pll_vid (
  input  wire        refclk,
  input  wire        rst,
  output wire        outclk_0,
  output wire        locked,
  input  wire [63:0] reconfig_to_pll,
  output wire [63:0] reconfig_from_pll
);
endmodule

module pll_cfg_hdmi (
  input  wire        mgmt_clk,
  input  wire        mgmt_reset,
  output wire [63:0] reconfig_to_pll,
  input  wire [63:0] reconfig_from_pll,
  output wire        mgmt_waitrequest,
  input  wire [5:0]  mgmt_address,
  input  wire        mgmt_write,
  input  wire [31:0] mgmt_writedata
);
endmodule
/* verilator lint_on UNDRIVEN */
/* verilator lint_on UNUSEDSIGNAL */
`default_nettype wire
