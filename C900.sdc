derive_pll_clocks
derive_clock_uncertainty

# core specific constraints
# clk_vid (pll_vid) is CLK_VIDEO: built at 96 MHz (HR) and reprogrammed to
# 65.028 MHz for the LR card, so timed at 96.  Every crossing with clk_sys
# goes through c900_sync2, a dual-clock RAM or the HR video FIFO, except
# the 6845 pins, which the LR dot side takes more than four dots after
# they change.
set vid_clk [get_clocks { *|pll_vid|altera_pll_i|*[*].*|divclk}]
set_clock_groups -asynchronous \
   -group [get_clocks { *|pll|pll_inst|altera_pll_i|*[*].*|divclk}] \
   -group $vid_clk

set_clock_groups -exclusive \
   -group $vid_clk \
   -group [get_clocks { pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
   -group [get_clocks { pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
   -group [get_clocks { spi_sck}] \
   -group [get_clocks { hdmi_sck}] \
   -group [get_clocks { *|h2f_user0_clk}] \
   -group [get_clocks { FPGA_CLK1_50 }] \
   -group [get_clocks { FPGA_CLK2_50 }] \
   -group [get_clocks { FPGA_CLK3_50 }]

# c900_sdram to its controller (clk_sys to clk_ram = 2 x clk_sys, edges
# aligned).  wdata_q, addr_q, be_q and we_q change only at a clk_sys edge
# that toggles req_t, and hold until done.  The controller loads them only
# in IDLE with req_t != req_s; req_t is still the old value at the clk_ram
# edge that coincides with the change (its own hold is checked), so the
# earliest load is the next clk_ram edge.  The hold check moves one clk_ram
# cycle back; setup stays at the next edge.
set_multicycle_path -hold -end 1 \
   -from [get_registers {*|c900_sdram:u_sdram|wdata_q[*] *|c900_sdram:u_sdram|addr_q[*] *|c900_sdram:u_sdram|be_q[*] *|c900_sdram:u_sdram|we_q}] \
   -to [get_registers {*|c900_sdram:u_sdram|sdram:u_ctrl|*}]
