#!/usr/bin/env bash
# Tests marker_line with the shapes of output psql really gives.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
source ./drill-lib.sh
failures=0
check() { # description expected input
  got="$(printf '%s' "$3" | marker_line)"
  if [ "$got" = "$2" ]; then echo "  PASS  $1"; else echo "  FAIL  $1: got '$got', want '$2'"; failures=$((failures + 1)); fi
}
check "tag, then the value, then a tag (psql 15 and later, several statements)" "2026-11-17 16:49:18.803713" $'CREATE TABLE\n2026-11-17 16:49:18.803713\nINSERT 0 1'
check "the value, then a tag (the RDS drill's format)" "2026-11-17T16:49:18Z" $'2026-11-17T16:49:18Z\nINSERT 0 1'
check "the value alone (a SELECT)" "2026-11-17 16:49:18.803713" $'2026-11-17 16:49:18.803713'
check "tags only means no marker" "" $'CREATE TABLE\nINSERT 0 1'
check "an error is not a marker" "" $'ERROR:  relation "restore_drill" does not exist'
check "no output means no marker" "" ""
check "the last timestamp wins if there are several" "2026-11-17 16:50:00.000000" $'2026-11-17 16:49:18.803713\n2026-11-17 16:50:00.000000'
echo
[ "$failures" = 0 ] && echo "marker_line handles every shape." || { echo "$failures check(s) failed."; exit 1; }
