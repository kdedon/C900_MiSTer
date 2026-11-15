# Floppy board benches.
#   make         fdlseek
#   make lint    lint tb_fdboard
#   make board ROM1=<boot1.rom>   build obj_dir/tb_fdboard (the board's
#            firmware reading through the 8716) and time reads in zones 0 and 3
#   make fdwrite ROM1=<boot1.rom> tb_fdboard writing both floppies (same side,
#            other tracks, drive changes), then every image block checked
#            (about an hour)
#   make fdlseek one fd_layout reseeking with late grants against one that
#            never reseeks
ROOT := ../..
include $(ROOT)/sources.mk
FD   := $(ROOT)/rtl/fdc
SRCS := $(FD)/fd_pkg.sv $(FD)/fd_layout.sv $(FD)/fd_head.sv $(FD)/fd_raw.sv $(FD)/fd_scan.sv \
        $(FD)/fd_media.sv $(FD)/fd_drive.sv $(ROOT)/rtl/host/disk_stream.sv
.PHONY: all board fdwrite fdlseek lint clean need_rom1
all: fdlseek

need_rom1:
	@[ -f "$(ROM1)" ] || { echo "ROM1=<boot1.rom> needed (scripts/make_boot_rom.sh)"; exit 1; }

HD   := $(ROOT)/rtl/hdc
BOARD_SRCS := $(ROOT)/rtl/motherboard/pdmac/*.sv $(FD)/gcr_engine.sv $(FD)/fdc8723.sv $(T65_NET) $(ROOT)/rtl/fdc/cpu6508.sv \
        $(ROOT)/rtl/common/c900_rom.sv $(ROOT)/rtl/fdc/c900_fdc.sv $(ROOT)/rtl/clock/fantdiv.sv \
        $(addprefix $(HD)/,wd2010_rdchan.sv wd2010_wrchan.sv wd2010.sv wd10c20.sv st506_pkg.sv st506_media.sv \
          st506_walker.sv st506_wrdec.sv st506_drive.sv) $(T48_NET) $(ROOT)/rtl/hdc/t48_wdc.sv \
        $(filter-out $(ROOT)/rtl/hdc/t48_wdc.sv $(addprefix $(HD)/,wd2010_rdchan.sv wd2010_wrchan.sv wd2010.sv wd10c20.sv st506_pkg.sv st506_media.sv st506_walker.sv st506_wrdec.sv st506_drive.sv),$(wildcard $(ROOT)/rtl/hdc/*.sv))
# One rst_n reaches chips with async and sync resets alike: SYNCASYNCNET off.
lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-SYNCASYNCNET +1364-2005ext+v $(ROOT)/lint/vendor.vlt \
	  --top-module tb_fdboard $(SRCS) $(BOARD_SRCS) tb_fdboard.sv

board: need_rom1 obj_dir/tb_fdboard
	./obj_dir/tb_fdboard --rom $(ROM1) 300:32 2250:32 300:1x8 2250:1x8

obj_dir/tb_fdboard: tb_fdboard.cpp tb_fdboard.sv $(SRCS) $(T65_NET) $(T48_NET)
	verilator --cc --exe --build +1364-2005ext+v -O3 -Wno-fatal -Wno-lint -Wno-style --x-assign fast --x-initial unique -j 2 \
	  $(ROOT)/lint/vendor.vlt --top-module tb_fdboard -o tb_fdboard \
	  $(SRCS) $(BOARD_SRCS) tb_fdboard.sv tb_fdboard.cpp > obj_dir/board_build.log

obj_dir/zero2k.rom:
	head -c 2048 /dev/zero > $@

fdwrite: need_rom1 obj_dir/tb_fdboard obj_dir/zero2k.rom
	./obj_dir/tb_fdboard --rom $(ROM1) --nohdc --hrom obj_dir/zero2k.rom --two --drive 1 --boot 150 --max 10 \
	  W:300:1 U:0 W:1:1 U:1 W:2:1 U:0 W:330:1 W:2:1 U:1 W:1:1 W:331:1 IDLE:300 CHK

fdlseek: obj_dir/tb_fdlseek
	./obj_dir/tb_fdlseek 100 7

obj_dir/tb_fdlseek: tb_fdlseek.cpp fdl_pair.sv $(FD)/fd_pkg.sv $(FD)/fd_layout.sv
	verilator --cc --exe --build -O2 -Wno-fatal --x-assign fast --x-initial unique -j 2 \
	  --top-module fdl_pair --Mdir obj_dir/fdlseek -o ../tb_fdlseek \
	  $(FD)/fd_pkg.sv $(FD)/fd_layout.sv fdl_pair.sv $(CURDIR)/tb_fdlseek.cpp > /dev/null 2>&1

clean:
	rm -rf obj_dir
