#!/usr/bin/env python3
"""BOOTP + TFTP (read only) for the C900 LANCE card on the MiSTer's tap0.

Run on the MiSTer after the C900 core is loaded with Network interface
= tap0 (Main creates tap0 then):

    python3 c9netsrv.py [--dir D] [--file coherent] [--if tap0]

It gives tap0 10.0.9.1/24, answers BOOTP from any client on tap0 with
10.0.9.2 and the boot file, and serves files from D (default: the
current directory) by TFTP.  Nothing leaves the MiSTer: tap0 reaches
only the core.  Main makes a new tap0 at every core load, so start the
server after the load.  A loader that stops reading early leaves the
transfer to time out ("gave up at block N"); that is normal.  Ctrl-C to
stop; it removes the address it added.
"""
import argparse
import os
import select
import socket
import struct
import subprocess
import sys
import time

SRV = "10.0.9.1"
CLI = "10.0.9.2"
MASK = "255.255.255.0"
SO_BINDTODEVICE = 25


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def udp(iface, port, bcast=False):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.SOL_SOCKET, SO_BINDTODEVICE, iface.encode() + b"\0")
    if bcast:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.bind(("0.0.0.0" if bcast else SRV, port))
    return s


def bootp_reply(req, bootfile):
    if len(req) < 240 or req[0] != 1:
        return None
    r = bytearray(300)
    r[0], r[1], r[2] = 2, 1, 6
    r[4:8] = req[4:8]                       # xid
    r[16:20] = socket.inet_aton(CLI)        # yiaddr
    r[20:24] = socket.inet_aton(SRV)        # siaddr
    r[28:34] = req[28:34]                   # chaddr
    f = bootfile.encode()[:127]
    r[108:108 + len(f)] = f
    r[236:240] = b"\x63\x82\x53\x63"
    opt = b"\x01\x04" + socket.inet_aton(MASK) + b"\xff"
    r[240:240 + len(opt)] = opt
    return bytes(r)


def tftp_send(iface, root, peer, fname):
    path = os.path.realpath(os.path.join(root, fname.lstrip("/")))
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, SO_BINDTODEVICE, iface.encode() + b"\0")
    s.bind((SRV, 0))
    if not path.startswith(os.path.realpath(root) + os.sep) or not os.path.isfile(path):
        s.sendto(struct.pack("!HH", 5, 1) + b"file not found\0", peer)
        log("TFTP", peer, fname, "not found")
        return
    data = open(path, "rb").read()
    nblk = len(data) // 512 + 1
    log("TFTP", peer, fname, len(data), "bytes,", nblk, "blocks")
    blk = 1
    while blk <= nblk:
        pkt = struct.pack("!HH", 3, blk & 0xFFFF) + data[(blk - 1) * 512:blk * 512]
        for tries in range(8):
            s.sendto(pkt, peer)
            got = False
            end = time.time() + 1.0
            while time.time() < end:
                rd, _, _ = select.select([s], [], [], max(0, end - time.time()))
                if not rd:
                    break
                m, src = s.recvfrom(600)
                if src != peer or len(m) < 4:
                    continue
                op, n = struct.unpack("!HH", m[:4])
                if op == 4 and n == (blk & 0xFFFF):
                    got = True
                    break
                if op == 5:
                    log("TFTP error from client:", m[4:].split(b"\0")[0])
                    return
            if got:
                break
        else:
            log("TFTP", fname, "gave up at block", blk)
            return
        blk += 1
    log("TFTP", fname, "done")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=".")
    ap.add_argument("--file", default="coherent")
    ap.add_argument("--if", dest="iface", default="tap0")
    a = ap.parse_args()
    if not os.path.isdir("/sys/class/net/" + a.iface):
        sys.exit(a.iface + " does not exist: load the C900 core with Network interface = tap0")
    subprocess.call(["ip", "addr", "add", SRV + "/24", "dev", a.iface])
    subprocess.call(["ip", "link", "set", a.iface, "up"])
    try:
        bs = udp(a.iface, 67, bcast=True)
        ts = udp(a.iface, 69)
        log("serving", a.dir, "on", a.iface, SRV, "boot file", a.file)
        while True:
            rd, _, _ = select.select([bs, ts], [], [])
            if bs in rd:
                m, src = bs.recvfrom(1500)
                r = bootp_reply(m, a.file)
                if r:
                    bs.sendto(r, ("255.255.255.255", 68))
                    log("BOOTP", m[28:34].hex(":"), "->", CLI, a.file)
            if ts in rd:
                m, peer = ts.recvfrom(600)
                if len(m) > 4 and struct.unpack("!H", m[:2])[0] == 1:
                    fname = m[2:].split(b"\0")[0].decode(errors="replace")
                    tftp_send(a.iface, a.dir, peer, fname)
    except KeyboardInterrupt:
        pass
    finally:
        subprocess.call(["ip", "addr", "del", SRV + "/24", "dev", a.iface])


if __name__ == "__main__":
    main()
