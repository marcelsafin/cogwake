#!/usr/bin/env bash
# Self-check: runnable tests for the non-trivial parsing/detection logic.
# Run: bash test/selfcheck.sh   (no root needed; read-only probes only)
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
COGWAKE_LIB=1 . "$DIR/bin/cogwake.sh"

fail=0
check(){ # label expected actual
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s  expected=%s got=%s\n' "$1" "$2" "$3"; fail=1; fi
}

# ps TIME column -> seconds (the bit most likely to silently break)
check "secs ss.cc"   "5.50"    "$(secs_from_time 5.50)"
check "secs mm:ss"   "83.00"   "$(secs_from_time 1:23)"
check "secs mm:ss.cc" "83.45"  "$(secs_from_time 1:23.45)"
check "secs hh:mm:ss" "3723.00" "$(secs_from_time 1:02:03)"

# agent_tree must run and return a comma list (or empty) without error
out="$(agent_tree)"; rc=$?
check "tree exit ok" "0" "$rc"
case "$out" in
  ""|*[0-9],*|*[0-9]) printf 'ok   tree shape\n' ;;
  *) printf 'FAIL tree shape  got=%s\n' "$out"; fail=1 ;;
esac

# lid/battery probes must run and yield sane shapes (read-only, no root)
lid_closed; rc=$?
case "$rc" in 0|1) printf 'ok   lid_closed runs (rc=%s)\n' "$rc" ;; *) printf 'FAIL lid_closed rc=%s\n' "$rc"; fail=1 ;; esac
on_battery; rc=$?
case "$rc" in 0|1) printf 'ok   on_battery runs (rc=%s)\n' "$rc" ;; *) printf 'FAIL on_battery rc=%s\n' "$rc"; fail=1 ;; esac
pct="$(batt_pct)"
case "$pct" in ''|*[!0-9]*) printf 'FAIL batt_pct not numeric got=%s\n' "$pct"; fail=1 ;; *) printf 'ok   batt_pct numeric (%s%%)\n' "$pct" ;; esac

[ "$fail" = 0 ] && { echo "selfcheck OK"; exit 0; } || { echo "selfcheck FAILED"; exit 1; }
