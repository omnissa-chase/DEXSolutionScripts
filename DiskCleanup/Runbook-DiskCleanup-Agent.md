# Agent Runbook — Invoke-DiskCleanup (Workspace ONE UEM)

**Use this runbook when:** A DEX signal indicates a device has low available disk space on the C: drive, or as part of a recurring fleet maintenance workflow to reclaim space from Windows update artifacts, memory dumps, and previous OS installations.

---

## Prerequisites

- [ ] Device is enrolled as **Hub-Managed** or **Fully Managed** in Workspace ONE UEM
- [ ] `cleanmgr.exe` is present on the endpoint (standard on Windows 10/11; may need to be installed on LTSC/Server builds)
- [ ] You have the **Script Management** role in the UEM console
- [ ] `Invoke-DiskCleanup.ps1` has been uploaded to **Resources > Scripts** in UEM

---

## When to Use This Script

| Trigger | Recommended Action |
|---|---|
| DEX sensor shows C: drive < 10 GB free | Run immediately as one-off remediation |
| DEX Experience Score declining due to disk pressure | Run and monitor before escalating |
| Post-Windows-feature-update (large `Windows.old` folder) | Run targeting "Previous Installations" and "Update Cleanup" |
| Scheduled fleet maintenance | Deploy on recurring schedule via UEM policy |

---

## Step 1 — Identify Target Devices

### From DEX

1. Navigate to **DEX > Experience Management > Devices**
2. Add a filter for a disk space sensor or low disk experience attribute
3. Export the device list or note the device IDs

### From UEM Console

1. Navigate to **Devices > List View**
2. Use **Advanced Search** to filter by a custom attribute or sensor value indicating low disk space
3. Create a **Smart Group** for targeted delivery if running at scale

---

## Step 2 — Review and Customize the Script (If Needed)

Before running, confirm the cleanup categories match your intent. Open `Invoke-DiskCleanup.ps1` and review the `$ConfiguredOptions` array.

**Default enabled categories:**

| Category | What It Cleans |
|---|---|
| Previous Installations | `Windows.old` folder from prior OS installs |
| System error memory dump files | Full crash dumps |
| System error minidump files | Minidump crash files |
| Update Cleanup | Superseded Windows Update packages |
| Windows Error Reporting Files | WER crash report queues |
| Windows Reset Log Files | Logs from system reset operations |
| Windows Upgrade Log Files | Logs from feature upgrade processes |

> ⚠️ Removing **Previous Installations** is irreversible — the device cannot roll back to the prior OS version after this runs. Confirm this is acceptable in your environment before deploying.

To add additional categories, uncomment the relevant lines in `$ConfiguredOptions`.

---

## Step 3 — Run the Script via UEM

### Single Device (Ad-hoc Remediation)

1. Navigate to **Devices > List View** → open the target device
2. Click **More Actions > Run Script** (or navigate to the **Scripts** tab)
3. Select **Invoke-DiskCleanup**
4. Confirm execution settings:
   - **Execution Context:** System
   - **Timeout:** 300 seconds (Disk Cleanup can be slow — increase to 600 if needed for large drives)
5. Click **Run**

### Bulk Execution

1. Navigate to **Resources > Scripts**
2. Click on **Invoke-DiskCleanup**
3. Go to the **Assignments** tab
4. Assign to the target Smart Group
5. Set execution schedule as needed (one-time or recurring)
6. Click **Save**

---

## Step 4 — Review Script Output

The script outputs a single line upon completion:

```
SpaceCleaned: X GB
```

Where `X` is the difference in free space before and after the cleanup run.

### Viewing Output in UEM

1. Navigate to **Devices > [Device] > Scripts** tab
2. Click on the **Invoke-DiskCleanup** execution record
3. View the **Output** column for the `SpaceCleaned` result

> 💡 **DEX Tip:** Create a Workspace ONE DEX **Sensor** that captures `SpaceCleaned` output from the script result. This allows you to track disk reclamation trends across the fleet in DEX dashboards and validate that cleanup is having the intended effect.

---

## Step 5 — Validate

1. Return to the device in UEM or DEX
2. Confirm the disk space sensor / attribute has updated
3. If the device still shows low free space after cleanup, escalate — there may be a large non-system folder (user data, application cache, log files) that this script does not target

---

## Troubleshooting

| Symptom | Likely Cause | Action |
|---|---|---|
| Script times out | Disk Cleanup is processing a large volume of data | Increase timeout to 600s and re-run |
| `SpaceCleaned: 0 GB` | Nothing to clean in the enabled categories, or categories already clean | Review which categories are enabled; check if a prior run already cleaned the same items |
| `cleanmgr.exe` not found | Missing Windows feature | Install via: `DISM /Online /Add-Capability /CapabilityName:Tools.DiskCleanup~~~~0.0.1.0` |
| Script returns non-zero exit code | PowerShell error during execution | Check UEM script output for error details; verify SYSTEM has access to `cleanmgr.exe` |

---

## Recurring Maintenance Schedule (Recommended)

For proactive fleet hygiene, deploy on a recurring basis:

| Frequency | Scope | Recommended Categories |
|---|---|---|
| Monthly | All managed Windows devices | Update Cleanup, WER Files, Windows Upgrade Log Files |
| Post-feature-update | Devices that received a Windows feature update | Previous Installations + all defaults |
| On-demand (DEX alert) | Devices below disk threshold | All defaults |
