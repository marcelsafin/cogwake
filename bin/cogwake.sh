#!/usr/bin/env bash
# cogwake — keep the Mac awake while an AI coding agent is actively working,
# INCLUDING with the lid closed on battery (laptop in a bag, tethered to a
# phone), then let it sleep ~HOLD seconds after the agent goes quiet.
#
# Why root: closing the lid triggers clamshell sleep, which `caffeinate` cannot
# stop on battery (`caffeinate -s` only holds on AC). The one switch that holds
# is `pmset disablesleep`, and that needs root — so cogwake runs as a
# LaunchDaemon, not a per-user agent.
#
# The lid-close race: the kernel decides at the instant the lid shuts, reading
# `disablesleep` *then*. A 5 s poll can't set it fast enough after the fact —
# the Mac is already asleep. So cogwake PRE-ARMS: while the agent is active it
# sets disablesleep=1 regardless of lid, so a mid-task lid close is already
# safe. It drops back to 0 once the agent is quiet for HOLD seconds; with the
# lid shut that means the Mac sleeps within a few seconds of the agent finishing.
#
# Thermal valve: a closed laptop in a bag has no airflow. When the lid is shut
# and macOS reports serious thermal pressure, cogwake releases the override and
# lets the Mac sleep to cool, even mid-task. Heat is the real bag risk, so this
# guards the hardware while the battery is left to run all the way down.
#
# Detection = CPU the agent process tree burns in a short window, so an *idle*
# agent sitting at a prompt does not hold the machine awake. Covers CLI agents
# (Copilot CLI, Claude, Codex, aider, …) and VS Code's copilot-language-server.
#
# Knobs live in /usr/local/etc/cogwake.env (see cogwake.env.example).
# Bash 3.2 safe (macOS default).
set -u
export LC_ALL=C   # awk must parse/print "." decimals (ps TIME, CPU deltas), not locale ","

CFG="${COGWAKE_CFG:-/usr/local/etc/cogwake.env}"
[ -f "$CFG" ] && . "$CFG"

: "${AGENT_RE:=copilot|claude|codex|aider|cursor-agent|ollama|gemini-cli|continue}"
: "${WINDOW:=2}"        # CPU sampling window, seconds
: "${BUSY_CPU:=0.30}"   # CPU-seconds the tree must burn in WINDOW to count as "working"
                        # 0.30s / 2s ≈ 15% of one core, averaged over the window
: "${HOLD:=30}"         # stay awake this long after the last activity, seconds
: "${POLL:=5}"          # pause between checks while the lid is shut, seconds
: "${LID_OPEN_POLL:=15}" # slower poll while the lid is open (less CPU; lid-open only
                         # pre-arms, and the heavy thermal sampler never runs then)
: "${BATT_FLOOR:=0}"    # on battery, release below this % (0 = off, run till it dies)
: "${THERM_GUARD:=1}"   # 1 = with the lid shut, release when thermal pressure is serious
: "${THERM_RE:=heavy|trapping|sleeping|serious|critical}"  # pressure levels that mean "too hot"
LOG="${COGWAKE_LOG:-/var/log/cogwake.log}"

log(){ printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null; }

# "[[hh:]mm:]ss[.cc]" -> seconds (float). The ps TIME column parser.
secs_from_time(){
  awk -v t="$1" 'BEGIN{ n=split(t,a,":"); s=0; for(i=1;i<=n;i++) s=s*60+a[i]; printf "%.2f", s }'
}

# Cumulative CPU-seconds for a comma/space list of PIDs.
cpu_secs(){
  [ -z "${1:-}" ] && { echo 0; return; }
  ps -o time= -p "$1" 2>/dev/null | awk '
    { n=split($1,a,":"); s=0; for(i=1;i<=n;i++) s=s*60+a[i]; tot+=s }
    END { printf "%.2f", tot+0 }'
}

# Agent root PIDs + every descendant (so a build/test the agent spawned counts).
# ponytail: one awk BFS — Bash 3.2 has no associative arrays.
agent_tree(){
  local roots
  roots=$(pgrep -f -i "$AGENT_RE" 2>/dev/null | sort -un | tr '\n' ' ')
  [ -z "$roots" ] && return 0
  ps -axo pid=,ppid= 2>/dev/null | awk -v roots="$roots" '
    { kids[$2] = kids[$2] " " $1 }
    END{
      n = split(roots, q, " "); tail = 0
      for (i = 1; i <= n; i++) if (q[i] != "") { tail++; q[tail] = q[i]; seen[q[i]] = 1 }
      head = 1
      while (head <= tail) {
        cur = q[head++]; print cur
        m = split(kids[cur], ch, " ")
        for (j = 1; j <= m; j++) if (ch[j] != "" && !(ch[j] in seen)) { seen[ch[j]] = 1; q[++tail] = ch[j] }
      }
    }' | sort -un | tr '\n' ','
}

lid_closed(){ ioreg -r -k AppleClamshellState -d 4 2>/dev/null | grep -q '"AppleClamshellState" = Yes'; }
on_battery(){ pmset -g batt 2>/dev/null | grep -q "Battery Power"; }
batt_pct(){ pmset -g batt 2>/dev/null | grep -Eo '[0-9]+%' | head -1 | tr -d '%'; }

# macOS thermal pressure level, lowercased (e.g. "nominal"). Needs root; empty if
# unreadable. This is the supported signal on Apple Silicon (no temp sysctl/SMC key).
thermal_level(){
  powermetrics --samplers thermal -n1 -i200 2>/dev/null \
    | awk -F': *' 'tolower($0) ~ /pressure level/ { print tolower($2); exit }'
}
# Pure predicate (testable without root): is this level "too hot"?
is_hot(){ [ -n "${1:-}" ] && printf '%s' "$1" | grep -Eqi "$THERM_RE"; }

SLEEP_DISABLED=0   # tracked state, avoids spamming pmset
set_disablesleep(){ # 0|1
  [ "$1" = "$SLEEP_DISABLED" ] && return
  if pmset -a disablesleep "$1" 2>>"$LOG"; then
    SLEEP_DISABLED=$1
    [ "$1" = 1 ] && log "AWAKE  disablesleep=1 (lid-close safe)" \
                 || log "release  disablesleep=0 (sleep allowed)"
  fi
}

main(){
  if [ "$(id -u)" != 0 ]; then
    echo "cogwake must run as root (pmset disablesleep needs root)" >&2
    log "ERROR not root — exiting"
    exit 1
  fi
  # Known baseline at start; resets a stuck flag left by a hard kill + relaunch.
  pmset -a disablesleep 0 2>/dev/null; SLEEP_DISABLED=0
  trap 'pmset -a disablesleep 0 2>/dev/null; log "stopped — disablesleep reset to 0"' EXIT INT TERM

  local lastactive=0 pids c0 c1 delta active now within want pct lvl closed
  log "started (re=$AGENT_RE window=${WINDOW}s busy=${BUSY_CPU}cpu-s hold=${HOLD}s battfloor=${BATT_FLOOR}% therm=${THERM_GUARD} poll=${POLL}/${LID_OPEN_POLL}s)"
  while :; do
    pids=$(agent_tree); pids=${pids%,}
    if [ -n "$pids" ]; then
      c0=$(cpu_secs "$pids")
      sleep "$WINDOW"
      c1=$(cpu_secs "$pids")
      delta=$(awk -v a="$c0" -v b="$c1" 'BEGIN{ d=b-a; if(d<0)d=0; print d }')
      active=$(awk -v d="$delta" -v t="$BUSY_CPU" 'BEGIN{ print (d>=t)?1:0 }')
    else
      sleep "$WINDOW"; active=0
    fi

    now=$(date +%s)
    [ "$active" = 1 ] && lastactive=$now
    closed=0; lid_closed && closed=1

    within=0
    if [ -n "$pids" ] && [ $((now - lastactive)) -lt "$HOLD" ]; then within=1; fi
    want=$within

    # Battery floor: off by default (run till it dies). Set BATT_FLOOR>0 to guard charge.
    if [ "$want" = 1 ] && [ "$BATT_FLOOR" -gt 0 ] && on_battery; then
      pct=$(batt_pct)
      if [ -n "$pct" ] && [ "$pct" -le "$BATT_FLOOR" ]; then
        want=0; log "battery ${pct}% <= ${BATT_FLOOR}% — releasing (sleep allowed)"
      fi
    fi

    # Thermal valve: only matters (and only sampled) with the lid shut — no airflow.
    if [ "$want" = 1 ] && [ "$THERM_GUARD" = 1 ] && [ "$closed" = 1 ]; then
      lvl=$(thermal_level)
      if is_hot "$lvl"; then
        want=0; log "thermal '$lvl' with lid closed — releasing to cool (sleep allowed)"
      elif [ -n "$lvl" ]; then
        log "thermal '$lvl' (lid closed, holding)"
      else
        log "thermal: unreadable (powermetrics gave nothing) — holding"
      fi
    fi

    set_disablesleep "$want"
    # Lid open: only pre-arming, so poll slowly to spare CPU. Lid shut: poll fast.
    if [ "$closed" = 1 ]; then sleep "$POLL"; else sleep "$LID_OPEN_POLL"; fi
  done
}

# Sourceable for tests: `COGWAKE_LIB=1 . bin/cogwake.sh` defines the
# functions without starting the loop.
[ "${COGWAKE_LIB:-0}" = 1 ] || main "$@"
