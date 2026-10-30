# Windows Update On/Off for Workspace ONE UEM

Two MDM command scripts that let an admin hold a Windows device from updating, then make it update on demand, without touching the Windows Update policy the device already has.

| Script | What it does | Typical runtime |
|---|---|---|
| `DEX_Stop-WindowsUpdate.ps1` | Turns Windows Update **off**: disables and stops the Windows Update service and sets the built-in 35-day Pause. | 2 to 25 seconds |
| `DEX_Start-WindowsUpdate.ps1` | Turns Windows Update **on**: re-enables and starts the service, clears the Pause, and triggers a scan, download and install now. | 3 to 35 seconds |

Both run as SYSTEM, target Windows PowerShell 5.1, use only in-box tooling, support a `WhatIf` dry run, and leave a status stamp under `HKLM:\Software\AirWatch\Extensions\WindowsUpdateControl`.

---

## 1. When to use this

The assumption is that the device already has an enforced Windows Update policy: a Workspace ONE Windows Update profile, Windows Update for Business deferrals, or a WSUS server. That policy decides *where* updates come from, *which* ones are offered, and *when* the device may restart. These scripts do not change any of that. They only control *whether the client is allowed to run* and *when it runs next*.

Typical flow for a maintenance window:

1. **Before the window**: run `DEX_Stop-WindowsUpdate.ps1` on the device or smart group. Nothing scans, downloads or installs.
2. **In the window**: run `DEX_Start-WindowsUpdate.ps1`. The service comes back, the pause clears, and an update cycle starts immediately against the policy's update source.
3. **Restart**: let the policy's active hours and deadline handle it, or push one of the `WindowsReboot\` scripts for a controlled, user-aware restart.
4. **After the window**: run `DEX_Stop-WindowsUpdate.ps1` again if the device should go back on hold.

Other uses: hold a device while a known-bad update is being pulled; freeze a device during a demo, exam or production run; or just "make it update right now" on a device that is weeks behind.

---

## 2. How the OFF script works, and what it cannot do

`DEX_Stop-WindowsUpdate.ps1` does three things, in order:

1. Sets the Windows Update service (`wuauserv`) start type to **Disabled**. This is what stops the Update Orchestrator (`UsoSvc`) from starting it again at the next scheduled scan.
2. **Stops** the service. It uses `sc.exe stop` and polls for up to 20 seconds rather than blocking on `Stop-Service`.
3. Sets the built-in **Pause Updates** for 35 days (the Windows maximum). These are the same six registry values the Settings app writes when a user clicks "Pause updates".

### Why the pause is there

Windows ships a self-healing service called Windows Update Medic (`WaaSMedicSvc`). Within about a day it notices that `wuauserv` is Disabled and sets it back to Manual. Stopping and disabling the service alone is therefore a hold of hours, not days. The pause is what keeps the device from resuming installs after Medic has done its work. The pause is honoured by the orchestrator regardless of the service start type.

Do not disable `WaaSMedicSvc` to make the service hold permanent. Its registry key is owned by TrustedInstaller, the change is undone by cumulative updates, and endpoint security tooling treats it as tampering. For a hold longer than 35 days, use the pause settings in the Workspace ONE Windows Update profile instead; that is a policy and Medic does not touch it.

### Safety checks in the OFF script

- If an update is **installing right now** (the Windows Update Agent reports the installer busy, or the Direct-mode task from the ON script is running), the script declines and exits 0. Interrupting an install is how a device ends up with a half-applied servicing stack. Re-run after it finishes. `$StopEvenIfInstalling` overrides this; leave it `$false`.
- If a **reboot is already pending**, the script says so. Updates that were already staged will still finish installing at the next restart. That work is done by the servicing stack during boot, not by `wuauserv`, and nothing here prevents it.

### What OFF does not stop

- Microsoft Store app updates.
- Defender platform and definition updates that Defender fetches itself.
- Third-party updaters (browsers, Adobe, Java, vendor agents).
- A pause or deferral set by **policy**. The script reports a policy pause but never changes one.

---

## 3. How the ON script works

`DEX_Start-WindowsUpdate.ps1` does the reverse, then forces a cycle:

1. If the service start type is Disabled, sets it back to **Manual** (the Windows default).
2. **Starts** the service if it is not running. If it does not reach Running within 15 seconds the script exits 1 and does not trigger anything.
3. **Clears the pause**: removes the six Settings-app pause values and runs `UsoClient ResumeUpdate`.
4. Triggers the update cycle according to `$InstallMode`.

### The three install modes

| Mode | What happens | Honours the policy's... | Use when |
|---|---|---|---|
| `Orchestrator` (default) | `UsoClient RefreshSettings` then `UsoClient ScanInstallWait`. The Update Orchestrator scans, downloads and installs now. The script returns in seconds; work continues under `UsoSvc`. | Source, deferrals, pause, AUOptions, active hours, deadlines | The normal case. Policy is "auto download and install" and you just want it to happen now instead of at the next scheduled scan. |
| `Direct` | Dispatches a hidden scheduled task (`WS1_DEX_WindowsUpdateInstall`, runs as SYSTEM, 3-hour cap) that uses the Windows Update Agent API to search, download and install every applicable software update itself. | Source and deferrals (the search still goes to the policy's server). **Not** AUOptions or "notify" settings. | Orchestrator mode downloads but never installs because the policy is "notify before install" (AUOptions 2 or 3), `NoAutoUpdate=1`, or the orchestrator is wedged and you need the install to happen regardless. |
| `None` | Service on, pause cleared, nothing triggered. | n/a | You only want to undo the OFF script and let the normal schedule take over. |

The ON script warns you when the policy it sees means Orchestrator mode will not install (`NoAutoUpdate=1`, or AUOptions 2/3) and suggests Direct mode.

### Neither mode restarts the device

Installing is one action; restarting is another. Restart behaviour stays with the update policy (active hours, deadlines, engaged restart) or with the `WindowsReboot\` scripts. Direct mode writes `RebootRequired` to the registry stamp so you can decide.

### Direct mode details

- The script copies itself to `C:\ProgramData\AirWatch\Extensions\WindowsUpdateControl\` and registers the task from there, because UEM deletes its own temp copy as soon as the launcher exits.
- **Add an AV/EDR exclusion** for `C:\ProgramData\AirWatch\Extensions\` and subfolders. Without it the staged copy can be quarantined and the task will appear to succeed while doing nothing.
- The payload holds a global mutex, so a second dispatch while one is running exits cleanly.
- Progress goes to `%SystemRoot%\Temp\UEM_DEX_Start-WindowsUpdate.log` and to the registry stamp (`Status` moves Dispatched, Running, Completed / CompletedWithErrors / Failed / TimedOut).
- Updates that need user input are skipped and logged. Driver updates are excluded unless `$IncludeDrivers` is `$true`.
- The payload unregisters its own task when it finishes.

---

## 4. Prerequisites

| Requirement | Notes |
|---|---|
| Windows 10 1607 or later, or Windows 11 | `UsoClient.exe` arrived in 1607. Older builds fall back to `wuauclt /detectnow /updatenow`, which scans but does not force an install. |
| Intelligent Hub with Scripts enabled, or any delivery that runs PowerShell as SYSTEM | Both scripts need admin rights to change the service and HKLM. |
| An enforced Windows Update policy | Not strictly required, but without one the device updates straight from Windows Update with Microsoft's defaults, which is probably not what you want to force. |
| AV/EDR exclusion for `C:\ProgramData\AirWatch\Extensions\` | Direct mode only. |
| Windows PowerShell 5.1 | Both scripts are written for it. They also parse and run under PowerShell 7. |

---

## 5. Deploy in Workspace ONE UEM

Create each script once as a Workspace ONE **Script** resource, then run it on demand.

1. **Resources > Scripts > Add > Windows.**
2. Name it (for example `DEX - Windows Update OFF` and `DEX - Windows Update ON`), paste the script body or upload the file.
3. Settings:

   | Setting | Value |
   |---|---|
   | Language | PowerShell |
   | Execution context | **System** |
   | Execution architecture | Auto / 64-bit |
   | Timeout | 60 seconds |
   | Variables (optional) | `WhatIf` = `true` for a dry-run copy of the script |

4. Assign to a smart group with **Run on demand** (do not schedule either script on an interval; these are deliberate actions).
5. Run from the device's **Scripts** tab, or from the script's assignment page for a whole smart group.

### Changing the install mode

UEM script variables are per script object, not per assignment, so tunables are hard-coded at the top of each file. To offer both ON behaviours, create two script objects: one with `$InstallMode = 'Orchestrator'` (the default) and one with `$InstallMode = 'Direct'`, named accordingly. The same goes for a copy with `$PauseUpdates = $false` if you want OFF without the pause.

### From a console or a build pipeline

Outside UEM the same choices are command-line switches: `DEX_Start-WindowsUpdate.ps1 -Mode Direct -Wait` runs the Direct install inline and returns 0, 3010 (reboot required) or 1; `-Mode None` undoes the OFF script and triggers nothing; `DEX_Stop-WindowsUpdate.ps1 -NoPause` holds the service without baking a pause into an image. The golden image sequence is in [WindowsUpdate-OnOff-QuickStart.md](WindowsUpdate-OnOff-QuickStart.md), section 3.

### Dry run first

Create a third copy of each script with the `WhatIf` variable set to `true`, assign it to a test device, and read the output. Every line prefixed `What if:` is an action the live script would take. The dry run never writes the registry stamp.

---

## 6. Reading the result

### Console output

Every line is prefixed with a four-digit run ID. Both scripts print a `[Before]` block and, on a live run, an `[After]` block:

```
[4821] [Before] wuauserv: Running / Manual   UsoSvc: Running
[4821] [Before] Source: Windows Update for Business (deferral policy present)   AutoUpdate disabled by policy: False
[4821] [Before] Pause: not paused   Pending reboot: False   Installing now: no
```

`Source` tells you which policy the device is actually following: `WSUS (http://server)`, `Windows Update for Business`, `Windows Update (MDM Update policy present)` for a Workspace ONE profile without deferrals, or `Windows Update (no update policy found)`.

### Registry stamp

`HKLM:\Software\AirWatch\Extensions\WindowsUpdateControl`

| Value | Meaning |
|---|---|
| `Mode` | `Off` or `On`, from whichever script ran last |
| `Status` | OFF: `Completed`, `SkippedInstalling`, `Failed`. ON: `Completed`, `Triggered`, `Dispatched`, `Running`, `CompletedWithErrors`, `TimedOut`, `Failed` |
| `LastRun` | ISO 8601 timestamp |
| `LastResult` | One-line summary |
| `PauseUntil` | Date the OFF pause expires |
| `Found` / `Installed` / `Failed` / `RebootRequired` | Direct mode only |

A sensor that returns `Mode` and `Status` from this key gives you an on/off dashboard column in Intelligence. `sensor-getservice.ps1` in this folder also shows whether `wuauserv` is running.

### Checking on the device

```powershell
Get-Service wuauserv, UsoSvc | Select-Object Name, Status, StartType
Get-ItemProperty 'HKLM:\Software\AirWatch\Extensions\WindowsUpdateControl'
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' | Select-Object Pause*
Get-Content "$env:SystemRoot\Temp\UEM_DEX_Start-WindowsUpdate.log" -Tail 30   # Direct mode
Get-WindowsUpdateLog                                                           # full client log, slow
```

Settings > Windows Update > Update history shows what the orchestrator installed and when.

---

## 7. Tunables

### `DEX_Stop-WindowsUpdate.ps1`

| Variable | Default | Purpose |
|---|---|---|
| `$PauseUpdates` | `$true` | Also set the 35-day pause. Set `$false` only if you accept that Medic will re-enable the service within about a day. |
| `$PauseDays` | `35` | Windows accepts at most 35. |
| `$StopEvenIfInstalling` | `$false` | Stop the service even while an install is in progress. Leave it. |
| `$StopTimeoutSeconds` | `20` | How long to wait for the service to stop before moving on. |

### `DEX_Start-WindowsUpdate.ps1`

| Variable | Default | Purpose |
|---|---|---|
| `$InstallMode` | `'Orchestrator'` | `Orchestrator`, `Direct` or `None`. See section 3. |
| `$ResumePause` | `$true` | Clear the Settings-app pause. |
| `$IncludeDrivers` | `$false` | Direct mode: also install driver updates offered by the update source. |
| `$StartTimeoutSeconds` | `15` | How long to wait for the service to start. |
| `$UsoWaitSeconds` | `5` | How long to wait on each `UsoClient` call. The orchestrator keeps working after the script moves on. |
| `$DirectTimeLimitHrs` | `3` | Direct mode scheduled task hard cap. |
| `$DirectDeadlineMin` | `150` | Direct mode: do not start a new phase (download, install) after this many minutes. |

---

## 8. Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| OFF exits 0 with `SKIPPED: an update is installing right now` | An install is in progress. | Wait for it to finish, then re-run. |
| OFF says `still 'StopPending' after 20 s` | The service is mid-operation. | Nothing. It finishes stopping on its own and cannot restart while Disabled. |
| A day after OFF, `wuauserv` is Manual again | Windows Update Medic reset it. Expected. | The pause is still in force, so nothing installs. Check `Pause:` in the ON/OFF output. |
| ON runs clean but nothing installs after 30 minutes | Policy is "notify" (AUOptions 2/3) or `NoAutoUpdate=1`; the ON output warns about this. Or a policy pause is set. | Use a `Direct` mode copy. For a policy pause, change the Workspace ONE profile. |
| ON says `wuauserv did not reach Running` | Service is broken, not just disabled. | Run `WindowsAutoRemediation\Invoke-AutoRemediateWindowsUpdates.ps1`, then ON again. |
| Direct mode: task runs, log is empty, nothing happens | The staged script was quarantined. | Add the AV/EDR exclusion for `C:\ProgramData\AirWatch\Extensions\`. |
| Direct mode: `Status = TimedOut` | Downloads or installs exceeded the deadline. | Downloads are cached; run ON again. Consider raising `$DirectDeadlineMin` and `$DirectTimeLimitHrs` for feature updates. |
| Direct mode: `FAILED ... HResult=0x80240022` or similar | A specific update failed. | The log names it. Check the Windows Update error code and whether the device needs a restart first (`Pending reboot: True`). |
| `Source: Windows Update (no update policy found)` | The device has no Windows Update profile or GPO. | Expected on an unmanaged test VM. Fix the assignment before relying on these scripts in production. |

---

## 9. Frequently asked

**Why not just `Stop-Service wuauserv`?**
Because the orchestrator starts it again at the next scheduled scan, usually within the hour. Disabled start type plus the pause is what makes the hold stick.

**Does OFF break the Intelligent Hub, Workspace ONE profiles, or app installs?**
No. Hub, OMA-DM, and app deployments do not use `wuauserv`. Microsoft Store apps and Defender updates have their own channels and keep working.

**Does OFF hide the pause from the user?**
No. Settings > Windows Update shows "Updates paused until <date>" with a Resume button. If the Workspace ONE profile sets `SetDisablePauseUXAccess`, the user cannot resume it; otherwise they can, and the ON script would then find nothing to clear.

**What if OFF runs on a device that was already paused by policy?**
Both pauses coexist. OFF adds the 35-day Settings pause; ON clears only that one and warns that the policy pause remains.

**Is running OFF or ON twice safe?**
Yes. Both are idempotent and report "already Disabled", "already running", "no pause to clear" as appropriate.

**Does ON force a restart?**
No. See section 3.

**Exit codes**

| Code | Meaning |
|---|---|
| `0` | Done, including "nothing to do" and OFF's "skipped, install in progress" |
| `1` | Failed: service missing, could not start, could not change the service, could not register the task, or a Direct-mode install with no successes |

---

## 10. Operational notes

- A device on hold is a device not receiving security updates. Track `Mode = Off` in the registry stamp and keep holds as short as the change requires.
- The 35-day pause expires on its own. If a device is still on hold after that, the service may also have been reset by Medic, and the device will update at its next scheduled scan. Re-run OFF to extend, or run ON to end the hold deliberately.
- Both scripts are in `SCRIPT-INVENTORY-CSV.csv` as `3) Complete - Needs Testing`. Validation steps are in `AutomatedTesting\TEST-VALIDATION.md`, sections 9.4 and 9.5.
