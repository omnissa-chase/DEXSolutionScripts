# Measure-LogonDuration.ps1 — Workspace ONE UEM Deployment Guide

Audience: Horizon / EUC engineers deploying this script as a Workspace ONE UEM
resource. This document covers what the script does, the event log prerequisite,
the three deployment modes, and how to wire it up in the UEM console.

---

## What this script does

Runs as **SYSTEM** and mines Windows event logs for the most recent interactive
logon of the currently logged-on user, breaking the logon down into phases:

| Phase | Source |
|---|---|
| Total logon duration | TerminalServices-LocalSessionManager EID 21 → Winlogon EID 7001 |
| Group Policy total | Group Policy EID 4001 → EID 8001 |
| GP Logon Scripts | Group Policy EID 4018 → EID 5018 (ScriptType=1) |
| Folder Redirection | Microsoft-Windows-Folder Redirection EID 501 → 502 |
| User Profile load | User Profile Service EID 1 → 2 |
| FSLogix container attach | FSLogix Operational log (if present) |
| ActiveSetup | Microsoft-Windows-Shell-Core EID 62170 → 62171 |
| AppX / UWP packages | Microsoft-Windows-AppReadiness EID 209 |
| Printer mapping | PrintService/Operational EID 300 → 306 **(requires log enabled)** |
| Scheduled tasks at logon | TaskScheduler/Operational EID 100 → 102 **(requires log enabled)** |

Results are written as string registry values under:

```
HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration
```

DEX sensors read from this key. Sensor scripts and naming are in
[`Sensors/`](./Sensors) — 17 individual value sensors plus one monolithic JSON
sensor (`logon_duration_summary.ps1`). Deploy the sensors as their own DEX
Sensor resources; they do not need to be part of this deployment.

---

## ⚠️ Event log prerequisite — read this first

Two of the ten phases depend on Windows event logs that are **disabled by
default** on a stock image:

- `Microsoft-Windows-PrintService/Operational`
- `Microsoft-Windows-TaskScheduler/Operational`

If these logs are off, the script still runs cleanly — it does **not** fail —
but the printer-mapping and scheduled-task phases write the sentinel string
`LogDisabled` instead of a measurement, and the corresponding sensors report
`-3` rather than a real value.

**You must enable these logs on every target device before those two phases
will report real data.** There are two ways to do this — pick one:

1. **One-time, recommended:** Deploy once with `DeployMode = ConfigureLogging`
   (see Mode 3 below), then deploy again with the mode you actually want.
2. **Combined in a single deployment:** Set `ConfigureLoggingFirst = true`
   alongside `RunNow` or `DeployScheduledTask`. The script enables the logs
   immediately before it does anything else, and only does this once per
   device — a registry marker (`AuditLogsConfiguredAt`) prevents it from
   shelling out to `wevtutil` on every run.

If you skip this step entirely, the script is still useful — total logon
duration, Group Policy, profile load, folder redirection, FSLogix, ActiveSetup,
and AppX timings all work with default Windows logging. You are only giving up
the printer and scheduled-task breakdowns.

---

## Deployment modes

The script is controlled by two settings, each of which can be delivered as a
UEM script **variable** (environment variable) or, if invoking manually, as a
PowerShell parameter. An explicitly passed parameter always overrides the
environment variable.

| Setting | Values | Default |
|---|---|---|
| `DeployMode` | `RunNow` \| `DeployScheduledTask` \| `ConfigureLogging` | `RunNow` |
| `ConfigureLoggingFirst` | `true` / `1` / `yes` / `y` (anything else = false) | `false` |

An unrecognised `DeployMode` value coming from the environment (e.g. a typo in
the UEM console) does **not** fail the deployment — it logs a warning and
falls back to `RunNow`.

### Mode 1 — `RunNow` (measure once, immediately)

Runs the measurement a single time against the currently logged-on user and
writes results to the registry, then exits. This is the mode to use if the
script itself is triggered by a WSO **logon** script trigger on every logon —
in that case UEM re-invokes the whole script each time, so no local scheduled
task is needed.

```
DeployMode = RunNow
```

Use this when your deployment mechanism already re-runs the script at every
logon (e.g. assigned as a Workspace ONE **logon trigger**).

### Mode 2 — `DeployScheduledTask` (install-once, run-forever)

Copies the script to `C:\ProgramData\AirWatch\Extensions\DEXTools` and
registers a **SYSTEM** scheduled task (`DEXTools_MeasureLogonDuration`) that
fires on every user logon with a 30-second delay (to let event log entries
flush). After this one-time deployment, the local scheduled task does the
measuring — no further UEM agent time is consumed per logon.

```
DeployMode = DeployScheduledTask
```

The task is registered to always call the local copy with
`-DeployMode RunNow -ConfigureLoggingFirst $false` explicitly — it can never
pick up a machine-level environment variable, so logging setup and
redeployment stay deployment-time concerns, not per-logon ones.

**Recommended for most fleets** — deploy once via UEM, let the task handle
every subsequent logon.

### Mode 3 — `ConfigureLogging` (enable optional event logs only)

Enables `PrintService/Operational` and `TaskScheduler/Operational` if not
already enabled, then exits without measuring anything. Safe to re-run —
already-enabled logs are reported and skipped.

```
DeployMode = ConfigureLogging
```

Use this as a one-time prep deployment ahead of Mode 1 or 2, or skip it
entirely by combining with `ConfigureLoggingFirst = true` in your primary
deployment (see below).

### Combining: enable logging and measure/deploy in one shot

Set both variables together to avoid a separate prep deployment:

```
DeployMode             = DeployScheduledTask
ConfigureLoggingFirst  = true
```

This enables the optional logs, then proceeds with the requested mode, in a
single UEM deployment. Idempotent — safe to leave `ConfigureLoggingFirst = true`
permanently, since the registry marker skips the `wevtutil` work after the
first successful run.

---

## Workspace ONE UEM console setup

**Resources → Scripts → Add**

| Field | Value |
|---|---|
| Script Type | PowerShell |
| Execution Context | **System** |
| Execution Architecture | 64-bit |
| Timeout | 60 seconds (measurement is fast; allow headroom on first run if `ConfigureLoggingFirst` is set) |
| Variables | `DeployMode` (String), `ConfigureLoggingFirst` (String) — set per assignment group as needed |

**Recommended assignment pattern:**

1. First deployment to the fleet (one-time): `DeployMode = DeployScheduledTask`,
   `ConfigureLoggingFirst = true`. This enables logging and installs the
   scheduled task in one pass.
2. Leave the script assigned with those same variables for new enrollments —
   it is idempotent (`ConfigureLoggingFirst` skips already-configured devices,
   and re-registering the scheduled task simply overwrites it).

If you prefer the logon-trigger model instead of a scheduled task, assign with
`DeployMode = RunNow` on a **logon** trigger instead of Mode 2, and drop the
scheduled-task step entirely.

---

## Verifying a deployment

Check the registry key on a target device after a logon has occurred:

```powershell
Get-ItemProperty -Path 'HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration'
```

- `CollectorVersion` confirms which build of the script wrote the data.
- `DataCollectedAt` confirms freshness — treat any other value as stale if
  this is old.
- Any `*DurationSec` value of `LogDisabled` means the event log prerequisite
  above was not completed on that device.
- Any value of `Unknown` means the phase could not be measured on that
  particular logon (e.g. GP events not found in the log window).
- Any value of `N/A` means the feature does not apply to this device (e.g. no
  FSLogix installed).

To confirm the scheduled task installed correctly (Mode 2):

```powershell
Get-ScheduledTask -TaskName 'DEXTools_MeasureLogonDuration' -TaskPath '\DEXTools\'
```

---

## Notes for engineers

- PowerShell 5.1 compatible — no dependency on PowerShell 7.
- All registry writes use `InvariantCulture` formatting, so values parse
  identically regardless of the device's regional/locale settings.
- The script never fails outright on missing data — every phase degrades to a
  sentinel string (`Unknown` / `N/A` / `LogDisabled`) rather than throwing, so
  a partial logon (e.g. no FSLogix) still produces a usable record.
- See the script's own comment-based help (`Get-Help .\Measure-LogonDuration.ps1
  -Full`) for complete parameter and example documentation.
