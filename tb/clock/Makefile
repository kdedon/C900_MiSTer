# Clock benches.
#   make     tb_fantdiv: crystal stand-in edge rates over 0.1 s
ROOT := ../..

.PHONY: all clean
all: obj_dir/tb_fantdiv
	./obj_dir/tb_fantdiv

obj_dir/tb_fantdiv: tb_fantdiv.sv $(ROOT)/rtl/clock/fantdiv.sv
	verilator --binary --timing -Wall -Wno-fatal --x-initial unique --top-module tb_fantdiv \
	  -o tb_fantdiv tb_fantdiv.sv $(ROOT)/rtl/clock/fantdiv.sv > /dev/null

clean:
	rm -rf obj_dir
