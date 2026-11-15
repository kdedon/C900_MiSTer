// Driver for tb_disk: the 96 MHz SDRAM clock and the 48 MHz clock (half of
// it, rising edges together), and Main_MiSTer on the HPS bus.
// Mounts and sector service follow user_io.cpp (user_io_file_mount,
// the UIO_GET_SDSTAT / UIO_SECTOR_RD / UIO_SECTOR_WR loop), one 16-bit
// word per io_strobe.  Images are read into memory; writes change only
// the in-memory copy.
//   +fd0=, +fd1=, +hd=, +hd1=<file>  images for S0, S1, S2, S3
//   +dump1=<file>     write slot 1's in-memory image to <file> at the end
//   +inreset          mount with the machine in reset, then release it (as
//                     a mount followed by an OSD reset); default: release
//                     at once and mount while it runs
//   +hpsfix=<n>, +hpsblk=<n>  clocks from a request to its transfer: n +
//                     n per block (default 24000 + 8250: with the bus
//                     transfer, about 8 ms per 16 KB, as measured)
//   +strobe=<n>       clocks per HPS bus word (default 6)
//   +pollgap=<n>      clocks between SD status polls (default 400)
//   +rstpulse=<n>     a machine reset n clocks after the mount
//   +mntat=<n>        mount n clocks after the machine leaves reset (an MGL
//                     <file delay=..>: the BIOS is already running)
//   +mntgap=<n>       n clocks between one slot's mount and the next (an MGL
//                     mounts its files one after another)
//   +mntrev           mount the highest slot first
#include "Vtb_disk.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

static std::unique_ptr<VerilatedContext> ctx;
static std::unique_ptr<Vtb_disk> top;
static int strobe_clks = 6;
static uint64_t ticks = 0;

// One 48 MHz period: four clk_ram edges.
static void tick() {
    top->clk_ram = 1; top->clk = 1; top->eval();
    top->clk_ram = 0; top->eval();
    top->clk_ram = 1; top->clk = 0; top->eval();
    top->clk_ram = 0; top->eval();
    ticks++;
}
static bool finished() { return ctx->gotFinish() || top->done; }

static uint16_t spi_w(uint16_t w) {
    top->io_din = w;
    top->io_strobe = 1;
    tick();
    top->io_strobe = 0;
    for (int i = 1; i < strobe_clks; i++) tick();
    return top->io_dout;
}
static void enable_io() { top->io_enable = 1; tick(); tick(); }
static void disable_io() { top->io_enable = 0; tick(); tick(); tick(); }

struct Img { std::vector<uint8_t> d; bool on = false; };
static Img img[4];
static uint64_t hps_fix = 24000, hps_blk = 8250;

static void load(int s, const char* arg) {
    const char* p = ctx->commandArgsPlusMatch(arg);
    if (!p || !*p) return;
    p = strchr(p, '=') + 1;
    FILE* f = fopen(p, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", p); exit(1); }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    img[s].d.resize(n);
    if (fread(img[s].d.data(), 1, n, f) != (size_t)n) { fprintf(stderr, "short read %s\n", p); exit(1); }
    fclose(f);
    img[s].on = true;
    printf("HPS: slot %d image %s, %ld bytes\n", s, p, n);
}

static void mount(int s) {
    uint64_t size = img[s].d.size();
    enable_io();
    spi_w(0x1d);   // UIO_SET_SDINFO
    spi_w(size & 0xFFFF); spi_w((size >> 16) & 0xFFFF);
    spi_w((size >> 32) & 0xFFFF); spi_w((size >> 48) & 0xFFFF);
    disable_io();
    enable_io();
    spi_w(0x1c);   // UIO_SET_SDSTAT
    spi_w(1 << s);
    disable_io();
    printf("HPS: mounted slot %d at clock %llu\n", s, (unsigned long long)ticks);
}

static uint64_t nrd = 0, nwr = 0;
// One user_io_poll: up to four requests.
static bool poll_sd() {
    bool any = false;
    for (int i = 0; i < 4; i++) {
        enable_io();
        uint16_t c = spi_w(0x16);   // UIO_GET_SDSTAT
        int disk = 0, op = 0, blks = 1;
        uint32_t lba = 0;
        if (c & 0x8000) {
            disk = (c >> 2) & 0xF;
            op = c & 3;
            spi_w(0);
            lba = spi_w(0);
            lba |= (uint32_t)spi_w(0) << 16;
            blks = ((c >> 9) & 0x3F) + 1;
        }
        disable_io();
        if (!op || disk > 3) break;
        any = true;
        for (uint64_t t = 0; t < hps_fix + hps_blk * blks && !finished(); t++) tick();
        uint32_t sz = 512 * blks;
        uint64_t off = (uint64_t)lba * 512;
        Img& m = img[disk];
        if (op == 2) {
            enable_io();
            spi_w(0x18 | (disk << 8));   // UIO_SECTOR_WR
            std::vector<uint8_t> b(sz);
            for (uint32_t k = 0; k < sz; k++) b[k] = spi_w(0) & 0xFF;
            disable_io();
            for (uint32_t k = 0; k < sz && off + k < m.d.size(); k++) m.d[off + k] = b[k];
            nwr++;
        } else if (op & 1) {
            enable_io();
            spi_w(0x17 | (disk << 8));   // UIO_SECTOR_RD
            for (uint32_t k = 0; k < sz; k++) spi_w(off + k < m.d.size() ? m.d[off + k] : 0);
            disable_io();
            nrd++;
        }
        if (finished()) break;
    }
    return any;
}

int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IOLBF, 0);
    ctx = std::make_unique<VerilatedContext>();
    ctx->commandArgs(argc, argv);
    top = std::make_unique<Vtb_disk>(ctx.get());
    const char* a;
    if ((a = ctx->commandArgsPlusMatch("strobe=")) && *a) strobe_clks = atoi(strchr(a, '=') + 1);
    if (strobe_clks < 3) strobe_clks = 3;   // hps_io moves sd_buff_addr 3 clocks after a strobe
    int pollgap = 400;
    if ((a = ctx->commandArgsPlusMatch("pollgap=")) && *a) pollgap = atoi(strchr(a, '=') + 1);
    bool inreset = (a = ctx->commandArgsPlusMatch("inreset")) && *a;
    if ((a = ctx->commandArgsPlusMatch("hpsfix=")) && *a) hps_fix = strtoull(strchr(a, '=') + 1, 0, 10);
    if ((a = ctx->commandArgsPlusMatch("hpsblk=")) && *a) hps_blk = strtoull(strchr(a, '=') + 1, 0, 10);
    load(0, "fd0="); load(1, "fd1="); load(2, "hd="); load(3, "hd1=");

    top->clk = 0; top->clk_ram = 0; top->io_enable = 0; top->io_strobe = 0; top->io_din = 0;
    top->hold = inreset ? 1 : 0;
    top->eval();
    for (int i = 0; i < 100; i++) tick();
    if (!inreset) while (!top->core_rst_n) tick();
    uint64_t mntat = 0;
    if ((a = ctx->commandArgsPlusMatch("mntat=")) && *a) mntat = strtoull(strchr(a, '=') + 1, 0, 10);
    for (uint64_t t = 0; t < mntat && !finished(); t++) tick();
    uint64_t mntgap = 0;
    if ((a = ctx->commandArgsPlusMatch("mntgap=")) && *a) mntgap = strtoull(strchr(a, '=') + 1, 0, 10);
    bool first = true;
    bool rev = (a = ctx->commandArgsPlusMatch("mntrev")) && *a;
    for (int i = 0; i < 4; i++) if (img[rev ? 3 - i : i].on) {
        int s = rev ? 3 - i : i;
        // the machine runs and its requests are served while the next mount waits
        for (uint64_t t0 = ticks; !first && ticks - t0 < mntgap && !finished();)
            if (!poll_sd()) for (int i = 0; i < pollgap && !finished(); i++) tick();
        mount(s);
        first = false;
    }
    if ((a = ctx->commandArgsPlusMatch("rstpulse=")) && *a) {
        // a machine reset n clocks after the mount
        uint64_t n = strtoull(strchr(a, '=') + 1, 0, 10);
        for (uint64_t t = 0; t < n; t++) tick();
        top->hold = 1; tick(); top->hold = 0;
        printf("HPS: reset pulse at clock %llu\n", (unsigned long long)ticks);
    }
    bool held = inreset;
    uint64_t mnt_at = ticks;
    while (!finished()) {
        bool any = poll_sd();
        if (held && ticks - mnt_at > 2000) {
            top->hold = 0;
            held = false;
            printf("HPS: machine reset released at clock %llu\n", (unsigned long long)ticks);
        }
        if (!any) for (int i = 0; i < pollgap && !finished(); i++) tick();
    }
    printf("HPS: %llu block reads, %llu block writes, %llu clocks\n",
           (unsigned long long)nrd, (unsigned long long)nwr, (unsigned long long)ticks);
    if ((a = ctx->commandArgsPlusMatch("dump1=")) && *a) {
        FILE* f = fopen(strchr(a, '=') + 1, "wb");
        if (!f || fwrite(img[1].d.data(), 1, img[1].d.size(), f) != img[1].d.size()) { fprintf(stderr, "dump1 failed\n"); return 1; }
        fclose(f);
    }
    top->final();
    return 0;
}
