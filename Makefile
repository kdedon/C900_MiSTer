# C900_MiSTer -- lint and testbenches.
#
#   make lint        Verilator -Wall over the whole core (top c900_core).
#                    rtl/vendor/ and a few moved chips: waived in
#                    lint/vendor.vlt.
#   make lint-emu    C900.sv with the core, the framework parts it uses
#                    (sys/, waived) and port shells of the PLL IP;
#                    Verilator's default warnings.
#   make tb          build and run every bench; tb/core is only built
#                    (it needs the ROMs: tb/core/gate.sh <rom_dir>).
#   make clean
#
# The Quartus source list is files.qip; keep sources.mk in step with it.

VERILATOR ?= verilator
OBJ       := obj_dir

include sources.mk

LINT_FLAGS := --lint-only -Wall +1364-2005ext+v --timescale 1ns/1ps lint/vendor.vlt $(HR_INC)

.PHONY: lint lint-emu tb clean

lint: $(T48_NET) $(T65_NET) $(RGBI_NET) $(SDRAM_SIM) $(VDC_SIM) $(VDC_SIM_VID)
	@$(VERILATOR) $(LINT_FLAGS) --top-module c900_core $(VENDOR_SRCS) $(CHIP_SRCS) $(CORE_SRCS) $(VDC_SIM_SRCS)
	@$(VERILATOR) $(LINT_FLAGS) --top-module ps2_kbd_matrix rtl/host/ps2_kbd_matrix.sv
	@$(VERILATOR) $(LINT_FLAGS) --top-module ps2_mouse_quad rtl/host/ps2_mouse_quad.sv
	@$(VERILATOR) $(LINT_FLAGS) --top-module ps2_mouse_msys rtl/host/ps2_mouse_msys.sv
	@$(VERILATOR) $(LINT_FLAGS) --top-module disk_stream rtl/fdc/fd_pkg.sv rtl/host/disk_stream.sv
	@$(VERILATOR) $(LINT_FLAGS) --top-module hr_video rtl/host/hr_video.sv rtl/common/vid_fifo.sv rtl/common/c900_sync2.sv
	@$(VERILATOR) $(LINT_FLAGS) --top-module lc_video rtl/host/lc_video.sv rtl/common/vid_fifo.sv rtl/common/c900_sync2.sv $(RGBI_NET)
	@$(VERILATOR) $(LINT_FLAGS) --top-module centronics_printer rtl/host/centronics_printer.sv
	@$(VERILATOR) $(LINT_FLAGS) --top-module speaker_audio rtl/host/speaker_audio.sv
	@$(VERILATOR) $(LINT_FLAGS) --top-module uart_sel rtl/host/uart_sel.sv
	@$(VERILATOR) $(LINT_FLAGS) --top-module boot_rom_load rtl/host/boot_rom_load.sv
	@$(VERILATOR) $(LINT_FLAGS) --top-module lance_link rtl/host/lance_link.sv
	@$(VERILATOR) $(LINT_FLAGS) --top-module c900_sdram $(SDRAM_SIM_SRCS)
	@# Quartus 17 sizes N'(... int'(x) ...) as one bit: the index silently loses bits.
	@if grep -rnE "[0-9]'\([^;]*int'\(" rtl C900.sv; then echo "lint: size cast of an int' cast"; exit 1; fi
	@echo "lint: clean"

EMU_SYS := sys/hps_io.sv sys/video_mixer.sv sys/scandoubler.v sys/hq2x.sv sys/gamma_corr.sv sys/video_freezer.sv

$(OBJ)/lint/build_id.v:
	@mkdir -p $(dir $@)
	@echo '`define BUILD_DATE "000000"' > $@

lint-emu: $(T48_NET) $(T65_NET) $(RGBI_NET) $(SDRAM_SIM) $(VDC_SIM) $(VDC_SIM_VID) $(OBJ)/lint/build_id.v
	@$(VERILATOR) --lint-only +1364-2005ext+v --timescale 1ns/1ps lint/vendor.vlt lint/emu.vlt $(HR_INC) +incdir+$(OBJ)/lint \
	  --top-module emu $(VENDOR_SRCS) $(CHIP_SRCS) $(CORE_SRCS) $(VDC_SIM_SRCS) $(SDRAM_SIM_SRCS) $(RGBI_NET) \
	  $(wildcard rtl/host/*.sv) $(EMU_SYS) lint/emu_stubs.sv C900.sv
	@echo "lint-emu: clean"

tb:
	$(MAKE) -C tb/clock
	$(MAKE) -C tb/hdc
	$(MAKE) -C tb/expansion
	$(MAKE) -C tb/lance
	$(MAKE) -C tb/mouse
	$(MAKE) -C tb/host
	$(MAKE) -C tb/fdc
	$(MAKE) -C tb/ports
	$(MAKE) -C tb/sdram
	$(MAKE) -C tb/lr_display
	$(MAKE) -C tb/lc_display
	$(MAKE) -C tb/dispram
	$(MAKE) -C tb/core

clean:
	rm -rf $(OBJ)
