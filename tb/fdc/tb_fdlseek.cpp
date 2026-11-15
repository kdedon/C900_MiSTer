// tb_fdlseek -- fd_layout reseek check: walk `b` reseeks to the cell walk
// `a` stands on, at random times, with its fetch grants delayed 0-8 clks;
// both get the same platter steps (`adv`, 4-40 clks apart, a seek clk
// never an adv clk).  Wherever both are ready their bits must be equal.
//
//   tb_fdlseek [trials] [seed]
//
// Prints seeks, advs after a seek before b was first ready, mismatching
// cells and the seeks they followed.
// Exit 0 PASS, 1 FAIL.
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include "verilated.h"
#include "Vfdl_pair.h"

static uint32_t rs = 1;
static uint32_t rnd(uint32_t n) { rs = rs * 1103515245u + 12345u; return (rs >> 8) % n; }

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    int trials = argc > 1 ? atoi(argv[1]) : 200;
    rs = argc > 2 ? (uint32_t)atoi(argv[2]) : 1u;
    Vfdl_pair* t = new Vfdl_pair;
    long seeks = 0, notRdy = 0, bad = 0, firstBad = -1, cmp = 0, badSeeks = 0;
    for (int tr = 0; tr < trials; tr++) {
        t->rst_n = 0; t->clk = 0; t->adv = 0; t->seek_a = 0; t->seek_b = 0;
        t->gnt_a = 0; t->gnt_b = 0; t->track = (uint8_t)(rnd(80));
        for (int c = 0; c < 4; c++) { t->clk = 1; t->eval(); t->clk = 0; t->eval(); }
        t->rst_n = 1;
        long cnt = 0, nextAdv = 50, nextSeek = 2000 + rnd(3000), clk = 0;
        int gwait = -1, pendA = 0, pendB = 0;
        uint16_t ra = 0, rb = 0;
        bool started = false, bseen = true, sbad = false;
        long seekClk = -1;
        while (cnt < 15000) {
            t->seek_a = clk == 1; t->seek_b = clk == 1;
            t->pos = 0; t->adv = 0;
            if (clk > 1 && clk == nextSeek) {
                t->seek_b = 1; t->pos = (uint32_t)cnt; seeks++;
                nextAdv = clk + 1 + rnd(400);
                nextSeek = clk + 500 + rnd(6000);
                bseen = false; sbad = false; seekClk = clk;
            } else if (clk == nextAdv) {
                t->adv = 1;
                nextAdv = clk + 4 + rnd(37);
                if (nextAdv == nextSeek) nextAdv++;
            }
            // grants: a at once, b after a random delay
            t->gnt_a = t->req_a;
            if (t->req_b && gwait < 0) gwait = (int)rnd(9);
            t->gnt_b = t->req_b && gwait == 0;
            // checksum bytes from the index; buffer bytes from the address
            t->ck_a = (uint8_t)(t->ckix_a * 37 + 5);
            t->ck_b = (uint8_t)(t->ckix_b * 37 + 5);
            t->rdata_a = (uint8_t)(pendA ? (ra * 131 + (ra >> 8) * 29) : 0);
            t->rdata_b = (uint8_t)(pendB ? (rb * 131 + (rb >> 8) * 29) : 0);
            t->eval();
            if (t->adv) {
                if (t->rdy_a) started = true;
                if (started && t->rdy_a && t->rdy_b) {
                    cmp++;
                    if (t->bit_a != t->bit_b) {
                        bad++; if (firstBad < 0) firstBad = cnt;
                        if (!sbad) { sbad = true; badSeeks++; }
                    }
                }
                if (started && !t->rdy_b && !bseen) notRdy++;
                cnt++;
            }
            if (t->rdy_b && clk > seekClk) bseen = true;
            pendA = t->gnt_a; ra = t->raddr_a;
            pendB = t->gnt_b; rb = t->raddr_b;
            if (t->gnt_b) gwait = -1; else if (gwait > 0) gwait--;
            t->clk = 1; t->eval(); t->clk = 0; t->eval();
            clk++;
        }
    }
    printf("RESULT %s trials=%d seeks=%ld compared=%ld adv_b_not_ready=%ld mismatches=%ld seeks_with_mismatch=%ld first_cell=%ld\n",
           bad ? "FAIL" : "PASS", trials, seeks, cmp, notRdy, bad, badSeeks, firstBad);
    t->final(); delete t;
    return bad ? 1 : 0;
}
