# Printer, IEEE-488 transceiver and speaker benches.
#   make     tb_prn: centronics_printer model on the CN5 lines
#            tb_xcvr: SN75160/SN75161 tables, speaker level
#            tb_scc_rx: SCC async receive under a slow reader (FIFO, overrun)
#   mkprog.py lp|tone: ROM patches for tb/core (+patch=, +prn=, +spk)
ROOT := ../..
V := verilator --binary --timing -Wno-fatal --x-initial unique
.PHONY: all clean
all: obj_dir/tb_prn obj_dir/tb_xcvr obj_dir/tb_scc_rx
	./obj_dir/tb_prn
	./obj_dir/tb_xcvr
	./obj_dir/tb_scc_rx

obj_dir/tb_prn: tb_prn.sv $(ROOT)/rtl/host/centronics_printer.sv
	$(V) --top-module tb_prn -Mdir obj_dir/prn -o ../tb_prn tb_prn.sv \
	  $(ROOT)/rtl/host/centronics_printer.sv > /dev/null

obj_dir/tb_xcvr: tb_xcvr.sv $(ROOT)/rtl/motherboard/sn75160.sv $(ROOT)/rtl/motherboard/sn75161.sv $(ROOT)/rtl/host/speaker_audio.sv
	$(V) --top-module tb_xcvr -Mdir obj_dir/xcvr -o ../tb_xcvr tb_xcvr.sv \
	  $(ROOT)/rtl/motherboard/sn75160.sv $(ROOT)/rtl/motherboard/sn75161.sv $(ROOT)/rtl/host/speaker_audio.sv > /dev/null

SCC := $(ROOT)/rtl/vendor/k8000/k8030_scc
obj_dir/tb_scc_rx: tb_scc_rx.sv $(SCC)/z8030_scc.sv $(SCC)/z8030_scc_channel.sv
	$(V) --top-module tb_scc_rx -Mdir obj_dir/rx -o ../tb_scc_rx tb_scc_rx.sv \
	  $(SCC)/z8030_scc_channel.sv $(SCC)/z8030_scc.sv > /dev/null

clean:
	rm -rf obj_dir
