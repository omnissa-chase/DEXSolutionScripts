# Interactive Reboot With User Deferral — v1.2.0.7

A full-featured, user-aware reboot enforcement script designed for organizations that need to guarantee reboots happen within a defined window without disrupting end users mid-task. Deployed via **Workspace ONE UEM Product Provisioning** due to its size exceeding the WS1 Script upload threshold.

---

## Overview

This script delivers Windows toast notification prompts to the currently logged-in user, giving them the ability to defer a reboot — but enforcing a hard deadline when the deferral window expires. It operates entirely without third-party dependencies, using only native .NET/WinRT libraries and Windows Task Scheduler.

### Key Characteristics

| Property | Detail |
|---|---|
| **Deployment Method** | Workspace ONE Product Provisioning |
| **Execution Context** | SYSTEM (orchestrator) + Interactive User (toast) |
| **Enrollment Required** | Hub-Managed or Fully Managed |
| **PowerShell Version** | 5.1+ |
| **Third-party Dependencies** | None — uses native WinRT toast APIs |

---

## How It Works

The script uses a multi-process architecture to bridge the gap between SYSTEM-context execution and user-visible toast notifications:

1. **Orchestrator Scheduled Task** — Runs as SYSTEM on a polling interval. Checks whether a reboot has already occurred (cleans itself up if so) and whether any users are actively logged in.
2. **Per-User Toast Task** — For each active user session, the orchestrator dynamically registers a one-shot scheduled task running as that user's identity. This task fires `UserToast.ps1`, which displays the toast notification in the user's session.
3. **Enforcement** — When the deadline is reached (`MaxHours` after first run), the next poll triggers an immediate `shutdown.exe /r /t <countdown> /f` and shows a mandatory "saving your work" countdown toast instead of a deferral prompt.
4. **Self-Cleanup** — After the machine reboots, the orchestrator task detects the new boot time, removes all scheduled tasks, registry keys, and helper scripts automatically.

### Architecture Diagram

```
WS1 Product Provisioning
        │
        ▼
Invoke_RebootWithUserDefer_1.2.0.7.ps1   (runs as SYSTEM)
        │
        ├── Writes helper scripts to disk:
        │       C:\ProgramData\AirWatch\Extensions\AdvancedReboot\
        │           RebootMainThread.ps1
        │           UserToast.ps1
        │
        ├── Registers Scheduled Task: \WorkspaceOneEx\RebootPrompt-Orchestrator
        │       Runs as: SYSTEM
        │       Trigger: Repeating every $PollMinutes minutes
        │
        └── Orchestrator (RebootMainThread.ps1)
                │
                ├── Checks: Has machine rebooted since FirstRunAt? → Cleanup & exit
                ├── Checks: Is deadline past? → Force shutdown
                └── For each active user session:
                        └── Registers one-shot task → UserToast.ps1 (runs as user)
                                └── Displays WinRT toast notification
                                        ├── "Reboot now" button
                                        └── "Not now" button (if not past deadline)
```

---

## Configuration

All configurable values are at the top of the script:

| Parameter | Default | Min | Max | Description |
|---|---|---|---|---|
| `$MaxHours` | `4` | `0` | `168` | Hours until the reboot is forced. Set to `0` to force immediately on next poll. |
| `$ShowEveryMinutes` | `30` | `30` | `1440` | How frequently the toast notification re-appears to the user. |
| `$RebootCountdownSeconds` | `300` | `30` | — | Seconds the user has to save work after the deadline triggers. |
| `$PollMinutes` | `5` | — | — | How often the orchestrator task checks conditions. |

---

## Registry Keys

| Path | Purpose |
|---|---|
| `HKLM:\Software\AirWatch\Extensions\AdvancedReboot` | Machine-level state (FirstRunAt, Deadline) |
| `HKLM:\Software\AirWatch\Extensions\AdvancedReboot\<username>` | Per-user deferral state |

---

## File Locations

| File | Path |
|---|---|
| Helper scripts | `C:\ProgramData\AirWatch\Extensions\AdvancedReboot\` |
| Orchestrator task | `Task Scheduler → \WorkspaceOneEx\RebootPrompt-Orchestrator` |

---

## Deployment — Product Provisioning

Because this script exceeds the Workspace ONE UEM Script file size limit, it **must** be deployed via **Product Provisioning**, not Script Management.

See [Runbook-Agent.md](Runbook-Agent.md) for step-by-step deployment instructions.