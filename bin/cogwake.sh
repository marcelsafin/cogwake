#!/usr/bin/env bash
# cogwake — keep the Mac awake ONLY while an AI coding agent is actively
# working (thinking / streaming tokens / running a tool it spawned), then let it
# sleep normally. Detection = CPU time the agent process tree burns in a short
# window, so an *idle* agent sitting at a prompt does NOT hold the machine awake.
#
# Covers CLI agents (Copilot CLI, Claude CLI, Codex, aider, …) and, for free,
# VS Code's copilot-language-server (matched by the "copilot" pattern) — its CPU
# only spikes while generating, so normal idle editing won't pin the Mac awake.
#
# Knobs live in ~/.config/cogwake.env (see cogwake.env.example).
# Bash 3.2 safe (macOS default). No sudo.
set -u
export LC_ALL=C   # awk must parse/print "." decimals (ps TIME, CPU deltas), not locale "," 

CFG="${COGWAKE_CFG:-$HOME/.config/cogwake.env}"
[ -f "$CFG" ] && . "$CFG"

: "${AGENT_RE:=copilot|claude|codex|aider|cursor-agent|ollama|gemini-cli|continue}"
: "${WINDOW:=2}"        # CPU sampling window, seconds
: "${BUSY_CPU:=0.30}"   # CPU-seconds the tree must burn in WINDOW to count as "working"
                        # 0.30s / 2s ≈ 15% of one core, averaged over the window
: "${HOLD:=150}"        # stay awake this long after the last activity, seconds
: "${POLL:=5}"          # pause between checks while idle, seconds
LOG="${COGWAKE_LOG:-$HOME/Library/Logs/cogwake.log}"

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

main(){
  local CAF="" lastactive=0 pids c0 c1 delta active now
  log "started (re=$AGENT_RE window=${WINDOW}s busy=${BUSY_CPU}cpu-s hold=${HOLD}s)"
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

    if [ -n "$pids" ] && [ $((now - lastactive)) -lt "$HOLD" ]; then
      if [ -z "$CAF" ] || ! kill -0 "$CAF" 2>/dev/null; then
        # -w $$ : caffeinate auto-releases if this watchdog ever dies (no stuck assertion).
        caffeinate -i -w "$$" & CAF=$!
        log "AWAKE held  (Δcpu=${delta:-0}s, pids=$pids)"
      fi
    else
      if [ -n "$CAF" ] && kill -0 "$CAF" 2>/dev/null; then
        kill "$CAF" 2>/dev/null; log "sleep allowed"
      fi
      CAF=""
    fi

    sleep "$POLL"
  done
}

# Sourceable for tests: `COGWAKE_LIB=1 . bin/cogwake.sh` defines the
# functions without starting the loop.
[ "${COGWAKE_LIB:-0}" = 1 ] || main "$@"
