# Host-side benches.
#   make     tb_disk_stream: disk images streamed into BRAM behind hps_io
#            tb_uart_sel: the SCC line on the MiSTer UART, the others idle
ROOT := ../..
.PHONY: all clean
all: obj_dir/tb_disk_stream obj_dir/tb_uart_sel
	./obj_dir/tb_disk_stream
	./obj_dir/tb_uart_sel

obj_dir/tb_disk_stream: tb_disk_stream.sv $(ROOT)/rtl/host/disk_stream.sv $(ROOT)/rtl/fdc/fd_pkg.sv
	mkdir -p obj_dir/ds
	verilator --binary --timing -Wno-fatal --x-initial unique --output-split-cfuncs 0 --top-module tb_disk_stream -Mdir obj_dir/ds \
	  -o ../tb_disk_stream $(ROOT)/rtl/fdc/fd_pkg.sv $(ROOT)/rtl/host/disk_stream.sv tb_disk_stream.sv > /dev/null

obj_dir/tb_uart_sel: tb_uart_sel.sv $(ROOT)/rtl/host/uart_sel.sv
	mkdir -p obj_dir/us
	verilator --binary --timing -Wno-fatal --x-initial unique --top-module tb_uart_sel -Mdir obj_dir/us \
	  -o ../tb_uart_sel $(ROOT)/rtl/host/uart_sel.sv tb_uart_sel.sv > /dev/null

clean:
	rm -rf obj_dir
