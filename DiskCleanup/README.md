# DiskCleanup

A collection of PowerShell scripts for automated disk space management and user profile cleanup on Windows endpoints. These scripts are intended to be deployed and executed via **Omnissa Workspace ONE UEM** and monitored through **Omnissa Workspace ONE DEX**.

---

## Scripts Overview

| Script | Type | Purpose |
|---|---|---|
| `Start-DiskCleanup.ps1` | Script | Runs Windows Disk Cleanup against system cleanup categories (previous installations, update artifacts, dumps, logs) |
| `Start-ClearRecycleBin.ps1` | Script | Empties every user's Recycle Bin by clearing the per-user folders on disk |
| `Start-UserProfileCleanup.ps1` | Script | **Deletes** inactive domain user profiles that exceed a size threshold |
| `Get-UserProfileSize.ps1` | Sensor | Read-only report of profile sizes and inactivity. Makes no changes |
| `profile_size_inventory.ps1` | Sensor | Run-once sensor returning every non-special profile as a single JSON payload |

> `Start-DiskCleanup.ps1` drives the built-in Disk Cleanup utility and writes a `StateFlags` value into the `VolumeCaches` registry key for profile ID `55`. `Start-ClearRecycleBin.ps1` no longer uses that utility at all; see its section below for why.

---

## Start-DiskCleanup.ps1

### Description
Automates the Windows built-in Disk Cleanup utility (`cleanmgr.exe`) by programmatically configuring cleanup options via the registry and executing a cleanup profile. Targets system-level categories such as previous Windows installations, update artifacts, error dumps, and upgrade log files.

### Parameters

| Parameter | Environment variable | Default | Description |
|---|---|---|---|
| `-Wait` | `WaitForCleanup` | off | Block until cleanup has finished before measuring free space. |
| `-WaitTimeoutSeconds` | `WaitTimeoutSeconds` | `900` | Upper bound on that wait, in seconds. |

An explicit parameter always beats the environment variable. An absent, empty, or unparseable value resolves to a no-wait run, so a bad input can never leave the script hanging.

### Why -Wait matters
`cleanmgr /sagerun` forks a worker and the launcher returns straight away, so without `-Wait` free space is measured while cleanup is still running and the reclaimed figure is usually zero. With `-Wait` the script blocks until three things are true:

1. All `cleanmgr` processes have exited.
2. The Windows Modules Installer service and its `TiWorker` process are idle. The **Update Cleanup** category hands component store work to that service, and it keeps running well after `cleanmgr` has gone. This is where most of the space comes back.
3. Free space has held steady across three consecutive readings, since deletions keep flushing after the workers exit.

Waiting adds a floor of roughly 15 seconds even when there is nothing to wait for.

### Configuration

| Variable | Default | Description |
|---|---|---|
| `$DskCleanProfileID` | `55` | Numeric ID (10-99) identifying the cleanup profile in the registry. Any unused value in that range works. |
| `$ConfiguredOptions` | See script | Array of Disk Cleanup category names to enable. Comment and uncomment lines to customise. |

### Enabled Cleanup Categories (Default)
- Previous Installations
- System error memory dump files
- System error minidump files
- Update Cleanup
- Windows Error Reporting Files
- Windows Reset Log Files
- Windows Upgrade Log Files

### Output
```
SpaceCleaned: 4.62 GB
FreeSpace: 91.28 GB
```

Both figures are gigabytes to two decimal places. `SpaceCleaned` is the free space gained; `FreeSpace` is the resulting free space on `C:`.

### Exit Codes

| Code | Meaning |
|---|---|
| `0` | Cleanup ran and the reported figures are trustworthy |
| `1` | `-Wait` was set and the timeout expired first, so the reported figures understate the space reclaimed |

### Deployment (Workspace ONE UEM)
- **Script Type:** PowerShell
- **Execution Context:** System
- **Run As:** `SYSTEM`
- **Timeout:** 30 seconds without `-Wait`. With `-Wait`, allow `WaitTimeoutSeconds` plus a margin. The default of 900 seconds needs a 20 minute timeout.

> **DEX Tip:** Pair with a DEX Custom Attribute or Sensor to capture the `SpaceCleaned` output and track disk reclamation trends across your fleet.

---

## Start-ClearRecycleBin.ps1

### Description
Empties the Recycle Bin for every user on the device by deleting the per-user folders on disk directly.

### Why it does not use Disk Cleanup
`cleanmgr` and `Clear-RecycleBin` both resolve the Recycle Bin belonging to the account that calls them. UEM runs scripts as SYSTEM, and SYSTEM's bin is always empty, because deletions performed by SYSTEM bypass the Recycle Bin entirely. A `cleanmgr` run with the Recycle Bin category therefore reclaims nothing on a managed device, however long it is given to finish. Earlier versions of this script did exactly that.

Recycled items live in `<drive>:\$Recycle.Bin\<user SID>\` as pairs: an `$R` entry holding the content, which may be a file or a whole folder, and an `$I` sidecar holding the original path and the deletion timestamp. This script walks those folders itself, so it is not tied to any one user's context.

### Parameters

| Parameter | Environment variable | Default | Description |
|---|---|---|---|
| `-OlderThanDays` | `OlderThanDays` | `0` | Only remove items deleted more than this many days ago. `0` removes everything. |
| `-AllFixedDrives` | `AllFixedDrives` | off | Process every fixed drive rather than the system drive only. |
| `-ResetShellIcon` | `ResetShellIcon` | off | Delete each emptied per-user folder so the desktop Recycle Bin icon stops showing as full. |

### Output
```
[1234] Running as NT AUTHORITY\SYSTEM. WhatIf=False, OlderThanDays=7, AllFixedDrives=False, ResetShellIcon=True
[1234] CBRADLEYSWIN11\chase on C:: 12 item(s), 840.55 MB, 3 left in place as newer than 7 day(s).
[1234] CbradleysWin11\KioskTest on C:: bin is empty.
[1234] ItemsRemoved: 12
[1234] SpaceCleaned: 840.55 MB
[1234] ItemsRetained: 3
```

Every bin gets a line, including the empty ones. On a device that reclaimed nothing, that line is what distinguishes a bin that was reachable and already empty from one that was never reached.

### Exit Codes

| Code | Meaning |
|---|---|
| `0` | Every reachable Recycle Bin was processed |
| `1` | At least one bin could not be read or an item could not be removed |

> **Must run as SYSTEM.** A user account cannot read another user's Recycle Bin folder. If the script cannot read one it says so and exits `1`, rather than reporting a silent success.

> This deletes Recycle Bin contents for **all users** on the device, and the deletion is not recoverable. Set `OlderThanDays` to leave recent deletions restorable.

> **The desktop icon goes stale.** Deleting on the filesystem does not notify the shell, so a logged-on user keeps seeing a full Recycle Bin icon even though the contents are gone. Explorer caches the count per user and only corrects it once something else changes the bin. Set `ResetShellIcon` to delete the emptied per-user folder, which clears that cache. Windows recreates the folder on the user's next delete.

---

## Start-UserProfileCleanup.ps1

### Description
**Deletes** inactive domain user profiles. Two conditions must both be true before a profile is removed:

1. The profile has not been used within a configurable number of days.
2. The profile exceeds a configurable size threshold in MB.

Requiring both prevents removal of small, rarely used profiles such as service accounts that are not actually consuming meaningful disk space.

The designated enrollment user account is excluded from cleanup to protect the Workspace ONE UEM enrollment state. Profile sizes are walked with native .NET `DirectoryInfo` enumeration rather than `Get-ChildItem`, and reparse points are skipped to avoid double counting and directory loops.

### Configuration

| Variable | Default | Description |
|---|---|---|
| `$ENROLLMENTUSER` | `"Administrator"` | Windows account used for UEM enrollment. This profile is **excluded** from deletion. Update it to match your environment. |
| `$DAYS_INACTIVE` | `30` | Days of inactivity before a profile is eligible for removal. |
| `$SIZE_THRESHOLD_MB` | `500` | Minimum profile size in MB before a profile is deleted. Set to `0` to delete all inactive profiles regardless of size. |

### Logic Flow
```
For each domain user profile (excluding $ENROLLMENTUSER):
  |- Is the profile inactive (last use > $DAYS_INACTIVE days ago)?
  \- Is the profile size > $SIZE_THRESHOLD_MB MB?
       |- YES to both -> Delete profile and report
       \- NO to either -> Skip profile and report details
```

### Output
```
[timestamp] Starting profile cleanup...
[timestamp] Examining profile: username
[timestamp] Profile, username, has size X MB, and has been inactive, Y day(s)
[timestamp] Deleted profile: C:\Users\username
[timestamp] Profile cleanup complete.
```

> **Note:** `$LOG_PATH` is declared and its directory is created, but nothing is ever written to it. All output goes to the script result, not to a file on disk.

### Deployment (Workspace ONE UEM)
- **Script Type:** PowerShell
- **Execution Context:** System
- **Run As:** `SYSTEM`

> **Important:** Set `$ENROLLMENTUSER` to the Windows account used to enroll devices in your environment before deploying. Deleting the enrollment user profile can disrupt device management. Profile deletion is not recoverable, so validate against a pilot group first.

---

## Get-UserProfileSize.ps1

### Description
A read-only report of every domain user profile with its size on disk and days since last use. It makes no changes and deletes nothing. Use it to preview what `Start-UserProfileCleanup.ps1` would act on, and to size up disk consumption before committing to a cleanup.

Its `$DAYS_INACTIVE` and `$SIZE_THRESHOLD_MB` values mirror the cleanup script so the two can be kept in step.

### Output
```
[timestamp] Starting profile cleanup...
[timestamp] Examining profile: username
[timestamp] Profile, username, has size X MB, and has been inactive, Y day(s)
```

> **Note:** This script declares `$ENROLLMENTUSER` and `$LOG_PATH`, but uses neither. It reports on every domain profile including the enrollment user, and writes no log file.

---

## profile_size_inventory.ps1

### Description
A run-once sensor that reports every non-special local user profile, its size on disk, and days since last login, as a single compressed JSON payload. Unlike `Start-UserProfileCleanup.ps1`, which only considers domain-joined non-enrollment profiles it might delete, this is a full read-only inventory regardless of domain.

Directory walking is bounded by wall clock rather than by rows or bytes. A shared stopwatch is checked before descending into each subdirectory across all profiles, so one huge profile cannot starve the others. A profile that could not be fully walked before the deadline reports `SizeMB` of `-4` rather than a misleading partial figure, and the top-level `Truncated` flag is set.

> **Must be deployed as a one-time or run-once sensor, never on a recurring schedule.** Timeout under 25 seconds.

---

## General Deployment Notes

### Prerequisites
- Scripts must be executed in the **SYSTEM** context via Workspace ONE UEM Script Management.
- Endpoints must be running **Windows 10** or **Windows 11**.
- `cleanmgr.exe` must be present for `Start-DiskCleanup.ps1`. On some Windows Server and LTSC builds it needs to be installed separately. `Start-ClearRecycleBin.ps1` has no such dependency.

### Recommended Workflow
1. Run `Get-UserProfileSize.ps1` or `profile_size_inventory.ps1` first to see what is actually consuming space.
2. Deploy scripts via **Workspace ONE UEM > Resources > Scripts**.
3. Schedule the cleanup scripts on a recurring basis, such as weekly or monthly, using UEM assignment policies.
4. Create **Workspace ONE DEX Sensors** to capture script output and surface disk health metrics in the DEX console.
5. Use DEX **Experience Scores** and dashboards to identify devices with persistent low-disk conditions and to validate cleanup effectiveness over time.

### Output Destinations
| Script | Where results go |
|---|---|
| `Start-DiskCleanup.ps1` | Script result. No log file |
| `Start-ClearRecycleBin.ps1` | Script result. No log file |
| `Start-UserProfileCleanup.ps1` | Script result. No log file, despite the `$LOG_PATH` variable |
| `Get-UserProfileSize.ps1` | Sensor value |
| `profile_size_inventory.ps1` | Sensor value (JSON) |
