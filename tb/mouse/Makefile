# Host mouse adapter benches.
#   make     tb_mouse: ps2_mouse_quad into the HR card's FN#7, port words
#            against the Go card (mouse_ports.txt, from mouse_ports.go.txt);
#            tb_msys: ps2_mouse_msys, the serial mouse on U74 A, at 400
#            clocks per bit and at the real 40000
ROOT := ../..
HR := $(ROOT)/rtl/hr_display
SRCS := $(ROOT)/rtl/host/ps2_mouse_quad.sv $(HR)/hr_u755.sv $(HR)/hr_pal20x8.sv $(HR)/hr_fn7.sv
MSYS := $(ROOT)/rtl/host/ps2_mouse_msys.sv

.PHONY: all clean
all: obj_dir/tb_mouse obj_dir/tb_msys obj_dir/tb_msys_1200
	./obj_dir/tb_mouse
	./obj_dir/tb_msys
	./obj_dir/tb_msys_1200

obj_dir/tb_mouse: tb_mouse.sv $(SRCS)
	verilator --binary --timing -Wno-fatal --x-initial unique --top-module tb_mouse \
	  -o tb_mouse tb_mouse.sv $(SRCS) > /dev/null

obj_dir/tb_msys: tb_msys.sv $(MSYS)
	verilator --binary --timing -Wno-fatal --x-initial unique --top-module tb_msys \
	  --Mdir obj_dir/msys -o ../tb_msys tb_msys.sv $(MSYS) > /dev/null

obj_dir/tb_msys_1200: tb_msys.sv $(MSYS)
	verilator --binary --timing -Wno-fatal --x-initial unique --top-module tb_msys -GBIT=40000 \
	  --Mdir obj_dir/msys1200 -o ../tb_msys_1200 tb_msys.sv $(MSYS) > /dev/null

clean:
	rm -rf obj_dir
