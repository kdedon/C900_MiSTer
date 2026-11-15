#!/usr/bin/env bash
# Copy the external RTL this core uses into rtl/vendor/ and record the
# source commit of each repo in rtl/vendor/MANIFEST.txt.
#
#   scripts/sync_vendor.sh            sync from ../k8000 and the upstream cores
#   SYNC_SYS=1 scripts/sync_vendor.sh also replace sys/ from ../Template_MiSTer
#   FORCE=1 scripts/sync_vendor.sh    sync even if a source fails a check
#   K8000_REF=<rev>                   sync a given commit (default HEAD)
#   T48_UPSTREAM_REF=<rev> T65_UPSTREAM_REF=<rev> SDRAM_UPSTREAM_REF=<rev>
#   VDC_UPSTREAM_REF=<rev>            the T48 / T65 VHDL, SDRAM controller and
#                                     8563/8568 commits (defaults below)
#   K8000_WORKTREE=1 scripts/sync_vendor.sh
#                                     copy k8000 from its working tree
#                                     (uncommitted work awaiting review);
#                                     the manifest says so and lists the
#                                     dirty paths
#
# The T48 (8049) and T65 (6502) cores are vendored as their upstream VHDL
# (Quartus compiles it; the benches make a Verilog netlist from it with GHDL
# at build time), not as netlists:
#   rtl/vendor/t48/  ../t48 (github.com/devsaurus/t48, Arnim Laeuger), rtl/vhdl
#   rtl/vendor/t65/  ../C64_MiSTer (github.com/MiSTer-devel/C64_MiSTer), rtl/t65
# The SDRAM controller is Sorgelig's single-port sdram.sv, unmodified:
#   rtl/vendor/sdram/  ../NeoGeo_MiSTer (github.com/MiSTer-devel/NeoGeo_MiSTer), rtl/mem
# The 8563/8568 VDC is Erik Scheffers' core with local patches
# (rtl/vendor_patches/vdc856x, applied in the order of vdc_patches):
#   rtl/vendor/vdc856x/  ../C128_MiSTer (github.com/MiSTer-devel/C128_MiSTer), rtl/vdc856x
# The T48 takes the local patches in rtl/vendor_patches/t48/ (the 8049 pin
# phases): they are applied to rtl/vendor/t48/ (patch -p1), and the manifest
# lists each with its md5.
#
# Files are taken from the named commit with `git archive`, never from the
# working tree (except with K8000_WORKTREE=1), so other work in progress in
# a source repo is not copied.
#
# Source checks (each refuses the sync unless FORCE=1):
#   - the branch is behind its upstream after `git fetch`
# Uncommitted changes under the copied paths are reported (they are not
# copied).  A repo with no upstream is reported and accepted.
# The script fetches but never pulls: update the sources yourself first.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
k8000="${K8000_DIR:-${here}/../k8000}"
template="${TEMPLATE_DIR:-${here}/../Template_MiSTer}"
t48_dir="${T48_DIR:-${here}/../t48}"
t65_dir="${T65_DIR:-${here}/../C64_MiSTer}"
sdram_dir="${SDRAM_DIR:-${here}/../NeoGeo_MiSTer}"
t48_ref="$(git -C "${t48_dir}" rev-parse "${T48_UPSTREAM_REF:-837bd24}")"
t65_ref="$(git -C "${t65_dir}" rev-parse "${T65_UPSTREAM_REF:-2f30f68}")"
sdram_ref="$(git -C "${sdram_dir}" rev-parse "${SDRAM_UPSTREAM_REF:-227d4f4}")"
vdc_dir="${VDC_DIR:-${here}/../C128_MiSTer}"
vdc_ref="$(git -C "${vdc_dir}" rev-parse "${VDC_UPSTREAM_REF:-f31162f}")"
vdc_patches=(
  "vsync_f1_modulo:field-1 vsync modulo in 9 bits, no function change; tb/lc_display make eq"
  "ram_pins:the RAM block moves out of the chip to its pins, c900_dispram; vdcram.v unused"
  "busy_pin:status b7 busy to a port, for the 8568 INTR pin in mos8568"
  "row_ram:the row latches in block RAM, no function change; tb/lc_display make eq"
  "interlace_bitmap:interlaced bitmap loads R12/R13 once a frame, for the even field; the odd field continues after it; no fetch in the top adjust row"
  "interlace_sync:R8 01 VSYNC half a line later in alternate fields, width in whole lines; row heights as R8 00"
  "refresh_count:R36 refresh cycles per line, not R36+1"
  "sync_polarity:R37 b7/b6 set the 8568 HSYNC/VSYNC polarity, 1 = positive, 1 from reset"
)
t48_files=(t48_pack-p.vhd psw.vhd pmem_ctrl_pack-p.vhd pmem_ctrl.vhd p2.vhd p1.vhd timer.vhd
           dmem_ctrl_pack-p.vhd dmem_ctrl.vhd decoder_pack-p.vhd cond_branch_pack-p.vhd
           alu_pack-p.vhd int.vhd t48_tb_pack-p.vhd decoder.vhd db_bus.vhd cond_branch.vhd
           clock_ctrl.vhd bus_mux.vhd alu.vhd t48_core.vhd)
t65_files=(T65_Pack.vhd T65_MCode.vhd T65_ALU.vhd T65.vhd)
dst="${here}/rtl/vendor"
force="${FORCE:-0}"
k8000_ref="$(git -C "${k8000}" rev-parse "${K8000_REF:-HEAD}")"

# check <repo> <path>...: fail if the paths are dirty or the branch is behind.
check() {
  local repo="$1"; shift
  local bad=0 dirty behind
  dirty="$(git -C "${repo}" status --porcelain -- "$@")"
  if [ -n "${dirty}" ]; then
    echo "note: ${repo} has uncommitted changes under $* (not copied):" >&2
    echo "${dirty}" >&2
  fi
  if git -C "${repo}" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
    git -C "${repo}" fetch --quiet
    behind="$(git -C "${repo}" rev-list --count 'HEAD..@{u}')"
    if [ "${behind}" != "0" ]; then
      echo "ERROR: ${repo} is ${behind} commit(s) behind its upstream; pull first" >&2
      bad=1
    fi
  else
    echo "note: ${repo} has no upstream; not checked for being behind" >&2
  fi
  if [ "${bad}" = "1" ] && [ "${force}" != "1" ]; then
    echo "refusing to sync (FORCE=1 overrides)" >&2
    exit 1
  fi
}

k8000_paths=(rtl/k800x_cpu rtl/k8010_mmu rtl/k8030_scc rtl/k8036_cio rtl/k8070_fpu)
k8000_wt="${K8000_WORKTREE:-0}"
if [ "${k8000_wt}" = "1" ]; then
  k8000_dirty="$(git -C "${k8000}" status --porcelain -- "${k8000_paths[@]}")"
else
  check "${k8000}" "${k8000_paths[@]}"
fi

# The sys/ line of the manifest survives a sync that does not touch sys/.
sys_line="$(grep '^Template_MiSTer ' "${dst}/MANIFEST.txt" 2>/dev/null || echo 'Template_MiSTer unknown')"
if [ "${SYNC_SYS:-0}" = "1" ]; then
  check "${template}" sys
  rm -rf "${here}/sys"
  cp -r "${template}/sys" "${here}/sys"
  sys_line="Template_MiSTer $(git -C "${template}" rev-parse HEAD) sys/"
fi

rm -rf "${dst}/k8000" "${dst}/t48" "${dst}/t65" "${dst}/sdram" "${dst}/vdc856x"
mkdir -p "${dst}/k8000" "${dst}/t48" "${dst}/t65" "${dst}/sdram" "${dst}/vdc856x"

# extract <repo> <rev> <dest> <path>...: copy rtl/<path> at <rev> to <dest>/<path>.
extract() {
  local repo="$1" rev="$2" out="$3"; shift 3
  git -C "${repo}" archive --format=tar "${rev}" "$@" | tar -x -C "${out}" --strip-components=1
}

# T48 and T65: the VHDL only.
git -C "${t48_dir}" archive --format=tar "${t48_ref}" "${t48_files[@]/#/rtl/vhdl/}" |
  tar -x -C "${dst}/t48" --strip-components=2
git -C "${t65_dir}" archive --format=tar "${t65_ref}" "${t65_files[@]/#/rtl/t65/}" |
  tar -x -C "${dst}/t65" --strip-components=2

# SDRAM controller.
git -C "${sdram_dir}" archive --format=tar "${sdram_ref}" rtl/mem/sdram.sv |
  tar -x -C "${dst}/sdram" --strip-components=2

# 8563/8568 VDC and its local patches.
git -C "${vdc_dir}" archive --format=tar "${vdc_ref}" rtl/vdc856x | tar -x -C "${dst}/vdc856x" --strip-components=2
git -C "${vdc_dir}" archive --format=tar "${vdc_ref}" rtl/rgbicolor.vhd | tar -x -C "${dst}/vdc856x" --strip-components=1
vdc_patch_lines=()
for e in "${vdc_patches[@]}"; do
  p="${here}/rtl/vendor_patches/vdc856x/${e%%:*}.patch"
  patch -s -d "${dst}/vdc856x" -p1 --no-backup-if-mismatch < "${p}"
  vdc_patch_lines+=("  patched: vendor_patches/vdc856x/${e%%:*}.patch md5 $(md5sum < "${p}" | cut -d' ' -f1) (local: ${e#*:})")
done

# T48 local patches, applied in name order.
patches="${here}/rtl/vendor_patches/t48"
t48_patch_lines=()
for p in "${patches}"/*.patch; do
  [ -e "${p}" ] || continue
  patch -s -d "${dst}/t48" -p1 --no-backup-if-mismatch < "${p}"
  t48_patch_lines+=("  patched: vendor_patches/t48/$(basename "${p}") md5 $(md5sum < "${p}" | cut -d' ' -f1)")
done

# k8000: Z8001 CPU (with its generated packages and ROMs), MMU, SCC, CIO.
if [ "${k8000_wt}" = "1" ]; then
  for p in "${k8000_paths[@]}"; do
    cp -r "${k8000}/${p}" "${dst}/k8000/"
  done
else
  extract "${k8000}" "${k8000_ref}" "${dst}/k8000" "${k8000_paths[@]}"
fi

{
  echo "# Vendored RTL. Written by scripts/sync_vendor.sh; do not edit by hand."
  echo "synced $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "T48 ${t48_ref} rtl/vhdl (github.com/devsaurus/t48) -> t48/"
  for l in "${t48_patch_lines[@]}"; do echo "${l} (local)"; done
  echo "T65 ${t65_ref} rtl/t65 (github.com/MiSTer-devel/C64_MiSTer) -> t65/"
  echo "SDRAM ${sdram_ref} rtl/mem/sdram.sv (github.com/MiSTer-devel/NeoGeo_MiSTer) -> sdram/"
  if [ "${k8000_wt}" = "1" ]; then
    echo "k8000 working tree, uncommitted, pending user review (base ${k8000_ref}); dirty paths:"
    echo "${k8000_dirty}" | sed 's/^/  /'
  else
    echo "k8000 ${k8000_ref}"
  fi
  echo "${sys_line}"
  echo "VDC856X ${vdc_ref} rtl/vdc856x + rtl/rgbicolor.vhd (github.com/MiSTer-devel/C128_MiSTer, Erik Scheffers) -> vdc856x/"
  for l in "${vdc_patch_lines[@]}"; do echo "${l}"; done
  echo "  licence: GPL-2, inferred from the author's other releases (CBM-II_MiSTer: GPL-2 LICENSE and GPL-2 file headers); no header in vdc856x, no LICENSE in C128_MiSTer; compatible with C900_MiSTer GPL-2"
  echo "  Verilator: tb/lc_display/vdc_sim.patch makes a simulation copy in obj_dir (never committed)"
} > "${dst}/MANIFEST.txt"

cat "${dst}/MANIFEST.txt"
