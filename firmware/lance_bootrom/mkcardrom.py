#!/usr/bin/env python3
"""Card boot ROM image from the linked l.out.

    mkcardrom.py ndrom.out boot2.rom

Image: the text padded to 1 KB, then the initialised data.  The board
takes A9:A8 from the offset, so the data segment starts on 1 KB.
Fills the header crt.s starts with: length in words, checksum (the
image's words sum to 0), text pages.  The image must fit the 12 KB
window, and text, data, bss and a 4 KB stack the 36 KB the BIOS gives
the card ROM.
"""
import struct
import sys

WINDOW = 12288
ROOM = 0x9000
STACK = 0x1000


def main():
    src, dst = sys.argv[1], sys.argv[2]
    f = open(src, 'rb').read()
    magic, flag, machine, tbase = struct.unpack_from('<HHHH', f, 0)
    sizes = []
    for i in range(9):
        hi, lo = struct.unpack_from('<HH', f, 8 + 4 * i)
        sizes.append(hi << 16 | lo)
    hi, lo = struct.unpack_from('<HH', f, 0x2c)
    entry = hi << 16 | lo
    if magic != 0o407 or machine != 4 or flag & 0x02 == 0:
        sys.exit('%s: not a separated Z8001 l.out' % src)
    shri, prvi, bssi, shrd, prvd, bssd = sizes[:6]
    if bssi:
        sys.exit('%s: text bss' % src)
    text = f[tbase:tbase + shri + prvi]
    data = f[tbase + shri + prvi:tbase + shri + prvi + shrd + prvd]
    if text[0:4] != b'C9NR':
        sys.exit('%s: no C9NR header' % src)
    tp = (len(text) + 1023) // 1024 * 4
    img = bytearray(text + bytes(tp * 256 - len(text)) + data)
    if len(img) & 1:
        img.append(0)
    if len(img) > WINDOW:
        sys.exit('image %d bytes, over the %d-byte window' % (len(img), WINDOW))
    if tp * 256 + shrd + prvd + bssd + STACK > ROOM:
        sys.exit('text, data and bss %d bytes, over %d' % (tp * 256 + shrd + prvd + bssd, ROOM - STACK))
    ent, seg = struct.unpack_from('>HH', img, 8)
    if seg != entry >> 24 or ent != entry & 0xffff:
        sys.exit('header entry %02x:%04x, l.out %08x' % (seg, ent, entry))
    struct.pack_into('>H', img, 6, len(img) // 2)
    struct.pack_into('>H', img, 16, tp)
    struct.pack_into('>H', img, 14, 0)
    s = sum(struct.unpack('>%dH' % (len(img) // 2), img)) & 0xffff
    struct.pack_into('>H', img, 14, -s & 0xffff)
    open(dst, 'wb').write(img)
    print('%s: %d bytes (text %d, %d pages; data %d; bss %d), entry %02x:%04x' %
          (dst, len(img), len(text), tp, shrd + prvd, bssd, seg, ent))


main()
