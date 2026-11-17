# Storage Health

Answers one question DEX does not answer on its own: **is this device slow or unstable because of its drive?**

A failing or worn drive, bad blocks and I/O errors are among the costliest causes of poor performance, and none of them show up as CPU or memory pressure. This component reads what Windows already knows about the drive behind the system volume, grades it 0 to 100, and repairs the few storage settings that can be repaired from the endpoint.

## Files

| File | Type | What it does |
|---|---|---|
| `Invoke-AutoRemediateStorageHealth.ps1` | Script | Seven checks, three repairs. Caches the score and reason. |
| `OneTimeSensor\storage_health.ps1` | One-time sensor (String, JSON) | The same checks, read-only, as one JSON object for an on-demand pull from the DEX console. Never schedule it. |
| `Sensors\storage_health_score.ps1` | Sensor (Integer) | The cached score. `-1` until the script has run. |
| `Sensors\storage_health_reason.ps1` | Sensor (String) | The largest deduction behind the score. Empty until the script has run. |
| `_AutomatedTesting\Test-StorageHealthScore.ps1` | Test | Unit tests for the score table and the parity check between the script and the sensor. No elevation, changes nothing. |
| `_AutomatedTesting\Invoke-AutoRemediateStorageHealth_BreakTest.ps1` | Test | Turns TRIM off and disables the Optimize Drives task, then checks the script repairs both. Elevated, lab VM only. |

## Deployment

1. Assign `Invoke-AutoRemediateStorageHealth.ps1` to run **once a day** as SYSTEM. On a healthy device it changes nothing and takes 5 to 12 seconds.
2. Assign `storage_health_score` and `storage_health_reason` on the normal sensor schedule. They only read the registry.
3. Keep `storage_health` for on-demand use from the DEX console.

Start with `WhatIf=true` on a pilot group: the script then reports what it would change and writes nothing.

## What the script checks

| Step | Check | When it finds something |
|---|---|---|
| 1 | Drive health: SMART failure prediction, health status, SSD wear, uncorrected media errors, temperature, other internal drives | Reports only |
| 2 | Storage errors in the System log over 7 days: bad blocks, I/O errors, controller resets, file system errors | Reports only |
| 3 | System volume health as NTFS reports it | Scan needed: starts the Windows online scan. Repair queued: reports that a restart is needed |
| 4 | TRIM | Turns it back on |
| 5 | Optimize Drives schedule (the `ScheduledDefrag` task) | Re-enables it |
| 6 | Optimize Drives recency | Starts the task when it has not run in 45 days |
| 7 | Boot drive type | Reports a spinning disk |

Steps 1, 2 and 7 print as `Warning` and exit 0. A hardware fault needs a backup and a replacement, and the cached reason is what flags the device.

The script never takes the volume offline and never defragments anything itself. Step 3 starts the built-in `ProactiveScan` task, and steps 5 and 6 use the Optimize Drives task Windows ships, which retrims an SSD and defragments a spinning disk at low priority.

### Virtual machines

Steps 4 to 7 are skipped on a virtual machine. TRIM, defragmentation and the drive type belong to the platform there, and VDI optimisation tools turn the Optimize Drives schedule off in golden images on purpose. Set `IncludeVirtualMachines=true` to manage them on persistent VMs. Steps 1 to 3 always run.

## Score

100 minus one deduction per finding, floor 0. The reason is the largest deduction.

| Reason | Points | Next step |
|---|---:|---|
| `DriveFailing` (SMART predicts failure, or the drive reports Unhealthy) | 60 | ADMIN |
| `DriveWarning` | 30 | ADMIN |
| `BadBlocks` | 25 | ADMIN |
| `WearHigh` (90% or more of rated SSD life used) | 25 | ADMIN |
| `MediaErrors` | 20 | ADMIN |
| `FileSystemErrors` | 20 | ADMIN |
| `IoErrors` (5 or more events; 5 points for 1 to 4) | 15 | ADMIN |
| `SecondaryDriveUnhealthy` | 15 | ADMIN |
| `SpinningBootDrive` | 15 | ADMIN |
| `DriveHot` (70 C or more) | 10 | ADMIN |
| `VolumeRepairAtRestart` | 20 | USER (restart the device) |
| `VolumeScanNeeded` | 15 | AUTO |
| `TrimDisabled` | 10 | AUTO |
| `OptimizeDisabled` | 10 | AUTO |
| `OptimizeStale` | 5 | AUTO |

`NextStep` is `ADMIN` when any hardware finding is present, `USER` when only a restart is needed, `AUTO` when the script can fix what was found, and `NONE` otherwise.

Suggested use in DEX: alert on `storage_health_reason` in `DriveFailing`, `DriveWarning`, `BadBlocks`, `WearHigh` or `MediaErrors` and open a hardware ticket. Those devices should be backed up before anything else is tried.

## Variables

All optional. Each is an environment variable (UEM script variable) of the same name.

| Variable | Default | Meaning |
|---|---|---|
| `WhatIf` | `false` | `true` reports without changing anything and without writing the cache |
| `EventLookbackDays` | `7` | Days of the System log read by step 2 (1 to 30) |
| `OptimizeStaleDays` | `45` | Days since Optimize Drives last ran before step 6 starts it (1 to 365) |
| `IncludeVirtualMachines` | `false` | Run steps 4 to 7 on virtual machines too |

## Where results go

- `HKLM:\Software\AirWatch\Extensions\StorageHealth`: `HealthScore`, `HealthReason`, `NextStep`, `Detail`, `Deductions`, `DriveHealth`, `VolumeHealth`, `Status`, `LastRun` and the step counts.
- `HKLM:\Software\AirWatch\Extension\DEXRecords\SystemHealth\StorageHealth`: one value per step.
- `C:\Windows\Temp\UEM_AutoRemediateStorageHealth.log`.

## Limits

- **Virtual disks report little.** Wear, temperature, error counters and SMART prediction read `-1` on most VMs, so a VM is graded on drive health status, volume health and event log errors only.
- **Storage Spaces and hardware RAID** can hide the physical drive. Step 1 then says it could not identify the drive and the other steps still run.
- **The shared block.** `Get-StorageFacts` and `Get-StorageScore` are pasted into both the script and the one-time sensor so each stays self-contained. Edit both together; `Test-StorageHealthScore.ps1` fails when they differ.
- **Size.** The script is close to the 32,767-character limit for consoles before UEM 2607. Measure after every edit.

## Testing

```powershell
# No elevation, changes nothing: score table, parity, live facts, sensor output
.\_AutomatedTesting\Test-StorageHealthScore.ps1

# Elevated or SYSTEM, lab VM only, after a snapshot
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<repo>\WindowsAutoRemediation\StorageHealth\_AutomatedTesting\Invoke-AutoRemediateStorageHealth_BreakTest.ps1" -Force -RemediationTest
```

The hardware findings (steps 1, 2 and 7) cannot be produced on a virtual machine. They are covered by the unit test with synthetic facts and still need one run on a physical laptop to confirm the values a real drive reports.
