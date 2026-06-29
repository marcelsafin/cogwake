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

You close the laptop to catch your train. An agent was mid-task. On battery, macOS clamshell-sleep suspends it within a second or two, and the phone tether drops with it. cogwake holds the Mac awake while an agent burns CPU, keeps running when you close the lid, and lets the Mac sleep about 30 seconds after the agent goes quiet.

It targets the work, not the app. An agent parked at a prompt uses no CPU, so the Mac sleeps on its normal timer.

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

### Battery floor

A closed laptop in a bag should never run itself flat. On battery below `BATT_FLOOR` percent (default 15), cogwake releases the flag and lets the Mac sleep.

## Install

```bash
git clone https://github.com/marcelsafin/cogwake.git && cd cogwake
sudo ./install.sh
```

`install.sh` copies the script to `/usr/local/bin`, the config to `/usr/local/etc/cogwake.env`, renders the LaunchDaemon plist into `/Library/LaunchDaemons`, and loads it in the system domain. It starts at boot and respawns if it dies.

## Verify

```bash
# loaded?
sudo launchctl print system/io.github.marcelsafin.cogwake | grep -E 'state|pid'

# what has it done?
tail -f /var/log/cogwake.log

# is sleep disabled right now?
pmset -g | grep SleepDisabled
```

While an agent works you see `SleepDisabled 1`. Stop the agent, wait past the hold, and it reads `0` again.

## Configure

Edit `/usr/local/etc/cogwake.env`:

| Knob | Default | Meaning |
|------|---------|---------|
| `AGENT_RE` | `copilot\|claude\|codex\|aider\|cursor-agent\|ollama\|gemini-cli\|continue` | command patterns that count as an agent |
| `BUSY_CPU` | `0.30` | CPU-seconds per window that count as working (≈15% of one core) |
| `HOLD` | `30` | seconds awake after the last activity |
| `BATT_FLOOR` | `15` | on battery, release below this charge % |
| `WINDOW` | `2` | CPU sample window, seconds |
| `POLL` | `5` | pause between checks, seconds |

Reload after an edit:

```bash
sudo launchctl kickstart -k system/io.github.marcelsafin.cogwake
```

## Test

```bash
bash test/selfcheck.sh   # CPU-time parser, process-tree walk, lid + battery probes
```

## Limits

- It reads CPU, not intent. A long remote reasoning step with no local CPU and no token traffic past `HOLD` can still let the Mac sleep. Raise `HOLD` to cover that.
- `disablesleep=1` keeps the display awake too while an agent runs. macOS has no clamshell-only hold on battery.
- Closed lid plus full CPU means no airflow. A long job in a sealed bag runs warm. The battery floor guards the charge, not the heat.
- The daemon resets `disablesleep` to `0` on exit, and again at its next start, so a crash leaves no stuck always-awake state.
- VS Code coverage rides on `copilot-language-server`. Add other editor agents to `AGENT_RE` by process name.

## Uninstall

```bash
sudo ./uninstall.sh
```

This removes the LaunchDaemon, resets `disablesleep` to `0`, and keeps your config and logs.

## License

MIT. See [LICENSE](LICENSE).
