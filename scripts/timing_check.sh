#!/usr/bin/env bash
# Fail if any clock has negative slack in C900.sta.summary.
#   scripts/timing_check.sh <output_files dir>
# Only the framework HDMI scaler clock (pll_hdmi) may fail setup, down to
# -0.250 ns.
set -euo pipefail

dir="${1:?usage: timing_check.sh <output_files dir>}"
sum="${dir}/C900.sta.summary"
[ -f "${sum}" ] || { echo "timing_check: ${sum} not found" >&2; exit 2; }

awk -v hdmi_floor=-0.250 '
  /^Type[ ]*:/ { t = $0; sub(/^Type[ ]*: */, "", t); next }
  /^Slack[ ]*:/ {
    s = $3 + 0
    lim = 0
    if (t ~ /^Setup / && t ~ /pll_hdmi/) lim = hdmi_floor
    if (s < lim) { printf "FAIL %s slack %.3f (limit %.3f)\n", t, s, lim; bad = 1 }
  }
  END { exit bad }
' "${sum}" || { echo "timing_check: FAILED" >&2; exit 1; }
echo "timing_check: OK"
