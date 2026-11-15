#!/usr/bin/env python3
"""Boot ROM size test images for tb_core, from a 32 KB boot0.rom.

  mkrom64.py <boot0.rom> <rom32.rom> <rom64.rom>

At the reset PC 0x0038, in place of the BIOS:
    ld  r1, <<0>>0x8000     read the upper half's first word
    ld  r2, <<0>>0x0000     and the lower half's
    jp  <<0>>0x8010         run from the upper half
rom32.rom: 32 KB (a 23128 pair).  0x8000 aliases 0x0000.
rom64.rom: 64 KB (a 27256 pair): the lower half is the
same, the upper half holds word 0x8000 + n at word n and, at 0x8010:
    ld  r3, $0x5A5A
    jr  $
"""
import sys

LOW = [0x6101, 0x8000, 0x8000, 0x6102, 0x0000, 0x5E08, 0x8000, 0x8010]
HIGH = [0x2103, 0x5A5A, 0xE8FF]


def put(img, base_h, base_l, word, val):
    img[base_h + word] = val >> 8
    img[base_l + word] = val & 0xFF


def main():
    src, out32, out64 = sys.argv[1:4]
    img = bytearray(open(src, 'rb').read())
    assert len(img) == 0x8000, len(img)
    for i, v in enumerate(LOW):
        put(img, 0x0000, 0x4000, 0x1C + i, v)
    open(out32, 'wb').write(img)

    big = bytearray(0x10000)
    for w in range(0x4000):
        put(big, 0x0000, 0x8000, w, (img[w] << 8) | img[0x4000 + w])
        put(big, 0x0000, 0x8000, 0x4000 + w, 0x8000 + w)
    for i, v in enumerate(HIGH):
        put(big, 0x0000, 0x8000, 0x4008 + i, v)
    open(out64, 'wb').write(big)


if __name__ == '__main__':
    main()
