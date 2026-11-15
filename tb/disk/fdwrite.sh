#!/usr/bin/env bash
# Floppy write through the whole machine (tb_disk, about 25 min).  The BIOS's
# disk read opcode is patched to write (0x0A), so its auto-boot writes block 2
# of a synthetic image on S1 (drive 1) from its 512-byte RAM buffer at 0x80400.
# The buffer is loaded with an LFSR pattern seeded by the block number, so
# every byte and block differs.  The FDC firmware writes the sector, then
# reads it back against the 8716's bytes.  PASS when the FDC posts status
# 0x80 in the floppy command block (DMA write to 0x08001C), the DMA reads of
# the buffer return no error, and the image after the run equals the original
# except block 2, which holds the pattern.
#   make -C tb/disk && tb/disk/fdwrite.sh <rom_dir>   (the C900 ROM dumps)
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="${here}/../.."
out="${here}/obj_dir/fdwrite"
mkdir -p "${out}"
[ $# -eq 1 ] || { echo "usage: $0 <rom_dir>: the C900 ROM dumps (not in this repo)" >&2; exit 2; }
"${root}/scripts/make_boot_rom.sh" "$1" "${out}" > /dev/null
rom="${out}/boot0.rom"

# memory test skipped (tb/core/skip_memtest.patch); wdread's "ldb @rr,#8" -> #0x0A
{ cat "${root}/tb/core/skip_memtest.patch"; printf '090C 0A\n490C 0A\n'; } > "${out}/wr.patch"
python3 -c "
open('${out}/fd.img', 'wb').write(bytes((l * 131 + i * 7 + l // 256 * 29) & 255
                                        for l in range(2392) for i in range(512)))"

blk=2
python3 -c "
l = 0xACE1 ^ (${blk} * 0x1021) & 0xFFFF
out = bytearray()
for i in range(512):
    for _ in range(8):
        l = (l >> 1) ^ (0xB400 if l & 1 else 0)
    out.append((l ^ (i * 7)) & 255)
open('${out}/pat.bin', 'wb').write(out)
open('${out}/ram.txt', 'w').write(''.join('%X %02X\\n' % (0x80400 + i, b) for i, b in enumerate(out)))"

rm -f "${out}/after.img"
"${here}/obj_dir/tb_disk" +rom="${rom}" +rom1="${out}/boot1.rom" +patch="${out}/wr.patch" +fd1="${out}/fd.img" \
  +maxcyc=17000000 +dmalog="${out}/dma.txt" +ram="${out}/ram.txt" +ramat=9100000 \
  +dump1="${out}/after.img" > "${out}/run.log"
st=$(awk '$3 == "08001c" && $4 == "W" { print substr($5, 1, 2); exit }' "${out}/dma.txt")
if [ "${st}" != "80" ]; then echo "RESULT FAIL fdwrite: status ${st:-none} (log ${out}/run.log)"; exit 1; fi
python3 - "${out}/fd.img" "${out}/after.img" "${out}/pat.bin" "${blk}" <<'PY'
import sys
before, after, pat = (open(p, 'rb').read() for p in sys.argv[1:4])
blk = int(sys.argv[4])
exp = before[:blk * 512] + pat + before[blk * 512 + 512:]
if len(after) != len(exp):
    sys.exit('RESULT FAIL fdwrite: image size %d, want %d' % (len(after), len(exp)))
bad = [i for i in range(len(exp)) if after[i] != exp[i]]
if bad:
    i = bad[0]
    sys.exit('RESULT FAIL fdwrite: %d bytes differ, first at 0x%X (block %d byte %d): got %02X want %02X'
             % (len(bad), i, i // 512, i % 512, after[i], exp[i]))
print('RESULT PASS fdwrite: status 0x80, block %d holds the pattern, rest unchanged' % blk)
PY
