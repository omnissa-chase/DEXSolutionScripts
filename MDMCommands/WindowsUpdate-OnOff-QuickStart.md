# Windows Update On/Off: Quick Start

Two scripts. One turns Windows Update off, the other turns it on and installs now. Neither touches the device's update policy, and neither restarts the device.

| Script | Does | Console switches |
|---|---|---|
| `DEX_Stop-WindowsUpdate.ps1` | Disables and stops `wuauserv`, sets the built-in 35-day Pause | `-NoPause` |
| `DEX_Start-WindowsUpdate.ps1` | Re-enables and starts `wuauserv`, clears the Pause, triggers an install | `-Mode Orchestrator|Direct|None`, `-Wait` |

Full detail, troubleshooting and FAQ: [WindowsUpdate-OnOff-Guide.md](WindowsUpdate-OnOff-Guide.md).

---

## 1. Run it by hand

Elevated PowerShell (Windows PowerShell 5.1 or PowerShell 7), from the folder holding the scripts:

```powershell
# Dry run first: prints every action as "What if:", changes nothing
$env:WhatIf = 'true'
.\DEX_Stop-WindowsUpdate.ps1
.\DEX_Start-WindowsUpdate.ps1 -Mode Direct
Remove-Item Env:\WhatIf

# Turn updates off (service Disabled + stopped, paused 35 days)
.\DEX_Stop-WindowsUpdate.ps1

# Turn updates on and let the orchestrator install now, in the background
.\DEX_Start-WindowsUpdate.ps1

# Turn updates on and install everything applicable right now, waiting for it
.\DEX_Start-WindowsUpdate.ps1 -Mode Direct -Wait

# Turn updates on, trigger nothing
.\DEX_Start-WindowsUpdate.ps1 -Mode None
```

Exit codes: `0` done, `1` failed. With `-Mode Direct -Wait` also `3010` meaning done and a restart is required.

Where to look afterwards:

```powershell
Get-Service wuauserv | Select-Object Status, StartType
Get-ItemProperty 'HKLM:\Software\AirWatch\Extensions\WindowsUpdateControl'      # Mode, Status, LastResult, Found/Installed/Failed
Get-Content "$env:SystemRoot\Temp\UEM_DEX_Start-WindowsUpdate.log" -Tail 40     # Direct mode progress
```

---

## 2. From Workspace ONE UEM

Create each script as **Resources > Scripts > Add > Windows**, PowerShell, context **System**, timeout **60 s**, assigned **on demand** (never on a schedule). Run from the device's Scripts tab or the assignment page for a whole smart group.

UEM cannot pass command-line switches, so the behaviour comes from the tunables at the top of each file. To offer more than one behaviour, create one script object per variant:

| Script object | Edit at the top of the file |
|---|---|
| Windows Update OFF | nothing; defaults are right |
| Windows Update ON (orchestrator) | nothing; `$InstallMode = 'Orchestrator'` |
| Windows Update ON (force install) | `$InstallMode = 'Direct'` |
| Windows Update ON (no install) | `$InstallMode = 'None'` |
| Dry run of any of the above | add script variable `WhatIf` = `true` |

Typical maintenance window: OFF before, ON (orchestrator) during, a `WindowsReboot\` script for the restart, OFF again after if the hold continues.

Direct mode from UEM stages a copy of the script under `C:\ProgramData\AirWatch\Extensions\WindowsUpdateControl\` and runs it as a scheduled task. Add an AV/EDR exclusion for `C:\ProgramData\AirWatch\Extensions\` first.

---

## 3. Golden image builds

The problem these solve in a build: Windows Update wakes up mid-build and fights your application installs for the servicing stack, then at the end the image still is not fully patched. Hold it while you install, patch deliberately in rounds, then leave the image in a known state.

### 3.1 The pattern

```
[1] Stop-WindowsUpdate -NoPause          hold while apps install
[2] install applications, drivers, agents
[3] Start-WindowsUpdate -Mode Direct -Wait
[4] exit 3010 -> reboot -> back to [3]   repeat until exit 0 (nothing applicable)
[5] reboot once more                     Sysprep refuses to generalize with a pending reboot
[6] Start-WindowsUpdate -Mode None       leave Windows Update enabled and unpaused
    or Stop-WindowsUpdate -NoPause       leave it disabled, no pause baked in
[7] optional: clean up, then capture / sysprep
```

Why `-NoPause` in step 1: a build takes hours, and Windows Update Medic takes about a day to re-enable a disabled service, so the pause is not needed and you do not want a pause with a build-date expiry baked into the image.

Why not just leave step 6 as the OFF state with the pause: every device deployed from the image would be paused until 35 days after the build date, then Medic would have re-enabled the service anyway. Pick one of the two explicit end states instead:

| End state | Command | Deployed devices... |
|---|---|---|
| Enabled, default behaviour (recommended) | `Start-WindowsUpdate -Mode None` | update per whatever policy lands at enrollment; no surprises |
| Disabled, no pause | `Stop-WindowsUpdate -NoPause` | stay off until Medic re-enables the service (about a day) or until a UEM ON command; use only if you want first-day silence and accept the drift |

### 3.2 Patch loop, PowerShell

For a provisioning step that can reboot and resume (Packer with `windows-restart`, MDT, SCCM task sequence with "restart computer" steps), run one round per step and branch on the exit code. For a single long step that cannot reboot, loop until exit 0 and record that a reboot is owed:

```powershell
# One patch round. Returns 0 (done), 3010 (done, reboot required), 1 (failed).
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Build\DEX_Start-WindowsUpdate.ps1 -Mode Direct -Wait
switch ($LASTEXITCODE) {
    0    { 'Nothing left to install.' }
    3010 { 'Installed; reboot and run this step again.' }
    1    { throw 'Windows Update round failed; see %SystemRoot%\Temp\UEM_DEX_Start-WindowsUpdate.log' }
}
```

Three rounds normally cover a Windows 11 build: servicing stack and cumulative update, then whatever the cumulative update unlocked (.NET, Defender platform), then a confirming empty round. Cap it at four.

### 3.3 Packer

```hcl
provisioner "powershell" {
  elevated_user     = var.winrm_username
  elevated_password = var.winrm_password
  inline = [
    "C:\\Build\\DEX_Stop-WindowsUpdate.ps1 -NoPause"
  ]
}

# ... application provisioners ...

provisioner "powershell" {
  elevated_user     = var.winrm_username
  elevated_password = var.winrm_password
  valid_exit_codes  = [0, 3010]
  inline            = ["C:\\Build\\DEX_Start-WindowsUpdate.ps1 -Mode Direct -Wait"]
}
provisioner "windows-restart" {}

# repeat the two blocks above two or three times

provisioner "powershell" {
  elevated_user     = var.winrm_username
  elevated_password = var.winrm_password
  inline            = ["C:\\Build\\DEX_Start-WindowsUpdate.ps1 -Mode None"]
}
```

`valid_exit_codes` matters: without it Packer treats 3010 as a failure.

### 3.4 MDT or SCCM task sequence

- **Run PowerShell Script** step, execution policy Bypass, parameters `-Mode Direct -Wait`, with **3010** added to the step's success codes (SCCM: the step's Options tab; MDT: the script's exit code is returned as the step result, so add a condition or wrap it).
- Follow with **Restart Computer**.
- Duplicate the pair two or three times, or put the pair in a group with a condition on the registry stamp: `HKLM\Software\AirWatch\Extensions\WindowsUpdateControl\Found` not equal to `0`.
- Last steps: **Restart Computer**, then **Run PowerShell Script** with `-Mode None`.

### 3.5 Hyper-V, VMware or manual builds in Audit mode

Same sequence from an elevated console in the running VM. Run as the local administrator; the Windows Update Agent API does not need SYSTEM. Reboot when a round returns 3010 and run the next round after sign-in.

### 3.6 Before capture

```powershell
# Remove build-time traces (optional; both are harmless if left)
Remove-Item 'HKLM:\Software\AirWatch\Extensions\WindowsUpdateControl' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:SystemRoot\Temp\UEM_DEX_Start-WindowsUpdate.log" -Force -ErrorAction SilentlyContinue

# Confirm no reboot is pending before sysprep /generalize
Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
```

Both `Test-Path` lines must return `False`. If either is `True`, reboot and check again; Sysprep fails on a pending servicing operation.

---

## 4. Things that catch people

- **Off is not forever.** Windows Update Medic re-enables the service in about a day. The 35-day pause is what makes a UEM hold stick; use `-NoPause` only for builds and other short holds.
- **Orchestrator mode obeys the policy.** With a "notify before install" policy it downloads and waits for a user. Use Direct mode when you need the install to happen regardless.
- **Nothing here reboots.** Direct mode reports `RebootRequired`; you decide when.
- **Do not run `-Wait` from UEM.** It blocks for the length of the install and the Hub script timeout will kill it. UEM gets the scheduled-task form automatically.
- **A pending reboot still finishes its updates.** Turning updates off after a cumulative update has staged does not stop the servicing stack at the next boot.
