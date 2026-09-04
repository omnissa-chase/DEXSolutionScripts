# DiskCleanup Testing Guide

**Audience:** A colleague doing hands-on validation of the DiskCleanup scripts before they are rolled out through Workspace ONE UEM. Everything in sections 1 to 5 runs the files directly on a local test machine. Section 6 covers the UEM round trip.

**Scope:** The two Disk Cleanup wrappers, which are the scripts that changed, plus a short section on the profile scripts.

| Script | Changes anything? | Covered in |
|---|---|---|
| [Start-ClearRecycleBin.ps1](Start-ClearRecycleBin.ps1) | Yes. Empties the Recycle Bin for every user | Section 3 |
| [Start-DiskCleanup.ps1](Start-DiskCleanup.ps1) | Yes. Removes previous Windows installations, update leftovers, dumps, logs | Section 4 |
| [Get-UserProfileSize.ps1](Get-UserProfileSize.ps1) | No | Section 5 |
| [Start-UserProfileCleanup.ps1](Start-UserProfileCleanup.ps1) | Yes. Deletes whole user profiles | Section 5 |
| [profile_size_inventory.ps1](profile_size_inventory.ps1) | No | [General Testing Guide, section 2.1](../General-Testing-Guide.md) |

---

## What changed, and what you are testing for

Both Disk Cleanup wrappers used to report the space they reclaimed, and the number was always wrong, for three separate reasons.

1. `cleanmgr /sagerun` forks a worker and returns immediately, so free space was measured while cleanup was still running.
2. The subtraction ran backwards. It computed old free space minus new, which for a cleanup can only be zero or negative.
3. The result was cast to a whole number of gigabytes, so a 400 MB cleanup read as 0.

The fix adds a wait option, set with `WaitForCleanup`, that blocks until cleanup has finished, corrects the arithmetic, and reports to two decimal places. The old symptom to watch for is a `SpaceCleaned` value that is **zero or negative by roughly the amount you expected to reclaim**. A pass is a positive value that matches what you put in the bin.

---

## 1. Before you start

**Use a virtual machine with a snapshot.** Start-DiskCleanup removes `Windows.old`, which is the only way to roll back a feature update, and Start-ClearRecycleBin empties the Recycle Bin for every user on the device. Neither is recoverable.

**Open an elevated Windows PowerShell 5.1 session**, which is what UEM uses. PowerShell 7 also works. If a result looks context dependent, Sysinternals `PsExec64.exe -s -i powershell.exe` gives you a true SYSTEM shell.

**Run these preflight checks.** All are read-only.

```powershell
Set-Location C:\path\to\DEXSolutionScripts\DiskCleanup

# cleanmgr must exist. It is missing on some Server and LTSC builds.
Get-Command cleanmgr

# The Windows Modules Installer should be idle before a waiting test.
# If Windows Update is mid-install, a waiting run will legitimately take a long time.
Get-Service TrustedInstaller | Select-Object Status
Get-Process TiWorker -ErrorAction SilentlyContinue

# Confirm each script wraps its body in a function.
Get-Command .\Start-DiskCleanup.ps1 -Syntax
Get-Command .\Start-ClearRecycleBin.ps1 -Syntax
```

Both should report **no parameters**. That is correct and deliberate. The Workspace ONE script engine does not recognise a `param` block at script scope, so the parameters now live on a function inside each file, and every input arrives as an environment variable.

> `Get-Help` shows nothing useful for any script in this repository. The shared header uses a `.DISCLAIMER` keyword that PowerShell does not recognise, and one unknown keyword disables the whole help block. Use `Get-Command -Syntax` instead.

---

## 2. How inputs reach the scripts

Every input arrives as an environment variable. The two below apply to `Start-DiskCleanup.ps1`; `Start-ClearRecycleBin.ps1` takes `OlderThanDays` and `AllFixedDrives` instead, and no longer waits on anything. Anything absent, empty, or unparseable falls back to the previous no-wait behaviour, so a bad input can never leave a script hanging.

| Input | Environment variable | Default | Accepted values |
|---|---|---|---|
| Wait for completion | `WaitForCleanup` | off | `true` / `false` (anything `[Convert]::ToBoolean` accepts) |
| Wait ceiling | `WaitTimeoutSeconds` | `900` | Positive integer |

**The environment variable channel is how UEM does it.** UEM supports variables on the script object itself, not per assignment, so one script object carries one set of values fleet-wide. The repository runbook treats behaviour switches like this as the sanctioned use of that feature. If two rings need different settings, create two script objects.

**To simulate the UEM channel locally**, set the variable in the same session before running the script, and clear it afterwards.

```powershell
$env:WaitForCleanup = 'true'
.\Start-ClearRecycleBin.ps1
$env:WaitForCleanup = $null
```

**You can verify input resolution without reading any code.** When `Wait` resolves to true the script prints one extra line before the results, and that line shows the resolved timeout:

```
Waiting up to 900 second(s) for Disk Cleanup to finish...
```

No line means `Wait` resolved to false. A different number means the timeout came from somewhere other than the default. That single line is the observable for every input test below.

---

## 3. Start-ClearRecycleBin.ps1

**This script was rewritten and no longer uses Disk Cleanup.** `cleanmgr` empties the Recycle Bin belonging to the account that calls it. UEM runs as SYSTEM, whose bin is always empty because SYSTEM deletions bypass the bin entirely, so the old version reclaimed nothing on a managed device. It now clears the per-user folders under `<drive>:\$Recycle.Bin\<SID>\` directly.

### 3.1 It must refuse to claim a false success

Run it as yourself, unelevated, on a device with more than one profile:

```powershell
$env:WhatIf = 'true'
.\Start-ClearRecycleBin.ps1
$env:WhatIf = $null
```

Expect a `Cannot read the Recycle Bin for ...` line for every other user, and exit `1`. A normal account cannot read another user's bin folder. This check exists so a wrong-context deployment is visible instead of silently reclaiming nothing.

### 3.2 Baseline

From an **elevated** session, so you can see every user's folder:

```powershell
Get-ChildItem -LiteralPath 'C:\$Recycle.Bin' -Force -Directory | ForEach-Object {
    $items = @(Get-ChildItem -LiteralPath $_.FullName -Force -EA SilentlyContinue | Where-Object Name -like '$R*')
    [pscustomobject]@{ SID = $_.Name; Items = $items.Count }
}
[math]::Round((Get-Volume -DriveLetter C).SizeRemaining / 1GB, 2)
```

### 3.3 Put 1 GB in the bin

Deleting from PowerShell normally bypasses the Recycle Bin, so use the shell call below. Do this as a normal user:

```powershell
New-Item -ItemType Directory -Path C:\Temp -Force | Out-Null
fsutil file createnew C:\Temp\recycle-probe.bin 1073741824

Add-Type -AssemblyName Microsoft.VisualBasic
[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile('C:\Temp\recycle-probe.bin', 'OnlyErrorDialogs', 'SendToRecycleBin')
```

Free space should **not** change. Binned data is still allocated, which is the whole point.

### 3.4 Dry run

```powershell
$env:WhatIf = 'true'
.\Start-ClearRecycleBin.ps1
$env:WhatIf = $null
```

| Check | Pass condition |
|---|---|
| `What if:` line | Names the probe and the owning account |
| Per-user summary | About 1024 MB against your account |
| `SpaceCleaned` | About 1024 MB |
| Probe | Still in the bin |
| Exit code | `0` when elevated |

### 3.5 Age filter

```powershell
$env:WhatIf = 'true'; $env:OlderThanDays = '7'
.\Start-ClearRecycleBin.ps1
$env:WhatIf = $null; $env:OlderThanDays = $null
```

A probe deleted moments ago must appear under `ItemsRetained`, not `ItemsRemoved`. The age comes from the deletion timestamp inside the `$I` sidecar, not from the file's own timestamp, so a recently copied old file is still judged by when it was deleted.

### 3.6 Live run

Elevated, so it reaches every user:

```powershell
.\Start-ClearRecycleBin.ps1
"exit=$LASTEXITCODE"
[math]::Round((Get-Volume -DriveLetter C).SizeRemaining / 1GB, 2)
```

Expect `SpaceCleaned` of roughly 1024 MB, exit `0`, the probe gone, and free space actually up by about a gigabyte. Folders in the bin are cleared recursively and their `$I` sidecars go with them.

### 3.7 The case the rewrite exists for: running as SYSTEM

Put a fresh probe in the bin as a normal user, then run the script as SYSTEM:

```powershell
$s = (Resolve-Path .\Start-ClearRecycleBin.ps1).Path
schtasks /Create /TN DEX_RBTest /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$s`"" /SC ONCE /ST 23:59 /RU SYSTEM /RL HIGHEST /F
schtasks /Run /TN DEX_RBTest
Start-Sleep -Seconds 20
schtasks /Delete /TN DEX_RBTest /F
```

The probe must be gone. This is the test the old version fails: run the same probe against the previous cleanmgr-based script as SYSTEM and it survives untouched, because SYSTEM's own bin is what gets emptied.

Check the run's first line. It now reports the account, so `Running as NT AUTHORITY\SYSTEM` confirms the context the rest of the test depends on.

### 3.8 The desktop icon, and ResetShellIcon

Expect the icon to stay full after a successful run. That is not a failure. Explorer caches each user's item count and is never told about a deletion made on the filesystem, so the icon lags until something else changes the bin. Confirm the real state by opening the bin rather than by looking at the icon.

`ResetShellIcon` fixes the icon by deleting the emptied per-user folder, which clears that cache:

```powershell
$env:ResetShellIcon = 'true'
.\Start-ClearRecycleBin.ps1
$env:ResetShellIcon = $null
```

| Check | Pass condition |
|---|---|
| Output | A `Reset the Recycle Bin folder for ...` line per emptied bin |
| Desktop icon | Now shows empty |
| With `WhatIf` set | No reset line, folder still present |
| With an age filter that retained items | No reset line for that user, folder still present |
| After the next delete | The folder comes back and the bin works normally |

That last row is the one worth confirming, since deleting a live user's bin folder sounds riskier than it is. Send any file to the Recycle Bin afterwards and check the folder reappears:

```powershell
Add-Type -AssemblyName Microsoft.VisualBasic
Set-Content C:\Temp\recreate.txt 'probe'
[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile('C:\Temp\recreate.txt', 'OnlyErrorDialogs', 'SendToRecycleBin')
Get-ChildItem -LiteralPath 'C:\$Recycle.Bin' -Force -Directory | Select-Object Name
```

---
## 4. Start-DiskCleanup.ps1

The amount reclaimed here depends on what the machine has accumulated, so the test is less about the exact number and more about the configuration, the wait, and the exit code. This is the only one of the two scripts that uses Disk Cleanup, so it is the only one with wait behaviour to test.

### 4.1 Preflight: is there anything to clean?

```powershell
Dism /Online /Cleanup-Image /AnalyzeComponentStore
```

Look for `Component Store Cleanup Recommended : Yes`. If it says `No` and there is no `C:\Windows.old`, expect a small `SpaceCleaned` and a short wait. That is still a valid run; it just exercises less of the wait routine. A VM that has recently taken a cumulative update is the best candidate.

### 4.2 Run with the wait enabled

```powershell
$Sw = [Diagnostics.Stopwatch]::StartNew()
$env:WaitForCleanup = 'true'
$Out = .\Start-DiskCleanup.ps1
$Sw.Stop()
$env:WaitForCleanup = $null
$Out
"exit=$LASTEXITCODE  seconds=$([int]$Sw.Elapsed.TotalSeconds)"
```

Expected: waiting line present, `SpaceCleaned` zero or positive, exit `0`. When Update Cleanup has work to do this can take several minutes. In a second window you can watch the handoff happen:

```powershell
while ($true) { "{0:HH:mm:ss}  cleanmgr={1}  TiWorker={2}  TrustedInstaller={3}" -f (Get-Date), [bool](Get-Process cleanmgr -EA SilentlyContinue), [bool](Get-Process TiWorker -EA SilentlyContinue), (Get-Service TrustedInstaller).Status; Start-Sleep 5 }
```

You should see cleanmgr disappear first, then TiWorker appear and the service go to `Running`, then both go idle. The script returns shortly after that.

### 4.3 Verify the registry configuration

This confirms the half of the script that selects categories, independent of how much space came back. It is read-only.

```powershell
$VC = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
Get-ChildItem $VC | ForEach-Object {
    $P = Get-ItemProperty $_.PSPath
    [pscustomobject]@{ Category = $_.PSChildName; StateFlags0055 = $P.StateFlags0055; StateFlags0056 = $P.StateFlags0056 }
} | Sort-Object Category | Format-Table -AutoSize
```

Expected: every category has a value under both columns. Exactly these seven read `2` under `StateFlags0055`, and everything else reads `0`:

- Previous Installations
- System error memory dump files
- System error minidump files
- Update Cleanup
- Windows Error Reporting Files
- Windows Reset Log Files
- Windows Upgrade Log Files

Under `StateFlags0056` only `Recycle Bin` reads `2`. A missing column means that script never reached its registry loop, which usually means it was not run elevated.

---

## 5. Profile scripts

These did not change functionally, but the README describing them was wrong in ways that affect testing, so two corrections first. **Neither script writes a log file.** Both declare `$LOG_PATH` and create its folder, but all output goes to the script result. And `Get-UserProfileSize.ps1` reports on the enrollment user too; its `$ENROLLMENTUSER` variable is declared but never used.

### 5.1 Get-UserProfileSize.ps1: read-only, safe anywhere

```powershell
.\Get-UserProfileSize.ps1
```

Expect one `Starting profile cleanup...` line, then an `Examining profile:` and a `Profile, name, has size X MB, and has been inactive, Y day(s)` line for every domain user profile. On a workgroup machine, local accounts count as domain users. Nothing is deleted. The output header says "cleanup" because the script is a fork of the cleanup script; that is cosmetic.

### 5.2 Start-UserProfileCleanup.ps1: deletes for real

There is no dry-run mode. Read the three tunables at the top of the script before every run.

**Safe first run.** Raise `$DAYS_INACTIVE` to something no profile can meet, such as `3650`, run it, and confirm every profile is examined and none deleted. This proves the enumeration and sizing without risk.

**Positive test, on a fresh VM only.** The recipe below sets both thresholds to zero, which qualifies **every** profile on the machine except the enrollment user. Only do this on a VM whose profiles are your own admin account and the probe below, and set `$ENROLLMENTUSER` to your own account name for the duration of the test so it is excluded.

```powershell
net user dexprobe 'Pr0be!Pass#2026' /add
runas /user:dexprobe "cmd /c exit"       # enter the password once; this creates C:\Users\dexprobe
Get-CimInstance Win32_UserProfile | Where-Object LocalPath -like '*dexprobe*' | Select-Object LocalPath, LastUseTime
```

Now edit the script: `$ENROLLMENTUSER` to your account, `$DAYS_INACTIVE = 0`, `$SIZE_THRESHOLD_MB = 0`. Run it and expect `Deleted profile: C:\Users\dexprobe`, the folder gone, and your own profile listed as examined but not deleted. Then restore the tunables and remove the account:

```powershell
net user dexprobe /delete
```

On a domain-joined VM, local accounts are excluded by the domain filter, so the probe has to be a domain account.

---

## 6. UEM round trip

Do this after the local tests pass. The aim is to confirm the variable channel and the timeout setting survive delivery.

1. Update the script object under **Resources > Scripts** with the new file. Context stays **System**.
2. On the script object, add a variable `WaitForCleanup` with value `true`. Optionally add `WaitTimeoutSeconds`.
3. Set the script timeout to at least the wait ceiling plus a margin. **The default ceiling of 900 seconds needs a 20 minute timeout.** The old 30 second value will kill a waiting run.
4. Assign to a smart group containing only the test VM and trigger a run.
5. In the run results, confirm the output shows the waiting line with the value you set, followed by `SpaceCleaned` and `FreeSpace`, and that the status is success.
6. To see the failure path, set `WaitTimeoutSeconds` to `1` and run again. Expect the `Warning:` line and a failed status with exit code `1`. Set it back afterwards.

Leave `WaitForCleanup` unset on the production script object if you want the previous fast no-wait behaviour, and set it if you want the reported figure to be accurate. Those are the only two deployment choices.

---

## 7. Pass and fail checklist

| # | Test | Pass |
|---|---|---|
| 1 | Both scripts report no parameters, and wrap their body in a function | Yes / No |
| 2 | Unelevated run reports `Cannot read the Recycle Bin for ...` and exits 1 | Yes / No |
| 3 | 1 GB probe, elevated dry run: about 1024 MB reported, probe still present | Yes / No |
| 4 | `OlderThanDays=7` with a fresh probe: counted under ItemsRetained | Yes / No |
| 5 | Elevated live run: probe gone and free space up by about 1 GB | Yes / No |
| 6 | Run as SYSTEM via scheduled task: another user's probe is removed | Yes / No |
| 7 | `ResetShellIcon=true`: reset line per emptied bin, icon clears, folder returns after the next delete | Yes / No |
| 8 | Start-DiskCleanup with `WaitForCleanup=banana`: live run, no waiting line | Yes / No |
| 9 | Start-DiskCleanup with `WaitTimeoutSeconds=120`: waiting line reads 120 | Yes / No |
| 10 | Start-DiskCleanup with `WaitForCleanup=true`: exit 0, `SpaceCleaned` not negative | Yes / No |
| 11 | Registry: seven categories at 2 under 0055, Recycle Bin at 2 under 0056, all else 0 | Yes / No |
| 12 | Get-UserProfileSize lists every profile, deletes nothing | Yes / No |
| 13 | UEM run shows waiting line and both result lines with success status | Yes / No |

---

## 8. Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| Recycle Bin icon still full after a successful run | Explorer caches the count and is not notified about filesystem deletions | Not a bug. Open the bin to see the real state, or set `ResetShellIcon=true` |
| `cleanmgr` not recognised | Server or LTSC build without Desktop Experience | Test on a client SKU, or install the feature |
| A waiting run takes the full ceiling and exits 1 | Windows Update is mid-install, so TrustedInstaller is busy for its own reasons | Check `Get-Process TiWorker`, wait for it to finish, run again. Or raise the ceiling |
| `SpaceCleaned` is about `-1.00` after the probe test | Old code with the inverted subtraction | Confirm the file version is 1.2.0 |
| `SpaceCleaned` is `0.00` when waiting, after the probe test | Probe never reached the bin, usually because it exceeded the bin size limit | Check `$Bin.Items()` before running. Use a 500 MB probe |
| `SpaceCleaned` is slightly negative, such as `-0.03` | Other processes wrote to disk during the run | Not a bug. Anything within a few hundredths of zero is noise |
| Waiting line missing when you expected it | Variable set in a different session, or misspelt | It must be set in the session that launches the script. The names are `WaitForCleanup` and `WaitTimeoutSeconds` |
| Registry columns missing | Script did not run elevated | Rerun from an elevated session |
| `Get-Help` shows only the syntax line | The `.DISCLAIMER` header keyword disables comment help repo-wide | Use `Get-Command -Syntax` |
| Start-UserProfileCleanup examines but never deletes | Profiles not old enough, or thresholds too high | Compare `LastUseTime` from `Get-CimInstance Win32_UserProfile` against `$DAYS_INACTIVE` |

---

## 9. Clean up afterwards

```powershell
$env:WaitForCleanup = $null; $env:WaitTimeoutSeconds = $null
net user dexprobe /delete 2>$null
```

The `StateFlags0055` and `StateFlags0056` registry values are harmless and the scripts rewrite them on every run, so they can stay. If you want the machine back to a clean state, revert the VM snapshot, which also restores anything the cleanup removed.
