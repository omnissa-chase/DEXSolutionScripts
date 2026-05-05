# Agent Runbook — Interactive Reboot With User Deferral (Workspace ONE UEM)

**Use this runbook when:** A DEX signal or help desk workflow requires a reboot with user-visible notifications and configurable deferral windows — especially where forcing an immediate reboot without warning would be disruptive. Also the correct option for **Registered-mode** devices that cannot receive standard app package deployments.

---

## Prerequisites

- [ ] Device is enrolled in Workspace ONE UEM (Hub-Managed, Fully Managed, or Registered)
- [ ] You have the **Product Provisioning** management role in UEM
- [ ] The **TroubleshootWizard – Interactive Reboot** Product has been created in UEM (see below if first time)
- [ ] Confirm the script parameters are configured for your scenario before deploying

---

## Understanding the Key Parameters

Before deploying, verify these values at the top of `Invoke_RebootWithUserDefer_1.2.0.7.ps1` match your intended behavior:

| Parameter | Default | Guidance |
|---|---|---|
| `$MaxHours` | `4` | Total hours before the reboot is forced. For business-hours scenarios consider `8`–`24`. For after-hours maintenance use `0` to force on next poll. |
| `$ShowEveryMinutes` | `30` | How often the toast re-appears. `30` is the minimum. |
| `$RebootCountdownSeconds` | `300` | Grace period (in seconds) given to users after the hard deadline triggers. Default is 5 minutes. |
| `$PollMinutes` | `5` | How often the SYSTEM orchestrator checks conditions. Keep at `5` unless polling overhead is a concern. |

---

## First-Time Setup — Creating the Product Provisioning Object

> Skip to **Deploying the Reboot** if the Product already exists in your console.

### Step 1 — Stage the File

The script is a single `.ps1` file. Because it exceeds the Workspace ONE Script upload size limit, it must be deployed via **Product Provisioning**.

1. Locate `Invoke_RebootWithUserDefer_1.2.0.7.ps1` from this repository
2. Adjust `$MaxHours`, `$ShowEveryMinutes`, `$RebootCountdownSeconds`, and `$PollMinutes` at the top of the file to match your organization's standard policy before uploading

### Step 2 — Upload to WS1 Product Provisioning

1. In the UEM console navigate to **Devices > Provisioning > Product List**
2. Click **Add Product**
3. Set **Platform** to **Windows**
4. Give the product a clear name: `Interactive Reboot - [MaxHours]hr Window` (e.g., `Interactive Reboot - 4hr Window`)
5. Under **Manifest**, click **Add** → **Install**
   - **Action Type:** Install Files / Actions
   - Upload `Invoke_RebootWithUserDefer_1.2.0.7.ps1`
   - **Execute Command:**
     ```
     powershell.exe -ExecutionPolicy Bypass -File "Invoke_RebootWithUserDefer_1.2.0.7.ps1"
     ```
6. **Condition (optional but recommended):** Add a condition to confirm the device has the Hub running — or leave unconditioned for immediate rollout

### Step 3 — Configure Conditions / Smart Groups

1. On the **Assignments** tab, select the Smart Group for your target devices
2. Click **Save & Publish**

---

## Deploying the Reboot

### Single Device (Ad-hoc / Help Desk)

1. Navigate to **Devices > List View** → open the target device
2. Go to the **Provisioning** tab (or use **More Actions**)
3. Locate the Interactive Reboot product
4. Click **Install** / **Force Install**
5. The device will receive the command on next check-in (typically within 1–5 minutes for enrolled devices)

### Bulk / DEX-Driven Remediation

1. Navigate to **Devices > Provisioning > Product List**
2. Open the Interactive Reboot product
3. On the **Assignments** tab, add or verify the Smart Group containing your target devices
4. Use **Actions > Force** to push immediately to all assigned devices

---

## What Happens on the Endpoint

Once the product runs:

1. The script writes `RebootMainThread.ps1` and `UserToast.ps1` to `C:\ProgramData\AirWatch\Extensions\AdvancedReboot\`
2. A SYSTEM-context scheduled task (`\WorkspaceOneEx\RebootPrompt-Orchestrator`) is registered and begins running every `$PollMinutes` minutes
3. On each poll, if a user is logged in, a toast notification appears:
   - **"Reboot now"** button initiates a countdown reboot
   - **"Not now"** button defers (toast returns after `$ShowEveryMinutes` minutes)
4. After `$MaxHours`, the deadline is reached — the next poll triggers `shutdown.exe /r /t $RebootCountdownSeconds /f` and shows a mandatory countdown toast (no deferral option)
5. After the reboot, the orchestrator detects the new boot time and self-cleans: removes the scheduled task, registry keys, and helper scripts

---

## Monitoring

### From UEM Console

1. Navigate to the device → **Provisioning** tab
2. Verify the product status is **Compliant** / **Installed**

### From Device (for troubleshooting)

Check Task Scheduler:
```
Task Scheduler → \WorkspaceOneEx\RebootPrompt-Orchestrator
```

Check registry state:
```
HKLM:\Software\AirWatch\Extensions\AdvancedReboot
```

Check helper scripts:
```
C:\ProgramData\AirWatch\Extensions\AdvancedReboot\
```

### From DEX

After the reboot completes, verify in **DEX > Experience Management > Devices**:
- Uptime counter has reset
- The triggering health metric has improved

---

## Cleanup / Cancellation

If you need to cancel a pending reboot before the deadline:

1. Remote into the device (or use a WS1 script command)
2. Run:
   ```powershell
   Unregister-ScheduledTask -TaskPath '\WorkspaceOneEx\' -TaskName 'RebootPrompt-Orchestrator' -Confirm:$false
   Remove-Item -Path 'HKLM:\Software\AirWatch\Extensions\AdvancedReboot' -Recurse -Force
   Remove-Item -Path 'C:\ProgramData\AirWatch\Extensions\AdvancedReboot\' -Recurse -Force
   shutdown.exe /a
   ```

---

## Troubleshooting

| Symptom | Likely Cause | Action |
|---|---|---|
| No toast appears after deployment | User not logged in at time of poll | Wait for next `$PollMinutes` interval or verify active user session with `quser` |
| Toast appeared but no enforcement | Deadline not yet reached | Check `HKLM:\Software\AirWatch\Extensions\AdvancedReboot\Deadline` |
| Orchestrator task missing | Script did not run as SYSTEM | Verify Product Provisioning executed under SYSTEM context |
| Reboot happened but scripts not cleaned up | Machine key `FirstRunAt` missing or corrupt | Manually run cleanup commands above |
| Product stuck in **Pending** state | Device hasn't checked in | Confirm Hub service is running; device may be offline |

---

## Notes

- This script is safe to re-deploy after the machine has rebooted — the self-cleanup logic detects the new boot time and re-installs fresh
- For devices that are never actively used by a logged-in user (kiosks, shared workstations with no active session), the orchestrator will trigger a SYSTEM-level forced reboot when the deadline passes
- Toast notifications display under the **Workspace ONE Intelligent Hub** app identity if Hub is installed, providing a familiar branded experience
