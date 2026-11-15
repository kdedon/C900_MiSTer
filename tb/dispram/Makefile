# Shared display RAM (c900_dispram) bench.
#   tb_hr_eq  the HR bitmap through c900_dispram against the card's own
#             block RAM (hr_fn4_dram before the move, patch reversed,
#             renamed hr_fn4_old): a_q and b_q equal every clk.
#   tb_lc_eq  the 8563 on c900_dispram (48 MHz clk) against the 8563 with
#             its own RAM block (vdc_top/vdc_ramiface before the move,
#             patch reversed, renamed vdo_*): pins and bus byte equal every
#             clk_vdc, a scoreboard of the bytes read back; NTSC columns,
#             the shortest column, double width, both column phases.
ROOT := ../..
include $(ROOT)/mk/vdc_sim.mk
V     := $(ROOT)/rtl/vendor/vdc856x
HR    := $(ROOT)/rtl/hr_display
VP    := $(ROOT)/rtl/vendor_patches
O     := obj_dir/orig
VFLAGS := --binary --timing -O2 -Wno-fatal -Wno-PROCASSWIRE -UVERILATOR --x-initial unique

.PHONY: all clean
all: obj_dir/tb_hr_eq obj_dir/tb_lc_eq
	./obj_dir/tb_hr_eq
	./obj_dir/tb_lc_eq
	./obj_dir/tb_lc_eq +vdcph +seed=5
	./obj_dir/tb_lc_eq +cth=1 +seed=7
	./obj_dir/tb_lc_eq +cth=1 +vdcph +seed=9
	./obj_dir/tb_lc_eq +cth=2 +dbl +seed=13
	./obj_dir/tb_lc_eq +cth=1 +dbl +vdcph +seed=17

$(O)/hr_fn4_old.sv: $(HR)/hr_fn4_dram.sv $(HR)/hr_card.sv hr_bitmap_ram_pins.patch
	rm -rf $(O)/hrcard && mkdir -p $(O)/hrcard/hrdisp
	cp $(HR)/hr_fn4_dram.sv $(HR)/hr_card.sv $(O)/hrcard/hrdisp/
	patch -s -R -d $(O)/hrcard -p1 < hr_bitmap_ram_pins.patch
	sed -E 's/\bhr_fn4_dram\b/hr_fn4_old/' $(O)/hrcard/hrdisp/hr_fn4_dram.sv > $@

REN := sed -E 's/\bvdc_(top|ramiface|video)\b/vdo_\1/g'
$(O)/vdo.stamp: $(VDC_SIM) $(VDC_SIM_VID) $(V)/vdc_ramiface.sv $(VP)/vdc856x/ram_pins.patch \
                $(VP)/vdc856x/busy_pin.patch $(VP)/vdc856x/row_ram.patch
	rm -rf $(O)/vdc && mkdir -p $(O)/vdc
	cp $(VDC_SIM) $(VDC_SIM_VID) $(V)/vdc_ramiface.sv $(O)/vdc/
	patch -s -R -d $(O)/vdc -p1 < $(VP)/vdc856x/row_ram.patch
	patch -s -R -d $(O)/vdc -p1 < $(VP)/vdc856x/busy_pin.patch
	patch -s -R -d $(O)/vdc -p1 < $(VP)/vdc856x/ram_pins.patch
	$(REN) $(O)/vdc/vdc_top.sv > $(O)/vdo_top.sv
	$(REN) $(O)/vdc/vdc_ramiface.sv > $(O)/vdo_ramiface.sv
	$(REN) $(O)/vdc/vdc_video.sv > $(O)/vdo_video.sv
	touch $@

obj_dir/tb_hr_eq: tb_hr_eq.sv $(O)/hr_fn4_old.sv $(HR)/hr_fn4_dram.sv $(ROOT)/rtl/common/c900_dispram.sv
	verilator $(VFLAGS) --top-module tb_hr_eq -Mdir obj_dir/hr -o ../tb_hr_eq $^ > /dev/null

obj_dir/tb_lc_eq: tb_lc_eq.sv $(O)/vdo.stamp $(VDC_SIM_SRCS) $(ROOT)/rtl/common/c900_dispram.sv $(ROOT)/tb/lc_display/vdcram_sim.v
	verilator $(VFLAGS) --top-module tb_lc_eq -Mdir obj_dir/lc -o ../tb_lc_eq tb_lc_eq.sv \
	  $(VDC_SIM_SRCS) $(O)/vdo_top.sv $(O)/vdo_ramiface.sv $(O)/vdo_video.sv \
	  $(ROOT)/rtl/common/c900_dispram.sv $(ROOT)/tb/lc_display/vdcram_sim.v > /dev/null

clean:
	rm -rf obj_dir
