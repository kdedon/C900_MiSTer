#!/usr/bin/env python3
"""Generate SystemVerilog sum-of-products logic from an 82S100 truth-table dump.

The dump is the full 16-input x 8-output table (65536 bytes): byte at index V
holds output pins F7..F0 for input word V (index bit b = input pin Ib).

Each output is minimized on its own support.  The minimizer expands every
uncovered ON minterm to a prime cube (literal removal, ON-set check), then
drops redundant cubes.  The function and its complement are both minimized
and the smaller cover is emitted (the 82S100 has a programmable output
inverter).  The result is checked against the dump before anything is
written.

usage: pla_gen.py <dump.bin> <module> <out.sv> [header-comment-file]
Python 3 standard library only.
"""
import sys


def load(path):
    with open(path, "rb") as f:
        d = f.read()
    if len(d) != 65536:
        sys.exit(f"{path}: {len(d)} bytes, want 65536")
    return d


def support(tab):
    deps = []
    for b in range(16):
        m = 1 << b
        if any(tab[i] != tab[i | m] for i in range(65536) if not i & m):
            deps.append(b)
    return deps


def project(tab, deps):
    """Truth table of one output over its support variables only."""
    n = len(deps)
    out = bytearray(1 << n)
    for v in range(1 << n):
        idx = 0
        for k, b in enumerate(deps):
            if (v >> k) & 1:
                idx |= 1 << b
        out[v] = tab[idx]
    return out


def cube_points(val, dc, n):
    """All minterms of cube (val on care bits, dc = don't-care mask)."""
    free = [k for k in range(n) if (dc >> k) & 1]
    pts = []
    for s in range(1 << len(free)):
        p = val
        for j, k in enumerate(free):
            if (s >> j) & 1:
                p |= 1 << k
        pts.append(p)
    return pts


def minimize(on, n):
    """Greedy prime cover of the ON set of a projected table `on` (0/1)."""
    full = (1 << n) - 1
    ones = [v for v in range(1 << n) if on[v]]
    if not ones:
        return []
    if len(ones) == 1 << n:
        return [(0, full)]
    covered = bytearray(1 << n)
    cubes = []
    # Expand minterms in order of fewest ON neighbours first: tends to pick
    # the essential primes early.
    def nbrs(v):
        return sum(on[v ^ (1 << k)] for k in range(n))
    for m in sorted(ones, key=nbrs):
        if covered[m]:
            continue
        val, dc = m, 0
        # Try dropping each literal; keep the drop if the cube stays ON.
        for k in range(n):
            ndc = dc | (1 << k)
            nval = val & ~ndc
            if all(on[p] for p in cube_points(nval, ndc, n)):
                val, dc = nval, ndc
        cubes.append((val, dc))
        for p in cube_points(val, dc, n):
            covered[p] = 1
    # Irredundant pass: drop a cube whose points are all covered by others.
    cnt = [0] * (1 << n)
    pts = [cube_points(v, d, n) for v, d in cubes]
    for ps in pts:
        for p in ps:
            cnt[p] += 1
    keep = []
    for i in sorted(range(len(cubes)), key=lambda i: len(pts[i])):
        if all(cnt[p] > 1 for p in pts[i]):
            for p in pts[i]:
                cnt[p] -= 1
        else:
            keep.append(cubes[i])
    return keep


def literals(cubes, n):
    return sum(n - bin(d).count("1") for _, d in cubes)


def fmt(cubes, deps, n):
    if not cubes:
        return "1'b0"
    terms = []
    for val, dc in cubes:
        lits = []
        for k in range(n):
            if (dc >> k) & 1:
                continue
            name = f"i[{deps[k]}]"
            lits.append(name if (val >> k) & 1 else f"~{name}")
        terms.append("(" + " & ".join(lits) + ")" if lits else "1'b1")
    return "\n      | ".join(terms)


def evaluate(cubes, deps, idx):
    for val, dc in cubes:
        ok = True
        for k, b in enumerate(deps):
            if (dc >> k) & 1:
                continue
            if ((idx >> b) & 1) != ((val >> k) & 1):
                ok = False
                break
        if ok:
            return 1
    return 0


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    path, module, out_path = sys.argv[1:4]
    header = ""
    if len(sys.argv) > 4:
        with open(sys.argv[4]) as f:
            header = f.read()
    d = load(path)
    body = []
    used = set()
    for o in range(8):
        tab = bytes((x >> o) & 1 for x in d)
        deps = support(tab)
        if not deps:
            body.append(f"  assign f[{o}] = 1'b{tab[0]};  // constant\n")
            continue
        used.update(deps)
        n = len(deps)
        proj = project(tab, deps)
        pos = minimize(proj, n)
        neg = minimize(bytes(1 - x for x in proj), n)
        inv = (len(neg), literals(neg, n)) < (len(pos), literals(pos, n))
        cubes = neg if inv else pos
        for idx in range(65536):
            got = evaluate(cubes, deps, idx) ^ inv
            if got != tab[idx]:
                sys.exit(f"F{o}: cover wrong at {idx:04x}")
        sup = ",".join(f"I{b}" for b in deps)
        body.append(f"  // F{o}: support {sup}; {len(cubes)} product terms"
                    f"{', complement form' if inv else ''}\n")
        expr = fmt(cubes, deps, n)
        if inv:
            body.append(f"  assign f[{o}] = ~(\n        {expr});\n")
        else:
            body.append(f"  assign f[{o}] =\n        {expr};\n")
    with open(out_path, "w") as f:
        f.write(header)
        f.write("`default_nettype none\n")
        f.write(f"module {module} (\n")
        f.write("  input  logic [15:0] i,   // input pins I15..I0\n")
        f.write("  output logic [7:0]  f    // output pins F7..F0 (electrical levels)\n")
        f.write(");\n")
        f.write("\n".join(b.rstrip("\n") for b in body) + "\n")
        unused = [b for b in range(15, -1, -1) if b not in used]
        if unused:
            f.write("  // Inputs no output depends on.\n")
            f.write("  logic unused_ok;\n")
            f.write("  assign unused_ok = &{1'b0, "
                    + ", ".join(f"i[{b}]" for b in unused) + "};\n")
        f.write("endmodule\n`default_nettype wire\n")


if __name__ == "__main__":
    main()
