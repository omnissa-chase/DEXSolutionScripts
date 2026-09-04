# Process Management — Graceful Close and Restart

Reference for `Restart-WinProcessGraceful.ps1`. The script header carries the parameter
contract (`Get-Help` still works); the architecture and the reasoning behind each design
decision live here, because the script has to fit inside UEM's 32,767-character script
object limit.

| Script | Purpose |
|---|---|
| `Restart-WinProcess.ps1` | Blunt restart. No graceful phase. |
| `Restart-WinProcessGraceful.ps1` | Graceful close with hang detection and user-work protection. **Start here.** |
| `Restart-WinProcessGracefulEx.ps1` | Earlier variant, retained for reference. |
| `Restart-WinService.ps1` | Service restart. |

---

## Architecture

```
Launcher (Hub thread)  ->  Watchdog (Task Scheduler)  ->  Sensor (reads result)
```

**Launcher** — discovers processes matching `FileDescription`, self-extracts the watchdog
to `%ProgramData%\AirWatch\Extensions\ProcessGraceful\Watch-ProcessClose.ps1`, writes
`state.json` beside it, registers scheduled task `WS1_ProcessGracefulWatchdog` with no
trigger, starts it on demand, and exits 0 in ~1–2 seconds.

**Watchdog** — sends the graceful close signal, polls each target once per second,
optionally restarts, writes `result.json`, and self-unregisters.

### Why a scheduled task, not `Start-Job`

Background jobs are child runspaces of the calling process. When Intelligent Hub reaps
this script's process tree, the job dies with it. A Task Scheduler-owned process is
genuinely detached and survives.

### Why the watchdog runs in the user session

Hang detection requires window-station access, which exists only inside an interactive
session. Running as SYSTEM in session 0:

- `MainWindowHandle` is always `IntPtr::Zero` for user-session processes
- therefore `Responding` cannot be read, so hang detection is impossible
- and a restart would launch invisibly into session 0

So the watchdog runs as the logged-on user (`LogonType Interactive`, `RunLevel Limited`).
Limited rather than Highest keeps it at least privilege — sufficient for closing the
user's own non-elevated processes.

**When no user is logged on** it falls back to SYSTEM. Responsiveness is unmeasurable
there, so it sends the graceful close signal and reports the outcome but **never**
force-kills. A process that cannot be measured must not be assumed hung.

---

## Protecting unsaved user work

This is the part that matters most, and it rests on one observation:

> **The save prompt is the detector.** There is no API that answers "does this app have
> unsaved changes?" But you get the answer for free — send `WM_CLOSE` and watch. If the
> process exits, nothing was unsaved. If it stays alive *and keeps responding*, it is
> showing a modal and waiting on a human.

### A responding process is never force-killed

With `ForceOnlyIfUnresponsive = $true` (default), a healthy process still open at the
deadline is reported `UserActionRequired` and **left running**. That single branch is the
whole data-loss defence.

Force-kill is reserved for a process confirmed hung: `UnresponsiveSampleCount` consecutive
1-second checks reporting `Responding = false`, with the streak reset on any recovery.
The reset matters — an app mid-save on a large file stops pumping messages and looks hung
for a moment. Requiring a sustained streak stops a slow save being mistaken for a crash.

### User-action retry

`UserActionRequired` used to be terminal: reported, left alone, and the remediation simply
did not happen until someone noticed the sensor.

The watchdog now re-attempts up to `UserActionRetryCount` times (default 1), waiting
`UserActionRetryDelaySec` (default 300 s) between attempts. The wait is **polled every
5 seconds, not slept** — a user who answers the prompt and closes the app is picked up
during the wait and never re-signalled.

Escalation rules are unchanged across retries. A responding process is still never forced,
so more attempts never mean more risk.

Only the `UserActionRequired` path loops. When `ForceOnlyIfUnresponsive` is disabled the
deadline resolves straight to `ForceKilled`, nothing is left awaiting the user, and the
loop exits after one pass — opting into forcing is never delayed by the retry window.

### Unsaved-work hint

Before signalling, each windowed process is checked for a modified-document marker in its
window title: a leading `*`, used by Notepad, VS Code, Notepad++ and most editors. Any hit
is recorded on the outcome and in `result.json`.

**It is a hint, never proof.** A hit is meaningful; a miss proves nothing, because most
applications never mark dirty state in the title at all. It is therefore wired so it can
only ever make the script *more* cautious, never less — a clean title is never treated as
permission to force.

With `SkipIfUnsavedWork = $true` a flagged process is left entirely untouched — no close
signal, no kill — and reported `UnsavedWorkSuspected`. Default is `$false`: the hint is
still detected and reported, it just does not block the close attempt.

**Office `~$` owner files are deliberately not probed.** Those appear when a document is
merely *open*, not when it is dirty, so they would flag every open document and train
people to ignore the signal. Window titles are cheap, need no filesystem walk, and are
reported by the app itself.

---

## Outcomes

| Outcome | Meaning | Process left running? |
|---|---|---|
| `ClosedGracefully` | Exited after the close signal, or closed by the user during the retry wait | No |
| `ForceKilled` | Confirmed hung, or deadline reached with `ForceOnlyIfUnresponsive = $false` | No |
| `UserActionRequired` | Still responding at the deadline after every attempt — almost certainly a save prompt | **Yes** |
| `UnsavedWorkSuspected` | Title showed a modified marker and `SkipIfUnsavedWork` was on — never signalled | **Yes** |
| `Error` | Force-kill was attempted and failed | Yes |

A restart is skipped when any process ends `UserActionRequired`, `UnsavedWorkSuspected`, or
`Error` — those are still running, and relaunching would leave the user with two instances.

---

## Timing budget

The scheduled task's `ExecutionTimeLimit` must cover every attempt **and** every wait
between them. Too small and Task Scheduler kills the watchdog mid-retry, leaving no
`result.json` for the sensor to read:

```
GracefulTimeoutSec * (1 + UserActionRetryCount)
  + UserActionRetryDelaySec * UserActionRetryCount
  + 120
```

At defaults: `15 * 2 + 300 + 120 = 450 s`.

Raising `UserActionRetryDelaySec` raises the cap automatically — but remember the watchdog
process stays resident for that whole window. It is detached, so Hub is never blocked, but
do not set a multi-hour delay casually.

---

## Reading the result

The launcher's exit code reflects successful **dispatch**, not the close outcome, because
it returns before the watchdog finishes. The authoritative record is:

- `%ProgramData%\AirWatch\Extensions\ProcessGraceful\state\result.json` — full detail,
  including per-process `Outcome`, `Attempts`, and `UnsavedHint`
- `HKLM:\Software\AirWatch\Extension\DEXRecords\ProcessGraceful` — best-effort summary
  mirror, including `UnsavedWorkSuspectedCount`
- the companion sensor `process_graceful_lastresult.ps1`

Use `-Mode Inline` for lab testing when you need the exit code to reflect the real outcome.
It blocks the caller and is not for production.

---

## Deployment

| Setting | Value |
|---|---|
| Execution Context | System |
| Architecture | x64 |
| PowerShell Version | 5.1 |
| Timeout | 60 s (the launcher returns in ~1–2 s) |

An AV/EDR exclusion on `C:\ProgramData\AirWatch\Extensions\ProcessGraceful` is required.
If execution from that path is blocked the watchdog silently never runs, and the launcher
still reports success because dispatch succeeded.

`FileDescription` is required — pass it as a parameter or set `$env:FileDescription`. It is
matched case-insensitively as a substring against each process's `Description` field (the
`FileDescription` from the binary's version info), e.g. `Microsoft Teams`, `Zoom`,
`Google Chrome`.
