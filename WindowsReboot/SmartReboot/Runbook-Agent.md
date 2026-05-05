# Agent Runbook — Smart Reboot (Workspace ONE UEM)

**Use this runbook when:** A DEX signal, help desk ticket, or automated workflow requires triggering a reboot on one or more Windows endpoints and user experience impact should be minimized using Workspace ONE's native deferral capabilities.

---

## Prerequisites

- [ ] Device is enrolled as **Hub-Managed** or **Fully Managed** in Workspace ONE UEM
- [ ] The **Required Reboot** application has been uploaded and configured in UEM (see [readme.md](readme.md))
- [ ] You have the **Device Management** or **Application Management** role in the UEM console

---

## Step 1 — Identify Target Devices

### From DEX (Recommended for DEX-driven remediation)

1. Navigate to **DEX > Experience Management > Devices**
2. Filter by the condition triggering the reboot need (e.g., high uptime, memory pressure score, failed update sensor)
3. Note the device serial numbers or UEM device IDs
4. For bulk remediation, export the device list or use a **Smart Group**

### From UEM Console

1. Navigate to **Devices > List View**
2. Use search or filters to locate the target device(s)
3. Confirm device **Last Seen** is recent and enrollment status is **Enrolled**

---

## Step 2 — Push the Reboot App

### Single Device

1. Navigate to **Devices > List View** → click the target device
2. Go to the **Apps** tab
3. Locate **Required Reboot** in the app list
   - If status shows **Installed** from a previous trigger, proceed to [Step 3 — Re-Triggering](#step-3--re-triggering-the-reboot) first
4. Click **Install** to push the app

### Bulk / Multiple Devices

1. Navigate to **Apps & Books > Applications > Native > Internal**
2. Click on **Required Reboot**
3. Go to the **Assignments** tab
4. Add or update an assignment targeting the Smart Group containing your devices
5. Set **App Delivery** to **On Demand** and click **Save**
6. From the app details, use **Actions > Push** to initiate delivery

---

## Step 3 — Re-Triggering the Reboot

If **Required Reboot** is already in **Installed** state on a device (the registry key exists from a prior deployment), you must cycle uninstall → install to re-trigger:

1. Navigate to the device's **Apps** tab
2. Find **Required Reboot** → click **Uninstall**
3. Wait for status to change to **Not Installed** (allow 5–10 minutes for device check-in)
4. Click **Install** to re-push

> 💡 The uninstall command removes `HKLM:\SOFTWARE\AirWatch\Extensions\SmartReboot`, resetting the detection state so the script will exit `1641` again on next run.

---

## Step 4 — Monitor Delivery Status

1. Navigate to **Devices > [Device] > Apps** tab
2. Monitor **Required Reboot** status:

| Status | Meaning |
|---|---|
| Pending Install | Command sent; awaiting device check-in |
| Installing | Script is running |
| Installed | Script ran and exited `0` (reboot already triggered or detection key found) |
| Install Failed | Script error — check event logs on device |

3. After the reboot completes, the registry key remains (`InstallComplete = 0`) — the app will show **Installed** and no further action is needed unless another reboot is required.

---

## Step 5 — Confirm Reboot Occurred

### From UEM Console

1. On the device details page, check **Last Enrollment** or **Last Seen** timestamp — it should refresh shortly after reboot
2. Optionally run a **Device Query** to force an immediate check-in

### From DEX

1. Navigate back to the device in **DEX > Experience Management**
2. Verify the uptime counter has reset
3. Confirm the triggering metric (memory pressure, stale uptime, etc.) has improved

---

## Troubleshooting

| Symptom | Likely Cause | Action |
|---|---|---|
| App stuck in **Pending Install** | Device hasn't checked in | Confirm Hub is running; use **Send Message** or wait for next check-in interval |
| App shows **Installed** but no reboot occurred | Registry key existed from prior run | Uninstall then reinstall (see Step 3) |
| App shows **Install Failed** | Script error | RDP/remote to device and check `C:\ProgramData\VMware\SfdAgent\` logs or run script manually as SYSTEM |
| Device not in expected Smart Group | Group membership issue | Verify group criteria and device attributes in UEM |

---

## Notes

- The reboot prompt shown to users is governed by the **Allow User Install Deferral** assignment setting — users can postpone but Workspace ONE enforces the deadline
- This script does **not** work on Registered-only devices — use [InteractiveReboot](../InteractiveReboot/Runbook-Agent.md) instead for those scenarios
- For fleet-wide scheduled reboots, prefer Smart Groups scoped by uptime sensor rather than manual device-by-device pushes
