# Agent Runbook — Remove-OversizedInactiveProfiles (Workspace ONE UEM)

**Use this runbook when:** A DEX signal or disk space alert indicates that stale domain user profiles are consuming significant disk space on a managed Windows endpoint. This script targets profiles that are both inactive beyond a configurable threshold **and** exceed a minimum size — protecting small service account profiles from accidental deletion.

---

## Prerequisites

- [ ] Device is enrolled as **Hub-Managed** or **Fully Managed** in Workspace ONE UEM
- [ ] Device is domain-joined (script targets domain user profiles; local profiles are excluded)
- [ ] `$ENROLLMENTUSER` variable in the script has been updated to match your environment's WS1 enrollment account **before uploading to UEM**
- [ ] You have the **Script Management** role in the UEM console
- [ ] `Remove-OversizedInactiveProfiles.ps1` has been uploaded to **Resources > Scripts** in UEM

---

## ⚠️ Critical Pre-Deployment Warning

> **Always update `$ENROLLMENTUSER`** before deploying. This variable protects the Windows account used to enroll the device into Workspace ONE UEM from being deleted. Removing the enrollment user profile can break device management and require re-enrollment.

**Default (change this):**
```powershell
$ENROLLMENTUSER = "chase"
```

Update to the service account or user account your organization uses for WS1 enrollment in your environment.

---

## When to Use This Script

| Trigger | Recommended Action |
|---|---|
| DEX sensor shows C: drive < 10 GB free and disk cleanup alone is insufficient | Run profile cleanup to reclaim space from stale accounts |
| Shared workstations / lab machines with many accumulated user profiles | Run on recurring schedule to keep profiles under control |
| Post-user-offboarding at scale (departures, role changes) | Run to clean up leftover profiles from departed users |
| Persistent low-disk DEX alerts that don't resolve after `Invoke-DiskCleanup` | Escalate to profile cleanup as the next remediation step |

---

## Understanding the Configuration

Review and adjust these variables in `Remove-OversizedInactiveProfiles.ps1` before deploying:

| Variable | Default | Guidance |
|---|---|---|
| `$ENROLLMENTUSER` | `"chase"` | **Must be updated.** The enrollment account excluded from all deletion logic. |
| `$DAYS_INACTIVE` | `30` | Profiles not used in this many days are candidates. Increase to `60` or `90` for environments where users log in infrequently (e.g., contractors, field staff). |
| `$SIZE_THRESHOLD_MB` | `500` | Profiles must exceed this size (MB) to be deleted. Set to `0` to remove all inactive profiles regardless of size — **use with caution**. |
| `$LOG_PATH` | `C:\Temp\Logs\ProfileCleanup.log` | Log destination. Directory is created automatically. |

---

## Step 1 — Identify Target Devices

### From DEX

1. Navigate to **DEX > Experience Management > Devices**
2. Filter by low disk space or a custom disk pressure sensor
3. Cross-reference with devices that are shared workstations or high-turnover endpoints (more likely to have accumulated profiles)

### From UEM Console

1. Navigate to **Devices > List View**
2. Filter using a custom attribute or sensor surfacing free disk space
3. Create a **Smart Group** for bulk targeting

---

## Step 2 — Run the Script via UEM

### Single Device (Ad-hoc Remediation)

1. Navigate to **Devices > List View** → open the target device
2. Click **More Actions > Run Script** (or the **Scripts** tab)
3. Select **Remove-OversizedInactiveProfiles**
4. Confirm execution settings:
   - **Execution Context:** System
   - **Timeout:** 300 seconds (large profile trees can take time to size)
5. Click **Run**

### Bulk Execution

1. Navigate to **Resources > Scripts**
2. Click on **Remove-OversizedInactiveProfiles**
3. Go to the **Assignments** tab
4. Assign to the target Smart Group
5. Set execution schedule (one-time or recurring monthly)
6. Click **Save**

---

## Step 3 — Review the Log File

After the script runs, a detailed log is written to the endpoint:

```
C:\Temp\Logs\ProfileCleanup.log
```

**Sample log output:**
```
[2026-05-05 09:14:01] Starting profile cleanup...
[2026-05-05 09:14:02] Examining profile: jsmith
[2026-05-05 09:14:04] Profile, jsmith, has size 1247.83 MB, and has been inactive, 62.4 day(s)
[2026-05-05 09:14:06] Deleted profile: C:\Users\jsmith
[2026-05-05 09:14:06] Examining profile: bwilson
[2026-05-05 09:14:07] Profile, bwilson, has size 312.10 MB, and has been inactive, 45.2 day(s)
[2026-05-05 09:14:07] Profile cleanup complete.
```

> `bwilson` was skipped — inactive but below the `$SIZE_THRESHOLD_MB` of 500 MB.

### Retrieving the Log Remotely

Use a Workspace ONE Script to read and return the log content:

```powershell
Get-Content "C:\Temp\Logs\ProfileCleanup.log" -Tail 50
```

Or use WS1 **File Manager** (if enabled) to pull the file directly.

---

## Step 4 — Validate

1. Return to the device in UEM or DEX
2. Confirm the disk space sensor has updated (may require a device query or sensor re-run)
3. If disk space is still insufficient, review the log to confirm profiles were actually deleted — there may be no eligible profiles meeting both thresholds, or another large directory may be the cause

---

## Troubleshooting

| Symptom | Likely Cause | Action |
|---|---|---|
| No profiles deleted despite expected candidates | Profiles don't meet both criteria simultaneously (inactive AND oversized) | Lower `$DAYS_INACTIVE` or `$SIZE_THRESHOLD_MB` as appropriate |
| Enrollment user account deleted | `$ENROLLMENTUSER` not updated before deployment | Update variable to correct account and re-enroll device if needed |
| Script errors on WMI calls | WMI service issue on endpoint | Run `winmgmt /resetrepository` or restart the WinMgmt service |
| Log file not created | `C:\Temp\Logs\` path blocked by policy | Update `$LOG_PATH` to a writable location such as `C:\ProgramData\Logs\ProfileCleanup.log` |
| Script output says 0 profiles examined | Device may be workgroup-joined, not domain-joined | Verify domain membership — script targets domain users only |

---

## Recurring Maintenance Schedule (Recommended)

| Environment Type | Frequency | Suggested Thresholds |
|---|---|---|
| Shared workstations / labs | Monthly | `$DAYS_INACTIVE=30`, `$SIZE_THRESHOLD_MB=500` |
| Corporate laptops (assigned users) | Quarterly | `$DAYS_INACTIVE=90`, `$SIZE_THRESHOLD_MB=1000` |
| Contractor / temp worker machines | Monthly | `$DAYS_INACTIVE=30`, `$SIZE_THRESHOLD_MB=200` |

---

## Related Runbook

If profile cleanup alone does not resolve the disk space issue, also run:

➡ [Runbook-DiskCleanup-Agent.md](Runbook-DiskCleanup-Agent.md) — Cleans Windows system artifacts, update files, and crash dumps
