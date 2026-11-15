#!/usr/bin/env bash
# Single-step circuit test (spec 3.10): builds hrtests/sstep.s, runs tb_core,
# checks the verdict word and the _NVI pin timing.
#   tb/core/sstep.sh [dir]     (needs obj_dir/tb_core; dir holds boot0.rom and
#                              boot1.rom, default obj_dir)
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${here}"
roms="${1:-obj_dir}"
bin="${TB_CORE:-./obj_dir/tb_core}"
hrtests/asm.sh sstep >/dev/null
"${bin}" +rom="${roms}/boot0.rom" +rom1="${roms}/boot1.rom" +patch=hrtests/sstep.patch +hr +ssmon +watchw=40080 +maxcyc=20000 > obj_dir/sstep.log
v=$(grep '^RAMW' obj_dir/sstep.log | tail -1 | sed 's/.*data //')
echo "verdict ${v} (8000 = all log checks pass; bit n set = check n failed)"
grep -m1 -c "^patch" obj_dir/sstep.log >/dev/null
rc=0
[ "${v}" = "8000" ] || rc=1
python3 sstep_check.py obj_dir/sstep.log || rc=1
exit ${rc}
