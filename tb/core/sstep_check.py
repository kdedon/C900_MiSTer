#!/usr/bin/env python3
"""Check an ssmon log (+ssmon) against the single-step timing: after the
I/O access arms STEP, _NVI falls on the second instruction fetch, is released
at the aborted fetch's NVI_CLK pulse or the acknowledge (before a third
fetch), and one arm gives one step.
With the NVI masked (no acknowledge) the shifter toggles _NVI at every fetch.
usage: sstep_check.py tb.log"""
import re, sys
ev = []
for l in open(sys.argv[1]):
    m = re.match(r"SS (\d+) (\w+)\s*(\S*)\s*(\S*)", l)
    if m:
        ev.append((int(m[1]), m[2], m[3], m[4]))
# an IF1 followed by ABORT opened an interrupt; it fetched no instruction
kept = []
for e in ev:
    if e[1] == "ABORT":
        k = max(j for j, f in enumerate(kept) if f[1] == "IF1")
        del kept[k]
    else:
        kept.append(e)
ev = kept
fails = 0
def bad(msg):
    global fails
    fails += 1
    print("FAIL", msg)
# an arm: STEP rises
arms = [i for i, e in enumerate(ev) if e[1] == "STEP" and e[2] == "1"]
print("arms (STEP rise):", len(arms))
for n, i in enumerate(arms):
    io = [e for e in ev[:i] if e[1] == "IO"][-1]
    j = i + 1
    if_n = 0
    fall = rise = ack = None
    nxt = arms[n + 1] if n + 1 < len(arms) else len(ev)
    masked = not any(e[1] == "ACK" for e in ev[i + 1:nxt])
    while j < nxt:
        t, k, a, _ = ev[j]
        if k == "IF1":
            if_n += 1
            if fall is not None and rise is None and not masked:
                bad(f"arm {n}: IF1 #{if_n} at {t} with _NVI still low")
        if k == "NVI" and a == "0" and fall is None:
            fall = (t, if_n)
        if k == "NVI" and a == "1" and fall is not None and rise is None:
            rise = (t, if_n)
        if k == "STEP" and a == "0":
            ack = next((e[0] for e in ev[j:j + 3] if e[1] == "ACK"), None)
            break
        j += 1
    print(f"arm {n}: IO {io[2]} {io[3]} @{io[0]}  STEP@{ev[i][0]}  NVI fall @{fall} (IF1 count)  "
          f"rise @{rise}  ack @{ack}")
    if fall is None or fall[1] != 2:
        bad(f"arm {n}: _NVI must fall at the second instruction fetch, got {fall}")
    if not masked and ack is None:
        bad(f"arm {n}: no acknowledge with the STEP fall")
    if rise is None:
        bad(f"arm {n}: _NVI never released")
    elif rise[1] != (3 if masked else 2):
        bad(f"arm {n}: _NVI released at fetch {rise[1]}")
print("PASS" if not fails else f"{fails} FAIL")
sys.exit(1 if fails else 0)
