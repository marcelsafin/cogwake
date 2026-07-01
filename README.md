<p align="center">
  <img src="assets/banner.svg" alt="cogwake" width="100%">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-LaunchDaemon-0d1117" alt="macOS LaunchDaemon">
  <img src="https://img.shields.io/badge/bash-3.2%2B-4EAA25" alt="bash 3.2+">
  <img src="https://img.shields.io/badge/sudo-required-f59e0b" alt="sudo required">
  <img src="https://img.shields.io/badge/license-MIT-3b82f6" alt="MIT">
</p>

# cogwake

You close the laptop to catch your train while an agent is mid-task. On battery, macOS clamshell sleep suspends it within a second or two, and your phone tether drops with it. cogwake holds the Mac awake while the agent burns CPU, through the lid close, and releases about 30 seconds after it goes quiet.

cogwake reads CPU. An agent idling at a prompt burns almost none, so the Mac sleeps on its normal timer; a working agent holds it awake.

## Why it needs root

`caffeinate` blocks idle sleep but not a lid close on battery. `caffeinate -s` holds only on AC power. The one switch that survives clamshell on battery is `pmset disablesleep`, and that needs root. cogwake runs as a root LaunchDaemon and flips that switch for you.

## How it decides

A LaunchDaemon samples every few seconds:

1. Find the agent processes by command name (Copilot CLI, Claude, Codex, aider, and the VS Code `copilot-language-server`), plus every child they spawned.
2. Sum the CPU that whole tree burns over a 2 second window.
3. Past the threshold, set `disablesleep=1`.
4. After 30 quiet seconds, set it back to 0. With the lid shut that sleeps the Mac within a few seconds of the agent finishing.

<p align="center">
  <img src="assets/flow.svg" alt="cogwake decision loop: poll agent processes, sum CPU over a 2s window, set disablesleep=1 while busy or within 30s, release when quiet" width="94%">
</p>

### Winning the lid-close race

The kernel checks `disablesleep` at the instant the lid shuts. A 5 second poll cannot set it after the fact. The Mac is already asleep. So cogwake pre-arms: while the agent is active it holds `disablesleep=1` even with the lid open, so closing the lid mid-task keeps the work running and the tether up. Thirty quiet seconds drops the flag.

### Battery: runs until it dies

By default cogwake keeps working on battery with no charge floor. Set `BATT_FLOOR` to a percent (say 15) if you want it to stop and sleep before the battery runs out. Off by default because the thermal valve guards the real bag risk.

### Thermal valve

A closed laptop in a bag has no airflow, so heat threatens the hardware before a drained battery does. With the lid shut, cogwake samples macOS thermal pressure. At a serious level (`THERM_RE`, default `heavy|trapping|sleeping|serious|critical`) it releases the override and lets the Mac sleep to cool, even mid-task. Your work pauses with the process frozen, and resumes when you open the lid. Normal load that only warms the Mac (moderate or fair pressure) keeps running.

### Footprint

cogwake can't go fully idle while the lid is open. To win the lid-close race it has to pre-arm, which means a light pulse must run with the lid open to keep the flag right. That pulse is one `pgrep` plus one `ps` scan, about 0.08 CPU-seconds per cycle, and with the lid open it polls every `LID_OPEN_POLL` seconds (default 15). The heavy part, the `powermetrics` thermal sample, runs only with the lid shut. So at your desk it costs near zero, and it does the real work in the bag.

## Install

```bash
git clone https://github.com/marcelsafin/cogwake.git && cd cogwake
sudo ./install.sh
```

`install.sh` copies the script to `/usr/local/bin`, the config to `/usr/local/etc/cogwake.env`, renders the LaunchDaemon plist into `/Library/LaunchDaemons`, and loads it in the system domain. It starts at boot and respawns if it dies. Nothing to run day to day: it stays passive until an agent burns CPU.

## Control

```bash
cogwake status     # ON/OFF, whether sleep is blocked right now, recent log
cogwake off        # stop guarding; Mac sleeps normally (persists across reboot)
cogwake on         # resume
cogwake restart    # reload after editing the config
cogwake log        # follow the activity log
```

`status` and `log` need no root; `on`, `off`, and `restart` prompt for it. While an agent works, `status` shows `sleep: BLOCKED`; idle, it shows `allowed`.

## Configure

Edit `/usr/local/etc/cogwake.env`:

| Knob | Default | Meaning |
|------|---------|---------|
| `AGENT_RE` | `copilot\|claude\|codex\|aider\|cursor-agent\|ollama\|gemini-cli\|continue` | command patterns that count as an agent |
| `EXCLUDE_RE` | `\.app/Contents/\|...\|copilot-detached` | command substrings that disqualify a match (GUI apps, daemons, detached dev servers) |
| `BUSY_CPU` | `0.30` | CPU-seconds per window that count as working (≈15% of one core) |
| `HOLD` | `30` | seconds awake after the last activity (raise for tethered, slow-network work) |
| `THERM_POLL` | `30` | seconds between thermal samples (the one costly call) |
| `BATT_FLOOR` | `0` | on battery, release below this % (`0` = run till it dies) |
| `THERM_GUARD` | `1` | with the lid shut, sleep on serious thermal pressure |
| `THERM_RE` | `heavy\|trapping\|sleeping\|serious\|critical` | pressure levels that count as too hot |
| `WINDOW` | `2` | CPU sample window, seconds |
| `POLL` | `5` | pause between checks while the lid is shut |
| `LID_OPEN_POLL` | `15` | pause between checks while the lid is open (lighter) |

Reload after an edit:

```bash
cogwake restart
```

## Test

```bash
bash test/selfcheck.sh      # unit: CPU-time parser, tree walk, lid/battery probes, is_hot, EXCLUDE_RE
bash test/integration.sh    # state machine: 14 hold/release scenarios via mocked sensors
```

`integration.sh` drives `decide()` (the whole hold/release logic) with a controlled clock and mocked battery/thermal/lid sensors, so the battery-floor, thermal valve, sticky-heat, and HOLD-tail behavior are all verified without root or hardware.

## Limits

- It reads CPU. It cannot see intent, so a long remote reasoning step with no local CPU and no token traffic past `HOLD` can still let the Mac sleep. Raise `HOLD` to cover that.
- Detection matches the whole command line, so a GUI app or daemon whose path holds an agent word (a browser bundled as `<name>.app`, a desktop chat app) would over-match. `EXCLUDE_RE` drops those by command; add your own if something slips through. Check `agent_tree` against `/var/log/cogwake.log`.
- `disablesleep=1` keeps the display awake too while an agent runs. macOS has no clamshell-only hold on battery.
- The thermal valve reads macOS thermal pressure, which needs root (no temp sysctl on Apple Silicon). It samples only while the lid is shut. Check the log for the level your Mac reports and tune `THERM_RE`.
- The daemon resets `disablesleep` to `0` on exit, and again at its next start, so a crash leaves no stuck always-awake state.
- VS Code coverage rides on `copilot-language-server`. Add other editor agents to `AGENT_RE` by process name.

## Uninstall

```bash
sudo ./uninstall.sh
```

This removes the LaunchDaemon, resets `disablesleep` to `0`, and keeps your config and logs.

## License

MIT. See [LICENSE](LICENSE).
