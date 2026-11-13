#!/usr/bin/env bash
# Usage: check_coverage.sh <dir> <min-percent> <lcov-file>...
# Merges the given lcov files (max hits per line) and gates lib/<dir> line coverage.
set -euo pipefail

dir=$1
min=$2
shift 2

awk -F'[:,]' -v dir="$dir" -v min="$min" '
  /^SF:/ { file = $2; next }
  /^DA:/ { line = file SUBSEP $2; if (!(line in hits) || $3 > hits[line]) hits[line] = $3 }
  END {
    prefix = "lib/" dir "/"
    for (line in hits) {
      split(line, parts, SUBSEP)
      if (index(parts[1], prefix) != 1) continue
      found++
      if (hits[line] > 0) hit++
    }
    if (found == 0) { print "No " prefix " coverage data"; exit 1 }
    pct = 100 * hit / found
    printf "%s line coverage: %.1f%% (%d/%d)\n", prefix, pct, hit, found
    if (pct < min) { printf "Below %d%%\n", min; exit 1 }
  }' "$@"
