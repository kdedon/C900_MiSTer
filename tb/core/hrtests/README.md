# HR bitmap test programs (tb_core +hr)

These are scratch tests from the 2026-11-04 HR cursor and bell investigation. docs/theory/FLOWS.md section 7 has the results.

- `t10.s`: XOR read-compute-write race against a kernel-style cursor move.
- `t11.s`: cursor drawn, the white fill's mouse-off dropped, then erased; leaves a full arrow. `gen11.py` generates it.
- `chk.s`: HR read-back check (`hr_rmw.s` in tb/core is the gate version).
- `bell.patch`: the shipped bell loop, from `mkpatch.py`.
- `asm.sh name` builds `name.patch` with the host `as-z8001` (`AS`, an as-z8001 assembler) and `o2patch.py`. Run tb_core with `+patch=<name>.patch +hr`; the HRMON shadow reports mismatches.
- `shot/`: decodes a 1440x1080 MiSTer screenshot back to 1024x800 desktop pixels.

- `sstep.s`: single-step circuit (spec 3.10); `tb/core/sstep.sh` runs it with the `ssmon.sv` pin monitor (`+ssmon`) and `sstep_check.py`.

They are not part of `make tb`.
