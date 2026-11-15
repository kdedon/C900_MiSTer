# Known issues

What a user meets running the 1985 software (boot ROM, Coherent 0.7.3
and the `c900final` hard disk) on this core, and the core's own limits.
Each entry: symptom, cause, what to do. The core matches the real
machine; the stock software is not patched (README). "Newer kernels"
means the OpenCoherent kernels, which this repository does not ship. Sources: kernel source files are the Coherent 0.7.3 tree on the
`c900final` disk (`src/sys/...`); BIOS sources are the decompiled boot
ROM; DEC = DECISIONS.md.

## Stock software

### Two hard disks of different geometry

Symptom: with two hard disk images mounted, the second drive reads and
writes the wrong blocks unless both images have the same cylinders,
heads and sectors.

Cause: the WD1003-CMD's 8049 keeps one parameter set for the card
(internal RAM 0x2E heads, 0x33 sectors per track; theory/chips/HDC_CARD.md
sec. 3) and divides every block number by it. The stock kernel loads
the parameters once, at driver load, for both drives (`drv/wd.c`
`wdload` -> `wdsetparam`; its own comment: "the parameters are used for
both drives by the controller (sorry, no mix and match on drive
types)"), and the values are a compiled-in table (`wdparam`, 612 x 4 x
17). The core gives each image the geometry of its size (`rtl/hdc/hd_image.sv`
header; DEC D-IMG-6), so a second image of another type is addressed
with the first's parameters.

What to do: give both drives the same type (same image size, or the
same CHS in a fixed VHD footer). Newer kernels re-send the parameters
on every drive switch.

### Large RAM cards: video memory taken as RAM, slow memory test

Symptom: with the NON-STOCK RAM card the ROM reports at most 3008K and
Coherent's banner at most about 2.9 MB, whatever the card's size. With
the LR card and 4M or more, the screen and running programs can corrupt
each other. With 8M or 15M the memory test runs 35 s or more before
"Memory test: ... OK" (MiSTer 2026-11-16).

Cause: the boot ROM sizes RAM by testing from segment 0x08 upward until
the first segment fails (`sizeram_`, memtest; theory/FLOWS.md sec. 2
step 1), and the kernel takes that figure (`src/commodore.c`,
`coretop = romconf.rom_eram`). The card leaves 0x37 empty for the LR
card's character RAM, so the count stops there: 2M stops at 0x36
(2976K); 4M, 8M and 15M reach 0x37 (3008K) [DEC D-MEM-8]. With the LR
card fitted, 0x37 answers, so the ROM tests the character RAM and counts
it as memory. The test itself only scribbles on the screen, which a
redraw recovers; the harm is that Coherent then allocates in that
segment, so its data lands in video memory [DEC D-MEM-8]. The test
writes and reads 0x5555 and 0xAAAA through every segment it finds, then
a tag pass against aliasing, at the CPU clock, so a large card takes
long; the time is the ROM's.

What to do: 2M is safe on every display card and tests quickly. 4M to
15M need a BIOS and kernel that know the card; with the stock ROM use
them headless or with the HR card only, and expect the slow test. 512K
with a card leaves 0x10-0x17 empty, so the ROM stops at 512K.

### Reset is an unclean shutdown

Symptom: after a reset or a core reload the next boot finds the root
file system dirty; a newer userland prints "The root file system was
not unmounted cleanly, repairing" and runs its check (MiSTer
2026-11-16).

Cause: Coherent 0.7.3 has no shutdown or halt command (`c900final` has
none; `sync` is `src/cmd/sync.c`) and the boot ROM has no halt. Written
blocks sit in the buffer cache until `/etc/update` or `sync` writes
them, and the superblock is written with the modified flag cleared by
`msync` (`coh/fs2.c`). The core adds its own delay: a cylinder is
written back to the image when the head leaves it or 0.1 s after the
last write [DEC D-IMG-5]. The stock `/etc/rc` mounts hd0-hd3 without a
check (`c900final` `/etc/rc`), so stock Coherent repairs nothing by
itself; the message above is the newer userland's init.

What to do: log out of every session, type `sync` twice, wait for the
disk LED to go out (README, Disk images), then reset. A floppy: `umount`
it and wait for the LED before ejecting.

### The hard disk kernel drives the HR console only

Symptom: booting `c900final` with the LR card, the Coherent banner and
the login appear on the serial line while the LR screen stays at
"Automatic boot in progress" (MiSTer 2026-11-16).

Cause: the kernel's console driver is SCC channel B, polled
(`src/console.c`: "Uses on-board RS-232 port B (SCC channel B) for all
I/O"), so the banner goes to serial on every display card. Init then
loads `/drv/kv` (`md.s` icode; theory/FLOWS.md sec. 9 step 5), the
video and keyboard driver of the install; `c900final` is an HR install
and its `kv` draws the HR bitmap (hrtty; FLOWS sec. 7). INFERRED from
the observation: that `kv` has no LR code.

What to do: use the HR card with `c900final`, or the serial console
(Serial Port = U74 B) with Display Card = None; the LR card needs an LR
install (the LR install floppy's kernel; FLOWS sec. 9 step 3).

### Serial login at 9600 baud shows garbage

Symptom: on `c900final` the serial login prompt on tty50 is unreadable
at the console speed, 9600 baud (MiSTer 2026-11-16).

Cause: the boot ROM and the kernel console run SCC channel B at 9600
baud (TC 17; theory/FLOWS.md sec. 8 step 1), but `/etc/ttys` on
`c900final` is `1Ltty50`: a getty at speed L = 2400 baud
(`src/cmd/getty.c` line 55, `sL` B2400; P is 9600, line 59).

What to do: switch the terminal to 2400 baud when the login prompt is
due, or edit `/etc/ttys` to `1Ptty50` from a working session. Newer
images ship `0Ptty50`.

### The boot ROM has no LC card console

Symptom: with Display Card = LC 8563 the ROM's messages and monitor are
on the serial line only; the LC screen stays blank until the kernel
loads its driver.

Cause: the stock ROM probes 3E:0000 (HR) and 37:0000 (LR) for video
RAM and otherwise takes SCC channel B (theory/FLOWS.md sec. 2 step 3);
it does not know the LC card's ID byte at 0x01FF. The card itself is
NON-STOCK [DEC D-OSD-4].

What to do: watch the serial line during boot, or use a BIOS with the
LC probe (the extended BIOS, not shipped here).

### The ROM boots floppy drive 1 before the hard disk

Symptom: with a floppy image mounted the machine boots from it, not
from the hard disk; the floppy must be in drive 1 (OSD S1).

Cause: the auto-boot sequence is `(fd,1)coherent` first, then
`(hd)coherent` (ROM `command()`; theory/FLOWS.md sec. 2 step 5).

What to do: eject the floppy (or mount it on S0) to boot the hard
disk; a boot floppy goes on S1.

### A copied file on a floppy comes back short

Symptom: after `cp` to a floppy, `sync`, `umount` and remount, a file is
shorter by whole blocks while `df` counts every block (MiSTer
2026-11-09).

Cause: INFERRED, no RTL fault found: a race in the kernel between
`sync` (or `/etc/update`) and a write that is still growing the file;
the inode is written with the old size and never again (theory/FLOWS.md
sec. 3; ROADMAP). Expected on a real C900 too; OPEN.

What to do: do not `sync` while a copy to a floppy runs; let `cp`
finish, then `sync` and `umount`, and check the size.

## The core's limits

- Writes reach the image up to 0.1 s after the last write, or when the
  head leaves the cylinder; the disk LED shows pending writes. Eject or
  switch off only with the LED out [DEC D-IMG-5].
- Hard disk images: a raw image of a C900 drive type, or a fixed VHD
  up to 2047 cylinders x 8 heads x 17 sectors (142.5 MB). Anything else
  is no drive [DEC D-IMG-6; `rtl/hdc/hd_image.sv`].
- Display card, memory and CPU clock changes take effect at the next
  reset (README).
- CPU clocks above 6 MHz are NON-STOCK; see README, CPU clock, and
  theory/SYSTEM.md sec. 2.
