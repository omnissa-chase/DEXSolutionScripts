# DiskCleanup

A collection of PowerShell scripts designed for automated disk space management and user profile cleanup on Windows endpoints. These scripts are intended to be deployed and executed via **Omnissa Workspace ONE UEM** and monitored through **Omnissa Workspace ONE DEX**.

---

## Scripts Overview

| Script | Purpose |
|---|---|
| `Invoke-DiskCleanup.ps1` | Runs Windows Disk Cleanup targeting specific system cleanup categories |
| `Remove-OversizedInactiveProfiles.ps1` | Removes inactive domain user profiles that exceed a configurable size threshold |

---

## Invoke-DiskCleanup.ps1

### Description
This script automates the Windows built-in Disk Cleanup utility (`cleanmgr.exe`) by programmatically configuring cleanup options via the registry and executing a cleanup profile. It targets system-level cleanup categories such as previous Windows installations, update artifacts, error dumps, and upgrade log files.

Upon completion, the script outputs the amount of disk space reclaimed (in GB).

### Configuration

| Variable | Default | Description |
|---|---|---|
| `$DskCleanProfileID` | `55` | The numeric ID (10–99) used to identify the cleanup profile in the registry. Can be any unused value in that range. |
| `$ConfiguredOptions` | See script | Array of Windows Disk Cleanup category names to enable. Comment/uncomment lines to customize which categories are cleaned. |

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
SpaceCleaned: X GB
```

### Deployment (Workspace ONE UEM)
- **Script Type:** PowerShell
- **Execution Context:** System
- **Timeout:** 300 seconds (recommended — Disk Cleanup can be slow)
- **Run As:** `SYSTEM`

> **DEX Tip:** Pair with a DEX Custom Attribute or Sensor to capture the `SpaceCleaned` output and track disk reclamation trends across your fleet.

---

## Remove-OversizedInactiveProfiles.ps1

### Description
This script provides more granular control over inactive profile cleanup by combining two conditions before deleting a profile:

1. The profile has **not been used** within a configurable number of days.
2. The profile **exceeds a configurable size threshold** (in MB).

Both conditions must be true for a profile to be deleted. This prevents removal of small, rarely-used profiles (e.g., service accounts) that are not actually consuming meaningful disk space.

The script also supports excluding a designated **enrollment user account** from cleanup to prevent adverse effects on the Workspace ONE UEM enrollment state.

All activity is logged to a file for auditability.

### Configuration

| Variable | Default | Description |
|---|---|---|
| `$ENROLLMENTUSER` | `"chase"` | Username of the Windows account used for Workspace ONE UEM enrollment. This profile is **excluded** from deletion. Update this to match your environment's enrollment account. |
| `$DAYS_INACTIVE` | `30` | Number of days of inactivity before a profile is eligible for removal. |
| `$SIZE_THRESHOLD_MB` | `500` | Minimum profile size in MB required before a profile is deleted. Set to `0` to delete all inactive profiles regardless of size. |
| `$LOG_PATH` | `C:\Temp\Logs\ProfileCleanup.log` | Path to the log file. The directory will be created automatically if it does not exist. |

### Logic Flow
```
For each domain user profile:
  ├─ Is the profile inactive (last use > $DAYS_INACTIVE days ago)?
  └─ Is the profile size > $SIZE_THRESHOLD_MB MB?
       └─ YES to both → Delete profile and log result
       └─ NO to either → Skip profile and log details
```

### Output (Log File)
```
[timestamp] Starting profile cleanup...
[timestamp] Examining profile: username
[timestamp] Profile, username, has size X MB, and has been inactive, Y day(s)
[timestamp] Deleted profile: C:\Users\username
[timestamp] Profile cleanup complete.
```

### Deployment (Workspace ONE UEM)
- **Script Type:** PowerShell
- **Execution Context:** System
- **Run As:** `SYSTEM`

> ⚠️ **Important:** Update `$ENROLLMENTUSER` to match the Windows account used to enroll devices into Workspace ONE UEM in your environment before deploying. Deleting the enrollment user profile can disrupt device management.

---

## General Deployment Notes

### Prerequisites
- Scripts must be executed in the **SYSTEM** context via Workspace ONE UEM Script Management.
- Endpoints must be running **Windows 10** or **Windows 11**.
- `cleanmgr.exe` must be present on the endpoint (required for `Invoke-DiskCleanup.ps1`). On some Windows Server or LTSC builds this may need to be installed separately.

### Recommended Workflow
1. Deploy scripts via **Workspace ONE UEM > Resources > Scripts**.
2. Schedule scripts to run on a recurring basis (e.g., weekly or monthly) using UEM assignment policies.
3. Create **Workspace ONE DEX Sensors** to capture script output and surface disk health metrics in the DEX console.
4. Use DEX **Experience Scores** and dashboards to identify devices with persistent low-disk conditions and validate cleanup effectiveness over time.

### Log File Locations
| Script | Log Path |
|---|---|
| `Remove-OversizedInactiveProfiles.ps1` | `C:\Temp\Logs\ProfileCleanup.log` |
| `Invoke-DiskCleanup.ps1` | *(No log file — output returned via script result)* |
