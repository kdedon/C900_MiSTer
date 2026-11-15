# Disk-image path bench (tb_disk): hps_io, disk_stream and the core, with
# Main_MiSTer's side of the HPS bus in the C++ driver.
#   make            build obj_dir/tb_disk
ROOT := ../..
include $(ROOT)/sources.mk

VFLAGS := --cc --exe --build +1364-2005ext+v -O3 --x-assign fast --x-initial unique -Wno-fatal -Wno-lint -Wno-style -Wno-PROCASSWIRE -Wno-BLKANDNBLK \
          --timescale 1ns/1ps -j 2 --top-module tb_disk -o tb_disk $(HR_INC) \
          $(ROOT)/lint/vendor.vlt

TB_SRCS := $(ROOT)/sys/hps_io.sv $(ROOT)/rtl/host/disk_stream.sv $(SDRAM_SIM_SRCS) $(VDC_SIM_SRCS) $(ROOT)/tb/common/sdram_cycle_model.sv $(ROOT)/rtl/host/boot_rom_load.sv

.PHONY: all clean
all: obj_dir/tb_disk

obj_dir/tb_disk: tb_disk.sv tb_disk.cpp $(VENDOR_SRCS) $(CHIP_SRCS) $(CORE_SRCS) $(TB_SRCS)
	verilator $(VFLAGS) $(VENDOR_SRCS) $(CHIP_SRCS) $(CORE_SRCS) $(TB_SRCS) tb_disk.sv tb_disk.cpp

clean:
	rm -rf obj_dir
