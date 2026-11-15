// Clock driver for tb_core: the 96 MHz SDRAM clock, the 48 MHz fabric clock
// (half of it, rising edges together, as from one PLL) and the 65.028 MHz LR
// video clock, free-running with their real periods (time in femtoseconds),
// until $finish.  With +lc the 32 MHz LC card clock too: a toggle every third
// 96 MHz half period, its rises meeting the 48 MHz rises every 62.5 ns.
// Without +lc it stays low, so the unselected card costs no evaluation.
//
// +forks=<file>: runs that share this one's start.  Each line is
//   <Z8001 clock> <log file> [+plusarg ...]
// At that clock the bench forks a child that takes the line's plusargs
// before its own (less the parent's images, which stay mounted, and output
// files), writes its output to the log file and finishes on its own.
// +slots=<dir>: every process (child or not) simulates only while it holds
// one of the lock files <dir>/slot*, so a tree of runs uses at most as many
// cores as there are slot files.  A free slot goes to the waiter with the
// lowest +prio=<n> (default 100).
#include "Vtb_core.h"
#include "Vtb_core___024root.h"
#include "Vtb_core__Dpi.h"
#include "svdpi.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <memory>
#include <sstream>
#include <string>
#include <sys/file.h>
#include <sys/wait.h>
#include <csignal>
#include <unistd.h>
#include <vector>

namespace {

// The parent's images (they stay mounted) and output files.
const char* const kParentOnly[] = {"+fd0=", "+fd1=", "+hd=", "+scctx=", "+dmalog=", "+trace=", "+hrvram=",
                                   "+frame=", "+prn=", "+fdctrace=", "+hdctrace=", "+cbus=", "+stopbytes="};

struct Child {
    int64_t at;
    std::string log;
    std::vector<std::string> args;
};

VerilatedContext* g_ctx;
std::vector<std::string> g_argv;
std::vector<Child> g_children;
size_t g_next = 0;
std::string g_slots;
int g_slot_fd = -1;
bool g_child = false;
int g_ready_fd = -1;

// Waiters announce themselves as <dir>/wait.<prio>.<pid>.
bool first_in_line(int prio) {
    DIR* d = opendir(g_slots.c_str());
    if (!d) { perror(g_slots.c_str()); exit(1); }
    bool first = true;
    while (dirent* e = readdir(d)) {
        int p, pid;
        if (sscanf(e->d_name, "wait.%d.%d", &p, &pid) != 2) continue;
        if (kill(pid, 0) != 0) { unlink((g_slots + "/" + e->d_name).c_str()); continue; }
        if (p < prio) first = false;
    }
    closedir(d);
    return first;
}

bool try_slots() {
    DIR* d = opendir(g_slots.c_str());
    if (!d) { perror(g_slots.c_str()); exit(1); }
    while (dirent* e = readdir(d)) {
        if (strncmp(e->d_name, "slot", 4) != 0) continue;
        int fd = open((g_slots + "/" + e->d_name).c_str(), O_RDONLY | O_CLOEXEC);
        if (fd < 0) continue;
        if (flock(fd, LOCK_EX | LOCK_NB) == 0) { g_slot_fd = fd; closedir(d); return true; }
        close(fd);
    }
    closedir(d);
    return false;
}

void take_slot() {
    if (g_slots.empty()) return;
    const char* ps = g_ctx->commandArgsPlusMatch("prio=");
    const int prio = *ps ? atoi(ps + 6) : 100;
    const std::string me = g_slots + "/wait." + std::to_string(prio) + "." + std::to_string(getpid());
    if (FILE* f = fopen(me.c_str(), "w")) fclose(f);
    usleep(500000);   // runs started together all announce themselves first
    while (!(first_in_line(prio) && try_slots())) usleep(100000);
    unlink(me.c_str());
}

void read_forks(const char* path) {
    FILE* f = fopen(path, "r");
    if (!f) { perror(path); exit(1); }
    char line[4096];
    while (fgets(line, sizeof line, f)) {
        std::istringstream s(line);
        Child c;
        if (!(s >> c.at >> c.log)) continue;
        for (std::string a; s >> a;) c.args.push_back(a);
        g_children.push_back(c);
    }
    fclose(f);
    for (size_t i = 1; i < g_children.size(); ++i)
        if (g_children[i].at < g_children[i - 1].at) {
            fprintf(stderr, "%s: clocks out of order\n", path);
            exit(1);
        }
}

// Forks every child due at the current fork clock: true in a child (its
// plusargs now first), false in the parent.
bool do_forks() {
    const int64_t at = g_children[g_next].at;
    for (; g_next < g_children.size() && g_children[g_next].at == at; ++g_next) {
        fflush(nullptr);
        int ready[2];
        if (pipe(ready) != 0) { perror("pipe"); exit(1); }
        const pid_t pid = fork();
        if (pid < 0) { perror("fork"); exit(1); }
        if (pid > 0) {   // wait until the child has copied the logs written so far
            char b;
            close(ready[1]);
            if (read(ready[0], &b, 1) != 1) { fprintf(stderr, "fork: child failed\n"); exit(1); }
            close(ready[0]);
            continue;
        }
        close(ready[0]);
        g_ready_fd = ready[1];
        const Child& c = g_children[g_next];
        if (!freopen(c.log.c_str(), "w", stdout)) { perror(c.log.c_str()); _exit(1); }
        if (g_slot_fd >= 0) close(g_slot_fd);   // the parent's lock stays
        g_slot_fd = -1;
        std::vector<std::string> a{g_argv[0]};
        a.insert(a.end(), c.args.begin(), c.args.end());
        for (size_t i = 1; i < g_argv.size(); ++i) {
            const std::string& s = g_argv[i];
            bool own = false;
            for (const char* k : kParentOnly) own |= s.rfind(k, 0) == 0;
            if (!own) a.push_back(s);
        }
        std::vector<const char*> p;
        for (const auto& s : a) p.push_back(s.c_str());
        g_ctx->commandArgs(static_cast<int>(p.size()), p.data());
        g_children.clear();
        g_next = 0;
        g_child = true;
        return true;
    }
    return false;
}

}  // namespace

int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IOLBF, 0);    // long runs are watched through a file
    auto ctx = std::make_unique<VerilatedContext>();
    ctx->commandArgs(argc, argv);
    g_ctx = ctx.get();
    g_argv.assign(argv, argv + argc);
    if (const char* f = ctx->commandArgsPlusMatch("forks="); *f) read_forks(f + 7);
    if (const char* s = ctx->commandArgsPlusMatch("slots="); *s) g_slots = s + 7;
    take_slot();
    auto top = std::make_unique<Vtb_core>(ctx.get());
    const uint64_t half_ram = 5208333;    // fs, 96 MHz
    const uint64_t half_vid = 7688996;    // fs, 65.028 MHz
    uint64_t t_ram = half_ram, t_vid = half_vid;
    const bool lc = ctx->commandArgsPlusMatch("lc")[0] != '\0';
    uint64_t n_ram = 0;
    top->clk = 0;
    top->clk_ram = 0;
    top->clk_vid = 0;
    top->clk_vdc = 0;
    top->eval();
    while (!ctx->gotFinish()) {
        uint64_t t = t_ram < t_vid ? t_ram : t_vid;
        if (t_ram == t) {
            top->clk_ram = !top->clk_ram;
            if (top->clk_ram) top->clk = !top->clk;
            if (lc && n_ram % 3 == 0) top->clk_vdc = !top->clk_vdc;
            n_ram++;
            t_ram += half_ram;
        }
        if (t_vid == t) { top->clk_vid = !top->clk_vid; t_vid += half_vid; }
        top->eval();
        if (g_next < g_children.size() && top->rootp->tb_core__DOT__zcyc >= g_children[g_next].at &&
            do_forks()) {
            svSetScope(svGetScopeFromName("TOP.tb_core"));
            tb_child_cfg();
            if (write(g_ready_fd, "r", 1) != 1) _exit(1);
            close(g_ready_fd);
            take_slot();
        }
    }
    top->final();
    fflush(nullptr);
    if (g_child) _exit(0);   // the parent's worker threads do not exist here: no destructors
    if (g_slot_fd >= 0) close(g_slot_fd);
    while (wait(nullptr) > 0) {}   // the children's logs are complete when this exits
    return 0;
}
