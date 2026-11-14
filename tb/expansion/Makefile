# Non-stock expansion card benches.
#   make     tb_ramcard: c900_ramcard against the Go card's segment decode
#            (ramcard_sel.txt, from ramcard_sel.go.txt run against the Go simulator)
ROOT := ../..

.PHONY: all clean
all: obj_dir/tb_ramcard
	./obj_dir/tb_ramcard

obj_dir/tb_ramcard: tb_ramcard.sv $(ROOT)/rtl/expansion/c900_ramcard.sv
	verilator --binary --timing -Wall -Wno-fatal --x-initial unique --top-module tb_ramcard \
	  -o tb_ramcard tb_ramcard.sv $(ROOT)/rtl/expansion/c900_ramcard.sv > /dev/null

clean:
	rm -rf obj_dir
