# LANCE Ethernet card (INVENTED)

No C900 Ethernet card shipped. This card, its boot ROM and the link to
the MiSTer's Linux side are the core's own. Approvals: DEC D-USR-3
(I/O 0x0700), D-BUS-4 and D-BUS-5 (chain and grant positions), D-MEM-9
(DRAM read point under a held /MREQ), D-ROM-4 and D-ROM-5 (boot ROM,
load and jump, `boot2.rom`), D-BLD-8 (RAM placement). Off by default
and held in reset with outputs masked when off [DEC D-OSD-3].

Sources: [TM] AMD Am7990 LANCE Technical Manual (1986, 06363A), by
page; rtl/expansion/am7990*.sv, rtl/host/lance_link.sv, C900.sv,
firmware/lance_bootrom/, scripts/mister/c9netsrv.py, tb/lance/,
tb/core/netboot.sh and netrom.sh. The chip itself follows the manual
and is not described here (theory/README.md).

```
  Z-Bus CN11                 card                        cable side          Linux
  AD /AS /DS R/W B/W ST  <-> glue <-> am7990 <-> TX TENA  <-> lance_link <-> DDR3 ring <-> Main <-> eth0 / tap0
  /BUSREQ /BAI /BAO /WAIT   PROM, strap, TCLK   RX RENA RCLK   (transceiver)
  /VI IEI IEO               ROM window          CLSN
```

## 1. Files

| file | what |
|---|---|
| rtl/expansion/am7990.sv, _dma, _silo, _tx, _rx | the chip: CSRs, init block, ring sequencer, bus-master cycles, 48-byte silo, serializer, deserializer |
| rtl/expansion/am7990_lance_card.sv | the card: decode, station PROM, vector strap, ROM window, Z-Bus mapping, TCLK |
| rtl/host/lance_link.sv | cable side: transceiver and the frame ring to Main in DDR3 |
| C900.sv | OSD bits, `boot2.rom` load, `C900_NO_LANCE` |
| firmware/lance_bootrom/ | the card's boot ROM (BOOTP, ARP, TFTP), `make` -> `build/boot2.rom` |
| scripts/mister/c9netsrv.py | BOOTP + TFTP server for tap0 on the MiSTer |

## 2. Register map (word I/O, ST 0010 or 0011)

The port address is latched from AD while /AS is Low; byte cycles are
ignored [am7990_lance_card.sv:110-120].

| port | r/w | what | source |
|---|---|---|---|
| 0x0700 | RW | RDP (ADR = A1 = 0) | card.sv:117, 183 |
| 0x0702 | RW | RAP | card.sv:117, 183 |
| 0x0710/12/14 | R | station PROM, MAC bytes 0-1, 2-3, 4-5, earlier byte in D15:8; Main's MAC when it has sent one, else 02:60:8C:0C:09:00 | card.sv:28, 122-131 |
| 0x0718 | W | ROMA: window word address, 14 bits | card.sv:119, 143 |
| 0x071A | R | ROMD: the word at ROMA; ROMA + 1 after each read | card.sv:120, 144 |

Window: words 0x0000-0x17FF the boot ROM (12 KB, 6K x 16 M10K), 0xFFFF
until `boot2.rom` has loaded; 0x3FE0-0x3FFF the IP configuration (ring
words 8-15, 32 x 16 MLAB), 0xFFFF until Main has set word 8 bit 63;
every other word 0xFFFF [card.sv:148-171]. A card not fitted does not
answer, so a BIOS probe reads 0xFFFF either way.

Interrupt: /VI = /INTR; the card is last in the chain (IEI from the
display card's IEO, [DEC D-BUS-4]); IEO = IEI while /INTR is High; an
acknowledge with IEI High at the /DS fall puts the strap 0x88 on AD7:0
[card.sv:29, 189-219, 233-234]. /WAIT is held from the /DS fall of a
slave access until the chip's /READY [card.sv:228].

## 3. Bus master

The chip runs with CSR3 = 7 (ACON, BCON, BSWP), so its pins map onto
the Z-Bus as [TM 3.3] Figure 3-2 draws for a Z8001 [card.sv:14-22,
222-231]:

| Am7990 | Z-Bus |
|---|---|
| ALE/AS | /AS |
| /DAS | /DS |
| READ | R/W |
| BYTE | B/W |
| /BUSRQ (open drain, reads the line back) | /BUSREQ |
| /HLDA | /BAI, from the 8716's /BAO [DEC D-BUS-5] |
| /BUSAKO | /BAO (passed through when the card is off) |
| /READY | /WAIT |

- Address: A23:16 go out on the lines the 8716's DMA address uses and
  bypass the MMU; the driver gives physical buffer addresses. ST reads
  1000 [card.sv:229].
- /MREQ is Low for the whole grant while the chip's own /BUSRQ is Low
  and /BAI has reached it (the [TM 3.3.1] Z8K90 PAL's M = HLDA); a grant
  passed down the chain is not ours [card.sv:227]. The DRAM re-arms its
  read at each /AS fall and takes the address at the /AS rise [DEC
  D-MEM-9].
- Tenures: buffer data in bursts of up to 8 words, descriptor and
  init-block words one per tenure [TM 1.8.6, p.1-16].
- TCLK, the chip clock and bit clock, is 10 MHz: the on-card SIA's 20 MHz
  crystal halved, made as a phase accumulator, 5 edges per 12 master
  clocks [card.sv:84-106]. RCLK = TCLK from the transceiver.

## 4. Boot ROM: load and jump [DEC D-ROM-4]

The network stack lives on the card, not in the system BIOS. The ROM
fetches one named file and hands it to the BIOS block by block; the
BIOS loads it as any boot program and jumps. Nothing is handed on: the
ROM writes no C9RC field; a program that needs its address does BOOTP
again or reads the configuration window.

Image [crt.s:1-31, mkcardrom.py]: text padded to 1 KB (a segment
base's A9:A8 come from the offset, not the MMU), then the initialised
data; at most 12 KB; text, data, bss and a 4 KB stack within the 36 KB
the BIOS gives it. Header, words, big-endian as the CPU reads them:

| word | field |
|---|---|
| 0-1 | "C9NR" |
| 2 | version 1 |
| 3 | length in words |
| 4 | entry offset |
| 5 | text segment the image is linked for (0x28; data 0x29) |
| 6 | flags, 0 |
| 7 | checksum: the image's words sum to 0 |
| 8 | text pages, the card's own |

Protocol with the BIOS (the BIOS side is in the BIOS repository; the
ROM side is nd.c and crt.s):

1. The BIOS writes 0 to ROMA, reads the header from ROMD, copies the
   image with INIR to physical `rc_rsvd_seg`:4000, checks the sum, maps
   the text segment onto the copy and far-calls
   `struct ndev *init(struct romconf *rp, char *jt, unsigned work)` in
   the MWC convention (arguments right to left, result in RR0); `work`
   is the copy's page. `init` maps the data segment past the text,
   zeroes its bss, reads the MAC from the PROM, starts nothing and
   returns the device record or 0 [crt.s:33-55, nd.c cinit].
2. Record [nd.h struct ndev]: "C9ND", version 1, name "nd", unit
   offset 4, far pointers `char *open(char *arg)`,
   `int read(int unit, long blk, char *buf)`, `char *info()`.
3. `(le)[server:]file`: the BIOS calls `open`. The ROM reads the
   configuration window; with a valid static block it uses it, else
   with the BOOTP flag it asks BOOTP (4 tries), else fails "no IP
   configuration". It starts the LANCE, ARPs the server (or the
   gateway), sends the TFTP read request for the file (empty: the
   configured or BOOTP file), takes block 1 and stops the LANCE
   [nd.c copen, net.c bootp, tfopen].
4. `read(unit, blk, buf)`: file block `blk` (0 = first 512 bytes), the
   last zero-padded; 1, or 0 past the end or on a failure (the ROM
   prints why). The next block ACKs the held one; the same block comes
   from the held copy; an earlier block re-reads the file from its
   start (new RRQ from a new local port, 1069 up, so stray blocks of
   the old transfer are dropped); a later one skips forward. The LANCE
   runs only inside `open` and `read`, so nothing DMAs into RAM after
   the jump [nd.c cread, net.c:243-335].
5. `info()`: one line for the monitor: MAC, then IP, mask, gateway,
   server and file [nd.c cinfo].

Every entry switches to the card's own stack, from the end of its 36 KB
down, and back to the BIOS's for C9JT services (`putchar`, `puts` only);
R0-R5 are the only registers an entry changes [crt.s:57-80]. Waits use
CIO 1 counter/timer 2 as the BIOS's do [nd.c:9].

Configuration block, window words 0x3FE0-0x3FFF, network byte order
[nd.h, nd.c rdcfg, copen]:

| byte | field |
|---|---|
| 0-3 | "C9IP" |
| 4-5 | version 1 |
| 6-7 | flags: bit 0 static valid, bit 1 BOOTP allowed, bit 7 block valid (ring word 8 bit 63) |
| 8-11, 12-15, 16-19, 20-23 | IP, mask, gateway (0: none), TFTP server |
| 24-63 | boot file name, NUL-padded (39 characters used) |

Build: `make -C firmware/lance_bootrom` with the Z8001 cross toolchain
(`TC=`), link `-R 0x28000000`, `mkcardrom.py` fills length, checksum
and text pages [Makefile]. `boot2.rom` is loaded by stock Main at
ioctl index 0x80 into the window, a byte at a time [C900.sv:353-357,
419-422; DEC D-ROM-5]; the repository ships no ROM.

## 5. Host link: the frame ring [lance_link.sv:1-34]

`lance_link` is the cable: transceiver and network. It is the core's
only DDRAM user (DDRAM_CLK = clk_sys), so no arbiter.

Transceiver, always while the card is on: RENA and RX echo TENA and TX
half a bit later (external loopback works, LCAR stays clear); CLSN
while TENA is High and a frame from Main is going out; heartbeat on
CLSN 1.0-2.0 us after TENA falls [TM p.1-12, p.4-15]; RCLK = TCLK
[lance_link.sv:77-93].

Ring: 64 KB at byte 0x30400000 (DDRAM word 0x06080000), 64-bit
little-endian words, byte i of a word in bits 8i+7:8i [lance_link.sv:9,
37]. Clear of the scaler frame buffers (0x20000000-0x217FFFFF) and
Main's save-state window (0x3E000000).

| word | owner | meaning |
|---|---|---|
| 0 | core | 'C9EN' (0x4339454E) in 63:32, epoch in 7:0, new at each start |
| 1 | core | tx_wr: frames put in the TX ring (32 bits) |
| 2 | Main | tx_rd: frames taken |
| 3 | Main | rx_wr: frames put in the RX ring |
| 4 | core | rx_rd: frames taken |
| 5 | Main | MAC bytes 0-5 in 47:0, bit 63 valid |
| 8-15 | Main | IP configuration, 64 bytes, word 8 bit 63 valid |
| 0x200 + 0x100 n | core | TX slot n = count mod 8: word 0 length in bytes, then the bytes |
| 0xA00 + 0x100 n | Main | RX slot n, likewise |

- Start: words 1-4 written 0, then word 0 with the next epoch (from 1
  at the core load). Main resets its side on a new epoch or when the
  counters are more than a ring apart.
- Poll: words 2-15 every 20 us; 2-7 in one burst, then 8-15 one at a
  time, each passed to the card's configuration RAM as four 16-bit
  halves [lance_link.sv:74, 399-437]. Word 5 with bit 63 set replaces
  the PROM contents; word 8 bit 63 validates the configuration window.
  The core never writes words 5 or 8-15.
- TX: the chip's frame is captured whole in a 2 KB buffer, then copied
  word by word, then the length, then tx_wr. The last 4 bytes are the
  FCS when they leave the CRC-32 residue and are not copied (DTCR=1
  frames go whole). Dropped: a frame that collided, finds the ring
  full, meets a copy still running, or is over 1540 bytes
  [lance_link.sv:73, 242].
- RX: when rx_wr != rx_rd the frame is fetched whole, padded with zeros
  to 60 bytes and sent with a computed FCS, 100 quiet bit times after
  the cable was last busy, never while TENA is High; a collision cuts
  it after 32 jam bits and it is sent again; then rx_rd. Lengths 0 or
  over 1536 are skipped.
- The DDR side resets only with the PLL, so a burst is never cut.

## 6. OSD and build switches

- `P1O[19:17] Network interface: None, eth0, eth1, wlan0, tap0`
  (CONF_STR page 1, [C900.sv:82; DEC OSD table 19:17]). None = no card.
  The card is fitted when the value is not 0, sampled while _MRESET is
  Low (`cfg_lance`, [C900.sv:310-326]); `lan_on = lance_en &
  board_reset_n` [c900_core.sv:547].
- `C900_NO_LANCE` leaves the card and `lance_link` out; the OSD row
  stays and reads as None [C900.sv:341, 572-587].
- Resources: 12 M10K ROM window, MLAB configuration, 4 M10K frame
  buffers [DEC D-BLD-8; lance_link.sv:99-100].

## 7. What Main must do

Stock Main_MiSTer polls this kind of ring only for the MacPPC7300 core
(magic 'PPCE', `support/mac/mac_eth.cpp`), by core name. The C900 ring
keeps its own magic 'C9EN', so networking needs a Main built with C900
support that:

- recognises the core and its magic, opens the interface the OSD names,
  and reopens it when the OSD changes;
- writes word 5 = 00:80:10 (Commodore) + the interface's low three
  bytes, bit 63 set;
- takes TX slots as tx_wr advances, puts frames into RX slots and
  advances rx_wr; resets on a new epoch;
- writes words 8-15 from MiSTer.ini `[C900]` keys `c900_ip=a.b.c.d[/len]`,
  `c900_gw`, `c900_server`, `c900_bootfile` (flags static when
  `c900_ip` parses, else BOOTP).

Main runs a per-core binary from MiSTer.ini (`[C900]` `main=<file under
/media/fat>`), so the stock Main stays for every other core. Without
such a Main the card still works in loopback (the transceiver echo) and
the ring stays unread.

tap0 reaches only the core. `scripts/mister/c9netsrv.py [--dir D]
[--file F] [--if tap0]`, run on the MiSTer after the core loads (Main
makes a new tap0 each load): gives tap0 10.0.9.1/24, answers BOOTP with
10.0.9.2 and the boot file, serves D by TFTP (512-byte blocks, 8 tries
of 1 s per block). A loader that stops reading early leaves "gave up at
block N"; that is normal.

## 8. Benches

- `make -C tb/lance`: `tb_lance` replays 34 vector sets (`vec/*.vec`,
  recorded from the Go Am7990 by `gen/mkvec.sh`, plus directed `d_*`
  sets written from [TM]) through a Z-Bus model with random /WAIT and a
  cable model; `tb_link` runs `lance_link` against a DDR model with
  random BUSY and latency; `tb_crom` checks the ROM window.
- tb_core gate step 16 (`tb/core/gate.sh`): `lance.s` in place of the
  BIOS sends a 32-byte frame to itself in external and internal loopback
  at 6 and 48 MHz: TINT and RINT through vector 0x88, the frame in RAM.
- `tb/core/netboot.sh`: the BIOS fetches a file by ARP and TFTP from
  `netpeer.cpp`, which plays Main on the ring and a host at 10.0.9.1.
- `tb/core/netrom.sh <dir> static|bootp`: the card ROM end to end (hook,
  a 137-block file read whole, past the end, a restart and a skip, then
  an l.out loaded block by block and run).

Not built: MERR, RX chaining and the TX/RX lookahead of [TM p.1-15]
(BUFF instead), TDR, BABL, FRAM, MODE.COLL. Without lookahead each
descriptor read waits for the bus, so the chip tolerates less grant
latency than [TM 2.5.1] computes (`+grant_delay`: all vectors pass to
150 clocks, 3.1 us).
