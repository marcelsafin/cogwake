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
# Matching the full command line (pgrep -f) is needed because codex/gemini run as
# `node`, cursor-agent as `bash`, so their comm isn't the agent name. But -f also
# catches GUI apps and daemons whose path/args merely contain an agent word (a
# browser named like an agent, a desktop chat app, fsmonitor, mcp-remote). Those
# get dropped by this command-line filter — a Chromium swarm burns real CPU and
# would otherwise falsely hold the Mac awake in the bag. `copilot-detached` drops
# Copilot CLI's own detached background servers (dev servers it launched), which
# burn CPU on their own and are not the agent thinking.
: "${EXCLUDE_RE:=\.app/Contents/|[Cc]rashpad|fsmonitor|mcp-remote|http\.server|copilot-detached}"
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
: "${THERM_POLL:=30}"   # seconds between thermal samples (powermetrics is the only real
                        # cost; sampling it every 30s instead of every POLL saves battery)
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
  local cand roots
  cand=$(pgrep -f -i "$AGENT_RE" 2>/dev/null | sort -un | tr '\n' ',')
  cand=${cand%,}
  [ -z "$cand" ] && return 0
  # Drop GUI apps / daemons that only matched because an agent word is in their
  # path or args (see EXCLUDE_RE). One ps call; keep the real CLI/interpreter
  # agents. EXCLUDE_RE is `:=`-defaulted above, so it is never empty here (an empty
  # pattern would make grep -Eiv drop every root) — a config `EXCLUDE_RE=''` falls
  # back to the default rather than disabling the filter.
  roots=$(ps -o pid=,command= -p "$cand" 2>/dev/null | grep -Eiv "$EXCLUDE_RE" | awk '{print $1}' | sort -un | tr '\n' ' ')
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
# Sticky decision state (persists across loop iterations; decide() updates them).
LASTACTIVE=0; THERM_HOT=0; LAST_THERM=0; UNREADABLE=0; BATT_LOGGED=0; WANT=0; WITHIN=0
set_disablesleep(){ # 0|1
  [ "$1" = "$SLEEP_DISABLED" ] && return
  if pmset -a disablesleep "$1" 2>>"$LOG"; then
    SLEEP_DISABLED=$1
    [ "$1" = 1 ] && log "AWAKE  disablesleep=1 (lid-close safe)" \
                 || log "release  disablesleep=0 (sleep allowed)"
  fi
}

# The whole hold/release decision for one cycle. Inputs are this cycle's readings;
# outputs are the globals WANT (1=hold sleep, 0=allow) and WITHIN (agent actively
# working / in the HOLD tail, used for the poll cadence). Sensor calls (on_battery,
# batt_pct, thermal_level) are separate functions so tests can mock them and drive
# this deterministically. Must NOT be called via $(...) — it updates sticky globals.
decide(){ # has_pids active closed now
  local has_pids=$1 active=$2 closed=$3 now=$4 pct lvl
  [ "$active" = 1 ] && LASTACTIVE=$now
  WITHIN=0
  if [ "$has_pids" = 1 ] && [ $((now - LASTACTIVE)) -lt "$HOLD" ]; then WITHIN=1; fi
  WANT=$WITHIN

  # Battery floor: off by default (run till it dies). Set BATT_FLOOR>0 to guard charge.
  if [ "$WANT" = 1 ] && [ "$BATT_FLOOR" -gt 0 ] && on_battery; then
    pct=$(batt_pct)
    if [ -n "$pct" ] && [ "$pct" -le "$BATT_FLOOR" ]; then
      WANT=0
      [ "$BATT_LOGGED" = 1 ] || { log "battery ${pct}% <= ${BATT_FLOOR}% — releasing (sleep allowed)"; BATT_LOGGED=1; }
    else BATT_LOGGED=0; fi
  else BATT_LOGGED=0; fi

  # Thermal valve: sampled at most every THERM_POLL while the lid is shut, since
  # powermetrics is the one heavy call. THERM_HOT is sticky between samples, so a
  # hot reading keeps the Mac releasable until a later sample reads cool — without
  # it, re-arming every POLL would skip the heat check and could cook in the bag.
  if [ "$THERM_GUARD" = 1 ] && [ "$closed" = 1 ]; then
    if [ $((now - LAST_THERM)) -ge "$THERM_POLL" ]; then
      LAST_THERM=$now
      lvl=$(thermal_level)
      if is_hot "$lvl"; then
        UNREADABLE=0
        [ "$THERM_HOT" = 1 ] || log "thermal '$lvl' with lid closed — will sleep to cool"
        THERM_HOT=1
      elif [ -n "$lvl" ]; then
        UNREADABLE=0
        [ "$THERM_HOT" = 0 ] || log "thermal '$lvl' (lid closed, cool again)"
        THERM_HOT=0
      else
        # Can't read pressure. The thermal valve is the only hardware guard while
        # sealed (BATT_FLOOR off), so fail safe toward cooling after two misses.
        UNREADABLE=$((UNREADABLE + 1))
        if [ "$UNREADABLE" -ge 2 ] && [ "$THERM_HOT" = 0 ]; then
          THERM_HOT=1; log "thermal: unreadable x$UNREADABLE — releasing to be safe (cannot confirm cool)"
        fi
      fi
    fi
  else
    THERM_HOT=0; LAST_THERM=0; UNREADABLE=0   # lid open or guard off: clear; resample at once next close
  fi
  [ "$THERM_HOT" = 1 ] && WANT=0
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

  local pids c0 c1 delta active now closed haspids
  log "started (re=$AGENT_RE window=${WINDOW}s busy=${BUSY_CPU}cpu-s hold=${HOLD}s battfloor=${BATT_FLOOR}% therm=${THERM_GUARD}/${THERM_POLL}s poll=${POLL}/${LID_OPEN_POLL}s)"
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
    closed=0; lid_closed && closed=1
    haspids=0; [ -n "$pids" ] && haspids=1

    decide "$haspids" "$active" "$closed" "$now"   # sets WANT + WITHIN (+ sticky state)
    set_disablesleep "$WANT"

    # Poll fast while actually holding the Mac awake (an agent is working, so a
    # mid-task lid close is armed) or whenever the lid is shut. Idle with the lid
    # open (e.g. persistent agent servers sitting at a prompt) polls slowly to
    # spare battery. Tradeoff: an idle agent that starts work can take up to
    # LID_OPEN_POLL to arm — fine, since the lid-close case is mid-work.
    if [ "$closed" = 1 ] || [ "$WITHIN" = 1 ]; then sleep "$POLL"; else sleep "$LID_OPEN_POLL"; fi
  done
}

# Sourceable for tests: `COGWAKE_LIB=1 . bin/cogwake.sh` defines the
# functions without starting the loop.
[ "${COGWAKE_LIB:-0}" = 1 ] || main "$@"
