// Main and a host for tb_core's LANCE ring (+netpeer=<dir>).
//
// Main's side of the ring, as Main's ring poll does it: word 5 holds the
// MAC, frames move between the slots and the host.
// The host is 10.0.9.1 at 02:00:0a:00:09:01:
//   - answers ARP requests for 10.0.9.1, and once asks who has the
//     address of the first machine that talked to it;
//   - serves the files in dir by TFTP (RRQ to port 69, octet, 512-byte
//     blocks, the next block on its ACK, the last one again after
//     RETX_NS without one, up to 5 times).  IP and UDP checksums are
//     computed, and checked on what arrives;
//   - with np_ipcfg: Main's IP configuration words 8-15, static
//     (10.0.9.2/24, server 10.0.9.1, the file) or BOOTP allowed, and a
//     BOOTP server giving 10.0.9.2, 255.255.255.0, server 10.0.9.1 and
//     the file.
// Frames to the card are padded to 60 bytes, without an FCS: the bridge
// appends it.  +netlog=<file> writes every frame in and out as pcap.
// NETPEER lines on stdout trace the exchange; np_final sums it up.
#include "svdpi.h"
#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

namespace {

typedef std::vector<uint8_t> Frame;

const uint32_t MAGIC = 0x4339454E;   // 'C9EN'
const uint64_t RETX_NS = 200000000;  // 200 ms
const uint8_t HOSTMAC[6] = {0x02, 0x00, 0x0a, 0x00, 0x09, 0x01};
const uint8_t GUESTMAC[6] = {0x00, 0x80, 0x10, 0x5a, 0x09, 0x02};   // word 5
const uint8_t HOSTIP[4] = {10, 0, 9, 1};
const uint8_t GUESTIP[4] = {10, 0, 9, 2};
std::string bootfile;
int n_bootp;

uint64_t ram[8192];
bool on;
std::string dir;
FILE* pcap;
uint64_t now;
uint32_t epoch = 0x100, tx_rd, rx_wr;
std::deque<Frame> rxq;   // to the card

int n_in, n_out, n_bad, n_arpq, n_arpr;
bool asked;              // our ARP request is out
bool answered;           // and answered
uint8_t peer_ip[4], peer_mac[6];
bool have_peer;

// One transfer at a time.
struct Xfer {
    bool on;
    std::string name;
    Frame data;
    uint8_t mac[6], ip[4];
    uint16_t port, tid;
    uint32_t blk;        // block sent, awaiting its ACK
    uint64_t sent_at;
    int tries;
    bool done;
} xf;
uint16_t next_tid = 50000;
int n_xfers_done, n_retx, n_dupack;

uint16_t be16(const uint8_t* p) { return p[0] << 8 | p[1]; }
void put16(uint8_t* p, uint16_t v) { p[0] = v >> 8; p[1] = v; }

uint32_t sum16(uint32_t s, const uint8_t* p, size_t n) {
    for (; n > 1; n -= 2, p += 2) s += be16(p);
    if (n) s += p[0] << 8;
    return s;
}
uint16_t fold(uint32_t s) {
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    return ~s & 0xffff;
}

void log_pcap(const Frame& f) {
    if (!pcap) return;
    uint32_t h[4] = {uint32_t(now / 1000000000), uint32_t(now % 1000000000), uint32_t(f.size()),
                     uint32_t(f.size())};
    fwrite(h, 4, 4, pcap);
    fwrite(f.data(), 1, f.size(), pcap);
    fflush(pcap);
}

std::string ip_str(const uint8_t* p) {
    char b[20];
    snprintf(b, sizeof b, "%u.%u.%u.%u", p[0], p[1], p[2], p[3]);
    return b;
}

void send(Frame f) {
    if (f.size() < 60) f.resize(60, 0);
    log_pcap(f);
    n_out++;
    rxq.push_back(f);
}

Frame ether(const uint8_t* dst, uint16_t type) {
    Frame f(14);
    memcpy(&f[0], dst, 6);
    memcpy(&f[6], HOSTMAC, 6);
    put16(&f[12], type);
    return f;
}

void arp(int op, const uint8_t* tha, const uint8_t* tpa) {
    static const uint8_t bcast[6] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
    Frame f = ether(op == 1 ? bcast : tha, 0x0806);
    const uint8_t h[8] = {0, 1, 8, 0, 6, 4, 0, uint8_t(op)};
    f.insert(f.end(), h, h + 8);
    f.insert(f.end(), HOSTMAC, HOSTMAC + 6);
    f.insert(f.end(), HOSTIP, HOSTIP + 4);
    if (op == 1) f.insert(f.end(), 6, 0);
    else f.insert(f.end(), tha, tha + 6);
    f.insert(f.end(), tpa, tpa + 4);
    send(f);
}

void udp(const uint8_t* mac, const uint8_t* ip, uint16_t sport, uint16_t dport, const Frame& pay) {
    Frame f = ether(mac, 0x0800);
    const size_t n = 28 + pay.size();
    uint8_t h[28] = {0x45, 0, 0, 0, 0, 0, 0x40, 0, 64, 17};
    put16(h + 2, uint16_t(n));
    memcpy(h + 12, HOSTIP, 4);
    memcpy(h + 16, ip, 4);
    put16(h + 10, fold(sum16(0, h, 20)));
    put16(h + 20, sport);
    put16(h + 22, dport);
    put16(h + 24, uint16_t(8 + pay.size()));
    uint32_t s = sum16(0, h + 12, 8) + 17 + 8 + pay.size();
    s = sum16(s, h + 20, 8);
    s = sum16(s, pay.data(), pay.size());
    uint16_t c = fold(s);
    put16(h + 26, c ? c : 0xffff);
    f.insert(f.end(), h, h + 28);
    f.insert(f.end(), pay.begin(), pay.end());
    send(f);
}

void tftp_err(const uint8_t* mac, const uint8_t* ip, uint16_t port, uint16_t code, const char* msg) {
    Frame p(4);
    put16(&p[0], 5);
    put16(&p[2], code);
    p.insert(p.end(), msg, msg + strlen(msg) + 1);
    udp(mac, ip, next_tid++, port, p);
    printf("NETPEER TFTP error %u to %s:%u: %s\n", code, ip_str(ip).c_str(), port, msg);
}

void send_block() {
    const size_t off = size_t(xf.blk - 1) * 512;
    const size_t n = off >= xf.data.size() ? 0 : std::min<size_t>(512, xf.data.size() - off);
    Frame p(4);
    put16(&p[0], 3);
    put16(&p[2], uint16_t(xf.blk));
    p.insert(p.end(), xf.data.begin() + off, xf.data.begin() + off + n);
    udp(xf.mac, xf.ip, xf.tid, xf.port, p);
    xf.sent_at = now;
}

void rrq(const uint8_t* mac, const uint8_t* ip, uint16_t port, const uint8_t* p, size_t n) {
    std::string name, mode;
    size_t i = 2;
    for (; i < n && p[i]; i++) name += char(p[i]);
    for (i++; i < n && p[i]; i++) mode += char(tolower(p[i]));
    printf("NETPEER RRQ \"%s\" mode %s from %s:%u\n", name.c_str(), mode.c_str(), ip_str(ip).c_str(), port);
    if (xf.on && !xf.done && xf.port == port && !memcmp(xf.ip, ip, 4) && xf.name == name) {
        printf("NETPEER RRQ again: transfer restarts\n");
    }
    if (name.empty() || name.find('/') != std::string::npos || name[0] == '.') {
        tftp_err(mac, ip, port, 2, "access violation");
        return;
    }
    if (mode != "octet") {
        tftp_err(mac, ip, port, 0, "octet only");
        return;
    }
    FILE* f = fopen((dir + "/" + name).c_str(), "rb");
    if (!f) {
        tftp_err(mac, ip, port, 1, "file not found");
        return;
    }
    xf = Xfer();
    xf.on = true;
    xf.name = name;
    for (int c; (c = fgetc(f)) != EOF;) xf.data.push_back(uint8_t(c));
    fclose(f);
    memcpy(xf.mac, mac, 6);
    memcpy(xf.ip, ip, 4);
    xf.port = port;
    xf.tid = next_tid++;
    xf.blk = 1;
    send_block();
}

void ack(uint16_t port, uint16_t blk) {
    if (!xf.on || xf.done || port != xf.port) return;
    if (blk != uint16_t(xf.blk)) {
        n_dupack++;
        return;
    }
    const bool last = size_t(xf.blk) * 512 > xf.data.size();
    if (xf.blk % 32 == 0 || last) printf("NETPEER ACK %u\n", blk);
    if (last) {
        xf.done = true;
        n_xfers_done++;
        printf("NETPEER sent \"%s\": %zu bytes, %u blocks, all ACKed\n", xf.name.c_str(), xf.data.size(), xf.blk);
        return;
    }
    xf.blk++;
    xf.tries = 0;
    send_block();
}

void bad(const char* why);

void bootp(const uint8_t* mac, const uint8_t* p, size_t n) {
    if (n < 300 || p[0] != 1 || p[1] != 1 || p[2] != 6) return bad("BOOTP request");
    if (memcmp(p + 28, mac, 6)) bad("BOOTP chaddr is not the frame's source");
    if (memcmp(p + 236, "\x63\x82\x53\x63", 4)) bad("BOOTP magic cookie");
    n_bootp++;
    printf("NETPEER BOOTP request xid %02x%02x%02x%02x\n", p[4], p[5], p[6], p[7]);
    Frame r(300, 0);
    r[0] = 2;
    r[1] = 1;
    r[2] = 6;
    memcpy(&r[4], p + 4, 4);
    memcpy(&r[16], GUESTIP, 4);
    memcpy(&r[20], HOSTIP, 4);
    memcpy(&r[28], mac, 6);
    memcpy(&r[108], bootfile.c_str(), std::min<size_t>(bootfile.size(), 127));
    const uint8_t v[] = {99, 130, 83, 99, 1, 4, 255, 255, 255, 0, 255};
    memcpy(&r[236], v, sizeof v);
    udp(mac, GUESTIP, 67, 68, r);
}

void bad(const char* why) {
    n_bad++;
    printf("NETPEER bad frame: %s\n", why);
}

void from_card(const Frame& f) {
    n_in++;
    log_pcap(f);
    if (f.size() < 60) bad("shorter than 60 bytes");
    if (f.size() < 14) return;
    const uint16_t type = be16(&f[12]);
    if (memcmp(&f[6], GUESTMAC, 6)) bad("source is not the MAC in word 5");
    if (type == 0x0806) {
        if (f.size() < 42) return bad("short ARP");
        const uint8_t* a = &f[14];
        if (be16(a) != 1 || be16(a + 2) != 0x0800 || a[4] != 6 || a[5] != 4) return bad("ARP header");
        if (memcmp(a + 8, &f[6], 6)) bad("ARP sender MAC is not the frame's source");
        const uint16_t op = be16(a + 6);
        if (op == 1 && !memcmp(a + 24, HOSTIP, 4)) {
            n_arpq++;
            printf("NETPEER ARP who-has %s tell %s\n", ip_str(a + 24).c_str(), ip_str(a + 14).c_str());
            if (memcmp(f.data(), "\xff\xff\xff\xff\xff\xff", 6)) bad("ARP request not broadcast");
            arp(2, a + 8, a + 14);
            if (!have_peer) {
                have_peer = true;
                memcpy(peer_ip, a + 14, 4);
                memcpy(peer_mac, a + 8, 6);
            }
            if (!asked) {   // as a host that wants to reply
                asked = true;
                arp(1, nullptr, peer_ip);
            }
        } else if (op == 2) {
            n_arpr++;
            printf("NETPEER ARP reply %s is-at %02x:%02x:%02x:%02x:%02x:%02x\n", ip_str(a + 14).c_str(), a[8],
                   a[9], a[10], a[11], a[12], a[13]);
            if (memcmp(f.data(), HOSTMAC, 6) || memcmp(a + 18, HOSTMAC, 6) || memcmp(a + 24, HOSTIP, 4))
                bad("ARP reply not to us");
            if (asked && !memcmp(a + 14, peer_ip, 4) && !memcmp(a + 8, peer_mac, 6)) answered = true;
        }
        return;
    }
    if (type != 0x0800) return;
    if (!memcmp(f.data(), "\xff\xff\xff\xff\xff\xff", 6) && f.size() >= 42 && f[14 + 9] == 17 &&
        be16(&f[14 + 22]) == 67 && !bootfile.empty()) {
        bootp(&f[6], &f[42], f.size() - 42);
        return;
    }
    if (memcmp(f.data(), HOSTMAC, 6)) return;
    if (f.size() < 14 + 28) return bad("short IP");
    const uint8_t* ip = &f[14];
    const size_t len = be16(ip + 2);
    if (ip[0] != 0x45 || len < 28 || 14 + len > f.size()) return bad("IP header");
    if (fold(sum16(0, ip, 20)) != 0) bad("IP header checksum");
    if (memcmp(ip + 16, HOSTIP, 4) || ip[9] != 17) return;
    const uint8_t* u = ip + 20;
    const size_t ulen = be16(u + 4);
    if (ulen != len - 20) return bad("UDP length");
    if (be16(u + 6)) {
        uint32_t s = sum16(0, ip + 12, 8) + 17 + ulen;
        if (fold(sum16(s, u, ulen)) != 0) bad("UDP checksum");
    }
    const uint16_t sport = be16(u), dport = be16(u + 2);
    const uint8_t* p = u + 8;
    const size_t n = ulen - 8;
    if (n < 4) return bad("short TFTP");
    const uint16_t op = be16(p);
    if (dport == 69 && op == 1) rrq(&f[6], ip + 12, sport, p, n);
    else if (xf.on && dport == xf.tid && op == 4) ack(sport, be16(p + 2));
    else if (op == 5) printf("NETPEER TFTP error from the card: %u\n", be16(p + 2));
    else printf("NETPEER UDP %u -> %u op %u ignored\n", sport, dport, op);
}

}  // namespace

extern "C" int np_init(const char* d, const char* log) {
    dir = d;
    on = true;
    if (*log) {
        pcap = fopen(log, "wb");
        if (!pcap) {
            perror(log);
            exit(1);
        }
        const uint32_t h[6] = {0xa1b23c4d, 0x00040002, 0, 0, 65535, 1};   // ns, Ethernet
        fwrite(h, 4, 6, pcap);
    }
    uint64_t w5 = 0x8000000000000000ull;
    for (int i = 0; i < 6; i++) w5 |= uint64_t(GUESTMAC[i]) << 8 * i;
    ram[5] = w5;
    printf("NETPEER serving %s as %s\n", d, ip_str(HOSTIP).c_str());
    return 1;
}

extern "C" void np_ipcfg(int mode, const char* file) {
    uint8_t b[64] = {'C', '9', 'I', 'P', 0, 1, 0, uint8_t(0x80 | (mode == 1 ? 1 : 2))};
    if (mode == 1) {
        memcpy(b + 8, GUESTIP, 4);
        memset(b + 12, 255, 3);
        memcpy(b + 20, HOSTIP, 4);
        snprintf((char*)b + 24, 40, "%s", file);
    } else {
        bootfile = file;
    }
    for (int i = 7; i >= 0; i--) memcpy(&ram[8 + i], b + 8 * i, 8);
    printf("NETPEER IP configuration %s, file \"%s\"\n", mode == 1 ? "static" : "BOOTP", file);
}

extern "C" long long np_rd(int i) { return (long long)ram[i]; }

extern "C" void np_wr(int i, long long d, char be) {
    for (int b = 0; b < 8; b++)
        if (be >> b & 1) ram[i] = (ram[i] & ~(0xffull << 8 * b)) | (uint64_t(d) & 0xffull << 8 * b);
}

extern "C" void np_poll(long long ns) {
    now = ns;
    if (uint32_t(ram[0] >> 32) != MAGIC) {
        epoch = 0x100;
        return;
    }
    const uint32_t tx_wr = uint32_t(ram[1]);
    uint32_t rx_rd = uint32_t(ram[4]);
    if ((ram[0] & 0xff) != epoch || tx_wr - tx_rd > 8 || rx_wr - rx_rd > 8) {
        epoch = ram[0] & 0xff;
        tx_rd = rx_wr = 0;
        printf("NETPEER ring epoch %u\n", epoch);
    }
    for (; tx_rd != tx_wr; tx_rd++) {
        const uint64_t* s = ram + 0x200 + (tx_rd & 7) * 0x100;
        const uint32_t len = uint32_t(s[0]);
        if (len && len <= 1536) from_card(Frame((const uint8_t*)(s + 1), (const uint8_t*)(s + 1) + len));
    }
    ram[2] = tx_rd;
    if (xf.on && !xf.done && now - xf.sent_at > RETX_NS) {
        if (++xf.tries > 5) {
            printf("NETPEER \"%s\": no ACK for block %u, given up\n", xf.name.c_str(), xf.blk);
            xf.on = false;
        } else {
            n_retx++;
            printf("NETPEER block %u again\n", xf.blk);
            send_block();
        }
    }
    rx_rd = uint32_t(ram[4]);
    while (rx_wr - rx_rd < 8 && !rxq.empty()) {
        const Frame& f = rxq.front();
        uint64_t* s = ram + 0xA00 + (rx_wr & 7) * 0x100;
        memset(s + 1, 0, 0x7f8);
        memcpy(s + 1, f.data(), f.size());
        s[0] = f.size();
        ram[3] = ++rx_wr;
        rxq.pop_front();
    }
}

extern "C" void np_final() {
    printf("NETPEER frames in %d, out %d, bad %d; ARP requests %d, replies %d (ours %s); "
           "transfers done %d, blocks again %d, duplicate ACKs %d\n",
           n_in, n_out, n_bad, n_arpq, n_arpr, !asked ? "not asked" : answered ? "answered" : "unanswered",
           n_xfers_done, n_retx, n_dupack);
    if (pcap) fclose(pcap);
}
