# LR display card benches.
#   make        scc
#   make card ROM1=<boot1.rom>   c900_lr_card: CRTC programming, CDR, /WAIT,
#               two frames (the character ROM from boot1.rom)
#   make scc    c900_lr_card: U31 and U36 registers, a U36 TX byte, empty socket
ROOT := ../..

LR    := $(ROOT)/rtl/lr_display
VEND  := $(ROOT)/rtl/vendor
CARD_SRCS := \
  $(ROOT)/rtl/common/c900_sync2.sv $(ROOT)/rtl/common/c900_rst_sync.sv \
  $(VEND)/k8000/k800x_cpu/gen/z8000_zbus_pkg.sv \
  $(VEND)/k8000/k8030_scc/z8030_scc_channel.sv $(VEND)/k8000/k8030_scc/z8030_scc.sv \
  $(ROOT)/rtl/lr_display/mc6845/mc6845_synth.v $(ROOT)/rtl/lr_display/mc6845_lrdisp.sv \
  $(wildcard $(LR)/*.sv)

VFLAGS := --binary --timing -Wall -Wno-fatal --x-initial unique --timescale 1ps/1ps

.PHONY: all card scc clean
all: scc

card: obj_card/tb_lr_card
	@[ -f "$(ROM1)" ] || { echo "ROM1=<boot1.rom> needed (scripts/make_boot_rom.sh)"; exit 1; }
	dd if="$(ROM1)" of=obj_card/crom.bin bs=4096 skip=3 count=1 status=none
	./obj_card/tb_lr_card +crom=obj_card/crom.bin

scc: obj_scc/tb_lr_scc
	./obj_scc/tb_lr_scc

obj_scc/tb_lr_scc: tb_lr_scc.sv $(CARD_SRCS)
	verilator $(VFLAGS) -O3 --Mdir obj_scc --top-module tb_lr_scc -o tb_lr_scc \
	  $(ROOT)/lint/vendor.vlt $(CARD_SRCS) tb_lr_scc.sv > /dev/null

obj_card/tb_lr_card: tb_lr_card.sv $(CARD_SRCS)
	verilator $(VFLAGS) -O3 --Mdir obj_card --top-module tb_lr_card -o tb_lr_card \
	  $(ROOT)/lint/vendor.vlt $(CARD_SRCS) tb_lr_card.sv > /dev/null

clean:
	rm -rf obj_card obj_scc
