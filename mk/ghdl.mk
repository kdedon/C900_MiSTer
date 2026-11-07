# Verilog netlists of the vendored VHDL cores (T48, T65, the VDC palette) for Verilator, made
# with GHDL at bench build time.  Build artifacts in obj_dir/ghdl, never
# committed; Quartus compiles the VHDL itself (files.qip).
#   needs: ROOT; GHDL (default: the pinned release in tools/ghdl, fetched
#   on first use).

# The rules here do not become the including Makefile's default goal.
GHDL_GOAL := $(.DEFAULT_GOAL)

GHDL     ?= $(ROOT)/tools/ghdl/bin/ghdl
GHDL_DIR := $(ROOT)/obj_dir/ghdl
T48_VHDL := $(addprefix $(ROOT)/rtl/vendor/t48/,t48_pack-p.vhd psw.vhd pmem_ctrl_pack-p.vhd \
  pmem_ctrl.vhd p2.vhd p1.vhd timer.vhd dmem_ctrl_pack-p.vhd dmem_ctrl.vhd decoder_pack-p.vhd \
  cond_branch_pack-p.vhd alu_pack-p.vhd int.vhd t48_tb_pack-p.vhd decoder.vhd db_bus.vhd \
  cond_branch.vhd clock_ctrl.vhd bus_mux.vhd alu.vhd t48_core.vhd)
T65_VHDL := $(addprefix $(ROOT)/rtl/vendor/t65/,T65_Pack.vhd T65_MCode.vhd T65_ALU.vhd T65.vhd)
T48_NET  := $(GHDL_DIR)/t48_core_synth.v
T65_NET  := $(GHDL_DIR)/T65_synth.v
RGBI_NET := $(GHDL_DIR)/rgbicolor_synth.v
GHDL_PIN := $(ROOT)/tools/ghdl/bin/ghdl
GHDL_DEP := $(filter $(GHDL_PIN),$(GHDL))

$(GHDL_PIN):
	$(ROOT)/scripts/get_ghdl.sh

# xtal_div_3_g = 1: the T48's own XTAL divider, as on the t48_wdc instance.
$(T48_NET): $(T48_VHDL) | $(GHDL_DEP)
	rm -rf $(GHDL_DIR)/t48 && mkdir -p $(GHDL_DIR)/t48
	$(GHDL) -a --workdir=$(GHDL_DIR)/t48 --std=93 $(T48_VHDL)
	$(GHDL) --synth --workdir=$(GHDL_DIR)/t48 --std=93 -gxtal_div_3_g=1 --out=verilog t48_core > $@.tmp
	mv $@.tmp $@

$(T65_NET): $(T65_VHDL) | $(GHDL_DEP)
	rm -rf $(GHDL_DIR)/t65 && mkdir -p $(GHDL_DIR)/t65
	$(GHDL) -a --workdir=$(GHDL_DIR)/t65 --std=08 -fsynopsys $(T65_VHDL)
	$(GHDL) --synth --workdir=$(GHDL_DIR)/t65 --std=08 -fsynopsys --out=verilog T65 > $@.tmp
	mv $@.tmp $@

# The palette's case statements on unsigned get an "others" choice, which
# GHDL requires (Quartus does not).
$(RGBI_NET): $(ROOT)/rtl/vendor/vdc856x/rgbicolor.vhd | $(GHDL_DEP)
	rm -rf $(GHDL_DIR)/rgbi && mkdir -p $(GHDL_DIR)/rgbi
	sed 's/^\(\s*\)end case;/\1when others => r <= X"00"; g <= X"00"; b <= X"00";\n\1end case;/' $< \
	  > $(GHDL_DIR)/rgbi/rgbicolor.vhd
	$(GHDL) -a --workdir=$(GHDL_DIR)/rgbi --std=08 $(GHDL_DIR)/rgbi/rgbicolor.vhd
	$(GHDL) --synth --workdir=$(GHDL_DIR)/rgbi --std=08 --out=verilog rgbicolor > $@.tmp
	mv $@.tmp $@

.DEFAULT_GOAL := $(GHDL_GOAL)
