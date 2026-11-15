# tb_lance: the Am7990 card against vectors from the Go LANCE (vec/*.vec,
# made by gen/mkvec.sh).  make SEED=n picks the bus timing seed;
# ARGS adds plusargs (ARGS=+grant_delay=300).
ROOT := ../..
EXP  := $(ROOT)/rtl/expansion
SRCS := $(EXP)/am7990_lance_card.sv $(EXP)/am7990.sv $(EXP)/am7990_dma.sv $(EXP)/am7990_tx.sv $(EXP)/am7990_rx.sv $(EXP)/am7990_silo.sv
VECS := $(wildcard vec/*.vec)
SEED ?= 1

.PHONY: all link crom clean
all: obj_dir/tb_lance link crom
	@for v in $(VECS); do ./obj_dir/tb_lance +vec=$$v +seed=$(SEED) $(ARGS) > obj_dir/run.log 2>&1; \
	  grep -E 'PASS|Fatal' obj_dir/run.log; grep -q '^PASS' obj_dir/run.log || exit 1; done

obj_dir/tb_lance: tb_lance.sv $(SRCS)
	verilator --binary --timing -Wall -Wno-fatal --x-initial unique --top-module tb_lance \
	  -o tb_lance tb_lance.sv $(SRCS) > obj_dir.log 2>&1 || (cat obj_dir.log; exit 1)

# tb_link: the frame ring bridge against Main's side
link: obj_dir/tb_link/tb_link
	@for s in 1 2 3; do ./obj_dir/tb_link/tb_link +seed=$$s > obj_dir/link.log 2>&1; \
	  grep -E 'PASS|Fatal' obj_dir/link.log; grep -q '^PASS' obj_dir/link.log || exit 1; done

obj_dir/tb_link/tb_link: tb_link.sv $(ROOT)/rtl/host/lance_link.sv
	@mkdir -p obj_dir
	verilator --binary --timing -Wall -Wno-fatal --x-initial unique --top-module tb_link --Mdir obj_dir/tb_link \
	  -o tb_link tb_link.sv $(ROOT)/rtl/host/lance_link.sv > obj_dir/link_build.log 2>&1 || (cat obj_dir/link_build.log; exit 1)

# tb_crom: the boot ROM and configuration window
crom: obj_dir/tb_crom/tb_crom
	@for s in 1 2 3; do ./obj_dir/tb_crom/tb_crom +seed=$$s > obj_dir/crom.log 2>&1; \
	  grep -E 'PASS|Fatal' obj_dir/crom.log; grep -q '^PASS' obj_dir/crom.log || exit 1; done

obj_dir/tb_crom/tb_crom: tb_crom.sv $(SRCS)
	@mkdir -p obj_dir
	verilator --binary --timing -Wall -Wno-fatal --x-initial unique --top-module tb_crom --Mdir obj_dir/tb_crom \
	  -o tb_crom tb_crom.sv $(SRCS) > obj_dir/crom_build.log 2>&1 || (cat obj_dir/crom_build.log; exit 1)

clean:
	rm -rf obj_dir obj_dir.log
