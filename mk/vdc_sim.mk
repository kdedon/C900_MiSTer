# Simulation copy of the vendored 8563 for Verilator, made by
# tb/lc_display/vdc_sim.patch: the block-local initialised clock divider
# moves to module scope (Verilator would re-run its initialiser on every
# clock).  The copy of vdc_video.sv is built with VERILATOR undefined: its
# Verilator branch stubs the row latches.  Build artifacts in obj_dir/vdc,
# never committed.
#   needs: ROOT

VDC_GOAL := $(.DEFAULT_GOAL)

VDC_DIR  := $(ROOT)/rtl/vendor/vdc856x
VDC_SIM  := $(ROOT)/obj_dir/vdc/vdc_top.sv
VDC_SIM_VID := $(ROOT)/obj_dir/vdc/vdc_video.sv
VDC_SIM_SRCS := $(VDC_SIM) $(VDC_SIM_VID) $(addprefix $(VDC_DIR)/,vdc_signals.sv vdc_signals_h.sv \
  vdc_signals_v.sv vdc_ramiface.sv)

$(VDC_SIM): $(VDC_DIR)/vdc_top.sv $(ROOT)/tb/lc_display/vdc_sim.patch
	mkdir -p $(dir $@)
	patch -s -o $(abspath $@).tmp $< $(ROOT)/tb/lc_display/vdc_sim.patch
	mv $@.tmp $@

$(VDC_SIM_VID): $(VDC_DIR)/vdc_video.sv
	mkdir -p $(dir $@)
	{ echo '`undef VERILATOR'; cat $<; echo '`define VERILATOR 1'; } > $@.tmp
	mv $@.tmp $@

.DEFAULT_GOAL := $(VDC_GOAL)
