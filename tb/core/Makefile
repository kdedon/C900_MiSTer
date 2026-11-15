# Whole-machine bench (tb_core): the BIOS boot gate.
#   make            build obj_dir/tb_core
#   make run ROMS=<dir> [ARGS="+nocard +trace=t.txt"]
#   make netboot ROMS=<dir> [FILE=<l.out>] [LOAD=1]  LANCE network boot (netboot.sh);
#                   FILE defaults to mknethello.py's, which prints NETBOOT OK
#   make netrom ROMS=<dir> [MODE=static|bootp]  the LANCE card's boot ROM
#                   (netrom.sh), through a stand-in for the BIOS hook
# ROMS: a directory with boot0.rom and boot1.rom (scripts/make_boot_rom.sh).
ROOT := ../..
include $(ROOT)/sources.mk

VERILATOR ?= verilator
ROMS ?= obj_dir
ARGS ?=

VFLAGS := --cc --exe --build +1364-2005ext+v -O3 --x-assign fast --x-initial unique -Wno-fatal -Wno-lint -Wno-style \
          --timescale 1ns/1ps -j 2 --top-module tb_core -o tb_core $(HR_INC) \
          $(ROOT)/lint/vendor.vlt

.PHONY: all run netboot netrom clean
all: obj_dir/tb_core

TB_SRCS := $(ROOT)/tb/core/ssmon.sv $(ROOT)/rtl/host/uart_sel.sv $(SDRAM_SIM_SRCS) $(VDC_SIM_SRCS) $(ROOT)/tb/common/sdram_cycle_model.sv $(ROOT)/rtl/host/centronics_printer.sv $(ROOT)/rtl/host/lance_link.sv $(ROOT)/rtl/host/boot_rom_load.sv

obj_dir/tb_core: tb_core.sv tb_core.cpp netpeer.cpp $(VENDOR_SRCS) $(CHIP_SRCS) $(CORE_SRCS) $(TB_SRCS)
	$(VERILATOR) $(VFLAGS) $(VENDOR_SRCS) $(CHIP_SRCS) $(CORE_SRCS) $(TB_SRCS) tb_core.sv tb_core.cpp netpeer.cpp

run: obj_dir/tb_core
	./obj_dir/tb_core +rom=$(ROMS)/boot0.rom +rom1=$(ROMS)/boot1.rom $(ARGS)

FILE ?= obj_dir/nethello.out
obj_dir/nethello.out: mknethello.py
	@mkdir -p obj_dir
	python3 mknethello.py $@

netboot: obj_dir/tb_core $(FILE)
	./netboot.sh $(if $(LOAD),-l) $(ROMS) $(FILE)

MODE ?= static
netrom: obj_dir/tb_core
	./netrom.sh $(ROMS) $(MODE)

clean:
	rm -rf obj_dir
