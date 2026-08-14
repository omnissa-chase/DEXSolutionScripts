# General Testing Guide

**Audience:** Admins doing local, hands-on validation of the scripts/sensors below before they're rolled out through Workspace ONE UEM. Every step here runs the file directly on a local test machine — nothing in this guide requires a UEM console, tenant, or profile assignment.

**Scope:** Four items —
1. Startup / logon duration (sensor + log-enablement script + resolution scripts)
2. User profile size/last-login measurement (sensor + resolution script)
3. Printer list reporting (sensor)
4. Folder Redirection health (recurring list sensor + one-time latency/risk probe sensor)

---

## How to run these locally

All scripts below are `Context: System` — in production they run as SYSTEM via UEM. For local testing, an elevated (Run as Administrator) PowerShell 5.1 session is sufficient for functional validation. If a script behaves differently than expected and you suspect it's context-related (e.g. it reads a different registry hive under your admin account than it would under SYSTEM), you can get true SYSTEM parity locally with Sysinternals `PsExec64.exe -s -i powershell.exe`.

To run a sensor and inspect its JSON output:

```powershell
$json = & 'C:\path\to\sensor.ps1'
$json                                       # raw compact JSON, exactly what UEM would receive
$json | ConvertFrom-Json | Format-List      # readable, flat fields
$json | ConvertFrom-Json | ConvertTo-Json -Depth 5   # readable, nested/array fields
```

---

## 1. Startup / Logon Duration

### 1.1 Sensor — logon_duration_measure.ps1

[GenericTroubleshooting/WindowsStartup/OneTimeSensor/logon_duration_measure.ps1](GenericTroubleshooting/WindowsStartup/OneTimeSensor/logon_duration_measure.ps1)

One-time/run-once sensor — mines event logs for the most recent interactive logon and returns every phase timing as one JSON object. Run it directly per the snippet above; no scheduled task or registry cache needed. Note it self-enforces a 25s deadline, so a very slow/degraded machine may return partial results with `TimedOut: true`.

| JSON field | What it means |
|---|---|
| `Status` | `"OK"` or `"Failed"` (see `Error` on failure) |
| `TimedOut` | `true` if the sensor's own 25s budget ran out before every phase finished |
| `Username` | `DOMAIN\user` of the logon being measured |
| `LogonTime` / `ShellReadyTime` | ISO timestamps: session start (TS EID 21/25) and desktop-ready (Winlogon EID 7001) |
| `DataCollectedAt` | When the sensor ran |
| `TotalMs` | End-to-end logon duration, `LogonTime` → `ShellReadyTime` |
| `GpStartTime` / `GpMs` | Group Policy processing start / total duration (EID 4001→8001) |
| `GpScriptsMs` | GP logon scripts only (EID 4018→5018, ScriptType=1) |
| `FolderRedirectMs` | Folder Redirection duration (EID 501→502) |
| `ProfileLoadMs` | User Profile Service load duration (EID 1→2) |
| `FslogixAttachMs` | FSLogix VHD(X) container attach duration (if FSLogix is installed) |
| `ActiveSetupMs` | Per-user ActiveSetup duration (Shell-Core EID 62170→62171) |
| `AppxLoadMs` | AppX/UWP registration duration (AppReadiness EID 209) |
| `PrintersMappedCount` / `PrinterMappingMs` | Count/duration of printer connections mapped at logon (PrintService/Operational EID 300→306) |
| `LogonTaskCount` / `LogonTaskTotalMs` | Count/duration of `AtLogOn` scheduled tasks that ran (TaskScheduler/Operational EID 100→102) |

Sentinel values on any `*Ms`/`*Count` field, instead of a real number:

| Value | Meaning |
|---|---|
| `-1` | Unknown — phase couldn't be measured |
| `-2` | Not applicable — feature not present on this device (e.g. no FSLogix) |
| `-3` | Log disabled — run **1.2** below first |
| `-4` | Timed out — the sensor's own deadline hit before this phase ran |

### 1.2 Log enablement script — Enable-LogonAuditLogs.ps1

[GenericTroubleshooting/WindowsStartup/Enable-LogonAuditLogs.ps1](GenericTroubleshooting/WindowsStartup/Enable-LogonAuditLogs.ps1)

`PrinterMappingMs`/`PrintersMappedCount` and `LogonTaskCount`/`LogonTaskTotalMs` above read from two Windows event logs (`Microsoft-Windows-PrintService/Operational`, `Microsoft-Windows-TaskScheduler/Operational`) that are **disabled by default**. Run this script once, elevated, before testing 1.1 if you want those two fields populated instead of `-3` (Log disabled):

```powershell
& 'C:\path\to\Enable-LogonAuditLogs.ps1'
```

Verify it worked:

```powershell
wevtutil gl "Microsoft-Windows-PrintService/Operational"
wevtutil gl "Microsoft-Windows-TaskScheduler/Operational"
# both should report "enabled: true"
```

### 1.3 Resolution scripts

Each targets one measured phase from 1.1. All four support a `WhatIf` environment variable — **set `WhatIf=true` for your first local run of each one**, which logs what it would change without changing anything:

```powershell
$env:WhatIf = 'true'
& 'C:\path\to\Invoke-AutoRemediateFSLogixExclusions.ps1'
```

| Resolution script | Targets sensor field | What it does |
|---|---|---|
| [Invoke-AutoRemediateFSLogixExclusions.ps1](WindowsAutoRemediation/WindowsLogon/Invoke-AutoRemediateFSLogixExclusions.ps1) | `FslogixAttachMs` | Adds Microsoft's documented Defender exclusions for FSLogix processes/VHD(X) paths |
| [Invoke-AutoRemediateProfileBloat.ps1](WindowsAutoRemediation/WindowsLogon/Invoke-AutoRemediateProfileBloat.ps1) | `ProfileLoadMs` | Deletes aged, regenerable per-user caches (temp, browser, Teams, thumbnails, crash dumps) |
| [Invoke-AutoRemediateLogonTaskContention.ps1](WindowsAutoRemediation/WindowsLogon/Invoke-AutoRemediateLogonTaskContention.ps1) | `LogonTaskCount` / `LogonTaskTotalMs` | Staggers third-party `AtLogOn` scheduled task trigger delays so they don't all fire at once |
| [Invoke-AutoRemediateAppXBloat.ps1](WindowsAutoRemediation/WindowsLogon/Invoke-AutoRemediateAppXBloat.ps1) | `AppxLoadMs` | Deprovisions non-essential inbox AppX packages for future user profiles |

Full details/parameters for all four: [WindowsAutoRemediation/WindowsLogon/README.md](WindowsAutoRemediation/WindowsLogon/README.md)

`GpMs`, `GpScriptsMs`, `FolderRedirectMs`, `ActiveSetupMs`, and `PrintersMappedCount`/`PrinterMappingMs` don't have a dedicated resolution script in this repo yet — they're reported for visibility only today.

### 1.4 Reference docs (background, not required to test locally)

- [GenericTroubleshooting/WindowsStartup/MeasureLogonDurationSensor.md](GenericTroubleshooting/WindowsStartup/MeasureLogonDurationSensor.md) — deployment guide for this sensor + the log-enablement script
- [GenericTroubleshooting/WindowsStartup/Measure-LogonDuration-UEM-Deployment.md](GenericTroubleshooting/WindowsStartup/Measure-LogonDuration-UEM-Deployment.md) — deployment guide for the original recurring collector (`Measure-LogonDuration.ps1`), not needed for this local test pass

---

## 2. User Profile Measurement

### 2.1 Sensor — profile_size_inventory.ps1

[DiskCleanup/profile_size_inventory.ps1](DiskCleanup/profile_size_inventory.ps1)

One-time/run-once sensor — lists every non-special local user profile with size on disk and days since last login, as one JSON object. Run it directly per the snippet above.

| JSON field | What it means |
|---|---|
| `Status` | `"OK"` or `"Failed"` (see `Error` on failure) |
| `DataCollectedAt` | When the sensor ran |
| `ProfileCount` | Number of profiles reported in `Profiles` |
| `TotalSizeMB` | Sum of `SizeMB` across all profiles that finished sizing (excludes any `-4` timed-out entries) |
| `Truncated` | `true` if the 25s shared budget ran out before every profile was sized |
| `Profiles[].Username` | Folder name of the profile (e.g. `chase`) |
| `Profiles[].LocalPath` | Full path to the profile (e.g. `C:\Users\chase`) |
| `Profiles[].SizeMB` | Size on disk in MB, or `-4` (timed out — budget ran out before this profile was walked) |
| `Profiles[].DaysSinceLastLogin` | Days since last use, or `-1` (unknown — no `LastUseTime` recorded) |
| `Profiles[].Loaded` | `true` if the profile is currently loaded (an active session) |

### 2.2 Resolution script — Start-UserProfileCleanup.ps1

[DiskCleanup/Start-UserProfileCleanup.ps1](DiskCleanup/Start-UserProfileCleanup.ps1)

Deletes whole profiles that are **both** inactive and over the size threshold below.

> **This script has no `WhatIf`/dry-run mode — it deletes matching profiles for real.** Before running it, open the script and confirm the tunables at the top match what you intend to test:

| Variable | Default | Meaning |
|---|---|---|
| `$ENROLLMENTUSER` | `"Administrator"` | Never deleted, regardless of age/size |
| `$DAYS_INACTIVE` | `30` | A profile must be unused this many days to qualify |
| `$SIZE_THRESHOLD_MB` | `500` | A profile must also exceed this size to qualify (`0` = ignore size, delete all inactive) |
| `$LOG_PATH` | `C:\Temp\Logs\ProfileCleanup.log` | Where run output is logged |

Recommended safe first test: raise `$DAYS_INACTIVE` (or `$SIZE_THRESHOLD_MB`) high enough that no real profile on your test machine qualifies, run it once, and confirm the log shows the expected profiles being *examined* (not deleted) before lowering the thresholds to something that will actually match a disposable test profile.

---

## 3. Printer List Reporting

### 3.1 Sensor — printer_inventory.ps1

[WindowsAutoRemediation/printer_inventory.ps1](WindowsAutoRemediation/printer_inventory.ps1)

Recurring sensor (fast, local WMI query — no event-log mining, no one-time budget needed). Lists every printer registered with the local print spooler as one JSON object. Run it directly per the snippet above.

| JSON field | What it means |
|---|---|
| `Status` | `"OK"` or `"Failed"` (see `Error` on failure) |
| `DataCollectedAt` | When the sensor ran |
| `PrinterCount` | Number of printers reported in `Printers` |
| `DefaultPrinter` | Name of the current default printer, or `null` |
| `Printers[].Name` | Printer name |
| `Printers[].DriverName` / `PortName` | Driver and port the printer is configured with |
| `Printers[].Default` | `true` if this is the default printer |
| `Printers[].Network` / `Shared` / `ShareName` | Whether the printer is a network connection, and/or shared out with a share name |
| `Printers[].Location` / `Comment` | Admin-set descriptive fields, or `null` if empty |
| `Printers[].WorkOffline` | `true` if the printer is set to work offline |
| `Printers[].Status` | Human-readable spooler status: `Idle`, `Printing`, `Offline`, etc. |
| `Printers[].ErrorState` | Human-readable device condition (`Low toner`, `Paper jammed`, `Door open`, etc.), or `null` if none reported |

> SYSTEM context enumerates the machine-wide spooler; a network printer connected only inside the interactive user's own session may not appear here if it was never registered at the machine level.

---

## 4. Folder Redirection Health

### 4.1 Sensor — logon_folder_redirection_map.ps1

[GenericTroubleshooting/WindowsStartup/Sensors/logon_folder_redirection_map.ps1](GenericTroubleshooting/WindowsStartup/Sensors/logon_folder_redirection_map.ps1)

Recurring sensor (registry-only, no disk enumeration or network calls). Lists every Folder Redirection-eligible known folder for the active interactive user and its current target path. Run it directly per the snippet above.

| JSON field | What it means |
|---|---|
| `Status` | `"OK"` or `"Failed"` (see `Error` on failure) |
| `DataCollectedAt` | When the sensor ran |
| `Username` | `DOMAIN\user` whose folders are being reported |
| `RedirectedCount` | Number of folders in `Folders` whose path is a UNC path |
| `Folders[].Folder` | Known-folder name (`Desktop`, `Documents`, `AppDataRoaming`, `Downloads`, etc. — 13 total, including the 5 GUID-keyed folders with no classic name) |
| `Folders[].Path` | Current resolved target path, or `null` if the registry value isn't set |
| `Folders[].Redirected` | `true` if `Path` is a UNC path (`\\server\share\...`) rather than local |

> `Redirected: false` does not always mean "not customized" — OneDrive Known Folder Move rewrites these same registry values to point at a local OneDrive path, which correctly reports `Redirected: false` here since it isn't a network path.

### 4.2 Sensor — logon_folder_redirection_latency_probe.ps1

[GenericTroubleshooting/WindowsStartup/OneTimeSensor/logon_folder_redirection_latency_probe.ps1](GenericTroubleshooting/WindowsStartup/OneTimeSensor/logon_folder_redirection_latency_probe.ps1)

One-time/run-once companion to 4.1. For every UNC-redirected folder it finds, times a bounded TCP:445 connect to the target server and a bounded folder-existence check, then combines reachability/latency with a static per-folder impact weight into a risk score. Self-enforces a 15s budget (30s UEM hard ceiling); every individual network/file check is capped at 1.5s so one dead server can't consume the whole run. Run it directly per the snippet above.

| JSON field | What it means |
|---|---|
| `Status` | `"OK"` or `"Failed"` (see `Error` on failure) |
| `DataCollectedAt` | When the sensor ran |
| `Username` | `DOMAIN\user` whose folders are being probed |
| `TimedOut` | `true` if the sensor's own 15s budget ran out before every redirected folder was probed |
| `OverallRiskScore` | Sum of every folder's `RiskScore` |
| `OverallSeverity` | `NotApplicable` (nothing redirected), `Normal`, `Elevated`, or `Critical` — bucketed from `OverallRiskScore` |
| `Folders[].Folder` / `Path` / `Redirected` | Same meaning as 4.1 |
| `Folders[].Reachable` | `true`/`false` if a TCP:445 connect to the target server succeeded within 1.5s; `null` if not redirected |
| `Folders[].ConnectMs` | TCP connect time in ms (latency proxy) — `null` if not redirected or unreachable |
| `Folders[].LikelyServedByCache` | `true` if the server was unreachable but the folder still resolved instantly — a strong signal Offline Files (CSC) is serving it locally instead of over the network |
| `Folders[].Severity` | `NotApplicable`, `Normal`, `Elevated` (`ConnectMs >= 150`), `Critical` (unreachable), or `TimedOut` (budget ran out before this folder was probed) |
| `Folders[].RiskScore` | Per-folder weighted score — `AppDataRoaming`/`Desktop`/`Start Menu` are weighted highest since they're read synchronously during shell init; `-4` if `Severity` is `TimedOut` |

> Why two sensors instead of one: this repo's sensor conventions reserve network calls for one-time sensors only, so the cheap registry-only listing (recurring) and the network reachability probe (one-time) can't be the same script.
