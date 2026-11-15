# The LANCE card's boot ROM: build/boot2.rom, for the core's folder.
#
#   make          build/boot2.rom (and build/ndrom.out, the link)
#   make test     build/ndhook.out, ndprog.out and ndbig.bin for tb/core netrom.sh
#   make clean
#
# TC: the Z8001 cross toolchain's build directory (as-z8001, ld-z8001,
# z8001/cc0-z8001 .. cc2-z8001); no default.
TC   ?=
CC0   = $(TC)/z8001/cc0-z8001
CC1   = $(TC)/z8001/cc1-z8001
CC2   = $(TC)/z8001/cc2-z8001
AS    = $(TC)/as-z8001
LD    = $(TC)/ld-z8001
VAR   = 800000020800
B     = build

.DELETE_ON_ERROR:
.PHONY: all test clean

all: $(B)/boot2.rom

ifneq ($(MAKECMDGOALS),clean)
ifeq ($(TC),)
$(error set TC to the Z8001 cross toolchain's build directory)
endif
endif

# crt.o first: the header starts the image.
OBJ = $(B)/crt.o $(B)/nd.o $(B)/net.o $(B)/lance.o

$(B)/boot2.rom: $(B)/ndrom.out mkcardrom.py
	python3 mkcardrom.py $< $@

$(B)/ndrom.out: $(OBJ)
	$(LD) -i -L -e init_ -R 0x28000000 -o $@ $(OBJ)

$(B)/%.o: %.c nd.h | $(B)
	$(CC0) $(VAR) $< $(B)/$*.z0 -I. > $(B)/$*.log 2>&1 || (cat $(B)/$*.log; exit 1)
	$(CC1) $(VAR) $(B)/$*.z0 $(B)/$*.z1 >> $(B)/$*.log 2>&1 || (cat $(B)/$*.log; exit 1)
	$(CC2) 0012 $(B)/$*.z1 $@ $(B)/$*.scr 0 >> $(B)/$*.log 2>&1 || (cat $(B)/$*.log; exit 1)

$(B)/%.o: %.s | $(B)
	$(AS) -g -o $@ $<

# A stand-in for the BIOS hook, booted by (le), the boot file it loads
# and a large file.
test: $(B)/boot2.rom $(B)/ndhook.out $(B)/ndprog.out $(B)/ndbig.bin

$(B)/ndhook.out: $(B)/hookcrt.o $(B)/hook.o
	$(LD) -i -L -e start -R 0x30000000 -o $@ $^

$(B)/ndprog.out: $(B)/progcrt.o $(B)/prog.o
	$(LD) -i -L -e start -R 0x32000000 -o $@ $^

$(B)/hook.o $(B)/prog.o: $(B)/%.o: test/%.c nd.h | $(B)
	$(CC0) $(VAR) $< $(B)/$*.z0 -I. > $(B)/$*.log 2>&1 || (cat $(B)/$*.log; exit 1)
	$(CC1) $(VAR) $(B)/$*.z0 $(B)/$*.z1 >> $(B)/$*.log 2>&1 || (cat $(B)/$*.log; exit 1)
	$(CC2) 0012 $(B)/$*.z1 $@ $(B)/$*.scr 0 >> $(B)/$*.log 2>&1 || (cat $(B)/$*.log; exit 1)

$(B)/hookcrt.o $(B)/progcrt.o: $(B)/%.o: test/%.s | $(B)
	$(AS) -g -o $@ $<

$(B)/ndbig.bin: test/mkbig.py
	python3 test/mkbig.py $@

$(B):
	mkdir -p $(B)

clean:
	rm -rf $(B)
