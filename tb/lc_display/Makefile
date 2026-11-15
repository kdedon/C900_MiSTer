# LC card (8563) bench.
#   make     tb_lc_card: c900_lc_card Z-Bus I/O, 8563 registers and RAM,
#            interrupt, NTSC sync timing, refresh cycles (R36), sync
#            polarity (R37), lc_video pixels into clk_vid (the palette
#            from a GHDL netlist of rgbicolor.vhd)
#            tb_lc_int: interlace (R8 3, 640x400 in 8x16 cells; a 640x400
#            bitmap, one field after the other in RAM) through lc_video,
#            the field flag and the woven fields; R8 1
# The vendored VDC is built from a simulation copy (vdc_sim.patch: the
# block-local initialised clock divider moves to module scope, which
# Verilator would otherwise re-initialise every clock) in obj_dir/vdc.
# -UVERILATOR: the VDC's Verilator branch stubs the row latches.
#   make perf  tb_lc_perf: wb900 lcbench loops, clocks and busy time per
#            operation at 6 MHz and 48 MHz (I/O at ZCLK)
#   make eq  the local 8563 patch changes nothing: tb_patch_expr checks the
#            field-1 vsync column for every R0, R2 and column; tb_patch_eq
#            runs the unpatched 8563 (patch reversed, modules renamed vdo_*)
#            beside the patched one and compares the pins every clock:
#            static frames, then R0/R2 writes at random times; interlaced
#            (R8 3, R8 1) and not.
#            tb_rowram_eq runs the 8563 with its row latches in flip-flops
#            (row_ram.patch reversed, vdr_*) beside the block-RAM version:
#            all pins every clock, the tb_lc_eq column cases, attributes,
#            bitmap mode, scrolling and row lengths at random times.
ROOT := ../..
include $(ROOT)/mk/ghdl.mk
V    := $(ROOT)/rtl/vendor/vdc856x
SIM  := obj_dir/vdc/vdc_top.sv
CARD := $(ROOT)/rtl/lc_display/c900_lc_card.sv $(ROOT)/rtl/lc_display/mos8568.sv \
        $(SIM) $(V)/vdc_signals.sv $(V)/vdc_signals_h.sv $(V)/vdc_signals_v.sv \
        $(V)/vdc_ramiface.sv $(V)/vdc_video.sv $(ROOT)/rtl/common/c900_dispram.sv \
        $(ROOT)/rtl/host/lc_video.sv $(ROOT)/rtl/common/vid_fifo.sv $(ROOT)/rtl/common/c900_sync2.sv $(RGBI_NET)

.PHONY: all eq perf clean
all: obj_dir/tb_lc_card obj_dir/tb_lc_int
	./obj_dir/tb_lc_card
	./obj_dir/tb_lc_card +vdcph
	./obj_dir/tb_lc_int +bmp
	./obj_dir/tb_lc_int +r4=32 +vdcph +bmp

$(SIM): $(V)/vdc_top.sv vdc_sim.patch
	mkdir -p $(dir $@)
	patch -s -o $@.tmp $< vdc_sim.patch
	mv $@.tmp $@

obj_dir/tb_lc_card: tb_lc_card.sv $(CARD)
	verilator --binary --timing -O2 -Wno-fatal -Wno-PROCASSWIRE -UVERILATOR --x-initial unique \
	  --top-module tb_lc_card -Mdir obj_dir/card -o ../tb_lc_card $< $(CARD) > /dev/null

obj_dir/tb_lc_int: tb_lc_int.sv $(CARD)
	verilator --binary --timing -O2 -Wno-fatal -Wno-PROCASSWIRE -UVERILATOR --x-initial unique \
	  --top-module tb_lc_int -Mdir obj_dir/int -o ../tb_lc_int $< $(CARD) > /dev/null

PATCH := $(ROOT)/rtl/vendor_patches/vdc856x/vsync_f1_modulo.patch
EQ    := obj_dir/eq
VFILES := vdc_signals.sv vdc_signals_h.sv vdc_signals_v.sv vdc_ramiface.sv
REN   := sed -E 's/\bvdc_(top|signals_h|signals_v|signals|ramiface|video)\b/vdo_\1/g'

$(EQ)/old.stamp: $(addprefix $(V)/,$(VFILES)) $(SIM) $(PATCH)
	rm -rf $(EQ)/orig && mkdir -p $(EQ)/orig
	cp $(addprefix $(V)/,$(VFILES)) $(V)/vdc_video.sv $(EQ)/orig/
	patch -s -R -d $(EQ)/orig -p1 < $(PATCH)
	for f in $(VFILES); do $(REN) $(EQ)/orig/$$f > $(EQ)/old_$$f; done
	$(REN) $(SIM) > $(EQ)/old_vdc_top.sv
	$(REN) $(EQ)/orig/vdc_video.sv > $(EQ)/old_vdc_video.sv
	touch $@

EQ_NEW := $(SIM) $(addprefix $(V)/,$(VFILES)) $(V)/vdc_video.sv vdcram_sim.v

obj_dir/tb_patch_expr: tb_patch_expr.sv
	verilator --binary -Wno-fatal --top-module tb_patch_expr -Mdir obj_dir/expr -o ../tb_patch_expr $< > /dev/null

obj_dir/tb_patch_eq: tb_patch_eq.sv $(EQ)/old.stamp $(EQ_NEW)
	verilator --binary --timing -O2 -Wno-fatal -Wno-PROCASSWIRE -UVERILATOR --x-initial unique \
	  --top-module tb_patch_eq -Mdir obj_dir/peq -o ../tb_patch_eq tb_patch_eq.sv $(EQ_NEW) \
	  $(addprefix $(EQ)/old_,$(VFILES) vdc_top.sv vdc_video.sv) > /dev/null

ROWP := $(ROOT)/rtl/vendor_patches/vdc856x/row_ram.patch
RREN := sed -E 's/\bvdc_(top|ramiface|video)\b/vdr_\1/g'
$(EQ)/row.stamp: $(SIM) $(V)/vdc_ramiface.sv $(V)/vdc_video.sv $(ROWP)
	rm -rf $(EQ)/rorig && mkdir -p $(EQ)/rorig
	cp $(SIM) $(V)/vdc_ramiface.sv $(V)/vdc_video.sv $(EQ)/rorig/
	patch -s -R -d $(EQ)/rorig -p1 < $(ROWP)
	for f in vdc_top.sv vdc_ramiface.sv vdc_video.sv; do $(RREN) $(EQ)/rorig/$$f > $(EQ)/row_$$f; done
	touch $@

ROW_NEW := $(SIM) $(V)/vdc_signals.sv $(V)/vdc_signals_h.sv $(V)/vdc_signals_v.sv \
           $(V)/vdc_ramiface.sv $(V)/vdc_video.sv vdcram_sim.v
obj_dir/tb_rowram_eq: tb_rowram_eq.sv $(EQ)/row.stamp $(ROW_NEW)
	verilator --binary --timing -O2 -Wno-fatal -Wno-PROCASSWIRE -UVERILATOR --x-initial unique \
	  --top-module tb_rowram_eq -Mdir obj_dir/req -o ../tb_rowram_eq tb_rowram_eq.sv $(ROW_NEW) \
	  $(addprefix $(EQ)/row_,vdc_top.sv vdc_ramiface.sv vdc_video.sv) > /dev/null

eq: obj_dir/tb_patch_expr obj_dir/tb_patch_eq obj_dir/tb_rowram_eq
	./obj_dir/tb_rowram_eq +seed=3
	./obj_dir/tb_rowram_eq +vdcph +seed=5
	./obj_dir/tb_rowram_eq +cth=1 +seed=7
	./obj_dir/tb_rowram_eq +cth=1 +vdcph +seed=9
	./obj_dir/tb_rowram_eq +cth=2 +dbl +seed=13
	./obj_dir/tb_rowram_eq +cth=1 +dbl +vdcph +seed=17
	./obj_dir/tb_rowram_eq +bmp +seed=19
	./obj_dir/tb_rowram_eq +cth=1 +bmp +seed=21
	./obj_dir/tb_rowram_eq +bmp +dbl +vdcph +seed=23
	./obj_dir/tb_patch_expr
	./obj_dir/tb_patch_eq +frames=4 +rw +seed=11 +vsfile=obj_dir/eq_vsync_p.txt
	./obj_dir/tb_patch_eq +frames=4 +rw +im +seed=23 +vsfile=obj_dir/eq_vsync_i.txt
	./obj_dir/tb_patch_eq +frames=3 +rw +ims +seed=97 +vsfile=obj_dir/eq_vsync_s.txt

clean:
	rm -rf obj_dir

PERF := tb_lc_perf.sv $(ROOT)/rtl/lc_display/c900_lc_card.sv $(ROOT)/rtl/lc_display/mos8568.sv \
        $(SIM) $(V)/vdc_signals.sv $(V)/vdc_signals_h.sv $(V)/vdc_signals_v.sv \
        $(V)/vdc_ramiface.sv $(V)/vdc_video.sv $(ROOT)/rtl/common/c900_dispram.sv
obj_dir/tb_lc_perf: $(PERF)
	verilator --binary --timing -O2 -Wno-fatal -Wno-PROCASSWIRE -UVERILATOR --x-initial unique \
	  --top-module tb_lc_perf -Mdir obj_dir/perf -o ../tb_lc_perf $(PERF) > /dev/null
perf: obj_dir/tb_lc_perf
	./obj_dir/tb_lc_perf +tc=8
	./obj_dir/tb_lc_perf +tc=1 +zio
