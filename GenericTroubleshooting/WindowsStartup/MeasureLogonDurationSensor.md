# MeasureLogonDurationSensor — Workspace ONE UEM Deployment Guide

Audience: Horizon / EUC engineers deploying the **self-contained** logon
duration sensor as a Workspace ONE UEM resource. This is a separate deployment
path from [`Measure-LogonDuration-UEM-Deployment.md`](./Measure-LogonDuration-UEM-Deployment.md) —
use this guide when you want a single one-time sensor pull instead of a
SYSTEM-scheduled collector plus a registry-cache-reading sensor.

---

## What this covers

Two files, deployed independently:

| File | Type | Purpose |
|---|---|---|
| [`OneTimeSensor/logon_duration_measure.ps1`](./OneTimeSensor/logon_duration_measure.ps1) | Sensor (one-time / run-once) | Mines event logs directly and returns the full logon-phase breakdown as one JSON string. No collector, no scheduled task, no registry cache. |
| [`Enable-LogonAuditLogs.ps1`](./Enable-LogonAuditLogs.ps1) | Script | Enables the two optional Windows event logs needed for full phase coverage. Run once per device image ahead of the sensor. |

This path exists because Workspace ONE Intelligence now supports triggering a
genuine **one-time sensor run**. That relaxes the strict "must always be fast"
constraint that a *recurring* sensor is held to — a one-time run may perform
the same event-log mining that previously required a separate SYSTEM-scheduled
collector script, all inside the sensor call itself, provided it still
respects the one-time/run-once sensor ceiling (self-enforced budget, 30
second UEM hard maximum). Use `logon_duration_measure.ps1` when you want a
single on-demand pull without deploying a scheduled task. Use
`Measure-LogonDuration.ps1` (see the other deployment guide) when you want
every logon recorded automatically.

---

## ⚠️ Event log prerequisite — read this first

Two of the twelve phases depend on Windows event logs that are **disabled by
default** on a stock image:

- `Microsoft-Windows-PrintService/Operational`
- `Microsoft-Windows-TaskScheduler/Operational`

If these logs are off, the sensor still runs cleanly and still returns valid
JSON — it does **not** fail — but `PrintersMappedCount`, `PrinterMappingMs`,
`LogonTaskCount`, and `LogonTaskTotalMs` all report `-3` (Log disabled)
instead of a real value.

**Run [`Enable-LogonAuditLogs.ps1`](./Enable-LogonAuditLogs.ps1) once per
device image before relying on those four fields.** It is idempotent — safe
to leave assigned permanently, since a registry marker
(`AuditLogsConfiguredAt`) skips the `wevtutil` work after the first
successful run. That marker is shared with `Measure-LogonDuration.ps1
-DeployMode ConfigureLogging`, so running either one first satisfies both.

If you skip this step entirely, the sensor is still useful — total logon
duration, Group Policy, profile load, folder redirection, FSLogix, ActiveSetup,
and AppX timings all work with default Windows logging. You are only giving up
the printer and scheduled-task breakdowns.

---

## Deploying `Enable-LogonAuditLogs.ps1`

**Resources → Scripts → Add**

| Field | Value |
|---|---|
| Script Type | PowerShell |
| Execution Context | **System** |
| Execution Architecture | 64-bit |
| Timeout | 30 seconds |
| Parameters | None required. Pass `-Force` only if you need to re-check logs that were previously reported enabled. |

Deploy this once per device image / assignment group, ahead of the sensor
below. Exit code `0` means every log that exists on the device is enabled;
`1` means at least one log could not be enabled (check that the script ran
elevated).

---

## Deploying `logon_duration_measure.ps1` as a sensor

**Resources → Sensors → Add**

| Field | Value |
|---|---|
| Sensor Name | `logon_duration_measure` |
| Data Type | String |
| Execution Context | **System** |
| Delivery Mechanism | **One-time / run-once** (not the recurring Sample Schedule) — confirm this option with your Intelligence configuration before assigning |
| Timeout | 30 seconds (UEM hard maximum for a one-time sensor) |
| Parameters | None |

Do **not** assign this sensor to a recurring Sample Schedule. It is
intentionally heavier than a normal sensor (it mines up to twelve separate
event log queries) and only stays within budget because it self-enforces a
25-second deadline internally, leaving headroom under the 30-second UEM
ceiling. A recurring schedule would repeatedly block the sensor queue for
that entire window on every sample interval.

---

## Reading the JSON payload

```json
{
  "Status": "OK",
  "TimedOut": false,
  "Username": "DOMAIN\\user",
  "LogonTime": "2026-08-12T08:30:38",
  "ShellReadyTime": "2026-08-12T08:30:52",
  "DataCollectedAt": "2026-08-12T16:49:05",
  "TotalMs": 14000,
  "GpStartTime": "2026-08-12T08:30:39",
  "GpMs": 3200,
  "GpScriptsMs": 900,
  "FolderRedirectMs": 450,
  "ProfileLoadMs": 1800,
  "FslogixAttachMs": -2,
  "ActiveSetupMs": 120,
  "AppxLoadMs": 300,
  "PrintersMappedCount": -3,
  "PrinterMappingMs": -3,
  "LogonTaskCount": -3,
  "LogonTaskTotalMs": -3
}
```

- `Status` is `"OK"` on a successful run (even if individual phases are
  degraded) or `"Failed"` with an `Error` message if no interactive user could
  be identified at all.
- `TimedOut` is `true` if the sensor's own 25-second budget was reached before
  every phase could run — any phase not yet attempted reports `-4` rather than
  blocking further.
- Sentinel values for every `*Ms` and `*Count` field:

  | Value | Meaning |
  |---|---|
  | `-1` | Unknown — phase could not be measured on this logon |
  | `-2` | Not applicable — feature not present on this device (e.g. no FSLogix) |
  | `-3` | Log disabled — run `Enable-LogonAuditLogs.ps1` first |
  | `-4` | Timed out — self-enforced deadline reached before this phase ran |

- `LogonTime`, `ShellReadyTime`, `GpStartTime`, and `DataCollectedAt` are ISO
  8601 local time, or `null` when unavailable.

---

## Verifying a deployment

Run the sensor manually on a target device and confirm it returns valid JSON:

```powershell
& '.\OneTimeSensor\logon_duration_measure.ps1' | ConvertFrom-Json | Format-List
```

- `TimedOut: false` and no `-4` values means the run completed within budget.
- `-3` values across the printer/task fields mean `Enable-LogonAuditLogs.ps1`
  has not run yet on that device.
- `Status: Failed` means no interactive user was detected — expected if run
  under a session with nobody logged on.

---

## Notes for engineers

- PowerShell 5.1 compatible — no dependency on PowerShell 7.
- Every event-log mining phase is wrapped in its own `try`/`catch`. A provider
  or log missing on a particular OS build/SKU degrades only that one field to
  `-1` — it never fails the whole sensor.
- This sensor does not write to the registry and has no dependency on
  `Measure-LogonDuration.ps1` having ever run. The two are independent
  delivery mechanisms for the same underlying measurements.
- See the sensor's own header comment for the full phase-to-event-ID mapping.
