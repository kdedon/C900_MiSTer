#!/bin/sh
# Regenerate the LR card PLAs (U18 ZRSEL, U22 4A75) from the 82S100 dumps.
# Needs the dumps (not in this repo); the build and tests do not.
#   scripts/gen_lr_plas.sh <dump_dir>   the directory holding the .bin dumps
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
dumps=${1:?dump_dir: the directory holding the 82S100 .bin dumps}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/u18.txt" <<'EOF'
// Generated from the 82S100 dump of U18; do not edit.
//
// LR card U18 "ZRSEL" (Address Bus sheet).
// Pin map as the card wires it:
//   I0 A0 (unused by every output)   I1 A2   I2 A3   I3 A4
//   I4 U27 A16&A17&A18   I5..I8 U28 /(A20&A21), A19, A22, A23 (order
//   among I5..I8 is immaterial: each must be Low for the CDR)
//   I9 BW-R (High = write)   I10 BB-W (unused)
//   I11 _BMREQ   I12 _BDS   I13 _I-O4   I14 _SUP   I15 _CCLK (unused)
//   F0 CDR (Low = selected)  F1 _SELI-O  F2 _CTL  F3 _STAT  F4 _6545
//   F5 PH2 (6545 E, High)  F6, F7 unused (0)
EOF

cat > "$tmp/u22.txt" <<'EOF'
// Generated from the 82S100 dump of U22; do not edit.
//
// LR card U22 "4A75" attribute decoder (Video sheet).  Input roles:
//   attribute b0..b7 on I4, I10, I13, I7, I12, I9, I5, I14
//   I0 CURBL_INK   I1..I3 cursor group   I15 ENBL_INK (character blink phase)
//   I6, I8, I11 cursor/raster/enable group, roles untraced
//   F0..F4 VID (one function on five pins: cell video polarity)
//   F5 cursor   F6 glyph suppress (blink)   F7 third attribute decode
EOF

python3 "$here/pla_gen.py" "$dumps/C900 ZRSEL 02 1A93 U18 82S100 bbfe6b73.bin" \
  lr_u18_zrsel "$root/rtl/lr_display/lr_u18_zrsel.sv" "$tmp/u18.txt"
python3 "$here/pla_gen.py" "$dumps/C900 380212-02 4A75 U22 82S100 7889163e.bin" \
  lr_u22_attr "$root/rtl/lr_display/lr_u22_attr.sv" "$tmp/u22.txt"
