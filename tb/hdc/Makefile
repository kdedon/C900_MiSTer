# Hard disk card benches.
#   make     tb_hd_image: image geometry (raw sizes, fixed VHD footer)
ROOT := ../..
.PHONY: all clean
all: obj_dir/tb_hd_image
	./obj_dir/tb_hd_image

obj_dir/tb_hd_image: tb_hd_image.sv $(ROOT)/rtl/hdc/hd_image.sv
	verilator --binary --timing -Wno-fatal --x-initial unique --top-module tb_hd_image \
	  -o tb_hd_image tb_hd_image.sv $(ROOT)/rtl/hdc/hd_image.sv > /dev/null

clean:
	rm -rf obj_dir
