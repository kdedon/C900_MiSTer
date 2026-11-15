#!/usr/bin/env python3
"""Synthetic disk images for the gate.

  mkimg.py hd <file>   raw 10 MB hard disk, drive type 306 x 4 x 17
  mkimg.py fd <file>   1,224,704-byte C900 floppy image

Every 512-byte block holds a pattern of its block number and offset, so a
block read from the wrong place shows in the DMA log.
"""
import sys

SIZES = {"hd": 306 * 4 * 17 * 512, "fd": 1224704}


def block(n):
    return bytes(((n * 7) + i * 3 + (i >> 8) + (n >> 8)) & 0xFF for i in range(512))


def main():
    kind, path = sys.argv[1], sys.argv[2]
    nblk = SIZES[kind] // 512
    with open(path, "wb") as f:
        for n in range(nblk):
            f.write(block(n))


if __name__ == "__main__":
    main()
