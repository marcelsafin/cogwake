#!/usr/bin/env bash
# Integration test: drive decide() (the whole hold/release state machine) through
# real-world scenarios with mocked sensors + a controlled clock. No root, no
# hardware. Proves the battery/thermal/within/sticky logic deterministically.
# Run: bash test/integration.sh
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
COGWAKE_LIB=1 . "$DIR/bin/cogwake.sh"

# knobs for the test
HOLD=30; THERM_GUARD=1; THERM_POLL=30; BATT_FLOOR=0

# mocks
log(){ :; }
_batt=0; _pct=100; _therm="nominal"
on_battery(){ [ "$_batt" = 1 ]; }
batt_pct(){ printf '%s' "$_pct"; }
thermal_level(){ printf '%s' "$_therm"; }

reset(){ LASTACTIVE=0 THERM_HOT=0 LAST_THERM=0 UNREADABLE=0 BATT_LOGGED=0 WANT=0 WITHIN=0; _batt=0; _pct=100; _therm="nominal"; BATT_FLOOR=0; }

fail=0
ck(){ # label expected_want actual_want
  if [ "$2" = "$3" ]; then printf 'ok   %s (want=%s)\n' "$1" "$3"
  else printf 'FAIL %s  want expected=%s got=%s\n' "$1" "$2" "$3"; fail=1; fi
}

# S1 agent working, lid open -> hold
reset; decide 1 1 0 1000
ck "working lid-open holds" 1 "$WANT"; [ "$WITHIN" = 1 ] || { echo "FAIL S1 within"; fail=1; }

# S2 no agent -> release
reset; decide 0 0 0 1000
ck "no agent releases" 0 "$WANT"

# S3 agent present but idle past HOLD -> release
reset; decide 1 0 0 1000
ck "idle past HOLD releases" 0 "$WANT"

# S4 agent in HOLD tail (active 20s ago) -> hold
reset; LASTACTIVE=980; decide 1 0 0 1000
ck "HOLD tail holds" 1 "$WANT"

# S5 hot + lid closed -> release to cool
reset; _therm="serious"; decide 1 1 1 1000
ck "hot+closed releases" 0 "$WANT"; [ "$THERM_HOT" = 1 ] || { echo "FAIL S5 therm_hot"; fail=1; }

# S6 nominal + lid closed -> hold
reset; _therm="nominal"; decide 1 1 1 1000
ck "nominal+closed holds" 1 "$WANT"

# S7 sticky hot between samples, then cools after THERM_POLL
reset; _therm="serious"; decide 1 1 1 1000
ck "  hot sample releases" 0 "$WANT"
_therm="nominal"; decide 1 1 1 1010          # 10s later (<THERM_POLL): no resample, stays hot
ck "  stays hot pre-resample" 0 "$WANT"
decide 1 1 1 1040                            # 40s later (>=THERM_POLL): resample -> cool
ck "  cools after THERM_POLL" 1 "$WANT"

# S8 battery floor -> release
reset; BATT_FLOOR=15; _batt=1; _pct=10; decide 1 1 0 1000
ck "battery below floor releases" 0 "$WANT"

# S8b battery above floor -> hold
reset; BATT_FLOOR=15; _batt=1; _pct=80; decide 1 1 0 1000
ck "battery above floor holds" 1 "$WANT"

# S9 thermal unreadable: one miss holds, two misses fail-safe to cool
reset; _therm=""; decide 1 1 1 1000
ck "  1 unreadable holds" 1 "$WANT"
_therm=""; decide 1 1 1 1040
ck "  2 unreadable fail-safe releases" 0 "$WANT"

# S10 lid opens after hot -> sticky cleared, holds again
reset; THERM_HOT=1; LAST_THERM=1000; decide 1 1 0 1005
ck "lid-open clears hot" 1 "$WANT"; [ "$THERM_HOT" = 0 ] || { echo "FAIL S10 sticky not cleared"; fail=1; }

[ "$fail" = 0 ] && { echo "integration OK"; exit 0; } || { echo "integration FAILED"; exit 1; }
