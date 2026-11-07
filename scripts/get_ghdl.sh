#!/usr/bin/env bash
# Fetches the pinned GHDL release into tools/ghdl.  The benches netlist the
# vendored VHDL cores with it.  GHDL 4.1
# writes the T65's ALU output net twice when an instance output and a
# signal share a name; 6.0.0 names it once.
#   scripts/get_ghdl.sh [dest]      (default: tools/ghdl)
set -euo pipefail
ver=6.0.0
tarball="ghdl-mcode-${ver}-ubuntu24.04-x86_64.tar.gz"
sha256=30d6a977b8456d140bbafecbbe64b1947a3d92eeae8f5e6d9f528a174f9566e7
url="https://github.com/ghdl/ghdl/releases/download/v${ver}/${tarball}"

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
dest="${1:-${root}/tools/ghdl}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

curl -sSfL -o "${tmp}/${tarball}" "${url}"
echo "${sha256}  ${tmp}/${tarball}" | sha256sum -c --quiet -
mkdir -p "${tmp}/x"
tar xzf "${tmp}/${tarball}" -C "${tmp}/x"
rm -rf "${dest}"
mkdir -p "$(dirname -- "${dest}")"
mv "${tmp}/x/${tarball%.tar.gz}" "${dest}"
"${dest}/bin/ghdl" --version | head -1
