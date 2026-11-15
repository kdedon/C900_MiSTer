// tb_fdboard -- the floppy board's firmware reading blocks through the
// 8716 into memory, with Main_MiSTer's side of the sd_* slots here.
//
//   tb_fdboard [--drive 0|1] [--lat CLKS] [--rom FILE] [--hrom FILE] [--nohdc]
//              [--max SEC] [--trace] [--irqlat CLKS] [--grant N]
//              [--nofd] BLK:N [BLK:N ...]
//
// Each BLK:N is one CMD_READ of N blocks from BLK (N=1 repeated R times:
// BLK:1xR, the kernel's one-block-per-command pattern).  The image is
// patByte(lba, i), 2392 blocks.  HPS service: a request is acknowledged
// after --lat clks (default 384000 = 8 ms at 48 MHz), then one byte per
// 2 clks.  Per command: status, time, and the firmware's FindSector
// misses (.TryAgain e80e), WaitSync timeouts (e896), Recalibrates (e637),
// data field retries (e29d, e2ca), INTEN polls (e130), HPS loads and
// `late`.  --rom: the 6508 ROM, or boot1.rom.  The hard disk card (8049
// ROM: --hrom, or boot1.rom; default the --rom file) runs with a blank 20 MB drive on slot 2 unless --nohdc.
// --irqlat: clks from a status to the kernel's out(WDIO,0) (default 1 ms);
// --grant: _CLK samples from /BUSREQ to the grant, minus 1 (default 1).
// Other steps, in order with the reads: FD:D (the boot ROM's probe of
// floppy D: one block, polled), HD:R (R one-block hard disk reads, the
// kernel's way), SDP (the boot ROM's set drive parameters), IDLE:MS, RST:MS
// (_MRESET Low for MS ms, as S1).  --nofd: no floppy image mounted.
// --boot MS: time from the board reset to the first step (default 1000).
// --two: both floppies mounted (drive 1's image is patByte(lba + 5000, i)).
// Writes and checks: W:BLK:N[xR] is CMD_WRITE (data new per command),
// U:D makes floppy D the unit of the steps after it, CHK compares both
// image files with every write so far (block by block).  Reads compare
// with the writes too.
// Exit: 0 every command status 0x80 with the right data, 1 otherwise.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

#include "verilated.h"
#include "Vtb_fdboard.h"

static const long kFdBlocks = 2392;
static const double kClk = 48e6;

static uint8_t patByte(long lba, int i) {
    return (uint8_t)(lba * 131 + i * 7 + (i >> 8) * 13 + (lba >> 8) * 29);
}
static uint8_t wpat(long gen, long lba, int i) {
    return (uint8_t)((gen * 37 + lba * 11 + i * 3 + (i >> 7)) ^ 0x5A);
}

struct Hps {
    std::vector<uint8_t> img[4];
    long latClks = 384000;
    int st = 0, slot = 0, i = 0, n = 0, ph = 0;
    long wait = 0, lba = 0, reads = 0, writes = 0;
    bool rd = false;
    void tick(Vtb_fdboard* t) {
        t->h_buff_wr = 0;
        switch (st) {
        case 0:
            for (int s = 0; s < 4; s++)
                if ((t->h_rd >> s & 1) || (t->h_wr >> s & 1)) {
                    slot = s; rd = t->h_rd >> s & 1; wait = latClks; st = 1;
                    break;
                }
            break;
        case 1:
            if (--wait > 0) break;
            lba = t->h_lba[slot]; n = (int)((t->h_blk_cnt >> (6 * slot) & 63) + 1) * 512;
            t->h_ack = 1u << slot; i = 0; ph = 0; st = rd ? 2 : 3;
            if (rd) reads++; else writes++;
            break;
        case 2:
            if (ph == 0) {
                long a = lba * 512 + i;
                t->h_buff_addr = i;
                t->h_buff_dout = a < (long)img[slot].size() ? img[slot][a] : 0;
                t->h_buff_wr = 1; ph = 1;
            } else { ph = 0; if (++i == n) st = 4; }
            break;
        case 3:
            if (ph == 0) { t->h_buff_addr = i; ph = 1; }
            else if (ph == 1) ph = 2;
            else {
                long a = lba * 512 + i;
                if (a < (long)img[slot].size()) img[slot][a] = t->h_buff_din;
                ph = 0; if (++i == n) st = 4;
            }
            break;
        case 4:
            t->h_ack = 0; st = 0;
            break;
        }
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    setvbuf(stdout, nullptr, _IOLBF, 0);
    int drive = 0;
    long lat = 384000, irqLat = 48000;
    double maxSec = 120;
    bool trace = false, nohdc = false;
    int grantDly = 1;
    std::string hromPath, romPath;
    struct Job { long blk; int n; int rep; char op; };
    bool nofd = false, two = false;
    long bootMs = 1000;
    std::vector<Job> jobs;
    for (int k = 1; k < argc; k++) {
        std::string a = argv[k];
        if (a == "--drive" && k + 1 < argc) drive = atoi(argv[++k]) & 1;
        else if (a == "--lat" && k + 1 < argc) lat = atol(argv[++k]);
        else if (a == "--irqlat" && k + 1 < argc) irqLat = atol(argv[++k]);
        else if (a == "--rom" && k + 1 < argc) romPath = argv[++k];
        else if (a == "--max" && k + 1 < argc) maxSec = atof(argv[++k]);
        else if (a == "--trace") trace = true;
        else if (a == "--nofd") nofd = true;
        else if (a == "--two") two = true;
        else if (a == "--boot" && k + 1 < argc) bootMs = atol(argv[++k]);
        else if (a.rfind("W:", 0) == 0) {
            Job j{0, 1, 1, 'W'};
            if (sscanf(a.c_str() + 2, "%ld:%dx%d", &j.blk, &j.n, &j.rep) < 2) { fprintf(stderr, "bad job %s\n", a.c_str()); return 4; }
            jobs.push_back(j);
        }
        else if (a.rfind("U:", 0) == 0) jobs.push_back({atol(a.c_str() + 2) & 1, 0, 1, 'U'});
        else if (a == "CHK") jobs.push_back({0, 0, 1, 'C'});
        else if (a == "--nohdc") nohdc = true;
        else if (a == "--grant" && k + 1 < argc) grantDly = atoi(argv[++k]) & 15;
        else if (a == "--hrom" && k + 1 < argc) hromPath = argv[++k];
        else if (a.rfind("--", 0) == 0) { fprintf(stderr, "unknown option %s\n", a.c_str()); return 4; }
        else if (a.rfind("FD:", 0) == 0) jobs.push_back({atol(a.c_str() + 3) & 1, 1, 1, 'F'});
        else if (a.rfind("HD:", 0) == 0) jobs.push_back({0, 1, atoi(a.c_str() + 3), 'H'});
        else if (a == "SDP") jobs.push_back({0, 0, 1, 'P'});
        else if (a.rfind("IDLE:", 0) == 0) jobs.push_back({atol(a.c_str() + 5), 0, 1, 'I'});
        else if (a.rfind("RST:", 0) == 0) jobs.push_back({atol(a.c_str() + 4), 0, 1, 'X'});
        else {
            Job j{0, 1, 1, 'R'};
            if (sscanf(a.c_str(), "%ld:%dx%d", &j.blk, &j.n, &j.rep) < 2) { fprintf(stderr, "bad job %s\n", a.c_str()); return 4; }
            jobs.push_back(j);
        }
    }
    if (romPath.empty()) { fprintf(stderr, "need --rom FILE (the 6508 ROM or boot1.rom)\n"); return 4; }
    if (hromPath.empty()) hromPath = romPath;
    std::ifstream rf(romPath, std::ios::binary);
    std::vector<uint8_t> rom((std::istreambuf_iterator<char>(rf)), std::istreambuf_iterator<char>());
    if (rom.size() == 0x4000) rom.resize(0x2000);
    if (rom.size() != 8192) { fprintf(stderr, "ROM %s: %zu bytes\n", romPath.c_str(), rom.size()); return 4; }

    std::ifstream hf(hromPath, std::ios::binary);
    std::vector<uint8_t> hrom((std::istreambuf_iterator<char>(hf)), std::istreambuf_iterator<char>());
    if (hrom.size() == 0x4000) hrom = std::vector<uint8_t>(hrom.begin() + 0x2000, hrom.begin() + 0x2800);
    if (hrom.size() != 2048) { fprintf(stderr, "8049 ROM %s: %zu bytes\n", hromPath.c_str(), hrom.size()); return 4; }
    const long kHdBytes = 21307392;

    Vtb_fdboard* top = new Vtb_fdboard;
    Hps hps;
    hps.latClks = lat;
    // model[d]: the image as every write so far leaves it
    std::vector<uint8_t> model[2];
    for (int d = 0; d < 2; d++) {
        if (d != drive && !two) continue;
        hps.img[d].resize(kFdBlocks * 512);
        for (long l = 0; l < kFdBlocks; l++)
            for (int i = 0; i < 512; i++) hps.img[d][l * 512 + i] = patByte(l + (d ? 5000 : 0), i);
        model[d] = hps.img[d];
    }
    int unit = drive;
    long wgen = 0;

    long clks = 0;
    long cTry = 0, cWsTo = 0, cRecal = 0, cCsum = 0, cAm = 0, cFind = 0, cSeekMis = 0, cInten = 0, cCmdRd = 0, cIrq = 0;
    unsigned prevA = 0;
    long lastLoads = 0;
    auto clock = [&]() {
        clks++;
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
        hps.tick(top);
        top->eval();
        unsigned a = top->cpu_pc;
        if (a != prevA) {
            switch (a) {
            case 0xe80e: cTry++; break;
            case 0xe896: cWsTo++; break;
            case 0xe637: cRecal++; break;
            case 0xe29d: cCsum++; break;
            case 0xe2ca: cAm++; break;
            case 0xe82b: cFind++; break;
            case 0xe869: cSeekMis++; break;
            case 0xe130: cInten++; break;
            case 0xe2a6: cCmdRd++; break;
            case 0xe14d: if (prevA == 0xffff) cIrq++; break;   // not MotorsOff's RTS dummy read
            }
            if (trace) {
                const char* ev = nullptr;
                switch (a) {
                case 0xe14d: if (prevA == 0xffff) ev = "IRQ"; break;
                case 0xe136: ev = "INTEN high"; break;
                case 0xe6ab: ev = "StartDrive"; break;
                case 0xe78c: ev = "steps done, spin-up wait"; break;
                case 0xe82b: ev = "FindSector"; break;
                case 0xe2bc: ev = "data sync"; break;
                case 0xe197: ev = "status"; break;
                case 0xe637: ev = "Recalibrate"; break;
                }
                if (ev) printf("  %9.3f ms %04x %s\n", clks / kClk * 1e3, a, ev);
            }
            prevA = a;
        }
        static unsigned lastM = 0, lastI = 1;
        if (trace && (top->mtron != lastM || top->inten_o != lastI)) {
            printf("  %9.3f ms pc %04x mtron %d inten %d\n", clks / kClk * 1e3, a, top->mtron, top->inten_o);
            lastM = top->mtron; lastI = top->inten_o;
        }
        if (trace && clks % 24000000 == 0)
            printf("  %9.3f ms pc %04x inten %d ireq_n %d mtron %d\n", clks / kClk * 1e3, a, top->inten_o, top->ireq_n, top->mtron);
        if (trace && hps.reads != lastLoads) {
            printf("  %9.3f ms HPS load lba %ld\n", clks / kClk * 1e3, hps.lba);
            lastLoads = hps.reads;
        }
    };
    auto run = [&](long n) { for (long c = 0; c < n; c++) clock(); };

    // reset, firmware, mount
    top->rst_n = 0; top->board_reset_n = 0; top->io6 = 0; top->io_ds_n = 1; top->io_ad = 0xFFFF;
    top->m_we = 0; top->img_mounted = 0; top->h_ack = 0; top->h_buff_wr = 0; top->hdc_off = nohdc; top->grant_dly = grantDly;
    run(4);
    top->rst_n = 1;
    for (int a = 0; a < 8192; a++) { top->rom_we = 1; top->rom_addr = a; top->rom_data = rom[a]; clock(); }
    top->rom_we = 0;
    for (int a = 0; a < 2048; a++) { top->hrom_we = 1; top->rom_addr = a; top->rom_data = hrom[a]; clock(); }
    top->hrom_we = 0;
    for (uint32_t a = 0x080000; a < 0x080200; a++) { top->m_we = 1; top->m_addr = a; top->m_wdata = 0; clock(); }
    top->m_we = 0;
    auto mountSlot = [&](int s, uint64_t size) {
        top->img_mounted = 1u << s; top->img_readonly = 0; top->img_size = size;
        run(40);
        top->img_mounted = 0;
        run(100);
    };
    if (!nofd) mountSlot(drive, kFdBlocks * 512);
    if (!nofd && two) mountSlot(!drive, kFdBlocks * 512);
    if (!nohdc) { hps.img[2].assign(kHdBytes, 0); mountSlot(2, kHdBytes); }
    top->board_reset_n = 1;
    run(bootMs * 48000);       // RAM tests, both floppies' Recalibrate, the hard disk's restore

    auto memW = [&](uint32_t a, uint8_t v) { top->m_we = 1; top->m_addr = a; top->m_wdata = v; clock(); top->m_we = 0; };
    auto memR = [&](uint32_t a) { top->m_addr = a; top->eval(); return (uint8_t)top->m_rdata; };
    auto ioWrite = [&](unsigned v) {
        top->io6 = 1; run(16);
        top->io_ad = v; top->io_ds_n = 0; run(8);
        top->io_ds_n = 1; top->io_ad = 0xFFFF; run(8);
        top->io6 = 0; run(8);
    };

    const uint32_t cb = 0x080010, dest = 0x080800;
    bool allOk = true;
    // One command block, polled to completion; the boot ROM's or the kernel's
    // out(WDIO, 0) after irq clks.
    auto cmd = [&](uint32_t b, const uint8_t* c, long irq) {
        for (int i = 0; i < 9; i++) memW(b + i, c[i]);
        memW(b + 0x0c, 0xFF);
        long c0 = clks;
        ioWrite(1);
        uint8_t eb = 0xFF;
        while (clks - c0 < (long)(maxSec * kClk)) {
            run(64);
            if ((eb = memR(b + 0x0c)) != 0xFF) break;
        }
        run(irq);
        ioWrite(0);
        printf("  %9.3f ms  cb %06x op %02x unit %d: status 0x%02x after %.1f ms\n", clks / kClk * 1e3, b, c[0], c[1] >> 5,
               eb, (clks - c0) / kClk * 1e3);
        return eb;
    };
    for (auto& j : jobs) {
        if (j.op == 'F') {
            const uint8_t c[9] = {0x08, (uint8_t)(j.blk << 5), 0, 0, 1, 0, 0x08, 0x04, 0x00};
            for (int t = 0; t < 8 && cmd(0x080010, c, 0) == 0x76; t++) {}
            continue;
        }
        if (j.op == 'H') {
            for (int r = 0; r < j.rep; r++) {
                const uint8_t c[9] = {0x08, 0, (uint8_t)(r >> 8), (uint8_t)r, 1, 0, 0x08, 0x08, 0x00};
                if (cmd(0x080000, c, irqLat) != 0x80) allOk = false;
                run(48000);
            }
            continue;
        }
        if (j.op == 'P') {
            const uint8_t g[6] = {0x0f, 0x42, 0x8c, 0x08, 0x08, 0x11};
            for (int i = 0; i < 6; i++) memW(0x080400 + i, g[i]);
            const uint8_t c[9] = {0x0c, 0, 0, 0, 0, 0, 0x08, 0x04, 0x00};
            cmd(0x080000, c, 0);
            continue;
        }
        if (j.op == 'I') { run((long)(j.blk * 48000)); continue; }
        if (j.op == 'U') { unit = (int)j.blk; continue; }
        if (j.op == 'C') {
            for (int d = 0; d < 2; d++) {
                if (model[d].empty()) continue;
                long nbad = 0;
                for (long l = 0; l < kFdBlocks; l++) {
                    long badAt = -1;
                    for (int i = 0; i < 512 && badAt < 0; i++)
                        if (hps.img[d][l * 512 + i] != model[d][l * 512 + i]) badAt = i;
                    if (badAt >= 0) {
                        if (nbad < 20) printf("    CHK fd%d block %ld differs at byte %ld (image %02x, written %02x)\n", d, l,
                                              badAt, hps.img[d][l * 512 + badAt], model[d][l * 512 + badAt]);
                        nbad++;
                    }
                }
                printf("CHK fd%d %s: %ld blocks differ  wb_busy=%d late=%d\n", d, nbad ? "FAIL" : "ok", nbad, top->wb_busy, top->late);
                if (nbad) allOk = false;
            }
            continue;
        }
        if (j.op == 'X') {
            printf("  %9.3f ms  _MRESET Low %ld ms\n", clks / kClk * 1e3, j.blk);
            top->board_reset_n = 0; run((long)(j.blk * 48000)); top->board_reset_n = 1;
            continue;
        }
        long tc0 = clks, t0Cr = cCmdRd, t0Iq = cIrq, t0In = cInten, t0Try = cTry, t0Ws = cWsTo, t0Rc = cRecal, t0Cs = cCsum, t0Am = cAm, t0Fd = cFind, t0Sm = cSeekMis,
             t0Ld = hps.reads;
        int bad = 0;
        for (int r = 0; r < j.rep; r++) {
            long blk = j.blk + (long)r * j.n;
            bool wr = j.op == 'W';
            if (wr) wgen++;
            for (int i = 0; i < j.n * 512; i++) memW(dest + i, wr ? wpat(wgen, blk + i / 512, i % 512) : 0xA5);
            uint8_t c[8] = {(uint8_t)(wr ? 0x0a : 0x08), (uint8_t)(unit << 5 | (blk >> 16 & 0xF)), (uint8_t)(blk >> 8), (uint8_t)blk,
                            (uint8_t)j.n, 0, 0x08, 0x08};
            for (int i = 0; i < 8; i++) memW(cb + i, c[i]);
            memW(cb + 0x0c, 0xFF);
            long c0 = clks;
            ioWrite(1);
            uint8_t eb = 0xFF;
            while (clks - c0 < (long)(maxSec * kClk)) {
                run(64);
                if ((eb = memR(cb + 0x0c)) != 0xFF) break;
            }
            run(irqLat);   // the kernel takes the /VI, then clears IREQ
            ioWrite(0);
            long badAt = -1;
            if (wr) {
                if (eb == 0x80) for (int i = 0; i < j.n * 512; i++) model[unit][blk * 512 + i] = wpat(wgen, blk + i / 512, i % 512);
            } else {
                for (int i = 0; i < j.n * 512 && badAt < 0; i++)
                    if (memR(dest + i) != model[unit][blk * 512 + i]) badAt = i;
            }
            if (j.rep > 1 || trace)
                printf("    %s fd%d blk %ld n %d: status 0x%02x %.1f ms%s\n", wr ? "W" : "R", unit, blk, j.n, eb, (clks - c0) / kClk * 1e3,
                       badAt >= 0 ? " DATA BAD" : "");
            if (eb != 0x80 || badAt >= 0) { bad++; allOk = false; }
            if (eb == 0xFF) break;
            run(48000);  // the kernel's turnaround, about 1 ms
        }
        printf("%s fd%d %ld:%dx%d %s %.3f s  tryagain=%ld waitsync_to=%ld recal=%ld findsector=%ld seekmistake=%ld "
               "csum=%ld am=%ld inten_polls=%ld irqs=%ld cmd_reads=%ld hps_loads=%ld late=%d\n",
               j.op == 'W' ? "WRITE" : "READ", unit, j.blk, j.n, j.rep, bad ? "FAIL" : "ok", (clks - tc0) / kClk, cTry - t0Try, cWsTo - t0Ws, cRecal - t0Rc,
               cFind - t0Fd, cSeekMis - t0Sm, cCsum - t0Cs, cAm - t0Am, cInten - t0In, cIrq - t0Iq, cCmdRd - t0Cr, hps.reads - t0Ld, top->late);
    }
    top->final();
    printf("RESULT %s\n", allOk ? "PASS" : "FAIL");
    return allOk ? 0 : 1;
}
