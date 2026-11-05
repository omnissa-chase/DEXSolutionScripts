# Test Validation - Resolution Scripts

**Audience:** engineers validating resolution (non-sensor) scripts before they are marked `4) Complete - Tested` in `SCRIPT-INVENTORY-CSV.csv` and published through Workspace ONE UEM.

**Scope:** every resolution script in the repo outside `Archived`, `Deprecated`, `TroubleshootingWizard`, `_RAWDATA`, `Sensors` and `OneTimeSensor`. 68 scripts in 7 groups. Sensors are covered by `UEM-API-TESTING-SPEC.md` and `General-Testing-Guide.md`, not here.

**Last updated:** 2026-10-29 (defect fixes, then the first UEM sweeps: 44 scripts and 69 sensors through the connector). Lab evidence in this document comes from the runs recorded in `C:\Temp\FixReport\Summary.csv` and `C:\Temp\DEXLabRuns\LabRun_20261028_14*\` on the lab VM.

---

## 1. How to use this document

Each script has one block with the same shape:

| Field | Meaning |
|---|---|
| **Path / version** | Repo-relative path and the `$SCRIPT_VERSION` or header version at the time of writing |
| **Inventory** | `Status` and `Potential End User Impact` columns from `SCRIPT-INVENTORY-CSV.csv`. `NOT IN CSV` means the script has no inventory row yet and cannot be published until one exists |
| **Inputs** | Parameters and `$env:` variables the script reads. Under UEM these arrive as script variables; locally set `$env:Name = 'value'` before the run |
| **Prerequisites** | Product, service or hardware that must exist for a meaningful test |
| **Automated coverage** | Break test harness, Pester unit tests, and the `uem-tests.json` entry, if any |
| **Test steps** | Numbered: precondition, how to create the broken state, run command, expected output and exit code, verification, restore |
| **Status** | One of the values below, with the evidence |
| **Review notes** | Defects or hazards found while reading the script. A `FIX FIRST` item blocks the test until it is addressed |

### 1.1 Status values

| Status | Meaning |
|---|---|
| `PASS - LAB` | Break test ran on the lab VM, remediation fixed the injected fault, validation confirmed it. Result JSON path given |
| `PASS - UEM` | A throwaway copy was published to the test tenant by the UEM connector (`UEM-API-TESTING-SPEC.md`), ran under Hub as SYSTEM on every live device in the test smart group and reported `Completed`. Proves the script runs clean as UEM runs it on a healthy machine; it does not inject a fault. Run id and result file given |
| `PASS - UNIT` | Pester unit tests pass. No hardware-level proof |
| `TESTED - MANUAL` | Inventory says `4) Complete - Tested`. The test was manual and no result artefact is in the repo. Steps below reproduce it |
| `NEEDS TEST` | Steps written, not yet executed |
| `NEEDS TEST - PRODUCT VM` | Steps written, but the product is not on the lab VM. Needs a VM with the product installed |
| `MANUAL ONLY` | Session-ending or destructive to user data. Never run through the harness or against a test group that contains the observing machine. Since 2026-10-30 the session-ending ones run through UEM against the single-VM group `Test_JSpencerOnly` (manifest key `onlyInGroup`), which holds only `CHASEWIN11_2`; the connector skips them against any other group. Manual steps given |
| `FIX FIRST` | A defect found during review makes a test meaningless until the script is corrected |
| `DEFERRED` | Out of scope for now by decision, not by defect. The previous status is kept in the cell. Currently the SCOM agent remediation set (since 2026-10-30, while the approach is reviewed; an agent upgrade is often the preferred fix) |

**Full Pass (agreed 2026-11-02).** A script moves to inventory status `4) Complete - Tested` only on a Full Pass, which depends on what kind of script it is:

| Kind | Examples | Full Pass means |
|---|---|---|
| Remediation: detects a fault and fixes it | `Invoke-AutoRemediate*`, `Invoke-Remediate*`, `Restart-WindowsUpdateServices.ps1`, `Invoke-DefenderDynamicPerformance.ps1` | `PASS - LAB` (a `<Script>_BreakTest.ps1` injected the fault on the lab VM and the script fixed it) **and** `PASS - UEM` |
| Action or report: does one thing on request, there is no fault to inject | reboots, sign-off, soft lock, BitLocker power-off, disk cleanup, recycle bin, threat report, logon audit enablement, logon measurement, Defender pause / update / cloud block, service or process restart with a named target | `PASS - UEM` **and** the observed effect recorded in this document (event log entry, state change, output) |

Everything else stays at `3) Complete - Needs Testing` with its validation status showing how far it got. Partial passes keep their caveat in the row text (for example `Start-UserProfileCleanup.ps1` has proven only the no-delete path) and do not count as Full Pass until the caveat is cleared.

### 1.2 Lab environment

| Item | Value |
|---|---|
| Host | `CBRADLEYSWIN11`, VMware VM, Windows 11 Pro build 26200, WORKGROUP |
| Snapshot | Taken before the 2026-10-28 runs. Revert to it after any `Dirty` harness result or any `MANUAL ONLY` test |
| Test marker | `C:\Temp\FixReport\.dex-test-machine` exists (required by `Assert-DexTestHost`) |
| Inbox consumer apps | Removed for every user by the AppX bloat break test on 2026-11-02 (Xbox, Bing Weather and News, Solitaire, Feedback Hub, Get Help, Maps, Clipchamp and others) and deliberately not restored; nothing in the lab needs them. A snapshot from before that run is the only way to see the script's first-run removal again |
| Present | Microsoft Defender, Google Chrome, OneDrive, Print Spooler, VMware virtual audio and USB controllers |
| Absent | Outlook, Teams, Zoom, FSLogix, SCCM client, SCOM agent, CrowdStrike, Trellix, Trend Micro, Wi-Fi adapter, VPN connection, App Volumes agent, BitLocker |
| Known quirks | Console mouse/keyboard are on the xHCI controller, so break tests disable the EHCI controller only. Master waveOut volume is genuinely 0 on this VM. BITS default start type is Manual. Spooler default is Automatic/Running |

### 1.3 Running a script the way UEM does

UEM runs scripts as a file under Windows PowerShell 5.1 as SYSTEM. Nearest local equivalent from an elevated PowerShell 5.1 console:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Something.ps1
"exit code: $LASTEXITCODE"
```

For true SYSTEM parity (different registry hives, no interactive desktop) use Sysinternals:

```powershell
PsExec64.exe -s -i powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\path\Invoke-Something.ps1
```

Step-engine scripts (the `Invoke-AutoRemediate*` family) share one exit-code contract: `0` all steps passed or were remediated, `1` at least one step is `Failed` after remediation, `2` devices remain unfixed (driver scripts only). Their output ends with a `Passed: n | Warnings: n | Failed: n | Remediations run: n` line, and most write a summary to `HKLM:\Software\AirWatch\Extension\DEXRecords\<Name>`.

### 1.4 Automated test entry points

```powershell
# Non-destructive, no elevation: 30 Pester unit tests for the two driver scripts
.\WindowsAutoRemediation\_AutomatedTesting\Unit\Invoke-DriverUnitTests.ps1

# Non-destructive harness dry run (stubs, no real device changes)
.\WindowsAutoRemediation\_AutomatedTesting\Unit\Invoke-DriverHarnessDryRun.ps1

# Destructive. Elevated, on the lab VM only, snapshot first. Runs unit tests, dry run, all six break tests, analysis.
.\WindowsAutoRemediation\_AutomatedTesting\Invoke-DriverDeviceLabRun.ps1 -Force
.\WindowsAutoRemediation\_AutomatedTesting\Invoke-DriverDeviceLabRun.ps1 -Force -IncludeRebootBreaks   # adds the Printer reboot break

# Re-analyse C:\Temp\FixReport without re-running anything
.\AutomatedTesting\Invoke-FixReportAnalysis.ps1
```

### 1.5 UEM script variables that must be set

Most scripts run with no variables. The ones below read a UEM script variable (surfaced to the script as an environment variable) that has no usable default, so a UEM item created without it either fails on every device or silently does nothing. This list comes from the code, not the inventory's `Requires Input` column; the two disagree on the driver scripts (noted at the end).

| Script | Variable | Without it | Also useful |
|---|---|---|---|
| `Restart-WinProcess.ps1` | `FileDescription` | Exits 1: `Error: FileDescription is not specified.` | `StartService` (`true`/`false`, default false) |
| `Restart-WinProcessGraceful.ps1` | `FileDescription` | Exits 1 | `Mode` (`Detached`/`Inline`), `GracefulTimeoutSec`, `Restart`, `SkipIfUnsavedWork` |
| `Restart-WinProcessGracefulEx.ps1` | `FileDescription` | Exits 1 (prototype, not for publication) | `Restart`, `GracefulTimeoutSec` |
| `Restart-WinService.ps1` | `ServiceName` | Exits 1: `Error: ServiceName is not specified.` | `WhatIf` |
| `Invoke-AutoRemediateSCOMClonedIdentity.ps1` | `ConfirmHighImpact` = `true` | Exits 0 with `Status = Skipped:NotConfirmed`; detection reported, nothing reset (fail-closed by design) | `WhatIf` |
| `Invoke-AutoRemediateSCOMHealthServiceCache.ps1` | `ConfirmHighImpact` = `true` | Exits 0 with `Status = Skipped:NotConfirmed`; nothing flushed | `WhatIf` |

Variables that change what the script does, but have a safe default:

| Script | Variable | Default behaviour | Set it to |
|---|---|---|---|
| `Invoke-DriverUpdates.ps1` | `Mode` | `Detect` only; exits 1 whenever driver updates exist | `Install` to apply; `AllowReboot=True` to get exit 3010 |
| `Invoke-AutoRemediateOutlook.ps1` | `AllowDestructiveActions` | Add-in disable and OST rename are report-only | `true` to let steps 1 and 2 act |
| `Invoke-AutoRemediateTeams.ps1` | `AllowDestructiveActions` | Auth cache clear and New Teams re-registration skipped | `true` |
| `Invoke-AutoRemediateZoom.ps1` | `AllowDestructiveActions` | Token cache clear and webcam consent fix skipped | `true` |
| `Invoke-AutoRemediateAppXBloat.ps1` | `RemoveForExistingUsers` | Deprovision for future users only | `true` to also remove for existing users |
| `Measure-LogonDuration.ps1`, `Measure-LogonDurationMultiSession.ps1` | `DeployMode` | `RunNow` (one measurement) | `DeployScheduledTask` to install the recurring collector |
| `Invoke-AutoRemediateDriverIssues.ps1`, `Invoke-AutoRemediateAllDriverIssues.ps1` | `DriverFilter`, `AllowedActions` | Empty filter = every device; actions Scan, Restart, Rollback | A filter to scope; add `Reinstall`/`Uninstall` to escalate further |
| `Invoke-AutoRemediateNetworkStack.ps1`, WindowsLogon scripts, `Invoke-AutoRemediateGenericVPN.ps1`, `Start-ClearRecycleBin.ps1`, `Restart-WinService.ps1` | `WhatIf` | Live run | `true` for a dry run on first deployment |

Scripts with hard-coded tunables and no variables at all, where the file itself must be edited before publishing: `Start-UserProfileCleanup.ps1` (`$DAYS_INACTIVE`, `$SIZE_THRESHOLD_MB`, `$ENROLLMENTUSER`), `Invoke-RebootWithUserDefer.ps1` (`$MaxHours`, `$ShowEveryMinutes`, `$RebootCountdownSeconds`), `Invoke-SimpleReboot.ps1` (`$CountdownSeconds`).

Inventory discrepancy: `SCRIPT-INVENTORY-CSV.csv` marks `Invoke-AutoRemediateDriverIssues.ps1` and `Invoke-AutoRemediateAllDriverIssues.ps1` as `Requires Input = Yes`, but both default `DriverFilter` to empty (all devices) and run without any variable. The six scripts in the first table are the ones that truly require one; the inventory agrees on all six.

---

## 2. Summary

| # | Script | Group | Inventory status | Impact | Automated coverage | Validation status |
|---|---|---|---|---|---|---|
| 1 | `Invoke-AutoRemediateAllDriverIssues.ps1` | Device / driver | Tested | Critical | Break test, 21 unit tests, UEM entry | `PASS - LAB` + UEM `6c8405` |
| 2 | `Invoke-AutoRemediateDriverIssues.ps1` | Device / driver | Tested | Critical | Break test, 9 unit tests, UEM entry | `PASS - LAB` + UEM `6c8405` |
| 3 | `Invoke-AutoRemediateAudioBluetooth.ps1` | Device / driver | Tested | Medium | Break test (5 breaks) | `PASS - LAB` + UEM `6c8405` |
| 4 | `Invoke-AutoRemediateNetworkStack.ps1` | Device / driver | Tested | High | Break test (2 breaks), UEM via `Test_JSpencerOnly` | `PASS - LAB` 2026-10-28 + UEM `e01538` (single-VM group, 2026-10-30) |
| 5 | `Invoke-AutoRemediateWindowsUpdates.ps1` | Device / driver | Tested | Medium | Break test (4 breaks) | `PASS - LAB` + UEM `6c8405` |
| 6 | `Invoke-AutoRemediatePrinter.ps1` | Device / driver | Tested | Low | Break test (4 breaks incl. reboot) | `PASS - LAB` + UEM `6c8405` |
| 7 | `Invoke-AutoRemediateWiFiSignalIssues.ps1` | Windows remediation | Needs Testing | Medium | none (tested by hand) | Full Pass on 2.0.2 by the user's decision 2026-11-03: `PASS - LAB` from the user's own remediation testing on a Wi-Fi-equipped machine (a separate session fixed three 2.0.1 bugs and verified them; 2.0.2 landed on main as `40551db`), and `PASS - UEM` only for the no-adapter path (`6c8405`), since neither lab VM has a wireless adapter. The product path has not run under Hub |
| 8 | `Invoke-DriverUpdates.ps1` | Windows remediation | Tested | Medium | Break test (1 breaks) + UEM | `PASS - LAB` + `PASS - UEM` = Full Pass (break test run f6feb1b31416 on 2026-11-02: WuauservStopped (service stopped, script started it; driver discovery itself is not injectable on a VM); result `C:\Temp\FixReport\Invoke-DriverUpdates\f6feb1b31416.json`; UEM sweep `6c8405`; rerun on 1.0.1 `0ec8523cc211` 2026-11-05 11:30 Passed, WuauservStopped repaired with the policy pre-check and pending-reboot helper in the path) |
| 9 | `Invoke-RemediateMemoryCompression.ps1` | Windows remediation | Tested | Low | Break test (1 break) | `PASS - LAB` + `PASS - UEM` = Full Pass (break test run 075ce256c2af on 2026-11-02, memory compression disabled and re-enabled, result `C:\Temp\FixReport\Invoke-RemediateMemoryCompression\075ce256c2af.json`) |
| 10 | `Invoke-RemediatePageFile.ps1` | Windows remediation | Tested | Medium | Break test (2 breaks) + UEM | `PASS - LAB` + `PASS - UEM` = Full Pass (break test runs c845854c3e7e and 114fedf1ed3c on 2026-11-02 (both files lost to the snapshot revert; rerun 75c3e07e492d at 12:57 passed the fixed break again and its file is kept): PageFileManualUnderThreshold (flag cleared, usage 9.9 %, script 1.0.1 warned "manually configured" and changed nothing, exit 0) and PageFileManualNearCapacity (flag cleared, 2 GB fixed size written through the `PagingFiles` registry value after WMI refused it, threshold override 0; script 1.0.1 set the flag back and wrote `Status = Remediated`, exit 0); results `C:\Temp\FixReport\Invoke-RemediatePageFile\c845854c3e7e.json` and `114fedf1ed3c.json`; UEM sweep `6c8405` (2026-10-29) `Completed` on both devices; script 1.0.1, defect 13.2.b) |
| 11 | `Invoke-RemediateSysMain.ps1` | Windows remediation | Tested | Low | Break test (2 breaks) | `PASS - LAB` + `PASS - UEM` = Full Pass (break test run a1b442690696 on 2026-11-02, SysMainService stopped and repaired, result `C:\Temp\FixReport\Invoke-RemediateSysMain\a1b442690696.json`; second run 90575d8adf92 covered SysMainDisabledWhileRunning, the gap 1.0.1 closed; script 1.0.1) |
| 12 | `Disable-NonEssentialStartupApps.ps1` | Windows remediation | Needs Testing | Medium | none | `TESTED - MANUAL` + UEM `6c8405` |
| 13 | `Enable-HardwareAcceleratedGPUScheduling.ps1` | Windows remediation | Tested | Medium | Break test (1 breaks) + UEM | `PASS - LAB` + `PASS - UEM` = Full Pass (break test run 61f9d608ba6d on 2026-11-02: HagsRegistryState (HwSchMode set to 1, script 1.0.2 set it back to 2 and exited 0); result `C:\Temp\FixReport\Enable-HardwareAcceleratedGPUScheduling\61f9d608ba6d.json`; UEM sweep `6c8405`) |
| 14 | `Restart-WindowsUpdateServices.ps1` | Windows remediation | Tested | Medium | Break test (4 breaks) + UEM | `PASS - LAB` + `PASS - UEM` = Full Pass (break test run 3cbd00c57db4 on 2026-11-02: BitsStopped and WuauservStopped (both services stopped, script restarted both); result `C:\Temp\FixReport\Restart-WindowsUpdateServices\3cbd00c57db4.json`; UEM sweep `6c8405`; rerun on 1.6.2.0 `25ed65fb8da0` 2026-11-05 10:55 Passed, WuauservStopped and CryptSvcStopped both repaired) |
| 15 | `Restart-WinProcess.ps1` | Windows remediation | Needs Testing | High | uem-tests.json (Chrome variables) | `TESTED - MANUAL` (fixed and verified 2026-10-29) + UEM `17a0a0` on one device; relaunch lands in session 0 |
| 16 | `Restart-WinProcessGraceful.ps1` | Windows remediation | Tested | High | uem-tests.json (Chrome variables) | `PASS - LAB` + `PASS - UEM` = Full Pass (break test 2026-11-02, runs `909a4e0e2236`, `bdd6b5d9ba62`, `fc7b3529f3ab`, all three breaks on 2.1.0; defects in 13.2.p fixed 2026-11-05 in 2.2.0: refused force-kill is Error not ClosedGracefully, expiring task, LastResult* mirror, Inaccessible outcome, windowed relaunch path, tolerant booleans; reruns on 2.2.0 `40a560a2b4d3` 13:25 (ProcessNotRunning) and `1ac93c400483` 13:35 (ProcessRunningRestart, pinned) both Passed, the trigger-started watchdog closed and relaunched Notepad) and `PASS - UEM` (one device, run `fb2f21`; watchdog closed and restarted Chrome) |
| 17 | `Restart-WinProcessGracefulEx.ps1` | Windows remediation | Needs Testing | Medium | UEM via `Test_JSpencerOnly` | `NEEDS TEST` (prototype); UEM run `6caa9a` (2026-11-02) ended `Failed (ScriptTimedOut 12007)` at the 30 s default: it waits the full graceful timeout inline, then force-kills and relaunches, and Chrome in the user session cannot be signalled from session 0. Prototype superseded by `Restart-WinProcessGraceful.ps1`, which dispatches the same work detached and passed; not for publication, no fix planned |
| 18 | `Restart-WinService.ps1` | Windows remediation | Tested | Medium | UEM entry (Spooler) | `PASS - LAB` (break test 2026-11-02, runs `795e25b09857`, `27398be0af27`, `2ab15d7c8d96`, all three breaks; defects in 13.2.n, fixed 2026-11-05 in 1.7.1.0 and rerun `f8724f5670f6` 10:55 Passed on SpoolerStopped) and `PASS - UEM` |
| 19 | `Invoke-AutoRemediateAppXBloat.ps1` | Windows logon | Tested | Medium | Break test (1 breaks) + UEM | `PASS - LAB` + `PASS - UEM` = Full Pass (break test run da4f55c3d6f8 on 2026-11-02 (file lost to the snapshot revert; rerun 40c964fd36f8 at 13:38 passed, file kept): InstalledDenyListedPackage (loose `DEXTest.BloatProbe` full-trust package registered under Developer Mode with `DenyListExtra=DEXTest.*`; script 1.0.0 removed it and exited 0, and as 13.3 predicted also removed ten inbox consumer packages for every user on the VM; the first attempt f3daf194e657 failed in the fixture because Windows will not register a framework package that way); result `C:\Temp\FixReport\Invoke-AutoRemediateAppXBloat\da4f55c3d6f8.json`; UEM sweep `6c8405` (2026-10-29) `Completed` on both devices) |
| 20 | `Invoke-AutoRemediateFSLogixExclusions.ps1` | Windows logon | Needs Testing | None | none | `NEEDS TEST - PRODUCT VM` (UEM: not-installed path ran, `6c8405`) |
| 21 | `Invoke-AutoRemediateLogonTaskContention.ps1` | Windows logon | Tested | Low | Break test (2 breaks) + UEM | `PASS - LAB` + `PASS - UEM` = Full Pass (break test run 43252617a969 on 2026-11-02 (file lost to the snapshot revert; rerun 0ed69496da08 at 12:58 passed, file kept): AtLogOnTriggerDelay (fixture task with no delay; script 1.0.0 gave it +60 s) and AtLogOnTaskVolume (3 fixtures took the host to 12 qualifying AtLogOn tasks against the warn threshold of 8; script reported Warning, wrote `QualifyingTaskCount = 12` and changed none of them, exit 0); result `C:\Temp\FixReport\Invoke-AutoRemediateLogonTaskContention\43252617a969.json`; the three earlier attempts were harness faults, see 13.5; UEM sweep `6c8405` (2026-10-29) `Completed` on both devices; rerun on 1.0.3 `f3dba3f5c473` 2026-11-05 11:29 Passed, AtLogOnTriggerDelay repaired and AtLogOnTaskVolume (12 against 8) reported and left alone, `QualifyingTaskCount = 12` matching the harness count) |
| 22 | `Invoke-AutoRemediateProfileBloat.ps1` | Windows logon | Tested | Low | Break test (9 breaks; 2 drawn) + UEM | `PASS - LAB` + `PASS - UEM` = Full Pass (break test run 2136e10ee79e on 2026-11-02 (file lost to the snapshot revert; rerun 711bbbadf409 at 12:57 passed with OversizedRoamingAppData reported and ShaderCaches cleared, file kept): ShaderCaches (aged RDP bitmap cache planted past the size threshold, cleared) and TeamsCache (aged classic Teams cache planted, cleared), fresh control files kept; script 1.0.0 exit 0; result `C:\Temp\FixReport\Invoke-AutoRemediateProfileBloat\2136e10ee79e.json`; three earlier attempts were fixture faults, see 13.5; the other seven breaks have not yet been drawn; UEM sweep `6c8405` (2026-10-29) `Completed` on both devices; 1.0.3 (2026-11-05, 13.2.j) budgets step 8 and escapes profile paths; rerun `e446f8bd2e99` 13:25 Passed on CrashDumps and UserTempFiles) |
| 23 | `Invoke-CrowdStrikeServiceRemediation.ps1` | Antivirus | Needs Testing | Medium | none | `NEEDS TEST - PRODUCT VM` (UEM: not-installed path ran, `6c8405`) |
| 24 | `Invoke-DefenderDynamicPerformance.ps1` | Antivirus | Tested | Low | Break test (2 breaks) + UEM | `PASS - LAB` + `PASS - UEM` = Full Pass (break test run acd1081436f9 on 2026-11-02: CpuProfileDrift and ScoreCacheCorrupt (load factor drifted to 5 with a stale marker, score cache set to a non-number; script recomputed the score and re-applied the profile); result `C:\Temp\FixReport\Invoke-DefenderDynamicPerformance\acd1081436f9.json`; UEM sweep `6c8405`; rerun on 1.2.0 `f5e48cac81fc` 2026-11-05 11:29 Passed, CpuProfileDrift (PriorityDriftMarkerRemoved) and ScoreCacheCorrupt (NonNumericScore) both repaired) |
| 25 | `Invoke-DefenderEnableCloudBlock_BAFS.ps1` | Antivirus | Tested | Low | none | `TESTED - MANUAL` + UEM `6c8405` |
| 26 | `Invoke-DefenderPauseScan.ps1` | Antivirus | Tested | Low | none | `TESTED - MANUAL` + UEM `6c8405` |
| 27 | `Invoke-DefenderServiceRemediation.ps1` | Antivirus | Tested | Low | none | `TESTED - MANUAL` + UEM `6c8405` |
| 28 | `Invoke-DefenderUpdateSignatures.ps1` | Antivirus | Tested | Low | none | `TESTED - MANUAL` + UEM `6c8405` |
| 29 | `Start-DefenderFullScan.ps1` | Antivirus | Needs Testing | Low | UEM via `Test_JSpencerOnly` | `PASS - UEM` (single-VM group, run `fad62d`, 2026-11-02, `Completed` 194 s after the sync; `Start-MpScan -AsJob` returns at once and the full scan then runs on the VM, revert the snapshot afterwards) |
| 30 | `Start-DefenderThreatReport.ps1` | Antivirus | Tested | Low | none | `TESTED - MANUAL` + UEM `6c8405` |
| 31 | `Invoke-TrellixCPUPriority.ps1` | Antivirus | Needs Testing | Low | none | `NEEDS TEST - PRODUCT VM` (UEM: not-installed path ran, `6c8405`) |
| 32 | `Invoke-TrellixLocalUpdate.ps1` | Antivirus | Needs Testing | Low | none | `NEEDS TEST - PRODUCT VM` (UEM: not-installed path ran, `6c8405`) |
| 33 | `Invoke-TrellixRefreshPolicies.ps1` | Antivirus | Needs Testing | Low | none | `NEEDS TEST - PRODUCT VM` (UEM: not-installed path ran, `6c8405`) |
| 34 | `Invoke-TrendMicroServiceRemediation.ps1` | Antivirus | Needs Testing | Medium | none | `NEEDS TEST - PRODUCT VM` (UEM: not-installed path ran, `6c8405`) |
| 35 | `Invoke-AutoRemediateChrome.ps1` | Application | Tested | Low | Break test (4 breaks) + UEM | `PASS - LAB` + `PASS - UEM` = Full Pass (break test run ea3f7e8bbf4f on 2026-11-02: CacheBloat (80 MB planted in Cache and Code Cache, cleared) and OrphanedNativeMessagingHost (WOW6432Node key pointing at a missing manifest, pruned); result `C:\Temp\FixReport\Invoke-AutoRemediateChrome\ea3f7e8bbf4f.json`; UEM sweep `6c8405`; rerun on 1.0.2 `03ba04fe011b` 2026-11-05 10:55 Passed, CrashLoop reported and OrphanedNativeMessagingHost (HKLM) pruned; 1.0.3 the same day fixes the latent install-fallback defect shared with Zoom (13.2.dd), which never fired here because Chrome's HKLM App Paths entry is read first, so the pass stands) |
| 36 | `Invoke-AutoRemediateOneDrive.ps1` | Application | Tested | Medium | Break test (5 breaks) + UEM | `PASS - LAB` + `PASS - UEM` = Full Pass (break test run 2dd3df491bfa on 2026-11-02: AutoStartAndProcess (OneDrive.exe stopped, script 1.0.2 relaunched it in the user session and exited 0) and KfmPolicyDrift (reported only, as designed); result `C:\Temp\FixReport\Invoke-AutoRemediateOneDrive\2dd3df491bfa.json`; UEM sweep `6c8405`) |
| 37 | `Invoke-AutoRemediateOutlook.ps1` | Application | Needs Testing | Medium | `ApplicationSpecific\Microsoft\Outlook\_AutomatedTesting\` | `PASS - LAB` on 1.1.0 (break test 2026-11-03 against classic Outlook on the lab VM, all seven breaks: `17d802490671`, `adb65d1d0cbb`, `7c1db1a7519c`, `590f40e38794`, `8eccf8929e22`, `c7c9e791ae0f`, `2d605de6719e`); `PASS - UEM` only for the not-installed path (`6c8405`). 1.1.1 (2026-11-03) bounds the step 3 event query after two slow lab runs (13.2.s); `PASS - LAB` re-confirmed on 1.1.1 at 10:25 (`223eb177b567`, `d8d1a083f0be`, `e823862823dd`: add-in fix, C2R Warning, deferred OST close; script runs 3.2 s, 2.7 s, 8.1 s and 5 s). `PASS - UEM` on the product path 2026-11-03 13:37 (run `64af6b`, Outlook open on `CBRADLEYSWIN11`): the Hub run wrote DEXRecords at 13:37:40 with 4 active steps, 3 Passed, 1 Warning, 0 Failed, so exit 0. Full Pass. The one Warning is a Hub-engine defect, 13.2.z: step 3's `Get-WinEvent` throws "Cannot marshal 'parameter #8'" under Hub's PowerShell 7.2.24 and the step degrades to "Unable to query Application event log", so every production run skipped the sync-backlog check until 1.1.2 (2026-11-05) rewrote the call on the .NET `EventLogReader`. 1.1.2 proven under Hub in run `4ea50e` (2026-11-05 11:46): step 3 returned a real Warning (2 Outlook error events in 7 days) where every earlier Hub run had "Unable to query". Full Pass on 1.1.2 |
| 38 | `Invoke-AutoRemediateTeams.ps1` | Application | Needs Testing | Medium | none | `NEEDS TEST - PRODUCT VM` (UEM: not-installed path ran, `6c8405`). New Teams is on `CBRADLEYSWIN11` since 2026-11-02; the first product-path run (`f7fcd1`, 2026-11-03 14:16) reported `Completed` on both devices but took the skipped path on this VM because 1.0.1 could not see a per-user MSIX from SYSTEM (13.2.aa, fixed in 1.0.2); rerun on 1.0.2 (`66f681`, 14:27) `Completed` on both devices and this time wrote DEXRecords on this VM: `TeamsVariant New (AppX)`, 2 active steps, 2 Passed, 0 Warning, 0 Failed. `PASS - UEM` on the product path. Break test written 2026-11-05 (one injectable break on a New-Teams-only host); 1.0.3 the same day fixes the step 6 gating (13.2.ee); `PASS - LAB` awaits the elevated run |
| 39 | `Invoke-AutoRemediateZoom.ps1` | Application | Needs Testing | Medium | break test being written (2026-11-05) | `NEEDS TEST - PRODUCT VM` until the break test runs (UEM: not-installed path ran, `6c8405`). Zoom 7.2.5 is on `CBRADLEYSWIN11` since 2026-11-05; 1.0.1 reported it as not installed (13.2.dd), fixed in 1.0.2, which ran all five steps on the VM |
| 40 | `Invoke-AutoRemediateBITSBacklog.ps1` | Application (SCCM) | Needs Testing | Low | `Invoke-SCCMLabRun.ps1` (baseline + `BitsDisabled`, `ForeignBitsJobKept`) | `NEEDS TEST - PRODUCT VM` (harness ready, awaiting external lab run) |
| 41 | `Invoke-AutoRemediateCcmCache.ps1` | Application (SCCM) | Needs Testing | Low | `Invoke-SCCMLabRun.ps1` (baseline only; purge path manual) | `NEEDS TEST - PRODUCT VM` (harness ready, awaiting external lab run) |
| 42 | `Invoke-AutoRemediateOrphanedCcmSetup.ps1` | Application (SCCM) | Needs Testing | Medium | `Invoke-SCCMLabRun.ps1` (baseline only; retry loop manual) | `NEEDS TEST - PRODUCT VM` (harness ready, awaiting external lab run) |
| 43 | `Invoke-AutoRemediateSCCMClient.ps1` | Application (SCCM) | Needs Testing | Medium | `Invoke-SCCMLabRun.ps1` (baseline + `CcmExecStopped`, `CcmExecManualStart`, `PolicyLogStale`) | `NEEDS TEST - PRODUCT VM` (harness ready, awaiting external lab run) |
| 44 | `Invoke-AutoRemediateWMIRepository.ps1` | Application (SCCM) | Needs Testing | High | `Invoke-SCCMLabRun.ps1` (baseline only; salvage path not simulated) | `NEEDS TEST - PRODUCT VM` (harness ready, awaiting external lab run) |
| 45 | `Invoke-AutoRemediateSCOMAgent.ps1` | Application (SCOM) | Needs Testing | Medium | none | `DEFERRED` (SCOM approach under review since 2026-10-30; was Reference only (48,336 chars, over the UEM limit)) |
| 46 | `Invoke-AutoRemediateSCOMAgentPart1.ps1` | Application (SCOM) | Needs Testing | Medium | none | `DEFERRED` (SCOM approach under review since 2026-10-30; was `NEEDS TEST - PRODUCT VM` (UEM: not-installed path ran, `6c8405`)) |
| 47 | `Invoke-AutoRemediateSCOMAgentPart2.ps1` | Application (SCOM) | Needs Testing | Low | none | `DEFERRED` (SCOM approach under review since 2026-10-30; was `NEEDS TEST - PRODUCT VM` (UEM: not-installed path ran, `6c8405`)) |
| 48 | `Invoke-AutoRemediateSCOMAgentPart3.ps1` | Application (SCOM) | Needs Testing | Low | none | `DEFERRED` (SCOM approach under review since 2026-10-30; was `NEEDS TEST - PRODUCT VM` (UEM: not-installed path ran, `6c8405`)) |
| 49 | `Invoke-AutoRemediateSCOMClonedIdentity.ps1` | Application (SCOM) | Needs Testing | High | UEM skip | `DEFERRED` (SCOM approach under review since 2026-10-30; was `NEEDS TEST - PRODUCT VM` (fixed 2026-10-29)) |
| 50 | `Invoke-AutoRemediateSCOMHealthServiceCache.ps1` | Application (SCOM) | Needs Testing | High | UEM skip | `DEFERRED` (SCOM approach under review since 2026-10-30; was `NEEDS TEST - PRODUCT VM` (fixed 2026-10-29)) |
| 51 | `Invoke-AutoRemediateSCOMMonitoringHost.ps1` | Application (SCOM) | Needs Testing | Medium | none | `DEFERRED` (SCOM approach under review since 2026-10-30; was `NEEDS TEST - PRODUCT VM` (UEM `6c8405`: `UnknownScriptError`; four launcher defects fixed in 1.0.2; final re-run 2026-10-30 ran the payload to `Skipped:NoAgent` on the lab VM)) |
| 52 | `Start-ClearRecycleBin.ps1` | Disk cleanup | Tested | Low | none | `TESTED - MANUAL` + UEM `6c8405` |
| 53 | `Start-DiskCleanup.ps1` | Disk cleanup | Tested | Low | none | `TESTED - MANUAL` (UEM `6c8405`: `ScriptTimedOut` on one device; fixed in 1.2.1, `Completed` on both in re-run `0501f4`) |
| 54 | `Start-UserProfileCleanup.ps1` | Disk cleanup | Tested | High | Break test (3 breaks) + UEM | `PASS - LAB` + `PASS - UEM` = Full Pass (break test runs 28180d46896e and 7027f9afc870 on 2026-11-02 (both files lost to the snapshot revert; rerun 1b0af182287a at 12:58 deleted DEXTestProfile and kept the enrollment fixture, file kept): StaleOversizedProfile (`DEXTestProfile`, 98.71 MB and idle 60 days against the scratch copy's 0-day, 32 MB thresholds, deleted in both runs), EnrollmentUserProfileKept (first run) and UnderThresholdProfileKept (`DEXTestKeep`, 2.71 MB, second run), both examined and left in place; the delete path that was manual is now exercised by the harness; results `C:\Temp\FixReport\Start-UserProfileCleanup\28180d46896e.json` and `7027f9afc870.json`; UEM run `bbf07f` (2026-10-30, single-VM group `Test_JSpencerOnly`) `Completed` on `CHASEWIN11_2`; rerun on 1.1.0 `a83bab70487a` 2026-11-05 10:55 Passed, StaleOversizedProfile deleted and EnrollmentUserProfileKept left alone through the new SID-based filter) |
| 55 | `Get-AppVolumesMountProbe.ps1` | Generic troubleshooting | Needs Testing | Low | none | `NEEDS TEST - PRODUCT VM` |
| 56 | `Enable-LogonAuditLogs.ps1` | Generic troubleshooting | Tested | Low | none | `TESTED - MANUAL` + UEM `6c8405` |
| 57 | `Measure-LogonDuration.ps1` | Generic troubleshooting | Tested | Low | none | `TESTED - MANUAL` + UEM `6c8405` |
| 58 | `Measure-LogonDurationMultiSession.ps1` | Generic troubleshooting | Tested | Low | Manual SYSTEM run through `AutomatedTesting\Start-SystemRun.ps1` (UEM skip: 87,435 chars, over the 32,767 limit) | `TESTED - MANUAL` (2026-11-02 12:34, lab VM `CBRADLEYSWIN11`, run as SYSTEM through a one-shot task with `-DeployMode RunNow`, collector 2.0.1, exit 0: nine event sources resolved (FSLogix `ProviderMissing`, expected on a VM without FSLogix), one console session measured at 3.18 s total logon, and all three registry keys written and read back, `LogonDuration`, `Sessions\<SID>` and `Aggregate`; log `C:\Temp\FixReport\SystemRun\Measure-LogonDurationMultiSession-20261102-123455.log`, copied to the evidence bundle). This is the highest status the script can reach: it cannot be published to UEM as a single script |
| 59 | `DEX_Invoke-SignoffWindows.ps1` | MDM commands | Tested | High | UEM via `Test_JSpencerOnly` | `PASS - UEM` (single-VM group, run `80650c`, 2026-10-30) |
| 60 | `DEX_LockDevice-BitlockEncryptionActivated.ps1` | MDM commands | Needs Testing | Critical | UEM via `Test_JSpencerOnly` | `PASS - UEM` for the positive path on v1.3.0 (single-VM group, run `1b5fcb`, 2026-10-30, BitLocker enabled on the VM first): Hub reported `Completed` 13 s after the sync and the device's System log holds event 1074 at 13:45:30 from `shutdown.exe` as SYSTEM carrying the script's own comment, with no 1075 abort; `manage-bde` showed `Protection On` afterwards, which is the default resume after one restart. Earlier the same day: run `c8e0dd` on v1.1.0 shut the unencrypted VM down instead of exiting 1 (guard rewritten around `Get-BitLockerVolume` in v1.2.0), and run `534500` on v1.2.0 could only show no result because the in-process `/t 0` killed the host before Hub reported (power-off deferred 15 s in v1.3.0). Negative path proven 2026-11-04 on v1.3.0 (run `389aa4`, created 2026-11-03 17:38 against the single-VM group after the user decrypted `CHASEWIN11_2` with `manage-bde -off`; the VM was off overnight and ran it at 08:26 on power-up): UEM status `Failed` with `ScriptNonSuccessReturnCode` (12011), reported 08:31, and the device kept checking in afterwards (08:32), so an unprotected device gets exit 1 and no shutdown. Both paths proven, so the script is Tested under the action-script rule. BitLocker was re-enabled on `CHASEWIN11_2` on 2026-11-04 about 13:30 (`Enable-BitLocker -PasswordProtector -UsedSpaceOnly -SkipHardwareTest` plus a recovery password, after `manage-bde -on` had failed twice: once on a connected virtual DVD, once with 0x8007000d on stale protector metadata, and the interactive `-pw` prompt hung in the terminal); `manage-bde -status` then showed Used Space Only Encrypted, 100 %, XTS-AES 128, Protection On, Password and Numerical Password protectors. The connector itself hung on the status poll for fifteen hours and died on `HTTP 999`; the status was read back by hand (`workflow-status-389aa4.txt` in the bundle) |
| 61 | `DEX_Start-LockDeviceSoft.ps1` | MDM commands | Tested | Low | UEM via `Test_JSpencerOnly` | `PASS - UEM` (single-VM group, run `496916`, 2026-10-30; console dropped to the lock screen, user signed back in) |
| 62 | `DEX_Stop-WindowsUpdate.ps1` | MDM commands | Needs Testing | Medium | UEM via `Test_JSpencerOnly` | `PASS - UEM` (single-VM group, run `8a63e2`, 2026-11-02, `Completed` 206 s after the sync; leaves a 35-day pause on the VM, revert the snapshot afterwards) |
| 63 | `DEX_Start-WindowsUpdate.ps1` | MDM commands | Needs Testing | Medium | UEM via `Test_JSpencerOnly` | `PASS - UEM` (single-VM group, run `48bf63`, 2026-11-02, `Completed` 417 s after the sync, run after the Stop script on the same VM; may leave it pending a restart, revert the snapshot afterwards) |
| 64 | `Invoke-AutoRemediateGenericVPN.ps1` | VPN | Needs Testing | Medium | `VPN\_AutomatedTesting\` | `PASS - LAB` (break test 2026-11-02 against the lab WireGuard tunnel: `a902d1fdde65`, `8149d16fe088`, `a53fc74b8558`, `348f1ade7322`, `eebc79b8d26b`, all five breaks); `PASS - UEM` only for the not-installed path (`6c8405`; the 2026-11-03 00:04 run `a45cd1` added nothing: `CBRADLEYSWIN11` reported Completed in 9 s but its tunnel service had stopped at some point after 19:52, so it took the no-client path again, and `CHASEWIN11_2` gave no result in 5 min). `PASS - UEM` on the product path 2026-11-03 13:05 (run `e0025c`, both tunnels up): the connector read `NoResult` on both devices within 5 min, but on `CBRADLEYSWIN11` the device log shows the SYSTEM run against the live tunnel (candidates 1, WireGuard Tunnel, all five steps Passed, MTU 1420, DNS 10.99.0.2, 0 remediations) and Hub's Workflow log audited the step as completed at 13:06:12. Full Pass; defects in 13.2.r |
| 65 | `Invoke-VpnStateCollection.ps1` | VPN | Needs Testing | Low | none | Now 1.1.2 (self-refreshing cache, section 10.2): `PASS - LAB` on 1.1.2 (gate test 2026-11-03 10:28, every assertion) and `PASS - UEM` on 1.1.2 (collector run `fb88b1` 10:28, `Completed` on both devices by the device log; sweep `4514e3` 11:53 proved one quiet rerun per state change with the hash intact), so Full Pass on 1.1.2. UEM parts one to three the same morning found the `Get-FileHash` defect 13.2.t (fixed 1.1.1) and the parallel-sensor race 13.2.u (fixed 1.1.2), both closed. The earlier passes below are on 1.0.1. `PASS - LAB` on 1.0.1 (break test 2026-11-02, runs `e73c23ecf1ac`, `f26937f84576`, `01c6dadd22f9`, `b91e95203a31`, all four breaks against a live WireGuard tunnel) and `PASS - UEM` on 1.0.1 (run `709d52`, 2026-11-02 15:24, `Completed` on both lab VMs; on `CBRADLEYSWIN11` the SYSTEM run wrote the connected row for the live WireGuard tunnel: score 100 Healthy, Connected 1, Split, MTU 1420, DNS 1, ClientCount 1. The earlier 1.0.0 pass in `6c8405` covered only the no-client path; 1.0.0 crashed on any device with a tunnel, 13.2.q). Other defects in 13.2.o |
| 66 | `Invoke-RebootWithUserDefer.ps1` | Reboot | Tested | High | UEM via `Test_JSpencerOnly` | `PASS - UEM` for the install (single-VM group, run `ea5217`, 2026-10-30; repeated 2026-11-03 14:11 as `4891ec`, `Completed` on `CHASEWIN11_2`, with a user signed in so the toast could be watched, and no toast was seen); the 2026-11-04 read-back of the device found the 2026-10-30 campaign state still in the registry, no log and a July orchestrator task that never fires, see 13.2.bb: on 1.2.0.7 both runs proved only the installer's exit 0, since the orchestrator never ran. Fixed in 1.2.0.8 (2026-11-04). Its first UEM run `6e05a8` (10:44) ended `NoResult` after the manifest's 5 min with the status endpoint answering 204 afterwards, so the item was deleted before Hub on `CHASEWIN11_2` reported; the window was raised to 8 min and the run repeated as `696abb` (12:41, after this VM had been rebooted twice: once for Hub, once for two more cores), `Completed` on `CHASEWIN11_2` 67 s after the sync (reported 17:43:21Z), so 1.2.0.8 installs under Hub, and the device's `RebootPrompt.log` shows the orchestrator polling every 5 min and launching the toast task for the signed-in user at 12:53:39, and the user found the prompt in the notification centre (13.2.bb); "Not now" only dismisses and the state key is nested under the host name (13.2.cc, low); the user then reported the prompt sliding away after a few seconds, so 1.2.0.9 (2026-11-04, 22,673 chars) gives the toast `scenario="reminder"`, which keeps it on screen until a button is pressed, and was pushed to the device as run `20c830` (13:31, `Completed` 200 s after the sync; helper files are rewritten on every install, the live campaign is kept); the user confirmed at about 13:55 that the persistent prompt shows and stays, so the install, the orchestrator, the cadence and the prompt are all observed on the device; the forced reboot at the 16:43 deadline and the post-reboot cleanup are the remaining manual steps. 1.2.1.0 (2026-11-04, 26,311 chars) adds `TestMode` at the user's suggestion (admin value or UEM script variable `TestMode=true`): the install starts a clean campaign, the orchestrator polls every minute and passes `-Force` so the helper prompts on every poll, nothing reboots, either button writes `ButtonPressed` to the user's hive through the protocol handler, and the next poll logs "TEST MODE: '<button>' pressed" and removes the task, the campaign key, the marker and the helpers; lets the prompt be validated on the harness VM itself. First TestMode run on `CBRADLEYSWIN11` 2026-11-04 14:23 (elevated, `$env:TestMode='true'`): campaign 14:23:45, poll 14:24:02, toast launched 14:24:13, the user pressed "Not now", and the 14:25:03 poll logged "TEST MODE: 'NotNow' pressed by chase; no reboot ... Test complete." with the orchestrator task, the campaign key, the marker and both helper files gone 18 s later; the log file stays as the record. One `RebootPrompt-Toast-<guid>` task was still registered afterwards, but its trigger and last run were from July 2026: a relic of the earlier release on this VM, not today's toast (which was unregistered 10 s after launch as designed). 1.2.1.1 (2026-11-04) sweeps `RebootPrompt-Toast-*` in every cleanup path. Second TestMode run on 1.2.1.2, 2026-11-05 10:44 (`CBRADLEYSWIN11`, elevated): campaign 10:44:14, toast launched 10:44:42, the user pressed "Reboot now", the marker read `RebootNow`, the helper's state sat directly under `AdvancedReboot\chase` (the 1.2.1.2 key shape), and the 10:45:33 poll logged "TEST MODE: 'RebootNow' pressed by chase; no reboot ... Test complete." and left nothing but the log: no task under `\WorkspaceOneEx\` (the July relic was swept by the install), no campaign key, no marker, no helper files. Both buttons, the cadence, the cleanup and the state-key fix are now observed; only the UEM script-variable form of TestMode is unexercised |
| 67 | `Invoke-SimpleReboot.ps1` | Reboot | Tested | High | UEM via `Test_JSpencerOnly` | `PASS - UEM` (single-VM group, run `f3996a`, 2026-10-30; device rebooted and came back). 1.0.1 defers the no-user reboot by 10 s, parse-checked, that branch not re-run |
| 68 | `SmartReboot.ps1` | Reboot | Tested | Low | none | `TESTED - MANUAL` |
| 69 | `Invoke-AutoRemediateTimeSync.ps1` | System health | Needs Testing | Low | `WindowsAutoRemediation\SystemHealth\_AutomatedTesting\` | `PASS - LAB` on 1.0.1 (break test `017c7d370050`, 2026-11-03 13:25: W32TimeService fixed, WorkgroupNoPeer reported only). Live elevated run 2026-11-04 09:02 resynced a clock the harness had left on `Local CMOS Clock` for the night (offset 0.017 s after). `PASS - UEM` run `ffaad1` (2026-11-04 12:43, Completed on both VMs; on `CBRADLEYSWIN11` it resynced the clock under Hub, `Step03 = [Remediated]`). Full Pass |
| 70 | `Invoke-AutoRemediateBitLockerProtection.ps1` | System health | Needs Testing | Medium | none (needs an encrypted, suspended volume) | `NEEDS TEST`; only the no-encrypted-volume path has run (live, elevated, 2026-11-03 13:28: "No BitLocker-encrypted volumes found", exit 0). `PASS - UEM` runs `e76ada` and `ffaad1` (2026-11-04): Completed on `CHASEWIN11_2`, which has an encrypted C: (product path), and on `CBRADLEYSWIN11` (no-volume path). No break test, so not Full Pass |
| 71 | `Invoke-AutoRemediateCertEnrollment.ps1` | System health | Needs Testing | Low | `WindowsAutoRemediation\SystemHealth\_AutomatedTesting\` | `PASS - LAB` on 1.0.1 (break test `2df122ace6f8`, 2026-11-03 13:28: WeakAlgorithmCertificate and ExpiredCertificate reported only, left in place, removed by restore). AutoenrollmentTask (fixed) drawn and repaired in `e1cfd894147c` (2026-11-04 10:13). `PASS - UEM` run `ffaad1` (2026-11-04 12:43, Completed on both VMs, 5 Passed on `CBRADLEYSWIN11` with the COM task path under PowerShell 7 as SYSTEM). Full Pass |
| 72 | `Invoke-AutoRemediateWord.ps1` | Application (Office) | Needs Testing | Medium | `ApplicationSpecific\Microsoft\Word\_AutomatedTesting\` (12 breaks) | Office 365 C2R 16.0.18925 is on `CBRADLEYSWIN11`; live non-elevated run 2026-11-05 ran all 9 steps (8 Passed, C2R update Warning by policy). 1.0.2 (2026-11-05) closes the step 3 gate bypass (13.2.ee). Break test written 2026-11-05, elevated run pending. 34,459 characters since the 1.0.1 EventLogReader rewrite, over the 32,767 pre-2607 limit (runbook rule 15): UEM publish needs a split or the limit waived; the lab run is unaffected |
| 73 | `Invoke-AutoRemediateExcel.ps1` | Application (Office) | Needs Testing | Medium | `ApplicationSpecific\Microsoft\Excel\_AutomatedTesting\` (10 breaks) | Live run 2026-11-05: 7 steps Passed. 1.0.2 closes the gate bypass in steps 3 and 6 (13.2.ee). Break test written, elevated run pending. 36,446 characters, over the 32,767 limit since 1.0.1 |
| 74 | `Invoke-AutoRemediatePowerPoint.ps1` | Application (Office) | Needs Testing | Medium | `ApplicationSpecific\Microsoft\PowerPoint\_AutomatedTesting\` (11 breaks) | Live run 2026-11-05: a real `igd10iumd64.dll` crash in the 7-day window makes steps 1 and 5 Warn (graphics acceleration fix gated); the harness rides on that crash for its GraphicsAccel breaks until about 2026-11-10. 1.0.2 closes the gate bypass. Break test written, elevated run pending. 33,628 characters, over the 32,767 limit since 1.0.1 |
| 75 | `Invoke-AutoRemediateAccess.ps1` | Application (Office) | Needs Testing | Low | `ApplicationSpecific\Microsoft\Access\_AutomatedTesting\` (7 breaks, one conditional on a real MSACCESS crash, present on the VM as of 2026-11-05) | Live run 2026-11-05 clean. 1.0.2 closes the gate bypass. Break test written, elevated run pending. 28,837 characters |
| 76 | `Invoke-AutoRemediateOneNote.ps1` | Application (Office) | Needs Testing | Medium | `ApplicationSpecific\Microsoft\OneNote\_AutomatedTesting\` (7 breaks) | Live run 2026-11-05 clean. 1.0.2 closes the gate bypass. Break test written (the cache rename break needs OneNote closed), elevated run pending. 28,721 characters |
| 77 | `Invoke-AutoRemediatePublisher.ps1` | Application (Office) | Needs Testing | Low | `ApplicationSpecific\Microsoft\Publisher\_AutomatedTesting\` (6 breaks) | Live run 2026-11-05: 4 steps Passed. 1.0.2 closes the gate bypass. Break test written, elevated run pending. 29,023 characters. Step 7 (Office Document Cache) is disabled in this script, so the suggested cache break is not injectable |

Counts after the 2026-10-29 fixes, the UEM sweeps, the 2026-10-30 SCOM deferral, the single-VM group runs and the 2026-11-02 afternoon break tests: 25 `PASS - LAB` (every one of them also `PASS - UEM`, so 25 Full Pass as of 2026-11-03, counting `Invoke-AutoRemediateWiFiSignalIssues.ps1` 2.0.2 by the user's decision on the strength of their own Wi-Fi testing; `Restart-WinService.ps1`, `Restart-WinProcessGraceful.ps1` and `Invoke-VpnStateCollection.ps1` joined on the afternoon of 2026-11-02, `Invoke-AutoRemediateGenericVPN.ps1` and `Invoke-AutoRemediateOutlook.ps1` on 2026-11-03 with both tunnels up and classic Outlook open; the collector is now Full Pass at 1.1.2), 7 `PASS - UEM` (`Invoke-AutoRemediateTeams.ps1` joined on 2026-11-03 once 1.0.2 could see New Teams from SYSTEM), 13 `TESTED - MANUAL`, 0 `FIX FIRST` (the four defects found by the 2026-11-02 break-test reviews, 13.2 a to d, were fixed the same day), 0 `MANUAL ONLY`, 7 `DEFERRED`, 0 reference-only copy, 17 `NEEDS TEST - PRODUCT VM`, 1 `NEEDS TEST` (`Restart-WinProcessGracefulEx.ps1`, a superseded prototype whose UEM run timed out; `Measure-LogonDurationMultiSession.ps1` moved to `TESTED - MANUAL` on 2026-11-02 after its SYSTEM run) (plus the SYSTEM path of `Disable-NonEssentialStartupApps.ps1`). The 8 scripts that had no inventory row were added to the CSV on 2026-11-02 as `3) Complete - Needs Testing`, and every Full Pass script is promoted to `4) Complete - Tested` under the Full Pass rule in 1.1 (25 so far; 41 script rows and 32 sensor rows carry that status as of 2026-11-05, the two folder-redirection sensors having returned once sweep `25a553` stored their values, the BitLocker lock script having joined under the action-script rule once its negative path ran, after the sensor reconciliation at the end of 13.2 promoted ten and demoted five). `Restart-WinProcessSoft.ps1` (0 bytes) is excluded from the count. The three `SystemHealth` scripts added on 2026-11-03 (rows 69 to 71) are not in these counts: on 2026-11-04 `Invoke-AutoRemediateTimeSync.ps1` and `Invoke-AutoRemediateCertEnrollment.ps1` became Full Pass (break tests plus UEM run `ffaad1`) and moved to `4) Complete - Tested`; `Invoke-AutoRemediateBitLockerProtection.ps1` is `PASS - UEM` on both paths but has no break test and stays at `3) Complete - Needs Testing`.

---

## 3. Device and driver scripts (break-test covered)

All six scripts in this group are exercised by `Invoke-DriverDeviceLabRun.ps1`. The orchestrator runs the Pester unit tests, the stubbed harness dry run, then every applicable break test, then the analyser. Each break test: captures original state, applies a fault, verifies the fault landed, runs the script under test, validates the component is repaired, restores anything the script did not fix, and writes `C:\Temp\FixReport\<Script>\<TestId>.json`.

Lab evidence used below is from the runs at 14:53 and 14:56 on 2026-10-28 (`LabRun_20261028_145310`, `LabRun_20261028_145616`). Earlier runs the same day (13:25 to 14:33) found and fixed harness and script defects; those are logged in `WindowsAutoRemediation\_AutomatedTesting\LAB-RUN-DriverAndDevice.md`.

### 3.1 `Invoke-AutoRemediateAllDriverIssues.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\Invoke-AutoRemediateAllDriverIssues.ps1`, v3.0.1 |
| Inventory | `3) Complete - Needs Testing`, impact Critical |
| Inputs | `-DriverFilter` / `$env:DriverFilter` (substring match on device or driver name, empty = all), `-AllowedActions` (subset of Scan, Restart, Rollback, Reinstall, Uninstall; default Scan, Restart, Rollback) |
| Prerequisites | Any PnP device that can be disabled. On the VM the EHCI USB controller is used |
| Automated coverage | `_AutomatedTesting\Invoke-AutoRemediateAllDriverIssues_BreakTest.ps1` (breaks `UsbDriverDisabled`, `DriverPackageDeleted`); `Unit\Invoke-AutoRemediateAllDriverIssues.Tests.ps1` (21 tests); `uem-tests.json` entry with `DriverFilter = ""` |

**Purpose.** Step engine over nine device classes (Audio, Bluetooth, Network Adapter, GPU/Display, Storage Controller, Chipset/SMBus, Touchpad/HID, Webcam/Camera, USB/Dock) plus Driver Store Scan, Uncovered Device Errors and Pending Driver Reboot. For every device with a non-zero `ConfigManagerErrorCode` it escalates through the allowed actions (`pnputil /scan-devices`, `/restart-device`, `/rollback-driver`, `/remove-device` + rescan, `/remove-device`) until the error clears.

**Test steps**

1. Precondition: elevated PS 5.1 console on the lab VM, snapshot taken, `C:\Temp\FixReport\.dex-test-machine` present, no pending reboot (`Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'` is false).
2. Non-destructive first:
   ```powershell
   .\WindowsAutoRemediation\_AutomatedTesting\Unit\Invoke-DriverUnitTests.ps1
   ```
   Expect `Passed: 30 Failed: 0`. Covers classification, escalation order, filter handling, argument forwarding, summary counts, exit codes.
3. Break and fix (single break, default escalation):
   ```powershell
   .\WindowsAutoRemediation\_AutomatedTesting\Invoke-AutoRemediateAllDriverIssues_BreakTest.ps1 -BreakName UsbDriverDisabled -RemediationTest -Environment Physical -Force
   ```
   The harness disables the EHCI USB controller (`Disable-PnpDevice`), confirms `ConfigManagerErrorCode = 22`, runs the script, expects the USB/Dock Driver Health step to report `-> Remediation ran` and the device to return to error code 0.
4. Boundary probe (proves a false pass cannot hide): same command with `-AllowedActions Scan`. The script must exit `2` and the harness must report `Overall = Failed`. This is the expected result and is what `Invoke-DriverDeviceLabRun.ps1` checks in its `AllDriverIssues-BoundaryProbe` step.
5. Optional, destructive to the driver store: `-BreakName DriverPackageDeleted -RemediationTest -Force` (or `-IncludeDriverPackageBreak` on the orchestrator). Deletes the OEM driver package for the test device; needs `Reinstall` in `-AllowedActions`.
6. Direct run, as UEM would:
   ```powershell
   $env:DriverFilter = ''
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WindowsAutoRemediation\Invoke-AutoRemediateAllDriverIssues.ps1; $LASTEXITCODE
   ```
   Expect every class to print `[Passed ]`, `Passed: n | Warnings: n | Failed: 0 | Remediations run: 0`, exit `0`.
7. Verify: `Get-PnpDevice -Status Error` returns nothing; `Get-ItemProperty 'HKLM:\Software\AirWatch\Extension\DEXRecords\DriverIssues'` (or the name printed in the `[Registry]` line) shows the latest counts.
8. Restore: the harness re-enables the device itself. If a run was interrupted, `.\Invoke-AutoRemediateAllDriverIssues_BreakTest.ps1 -Restore -Force`.

**Status:** `PASS - LAB`. Evidence: `C:\Temp\FixReport\Invoke-AutoRemediateAllDriverIssues\250c0e222440.json` (Passed, UsbDriverDisabled, 2026-10-28 14:57) and `172ec542622b.json` (boundary probe, Failed as expected). Five passing runs and four expected-failure probes recorded in `Summary.csv` across the day. Unit tests 21/21. Also `Completed` on both lab devices in UEM sweep `6c8405` (2026-10-29).

**Review notes.** Fixed today: `Test-DriverMatch` not visible to step scriptblocks under UEM (GetNewClosure module scope); single-object `.Count` returning null in PS 5.1; `Select-String` count for Published Name. Inventory status should move to `4) Complete - Tested`.

### 3.2 `Invoke-AutoRemediateDriverIssues.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\Invoke-AutoRemediateDriverIssues.ps1`, v3.0.1 |
| Inventory | `3) Complete - Needs Testing`, impact Critical |
| Inputs | `-DriverFilter` / `$env:DriverFilter`, `-AllowedActions` (same set as 3.1) |
| Prerequisites | As 3.1 |
| Automated coverage | `Invoke-AutoRemediateDriverIssues_BreakTest.ps1` (`UsbDriverDisabled`, `DriverPackageDeleted`); `Unit\Invoke-AutoRemediateDriverIssues.Tests.ps1` (9 tests); `uem-tests.json` entry with `DriverFilter = "VMware"` |

**Purpose.** Single-pass variant of 3.1 without the class table. Enumerates `Win32_PnPEntity` with a non-zero error code, filters by `DriverFilter`, escalates through the allowed actions, prints matched/errored/fixed/unfixed counts. Exit `0` clean, `2` unfixed devices remain.

**Test steps**

1. Precondition as 3.1 step 1.
2. Unit tests as 3.1 step 2 (the same runner covers both scripts).
3. Break and fix:
   ```powershell
   .\WindowsAutoRemediation\_AutomatedTesting\Invoke-AutoRemediateDriverIssues_BreakTest.ps1 -BreakName UsbDriverDisabled -RemediationTest -Environment Physical -Force
   ```
   Harness passes `-DriverFilter` matching the disabled controller and `-AllowedActions Scan,Restart,Rollback`. Expect the controller re-enabled and `Overall = Passed`.
4. Filter negative test: run the script directly with `$env:DriverFilter = 'NoSuchDevice'` while a device is disabled by hand (`Disable-PnpDevice -InstanceId <id> -Confirm:$false`). Expect `matched: 0`, exit `0`, and the device still disabled. Re-enable with `Enable-PnpDevice`.
5. Direct run with the UEM manifest values:
   ```powershell
   $env:DriverFilter = 'VMware'
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WindowsAutoRemediation\Invoke-AutoRemediateDriverIssues.ps1; $LASTEXITCODE
   ```
   Expect a device list, `errored: 0`, exit `0`.
6. Verify and restore as 3.1 steps 7 and 8.

**Status:** `PASS - LAB`. Evidence: `C:\Temp\FixReport\Invoke-AutoRemediateDriverIssues\ac4fd4a9f531.json` (Passed, 14:57). Four passing runs today, zero failures. Unit tests 9/9. Also `Completed` on both lab devices in UEM sweep `6c8405` (2026-10-29).

**Review notes.** Fixed today: `@($matched).Count` and `@($errored).Count` guards; entry point forwards named arguments. Inventory status should move to `4) Complete - Tested`.

### 3.3 `Invoke-AutoRemediateAudioBluetooth.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\Invoke-AutoRemediateAudioBluetooth.ps1`, v1.0.2 |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | none |
| Prerequisites | An audio endpoint device (VMware virtual audio is enough), `Audiosrv`, `AudioEndpointBuilder`, `bthserv` services |
| Automated coverage | `Invoke-AutoRemediateAudioBluetooth_BreakTest.ps1`, breaks `AudioServicesStopped`, `AudioDriverDisabled`, `VolumeMuted`, `MicrophoneAccessDenied`, `BluetoothServiceStopped` |

**Purpose.** Eight steps: Audio Services, Audio Driver Health, Default Audio Output Device, Volume & Mute State, Microphone Access Policy, Bluetooth Service, Bluetooth Device Pairing, Bluetooth Audio Profile. Five have resolutions (start services, enable or restart the audio device, raise master volume via `waveOutSetVolume`, set the microphone consent store to Allow, start `bthserv`). The last three are report-only because they need user interaction.

**Test steps**

1. Precondition as 3.1 step 1. Note the baseline: `Get-Service Audiosrv,AudioEndpointBuilder,bthserv | Select Name,Status,StartType` and `(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone').Value`.
2. All five breaks at once:
   ```powershell
   .\WindowsAutoRemediation\_AutomatedTesting\Invoke-AutoRemediateAudioBluetooth_BreakTest.ps1 -BreakCount 5 -RemediationTest -Environment Physical -Force
   ```
   Harness stops both audio services, disables the audio PnP device (error 22), sets waveOut master volume to 0, writes `Deny` to the microphone consent store, stops `bthserv`.
3. Expect in the script output: `Audio Services ... -> Remediation ran`, `Audio Driver Health ... -> Remediation ran`, `Volume & Mute State ... -> Remediation ran`, `Microphone Access Policy ... -> Remediation ran`, `Bluetooth Service ... -> Remediation ran`, final `Failed: 0`, exit `0`. Harness `Validated = 5`, `Overall = Passed`.
4. Single break replay for triage: `-BreakName VolumeMuted` or `-BreakName AudioDriverDisabled` with `-RemediationTest -Force`.
5. Direct run:
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WindowsAutoRemediation\Invoke-AutoRemediateAudioBluetooth.ps1; $LASTEXITCODE
   ```
   On this VM expect `Volume & Mute State` to pass (master volume is read back after the fix as 0x7FFF), Bluetooth Device Pairing and Bluetooth Audio Profile to report `[Warning]` (no Bluetooth radio), exit `0`.
6. Verify: services Running, `Get-PnpDevice -Class MEDIA -Status Error` empty, consent store `Allow`.
7. Restore: harness restores volume and consent to captured values. Manual fallback: `Start-Service Audiosrv,AudioEndpointBuilder,bthserv`, `Enable-PnpDevice` on the audio device, `Set-ItemProperty ...\ConsentStore\microphone -Name Value -Value Allow`.

**Status:** `PASS - LAB`. Evidence: `C:\Temp\FixReport\Invoke-AutoRemediateAudioBluetooth\972720efc3e4.json` (Passed, 5/5 breaks validated, 14:58) and `782c100fb879.json` (Passed, 14:55). The two 14:29 and 14:32 runs validated only 3 of 5; the v1.0.2 changes below fixed the remaining two. Also `Completed` on both lab devices in UEM sweep `6c8405` (2026-10-29).

**Review notes.** v1.0.2 changes made today: Audio Driver Health now calls `pnputil /enable-device` when the device reports error 22 (disabled) instead of `/restart-device`, which cannot clear a disabled device. Volume resolution now calls `winmm.dll waveOutSetVolume` with 0x7FFF7FFF instead of SendKeys volume-up, which has no effect in a SYSTEM session. Inventory status should move to `4) Complete - Tested`.

### 3.4 `Invoke-AutoRemediateNetworkStack.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\Invoke-AutoRemediateNetworkStack.ps1`, v1.0.1 |
| Inventory | `3) Complete - Needs Testing`, impact High |
| Inputs | `$env:WhatIf` honoured (`true` logs intended changes only) |
| Prerequisites | One DHCP-addressed adapter with a default gateway, Windows Firewall service |
| Automated coverage | `Invoke-AutoRemediateNetworkStack_BreakTest.ps1`, breaks `DhcpLeaseLoss` (`ipconfig /release`), `FirewallDisabled` (all three profiles off). `uem-tests.json` skip: adapter reset and Winsock reset can sever the Hub session |

**Purpose.** Seven steps: DNS Resolution, Default Gateway, Network Adapters, Winsock / IP Stack, Adapter Bounce, Firewall Status, Internet Connectivity. Resolutions flush and re-register DNS, renew DHCP, enable disabled adapters, `netsh winsock reset`, disable/enable the adapter, re-enable firewall profiles.

**Test steps**

1. Precondition as 3.1 step 1. Run from the VM console, not over RDP: the DHCP release will drop a remote session for several seconds.
2. Both safe breaks:
   ```powershell
   .\WindowsAutoRemediation\_AutomatedTesting\Invoke-AutoRemediateNetworkStack_BreakTest.ps1 -BreakCount 2 -RemediationTest -Environment Physical -Force
   ```
   Expect `Default Gateway ... -> Remediation ran` (DHCP renewed, gateway back) and `Firewall Status ... -> Remediation ran` (profiles re-enabled), exit `0`, `Overall = Passed`.
3. WhatIf run (no changes): `$env:WhatIf = 'true'` then run the script directly with the firewall disabled by hand (`Set-NetFirewallProfile -All -Enabled False`). Expect `[WhatIf]` lines and the firewall still disabled. Re-enable: `Set-NetFirewallProfile -All -Enabled True`. Clear `$env:WhatIf`.
4. Direct healthy run: exit `0`, all seven steps `[Passed ]` (Internet Connectivity may warn on a lab without outbound access).
5. Not automated, manual only, from the console: disable the adapter (`Disable-NetAdapter -Name 'Ethernet0' -Confirm:$false`) and run the script. Expect `Network Adapters ... -> Remediation ran` and the adapter `Up`. Winsock reset needs a reboot to be fully verified; run `netsh winsock show catalog` afterwards and reboot.
6. Verify: `Get-NetIPConfiguration` shows a gateway, `Get-NetFirewallProfile | Select Name,Enabled` all True, `Resolve-DnsName microsoft.com` succeeds.
7. Restore: harness renews DHCP and re-enables profiles. Fallback: `ipconfig /renew`, `Set-NetFirewallProfile -All -Enabled True`.

**Status:** `PASS - LAB` for the two safe steps. Evidence: `C:\Temp\FixReport\Invoke-AutoRemediateNetworkStack\89bb2f85208e.json` (Passed, 14:59), four passing runs today. Adapter and Winsock steps remain manually verified only, by design. UEM run `e01538` (2026-10-30, single-VM group `Test_JSpencerOnly`, high-impact gate lifted): `Completed` on `CHASEWIN11_2`, reported after the network returned; result file `test-result-solo-netstack.json` in the connector folder.

**Review notes.** Keep the `uem-tests.json` skip until the UEM test group has a device whose Hub connection survives an adapter bounce. Inventory status can move to `4) Complete - Tested` with the note that two steps are console-verified.

### 3.5 `Invoke-AutoRemediateWindowsUpdates.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\Invoke-AutoRemediateWindowsUpdates.ps1`, v1.0.1 |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | none |
| Prerequisites | `wuauserv`, `BITS`, `CryptSvc` services, `C:\Windows\SoftwareDistribution` |
| Automated coverage | `Invoke-AutoRemediateWindowsUpdates_BreakTest.ps1`, breaks `WuauservStopped`, `BitsDisabled`, `CryptSvcStopped`, `DataStoreBloated` (sparse oversized file injected into the DataStore) |

**Purpose.** Eight steps: Windows Update Service, BITS Service, Cryptographic Services, Windows Update DataStore, Pending Reboot Check, Windows Update Policy, Disk Space for Updates, Last Update Date. Resolutions start the services (and set BITS back from Disabled), and rebuild the DataStore by stopping `wuauserv`, renaming `SoftwareDistribution`, and restarting.

**Test steps**

1. Precondition as 3.1 step 1. Confirm `Get-Service BITS | Select StartType` is `Manual` (the default) so the restore has a correct baseline.
2. All four breaks:
   ```powershell
   .\WindowsAutoRemediation\_AutomatedTesting\Invoke-AutoRemediateWindowsUpdates_BreakTest.ps1 -BreakCount 4 -RemediationTest -Environment Physical -Force
   ```
   Expect `-> Remediation ran` on the three service steps and on Windows Update DataStore, `Failed: 0`, exit `0`, `Overall = Passed`.
3. Direct healthy run: exit `0`. `Pending Reboot Check`, `Disk Space for Updates` and `Last Update Date` are informational and print `[Passed ]` or `[Warning]` only.
4. Verify: `Get-Service wuauserv,BITS,CryptSvc | Select Name,Status,StartType` all Running and BITS `Manual`; `Get-ChildItem C:\Windows\SoftwareDistribution\DataStore` has no multi-GB file; `C:\Windows\SoftwareDistribution.old*` cleaned up by the harness restore.
5. Restore: the harness restores BITS start type in reverse order of application. If the machine is left with BITS Disabled after an interrupted run: `Set-Service BITS -StartupType Manual; Start-Service BITS`.

**Status:** `PASS - LAB`. Evidence: `C:\Temp\FixReport\Invoke-AutoRemediateWindowsUpdates\9a0da4c96876.json` (Passed, 4/4, 14:59), four passing runs today. Also `Completed` on both lab devices in UEM sweep `6c8405` (2026-10-29).

**Review notes.** The Disk Space step is intentionally not broken by the harness; its remediation touches real files on `C:`. Inventory status should move to `4) Complete - Tested`.

### 3.6 `Invoke-AutoRemediatePrinter.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\Invoke-AutoRemediatePrinter.ps1`, v1.0.1 |
| Inventory | `3) Complete - Needs Testing`, impact Low |
| Inputs | none |
| Prerequisites | Print Spooler, at least one printer (harness creates `DEXTest Printer` on Microsoft Print To PDF), Printing-PrintToPDFServices-Features / Printing-Foundation-Features optional features |
| Automated coverage | `Invoke-AutoRemediatePrinter_BreakTest.ps1`, breaks `SpoolerService` (stop, or disable and stop), `PrinterOffline` (WorkOffline flag), `NetworkPrinterUnreachable` (printer on an unroutable address, report-only expectation), `PrintFoundationFeature` (optional feature disabled, needs reboot, gated behind `-IncludeRebootBreaks`) |

**Purpose.** Nine steps: Print Spooler Service, Printers Installed, Printer Offline State, Default Printer Set, Print Spooler Queue, Printer Driver Health, Network Printer Connectivity, Windows Print & Scan Feature, Device Condition Signals. Four have resolutions (start Spooler, clear WorkOffline, purge stuck queue, re-enable the print feature); the rest report.

**Test steps**

1. Precondition as 3.1 step 1. Confirm Spooler is `Automatic` and `Running`.
2. Non-reboot breaks:
   ```powershell
   .\WindowsAutoRemediation\_AutomatedTesting\Invoke-AutoRemediatePrinter_BreakTest.ps1 -BreakCount 3 -RemediationTest -Environment Physical -Force
   ```
   The harness excludes `SpoolerService` from multi-break selections (stopping the Spooler would mask the other breaks), so this exercises `PrinterOffline` and `NetworkPrinterUnreachable`. Expect `Printer Offline State ... -> Remediation ran` and `Network Printer Connectivity` reported as `[Warning]` (report-only is the expected outcome). `Overall = Passed`.
3. Spooler alone:
   ```powershell
   .\WindowsAutoRemediation\_AutomatedTesting\Invoke-AutoRemediatePrinter_BreakTest.ps1 -BreakName SpoolerService -RemediationTest -Environment Physical -Force
   ```
   Expect `Print Spooler Service ... -> Remediation ran`, Spooler Running and Automatic afterwards.
4. Reboot break, last, from the console:
   ```powershell
   .\WindowsAutoRemediation\_AutomatedTesting\Invoke-AutoRemediatePrinter_BreakTest.ps1 -BreakName PrintFoundationFeature -IncludeRebootBreaks -RemediationTest -Environment Physical -Force
   ```
   The harness disables Printing-Foundation-Features, registers an AtStartup resume task, reboots, runs the script (`Windows Print & Scan Feature: Print feature state: Disabled -> Remediation ran`), reboots again to apply, validates `Enabled`, and writes the result. Expect `RebootCount = 2`, `Overall = Passed`. The orchestrator shows this step as `Incomplete / ATTENTION` because it reads the state file before the reboot finishes; read the final JSON after the second reboot.
5. Direct healthy run: exit `0`, `Network Printer Connectivity` warns `No network printers found (USB only)` on the VM.
6. Verify: `Get-Service Spooler`, `Get-Printer | Select Name,WorkOffline`, `Get-WindowsOptionalFeature -Online -FeatureName Printing-Foundation-Features | Select State`.
7. Restore: harness removes `DEXTest Printer` and the unroutable printer. Fallback: `Get-Printer | Where-Object Name -like 'DEXTest*' | Remove-Printer; Set-Service Spooler -StartupType Automatic; Start-Service Spooler`.

**Status:** `PASS - LAB`, all four breaks. Evidence: `b9ab66452785.json` (PrinterOffline + NetworkPrinterUnreachable, Passed, 14:59), `e80561c2f791.json` (SpoolerService, Passed, 14:59), `1265da746055.json` (PrintFoundationFeature, Passed after 2 reboots, 15:02), all under `C:\Temp\FixReport\Invoke-AutoRemediatePrinter\`. Also `Completed` on both lab devices in UEM sweep `6c8405` (2026-10-29).

**Review notes.** Harness fixes today: applied breaks are committed to the state file incrementally so an abort mid-apply can still be restored; `SpoolerService` is exclusive in random selections. The 14:30 and 14:33 runs that show `BreakFailed`/`Failed` with zero breaks predate those fixes. Inventory status should move to `4) Complete - Tested`.

---

## 4. Antivirus scripts

None of these have a break test. The Defender scripts can be tested on the lab VM. The CrowdStrike, Trellix and Trend Micro scripts need a VM with the product; on the lab VM they only exercise the "not found" path, which proves nothing about the fix.

Common to all twelve: no `SupportsShouldProcess`; most `Exit 0` on every path, so a UEM result of `Completed` does not prove the fix landed. Verify state, not exit code. Timestamps in several use `hh` (12-hour clock without AM/PM); cosmetic only.

### 4.1 `Invoke-CrowdStrikeServiceRemediation.ps1`

| Field | Value |
|---|---|
| Path / version | `AntiVirusResolutionScripts\CrowdStrike\Invoke-CrowdStrikeServiceRemediation.ps1`, v1.0.0.0 |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | none |
| Prerequisites | CrowdStrike Falcon sensor (`CSFalconService`) |
| Automated coverage | none |

**Purpose.** Intended to set Falcon services to Automatic and start them.

**Test steps** (after the fix below)

1. On a Falcon VM, baseline: `Get-Service CSFalconService | Select Status,StartType`.
2. Break: Falcon is tamper-protected; `Stop-Service CSFalconService` will be denied unless a maintenance token is applied in the Falcon console. Apply the token, stop the service, confirm `Stopped`.
3. Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-CrowdStrikeServiceRemediation.ps1; $LASTEXITCODE`.
4. Expect `[nnnn] CSFalconService has been started and set to Automatic.`, exit `0`.
5. Verify `Get-Service CSFalconService` Running / Automatic.
6. Restore: nothing; revoke the maintenance token.

**Status:** `NEEDS TEST - PRODUCT VM`. UEM sweep `6c8405` (2026-10-29) reported `Completed` on both lab devices, which proves only the not-installed path (result file `test-result-scripts.json` in the connector folder). Fixed 2026-10-29 (v1.0.1.0), parse-checked, not yet run against Falcon.

**Review notes.** Fixed: the service array was the Trend Micro list, so the script never referenced a CrowdStrike service. It now targets `CSFalconService`, re-reads the service after the start attempt, prints a tamper-protection hint when it stays stopped, and exits `1` in that case instead of always `0`. On a device without Falcon it prints "No CrowdStrike Falcon services are installed" and exits `0`.

### 4.2 `Invoke-DefenderDynamicPerformance.ps1`

| Field | Value |
|---|---|
| Path / version | `AntiVirusResolutionScripts\MicrosoftDefender\Invoke-DefenderDynamicPerformance.ps1`, v1.2.0 (reviewed with no version variable; 1.1.0 added it) |
| Inventory | `3) Complete - Needs Testing`, impact Low |
| Inputs | none (reads `$env:SystemDrive`, `HKLM:\SOFTWARE\AIRWATCH\Extensions\HealthDetection`) |
| Prerequisites | Microsoft Defender AV, Storage module (`Get-PhysicalDisk`) |
| Automated coverage | `_AutomatedTesting\Invoke-DefenderDynamicPerformance_BreakTest.ps1` (2 breaks) |

**Purpose.** Scores the hardware (BIOS age, logical CPUs, system disk media and bus type), caches the score under the AirWatch HealthDetection key, and sets Defender scan CPU settings by score bucket: VeryLow 20 percent plus low-priority scans, Low 40, Mid 50, High 75.

**Test steps**

1. Baseline: `Get-MpPreference | Select ScanAvgCPULoadFactor,EnableLowCpuPriority,DisableCpuThrottleOnIdleScans`.
2. Break:
   ```powershell
   Set-MpPreference -ScanAvgCPULoadFactor 10
   Set-MpPreference -EnableLowCpuPriority $true
   Set-MpPreference -DisableCpuThrottleOnIdleScans $true
   Remove-ItemProperty 'HKLM:\SOFTWARE\AIRWATCH\Extensions\HealthDetection' -Name PerformanceProfile,CurrentProfile,PeformanceScore -ErrorAction SilentlyContinue
   ```
3. Run the script. It prints nothing on success.
4. Expect for a 4-vCPU, 2021-BIOS VM with an unspecified disk type: score 1 to 5, bucket Mid, so `ScanAvgCPULoadFactor 50`, `EnableLowCpuPriority False`, `DisableCpuThrottleOnIdleScans False`.
5. Verify with the baseline command and `Get-ItemProperty 'HKLM:\SOFTWARE\AIRWATCH\Extensions\HealthDetection'`.
6. Restore: `Set-MpPreference` back to the baseline values.

**Status:** `PASS - LAB` + `PASS - UEM`, Full Pass. Break test run acd1081436f9 on 2026-11-02 (elevated, lab VM `CBRADLEYSWIN11`): CpuProfileDrift and ScoreCacheCorrupt (load factor drifted to 5 with a stale marker, score cache set to a non-number; script recomputed the score and re-applied the profile); machine restored. Result `C:\Temp\FixReport\Invoke-DefenderDynamicPerformance\acd1081436f9.json`. UEM sweep `6c8405` (2026-10-29) `Completed` on both devices. Rerun on 1.2.0 (13.2.e) `f5e48cac81fc` 2026-11-05 11:29, elevated, 6.5 s: CpuProfileDrift by the PriorityDriftMarkerRemoved method and ScoreCacheCorrupt by NonNumericScore, both verified broken and both repaired; machine restored. Result `C:\Temp\FixReport\Invoke-DefenderDynamicPerformance\f5e48cac81fc.json`.

**Review notes.** Fixed: cache key mismatch (`PeformanceScore` written, `PerformanceProfile` read), `CurrentProfile` never written so settings re-applied every run, scores 7 and 8 mapped to no profile, trailing `System.Windows.Forms` reference, missing `ConfigDefender` import on PowerShell 7, no output or exit code. Dead code removed. Exits `1` when Defender cmdlets are absent.

### 4.3 `Invoke-DefenderEnableCloudBlock_BAFS.ps1`

| Field | Value |
|---|---|
| Path / version | `AntiVirusResolutionScripts\MicrosoftDefender\Invoke-DefenderEnableCloudBlock_BAFS.ps1`, v1.0.2.1 |
| Inventory | `4) Complete - Tested`, impact Low |
| Inputs | none |
| Prerequisites | Microsoft Defender AV, not policy-managed for Spynet settings |
| Automated coverage | none |

**Purpose.** Sets `CloudBlockLevel` to High (1), `MAPSReporting` to Advanced (2), `SubmitSamplesConsent` to 1, each only when not already compliant.

**Test steps**

1. Confirm the device is not GPO or Intune managed for these values: `Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' -ErrorAction SilentlyContinue` returns nothing.
2. Break:
   ```powershell
   Set-MpPreference -CloudBlockLevel 0
   Set-MpPreference -MAPSReporting Disabled
   Set-MpPreference -SubmitSamplesConsent 0
   ```
3. Run the script.
4. Expect `[nnnn] Cloud block level updated to: 1.`, `[nnnn] Updating MAPS Reporting to: Advanced.`, `[nnnn] Updating SubmitSamplesConsent to: '1'.`, exit `0`. A second run prints the three "already" lines.
5. Verify `Get-MpPreference | Select CloudBlockLevel,MAPSReporting,SubmitSamplesConsent` is `1 / 2 / 1`.
6. Restore: only if the baseline differed. Sample submission at consent 1 sends files to Microsoft.

**Status:** `TESTED - MANUAL`. Also `Completed` on both lab devices in UEM sweep `6c8405` (2026-10-29).

**Review notes.** Always exits `0` even if `Set-MpPreference` fails. Policy-managed values make the cmdlet silently ineffective; the second run will keep printing "updating" in that case, which is the tell.

### 4.4 `Invoke-DefenderPauseScan.ps1`

| Field | Value |
|---|---|
| Path / version | `AntiVirusResolutionScripts\MicrosoftDefender\Invoke-DefenderPauseScan.ps1`, no version variable |
| Inventory | `4) Complete - Tested`, impact Low |
| Inputs | none (reads `$env:ProgramFiles`, `$env:ProgramData`) |
| Prerequisites | `MpCmdRun.exe` under Program Files or the Platform folder |
| Automated coverage | none |

**Purpose.** Finds the newest `MpCmdRun.exe` and runs `-Scan -Cancel`.

**Test steps**

1. Start a scan: `Start-MpScan -ScanType FullScan -AsJob`. Confirm event 1000 in `Microsoft-Windows-Windows Defender/Operational` or `Get-MpComputerStatus | Select FullScanStartTime,FullScanEndTime`.
2. Within a few seconds run the script.
3. Expect MpCmdRun's own text (`Scan cancelled`), no script-authored lines, exit `0`.
4. Verify event 1002 ("scan was stopped before it finished") appears: `Get-WinEvent -LogName 'Microsoft-Windows-Windows Defender/Operational' -MaxEvents 20 | Where-Object Id -eq 1002`.
5. Negative path: rename nothing; instead run on a machine with Defender removed to see `MpCmdRun.exe was not found.` as a terminating error.
6. Restore: none.

**Status:** `TESTED - MANUAL`. Also `Completed` on both lab devices in UEM sweep `6c8405` (2026-10-29).

**Review notes.** Path selection is a string sort on `FullName` descending, so `C:\ProgramData\...\Platform\...` beats `C:\Program Files\Windows Defender\...` and version folders sort lexically, not numerically. The name says pause; it cancels. No exit code of its own.

### 4.5 `Invoke-DefenderServiceRemediation.ps1`

| Field | Value |
|---|---|
| Path / version | `AntiVirusResolutionScripts\MicrosoftDefender\Invoke-DefenderServiceRemediation.ps1`, v1.6.1.0 |
| Inventory | `4) Complete - Tested`, impact Low |
| Inputs | none (`$WhatIfPreference` hard-coded `$false` at line 30; set `$true` to skip the RTP change only) |
| Prerequisites | Defender AV and Windows Firewall services: `MDCoreSvc`, `WinDefend`, `WdNisSvc`, `mpssvc` |
| Automated coverage | none |

**Purpose.** Sets the four services to Automatic and starts them if stopped, then enables Real-Time Protection if disabled.

**Test steps**

1. Baseline: `Get-Service MDCoreSvc,WinDefend,WdNisSvc,mpssvc | Select Name,Status,StartType` and `(Get-MpComputerStatus).RealTimeProtectionEnabled`. Note whether `WdNisSvc` is Manual (common); the script will set it Automatic.
2. Break the testable parts. `WinDefend`, `MDCoreSvc` and `WdNisSvc` are protected processes and cannot be stopped even as SYSTEM. Use the firewall: `Stop-Service mpssvc -Force`. For RTP, only with Tamper Protection off in Windows Security: `Set-MpPreference -DisableRealtimeMonitoring $true`.
3. Run the script.
4. Expect `[nnnn] mpssvc has been started and set to Automatic.`, "already running" lines for the protected services, `Real Time Protection enabled.  Status is True.` (or "already enabled"), exit `0`. Access Denied text from `Set-Service` on `WinDefend` is normal and does not change the exit code.
5. Verify all four Running, RTP True.
6. Restore: `Set-Service WdNisSvc -StartupType Manual` if it was Manual. Re-enable Tamper Protection.

**Status:** `TESTED - MANUAL`. Also `Completed` on both lab devices in UEM sweep `6c8405` (2026-10-29).

**Review notes.** Always exits `0`. Forcing `WdNisSvc` to Automatic is a persistent config change. Starting `mpssvc` re-enables the firewall, which is visible to a user who had turned it off.

### 4.6 `Invoke-DefenderUpdateSignatures.ps1`

| Field | Value |
|---|---|
| Path / version | `AntiVirusResolutionScripts\MicrosoftDefender\Invoke-DefenderUpdateSignatures.ps1`, v1.0.0.0 |
| Inventory | `4) Complete - Tested`, impact Low |
| Inputs | none |
| Prerequisites | Defender AV, network path to the configured signature source |
| Automated coverage | none |

**Purpose.** If `Get-MpComputerStatus` reports `DefenderSignaturesOutOfDate`, starts `Update-MpSignature -AsJob` and exits.

**Test steps**

1. Baseline: `Get-MpComputerStatus | Select AntivirusSignatureVersion,AntivirusSignatureLastUpdated,DefenderSignaturesOutOfDate`.
2. Break (lab only, degrades protection until the update completes): `& "$env:ProgramFiles\Windows Defender\MpCmdRun.exe" -RemoveDefinitions -All`. Confirm `DefenderSignaturesOutOfDate` is True. Alternative that does not degrade: test only the "already up to date" branch.
3. Run the script.
4. Expect `[nnnn] Updating signature as job` plus a Job object table, exit `0`; or `[nnnn] Defender signature is already up to date.`, exit `0`.
5. Verify after 1 to 5 minutes: `DefenderSignaturesOutOfDate` False, event 2000 in the Defender Operational log.
6. Restore: none needed once signatures are current.

**Status:** `TESTED - MANUAL`. Also `Completed` on both lab devices in UEM sweep `6c8405` (2026-10-29).

**Review notes.** The job lives in the script's own session and the script exits immediately; under Hub the host process may end before the job runs. Prefer `Update-MpSignature` synchronously or `MpCmdRun -SignatureUpdate` if UEM runs show no event 2000. `$MaxFullScanHours` is unused.

### 4.7 `Start-DefenderFullScan.ps1`

| Field | Value |
|---|---|
| Path / version | `AntiVirusResolutionScripts\MicrosoftDefender\Start-DefenderFullScan.ps1`, v1.0.3.1 |
| Inventory | `3) Complete - Needs Testing`, impact Low (actual user impact is a full scan: hours of high CPU and disk) |
| Inputs | none (`$WhatIfPreference` line 7, set `$true` for a dry run) |
| Prerequisites | Defender AV; optional WS1 scheduled task `\WorkspaceOneEx\Defender\FullScanDetection`; `HKLM:\SOFTWARE\AIRWATCH\Extensions\HealthDetection` |
| Automated coverage | none |

**Purpose.** Starts a full scan as a job unless one is already running, detected via the WS1 task plus `FullScanInProgress` registry flag, or via events 1000/1001 and `Get-MpComputerStatus`.

**Test steps** (after the fix below)

1. Dry run: set `$WhatIfPreference=$true` on line 7 of a scratch copy and run it. Expect `What if: Performing the operation 'Start-MpScan' ...`, exit `0`.
2. Skip path: `Start-MpScan -ScanType FullScan -AsJob`, wait for event 1000, run the script. Expect `Full scan is already running. Exiting...`, exit `0`.
3. Task branch: register a placeholder task and flag, run, expect the same skip:
   ```powershell
   Register-ScheduledTask -TaskPath '\WorkspaceOneEx\Defender\' -TaskName FullScanDetection -Action (New-ScheduledTaskAction -Execute cmd.exe) -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(1))
   New-ItemProperty 'HKLM:\SOFTWARE\AIRWATCH\Extensions\HealthDetection' -Name FullScanInProgress -Value 1 -PropertyType DWord -Force
   ```
   Clean up with `Unregister-ScheduledTask -TaskPath '\WorkspaceOneEx\Defender\' -TaskName FullScanDetection -Confirm:$false` and remove the property.
4. Start path: cancel any scan (`MpCmdRun.exe -Scan -Cancel`), run the script. Expect `Starting Defender scan (Full Scan).` plus a Job table, exit `0`, event 1000 with `Scan Parameters: Full scan`.
5. Restore: `MpCmdRun.exe -Scan -Cancel`.

**Status:** `PASS - UEM`. Fixed 2026-10-29 (v1.0.3.2), parse-checked. Ran through UEM as SYSTEM against the single-VM group `Test_JSpencerOnly` on 2026-11-02 (run `fad62d`): `Completed`, reported 194 s after the sync. The script starts the full scan with `Start-MpScan -AsJob` and exits, so the status is definitive while the scan itself runs on for hours on `CHASEWIN11_2`; the VM is reverted to its snapshot afterwards. Action script under the Full Pass rule: UEM `Completed` plus the scan start is the pass. Manual steps 1 to 4 remain the way to watch the scan itself.

**Review notes.** Fixed: `$healthDetectionPath` is now assigned before the branch, so the task-present path reads `FullScanInProgress` correctly; the event and `Get-MpComputerStatus` paths both normalise to `[DateTime]` before comparing, so a finished scan is no longer reported as running; `Start-MpScan` uses `-ErrorAction Stop` so the catch and exit `1` are reachable. Remaining: `-MaxEvents 100` can miss the start event on busy logs.

### 4.8 `Start-DefenderThreatReport.ps1`

| Field | Value |
|---|---|
| Path / version | `AntiVirusResolutionScripts\MicrosoftDefender\ThreatReporting\Start-DefenderThreatReport.ps1`, v1.4.8.4 |
| Inventory | `4) Complete - Tested`, impact Low |
| Inputs | none (`$MAP_THREATS_TO_APPS=$true`, `$MAP_THREATS_RETENTION=36` hours hard-coded) |
| Prerequisites | Defender AV with at least one detection in history |
| Automated coverage | none |

**Purpose.** Writes `ActiveThreats` and `LastRun` to the AirWatch HealthDetection key and publishes each detection as a hidden `THRT:<id>` entry under the Uninstall hive so it surfaces in Workspace ONE Intelligence app inventory. Archives entries older than 36 hours and purges orphans.

**Test steps**

1. Baseline: `Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' | Where-Object PSChildName -like 'THRT:*'` returns nothing.
2. Create a detection with the EICAR test string (Real-Time Protection quarantines it instantly):
   ```powershell
   Set-Content -Path "$env:TEMP\eicar.com" -Value 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*'
   Get-MpThreatDetection | Select ThreatID,InitialDetectionTime
   ```
3. Run the script.
4. Expect `[nnnn]Writing active threats to registry: 0` (quarantined is inactive), `[nnnn]Adding record for THRT:...`, `[nnnn]Updating LastRun to <ISO>`, exit `0`.
5. Verify `Get-ChildItem ...\Uninstall | Where-Object PSChildName -like 'THRT:*' | Get-ItemProperty` shows `DisplayName` like `THRT:Virus:DOS/EICAR_Test_File-2 (Inactive)`, `Publisher = DEFENDER`, `SystemComponent = 1`; `Get-ItemProperty 'HKLM:\SOFTWARE\AIRWATCH\Extensions\HealthDetection' | Select ActiveThreats,LastRun`.
6. Second run: expect `Updating record for ...`. After 36 hours (or by editing `InstallDate` back 2 days) expect `Archiving record for ...` and the entry moved to `HealthDetection\THRT:<id>`.
7. Restore: `Remove-MpThreat` for the EICAR threat, delete the `THRT:*` keys under both hives, remove `$env:TEMP\eicar.com` if still present.

**Status:** `TESTED - MANUAL`. Also `Completed` on both lab devices in UEM sweep `6c8405` (2026-10-29).

**Review notes.** The `UninstallString` written for active threats runs `Remove-MpThreat` if anyone uninstalls the entry from WS1: intended, but worth knowing. If Defender cmdlets fail (third-party AV present) the script continues, writes `ActiveThreats = 0` and purges every `THRT:*` record. `InstallDate` is written as ISO 8601 rather than the `yyyyMMdd` that Programs and Features expects.

### 4.9 `Invoke-TrellixCPUPriority.ps1`

| Field | Value |
|---|---|
| Path / version | `AntiVirusResolutionScripts\Trellix\Invoke-TrellixCPUPriority.ps1`, v1.0.0.0 |
| Inventory | `3) Complete - Needs Testing`, impact Low |
| Inputs | none |
| Prerequisites | Trellix ENS processes: `mcshield`, `mfemms`, `mfevtps`, `macmnsvc`, `masvc`, `mfeesp`, `mfeann`, `mfehcs`, `mfetp` |
| Automated coverage | none |

**Purpose.** Sets `PriorityClass = BelowNormal` on every running Trellix process and emits one object per process with the result.

**Test steps**

1. Product VM: baseline `Get-Process mcshield,mfetp -ErrorAction SilentlyContinue | Select Name,Id,PriorityClass`.
2. Logic-only smoke on the lab VM: `Copy-Item C:\Windows\System32\notepad.exe $env:TEMP\mfetp.exe; Start-Process $env:TEMP\mfetp.exe`.
3. Run the script.
4. Expect a table with `Result = Priority changed to BelowNormal` for the dummy process. On a real product VM expect `Failed: Access is denied` for self-protected processes such as `mcshield`.
5. Verify `PriorityClass` is `BelowNormal` for the processes that reported success.
6. Restore: `Stop-Process -Name mfetp; Remove-Item $env:TEMP\mfetp.exe`. Priority resets on service restart.

**Status:** `NEEDS TEST - PRODUCT VM`. UEM sweep `6c8405` (2026-10-29) reported `Completed` on both lab devices, which proves only the not-installed path (result file `test-result-scripts.json` in the connector folder).

**Review notes.** In the catch block `$_` is the ErrorRecord, so the failure row loses `ProcessName` and `PID`. Lowering scanner priority delays on-access scanning. No exit code.

### 4.10 `Invoke-TrellixLocalUpdate.ps1`

| Field | Value |
|---|---|
| Path / version | `AntiVirusResolutionScripts\Trellix\Invoke-TrellixLocalUpdate.ps1`, v1.0.0.0 |
| Inventory | `3) Complete - Needs Testing`, impact Low |
| Inputs | none (reads `$env:ProgramFiles`, `${env:ProgramFiles(x86)}`) |
| Prerequisites | Trellix ENS Threat Prevention `amcfg.exe`; McAfee/Trellix Agent `CmdAgent.exe` |
| Automated coverage | none |

**Purpose.** Runs `amcfg.exe /update` for AMCore content, then `CmdAgent.exe /p /c /e /f` with 10-second pauses for a policy refresh.

**Test steps**

1. Product VM: note the current AMCore content version in the ENS console and the last agent communication time in ePO.
2. Run the script. Allow several minutes; it is synchronous.
3. Expect `Running Trellix ENS content update...`, `Running Trellix Agent policy refresh...`, four `Running CmdAgent.exe /x` lines.
4. Verify the ENS update log under `C:\ProgramData\McAfee\Endpoint Security\Logs\` shows a new update and `C:\ProgramData\McAfee\Agent\logs\masvc_*.log` shows property collection and policy enforcement.
5. Lab VM without the product: expect both "not found. Skipping" lines and an instant exit.

**Status:** `NEEDS TEST - PRODUCT VM`. UEM sweep `6c8405` (2026-10-29) reported `Completed` on both lab devices, which proves only the not-installed path (result file `test-result-scripts.json` in the connector folder).

**Review notes.** Four 10-second sleeps plus the content update exceed a 30-second UEM script timeout; raise the timeout on the UEM item or drop the sleeps. External exit codes are not checked. Duplicates the CmdAgent logic in 4.11.

### 4.11 `Invoke-TrellixRefreshPolicies.ps1`

| Field | Value |
|---|---|
| Path / version | `AntiVirusResolutionScripts\Trellix\Invoke-TrellixRefreshPolicies.ps1`, v1.0.0.0 |
| Inventory | `3) Complete - Needs Testing`, impact Low |
| Inputs | none |
| Prerequisites | McAfee/Trellix Agent `CmdAgent.exe` |
| Automated coverage | none |

**Purpose.** Runs `CmdAgent.exe /p`, `/c`, `/e`, `/f` hidden with `-Wait`, 10 seconds apart.

**Test steps**

1. Product VM: note the agent's last communication time in ePO.
2. Run the script (about 40 seconds minimum).
3. Expect four `Running CmdAgent.exe /x` lines.
4. Verify `masvc_<host>.log` shows "Collecting properties", "Checking for policies", "Enforcing policies", "Sending events", and ePO shows a new last-communication time.
5. Lab VM without the product: expect the terminating error `CmdAgent.exe was not found.` and a non-zero host exit.

**Status:** `NEEDS TEST - PRODUCT VM`. UEM sweep `6c8405` (2026-10-29) reported `Failed` (exit 1) on both lab devices, which is the manifest's expected result there, which proves only the not-installed path (result file `test-result-scripts.json` in the connector folder).

**Review notes.** Same 40-second floor as 4.10. Throws on a missing executable where 4.10 prints a message; pick one behaviour.

### 4.12 `Invoke-TrendMicroServiceRemediation.ps1`

| Field | Value |
|---|---|
| Path / version | `AntiVirusResolutionScripts\TrendMicro\Invoke-TrendMicroServiceRemediation.ps1`, v1.0.0.0 |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | none |
| Prerequisites | Trend Micro Apex One / OfficeScan agent services `ntrtscan`, `tmlisten`, `ofcservice`, `TmCCSF`, `TmWSCSvc`, `TmPfw` |
| Automated coverage | none |

**Purpose.** Sets each service to Automatic and starts it if stopped.

**Test steps**

1. Product VM: baseline `Get-Service ntrtscan,tmlisten,ofcservice,TmCCSF,TmWSCSvc,TmPfw | Select Name,Status,StartType`.
2. Break: Apex One self-protects; allow "Unload/Unlock" in the agent policy, then `Stop-Service tmlisten`.
3. Run the script.
4. Expect `[nnnn] tmlisten has been started and set to Automatic.`, "already running" for the rest, warnings for any service absent by policy, exit `0`.
5. Verify all present services Running / Automatic.
6. Restore: re-lock the agent in policy. Note `TmPfw` set to Automatic turns the Trend firewall on if it was off by design.

**Status:** `NEEDS TEST - PRODUCT VM`. UEM sweep `6c8405` (2026-10-29) reported `Completed` on both lab devices, which proves only the not-installed path (result file `test-result-scripts.json` in the connector folder).

**Review notes.** Header promises a real-time protection check that does not exist in the body. Always exits `0`. Identical body to 4.1.

---

## 5. Windows remediation scripts (no harness)

Seventeen scripts under `WindowsAutoRemediation\` outside the six harness-covered ones. Nine are step-engine scripts, the rest are plain or `ShouldProcess` scripts. None has a break test; every test below is manual. All run as SYSTEM under UEM unless noted. Several share one defect worth knowing up front: when a step is `Failed` and then successfully remediated, the script still exits `1` on that run, so the first UEM run of a broken device reports Failed and the second reports Completed. That is by design in these scripts but should be read as "remediated" not "broken".

`ProcessManagement\Restart-WinProcessSoft.ps1`, a 0-byte placeholder, was deleted from the repo on 2026-11-02; it was never counted or published.

### 5.1 `Invoke-AutoRemediateWiFiSignalIssues.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\Invoke-AutoRemediateWiFiSignalIssues.ps1`, v2.0.2 (2026-11-02: every adapter lookup wrapped in `@()` so a single adapter counts as one; steps 4 and 5 return a Warning naming the settings they could not read instead of a false pass; the engine re-runs detection after each remediation, prints the final status, summarises `Fixed: N | Still failing: N` and exits 1 when anything still fails) |
| Inventory | `4) Complete - Tested` since 2026-11-03 (row 7), impact Medium |
| Inputs | `$env:AdapterName` (optional, default all wireless adapters) |
| Prerequisites | Physical Wi-Fi adapter, `WlanSvc`, NetAdapter module, `powercfg` |
| Automated coverage | none |

**Purpose.** Seven steps: Wireless Adapter Detection, Wi-Fi Signal Strength (bounces the adapter when weak or not connected), Driver Age (report), NIC Power Management, Adapter Power Saving Mode, Power Plan Wireless Settings, USB Selective Suspend.

**Test steps** (needs a laptop or a VM with a USB Wi-Fi adapter passed through)

1. Baseline: `Get-NetAdapterPowerManagement -Name Wi-Fi | Select AllowComputerToTurnOffDevice`; `powercfg /q SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a`.
2. Break:
   ```powershell
   Set-NetAdapterPowerManagement -Name Wi-Fi -AllowComputerToTurnOffDevice Enabled
   powercfg /setdcvalueindex SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 3
   powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
   powercfg /setactive SCHEME_CURRENT
   ```
   The two `powercfg` breaks also work on the lab VM, but step 1 of the script fails there with no adapter and the exit code is always `1`.
3. Run the script from the console (step 2 may bounce the adapter for about 8 seconds).
4. Expect `[Failed ] NIC Power Management ... -> Remediation ran`, `[Failed ] Power Plan Wireless Settings: ... (AC=0, DC=3 ...) -> Remediation ran`, `[Warning] USB Selective Suspend ... -> Remediation ran`, exit `1` on this run, `0` on the next.
5. Verify: `AllowComputerToTurnOffDevice : Disabled`; `powercfg /q` shows AC and DC index `0x00000000` for wireless and `0x00000001` for USB selective suspend.
6. Restore: reverse the `powercfg` values if the device had different defaults.

**Status:** `NEEDS TEST - PRODUCT VM`. UEM sweep `6c8405` (2026-10-29) reported `Failed` (exit 1) on both lab devices, which is the manifest's expected result there, which proves only the not-installed path (result file `test-result-scripts.json` in the connector folder).

**Review notes.** Bounces the adapter on a mere warning, including when Wi-Fi is simply not connected. Disables USB selective suspend system-wide even for non-USB adapters. Exit `1` after a successful fix. Step 3 recommends `Invoke-DriverUpdates.ps1` but does not call it.

### 5.2 `Invoke-DriverUpdates.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\DriverUpdates\Invoke-DriverUpdates.ps1`, v1.0.1 |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | `$env:Mode` (`Detect` default, `Install`), `$env:DriverFilter` (regex on title), `$env:AllowReboot` (`True`/`False`), `$env:MaxUpdates` (default 10) |
| Prerequisites | `wuauserv`, `Microsoft.Update.Session` COM, reachable Windows Update or WSUS, driver updates not excluded by policy |
| Automated coverage | `DriverUpdates\_AutomatedTesting\Invoke-DriverUpdates_BreakTest.ps1` (1 breaks) |

**Purpose.** Searches Windows Update for driver updates. Detect mode lists them and exits `1` when any exist. Install mode downloads and installs, forces a reboot flag for high-risk classes (audio, GPU, USB controllers, storage, chipset) and exits `3010` when a reboot is needed and `AllowReboot` is true.

**Test steps**

1. Precheck what WU offers: `(New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().Search("IsInstalled=0 and Type='Driver'").Updates | Select Title`. A fresh VM usually has at least one optional driver.
2. Detect: `$env:Mode='Detect'` then run. Expect `[RebootReq]`/`[NoReboot]` lines, `N driver update(s) available. Run with -Mode Install to apply.`, exit `1`. With `$env:DriverFilter='ZZZNOMATCH'` expect `No driver updates to act on.`, exit `0`.
3. Install (snapshot first): `$env:Mode='Install'; $env:AllowReboot='True'` then run. Expect `Install results:` with `[OK]` lines, `Summary: N installed, 0 failed, RebootRequired: True|False`, exit `3010` or `0`.
4. Reboot-flag path without a real install: create `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired` before an Install run and expect `3010`. Remove the key afterwards.
5. Verify in Device Manager or `Get-PnpDeviceProperty` that the driver version changed; rerun Detect and expect exit `0`.

**Status:** `PASS - LAB` + `PASS - UEM`, Full Pass. Break test run f6feb1b31416 on 2026-11-02 (elevated, lab VM `CBRADLEYSWIN11`): WuauservStopped (service stopped, script started it; driver discovery itself is not injectable on a VM); machine restored. Result `C:\Temp\FixReport\Invoke-DriverUpdates\f6feb1b31416.json`. UEM sweep `6c8405` (2026-10-29) `Completed` on both devices. Rerun on 1.0.1 (13.2.l) `0ec8523cc211` 2026-11-05 11:30, elevated, 46 s: WuauservStopped verified broken and repaired, the search ran through the new policy pre-check and pending-reboot helper on an unblocked host; machine restored. Result `C:\Temp\FixReport\Invoke-DriverUpdates\0ec8523cc211.json`.

**Review notes.** Detect exit `1` is indistinguishable from an error exit `1`; UEM will show Failed whenever updates exist. Malformed `$env:AllowReboot` or `$env:MaxUpdates` throws in the param block and the script falls through to a trailing `Exit 0`. WU search and download can exceed the 120-second timeout noted in the header.

### 5.3 `Invoke-RemediateMemoryCompression.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\Memory\Invoke-RemediateMemoryCompression.ps1` |
| Inventory | `3) Complete - Needs Testing`, impact Low |
| Inputs | none |
| Prerequisites | `Get-MMAgent`/`Enable-MMAgent` (Windows 10 or later) |
| Automated coverage | `Memory\_AutomatedTesting\Invoke-RemediateMemoryCompression_BreakTest.ps1` (1 break) |

**Purpose.** Re-enables memory compression when `Get-MMAgent` reports it disabled and records the result under `HKLM:\Software\AirWatch\Extension\DEXRecords\MemoryErrors\MemoryCompression`.

**Test steps**

1. Baseline: `(Get-MMAgent).MemoryCompression`.
2. Break: `Disable-MMAgent -MemoryCompression`. Confirm `False`.
3. Run the script.
4. Expect `[Remediated] Memory compression is disabled. Enabling now.`, `[Registry] Results written to ...`, exit `0`. Second run: `[Passed] Memory compression is enabled.`
5. Verify `(Get-MMAgent).MemoryCompression` is `True`; registry `Status = Remediated`.
6. Restore: none; or `Disable-MMAgent -MemoryCompression` if the image disables it on purpose.

**Status:** `PASS - LAB` + `PASS - UEM`, Full Pass. Break test run 075ce256c2af on 2026-11-02 (elevated, lab VM `CBRADLEYSWIN11`): memory compression disabled with `Disable-MMAgent`, verified off, the script re-enabled it and wrote `Status = Remediated`; machine restored. Result `C:\Temp\FixReport\Invoke-RemediateMemoryCompression\075ce256c2af.json`. UEM sweep `6c8405` (2026-10-29) `Completed` on both devices.

**Review notes.** Still attempts the fix when detection throws. Registry path uses `Extension` (singular) while the WindowsLogon scripts use `Extensions`. Some SSD or VDI baselines disable compression deliberately.

### 5.4 `Invoke-RemediatePageFile.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\Memory\Invoke-RemediatePageFile.ps1` |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | `$env:PageFileUsageFailPercent` (default 80) |
| Prerequisites | `Win32_ComputerSystem`, `Win32_PageFileUsage` |
| Automated coverage | `Memory\_AutomatedTesting\Invoke-RemediatePageFile_BreakTest.ps1` (2 breaks) |

**Purpose.** When the page file is manually sized and usage is at or above the threshold, resets it to system-managed. Reports high usage otherwise. Writes `RebootRequired = True` to `...\DEXRecords\MemoryErrors\PageFile` after a fix.

**Test steps** (snapshot first; involves a reboot)

1. Break:
   ```powershell
   Get-CimInstance Win32_ComputerSystem | Set-CimInstance -Property @{ AutomaticManagedPagefile = $false }
   Set-CimInstance -Query "SELECT * FROM Win32_PageFileSetting" -Property @{ InitialSize = 1024; MaximumSize = 1024 }
   Restart-Computer
   ```
2. Force the Failed path without real memory pressure: `$env:PageFileUsageFailPercent = '1'`. Run.
3. Expect `[Remediated] Page file is manually configured and near capacity: ... Resetting to system-managed.`, `-> Reboot recommended ...`, exit `0`.
4. Verify `(Get-CimInstance Win32_ComputerSystem).AutomaticManagedPagefile` is `True`; registry `Status = Remediated`, `RebootRequired = True`. Reboot, then rerun with no override and expect `[Passed] Page file is system-managed, ...`.
5. Without the override and a manual-but-healthy page file, expect `[Warning]` and exit `1` with no change.

**Status:** `PASS - LAB` + `PASS - UEM`, Full Pass. Break test runs c845854c3e7e and 114fedf1ed3c on 2026-11-02 (elevated, lab VM `CBRADLEYSWIN11`): the first cleared `AutomaticManagedPagefile` with system-managed sizes left in place (usage 9.9 %), and script 1.0.1 reported Warning "Page file is manually configured", changed nothing and exited 0 with `Status = Warning`; the second cleared the flag, pinned a 2 GB fixed size (written to the `PagingFiles` registry value after every WMI route answered "Value out of range", see 13.5) and set the script's threshold override to 0, and script 1.0.1 turned automatic management back on, wrote `Status = Remediated` and exited 0. Machine restored after each run, including the captured `PagingFiles` value. Results `C:\Temp\FixReport\Invoke-RemediatePageFile\c845854c3e7e.json` and `114fedf1ed3c.json`. UEM sweep `6c8405` (2026-10-29) `Completed` on both devices.

**Review notes.** Both advisory Warning states exit `1`, which UEM reports as Failed with nothing to fix. A malformed threshold variable throws in the param block and the script falls through to `Exit 0`.

### 5.5 `Invoke-RemediateSysMain.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\Memory\Invoke-RemediateSysMain.ps1` |
| Inventory | `3) Complete - Needs Testing`, impact Low |
| Inputs | none |
| Prerequisites | `SysMain` service |
| Automated coverage | `Memory\_AutomatedTesting\Invoke-RemediateSysMain_BreakTest.ps1` (2 breaks) |

**Purpose.** Sets SysMain (Superfetch) to Automatic and starts it. Records to `...\DEXRecords\MemoryErrors\SysMain`.

**Test steps**

1. Break: `Stop-Service SysMain -Force; Set-Service SysMain -StartupType Disabled`.
2. Run. Expect `[Remediated] SysMain is disabled. Setting to Automatic and starting.`, exit `0`.
3. Verify `Get-Service SysMain | Select Status,StartType` is Running / Automatic; rerun prints `[Passed] SysMain is running (StartType: Automatic)`.
4. Restore: none.

**Status:** `PASS - LAB` + `PASS - UEM`, Full Pass. Break test run a1b442690696 on 2026-11-02 (elevated, lab VM `CBRADLEYSWIN11`): SysMain stopped, verified stopped, script 1.0.1 set Automatic and started it and wrote `Status = Remediated`; machine restored. Result `C:\Temp\FixReport\Invoke-RemediateSysMain\a1b442690696.json`. Second run 90575d8adf92 (same day, `-BreakName SysMainDisabledWhileRunning`): service left running with StartType Disabled, script 1.0.1 detected it and set Automatic; this is the gap 1.0.0 would have missed. UEM sweep `6c8405` (2026-10-29) `Completed` on both devices.

**Review notes.** Reverts deliberate SysMain disablement on SSD or VDI images. A GPO enforcing Disabled undoes the fix at the next refresh.

### 5.6 `Disable-NonEssentialStartupApps.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\Performance\Disable-NonEssentialStartupApps.ps1` |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | none (hard-coded gaming, media and personal-utility name lists) |
| Prerequisites | Must run in **User** context (see review notes) |
| Automated coverage | none |

**Purpose.** Five steps: removes matching entries from `HKCU\...\Run` (gaming, media, utilities), audits `HKLM\...\Run` (report only), deletes matching `.lnk` files from the user's Startup folder.

**Test steps** (run as the test user, not SYSTEM)

1. Break:
   ```powershell
   New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name Spotify -Value 'C:\lab\spotify.exe' -PropertyType String
   New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name Steam   -Value 'C:\lab\steam.exe'   -PropertyType String
   New-Item -Path "$([Environment]::GetFolderPath('Startup'))\Discord.lnk" -ItemType File
   # elevated, for the audit warning:
   New-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -Name Dropbox -Value 'C:\lab\dropbox.exe' -PropertyType String
   ```
2. Run. Expect `[Failed ] HKCU Run - Gaming Clients: ... Steam -> Remediation ran`, `[Failed ] HKCU Run - Media & Entertainment: ... Spotify -> Remediation ran`, `[Warning] HKLM Run - Non-Essential Entries (Audit): ... Dropbox`, `[Failed ] Startup Folder - User Scope: ... Discord.lnk -> Remediation ran`, exit `1` this run, `0` next run.
3. Verify the HKCU values and the shortcut are gone; the HKLM value remains.
4. Restore: `Remove-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -Name Dropbox`.

**Status:** `TESTED - MANUAL` for the User-context path (2026-10-29, v1.0.2: planted `SpotifyLabTest` Run value and `DiscordLabTest.lnk` removed, exit `1` then `0`). `NEEDS TEST` for the SYSTEM path: run elevated via `PsExec64 -s` with a console user logged on and confirm the banner reads `Target user: <console user>` and the entries in that user's hive are removed. Also `Completed` on both lab devices in UEM sweep `6c8405` (2026-10-29).

**Review notes.** Fixed: under SYSTEM the script now resolves the console user and targets `HKEY_USERS\<SID>\...\Run` and that user's Startup folder; with no console user it reports and exits `0`. Header context updated. Remaining: substring matching gives false positives (`itch` matches Twitch, `Steam` matches SteamVR); removes org-deployed per-user Dropbox or Discord; no WhatIf; exit `1` on the run that fixes things.

### 5.7 `Enable-HardwareAcceleratedGPUScheduling.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\Performance\Enable-HardwareAcceleratedGPUScheduling.ps1` |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | none |
| Prerequisites | Windows 10 2004 (build 19041) or later; a real GPU with a WDDM 2.7 driver for the setting to matter |
| Automated coverage | `Performance\_AutomatedTesting\Enable-HardwareAcceleratedGPUScheduling_BreakTest.ps1` (1 breaks) |

**Purpose.** Four steps: OS build check, GPU driver WDDM version (report), HAGS registry state (sets `HwSchMode = 2`), pending reboot flag (report).

**Test steps**

1. Break: `Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -Value 1 -Type DWord` (or remove the value).
2. Run. Expect `[Failed ] HAGS Registry State: HAGS is disabled (HwSchMode = 1). Will enable. -> Remediation ran`, `[Warning] Pending Reboot Flag: Reboot pending for: HAGS enabled ...`, exit `1` this run. On the VM also expect `[Warning] GPU Driver WDDM Version` for the VMware SVGA driver.
3. Verify `(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers').HwSchMode` is `2`. On real hardware reboot and check Settings > System > Display > Graphics > Default settings.
4. Restore: set the value back to the baseline.

**Status:** `PASS - LAB` + `PASS - UEM`, Full Pass. Break test run 61f9d608ba6d on 2026-11-02 (elevated, lab VM `CBRADLEYSWIN11`): HagsRegistryState (HwSchMode set to 1, script 1.0.2 set it back to 2 and exited 0); machine restored. Result `C:\Temp\FixReport\Enable-HardwareAcceleratedGPUScheduling\61f9d608ba6d.json`. UEM sweep `6c8405` (2026-10-29) `Completed` on both devices.

**Review notes.** Step 4 treats `HwSchMode = 2` as "reboot pending" forever, so the script warns on every run after enabling. Writes the value even when no capable GPU was found. Uses `Get-WmiObject` (PS 5.1 only).

### 5.8 `Restart-WindowsUpdateServices.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\ProcessManagement\Restart-WindowsUpdateServices.ps1`, v1.6.1.0 |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | none (`$ForceRestart = $true` hard-coded) |
| Prerequisites | `wuauserv`, `bits`, `cryptsvc`, `msiserver` |
| Automated coverage | `ProcessManagement\_AutomatedTesting\Restart-WindowsUpdateServices_BreakTest.ps1` (4 breaks) |

**Purpose.** Stops and starts all four services unconditionally, then exits `1` if any is not running.

**Test steps**

1. Break: `Stop-Service wuauserv,bits -Force`.
2. Run. Expect `[nnnn] wuauserv stopped.` / `started.` for each, `SUCCESS. 4 of 4 service(s) running.`, exit `0`.
3. Failure path: `Set-Service wuauserv -StartupType Disabled; Stop-Service wuauserv`. Run, expect `FAILED. Only 3 of 4 service(s) are running after remediation.`, exit `1`. Restore with `Set-Service wuauserv -StartupType Manual`.
4. Verify `Get-Service wuauserv,bits,cryptsvc,msiserver | Select Name,Status` all Running. Note `msiserver` is left running where it is normally stopped.

**Status:** `PASS - LAB` + `PASS - UEM`, Full Pass. Break test run 3cbd00c57db4 on 2026-11-02 (elevated, lab VM `CBRADLEYSWIN11`): BitsStopped and WuauservStopped (both services stopped, script restarted both); machine restored. Result `C:\Temp\FixReport\Restart-WindowsUpdateServices\3cbd00c57db4.json`. UEM sweep `6c8405` (2026-10-29) `Completed` on both devices.

**Review notes.** Overlaps with the Windows Update DataStore and service steps in `Invoke-AutoRemediateWindowsUpdates.ps1` (the header says so). Non-ASCII box-drawing and em dash characters in comments and one output string; the file has a BOM so it decodes correctly, but a stripped copy would not. `-ErrorAction Continue` inside `Try` means stop/start failures print `stopped.`/`started.` anyway. `Stop-Service -Force` on `cryptsvc` and `bits` stops dependents that are never restarted.

### 5.9 `Restart-WinProcess.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\ProcessManagement\Restart-WinProcess.ps1` |
| Inventory | `3) Complete - Needs Testing`, impact High |
| Inputs | **REQUIRED UEM variable** `FileDescription` (exit 1 without it); optional `StartService` |
| Prerequisites | A process whose file description matches |
| Automated coverage | `uem-tests.json` skip (needs variables) |

**Purpose.** Force-kills processes whose `Description` contains the given text, optionally relaunching.

**Test steps**

1. `Start-Process notepad; $env:FileDescription = 'Notepad'; $env:StartService = 'false'`. Run. Expect `Stopping process 'Notepad' (PID: n)...`, exit `0`, Notepad gone.
2. Run again with nothing running. Expect `No running process matches description '*Notepad*'. Nothing to do.`, exit `0`.
3. `Start-Process notepad; $env:StartService = 'true'`. Run. Expect the stop line, `Starting process '<path>\Notepad.exe'...`, exit `0`, exactly one new Notepad instance.
4. Clear `$env:FileDescription`. Run. Expect `Error: FileDescription is not specified.`, exit `1`.

**Status:** `TESTED - MANUAL` (2026-10-29, v1.1.0, all four steps above passed on the lab VM, non-elevated). UEM run `17a0a0` (2026-10-30, `FileDescription = Google Chrome`, `StartService = true`, high-impact gate lifted): `Completed` on `CBRADLEYSWIN11` and every Chrome PID changed, so the kill and relaunch work under Hub. `CHASEWIN11_2` was offline for the run. The relaunched Chrome processes are all in session 0 (SYSTEM), invisible to the user; see the review note.

**Review notes.** Confirmed under UEM 2026-10-30: with `StartService = true` the relaunch runs as SYSTEM in session 0, so an interactive application disappears from the user's desktop and SYSTEM-owned copies linger until reboot. Use `StartService` only for background processes, and use `Restart-WinProcessGraceful.ps1` (interactive watchdog task) for user applications. Fixed: `$ProcessName` was never assigned, so every match ended in exit `1` without stopping anything. Processes are now stopped by Id, relaunch uses the recorded executable path, and `StartService` is parsed as a boolean string (`'false'` was previously true). Still a force-kill with no save prompt by design.

### 5.10 `Restart-WinProcessGraceful.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\ProcessManagement\Restart-WinProcessGraceful.ps1`, v2.2.0 (reviewed at 2.1.0) |
| Inventory | `4) Complete - Tested` (Needs Testing until 2.2.0 passed the running-process break on 2026-11-05), impact High |
| Inputs | **REQUIRED UEM variable** `FileDescription` (exit 1 without it); `GracefulTimeoutSec` (15), `Restart`, `ForceOnlyIfUnresponsive` (true), `UnresponsiveSampleCount` (3), `UserActionRetryCount` (1), `UserActionRetryDelaySec` (300), `SkipIfUnsavedWork`, `Mode` (`Detached` default, `Inline`) |
| Prerequisites | Task Scheduler, an interactive user for hang detection, AV exclusion on `C:\ProgramData\AirWatch\Extensions\ProcessGraceful` |
| Automated coverage | `uem-tests.json` skip (needs variables) |

**Purpose.** Launcher that writes a watchdog script and dispatches it as a scheduled task in the user's session. The watchdog asks matching processes to close, force-kills only processes confirmed hung, retries after a delay, optionally relaunches, and writes `state\result.json` plus a DEXRecords key.

**Test steps** (launch from `pwsh.exe` so the launcher's own description does not match)

1. Graceful close: `Start-Process notepad; $env:FileDescription='Notepad'; $env:Mode='Inline'; $env:GracefulTimeoutSec='10'; $env:UserActionRetryCount='0'`. Run. Expect `Watchdog finished inline with exit code 0.`, Notepad gone, `result.json` with `Outcome = ClosedGracefully`.
2. User action required: type text in Notepad first (title becomes `*Untitled`), same run. Expect `UserActionRequired`, Notepad still open. Add `$env:SkipIfUnsavedWork='True'` and expect `UnsavedWorkSuspected`.
3. Hung process (as the logged-on admin, not SYSTEM): start a PowerShell window that shows a form and sleeps, set `$env:FileDescription='Windows PowerShell'`, run. Expect `ForceKilled` after the unresponsive samples.
4. Detached path: clear `$env:Mode`, run via `PsExec64 -s` or UEM. Expect `Watchdog dispatched as scheduled task 'WS1_ProcessGracefulWatchdog' (User context).`, exit `0`, then read `C:\ProgramData\AirWatch\Extensions\ProcessGraceful\state\result.json` for the real outcome.
5. Verify `Get-ScheduledTask WS1_ProcessGracefulWatchdog` returns nothing after completion (2.2.0: the watchdog unregisters it when its token allows, otherwise Task Scheduler deletes it a minute after the end boundary, about 9.5 min at defaults, and `watchdog.log` says which); `Get-ItemProperty 'HKLM:\Software\AirWatch\Extension\DEXRecords\ProcessGraceful'` shows `Status = Completed` and counts when the watchdog ran as SYSTEM, or `Status = Dispatched` with the `LastResult*` values filled in by the next launcher run when it ran as the user.
6. Restore: delete the ProcessGraceful folder and registry key.

**Status:** `PASS - LAB` (break test `Restart-WinProcessGraceful_BreakTest.ps1`, 2026-11-02, runs `909a4e0e2236`, `bdd6b5d9ba62`, `fc7b3529f3ab`: Character Map launched as the signed-in user, closed gracefully by the watchdog, relaunched or not as configured, no-match path reported; see 13.1 and 13.2.p) and `PASS - UEM` on one device. UEM run `fb2f21` (2026-10-30, `FileDescription = Google Chrome`, `Restart = true`, `GracefulTimeoutSec = 15`, high-impact gate lifted): `Completed` on `CBRADLEYSWIN11`; the watchdog log in `%ProgramData%\AirWatch\Extensions\ProcessGraceful\state\` shows all 10 Chrome processes closed gracefully (`matched=10 graceful=10 forced=0 userpending=0`), Chrome restarted from its original path in the user session, `result.json` written, task "unregistered" by the log although it was still registered on 2026-11-02 (13.2.p item 2). `CHASEWIN11_2` was offline for the run. 2.2.0 (2026-11-05) fixes the six 13.2.p items; parse-clean, 31,131 characters, the expiring-trigger registration proven with a probe task on this VM; the break-test reruns `40a560a2b4d3` (2026-11-05 13:25, ProcessNotRunning) and `1ac93c400483` (13:35, pinned ProcessRunningRestart) both Passed: the task started from its trigger 5 s after registration, Notepad was closed gracefully and relaunched, `result.json` carried the new `InaccessibleCount`, and the watchdog logged the honest "HKLM mirror skipped" line; the harness cut the watchdog off during its self-cleanup (13.2.p) and now waits for it. Results `C:\Temp\FixReport\Restart-WinProcessGraceful\40a560a2b4d3.json` and `1ac93c400483.json`. Full Pass on 2.2.0; a UEM rerun with the Chrome variables would show the `LastResult*` mirror on its second run.

**Review notes.** In Detached mode exit `0` proves dispatch only. `PID<n>_Result` registry values accumulate forever. Inline mode can exceed the 60-second Hub timeout. With no console user (RDP only) the watchdog runs as SYSTEM, never detects hangs and never force-kills.

### 5.11 `Restart-WinProcessGracefulEx.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\ProcessManagement\Restart-WinProcessGracefulEx.ps1` |
| Inventory | NOT IN CSV |
| Inputs | **REQUIRED UEM variable** `FileDescription` (exit 1 without it, since v0.9.1); `Restart` (default true), `GracefulTimeoutSec` (15), `WhatIf` |
| Prerequisites | Google Chrome running |
| Automated coverage | none |

**Purpose.** Earlier prototype retained for reference. Sends close to every Chrome process and relaunches Chrome 2 seconds later.

**Test steps.** `Start-Process notepad; $env:FileDescription='Notepad'; $env:Restart='true'; $env:GracefulTimeoutSec='10'`. Run. Expect `Graceful signal sent`, `Closed gracefully.`, `Summary: 1 graceful, 0 force-killed, 0 error(s).`, `Restarting: ...`, `Process restarted.`, exit `0`. With unsaved text in Notepad the close is refused; expect `Force-killed (still running after 10s).` or, with `$env:WhatIf='true'`, `WhatIf: would force-kill`.

**Status:** `NEEDS TEST`, UEM run recorded. Fixed 2026-10-29 (v0.9.1), parse-checked. Run through UEM against the single-VM group on 2026-11-02 (run `6caa9a`, Chrome open in the jspencer session, variables FileDescription=Google Chrome, GracefulTimeoutSec=15): `Failed (ScriptTimedOut 12007)` at the 30-second default timeout. The prototype does its whole wait, kill and relaunch inline (15 s graceful wait that cannot reach a window in another session from session 0, then force-kill, then wait for exit, then relaunch), which is longer than Hub allows. `Restart-WinProcessGraceful.ps1` dispatches the same work detached and reports at once, which is why it passed (`fb2f21`). Still a prototype superseded by that script; not a publication candidate and no fix planned.

**Review notes.** Fixed: hard-coded `"Chrome"` removed, `GracefulTimeoutSec` defined (env, default 15), counters updated, force-kill now happens through `ShouldProcess`, relaunch waits for the matched processes to exit, `--restore-last-session` only passed to `chrome.exe`.

### 5.12 `Restart-WinService.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\ProcessManagement\Restart-WinService.ps1`, v1.7.0.0 |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | **REQUIRED UEM variable** `ServiceName` (exit 1 without it; substring match on Name and DisplayName); optional `WhatIf` |
| Prerequisites | Target service |
| Automated coverage | `uem-tests.json` entry: `ServiceName = Spooler`, `WhatIf = ""` |

**Purpose.** Restarts (or starts) every service whose name or display name contains the text. Honours `ShouldProcess` through `$env:WhatIf`.

**Test steps**

1. Dry run: `Stop-Service Spooler -Force; $env:ServiceName='Spooler'; $env:WhatIf='true'`. Run. Expect `[nnnn] WhatIf: would start Print Spooler (Spooler).`, Spooler still stopped, exit `0`.
2. Live: clear `$env:WhatIf`, run. Expect `[nnnn] Print Spooler (Spooler) has been started.`, exit `0`. Run again with Spooler running and expect `... successfully restarted.`
3. Failure path: `Set-Service Spooler -StartupType Disabled; Stop-Service Spooler`, run, expect `Error, ... could not be started: ...` and exit `1`. Restore `Set-Service Spooler -StartupType Automatic; Start-Service Spooler`.
4. No match: `$env:ServiceName='NoSuchService'`, expect `Error: no service matched 'NoSuchService'.`, exit `1`.

**Status:** `PASS - UEM` for the healthy-machine run (UEM sweep `6c8405`, 2026-10-29: `Completed` on `CBRADLEYSWIN11` and `CHASEWIN11_2`, result file `test-result-scripts.json` in the connector folder) and `PASS - LAB` (break test `Restart-WinService_BreakTest.ps1`, 2026-11-02, runs `795e25b09857`, `27398be0af27`, `2ab15d7c8d96`: stopped Spooler restarted; stopped-and-disabled Spooler reported, not fixed; unknown name reported; see 13.1 and 13.2.n).

**Review notes.** Substring matching can hit many services (`Update` matches `wuauserv`, `UsoSvc`, `WaaSMedicSvc`, Edge and Google update services) and restarts all of them. `Stop-Service -Force` stops dependents without restarting them. Stop, 1-second pause and start of a slow service can exceed the 15-second timeout in the header.

### 5.13 `Invoke-AutoRemediateAppXBloat.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\WindowsLogon\Invoke-AutoRemediateAppXBloat.ps1`, v1.0.0 (header says 1.0.1) |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | `$env:DenyListExtra` (comma-separated patterns), `$env:RemoveForExistingUsers` (`true|1|yes|y`), `$env:WhatIf` |
| Prerequisites | DISM AppX cmdlets; SYSTEM |
| Automated coverage | `_AutomatedTesting\Invoke-AutoRemediateAppXBloat_BreakTest.ps1` (1 breaks) |

**Purpose.** Two steps: deprovision a curated deny list of consumer inbox AppX packages for future users; optionally remove them for existing users. A safelist (Calculator, Store, Photos, Terminal, Notepad, shell components, runtime frameworks) cannot be overridden.

**Test steps** (snapshot first; a stock Windows 11 image is already in the "broken" state)

1. Confirm candidates: `Get-AppxProvisionedPackage -Online | Where-Object DisplayName -in 'Microsoft.BingWeather','Microsoft.MicrosoftSolitaireCollection','Clipchamp.Clipchamp'`.
2. Dry run: `$env:WhatIf='true'`, run. Expect the `[Failed ]` detection lines, `WhatIf run -- registry cache left untouched.` in `C:\Windows\Temp\UEM_AutoRemediateAppXBloat.log`, no registry change, exit `0`.
3. Live: clear `$env:WhatIf`, run. Expect `[Failed ] Deprovision Non-Essential AppX (Future Users): N provisioned package(s) match the deny list: ... -> Removal applied`, `Remediations applied: 1`, exit `0`.
4. Existing users: `$env:RemoveForExistingUsers='true'` with `Get-AppxPackage -AllUsers Microsoft.BingWeather` still present. Expect step 2 `-> Removal applied`.
5. Verify the packages are gone from both cmdlets; `HKLM:\Software\AirWatch\Extensions\AppXBloat\Remediation` shows `RemediationsRun = 1`, `RemediationErrors = 0`. Rerun prints `No matching packages are provisioned for new users`.
6. Re-arm for another run: revert the snapshot or point `$env:DenyListExtra='Microsoft.WindowsAlarms'` at a still-provisioned package.

**Status:** `PASS - LAB` + `PASS - UEM`, Full Pass. Break test run da4f55c3d6f8 on 2026-11-02 (elevated, lab VM `CBRADLEYSWIN11`): InstalledDenyListedPackage (loose `DEXTest.BloatProbe` full-trust package registered under Developer Mode with `DenyListExtra=DEXTest.*`; script 1.0.0 removed it and exited 0, and as 13.3 predicted also removed ten inbox consumer packages for every user on the VM; the first attempt f3daf194e657 failed in the fixture because Windows will not register a framework package that way); machine restored. Result `C:\Temp\FixReport\Invoke-AutoRemediateAppXBloat\da4f55c3d6f8.json`. UEM sweep `6c8405` (2026-10-29) `Completed` on both devices.

**Review notes.** `Remove-AppxPackage -AllUsers` commonly fails for in-use packages (0x80073CFA) and then the script exits `1`. Enumeration plus removal can exceed the 90-second header timeout. Version constant and header disagree. The Store can reinstall removed apps.

### 5.14 `Invoke-AutoRemediateFSLogixExclusions.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\WindowsLogon\Invoke-AutoRemediateFSLogixExclusions.ps1`, v1.0.0 |
| Inventory | `3) Complete - Needs Testing`, impact None |
| Inputs | `$env:WhatIf` |
| Prerequisites | FSLogix Apps (`frxsvc`), Defender cmdlets, `HKLM:\SOFTWARE\FSLogix\Profiles` or `ODFC` `VHDLocations` |
| Automated coverage | none |

**Purpose.** Three steps that add Microsoft's documented Defender exclusions for FSLogix processes, VHD paths (including each configured `VHDLocations` share) and `VHD`/`VHDX` extensions. Additive only.

**Test steps**

1. Without FSLogix the script prints a skip message and exits `0`. To test on the lab VM either install FSLogix Apps or simulate:
   ```powershell
   New-Service -Name frxsvc -BinaryPathName 'C:\Windows\System32\svchost.exe -k netsvcs' -StartupType Manual
   New-Item 'HKLM:\SOFTWARE\FSLogix\Profiles' -Force | Out-Null
   New-ItemProperty -Path 'HKLM:\SOFTWARE\FSLogix\Profiles' -Name VHDLocations -PropertyType MultiString -Value @('\\labfs\Profiles')
   Remove-MpPreference -ExclusionExtension VHD,VHDX -ErrorAction SilentlyContinue
   ```
2. Dry run with `$env:WhatIf='true'`; expect three `[Failed ]` lines and no change.
3. Live run. Expect `[Failed ] FSLogix Process Exclusions: Missing: ... -> Remediation applied`, same for Path and VHD Extension, `Remediations applied: 3`, exit `0`.
4. Verify `Get-MpPreference | Select -ExpandProperty ExclusionProcess` lists `frxccd.exe`, `frxccds.exe`, `frxsvc.exe`; `ExclusionPath` includes `C:\ProgramData\FSLogix\Cache\*` and `\\labfs\Profiles\*.VHDX`; `ExclusionExtension` has `VHD`, `VHDX`. Rerun prints `All 3 process exclusions present` and so on.
5. Restore: `sc.exe delete frxsvc`, `Remove-Item HKLM:\SOFTWARE\FSLogix -Recurse`, `Remove-MpPreference` for each added item.

**Status:** `NEEDS TEST - PRODUCT VM` (simulation above is acceptable for logic validation). Also `Completed` on both lab devices in UEM sweep `6c8405` (2026-10-29).

**Review notes.** Tamper Protection or Intune-managed exclusions (`DisableLocalAdminMerge`) make `Add-MpPreference` fail or be ignored, giving a perpetual Failed. Under SYSTEM `$env:TEMP` equals `C:\Windows\Temp`, so two path entries duplicate. Version constant and header disagree.

### 5.15 `Invoke-AutoRemediateLogonTaskContention.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\WindowsLogon\Invoke-AutoRemediateLogonTaskContention.ps1`, v1.0.3 (reviewed at 1.0.0) |
| Inventory | `3) Complete - Needs Testing`, impact Low |
| Inputs | `$env:MinDelaySeconds` (60), `$env:StaggerSeconds` (30), `$env:TaskVolumeWarnCount` (8), `$env:WhatIf` |
| Prerequisites | ScheduledTasks module |
| Automated coverage | `_AutomatedTesting\Invoke-AutoRemediateLogonTaskContention_BreakTest.ps1` (2 breaks) |

**Purpose.** Two steps: raise and stagger the `Delay` on AtLogOn triggers of enabled non-Microsoft tasks (`PT1M`, `PT1M30S`, ...); warn when too many such tasks exist.

**Test steps**

1. Break:
   ```powershell
   $a = New-ScheduledTaskAction -Execute cmd.exe -Argument '/c exit'
   $t = New-ScheduledTaskTrigger -AtLogOn
   $p = New-ScheduledTaskPrincipal -GroupId 'BUILTIN\Users'
   1..2 | ForEach-Object { Register-ScheduledTask -TaskName "LabLogonTask$_" -TaskPath '\LabVendor\' -Action $a -Trigger $t -Principal $p }
   ```
   Use `1..9` to also trip the volume warning.
2. Dry run with `$env:WhatIf='true'`; expect `[Failed ] AtLogOn Task Trigger Delay: 2 of 2 task(s) need a delay: \LabVendor\LabLogonTask1 -> +60s, ...` and no change.
3. Live run. Expect `-> Delay(s) applied`, `[Passed ] AtLogOn Task Volume: 2 tasks trigger AtLogOn, below the 8 warn threshold`, exit `0`.
4. Verify `(Get-ScheduledTask -TaskPath '\LabVendor\').Triggers | Select Delay` shows `PT1M` and `PT1M30S`; registry `HKLM:\Software\AirWatch\Extensions\LogonTaskContention\Remediation` has `TasksDelayed = 2`. Rerun prints `All 2 qualifying task(s) already have at least a 60 second delay`.
5. Restore: `Get-ScheduledTask -TaskPath '\LabVendor\' | Unregister-ScheduledTask -Confirm:$false`.

**Status:** `PASS - LAB` + `PASS - UEM`, Full Pass. Break test run 43252617a969 on 2026-11-02 (elevated, lab VM `CBRADLEYSWIN11`): a fixture logon task registered with no delay was given +60 s by script 1.0.0, and three volume fixtures took the host to 12 qualifying AtLogOn tasks (Edge update, five per-user OneDrive startup tasks, Google updater, Workspace ONE SfdAgent, the fixtures), which the script reported as a Warning against the threshold of 8, recorded as `QualifyingTaskCount = 12` and left untouched (every fixture still enabled with its 90 s delay); exit 0; machine restored. Result `C:\Temp\FixReport\Invoke-AutoRemediateLogonTaskContention\43252617a969.json`. Three earlier attempts the same day were harness faults (13.5). UEM sweep `6c8405` (2026-10-29) `Completed` on both devices. Rerun on 1.0.3 (13.2.i) `f3dba3f5c473` 2026-11-05 11:29, elevated, 5.5 s: the no-delay fixture was repaired through the rewritten parser, and the volume break (17 folders, 32 tasks, 12 qualifying against 8) was reported with the fixtures untouched and the script's `QualifyingTaskCount = 12` matching the harness; machine restored. Result `C:\Temp\FixReport\Invoke-AutoRemediateLogonTaskContention\f3dba3f5c473.json`.

**Review notes.** The ISO 8601 parser handles only `PT#H#M#S`; a delay stored as `P0DT0H1M0S` or `P1D` parses as 0 and can be lowered. `Set-ScheduledTask` fails for tasks with a stored password. Delaying vendor agents is user-visible.

### 5.16 `Invoke-AutoRemediateProfileBloat.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\WindowsLogon\Invoke-AutoRemediateProfileBloat.ps1`, v1.0.3 (reviewed at 1.0.0) |
| Inventory | `3) Complete - Needs Testing`, impact Low |
| Inputs | `$env:MinFileAgeDays` (7), `$env:MinSizeThresholdMB` (50), `$env:RoamingWarnMB` (500), `$env:HiveWarnMB` (100), `$env:WhatIf` |
| Prerequisites | `Win32_UserProfile`; SYSTEM to reach every profile |
| Automated coverage | `_AutomatedTesting\Invoke-AutoRemediateProfileBloat_BreakTest.ps1` (9 breaks; 2 drawn so far) |

**Purpose.** Nine steps across every non-special local profile: delete aged files from user Temp, browser caches, Teams caches, Explorer thumbnail and icon caches, crash dumps and WER reports, RDP and shader caches, Recent items and Jump Lists; report oversized Roaming AppData and oversized registry hives.

**Test steps** (as the test user, elevated)

1. Break:
   ```powershell
   $t = "$env:LOCALAPPDATA\Temp\labbloat"; New-Item $t -ItemType Directory -Force | Out-Null
   1..6 | ForEach-Object { $f = "$t\big$_.bin"; fsutil file createnew $f 10485760 | Out-Null; (Get-Item $f).LastWriteTime = (Get-Date).AddDays(-30) }
   1..600 | ForEach-Object { $f = "$env:APPDATA\Microsoft\Windows\Recent\lab$_.lnk"; New-Item $f -ItemType File -Force | Out-Null; (Get-Item $f).LastWriteTime = (Get-Date).AddDays(-30) }
   $env:RoamingWarnMB = '1'; $env:HiveWarnMB = '1'
   ```
2. Dry run with `$env:WhatIf='true'`; expect `[Failed ] User Temp Files: 60 MB in 6 file(s) older than 7 day(s)` and `[Failed ] Recent Items and Jump Lists: 600 file(s) ...` with nothing deleted.
3. Live run. Expect `-> Cleanup applied` on both, `[Warning]` on Roaming AppData and Registry Hive, `Reclaimed: 60 MB`, exit `0`.
4. Verify the `labbloat` files and `lab*.lnk` are gone; `HKLM:\Software\AirWatch\Extensions\ProfileBloat\Remediation` shows `ReclaimedMB = 60`, `CleanupsRun = 2`; log at `C:\Windows\Temp\UEM_AutoRemediateProfileBloat.log`.
5. Restore: clear the two env overrides.

**Status:** `PASS - LAB` + `PASS - UEM`, Full Pass. Break test run 2136e10ee79e on 2026-11-02 (elevated, lab VM `CBRADLEYSWIN11`, fixture profile `DEXTestBloat` loaded through a logon): an aged RDP bitmap cache and an aged classic Teams cache were planted past the size threshold, both verified, and script 1.0.0 cleared both while leaving the fresh control files, exit 0; machine restored. Result `C:\Temp\FixReport\Invoke-AutoRemediateProfileBloat\2136e10ee79e.json`. The run drew two of the nine breaks; the remaining seven (temp files, browser caches, Explorer icon cache, crash dumps, Recent items, and the two reported-only size checks) can be exercised with `-BreakName`. Three earlier attempts the same day were fixture faults (13.5). UEM sweep `6c8405` (2026-10-29) `Completed` on both devices. 1.0.3 (2026-11-05, 13.2.j): step 8 sizes `AppData\Roaming` with a budgeted .NET walk that stops at the threshold or after 90 s and reports a tree it could not size; profile paths are wildcard-escaped. WhatIf run on this VM: step 8 0.9 s across four profiles, `chase` reported "at least 533.5 MB". Break-test rerun on 1.0.3 `e446f8bd2e99` (2026-11-05 13:25, elevated, 8.4 s) Passed: CrashDumps and UserTempFiles planted in `DEXTestBloat`, both repaired, profile restored. Result `C:\Temp\FixReport\Invoke-AutoRemediateProfileBloat\e446f8bd2e99.json`.

**Review notes.** Step 7 deletes `CustomDestinations` and `AutomaticDestinations`, which hold user-pinned Jump List items (not pure cache). Deleting `WER\ReportQueue` discards un-uploaded crash reports. Steps 1 to 7 still walk their cache folders twice (measure, then delete), but those folders are bounded; the unbounded walk of step 8 is budgeted since 1.0.3.

---

### 5.17 `Invoke-AutoRemediateTimeSync.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\SystemHealth\Invoke-AutoRemediateTimeSync.ps1`, v1.0.1 (2026-11-03: two-stage resync, queued with rediscovery then blocking; `ResyncWaitSeconds` default 20; step 4 reports a Warning instead of a false "offset 0" when there is no source) |
| Inventory | `3) Complete - Needs Testing`, impact Low |
| Inputs | `$env:KerberosMaxSkewSeconds` (300), `$env:StaleSyncWarnSeconds` (86400), `$env:ConfigureWorkgroupNtp` (false), `$env:WorkgroupNtpServer` (`time.windows.com,0x9`), `$env:AllowLargeCorrection` (true), `$env:ResyncWaitSeconds` (20, range 6 to 45), `$env:WhatIf` |
| Prerequisites | W32Time installed; elevation for `w32tm /resync` and `/config`; skips with exit 0 on a domain controller |
| Automated coverage | `_AutomatedTesting\Invoke-AutoRemediateTimeSync_BreakTest.ps1` (W32TimeService fixed; WorkgroupNoPeer reported only, skipped on a domain member) |

**Purpose.** Five steps: W32Time service state and start type; time source configuration (domain hierarchy on a member, a Warning on a workgroup device unless `ConfigureWorkgroupNtp` is set); clock synchronisation (forces a resync when the clock is unsynchronised or stale); clock offset against the Kerberos skew limit (lifts the phase-correction limit for one resync when the clock is too far out, then restores it); hypervisor time sync conflict (report only).

**Test steps** (elevated)

1. Break: stop W32Time and set it to Disabled, or set `HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters\Type` to `NoSync` on a workgroup device.
2. Dry run with `$env:WhatIf='true'`; expect `[Failed ] W32Time Service` or `[Warning] Time Source Configuration` with `What if:` lines and no change.
3. Live run. Expect `-> Remediated` on the failed step, `Clock: synchronised=True` in the footer, exit `0`.
4. Verify `HKLM:\Software\AirWatch\Extensions\TimeSync\Remediation` and `HKLM:\Software\AirWatch\Extension\DEXRecords\SystemHealth\TimeSync`; log at `C:\Windows\Temp\UEM_AutoRemediateTimeSync.log`.
5. Restore: the harness restores the captured service state and `Type`.

**Status:** `PASS - LAB`. Break test run `017c7d370050` on 2026-11-03 13:25 (elevated, `CBRADLEYSWIN11`): W32TimeService broken with StoppedManualOrDisabled and repaired to Running/Manual; WorkgroupNoPeer (`Type=NoSync`) reported as a Warning and left alone. Two earlier runs (`3042d520cb84`, 12:37, and the 12:40 cert run) returned `FalsePass` on the report-only break because the harness compared with `-like "[Warning] ..."`, which PowerShell reads as a character class; both harnesses now use a literal prefix match. The harness restart left W32Time on `Local CMOS Clock` with its next poll 4.5 hours out (the NTP client's `SpecialPollInterval` on this device), so the 2026-11-03 13:28 WhatIf run correctly showed step 3 `Failed`; the live elevated run on 2026-11-04 09:02 remediated it in one pass (`Clock Offset: Offset 0.017 s from 'time.windows.com,0x9'`, 4 Passed, 1 Failed then remediated; this family exits 1 only when a resolution block throws, so the run exited 0). UEM run `b30cc7` on 2026-11-04 10:30 (Test_Treddy, with the BitLocker and cert scripts) ended NoResult on both VMs within 5 minutes and left no trace on `CBRADLEYSWIN11` (no script log, no DEXRecords, nothing in the Hub executor log). Hub-side cause on this VM: its LiteDB store has failed on every open since 08:44 local ("The process cannot access the file because it is being used by another process" in the DSM, TaskScheduler and Workflow logs; the workflow scheduler logs "Started blocked workflow sync" and runs nothing). Three minutes earlier ESENT logged "cannot write to the log drive" for `secedit.sdb` and the SRU store, after the VM resumed at 08:31 with a four-minute clock jump, so a transient guest I/O failure broke the store and the Hub health monitor did not repair it. The other session's 10:20 sensor run (`d38733`) failed the same way. Fix (the user, 10:50): `Restart-Service AirwatchService` does not clear it; killing the Hub main process `TaskScheduler.exe` does, and the service respawns it with a clean store (lock errors stopped at once, the new process handled workflow events within minutes). `CHASEWIN11_2` was unreachable for a different reason: its clock was skewed after the host resume, and the user ran this script on it by hand, which repaired it. That is the first real product-path use of the time sync remediation. The rerun `e76ada` (11:06) was Completed on `CHASEWIN11_2` (104 s after sync) but NoResult here: Hub's Workflow log shows all three steps failing with `PowerShellExecutor timed out` before the scripts wrote a first log line, with 0.2 GB of RAM free on this 8 GB guest (VS Code about 1.8 GB, Defender 330 MB), so PowerShell 7 could not start inside the 60 s budget. After a VM restart, run `ffaad1` (12:43) was Completed on both devices 207 s after sync. On this VM the clock was back on `Local CMOS Clock` after the restart and the script resynced it as SYSTEM under Hub: DEXRecords `ScriptVersion 1.0.1`, `Step03_ClockSynchronization = [Remediated]`, `Step04 = Offset 0.075 s from 'time.windows.com,0x9'`, 4 Passed, 1 Remediated, `w32tm` showing a good sync at 12:43:54. The log also shows a first attempt at 12:42:44 that stops after step 2 before the complete run at 12:43:40, so Hub started the step twice in that sync. `PASS - LAB` + `PASS - UEM`: Full Pass, inventory `4) Complete - Tested`.

**Review notes.** On a workgroup device W32Time can sit on `Local CMOS Clock` for hours after a service restart: it reaches the peer once, does not select it, and waits for the special poll interval. Only a resync moves it, which is why step 3 is a Failed-and-fix rather than a Warning. Step 1 treats Manual as normal on a workgroup device (trigger start) and Disabled as a fault anywhere.

---

### 5.18 `Invoke-AutoRemediateBitLockerProtection.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\SystemHealth\Invoke-AutoRemediateBitLockerProtection.ps1`, v1.0.0 |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | `$env:EscrowRecoveryKey` (false), `$env:IncludeDataVolumes` (true), `$env:WhatIf` |
| Prerequisites | BitLocker module; elevation (`Get-BitLockerVolume` fails without it and the script exits 1); an encrypted volume, else exit 0 with "No BitLocker-encrypted volumes found" |
| Automated coverage | none. A break test would have to suspend protection on a fully encrypted volume, so this stays a manual test on a machine that already has one |

**Purpose.** Three steps: resume protection on fully encrypted OS and fixed data volumes left suspended (deferred while an update reboot count or a pending reboot is in place, to avoid a recovery prompt at boot); resume a paused encryption; report volumes with no recovery password protector and, with `EscrowRecoveryKey`, back the key up to Entra ID or AD.

**Test steps** (elevated, on a machine with an encrypted OS volume, after confirming the recovery key is escrowed)

1. Break: `Suspend-BitLocker -MountPoint C: -RebootCount 0`.
2. Dry run with `$env:WhatIf='true'`; expect `[Failed ] Suspended Protection: C: ...` with a `What if:` line and `Get-BitLockerVolume C:` still showing `ProtectionStatus Off`.
3. Live run. Expect `-> Remediated`, `ProtectionStatus On`, exit `0`.
4. Verify `HKLM:\Software\AirWatch\Extensions\BitLockerProtection\Remediation`; log at `C:\Windows\Temp\UEM_AutoRemediateBitLockerProtection.log`.
5. Deferral check: `Suspend-BitLocker -MountPoint C: -RebootCount 1`, run live, expect a Warning naming the reboots left and no resume. `Resume-BitLocker -MountPoint C:` to restore.

**Status:** `NEEDS TEST`. Only the no-encrypted-volume path has run (live, elevated, 2026-11-03 13:28 on `CBRADLEYSWIN11`: "No BitLocker-encrypted volumes found. Nothing to do.", exit 0). The lab VM has no encrypted volume. `PASS - UEM`: runs `e76ada` (11:06) and `ffaad1` (12:43) on 2026-11-04 were Completed on `CHASEWIN11_2`, whose C: is BitLocker-encrypted with a password protector, so the product path ran under Hub as SYSTEM and exited 0; `ffaad1` was also Completed on `CBRADLEYSWIN11` ("No encrypted volumes. Exiting without changes" at 12:43:44). Whether `CHASEWIN11_2` had anything to resume is not known from here; its DEXRecords `SystemHealth\BitLockerProtection` key holds the step results. No break test, so it stays `3) Complete - Needs Testing` under the Full Pass rule until a suspended-protection run is validated by hand (steps above).

---

### 5.19 `Invoke-AutoRemediateCertEnrollment.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\SystemHealth\Invoke-AutoRemediateCertEnrollment.ps1`, v1.0.1 (2026-11-03: CertificateServicesClient tasks are read, enabled and started through the Task Scheduler COM API; the CIM cmdlets cost 5 s per call on the lab VM and put the run over its 30 s budget) |
| Inventory | `3) Complete - Needs Testing`, impact Low |
| Inputs | `$env:ExpiringSoonDays` (30), `$env:RootSyncStaleDays` (90), `$env:ExpiredRootNoiseMax` (20), `$env:WhatIf` |
| Prerequisites | elevation to enable tasks and run `certutil -pulse`; `LocalMachine\My` readable |
| Automated coverage | `_AutomatedTesting\Invoke-AutoRemediateCertEnrollment_BreakTest.ps1` (AutoenrollmentTask fixed; ExpiredCertificate and WeakAlgorithmCertificate reported only, planted as self-signed `CN=DEXTest ...` certificates in `LocalMachine\My` and removed by thumbprint on restore) |

**Purpose.** Five steps: re-enable disabled CertificateServicesClient tasks; machine certificate expiry (triggers autoenrollment when a certificate issued from an AD CS template is expired or expiring, reports others with subject and template); MD5 or SHA-1 signed machine certificates (report only); AuthRoot auto-update disabled or stale (report only); AD CS autoenrollment policy flags (report only, not applicable off-domain).

**Test steps** (elevated)

1. Break: `Disable-ScheduledTask -TaskPath '\Microsoft\Windows\CertificateServicesClient\' -TaskName SystemTask`, and plant an expired self-signed certificate in `Cert:\LocalMachine\My` (`New-SelfSignedCertificate -Subject 'CN=DEXTest Expired' -NotAfter (Get-Date).AddDays(-2) -CertStoreLocation Cert:\LocalMachine\My`).
2. Dry run with `$env:WhatIf='true'`; expect `[Failed ] Autoenrollment Tasks` with a `What if:` line and `[Warning] Machine Certificate Expiry` naming the planted subject.
3. Live run. Expect `-> Remediated` on the task step, the Warning unchanged, exit `0` (this family exits 1 only when a resolution block throws).
4. Verify the task is enabled; `HKLM:\Software\AirWatch\Extensions\CertEnrollment\Remediation`; log at `C:\Windows\Temp\UEM_AutoRemediateCertEnrollment.log`.
5. Restore: remove the planted certificate by thumbprint.

**Status:** `PASS - LAB`. Break test run `2df122ace6f8` on 2026-11-03 13:28 (elevated, `CBRADLEYSWIN11`): WeakAlgorithmCertificate (sha1RSA) and ExpiredCertificate both verified, both reported, both left in place, removed by restore. The earlier run `a509cfb91722` (12:40) was the `FalsePass` harness bug described in 5.17. Run `e1cfd894147c` on 2026-11-04 10:13 drew AutoenrollmentTask (SystemTask disabled; the script re-enabled it through the COM API, `-> Remediated`, exit 0, 3.8 s) together with WeakAlgorithmCertificate (reported, left in place), so every break in the harness has now passed. The 2026-11-03 13:29 WhatIf run on 1.0.1 took 5 s against 4 machine certificates and 6 tasks. `PASS - UEM`: run `e76ada` (2026-11-04 11:06) Completed on `CHASEWIN11_2`, run `ffaad1` (12:43) Completed on both devices 208 s after sync; DEXRecords on `CBRADLEYSWIN11` show `ScriptVersion 1.0.1`, 5 Passed, 0 Warnings, so the Task Scheduler COM path works under Hub's PowerShell 7 as SYSTEM. `PASS - LAB` + `PASS - UEM`: Full Pass, inventory `4) Complete - Tested`.

---

## 6. Application-specific scripts

Seventeen step-engine scripts under `ApplicationSpecific\`. Shared behaviour: `-> Remediation ran` means the resolution block returned without throwing, not that the fix worked; a step that is `Failed` and then remediated still exits `1` on that run because there is no re-detect. The five end-user application scripts (Chrome, OneDrive, Outlook, Teams, Zoom) resolve the logged-on user through `Win32_ComputerSystem.UserName` and work on `C:\Users\<user>` and `HKEY_USERS\<SID>`, so they need a console user even when run as SYSTEM. Boolean `$env:` inputs go through `[Convert]::ToBoolean`, so a value like `banana` throws at parameter binding.

Only Chrome and OneDrive are installed on the lab VM. Outlook, Teams and Zoom are detected by file presence, so a copied `cmd.exe` placed at the detection path is enough to exercise the step logic (noted per script). SCCM and SCOM need product VMs; a registry-and-file fixture exercises the guards and most report-only steps.

### 6.1 `Invoke-AutoRemediateChrome.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\Chrome\Invoke-AutoRemediateChrome.ps1`, v1.0.1 |
| Inventory | `3) Complete - Needs Testing`, impact Low |
| Inputs | `$env:CacheSizeWarningMB` (500), `$env:ExtensionCountWarning` (20), `$env:AllowDestructiveActions` (reserved, gates nothing) |
| Prerequisites | Chrome installed (else `[Skipped]`, exit 0); console user |
| Automated coverage | `_AutomatedTesting\Invoke-AutoRemediateChrome_BreakTest.ps1` (4 breaks) |

**Purpose.** Six steps: Chrome Cache Bloat (clears `Cache` and `Code Cache` when Chrome is closed), Extension Count (report), Google Update Service Health (report), Enterprise Policy Check (report), GPU / Renderer Crash Loop (report), Stale NativeMessaging Hosts (removes keys whose manifest file is gone). Writes `HKLM:\Software\AirWatch\Extension\DEXRecords\ChromeErrors`.

**Test steps** (lab VM, user logged on, Chrome closed, run as SYSTEM via `PsExec64 -s`)

1. Break:
   ```powershell
   $u = 'C:\Users\<user>\AppData\Local\Google\Chrome\User Data\Default'
   fsutil file createnew "$u\Cache\bloat.bin" 600000000
   1..20 | ForEach-Object { New-Item -ItemType Directory "$u\Extensions\$('a'*31)$([char](97+$_%16))" -Force | Out-Null }
   sc.exe config gupdate start= disabled
   New-Item HKLM:\SOFTWARE\Policies\Google\Chrome -Force | Out-Null; Set-ItemProperty HKLM:\SOFTWARE\Policies\Google\Chrome UpdateDefault 2 -Type DWord
   1..5 | ForEach-Object { New-Item -ItemType File "C:\Users\<user>\AppData\Local\Google\Chrome\User Data\Crashpad\reports\test$_.dmp" -Force | Out-Null }
   New-Item 'HKLM:\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.test.orphan' -Force | Set-ItemProperty -Name '(default)' -Value 'C:\nonexistent\manifest.json'
   ```
2. Run. Expect `[Warning] Chrome Cache Bloat: Chrome cache is 572MB (threshold: 500MB) ... -> Remediation ran`, `[Warning]` for Extension Count, Google Update Service Health, Enterprise Policy Check and Crash Loop with no remediation note, `[Warning] Stale NativeMessaging Hosts: 1 orphaned ... com.test.orphan. -> Remediation ran`, exit `0`.
3. Verify the two cache folders are empty, the orphan key is gone, and `Get-ItemProperty HKLM:\Software\AirWatch\Extension\DEXRecords\ChromeErrors` shows `Step06_StaleNativeMessagingHosts = [Remediated] ...`. Rerun shows `Chrome cache is 0MB`.
4. Chrome running: expect `-> Remediation ERROR: Chrome is running -- cache folders are locked...` on step 1.
5. Restore: `sc.exe config gupdate start= delayed-auto`, remove the policy key and value, delete the fake extension folders and crash reports.

**Status:** `PASS - LAB` + `PASS - UEM`, Full Pass. Break test run ea3f7e8bbf4f on 2026-11-02 (elevated, lab VM `CBRADLEYSWIN11`): CacheBloat (80 MB planted in Cache and Code Cache, cleared) and OrphanedNativeMessagingHost (WOW6432Node key pointing at a missing manifest, pruned); machine restored. Result `C:\Temp\FixReport\Invoke-AutoRemediateChrome\ea3f7e8bbf4f.json`. UEM sweep `6c8405` (2026-10-29) `Completed` on both devices.

**Review notes.** No step returns `Failed` by design, so exit `1` only follows a detection exception. Step 6 reads `HKCU:` which under SYSTEM is the SYSTEM hive, unlike the `HKU\<SID>` approach used elsewhere. Recursive cache sizing can be slow on very large caches.

### 6.2 `Invoke-AutoRemediateOneDrive.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\Microsoft\OneDrive\Invoke-AutoRemediateOneDrive.ps1`, v1.0.1 |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | `$env:AllowDestructiveActions` (reserved, unused) |
| Prerequisites | OneDrive.exe present (else `[Skipped]`); resolvable user SID; `FileSyncHelper` service |
| Automated coverage | `_AutomatedTesting\Invoke-AutoRemediateOneDrive_BreakTest.ps1` (5 breaks) |

**Purpose.** Five steps: Auto-start / Process Health (restores the `Run` key and starts OneDrive in the user session via a temporary scheduled task), Account Sign-in State (report), Sync Error Detection (report), Files On-Demand Service (starts `FileSyncHelper` unless Disabled), Known Folder Move Status (report). Writes `...\DEXRecords\OneDriveErrors`.

**Test steps** (lab VM, user logged on, run as SYSTEM)

1. Break as the user: `Stop-Process -Name OneDrive -Force; Remove-ItemProperty HKCU:\Software\Microsoft\Windows\CurrentVersion\Run -Name OneDrive`. Elevated: `Stop-Service FileSyncHelper`. Optional sync-error event: `New-EventLog -LogName Application -Source OneDriveLabTest; Write-EventLog -LogName Application -Source OneDriveLabTest -EntryType Error -EventId 100 -Message 'OneDrive sync test error'`.
2. Run. Expect `[Failed ] OneDrive Auto-start / Process Health: OneDrive is not running and the auto-start Run key is missing. ... -> Remediation ran`, `[Warning] Sync Error Detection ...`, `[Warning] Files On-Demand Service: FileSyncHelper service is not running ... -> Remediation ran`, exit `1` this run (Failed counted before remediation), `0` on rerun.
3. Verify `Get-Process OneDrive -IncludeUserName` shows the process in the user's session, the `Run` value is back, `(Get-Service FileSyncHelper).Status` is Running, and `Get-ScheduledTask DEX-TempStartOneDrive` returns nothing.
4. Disabled service path: `Set-Service FileSyncHelper -StartupType Disabled`, rerun, expect `[Info] FileSyncHelper is Disabled -- skipping restart...`. Restore to Manual.
5. Restore: `Remove-EventLog -Source OneDriveLabTest`.

**Status:** `PASS - LAB` + `PASS - UEM`, Full Pass. Break test run 2dd3df491bfa on 2026-11-02 (elevated, lab VM `CBRADLEYSWIN11`): AutoStartAndProcess (OneDrive.exe stopped, script 1.0.2 relaunched it in the user session and exited 0) and KfmPolicyDrift (reported only, as designed); machine restored. Result `C:\Temp\FixReport\Invoke-AutoRemediateOneDrive\2dd3df491bfa.json`. UEM sweep `6c8405` (2026-10-29) `Completed` on both devices.

**Review notes.** Starting OneDrive is user-visible. Step 5 has two identical `if` branches; the second is dead code. Step 3 scans every Level-2 Application event in 24 hours with a wildcard on Message and can be slow.

### 6.3 `Invoke-AutoRemediateOutlook.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\Microsoft\Outlook\Invoke-AutoRemediateOutlook.ps1`, v1.1.2 (2026-11-05: step 3 reads the Application log through the .NET `EventLogReader`, 13.2.z; 1.1.1 on 2026-11-03: step 3 event query filtered inside the query hash; 1.1.0 on 2026-11-02: two-tier OST remediation and deferred Outlook close, see below; 1.0.2 fixes in 13.2.s) |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | `$env:CacheSizeWarningMB` (30720), `$env:AllowDestructiveActions` (gates steps 1 and 2) |
| Prerequisites | `OUTLOOK.EXE` under Office16 or a Click-to-Run configuration key (else `[Skipped]`); user SID and profile |
| Automated coverage | none |

**Purpose.** Five steps: Office Add-in Conflict (disables the first third-party add-in by setting `LoadBehavior = 0`, gated), OST Cache Size (renames the largest OST to `.bak`, gated), Exchange Sync Backlog (report), Office C2R Update Health (report, can be `Failed`), Outlook Profile Health (report). Writes `...\DEXRecords\OutlookErrors`.

**Test steps** (product VM; on the lab VM a `HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration` key with `VersionToReport = 16.0.1` is enough to pass detection)

1. Break:
   ```powershell
   New-Item "Registry::HKEY_USERS\<SID>\Software\Microsoft\Office\16.0\Outlook\Addins\Contoso.LabAddin" -Force | Set-ItemProperty -Name LoadBehavior -Value 3 -Type DWord
   $env:CacheSizeWarningMB = '100'; fsutil file createnew "C:\Users\<user>\AppData\Local\Microsoft\Outlook\labtest.ost" 157286400
   Set-ItemProperty HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration UpdatesEnabled 'False'   # note the original first
   ```
2. Run with `$env:AllowDestructiveActions` unset. Expect `[Warning] Office Add-in Conflict: ... -- set $AllowDestructiveActions=$true to apply.` and the same on OST Cache Size, no remediation notes, `[Failed ] Office C2R Update Health: C2R updates are disabled (UpdatesEnabled=False) ...`, exit `1`.
3. Run with `$env:AllowDestructiveActions='true'` and Outlook closed. Expect `-> Remediation ran` on steps 1 and 2; verify `LoadBehavior` is `0` and `labtest_<stamp>.bak` exists.
4. Restore: `UpdatesEnabled` back to `True`, delete the lab add-in key and the `.bak`, clear the env variables.

**Status:** Full Pass on 1.1.1. `PASS - LAB` (all seven breaks on 1.1.0 on 2026-11-03 08:26 to 08:55, three re-confirmed on 1.1.1 at 10:25; row 37 and 13.5 have the ids) against classic Outlook 16.0.18925 on the lab VM, and `PASS - UEM` on the product path (run `64af6b`, 13:37, Outlook open: 4 active steps, 3 Passed, 1 Warning, exit 0); `CHASEWIN11_2` has no Office (not-installed path). The FIX FIRST on step 3 (`Get-WinEvent` throws under Hub's engine and the step degraded to a Warning, 13.2.z, leaving the sync-backlog check inert in production) is closed in 1.1.2 (2026-11-05): the step reads the Application log through the .NET `EventLogReader` with the same seven-day, Level 1 to 3 filter and matches `*Outlook*` on the provider name in the loop. Proven on this VM under 5.1 and pwsh 7.5 (parse clean; the same reader form passed as probe form J under Hub in `07e3c1`), then under Hub: UEM run `4ea50e` (2026-11-05 11:46, Outlook open on `CBRADLEYSWIN11`) reported `Completed` on both devices, and the DEXRecords written at 11:46:57 show 4 steps, 3 Passed, 1 Warning, with step 3 now a real finding ("2 Outlook error event(s) in last 7 days") instead of the query failure. Full Pass on 1.1.2. The break test needs classic Outlook signed in (the new Outlook, `olk.exe`, is out of the script's scope and leaves no profile or OST). UEM sweep `6c8405` (2026-10-29) reported `Completed` on both lab devices when neither had Office, which proved only the not-installed path. Note for step 2 above: the gated step 1 Warning carries no "set $AllowDestructiveActions" hint; only step 2's does.

**1.1.0 design (approved 2026-11-02).** The OST rename is no longer the first remedy. Step 2 now has two tiers, both behind `$AllowDestructiveActions`: tier 1 lowers the user's "mail to keep offline" window (`Cached Mode\SyncWindowSetting`, `$env:OstSyncWindowMonths`, default 12) and stamps `OstTier1AppliedAt` in DEXRecords; it needs no close and the OST shrinks only after Outlook compacts it. Tier 2, the rename, fires only when tier 1 was applied at least `$env:OstTier2AfterDays` (7) days earlier, the OST is still over threshold and `$env:AllowOstRename` is true; it forces a full resync. If Outlook is open at tier 2, `$env:CloseOutlookForRepair` allows a deferred close: the SYSTEM script persists a helper under `C:\ProgramData\AirWatch\Extensions\Outlook\` (ACL locked to SYSTEM and Administrators, `state\` writable by users for the result) and registers a one-shot task as the signed-in user that shows a toast, waits `$env:OutlookCloseGraceSeconds` (300), closes Outlook through its main window, never force-kills, renames, relaunches and writes `state\result.json`; the next SYSTEM run copies the outcome into DEXRecords. UEM's `Completed` on that path proves the dispatch, and the result file is the evidence of the close. After the first deferred-close runs the helper re-sends the close request every 10 s for 60 s and records `CloseAttempts` in the result file, and the break test's Validate runs the script a second time to prove the production cleanup (task removed, outcome copied into DEXRecords). The script is 32,613 characters, 154 under the UEM limit, so the next change to it must free space first.

**Review notes.** Fixed in 1.0.2 (13.2.s): the blank single-object count, and step 4's Failed-with-false-promise for `UpdatesEnabled=False`, which exited 1 on every policy-managed device. Step 3's seven-day event query carries the provider and level filter inside the query hash since 1.1.1 (13.2.s). OST rename forces a full mailbox resync.

### 6.4 `Invoke-AutoRemediateTeams.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\Microsoft\Teams\Invoke-AutoRemediateTeams.ps1`, v1.0.3 (reviewed at 1.0.1) |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | `$env:CacheSizeWarningMB` (1024), `$env:AllowDestructiveActions` (gates steps 2 and 6) |
| Prerequisites | Classic Teams (`AppData\Local\Microsoft\Teams\Update.exe`) or New Teams (`Get-AppxPackage MSTeams`) |
| Automated coverage | none |

**Purpose.** Six steps: Teams Cache Bloat (clears six cache folders), Sign-in / Auth Token Cache (clears Cookies, Application Cache, Local Storage, gated), Teams Updater Stuck (kills `Update.exe` older than 30 minutes), Classic Teams Update Health (report, can be Failed), Teams Notification Settings (report), New Teams Package Registration (re-registers the AppX, gated). Steps 1 to 4 run only when Classic is detected. Writes `...\DEXRecords\TeamsErrors`.

**Test steps** (fake Classic install on the lab VM: `Copy-Item C:\Windows\System32\cmd.exe "C:\Users\<user>\AppData\Local\Microsoft\Teams\Update.exe"`)

1. Break:
   ```powershell
   $r = "C:\Users\<user>\AppData\Roaming\Microsoft\Teams"
   New-Item "$r\Cache","$r\Cookies" -ItemType Directory -Force | Out-Null
   fsutil file createnew "$r\Cache\bloat.bin" 1200000000
   1..3 | ForEach-Object { Add-Content "$r\logs.txt" '2026-10-28T10:00:00.000Z Err Failed to get token AADSTS50076' }
   New-Item "$r\Cookies\c.txt" -ItemType File | Out-Null
   1..3 | ForEach-Object { Add-Content "C:\Users\<user>\AppData\Local\Microsoft\Teams\SquirrelSetup.log" 'error: lab' }
   ```
2. Run without the flag. Expect `[Warning] Teams Cache Bloat ... -> Remediation ran`, `[Warning] Sign-in / Auth Token Cache: 3 auth failure pattern(s) ... Set $AllowDestructiveActions=$true to clear auth cache.`, `[Failed ] Classic Teams Update Health ...` with no remediation, exit `1`.
3. Run with `$env:AllowDestructiveActions='true'`. Expect step 2 `-> Remediation ran` and `Cookies` empty.
4. Stuck updater: copy `powershell.exe` to the `Update.exe` path, start it with `-Command Start-Sleep 7200`, wait 31 minutes, rerun. Expect `[Failed ] Teams Updater Stuck: ... (PID n, running 31min). -> Remediation ran` and the process gone.
5. Restore: delete the fake Teams folders.

**Status:** `NEEDS TEST - PRODUCT VM` (the fake-install path above validates the Classic steps on the lab VM). Also `Completed` on both lab devices in UEM sweep `6c8405` (2026-10-29). 1.0.3 (2026-11-05, 13.2.ee) gates step 6 properly; live run on `CBRADLEYSWIN11` unchanged (New variant, 2 steps Passed). A break test (one registry-only break, the notification override; the four Classic steps cannot be exercised on a New-Teams-only host without faking a Classic install) was written 2026-11-05 and awaits its elevated run.

**Review notes.** `Get-AppxPackage MSTeams` as SYSTEM returns only SYSTEM's packages, so New Teams is unlikely to be detected without `-AllUsers`, and `Add-AppxPackage -Register` as SYSTEM registers for SYSTEM. Step 6 prints `-> Remediation ran` even when it only printed the skip message, and returns Failed regardless of the flag. Step 4's `error|failed|exception` regex is loose.

### 6.5 `Invoke-AutoRemediateZoom.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\Zoom\Invoke-AutoRemediateZoom.ps1`, v1.0.2 (reviewed at 1.0.1) |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | `$env:CacheSizeWarningMB` (500), `$env:AllowDestructiveActions` (gates steps 4 and 5) |
| Prerequisites | `Zoom.exe` via App Paths, Program Files or `AppData\Roaming\Zoom\bin` |
| Automated coverage | none |

**Purpose.** Five steps: Zoom Cache / Log Bloat (clears `logs` and `data\cache`), Zoom Updater / Version Health (report), Outlook Add-in Conflict (report), Sign-in / SSO Token Cache (deletes auth, token, login, sso and credential files in `data`, gated), Camera / Webcam Permission (sets the Zoom `ConsentStore\webcam\NonPackaged` key to Allow, gated). Writes `...\DEXRecords\ZoomErrors`.

**Test steps** (fake install on the lab VM: `New-Item -ItemType Directory 'C:\Program Files\Zoom\bin' -Force; Copy-Item C:\Windows\System32\cmd.exe 'C:\Program Files\Zoom\bin\Zoom.exe'`)

1. Break:
   ```powershell
   $z = "C:\Users\<user>\AppData\Roaming\Zoom"
   New-Item "$z\logs","$z\data\cache" -ItemType Directory -Force | Out-Null
   fsutil file createnew "$z\logs\big.log" 600000000
   Add-Content "$z\logs\zoom.log" '2026-10-28 10:00:00 sign-in failed SSO error'
   New-Item "$z\data\zoom_token.db" -ItemType File | Out-Null
   New-Item HKLM:\SOFTWARE\Zoom\ZoomUpdate -Force | Set-ItemProperty -Name EnableAutoUpdate -Value 0 -Type DWord
   New-Item "Registry::HKEY_USERS\<SID>\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam\NonPackaged\C:#Program Files#Zoom#bin#Zoom.exe" -Force | Set-ItemProperty -Name Value -Value Deny
   ```
2. Run without the flag. Expect `[Warning] Zoom Cache / Log Bloat ... -> Remediation ran`, `[Warning] Zoom Updater / Version Health ...`, `[Warning] Sign-in / SSO Token Cache ...` and `[Warning] Camera / Webcam Permission ...` with no remediation, exit `0`.
3. Run with `$env:AllowDestructiveActions='true'`. Expect steps 4 and 5 `-> Remediation ran`; verify `zoom_token.db` is gone and the consent key `Value` is `Allow`.
4. Restore: remove the fake install, the Zoom folders, the `ZoomUpdate` key and the consent key.

**Status:** `NEEDS TEST - PRODUCT VM` (fake-install path validates logic on the lab VM). Also `Completed` on both lab devices in UEM sweep `6c8405` (2026-10-29). Zoom 7.2.5.51704 was installed machine-wide on `CBRADLEYSWIN11` (`C:\Program Files\Zoom\bin\Zoom.exe`, no App Paths entry) by 2026-11-05; 1.0.1 still printed `[Skipped] Zoom does not appear to be installed` (13.2.dd). 1.0.2 (2026-11-05) fixed the detection, and a non-elevated live run on the VM then executed all five steps (`Steps: 5 Version: 7.2.5.51704`, all Passed, the data and log folders being empty, exit 0; only the HKLM write was denied as expected outside SYSTEM). 1.0.3 the same day anchors the step 4 `401` pattern (13.2.ee). The break test (six breaks: CacheBloat fixed; UpdaterAutoUpdateDisabled, OutlookAddinCrashDisabled, SsoTokenCacheGated and WebcamDeniedGated reported; WebcamDenied fixed with the flag; full coverage needs three pinned passes because of the gated/ungated and shared-fixture exclusions) was written 2026-11-05 and awaits its elevated run.

**Review notes.** The regex term `401` matches any `401` substring. Step 5 triggers the per-app Allow even in the global-Deny case where the message says only the user can fix it. Step 4 forces a re-login.

### 6.6 `Invoke-AutoRemediateBITSBacklog.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\Microsoft\SCCM\Invoke-AutoRemediateBITSBacklog.ps1` |
| Inventory | NOT IN CSV |
| Inputs | none (`CCMDTS*`, 4-hour and 24-hour ages hard-coded) |
| Prerequisites | BITS, `BitsTransfer` module; SCCM client for real jobs |
| Automated coverage | none |

**Purpose.** Three steps: BITS Service State (resets Disabled to demand-start and starts), Stalled CCM Jobs (removes `CCMDTS*` jobs in Error for 4 hours or Suspended for 24 hours), Non-CCM Job Survey (report).

**Test steps**

1. Break: `sc.exe config BITS start= disabled`; `Start-BitsTransfer -Source 'http://localhost/does-not-exist.bin' -Destination C:\Temp\x.bin -DisplayName 'CCMDTS Job Lab' -Asynchronous` (404 puts it in Error). In a lab copy set `$MinJobAgeHours = 0` or wait 4 hours. A second job named `LabOtherProduct` exercises the survey.
2. Run. Expect `[Failed ] BITS Service State: BITS is Disabled -- no CM content can download -> Remediation ran`, `[Failed ] Stalled CCM Jobs: 1 stalled CCM job(s) of 1 total (1 Error) -> Remediation ran`, `[Warning] Non-CCM Job Survey ...`, exit `1` this run.
3. Verify `sc.exe qc BITS` shows `DEMAND_START`; `Get-BitsTransfer -AllUsers | Where-Object DisplayName -like 'CCMDTS*'` is empty. Rerun prints `[Passed ] Stalled CCM Jobs: No Configuration Manager BITS jobs queued`, exit `0`.
4. Restore: `Get-BitsTransfer -AllUsers | Where-Object DisplayName -eq 'LabOtherProduct' | Remove-BitsTransfer`.

**Status:** `NEEDS TEST - PRODUCT VM` (service and synthetic-job paths work on the lab VM). Needs an inventory row.

**Review notes.** Removing CM jobs causes re-download from the distribution point. The SCCM README says to confirm the removed list in output, but the script prints no per-job list.

### 6.7 `Invoke-AutoRemediateCcmCache.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\Microsoft\SCCM\Invoke-AutoRemediateCcmCache.ps1` |
| Inventory | NOT IN CSV |
| Inputs | `$env:RunAsPayload` (set by the scheduled task); hard-coded 80 percent, 30 days, 50 elements per run |
| Prerequisites | SCCM client (`root\ccm\SoftMgmtAgent`, `UIResource.UIResourceMgr`) |
| Automated coverage | none |

**Purpose.** Launcher stages itself to `C:\ProgramData\Omnissa\DEX\SCCM\` and dispatches the SYSTEM task `DEX_SCCMRemediateCache`. The payload runs four steps: Content Activity Guard (aborts if a task sequence, `ccmsetup` or an active CCM download is running), Cache Utilization (purges stale, unreferenced, unpinned elements through the supported COM API), Orphaned Cache Folders (report), Post-Purge Verification. Results at `HKLM:\Software\AirWatch\Extension\DEXRecords\SCCM\CcmCache`.

**Test steps**

1. Lab VM (no client): run the launcher. Expect `Task 'DEX_SCCMRemediateCache' dispatched. Results will appear at: ...`, exit `0`. After the task runs, the registry shows `Status = Failed`, `Failed = 1` from `Unable to read CacheConfig`. Task is unregistered. This proves the dispatch path only.
2. Product VM: fill the cache above 80 percent with content older than 30 days (or lower `$StaleCacheDays` in a lab copy), run the launcher, then read the registry: `Status = Passed`, `ElementsRemoved > 0`, step 4 text `Removed N element(s), freed ~XMB`.
3. Guard: start an active CCM download or a renamed `TSManager.exe` and confirm step 1 aborts with `Aborting -- ...`.

**Status:** `NEEDS TEST - PRODUCT VM`. Needs an inventory row.

**Review notes.** Fixed 2026-10-29 (v1.0.2): `MBFreed` was computed from a discarded query (`$null = Get-CimInstance ...`) and always equalled the whole pre-purge usage; it is now a real post-purge re-read.

### 6.8 `Invoke-AutoRemediateOrphanedCcmSetup.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\Microsoft\SCCM\Invoke-AutoRemediateOrphanedCcmSetup.ps1` |
| Inventory | NOT IN CSV |
| Inputs | `$env:RunAsPayload`; hard-coded 240 minutes, 3 retries, 2-hour log window |
| Prerequisites | `ccmsetup.exe` process, `C:\Windows\ccmsetup\Logs\ccmsetup.log` |
| Automated coverage | none |

**Purpose.** Launcher plus payload (`DEX_SCCMRemediateCcmSetup`). Four steps: Active Download Guard, Retry Loop Confirmation (three retry lines in the last 64 KB of a recently written log), Orphaned CcmSetup Process (kills a confirmed retry loop older than 240 minutes), Client Service Recovery (starts `CcmExec`, reports partial install). Results at `...\DEXRecords\SCCM\OrphanedCcmSetup`.

**Test steps** (synthetic, works on the lab VM)

1. Break: `Copy-Item $PSHOME\powershell.exe C:\Temp\ccmsetup.exe; Start-Process C:\Temp\ccmsetup.exe -ArgumentList '-Command Start-Sleep 20000'`; write three lines `Sleeping for 10 minutes before retrying` to `C:\Windows\ccmsetup\Logs\ccmsetup.log`. Lower `$OrphanMinutes` in a lab copy or wait 4 hours.
2. Run the launcher, then read the payload result. Expect `[Passed ] Retry Loop Confirmation: Retry loop confirmed: 3 retry entries, log active Nm ago`, `[Failed ] Orphaned CcmSetup Process: 1 ccmsetup.exe process(es) in a confirmed retry loop ... -> Remediation ran`, and on the lab VM `[Failed ] Client Service Recovery: CcmExec service is absent after terminating ccmsetup ...`. Registry `CcmSetupKilled = 1`.
3. Verify `Get-Process ccmsetup` is empty and the task is unregistered.
4. Guard: any active BITS download or files written into `C:\Windows\ccmsetup` during the 8-second window produces `Aborting -- ...`.
5. Restore: delete the fake log and executable.

**Status:** `NEEDS TEST - PRODUCT VM` for the Client Service Recovery pass path. Needs an inventory row.

**Review notes.** Killing `ccmsetup` can leave a half-installed client. Step 1 treats any BITS job of any product as an abort signal. The payload always exits `1` after a kill on a device without a healthy client.

### 6.9 `Invoke-AutoRemediateSCCMClient.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\Microsoft\SCCM\Invoke-AutoRemediateSCCMClient.ps1` |
| Inventory | NOT IN CSV |
| Inputs | none; thresholds hard-coded |
| Prerequisites | SCCM client (`CcmExec`, `root\ccm`, `C:\Windows\CCM\Logs`) |
| Automated coverage | none |

**Purpose.** Fourteen-step health sweep. Only three steps act: CcmExec Service State (sets delayed-auto and starts), Management Point Connectivity (`ipconfig /flushdns`), Policy Retrieval Freshness (triggers machine policy schedules). The rest report and name the spin-off script to deploy.

**Test steps**

1. Lab VM baseline (no client): steps 1, 7 and 13 fail and 2, 5, 6 and 12 warn; exit `1`. Useful as a parse and output-format check only.
2. Product VM: `Stop-Service CcmExec`, run, expect `[Failed ] CcmExec Service State: CcmExec is Stopped (StartMode: Auto) -> Remediation ran`, service Running within seconds, rerun `[Passed ]`.
3. Stale policy: `(Get-Item C:\Windows\CCM\Logs\PolicyAgent.log).LastWriteTime = (Get-Date).AddDays(-3)`, run, expect `[Warning] Policy Retrieval Freshness: Last policy activity 72h ago ... -> Remediation ran` and the log timestamp refreshes.
4. Certificate warning: a self-signed cert expiring in 10 days moved to `Cert:\LocalMachine\SMS`.
5. BITS warning: a `CCMDTS*` job in Error (no age gate here).

**Status:** `NEEDS TEST - PRODUCT VM`. Needs an inventory row.

**Review notes.** `-> Remediation ran` prints even when `sc.exe` or `Invoke-CimMethod` fail silently. Step 7 can spend 6 seconds on socket waits and is expected to fail on CMG or internet-only clients. No registry record is written despite the README implying one.

### 6.10 `Invoke-AutoRemediateWMIRepository.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\Microsoft\SCCM\Invoke-AutoRemediateWMIRepository.ps1` |
| Inventory | NOT IN CSV |
| Inputs | `$env:RunAsPayload` |
| Prerequisites | `winmgmt.exe`; SCCM client for step 3 to pass |
| Automated coverage | none |

**Purpose.** Launcher plus payload (`DEX_SCCMRemediateWMI`). Three steps: Install In Progress Guard (aborts on `ccmsetup`, `TSManager` or `TrustedInstaller`), Repository Consistency (runs `winmgmt /salvagerepository` only after two consecutive `/verifyrepository` failures), Post-Salvage Verification (re-verify and check `root\ccm`). Results at `...\DEXRecords\SCCM\WMIRepository`.

**Test steps**

1. Lab VM healthy: expect `[Passed ] Install In Progress Guard`, `[Passed ] Repository Consistency: WMI repository is consistent`, `[Failed ] Post-Salvage Verification: Repository consistent but root\ccm namespace is unavailable ...`, `Status = Failed`, exit `1`.
2. Guard: `sc.exe start TrustedInstaller` then run; expect all three steps `Warning`, `Status = Warning`.
3. Salvage path: do not corrupt WMI on a shared VM. On a disposable snapshot only, after a real inconsistency expect `[Failed ] Repository Consistency ... -> Remediation ran` followed by `[Passed ] Post-Salvage Verification: Repository consistent and root\ccm responding (client 5.x)`.

**Status:** `NEEDS TEST - PRODUCT VM`. Needs an inventory row.

**Review notes.** Step 3 always fails on devices without the CM client regardless of step 2. `TrustedInstaller` runs often on Windows 11, so the abort gate may fire frequently. Salvage restarts `Winmgmt`, which cascades to CcmExec and monitoring agents; maintenance window only.

### 6.11 `Invoke-AutoRemediateSCOMAgent.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\Microsoft\SCOM\Invoke-AutoRemediateSCOMAgent.ps1`, v1.0.0 |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | `$env:WhatIf` |
| Prerequisites | SCOM agent (`HealthService`, `HKLM:\SOFTWARE\Microsoft\Microsoft Operations Manager\3.0`) |
| Automated coverage | none |

**Purpose.** Combined fourteen-step sweep with a health score. Reference copy only: at 48,336 characters it exceeds the UEM 32,767-character limit, and the README says not to deploy it. Parts 1 to 3 below are the deployable split.

**Test steps.** Use Parts 1 to 3. A synthetic fixture for the monolith is the same as 6.12.

**Status:** `DEFERRED`. SCOM agent remediation is out of scope since 2026-10-30 while the approach is reviewed (updating the SCOM agent is often the preferred fix). Previous status, kept for the record: Reference only. Not a publication candidate; mark it so in the inventory.

### 6.12 `Invoke-AutoRemediateSCOMAgentPart1.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\Microsoft\SCOM\Invoke-AutoRemediateSCOMAgentPart1.ps1`, `$SCRIPT_VERSION` 1.0.0 (header says 1.1.0) |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | `$env:WhatIf` |
| Prerequisites | SCOM agent registry root; `HealthService` for the service step |
| Automated coverage | none |

**Purpose.** Steps 1 to 5: HealthService Service State (sets auto and starts), Startup Delay, Management Group Registration, Management Server Connectivity (`ipconfig /flushdns`), Configuration Cache Freshness. The only part that remediates. Writes `Part1*` values, `ManagementServer`, `ConfigAgeHours`, `ServiceRunning`, `MsReachable` to `HKLM:\Software\AirWatch\Extensions\SCOM`. No agent: writes `Status = NotApplicable`, exit `0`.

**Test steps** (synthetic fixture works on the lab VM)

1. Fixture:
   ```powershell
   New-Item 'HKLM:\SOFTWARE\Microsoft\Microsoft Operations Manager\3.0\Setup' -Force | Set-ItemProperty -Name InstallDirectory -Value 'C:\Lab\SCOM\'
   New-Item 'HKLM:\SOFTWARE\Microsoft\Microsoft Operations Manager\3.0\Agent Management Groups\LabMG\Parent Health Services\0' -Force | Set-ItemProperty -Name NetworkName -Value 'localhost'
   Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft Operations Manager\3.0\Agent Management Groups\LabMG\Parent Health Services\0' -Name Port -Value 5723 -Type DWord
   New-Item 'C:\Lab\SCOM\Health Service State\Connector Configuration Cache\LabMG\OpsMgrConnector.Config.xml' -Force | Out-Null
   (Get-Item 'C:\Lab\SCOM\Health Service State\Connector Configuration Cache\LabMG\OpsMgrConnector.Config.xml').LastWriteTime = (Get-Date).AddDays(-3)
   ```
2. Run. Expect `[Failed ] HealthService Service State: HealthService is not installed but agent registry keys exist ...`, `[Failed ] Management Server Connectivity: Management server unreachable on port 5723: localhost ... -> Remediation ran`, `[Warning] Configuration Cache Freshness ...`, exit `1`. Set `Port` to 135 to make connectivity pass.
3. WhatIf: `$env:WhatIf='true'`, expect the header `WhatIf=True`, no `sc.exe` or `flushdns` executed (log lacks the "Issued start" line) while the console still shows `-> Remediation ran`.
4. Product VM: `Stop-Service HealthService`, run, expect `[Failed ] HealthService Service State: HealthService is Stopped (StartMode: Auto) -- this device is grey in the console -> Remediation ran`, service Running shortly after, registry `ServiceRunning = 0` then `1` on rerun.
5. Verify `Get-ItemProperty HKLM:\Software\AirWatch\Extensions\SCOM` shows a fresh `Part1RunTime`.
6. Restore: `Remove-Item 'HKLM:\SOFTWARE\Microsoft\Microsoft Operations Manager' -Recurse; Remove-Item C:\Lab\SCOM -Recurse`.

**Status:** `DEFERRED`. SCOM agent remediation is out of scope since 2026-10-30 while the approach is reviewed (updating the SCOM agent is often the preferred fix). Previous status, kept for the record: `NEEDS TEST - PRODUCT VM` (fixture validates the registry and connectivity logic on the lab VM). Also `Completed` on both lab devices in UEM sweep `6c8405` (2026-10-29).

**Review notes.** Version constant and header disagree. Step 1 resolution skips if any process named `setup` is running.

### 6.13 `Invoke-AutoRemediateSCOMAgentPart2.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\Microsoft\SCOM\Invoke-AutoRemediateSCOMAgentPart2.ps1`, v1.0.0 |
| Inventory | `3) Complete - Needs Testing`, impact Low |
| Inputs | `$env:WhatIf` (nothing to gate) |
| Prerequisites | Agent root; `Operations Manager` event log |
| Automated coverage | none |

**Purpose.** Steps 6 to 10, all report-only: Health Service State Folder Size, Health Service Store Database, Agent Runtime Footprint, Connector Connectivity Failures, Workflow Health. Owns the single `Operations Manager` event-log pass. Writes `Part2*` and the metric values.

**Test steps** (fixture from 6.12 plus)

1. `fsutil file createnew 'C:\Lab\SCOM\Health Service State\big.bin' 1700000000`; `fsutil file createnew 'C:\Lab\SCOM\Health Service State\Health Service Store\HealthServiceStore.edb' 900000000`.
2. `New-EventLog -LogName 'Operations Manager' -Source HealthService` then `Write-EventLog -LogName 'Operations Manager' -Source HealthService -EventId 21016 -EntryType Error -Message lab` (and 20070, three of 1103, 4001, 7016).
3. Run. Expect `[Warning] Health Service State Folder Size: Health Service State is 1700.2MB (threshold 1536MB) ...`, `[Warning] Connector Connectivity Failures: 1 event(s) 21016 ...`, `[Warning] Workflow Health ...`, exit `0`.
4. Verify registry `StateFolderMB`, `NotRegistered24h`, `UnloadedWorkflows24h`, `Part2RunTime`.
5. Restore: `Remove-EventLog -LogName 'Operations Manager'` and the fixture.

**Status:** `DEFERRED`. SCOM agent remediation is out of scope since 2026-10-30 while the approach is reviewed (updating the SCOM agent is often the preferred fix). Previous status, kept for the record: `NEEDS TEST - PRODUCT VM` (Agent Runtime Footprint needs real processes). Also `Completed` on both lab devices in UEM sweep `6c8405` (2026-10-29).

**Review notes.** Most expensive part (90-second budget in the README). Writes decimal strings such as `1700.2` that Part 3 cannot parse (see 6.14).

### 6.14 `Invoke-AutoRemediateSCOMAgentPart3.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\Microsoft\SCOM\Invoke-AutoRemediateSCOMAgentPart3.ps1`, v1.0.0 |
| Inventory | `3) Complete - Needs Testing`, impact Low |
| Inputs | `$env:WhatIf` (nothing to gate) |
| Prerequisites | Agent root; Parts 1 and 2 run within 26 hours for a complete score |
| Automated coverage | none |

**Purpose.** Steps 11 to 14 (Channel Certificate Health, Agent Version, Time Synchronisation Skew, Optional Agent Sub-services) plus the sweep-wide health score computed from its own metrics and the Part 1 and 2 registry cache. Writes aggregate `Status`, `HealthScore`, `HealthReason`, `ScoreComplete`.

**Test steps**

1. Run Part 3 alone on an empty cache: expect `Health score: -1 (IncompleteSweep) -- INCOMPLETE, Part 1 or 2 has not run recently`, `ScoreComplete = 0`.
2. Run Parts 1 and 2 on the fixture, then Part 3: expect a numeric score and `ScoreComplete = 1`.
3. Certificate: `Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft Operations Manager\3.0\Machine Settings' ChannelCertificateSerialNumber ([byte[]](1,2,3,4)) -Type Binary` (create the key first). Expect `[Failed ] Channel Certificate Health: Channel certificate serial 04030201 is configured but no matching certificate exists ...`, exit `1`.
4. Time: `Stop-Service w32time`, expect `[Warning] Time Synchronisation Skew: Windows Time service did not respond ...`. Restart the service.

**Status:** `DEFERRED`. SCOM agent remediation is out of scope since 2026-10-30 while the approach is reviewed (updating the SCOM agent is often the preferred fix). Previous status, kept for the record: `NEEDS TEST - PRODUCT VM`. UEM sweep `6c8405` (2026-10-29) reported `Completed` on both lab devices, which proves only the not-installed path (result file `test-result-scripts.json` in the connector folder). Fixed 2026-10-29 (v1.1.1), parse-checked. Re-run the fixture in step 2 and confirm the score drops when `StateFolderMB` is over 1536 and `ConfigAgeHours` over 24.

**Review notes.** Fixed: `Get-Cached` now parses culture-invariant doubles and rounds, so the decimal strings Part 2 writes no longer read back as -1 and the `ConfigurationCacheStale`, `HealthServiceStateOversized` and CPU deductions apply. Remaining: exit code does not reflect Part 1 or 2 failures (by design, documented in the README).

### 6.15 `Invoke-AutoRemediateSCOMClonedIdentity.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\Microsoft\SCOM\Invoke-AutoRemediateSCOMClonedIdentity.ps1` |
| Inventory | `3) Complete - Needs Testing`, impact High |
| Inputs | **REQUIRED UEM variable** `ConfirmHighImpact` = `true` (without it every run ends `Skipped:NotConfirmed`); optional `WhatIf`; `RunAsPayload` is set by the task, never by UEM |
| Prerequisites | SCOM agent; `Operations Manager` log; AV exclusion on `C:\ProgramData\AirWatch\Extensions\` |
| Automated coverage | `uem-tests.json` skip |

**Purpose.** Destructive launcher plus payload (`WS1_SCOMClonedIdentity`). Renames `Health Service State` to drop a golden-image identity, only when the folder predates the OS install and the management server has rejected the agent three times in 24 hours, with rollback and a 14-day cooldown. Results at `HKLM:\Software\AirWatch\Extensions\SCOM\ClonedIdentity`.

**Test steps** (synthetic fixture, payload run directly so env variables are visible)

1. Fixture: registry root as 6.12; `New-Item 'C:\Lab\SCOM\Health Service State' -ItemType Directory -Force; (Get-Item 'C:\Lab\SCOM\Health Service State').CreationTime = (Get-Date).AddYears(-2)`; `New-EventLog -LogName 'Operations Manager' -Source HealthService` and three `Write-EventLog ... -EventId 21016`.
2. Gates: run without `ConfirmHighImpact`, expect `Status = Skipped:NotConfirmed`. Set CreationTime to now, expect `Skipped:StateIsLocal`. Two events only, expect `Skipped:NoRejectionEvidence`.
3. Reset path: `$env:ConfirmHighImpact='true'; $env:RunAsPayload='true'; & .\Invoke-AutoRemediateSCOMClonedIdentity.ps1`. Expect `[Failed ] Identity Reset: Both signals present (image-baked state 730 days old, 3 rejections) -- resetting agent identity -> Remediation ran`, then on the fixture `[Failed ] Post-Reset Verification: HealthService did not start after the reset -- original state folder restored`, `Status = RolledBack`, `RolledBack = 1`, exit `1`, original folder name back.
4. Product VM success: step 6 `[Passed ] ... Agent re-registered with a new identity and received configuration; old state removed`, `LastResetTime` written, task unregistered.

**Status:** `DEFERRED`. SCOM agent remediation is out of scope since 2026-10-30 while the approach is reviewed (updating the SCOM agent is often the preferred fix). Previous status, kept for the record: `NEEDS TEST - PRODUCT VM`. Fixed 2026-10-29 (v1.0.1, 32,633 characters), parse-checked. Re-run the fixture via the launcher (not the payload directly) to prove the forwarded `ConfirmHighImpact` reaches the task; expect `Status = RolledBack` on the fixture and `Status = Reset`, exit `0`, on a real agent.

**Review notes.** Fixed: the launcher now forwards whitelisted `ConfirmHighImpact` and `WhatIf` values (`true|false|1|0|yes|no` only, lower-cased) into the task command line, so the payload sees them under UEM; the aggregate no longer counts the action step's designed `Failed` once its remediation ran, so a successful reset reports `Reset` and exit `0`; a WhatIf run reports `Skipped:WhatIf` and a deadline abort `Skipped:TimedOut`. Still the highest blast radius in the repo; wrong tool for non-persistent VDI.

### 6.16 `Invoke-AutoRemediateSCOMHealthServiceCache.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\Microsoft\SCOM\Invoke-AutoRemediateSCOMHealthServiceCache.ps1` |
| Inventory | `3) Complete - Needs Testing`, impact High |
| Inputs | **REQUIRED UEM variable** `ConfirmHighImpact` = `true` (without it every run ends `Skipped:NotConfirmed`); optional `WhatIf`; `RunAsPayload` is set by the task, never by UEM |
| Prerequisites | SCOM agent with a reachable management server |
| Automated coverage | `uem-tests.json` skip |

**Purpose.** Destructive launcher plus payload (`WS1_SCOMHealthServiceCache`). Stops `HealthService`, renames `Health Service State`, restarts, waits up to 300 seconds for configuration to return, rolls back if it does not. Gates: confirmation, install guard, management server reachability, a flush signal (stale config, ESENT errors or folder over 1536 MB), 7-day cooldown. Results at `...\Extensions\SCOM\HealthServiceCache`.

**Test steps** (synthetic fixture, payload run directly)

1. Fixture as 6.12 with `Port = 135` (reachable) and the 3-day-old `OpsMgrConnector.Config.xml`.
2. Gates: Port 5723 gives `Skipped:ManagementServerUnreachable`; fresh config and a small folder give `Skipped:NoSignal`; `sc.exe start TrustedInstaller` gives `Skipped:InstallInProgress`; no `ConfirmHighImpact` gives `Skipped:NotConfirmed`. Clear `LastRunTime` between attempts.
3. Flush path: `$env:ConfirmHighImpact='true'; $env:RunAsPayload='true'; & .\Invoke-AutoRemediateSCOMHealthServiceCache.ps1`. Expect `[Passed ] Management Server Reachability: Management server localhost:135 reachable ...`, `[Passed ] Flush Signal Confirmation: Flush signal(s) confirmed: configuration 72h stale`, `[Failed ] Health Service State Flush: All gates cleared -- flushing NMB of agent state -> Remediation ran`, `[Failed ] Post-Flush Verification: HealthService did not start within 60s after the flush -- state folder restored`, `Status = RolledBack`, exit `1`, folder restored.
4. Product VM success: `[Passed ] Post-Flush Verification: Agent recovered: service running and configuration re-downloaded; reclaimed ~NMB`, no `dexbak` folder left.

**Status:** `DEFERRED`. SCOM agent remediation is out of scope since 2026-10-30 while the approach is reviewed (updating the SCOM agent is often the preferred fix). Previous status, kept for the record: `NEEDS TEST - PRODUCT VM`. Fixed 2026-10-29 (v1.0.1, 32,692 characters), parse-checked. Re-run the gate variants via the launcher, confirm a `Skipped:*` run does not write `LastFlushTime`, and that a real flush reports `Completed`, exit `0`.

**Review notes.** Fixed: the cooldown gate reads `LastFlushTime`, written only when a flush happened (`LastRunTime` is still written every run for reporting); same forwarding and aggregate fixes as 6.15, so a successful flush reports `Completed`. The file was 33,580 characters on disk before this change, already over the UEM limit despite `DESIGN.md` saying 32,717; comment text was trimmed to bring it to 32,692. Any future edit must re-check the size.

### 6.17 `Invoke-AutoRemediateSCOMMonitoringHost.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\Microsoft\SCOM\Invoke-AutoRemediateSCOMMonitoringHost.ps1` |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | `$env:RunAsPayload`; `$env:WhatIf` |
| Prerequisites | Running SCOM agent with `MonitoringHost` processes |
| Automated coverage | none |

**Purpose.** Launcher plus payload (`WS1_SCOMMonitoringHost`). Restarts `HealthService` to clear a runaway `MonitoringHost` after two load samples 45 seconds apart confirm CPU over 20 percent or memory over 500 MB, with guards for recent start or recent configuration and a 20-hour cooldown. Results at `...\Extensions\SCOM\MonitoringHost`.

**Test steps**

1. Lab VM: registry root only gives `Skipped:ServiceNotRunning`; no root gives `Skipped:NoAgent`.
2. Product VM: force load with a heavy management pack script or lower `$CpuWarnPercent` in a lab copy. Expect `[Passed ] Sustained Load Confirmation: Sustained load confirmed: 35.2% CPU over 45s ...`, `[Failed ] Agent Recycle: Recycling HealthService ... -> Remediation ran`, `[Passed ] Post-Recycle Verification: Agent recycled and running: working set XMB -> YMB ...`, registry `Recycled = 1`, `LastRecycleTime` set.
3. Second run within 20 hours: `Recycled at <time>, within the 20h cooldown. Skipping.`, `Status = SkippedCooldown`.
4. `Restart-Service HealthService` immediately before a run gives `Skipped:AgentRecentlyStarted`.

**Status:** `DEFERRED`. SCOM agent remediation is out of scope since 2026-10-30 while the approach is reviewed (updating the SCOM agent is often the preferred fix). Previous status, kept for the record: `NEEDS TEST - PRODUCT VM`. UEM sweep `6c8405` (2026-10-29): `Failed` with `UnknownScriptError (12004)` on both lab devices (after 1 s on `CHASEWIN11_2`, 206 s on `CBRADLEYSWIN11`). Hub's executor log on the VM gave the cause: `Launcher failed: Cannot bind argument to parameter 'Path' because it is an empty string`. Hub feeds the script to PowerShell through stdin, so `$PSCommandPath` is empty and the launcher's self-copy (`Copy-Item -Path $PSCommandPath`) throws. Every launcher that stages itself for a scheduled task had the same line: the three SCOM launchers, the three SCCM launchers (`CcmCache`, `OrphanedCcmSetup`, `WMIRepository`), `DEX_Start-WindowsUpdate.ps1`, and the `DeployScheduledTask` mode of `Measure-LogonDuration.ps1` and `Measure-LogonDurationMultiSession.ps1`. All ten now write `$MyInvocation.MyCommand.ScriptBlock.ToString()` to the payload path instead, which holds the full script text in both file and stdin mode (verified locally). The re-runs then exposed two more launcher defects that only show under Hub: `-WhatIf:$false` passed to `Register-ScheduledTask` (no such parameter) and `-DeleteExpiredTaskAfter` on a trigger-less task (needs an `EndBoundary`, so registration fails). Both removed from every launcher that had them. Re-run `c99707` (2026-10-30 00:21) reported `Completed` on both lab devices, but the payload Hub staged on the VM was 25,951 characters against a 30,629-character source: inside the script's main function `$MyInvocation.MyCommand.ScriptBlock` is the function body, so the header and the tail that switches the copy into payload mode were lost and the payload took the "already running" exit. Fixed by capturing the script text at script scope (the line before the function) in all six function-wrapped launchers. In the final re-run (`37acca`, 2026-10-30 00:31, `Completed` on both lab devices, result file `test-result-launcher.json`) the staged payload is 30,780 bytes, the payload log shows every step and `Payload complete`, and the registry record reads `Status = Skipped:NoAgent`, which is the correct result on a device without the SCOM agent. Details in `UEM-API-TESTING-SPEC.md`.

**Review notes.** Fixed 2026-10-29 (v1.0.1): a healthy recycle now reports `Recycled` and exit `0`; `WhatIf` is forwarded into the task command line and a WhatIf run reports `Skipped:WhatIf`. Monitoring gap during the restart; unsent queue lost.

---


## 7. Disk cleanup scripts

### 7.1 `Start-ClearRecycleBin.ps1`

| Field | Value |
|---|---|
| Path / version | `DiskCleanup\Start-ClearRecycleBin.ps1`, v2.2.0 |
| Inventory | `4) Complete - Tested`, impact Low |
| Inputs | `$env:OlderThanDays` (0 = everything), `$env:AllFixedDrives` (`true`/`false`), `$env:ResetShellIcon`, `$env:WhatIf` |
| Prerequisites | SYSTEM (per-user bin folders are ACL'd to owner, SYSTEM and Administrators) |
| Automated coverage | none |

**Purpose.** Empties every user's Recycle Bin by deleting `$R*`/`$I*` pairs under `<drive>:\$Recycle.Bin\<SID>\`, honouring an age cutoff read from the `$I` sidecar. Reports per-user and total MB. Full `ShouldProcess` support.

**Test steps**

1. Seed as a normal user:
   ```powershell
   fsutil file createnew C:\Temp\recycle-probe.bin 1073741824
   Add-Type -AssemblyName Microsoft.VisualBasic
   [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile('C:\Temp\recycle-probe.bin','OnlyErrorDialogs','SendToRecycleBin')
   ```
2. Dry run elevated with `$env:WhatIf='true'`: expect `What if:` lines and `SpaceCleaned: ~1024 MB` still reported, bin unchanged.
3. Live run as SYSTEM (scheduled task or `PsExec64 -s`). First output line must read `Running as NT AUTHORITY\SYSTEM`. Expect `<user> on C:: 1 item(s), 1024 MB`, `ItemsRemoved: 1`, `SpaceCleaned: 1024 MB`, exit `0`.
4. Age cutoff: reseed, set `$env:OlderThanDays='7'`, expect the item under `ItemsRetained`.
5. Unelevated negative: expect `Cannot read the Recycle Bin for <user>. Run this as SYSTEM.` and exit `1`.
6. Verify `Get-ChildItem -LiteralPath 'C:\$Recycle.Bin' -Force -Directory` counts and `(Get-Volume -DriveLetter C).SizeRemaining` up by about 1 GB.

**Status:** `TESTED - MANUAL`. Also `Completed` on both lab devices in UEM sweep `6c8405` (2026-10-29).

**Review notes.** Irrecoverable for all users; deploy with `OlderThanDays`. `DiskCleanup\Testing-Guide.md` section 4.3 still describes a registry `StateFlags0056` from the old cleanmgr version; v2.2.0 writes no registry.

### 7.2 `Start-DiskCleanup.ps1`

| Field | Value |
|---|---|
| Path / version | `DiskCleanup\Start-DiskCleanup.ps1` |
| Inventory | `4) Complete - Tested`, impact Low |
| Inputs | `$env:WaitForCleanup` (bool), `$env:WaitTimeoutSeconds` (900) |
| Prerequisites | `cleanmgr.exe` (absent on some Server and LTSC builds) |
| Automated coverage | none |

**Purpose.** Writes `StateFlags0055 = 2` for seven system categories (Previous Installations, memory dumps, minidumps, Update Cleanup, WER files, Reset and Upgrade logs) and `0` for all others, runs `cleanmgr /sagerun:55`, optionally waits for `cleanmgr`, `TiWorker` and `TrustedInstaller` to settle, prints `SpaceCleaned` and `FreeSpace` in GB.

**Test steps** (snapshot first; removes `Windows.old`)

1. Seed: `fsutil file createnew C:\Windows\Minidump\lab.dmp 52428800`.
2. Run with `$env:WaitForCleanup='true'`. Expect `Waiting up to 900 second(s) for Disk Cleanup to finish...`, `SpaceCleaned: X GB`, `FreeSpace: Y GB`, exit `0`.
3. Verify every `VolumeCaches` subkey has `StateFlags0055` and exactly the seven categories read `2`; the seeded minidump is gone.
4. Timeout path: `$env:WaitTimeoutSeconds='1'`, expect the warning and exit `1`.
5. No-wait path: unset `WaitForCleanup`, expect no waiting line and an immediate return while cleanmgr keeps running.

**Status:** `TESTED - MANUAL`. UEM sweep `6c8405` (2026-10-29): `ScriptTimedOut` on `CBRADLEYSWIN11`, `Completed` on `CHASEWIN11_2`. The script itself exited 0 in 5 s; cleanmgr, launched with the call operator, inherited the host's output pipe and Hub waited for cleanup to finish. Fixed in 1.2.1 (Start-Process); re-run `0501f4` the same evening reported `Completed` on both devices.

**Review notes.** The default 900-second wait needs a UEM timeout near 20 minutes; without the wait use 30 seconds. Hard-coded `C:`. Header script name differs from the file name. A pending Windows Update install can legitimately make a waiting run hit the ceiling.

### 7.3 `Start-UserProfileCleanup.ps1`

| Field | Value |
|---|---|
| Path / version | `DiskCleanup\Start-UserProfileCleanup.ps1` |
| Inventory | `3) Complete - Needs Testing`, impact High |
| Inputs | none; hard-coded `$ENROLLMENTUSER = "Administrator"`, `$DAYS_INACTIVE = 30`, `$SIZE_THRESHOLD_MB = 500` |
| Prerequisites | PS 5.1 (`Get-WmiObject`), SYSTEM |
| Automated coverage | `_AutomatedTesting\Start-UserProfileCleanup_BreakTest.ps1` (3 breaks); `uem-tests.json` skip |

**Purpose.** Deletes whole local profiles that are both inactive beyond the threshold and larger than the size threshold, via `Remove-WmiObject` on `Win32_UserProfile`.

**Test steps** (per `General-Testing-Guide.md` section 2.2; snapshot first)

1. Create a disposable profile: `net user dexprobe 'Pr0be!Pass#2026' /add; runas /user:dexprobe "cmd /c exit"`. Confirm `C:\Users\dexprobe` exists.
2. Safe negative first: edit a scratch copy with `$DAYS_INACTIVE = 3650`. Run. Expect every profile `Examining profile: ...` and no `Deleted profile:` line.
3. Positive: set `$ENROLLMENTUSER` to your own account, `$DAYS_INACTIVE = 0`, `$SIZE_THRESHOLD_MB = 0`. Run as SYSTEM. Expect `Deleted profile: C:\Users\dexprobe`, `Profile cleanup complete.`, exit `0`.
4. Verify `Test-Path C:\Users\dexprobe` false; `Get-CimInstance Win32_UserProfile | Where-Object LocalPath -like '*dexprobe*'` empty; the `ProfileList` SID key gone.
5. Restore: `net user dexprobe /delete`; discard the scratch copy.

**Status:** `PASS - LAB` + `PASS - UEM`, Full Pass. Break test runs 28180d46896e and 7027f9afc870 on 2026-11-02 (elevated, lab VM `CBRADLEYSWIN11`): StaleOversizedProfile (`DEXTestProfile`, 98.71 MB and idle 60 days against the scratch copy's 0-day, 32 MB thresholds, deleted in both runs), EnrollmentUserProfileKept (first run) and UnderThresholdProfileKept (`DEXTestKeep`, 2.71 MB, second run), both examined and left in place; the delete path that was manual is now exercised by the harness; machine restored. Results `C:\Temp\FixReport\Start-UserProfileCleanup\28180d46896e.json` and `7027f9afc870.json`. UEM run `bbf07f` (2026-10-30, single-VM group `Test_JSpencerOnly`) `Completed` on `CHASEWIN11_2`.

**Review notes.** No dry run. `Deleted profile:` prints before the delete is attempted, so a failed delete still shows the line. `$LOG_PATH` is declared but never written; the README and testing guide say otherwise. `Win32_UserAccount` enumeration on a domain-joined machine queries the whole domain and can time out. `LastUseTime` is unreliable on recent Windows 11 builds.

---

## 8. Generic troubleshooting scripts

### 8.1 `Get-AppVolumesMountProbe.ps1`

| Field | Value |
|---|---|
| Path / version | `GenericTroubleshooting\AppVolumesMount\Get-AppVolumesMountProbe.ps1`, v1.0.0 |
| Inventory | NOT IN CSV |
| Inputs | `-LogonCount` (3), `-WindowMinutes` (10), `-LookbackHours` (168), `-Sanitize` (true), `-CopyFullLog`, `-OutputPath`, `-MaxLogLines` (4000); each also via `$env:` except `MaxLogLines` |
| Prerequisites | Omnissa App Volumes agent for meaningful content; elevation to read the log and `svservice` Parameters |
| Automated coverage | none |

**Purpose.** Read-only probe. Writes one sanitized report (agent identity, services, `svservice` parameters, event IDs, `svservice.log` slices around each interactive logon, disk arrivals, clock offset) to `C:\Windows\Temp\AppVolumes_MountProbe_<host>_<stamp>.txt`.

**Test steps**

1. Lab VM (no agent): run elevated. Expect `Agent install     : NOT FOUND`, `Report written to : ...`, `Send that file back. Nothing on this device was modified.`
2. `-Sanitize $false -OutputPath C:\Temp\raw.txt`: confirm real hostname appears in the raw file and `HOST01`/`USER01` in the default one.
3. Unelevated: expect the `*** NOT ELEVATED` block.
4. Product VM: expect `svservice.log : N line(s)`, `Logon windows : N`, per-logon sections with log slices.

**Status:** `NEEDS TEST - PRODUCT VM` (the no-agent path works on the lab VM).

**Review notes.** Lines 690 and 696 pass `[string]$disk.FriendlyName` in argument mode, so the literal text `[string]` is prepended in the Disks and Volumes section. Unsanitized output contains usernames and hostnames. Needs an inventory row before publication.

### 8.2 `Enable-LogonAuditLogs.ps1`

| Field | Value |
|---|---|
| Path / version | `GenericTroubleshooting\WindowsStartup\Enable-LogonAuditLogs.ps1` |
| Inventory | `4) Complete - Tested`, impact Low |
| Inputs | none from UEM (`-Force` exists on the inner function but is never passed) |
| Prerequisites | Elevation for `wevtutil sl` |
| Automated coverage | none |

**Purpose.** Enables `Microsoft-Windows-PrintService/Operational` and `Microsoft-Windows-TaskScheduler/Operational`, writes `AuditLogsConfiguredAt` under `HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration`, and skips on later runs.

**Test steps**

1. Break: `wevtutil sl Microsoft-Windows-PrintService/Operational /e:false; wevtutil sl Microsoft-Windows-TaskScheduler/Operational /e:false; Remove-ItemProperty -Path HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration -Name AuditLogsConfiguredAt -ErrorAction SilentlyContinue`.
2. Run. Expect `[ENABLED]` for both logs, `=== Configuration complete ===`, exit `0`.
3. Run again. Expect `Audit logs already configured at <stamp>. Skipping.`, exit `0`.
4. Verify `wevtutil gl Microsoft-Windows-PrintService/Operational` shows `enabled: true` (same for TaskScheduler).
5. Unelevated with logs disabled: `[FAILED]` lines and exit `1`.

**Status:** `TESTED - MANUAL`. Also `Completed` on both lab devices in UEM sweep `6c8405` (2026-10-29).

**Review notes.** The marker is written even when a log reports `[FAILED]`, so later runs skip and never retry, and `-Force` cannot be reached from UEM.

### 8.3 `Measure-LogonDuration.ps1`

| Field | Value |
|---|---|
| Path / version | `GenericTroubleshooting\WindowsStartup\Measure-LogonDuration.ps1`, collector v1.1.4 (2026-11-05 afternoon: shell-ready from the session's explorer.exe, GP 4001 bounded to the logon window, N/A on workgroup devices; 1.1.3 the same morning: every event query through the .NET `EventLogReader`, 13.2.z; 1.1.2 on 2026-11-03: User Profiles Service provider name) |
| Inventory | `4) Complete - Tested`, impact Low |
| Inputs | `-DeployMode`/`$env:DeployMode` (`RunNow`, `DeployScheduledTask`, `ConfigureLogging`), `-ConfigureLoggingFirst`, `-NoExit` |
| Prerequisites | A console user for `RunNow`; elevation for registry and task registration |
| Automated coverage | none |

**Purpose.** Mines event logs for the console user's last logon and writes 18 values (GP, folder redirection, profile load, FSLogix, ActiveSetup, AppX, printers, logon tasks) under `HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration`. Can install itself as a SYSTEM task that runs 30 seconds after each logon.

**Test steps**

1. Log on at the console, elevated: `.\Measure-LogonDuration.ps1 -NoExit`. Expect `Logon duration metrics recorded for '<user>' at '<path>'` and a `-- Registry readback ---` block with all values.
2. Sentinels: disable the optional logs (8.2 break step) and rerun; expect `LogDisabled` for the printer and task fields.
3. Task: `-DeployMode DeployScheduledTask -ConfigureLoggingFirst $true`. Expect `Scheduled task '\DEXTools\DEXTools_MeasureLogonDuration' registered.`; verify `Get-ScheduledTask -TaskPath '\DEXTools\'` shows SYSTEM principal and the copied script at `C:\ProgramData\AirWatch\Extensions\DEXTools\`. Log off and on, confirm `DataCollectedAt` updates.
4. No-user path: `PsExec64 -s` with nobody at the console. Expect `No interactive user detected. Nothing to measure.`, exit `1`.
5. Restore: `Unregister-ScheduledTask -TaskPath '\DEXTools\' -TaskName DEXTools_MeasureLogonDuration -Confirm:$false; Remove-Item 'C:\ProgramData\AirWatch\Extensions\DEXTools' -Recurse; Remove-Item HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration -Recurse`.

**Status:** `TESTED - MANUAL`. Also `Completed` on both lab devices in UEM sweep `6c8405` (2026-10-29). 1.1.3 (2026-11-05) replaces every `Get-WinEvent` call with the .NET `EventLogReader` after the probe showed the cmdlet fails in every form under Hub's engine (13.2.z); a scratch run on this VM redirected to HKCU wrote a registry record identical to 1.1.2's across all 18 values, in 5 s instead of 19 s under 5.1 and 6.6 s instead of 8.4 s under pwsh 7.5. Its one-time counterpart `OneTimeSensor\logon_duration_measure.ps1` 1.1.0, rewritten the same way, is the UEM proof for the approach: sensor run `6607c3` (2026-11-05 09:29) returned `Status OK` with real values from both devices 17 and 20 s after sync (`CBRADLEYSWIN11`: GpMs 40, ProfileLoadMs 130, ActiveSetupMs 3640, 36 logon tasks over 275.8 s; `CHASEWIN11_2`: GpMs 70, ProfileLoadMs 90, ActiveSetupMs 23070, 27 tasks over 234.4 s), where every earlier Hub run of that sensor had returned `{"Status":"Failed","Error":"Cannot marshal 'parameter #8'..."}` (13.2.v). The sensor is `4) Complete - Tested` from this run. The collector itself then ran under Hub: UEM run `d17a02` (2026-11-05 11:33) reported `Completed` on both devices, and the cache it wrote (`CollectorVersion` 1.1.3, `DataCollectedAt` 11:33:56 and 11:34:03) fed the 21-sensor sweep `e5d833` (11:37 to 11:46), where every `logon_*` sensor passed: `logon_time` 2026-11-05T08:35:18 and 2026-11-04T14:04:51, `logon_gp_start_time` ten minutes after each, `logon_gp_duration_ms` 40 and 70, `logon_profile_load_duration_ms` 130 and 90, `logon_activesetup_duration_ms` 3640 and 23070, `logon_task_count` 36 and 27, `logon_task_total_duration_ms` 275840 and 234400, `logon_printers_mapped_count` and `logon_printer_mapping_duration_ms` 0, the not-applicable phases (`gp_scripts`, `folder_redirect`, `fslogix_attach`, `appx_load`) -2 on both, `logon_duration_summary` the full record with `CollectorPresent` true, and `logon_shell_ready_time` with no value as the manifest expects. Fourteen scalar sensors plus the summary are `4) Complete - Tested` from this sweep; `logon_shell_ready_time` and `logon_total_duration_ms` (-1) stay at Needs Testing until the Winlogon 7001 defect below is fixed, since a sentinel is not a value. Two observations for a later fix, present in 1.1.2 and before: `ShellReadyTime` and `TotalMs` are always Unknown on Windows 11 because Winlogon EID 7001 carries `[1, <SID>]` there, never the `'Shell'` subscriber name the filter expects; and the Group Policy phase takes the newest EID 4001 for the user with no logon-window bound, so on both VMs it reported a refresh cycle ten minutes after logon (40 and 70 ms) rather than the logon's own processing. Both fixed the same afternoon in collector 1.1.4 and sensor 1.1.1. Shell-ready is now the creation time of the session's earliest `explorer.exe` (`Win32_Process`, the approach the multi-session collector already used), with the 7001 `Shell` filter kept only as a fallback when no shell process is alive for the session: UEM run `948b35` (collector) and `b9b16e` (sensors) returned `logon_shell_ready_time` 08:35:19 and 14:04:53 and `logon_total_duration_ms` 1590 and 2080 on the two devices, and both sensors are `4) Complete - Tested` from that run. The Group Policy 4001 is now the oldest cycle inside a window from one minute before the logon to ten minutes after it, with the 8001 looked for in the thirty minutes after it. That run then returned `GpMs` -1 and no `GpStartTime` on both VMs, so a temporary probe sensor listed the GP Operational log under Hub (`a82a13` for all cycles, `8c7790` for user 4001/8001 only; temporary inventory row and `Sensors\gp_log_probe.ps1` removed afterwards, result files kept in the bundle): both workgroup VMs log the user's 4001/8001 pairs only as refresh cycles, ten minutes after each logon (08:45:18 for the 08:35:18 logon, 14:14:51 for 14:04:51) and on Hub syncs, never at logon, while the computer-side 4004/8004 pairs fire dozens of times a day. So the 40 and 70 ms that `e5d833` reported were a refresh, not logon processing, and a workgroup device has no domain policy to process at logon. 1.1.4 therefore reports `N/A` (sensor -2) when no user cycle falls inside the window and `Win32_ComputerSystem.PartOfDomain` is false, and `Unknown` only on a domain-joined device where a cycle should have been there. `logon_gp_duration_ms` keeps Tested on the -2 value (the same not-applicable contract as the FSLogix and AppX sensors); `logon_gp_start_time` goes back to Needs Testing with `expectNoValue` in the manifest, since only a domain-joined device can give it a value. Confirmation run with that rule: collector `aee6f0` Completed on both devices, sensors `a890ba` all six passed (`logon_gp_duration_ms` -2 on both, `logon_gp_start_time` no value as the manifest now expects, shell-ready and total unchanged at 1590 and 2080 ms).

**Review notes.** `TotalLogonDurationSec` is based on Winlogon event 7001, which fires almost at logon time, so expect 0 to 1 second rather than real time-to-desktop (and Unknown on Windows 11, see above). Registry and task failures only warn.

### 8.4 `Measure-LogonDurationMultiSession.ps1`

| Field | Value |
|---|---|
| Path / version | `GenericTroubleshooting\WindowsStartup\Measure-LogonDurationMultiSession.ps1`, collector v2.1.1 (2026-11-05: .NET `EventLogReader` for every event query, provider fallback reads System and Application, 13.2.z; 2.1.0 on 2026-11-03: authentication, Winlogon subscriber, pre-shell gap, startup app and explained/unexplained phases) |
| Inventory | NOT IN CSV |
| Inputs | `DeployMode`, `SessionScope` (`LastLogon`, `AllActive`, `AllSince`, `AllUsers`), `AllUsers`, `LookbackHours` (24), `MaxSessions` (50), `TargetUser`, `ExcludeUserPattern`, `AggregateWindowHours` (24), `TimeBudgetSeconds` (240), `RepeatMinutes` (15), `ConfigureLoggingFirst`, `NoExit`; each as parameter or `$env:` |
| Prerequisites | `TerminalServices-LocalSessionManager/Operational` log; elevation |
| Automated coverage | none (UEM skip); manual SYSTEM run through `AutomatedTesting\Start-SystemRun.ps1` |

**Purpose.** Multi-session variant for shared hosts. Measures every attributable logon, writes per-user records under `...\LogonDuration\Sessions\<SID>`, the newest to the flat key, and P50/P95 aggregates under `...\LogonDuration\Aggregate`. Can install a recurring SYSTEM task.

**Test steps**

1. Log on two users (console plus RDP). Elevated: `.\Measure-LogonDurationMultiSession.ps1 -AllUsers -NoExit`. Expect `-- Event source resolution ---`, a `-- Measured ---` table with one row per user, `-- Aggregate ---` with P50/P95, and the readback for all three keys.
2. `-SessionScope AllSince` twice: second run prints `No sessions in scope need measuring. Refreshing the aggregate only.`
3. Task: `-DeployMode DeployScheduledTask -ConfigureLoggingFirst $true`. Verify the task shows `AtLogOn (30s delay) + every 15 minute(s)`.
4. Verify `Get-ChildItem HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration\Sessions` has one key per user; aggregate `SessionCount` equals distinct users.
5. Restore: unregister `DEXTools_MeasureLogonDurationMultiSession`, remove the DEXTools folder and the LogonDuration key.

**Status:** `TESTED - MANUAL`. Run on 2026-11-02 at 12:34 on the lab VM `CBRADLEYSWIN11` as SYSTEM through `AutomatedTesting\Start-SystemRun.ps1 -Arguments "-DeployMode RunNow"` (one-shot scheduled task, the way Hub would run it), collector 2.0.1, exit 0. 2.1.1 (2026-11-05, .NET `EventLogReader`): a scratch run on this VM redirected to HKCU wrote a session record identical to 2.1.0's across all 41 values in 5.6 s instead of 18.3 s. Nine event sources resolved via the event log, FSLogix reported `ProviderMissing` (no FSLogix on the VM, expected). One console session in the 24 h window was measured: `CBRADLEYSWIN11\chase`, logon 09:14:38, shell ready 3.18 s later (`ShellReadySource = ExplorerProcess`), Group Policy 1.03 s, profile load 0.3 s, Active Setup 19.21 s, AppX 18.55 s, 10 logon tasks totalling 67.47 s, 0 printers. All three keys were written and read back: `HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration` (most recent logon, 29 values, `Provisional = False`), `...\Sessions\S-1-5-21-...-1001` (per-user record) and `...\Aggregate` (P50/P95/Max/Mean 3.18 s, 1 session). Phase durations larger than the total are expected: the total stops at shell ready while the scoped phases keep running in the background. Log `C:\Temp\FixReport\SystemRun\Measure-LogonDurationMultiSession-20261102-123455.log`, copied to the evidence bundle under `lab-results\SystemRun\`. At 87,435 characters the script cannot be published to UEM as a single script (limit 32,767), so the UEM manifest skips it and this manual SYSTEM run is the highest status available; the two-user case (console plus RDP, step 1 above) remains manual.

**Review notes.** `$script:ExitCode` is never set to anything but 0, so every path exits `0`, including no logons found and write failures. Sensors should map `Ambiguous` to -4.

---

## 9. MDM command scripts

The first three end or weaken the console session and must never be run through the harness or against a VM you are working from. The Windows Update on/off pair (9.4, 9.5) changes update behaviour on whatever device it lands on, so it is also skipped in `uem-tests.json` and tested on the lab VM by hand. All five are skipped in `uem-tests.json`.

### 9.1 `DEX_Invoke-SignoffWindows.ps1`

| Field | Value |
|---|---|
| Path / version | `MDMCommands\DEX_Invoke-SignoffWindows.ps1` |
| Inventory | `4) Complete - Tested`, impact High |
| Inputs | none from UEM (`-CurrentUser` exists on the inner block but is never passed, so it always signs off every session) |
| Prerequisites | `query session`, `logoff` |
| Automated coverage | `uem-tests.json` skip |

**Purpose.** Parses `query session` and runs `logoff <id>` for every Active or Disconnected session, console user last.

**Test steps**

1. Have a disposable user logged on (console or RDP). Run as SYSTEM from a different session (`PsExec64 -s` from RDP, or a scheduled task).
2. Expect `Signing off all active user sessions.`, `Logging off session ID: n` per session with the console one labelled last, exit `0`.
3. Verify `query session` shows no Active or Disc user sessions; Security log 4647/4634 for the users.
4. Empty box: `No active user sessions found.`, exit `0`.

**Status:** `PASS - UEM` through the single-VM group. UEM run `80650c` (2026-10-30, group `Test_JSpencerOnly`, high-impact gate lifted): `Completed` on `CHASEWIN11_2`, with Hub reporting after the sign-off because it runs as SYSTEM; result file `test-result-solo-signoff.json` in the connector folder. Device-side proof is Winlogon event 7002 on that VM. Still never run against a group that contains the observing machine; the connector enforces this with the manifest's `onlyInGroup`.

**Review notes.** Destroys unsaved work. `SupportsShouldProcess` is declared but never wired to an input, so it is always live. Em dash and box-drawing characters inside the file; the BOM keeps them intact. Any purely numeric token is treated as a session ID.

### 9.2 `DEX_LockDevice-BitlockEncryptionActivated.ps1`

| Field | Value |
|---|---|
| Path / version | `MDMCommands\DEX_LockDevice-BitlockEncryptionActivated.ps1` |
| Inventory | `3) Complete - Needs Testing`, impact Critical |
| Inputs | none |
| Prerequisites | BitLocker-enabled `C:` |
| Automated coverage | `uem-tests.json` skip |

**Purpose.** Runs `manage-bde -protectors -disable C:` then `shutdown /s /f /t 0`. The inventory describes this as intended: "device decommission or emergency scenarios where encryption must be suspended before power-off". It is not a screen lock.

**Test steps.** Snapshot, hold the recovery key, run as SYSTEM, power on, confirm `manage-bde -status C:` shows `Protection Status: Protection Off`, then `manage-bde -protectors -enable C:`. Negative path on a VM without BitLocker: expect `An error has occured: manage-bde -protectors -disable C: returned <code> ...` and exit `1` with no shutdown.

**Status:** `PASS - UEM` for both paths on v1.3.0: positive (run `1b5fcb`, 2026-10-30) and negative (run `389aa4`, executed 2026-11-04 08:26 on the decrypted `CHASEWIN11_2`: `Failed`, `ScriptNonSuccessReturnCode`, device still checking in six minutes later; row 60). Tested under the action-script rule. BitLocker was enabled on `CHASEWIN11_2` first with a password protector and the no-TPM policy (the VM has no vTPM), UEM confirmed `BitLockerProtectionPresent`, then the script ran as SYSTEM through the single-VM group and Hub reported `Completed` 13 seconds after the sync. Device-side evidence from the operator: System event 1074 at 13:45:30, source `shutdown.exe`, user `NT AUTHORITY\SYSTEM`, type `shutdown`, comment "Emergency lock-down: BitLocker protectors suspended, powering off" (the v1.3.0 message), and no 1075 abort. A second 1074 at 13:25:04 with an empty comment is the v1.2.0 run `534500`, so that run also reached its in-process `shutdown /t 0`; its "no result" was purely the reporting race, as diagnosed. `manage-bde -status C:` afterwards showed `Protection On`, which is what `manage-bde -protectors -disable` without `-RebootCount` produces after one restart, so no manual re-enable was needed. The kernel log closes it: Kernel-General event 13 (shutting down) at 13:45:49, four seconds after the 15-second timer expired, and event 12 (started) at 13:48:53, which is also the device's `LastBootUpTime`; the v1.2.0 run shows the same pair at 13:25:11 and 13:31:48. So each run suspended the protectors and powered the VM off, and the VM came back on its own three to six minutes later without the operator booting it (a Fusion or host behaviour worth checking, not a script matter). For a real decommission the console check at boot is: boot the VM (no startup password while protectors are suspended), confirm `manage-bde -status C:` shows `Protection Off`, then `manage-bde -protectors -enable C:`. The v1.2.0 attempt (run `534500`, same day) ended as no result because that version ran `shutdown /t 0` in-process and the OS tore the host down before Hub could report; v1.3.0 hands the power-off to `shutdown.exe`'s 15-second timer instead, so the status is definitive. The negative path (unprotected device, expect `Failed` with no shutdown) is still unproven on v1.2.0+; prove it on a decrypted VM by setting `expect` to `Failed`. The v1.2.0 negative path (unprotected device, expect `Failed` with no shutdown) is still unproven, because the VM was encrypted before v1.2.0 could run against it; prove it on a decrypted VM by setting `expect` back to `Failed`.

**History.** First UEM run on v1.1.0 against the single-VM group on 2026-10-30 (run `c8e0dd`). UEM reports that VM as `BitLockerProtectionNotPresent`, so the expected result was `Failed` with no shutdown. Instead the run ended `NoResult` and the device stopped checking in: a `DeviceQuery` control sent to the observing VM advanced its last-seen time within two minutes, while the target's stayed at the previous run's timestamp, so the VM powered off. Conclusion: in v1.1.0 `manage-bde -protectors -disable C:` did not return a non-zero exit code on that volume, and the exit-code guard let the script reach `shutdown /s /f /t 0`. Fixed in v1.2.0 (parse-checked): the script now requires `Get-BitLockerVolume C:` to report `ProtectionStatus On` before the suspend and `Off` after it, and treats `ERROR:` text from `manage-bde` as a failure; any other state throws and exits `1` without powering off. The VM was booted afterwards (it had no protectors to re-enable), BitLocker was enabled on it, the v1.2.0 attempt (run `534500`) ended as no result because of the in-process `/t 0`, and the v1.3.0 positive path passed as run `1b5fcb` above.

**Review notes.** Fixed: added a header stating the intent and the clear-key exposure, the catch block now prints the error, and both native commands are exit-code checked so a failed `manage-bde` no longer proceeds to shutdown. The name remains misleading; consider renaming to make "suspend BitLocker and power off" explicit.

### 9.3 `DEX_Start-LockDeviceSoft.ps1`

| Field | Value |
|---|---|
| Path / version | `MDMCommands\DEX_Start-LockDeviceSoft.ps1` |
| Inventory | `4) Complete - Tested`, impact Low |
| Inputs | none |
| Prerequisites | An active console session, `tsdiscon.exe` |
| Automated coverage | `uem-tests.json` skip |

**Purpose.** `tsdiscon.exe console`: disconnects the console session to the lock screen, keeping processes alive.

**Test steps**

1. User at the console. Run as SYSTEM via scheduled task or `PsExec64 -s`.
2. Expect the console to switch to the lock screen; `query session` shows the user `Disc` and `console` as `Conn`; `Get-Process -IncludeUserName` still lists the user's processes; exit `0`.
3. User unlocks normally. No restore needed.

**Status:** `PASS - UEM`. Ran through UEM against the single-VM group `Test_JSpencerOnly` on 2026-10-30 (run `496916`, `Completed` on `CHASEWIN11_2` about 200 s after the sync, exit `0`). The console session dropped to the lock screen and the user signed back in afterwards. Still never run it against a group that contains the observing machine.

**Review notes.** With no console user the `tsdiscon` error is swallowed and exit is still `0`. `$WhatIfPreference` is checked but never settable.

### 9.4 `DEX_Stop-WindowsUpdate.ps1`

| Field | Value |
|---|---|
| Path / version | `MDMCommands\DEX_Stop-WindowsUpdate.ps1`, 1.0.0 |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | `$env:WhatIf` (dry run); `-NoPause` switch (console/image builds only). Tunables hard-coded: `$PauseUpdates`, `$PauseDays`, `$StopEvenIfInstalling`, `$StopTimeoutSeconds` |
| Prerequisites | `wuauserv` present; elevated (SYSTEM) session; `sc.exe` |
| Automated coverage | `uem-tests.json` skip |

**Purpose.** Turns Windows Update off: sets `wuauserv` to Disabled, stops it (`sc.exe stop` plus a 20 s poll), and writes the six Settings-app pause values under `HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings` for 35 days. Declines (exit 0) while the Windows Update Agent reports an install in progress. Stamps `HKLM:\Software\AirWatch\Extensions\WindowsUpdateControl`. Guide: `MDMCommands\WindowsUpdate-OnOff-Guide.md`.

**Test steps**

1. Snapshot the VM. Precondition: `Get-Service wuauserv` is `Running / Manual`; `Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' | Select Pause*` shows no values.
2. Dry run: `$env:WhatIf='true'; powershell.exe -File .\DEX_Stop-WindowsUpdate.ps1`. Expect a `[Before]` block, three `What if:` lines (start type, stop, pause), no `[After]` block, exit `0`, no registry stamp written.
3. Live run as SYSTEM (`PsExec64 -s` or a scheduled task), `$env:WhatIf` unset. Expect `wuauserv start type set to Disabled.`, `wuauserv stopped.`, `Updates paused until <date> (UTC).`, an `[After]` block showing `Stopped / Disabled` and `paused until`, exit `0`.
4. Verify: `Get-Service wuauserv` is `Stopped / Disabled`; the six `Pause*` values exist with ISO 8601 UTC strings 35 days apart; the stamp key has `Mode=Off`, `Status=Completed`, `PauseUntil`. Settings > Windows Update shows "Updates paused until".
5. Idempotency: run again. Expect `already Disabled`, `already stopped`, pause rewritten, exit `0`.
6. Install-in-progress path: start a large install (or run 9.5 in Direct mode and wait for `Status=Running`), then run this script. Expect `SKIPPED: an update is installing right now`, exit `0`, service untouched, `Status=SkippedInstalling`.
7. Restore: run 9.5 with `$InstallMode = 'None'`, or revert the snapshot.

**Status:** `PASS - UEM`. Parse-checked under Windows PowerShell 5.1 and PowerShell 7 and dry-run on the lab VM 2026-10-29. Ran live through UEM as SYSTEM against the single-VM group `Test_JSpencerOnly` on 2026-11-02 (run `8a63e2`): `Completed`, reported 206 s after the sync. Action script under the Full Pass rule: UEM `Completed` plus the pause and stopped service it leaves behind is the pass; `DEX_Start-WindowsUpdate.ps1` ran next on the same VM to undo it, then the VM is reverted to its snapshot. Steps 3 to 6 remain the manual way to inspect the state it sets.

**Review notes.** The hold is deliberately bounded: `WaaSMedicSvc` resets the start type within about a day and the pause expires after 35 days. Both are documented in the guide. Stopping the service is guarded by `ShouldProcess`; the `sc.exe` call does not honour `$WhatIfPreference` on its own.

### 9.5 `DEX_Start-WindowsUpdate.ps1`

| Field | Value |
|---|---|
| Path / version | `MDMCommands\DEX_Start-WindowsUpdate.ps1`, 1.0.0 |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | `$env:WhatIf` (dry run); `-Mode Orchestrator|Direct|None` and `-Wait` (console/image builds only; `-Wait` runs the Direct payload inline and returns 0, 3010 or 1); `-RunAsPayload` (internal, set by the Direct-mode task and by `-Wait`). Tunables hard-coded: `$InstallMode` (`Orchestrator`, `Direct`, `None`), `$ResumePause`, `$IncludeDrivers`, `$StartTimeoutSeconds`, `$UsoWaitSeconds`, `$DirectTimeLimitHrs`, `$DirectDeadlineMin` |
| Prerequisites | `wuauserv` present; elevated (SYSTEM) session; `UsoClient.exe` (Windows 10 1607+); Direct mode needs an AV/EDR exclusion for `C:\ProgramData\AirWatch\Extensions\` |
| Automated coverage | `uem-tests.json` skip |

**Purpose.** Turns Windows Update on and makes the device update now: sets `wuauserv` back to Manual if Disabled, starts it (`sc.exe start` plus a 15 s poll), removes the six pause values and runs `UsoClient ResumeUpdate`, then either asks the orchestrator for `RefreshSettings` and `ScanInstallWait` (default), or registers the hidden SYSTEM task `WS1_DEX_WindowsUpdateInstall` that runs this same file with `-RunAsPayload` and installs everything applicable through the Windows Update Agent COM API (search, download, install; global mutex; 150 min phase deadline; 3 h task cap; log at `%SystemRoot%\Temp\UEM_DEX_Start-WindowsUpdate.log`). Never restarts the device.

**Test steps**

1. Precondition: the device is in the 9.4 "off" state (`Stopped / Disabled`, paused). Have at least one applicable update (`(New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0 and Type='Software'").Updates.Count` is greater than 0); a VM a month behind is ideal.
2. Dry run: `$env:WhatIf='true'`. Expect `[Before]` block, `What if:` lines for start type, start, clear pause and the orchestrator trigger, exit `0`, no changes.
3. Live run, Orchestrator mode, as SYSTEM. Expect `wuauserv start type set to Manual.`, `wuauserv started.`, `UsoClient ResumeUpdate returned 0`, `Pause cleared.`, `UsoClient RefreshSettings returned 0`, `UsoClient ScanInstallWait returned 0` (or the "still running" line), `[After]` showing `Running / Manual` and `not paused`, exit `0`, in under 35 s.
4. Verify within 5 to 30 minutes: Settings > Windows Update shows a scan or download in progress and then installs; `Get-WindowsUpdateLog` shows a scan started by `UsoClient`; the stamp has `Mode=On`, `Status=Triggered`.
5. Direct mode: set `$InstallMode = 'Direct'` in a copy and run as SYSTEM. Expect `the Direct install task 'WS1_DEX_WindowsUpdateInstall' is running as SYSTEM`, exit `0`. Verify `Get-ScheduledTask WS1_DEX_WindowsUpdateInstall` is `Running`, the log fills with `Searching`, `Queued:`, `Downloading`, `Installing`, and the stamp moves `Dispatched` to `Running` to `Completed` with `Found`, `Installed`, `Failed`, `RebootRequired`. The task is gone when the payload finishes.
6. Concurrency: run Direct mode twice in quick succession. Expect the second run to print `A Direct-mode install is already running`, exit `0`.
7. Negative path: with `wuauserv` broken (`sc.exe config wuauserv binPath= bad` on a snapshot), expect `wuauserv did not reach Running`, exit `1`, `Status=Failed`. Revert the snapshot.
8. Restore: nothing required beyond letting the device restart if `RebootRequired` is true.

**Status:** `PASS - UEM`. Parse-checked under Windows PowerShell 5.1 and PowerShell 7, WhatIf dry run and the payload's read-only WUA search exercised on the lab VM 2026-10-29. Ran live through UEM as SYSTEM against the single-VM group `Test_JSpencerOnly` on 2026-11-02 (run `48bf63`), straight after `DEX_Stop-WindowsUpdate.ps1` on the same VM: `Completed`, reported 417 s after the sync. Action script under the Full Pass rule: UEM `Completed` plus the re-enabled service and the scan it triggers is the pass; the VM is reverted to its snapshot afterwards. Steps 3 to 7 remain the manual way to inspect what it set.

**Review notes.** Orchestrator mode honours the device's `AUOptions`; with a notify-only policy it downloads and waits for the user, which the script warns about. `IUpdateInstaller.Install()` is synchronous, so inside the payload the 150 min deadline is only checked between phases and the task's 3 h `ExecutionTimeLimit` is the hard stop. `UsoClient` is launched with `UseShellExecute` so a child that outlives the script does not hold Hub's stdio handles.

---

## 10. VPN scripts

### 10.1 `Invoke-AutoRemediateGenericVPN.ps1`

| Field | Value |
|---|---|
| Path / version | `VPN\Invoke-AutoRemediateGenericVPN.ps1` |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | `$env:WhatIf`; tunables hard-coded (`TargetTunnelMtu` 1400, ceiling 1500, floor 1280) |
| Prerequisites | A non-hardware adapter not matching the exclusion regex (Hyper-V, WSL, Docker, VMware, VirtualBox, Bluetooth, Loopback and others), so a real VPN client or WireGuard |
| Automated coverage | none |

**Purpose.** Six steps on the Windows side of a tunnel: Multiple VPN Clients (warn), VPN Support Services (`RasMan`, `IKEEXT`, `BFE`), Tunnel MTU (set to 1400), Tunnel DNS (flush and register), Orphaned Tunnel Routes (remove from ActiveStore), Tunnel Adapter Bounce (disabled by default). Never reconnects a tunnel. Caches to `HKLM:\Software\AirWatch\Extensions\VPN\Remediation`.

**Test steps**

1. Install WireGuard and activate a tunnel with `Address = 10.99.0.2/32` and a dummy peer; the interface comes up without a handshake.
2. Break: `Set-NetIPInterface -InterfaceAlias <wg> -AddressFamily IPv4 -NlMtuBytes 1500`; `Set-DnsClientServerAddress -InterfaceAlias <wg> -ResetServerAddresses`; `Stop-Service RasMan -Force; Set-Service RasMan -StartupType Disabled`.
3. Dry run with `$env:WhatIf='true'`: expect `[Failed ]` lines, `Dry run: results not cached to the registry.`, no change.
4. Live run. Expect `[Failed ] VPN Support Services: Service(s) not available: RasMan (Stopped) -> Remediation ran`, `[Failed ] Tunnel MTU: Tunnel MTU is 1500 ... -> Remediation ran`, `[Failed ] Tunnel DNS ... -> Remediation ran`, exit `0`.
5. Verify `(Get-NetIPInterface -InterfaceAlias <wg> -AddressFamily IPv4).NlMtu` is 1400; `Get-Service RasMan` Running and Manual; registry `LastRun` updated; log `C:\Windows\Temp\UEM_AutoRemediateGenericVPN.log`.
6. Lab VM without a tunnel adapter: `No VPN client present on this device. Nothing to process.`, exit `0`.
7. Restore: `Set-Service RasMan -StartupType Manual`, remove the WireGuard tunnel.

**Status:** `NEEDS TEST - PRODUCT VM`. UEM sweep `6c8405` (2026-10-29) reported `Completed` on both lab devices, which proves only the not-installed path (result file `test-result-scripts.json` in the connector folder).

**Review notes.** `RasMan` and `IKEEXT` are Manual-start and normally stopped when idle, so step 2 reports Failed and starts them on every run on any device with a tunnel adapter. Detection-only failures do not change the exit code; only a thrown remediation does.

### 10.2 `Invoke-VpnStateCollection.ps1`

| Field | Value |
|---|---|
| Path / version | `VPN\Invoke-VpnStateCollection.ps1` |
| Inventory | `3) Complete - Needs Testing`, impact Low |
| Inputs | none |
| Prerequisites | Same adapter detection as 10.1; `NetworkProfile/Operational` and `RasClient` events |
| Automated coverage | none |

**Purpose.** Caches 13 VPN state values and a health score (100 minus deductions for tunnel down, MTU, DNS, discards, flaps, failures, multiple clients) to `HKLM:\Software\AirWatch\Extensions\VPN` for lightweight sensors.

**Test steps**

1. Lab VM: run. Expect `No VPN client detected on this device.`, `HealthScore = -1`, `HealthReason = NoVpnClient`, `VPN state cached to ...`, exit `0`.
2. With the WireGuard tunnel from 10.1 at MTU 1500: expect `Active tunnel: ...`, `Health score: 80 (MtuNotReducedForTunnel)`.
3. With DNS reset: `NoDnsOnTunnel` deduction.
4. Verify `Get-ItemProperty HKLM:\Software\AirWatch\Extensions\VPN` shows `Connected`, `TunnelMode`, `TunnelMtu`, `ClientCount`, fresh `LastRun`; log `C:\Windows\Temp\UEM_VpnStateCollection.log`.

**Status:** `PASS - LAB` and `PASS - UEM` on 1.0.1 (2026-11-02). Break test `VPN\_AutomatedTesting\Invoke-VpnStateCollection_BreakTest.ps1` (13.1) passed all four breaks against the lab WireGuard tunnel (`e73c23ecf1ac`, `f26937f84576`, `01c6dadd22f9`, `b91e95203a31`); UEM run `709d52` reported `Completed` on both VMs and wrote the connected row on `CBRADLEYSWIN11`. Steps 2 and 3 above (MTU 1500 and DNS reset deductions) are not yet exercised; they belong with the 10.1 break test. 1.0.0 crashed on any device with a tunnel (13.2.q).

**Self-refreshing cache: 1.1.0 designed and built 2026-11-02, hardened to 1.1.2 and Full Pass under Hub on 2026-11-03 (results at the end of this block).** The thirteen sensors were thin readers of a cache that was only as fresh as the collector's last scheduled run. Collector 1.1.0 now also writes `StateFingerprint` (per candidate adapter: ifIndex, Status, IPv4 MTU, IPv4 DNS servers), `LastChecked`, and persists its own text to `C:\ProgramData\AirWatch\Extensions\VPN\Invoke-VpnStateCollection.ps1` with a protected ACL (owner Administrators; SYSTEM and Administrators full, Users read) and the file's SHA-256 in `CollectorHash`; with `VPN_COLLECTOR_QUIET=1` it writes its log but nothing to the output stream. The ten signed-off sensors (1.1.0) carry an identical 34-line gate: cache checked within 15 minutes, read it; otherwise compute the fingerprint, and if it matches stamp `LastChecked` and read; if it differs, verify the persisted copy's hash and run it (bounded at 40 s, hidden window, never inheriting Hub's output pipe), then read; on any failure read the existing cache and, for `vpn_health_reason` only, append `;Stale`. Hub runs a device's sensors one after another, so the first sensor in a sample pays for one refresh and the rest take the fast path. Five sensors that had enumerated adapters live (`vpn_connected`, `vpn_tunnel_mode`, `vpn_adapter_name`, `vpn_tunnel_mtu`, `vpn_dns_configured`) now read the cache like the rest, since the fingerprint covers what they used to read. The three parked sensors are untouched. Lab proof: `VPN\_AutomatedTesting\Test-VpnSensorGate.ps1` (elevated) runs the collector, then drives `vpn_health_score` and `vpn_health_reason` through four scenarios in fresh `powershell.exe` processes: fresh cache, stale but unchanged fingerprint, stale and changed fingerprint (collector rerun), and a tampered hash (cache read, `Stale` appended); each must emit exactly one line. The 1.1.0 collector's persist, ACL and new values were already exercised once on the no-client branch at 23:55 on 2026-11-02. Gate test run 2026-11-03 08:43 with the tunnel up: PASSED, every assertion. Fingerprint `24|Up|1420|10.99.0.2`; fresh cache read in 0.9 s; stale-but-unchanged bumped `LastChecked` in 5 s; stale-and-changed reran the persisted collector in 11.1 s with `LastRun` refreshed and the hash intact; tampered hash fell back to the cache in 4.2 s with `vpn_health_reason` emitting `Healthy;Stale`; restore run left `Healthy`. Collector 1.1.0 and the ten sensors are therefore `PASS - LAB` for the gate. UEM proof, 2026-11-03 (UEM-API-TESTING-SPEC.md has the run ids): part one, collector run then sensor sweep with the tunnel up, returned the connected row from `CBRADLEYSWIN11` and showed the cheap path firing under Hub (`LastChecked` bumped three seconds past the fifteen-minute mark, `LastRun` untouched). Part two, tunnel deactivated in the WireGuard app and the ten sensors run again with no collector run: the first sensor past the gate saw the fingerprint change, verified the hash, reran the persisted copy quietly, and the sweep reported the no-client row (`-1`, `NoVpnClient`, False, None, empty, `-1`, `-1`, 0, `-1`) with `LastRun` 09:30:24, so the architecture works end to end under Hub. One defect fell out (13.2.t): in the child `powershell.exe` the sensor spawned from Hub's sensor host, `Get-FileHash` was "not recognized", so the quiet rerun logged a WARN and wrote `CollectorHash` empty, which would have left the cache unrefreshable until the next scheduled collector run. 1.1.1 (collector and the ten sensors) hashes with .NET `SHA256` instead and logs the child's PowerShell version and `PSModulePath`; Part three on 1.1.1 (collector `ee64c2` with the tunnel down, tunnel back up, sweep `90b8b9` at 10:12): all ten sensors passed on both devices and the quiet rerun did its job from inside the Hub-spawned child, which the collector's new Host line shows is Windows PowerShell 5.1.26100 with `Get-FileHash` unavailable and the 7-shaped `PSModulePath` inherited from Hub's own PowerShell 7.2 host (13.2.t); it found the candidate adapter and wrote the connected row, so the child sees the adapter cmdlets. The same sweep exposed a race (13.2.u): Hub runs sensors on parallel threads, two of them launched the collector in the same second, and the loser clobbered the hash and briefly wrote `CollectionError`. 1.1.2 serialises the gate and the collector with named mutexes. Gate test rerun on 1.1.2 at 10:28: PASSED, every assertion (hash `43079737…C82F`; fresh read 0.9 s, cheap path 5.6 s, quiet rerun 13.9 s with the hash intact, tampered hash fell back in 5.3 s with `Healthy;Stale`); the device log shows the UEM collector run `3815` and the gate test's own collector `8437` starting ten seconds apart and the second one waiting on the mutex, so the collector lock works. Part four under Hub, 11:53 (collector 1.1.2 run `fb88b1` at 10:28 with the tunnel up, both tunnels deactivated, sweep `4514e3` with no collector run): PASSED on the device. The collector log shows exactly one quiet rerun (7907, 11:56:13 to 11:56:23) from the Hub-spawned 5.1 child, the persisted hash unchanged before and after, and the no-client row written at 11:56:21; UEM holds a clean no-client row from both devices for all nine value-emitting sensors (`-1`, `NoVpnClient`, False, None, empty, `-1`, `-1`, 0, `-1`; `vpn_dns_configured` emits nothing by design), and the cheap path bumped `LastChecked` at 12:11:32 without touching `LastRun`. The connector itself died on a UEM API timeout (HTTP 999) before writing its result file, so the values were read back from the device sensors endpoint afterwards (bundle file `sensor-values-vpnsensors112-4514e3.txt`). Collector 1.1.2 and the ten gated sensors are therefore `PASS - LAB` and `PASS - UEM`: Full Pass, with 13.2.t and 13.2.u closed. `CHASEWIN11_2`, back online for part two, reported `Healthy;Stale`: its cache came from collector 1.0.1 and has no fingerprint or hash, which is the designed fallback until a 1.1.x collector runs there. Hub also logs an `[ERR]` "invalid because expected type is BOOLEAN" each time `vpn_dns_configured` emits nothing on a no-client device; the sample is dropped, which is the documented intent, but the noise is worth knowing about.

**Review notes.** Confirmed on the lab tunnel (13.2.o): flap and last-connect correlation compares NetworkProfile event text to the adapter `InterfaceDescription`, but the event carries the adapter `Name`, so `FlapCount24h` is always 0 on real tunnels; the built-in Windows VPN client is invisible to the structural test; and Up plus an IPv4 address scores 100 Healthy even with a dead peer. Any virtual adapter not in the exclusion list (Tailscale, ZeroTier, WARP, OpenVPN TAP) counts as a VPN client.

---

## 11. Reboot scripts

### 11.1 `Invoke-RebootWithUserDefer.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsReboot\InteractiveReboot\Invoke-RebootWithUserDefer.ps1`, v1.2.0.7 |
| Inventory | `4) Complete - Tested`, impact High |
| Inputs | none; hard-coded `$MaxHours = 4`, `$ShowEveryMinutes = 30`, `$RebootCountdownSeconds = 300`, `$PollMinutes = 5` |
| Prerequisites | SYSTEM, Task Scheduler, WinRT toast APIs, logged-on users; deployed by Product Provisioning |
| Automated coverage | `uem-tests.json` skip |

**Purpose.** Drops `UserToast.ps1` and `RebootMainThread.ps1` under `C:\ProgramData\AirWatch\Extensions\AdvancedReboot`, registers `\WorkspaceOneEx\RebootPrompt-Orchestrator` (SYSTEM, every 5 minutes), which toasts each active user every 30 minutes and forces a reboot when the deadline passes.

**Test steps** (snapshot first)

1. In a scratch copy set `$MaxHours = 24`. Run as SYSTEM (`PsExec64 -s`) with a user logged on.
2. Expect within about 2 minutes a "Reboot available" toast with "Reboot now" and "Not now". Verify `Get-ScheduledTask -TaskPath '\WorkspaceOneEx\'` shows the orchestrator and `Get-ItemProperty HKLM:\Software\AirWatch\Extensions\AdvancedReboot` shows `FirstRunAt` and `Deadline`.
3. Deadline path (ends the session): set `$MaxHours = 0`, rerun, expect `shutdown.exe /r` within one poll and System log 1074. Abort with `shutdown /a` if needed.
4. After a reboot the orchestrator removes the task, key and helper scripts on its next poll.
5. Restore: unregister everything under `\WorkspaceOneEx\`, remove the AdvancedReboot registry key and folder, remove `HKCU:\Software\Classes\rebootcountdown|rebootabort|rebootlater`.

**Status:** `PASS - UEM` for the install path through the single-VM group. UEM run `ea5217` (2026-10-30, group `Test_JSpencerOnly`, high-impact gate lifted, user signed in): `Completed` on `CHASEWIN11_2`, which means the orchestrator task and helpers were written and registered under Hub; result file `test-result-solo-rebootdefer.json` in the connector folder. Fixed 2026-10-29; main script and both extracted helpers parse clean under PowerShell 5.1. The deferral flow itself (toast, defer, countdown, forced reboot at the deadline) still needs the manual steps 1 to 4 on that VM, then a revert to the snapshot, because the orchestrator persists and keeps prompting.

**Review notes.** Fixed: `if($mandatoryReboot=$true)` (assignment) is now a comparison, so the no-users path reboots only after the deadline; `Write-Log` is defined inside the orchestrator and appends to `RebootPrompt.log` under the AdvancedReboot folder; `$shutdown` is assigned before the protocol handler commands are built, so "Reboot now" and the abort handler are well-formed; the task Description stamp and `Deadline` value are ISO round-trip strings and are parsed invariantly; the leaked `New-ItemProperty` output is suppressed. Remaining, harmless: the toast writes a per-user `Deadline` value that is never read (the reader uses `DeadlineAt`), `Deferrals` is never populated, a verbose line references two undefined path variables, and the file has no version string (the readme says 1.2.0.7).

### 11.2 `Invoke-SimpleReboot.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsReboot\InteractiveReboot\Invoke-SimpleReboot.ps1` |
| Inventory | `4) Complete - Tested`, impact High |
| Inputs | none; `$CountdownSeconds = 300` |
| Prerequisites | `shutdown.exe`, PS 5.1 (`Get-WmiObject`) |
| Automated coverage | `uem-tests.json` skip |

**Purpose.** With a console user: `shutdown.exe /r /f /t 300` with a message. Without: forced reboot after 10 seconds (1.0.1; was `/t 0`, which could tear the process down before Hub recorded the result).

**Test steps**

1. Console user logged on, elevated run. Expect `Console user detected: <user>`, `Scheduling reboot in 300 seconds...`, the Windows sign-out banner, exit `0`.
2. Within 300 seconds `shutdown /a`. System log shows 1074 then 1075.
3. No-user branch: disposable snapshot only; reboots immediately.

**Status:** `PASS - UEM` through the single-VM group. UEM run `f3996a` (2026-10-30, group `Test_JSpencerOnly`, high-impact gate lifted): `Completed` on `CHASEWIN11_2`, which then restarted on the countdown and checked back in at 11:01; result file `test-result-solo-simplereboot.json` in the connector folder. Device-side proof is System event 1074 on that VM. The connector's `onlyInGroup` guard keeps it away from any group containing the observing machine.

**Review notes.** 1.0.1 (2026-10-30, parse-checked, not re-run): the no-user branch schedules the reboot 10 seconds out instead of `/t 0`, so Hub records the result in both branches, and the `manueagement` typo is fixed. Does not detect an already pending shutdown (error 1190) and still exits `0`.

### 11.3 `SmartReboot.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsReboot\SmartReboot\SmartReboot.ps1` |
| Inventory | `4) Complete - Tested`, impact Low |
| Inputs | none |
| Prerequisites | Deployed as a UEM app with installer reboot exit code `1641`, Force Restart, detection `HKLM\SOFTWARE\AirWatch\Extensions\SmartReboot\InstallComplete = 0` |
| Automated coverage | none |

**Purpose.** Creates the detection key and exits `1641` on first run so UEM performs the reboot; exits `0` when the key exists.

**Test steps**

1. Local: `powershell -ExecutionPolicy Bypass -File .\SmartReboot.ps1; $LASTEXITCODE` is `1641`; nothing reboots outside UEM. Second run is `0`.
2. Verify `Get-ItemProperty HKLM:\SOFTWARE\AirWatch\Extensions\SmartReboot` shows `InstallComplete : 0`.
3. Re-arm: `Remove-Item -Path 'HKLM:\SOFTWARE\AirWatch\Extensions\SmartReboot' -Recurse -Force`.
4. UEM path: install the app on the test device and confirm the restart follows the assignment's deferral settings.

**Status:** `TESTED - MANUAL`.

**Review notes.** `New-ItemProperty -Force` without `Out-Null` prints the property object. No header or version in the script.

---

## 12. Recommended next actions

1. Done 2026-11-02: the six `PASS - LAB` scripts are `4) Complete - Tested` in the inventory under the Full Pass rule in 1.1.
2. All eleven `FIX FIRST` items were corrected on 2026-10-29 (see each script's review notes). Done 2026-11-02: the empty `Restart-WinProcessSoft.ps1` was deleted and the size table in the SCOM `DESIGN.md` was re-measured. `Restart-WinProcessGracefulEx.ps1` works again but remains a prototype superseded by `Restart-WinProcessGraceful.ps1`.
3. Done 2026-11-02: inventory rows added for the five SCCM scripts, `Get-AppVolumesMountProbe.ps1`, `Measure-LogonDurationMultiSession.ps1` and `Restart-WinProcessGracefulEx.ps1`, all at `3) Complete - Needs Testing`.
4. Done 2026-11-02: all thirteen break tests in section 13 ran and passed (run log in 13.5), the four `FIX FIRST` defects in 13.2 were fixed first, and the 13.3 collateral decisions are recorded. The three break tests written later that day (`Restart-WinService.ps1`, `Restart-WinProcessGraceful.ps1`, `Invoke-VpnStateCollection.ps1`) also ran and passed the same afternoon, the last against a live WireGuard tunnel, which exposed and fixed collector defect 13.2.q; the 1.0.1 collector then went back through UEM against both VMs (`709d52`, Completed, connected row written on the tunnel VM). Still on the lab VM: the BitLocker negative path on a decrypted `CHASEWIN11_2` (manifest expect `Failed`); the `Invoke-RebootWithUserDefer.ps1` toast and deferral checked by hand at the console; a re-run of the three WindowsLogon break tests against the 1.0.2 scripts (defect m fix, registry-only change); the undrawn `-BreakName` cases for SysMain and profile bloat; and the 13.2 defects e-l, which are documented but not scheduled.
5. Stand up one product VM each for Defender-adjacent (CrowdStrike, Trellix, Trend Micro), Microsoft 365 (Outlook, Teams), Zoom, SCCM, FSLogix and VPN, and work through the `NEEDS TEST - PRODUCT VM` group. SCOM is `DEFERRED` since 2026-10-30 and needs a decision on the remediation approach (agent upgrade versus restart or recycle) before any test.
6. Once a script passes here, add or adjust its `uem-tests.json` entry and run it through the UEM test group per `UEM-API-TESTING-SPEC.md`. The loop is proven end to end as of 2026-10-29 (`Invoke-AutoRemediateChrome.ps1` is `PASS - UEM`); the full `-Type Script` sweep ran as `6c8405` on 2026-10-29 and the single-VM group covered the session-ending scripts on 2026-10-30 and 2026-11-02, so the only UEM runs left are re-runs after a script changes and the product-VM group once those VMs exist.

---

## 13. Break tests written and run 2026-11-02

Thirteen `<Script>_BreakTest.ps1` files were added in the same pattern as the six driver and device tests (one `_AutomatedTesting` folder beside each target, `Invoke-AllBreakTests.ps1` discovers them by name, results go to `C:\Temp\FixReport\<ScriptUnderTest>\`). All thirteen parse-check clean under Windows PowerShell 5.1. They are destructive by design and run only elevated on the marked, snapshotted lab VM with `-Force -RemediationTest`. All thirteen were run on 2026-11-02 and all thirteen passed (13.5 has every attempt, including the harness and fixture faults fixed along the way). Each target is now Full Pass under the rule in 1.1. Each one was written after a full read of its target, and that reading produced the defect list in 13.2.

### 13.1 Files and coverage

| Target script | Break test | Breaks (expected outcome) | Not covered |
|---|---|---|---|
| `Invoke-RemediateMemoryCompression.ps1` | `WindowsAutoRemediation\Memory\_AutomatedTesting\` | MemoryCompressionDisabled (fixed) | the Get-MMAgent failure branch |
| `Invoke-RemediatePageFile.ps1` | same folder | PageFileManualUnderThreshold (reported only), PageFileManualNearCapacity (fixed, by lowering the script's own `PageFileUsageFailPercent` override to 0; the two are mutually exclusive per run) | system-managed-but-high-usage warning |
| `Invoke-RemediateSysMain.ps1` | same folder | SysMainService (fixed; stop, disable, manual variants), SysMainDisabledWhileRunning (fixed, expected to `FalsePass` until defect 13.2.c is fixed) | service removed |
| `Enable-HardwareAcceleratedGPUScheduling.ps1` | `WindowsAutoRemediation\Performance\_AutomatedTesting\` | HagsRegistryState (fixed; value 1 or value absent) | OS build, driver version, pending reboot (all hardware or TrustedInstaller-owned facts) |
| `Restart-WindowsUpdateServices.ps1` | `WindowsAutoRemediation\ProcessManagement\_AutomatedTesting\` | WuauservStopped, BitsStopped, CryptSvcStopped, UpdateStackStopped (all fixed; the last runs alone) | disabled service, msiserver, stale SoftwareDistribution (script never looks) |
| `Invoke-DriverUpdates.ps1` | `WindowsAutoRemediation\DriverUpdates\_AutomatedTesting\` | WuauservStopped (fixed) | driver discovery and install (a lab VM has no missing driver to inject), reboot signals, policy keys (script does not read them) |
| `Invoke-DefenderDynamicPerformance.ps1` | `AntiVirusResolutionScripts\MicrosoftDefender\_AutomatedTesting\` | CpuProfileDrift, ScoreCacheCorrupt (both fixed; two methods each) | silent drift while the profile marker matches (script skips by design, see 13.2.e) |
| `Invoke-AutoRemediateLogonTaskContention.ps1` | `WindowsAutoRemediation\WindowsLogon\_AutomatedTesting\` | AtLogOnTriggerDelay (fixed), AtLogOnTaskVolume (reported only; registers up to 10 `DEXTest` logon tasks) | none |
| `Invoke-AutoRemediateProfileBloat.ps1` | same folder | nine breaks, one per step, in a `DEXTestBloat` profile created through `CreateProfile`, or through a hidden logon when that call fails (0x800706F7 on the lab VM): UserTempFiles, BrowserCaches, TeamsCache, ExplorerIconCache, CrashDumps, ShaderCaches, RecentItems (fixed; each also plants a fresh control file that must survive), OversizedRoamingAppData, OversizedRegistryHive (reported only) | none |
| `Invoke-AutoRemediateAppXBloat.ps1` | same folder | InstalledDenyListedPackage (fixed; a loose-file `DEXTest.BloatProbe` full-trust main package registered under Developer Mode with `DenyListExtra=DEXTest.*`; a framework package cannot be registered that way (0x80073CF9)) | step 1 deprovisioning (needs a signed package) |
| `Invoke-AutoRemediateChrome.ps1` | `ApplicationSpecific\Chrome\_AutomatedTesting\` | CacheBloat (fixed), ExtensionCount (reported only), CrashLoop (reported only), OrphanedNativeMessagingHost (fixed; HKCU, HKLM, WOW6432Node variants) | Google Update service (no such service on the VM), enterprise policy (see 13.2.g) |
| `Invoke-AutoRemediateOneDrive.ps1` | `ApplicationSpecific\Microsoft\OneDrive\_AutomatedTesting\` | AutoStartAndProcess (fixed), AccountNotSignedIn, FilesOnDemandServiceDisabled, KfmPolicyDrift (reported only), FilesOnDemandServiceStopped (fixed) | sync-error detection (needs an event-log record that Restore cannot remove) |
| `Start-UserProfileCleanup.ps1` | `DiskCleanup\_AutomatedTesting\` | StaleOversizedProfile (fixed: `DEXTestProfile` deleted), UnderThresholdProfileKept, EnrollmentUserProfileKept (reported only). Runs a scratch copy with the constants set to 0 days, 32 MB, enrollment user `DEXTestEnroll`, and an added SID allow-list so only `DEXTest*` accounts are ever candidates | domain-joined behaviour, loaded-profile error path |
| `Restart-WinService.ps1` (added later on 2026-11-02) | `WindowsAutoRemediation\ProcessManagement\_AutomatedTesting\` | SpoolerStopped (fixed; stop, or Manual-and-stop), SpoolerDisabledAndStopped (reported only: the script never resets StartType, exit 1), UnknownServiceName (reported only: `DEXNoSuchService`, exit 1). One `ServiceName` per run, so one break per run (`-BreakCount` defaults to 1); validation reads exit code and the tagged output line, since the script writes no `DEXRecords` | hung-but-running service, restart-while-running (the UEM healthy run covers it), protected services |
| `Restart-WinProcessGraceful.ps1` (added later on 2026-11-02) | same folder | ProcessRunningRestart (fixed: target launched as the signed-in user through a one-shot Limited task so it carries the watchdog's token, `Restart=true`; validates the launcher output and `Dispatched` record, then waits for the watchdog's `result.json` to show `ClosedGracefully` and `Restarted=true`, the old PID gone and a newer same-description process), ProcessRunningNoRestart (fixed: `Restart=false`, nothing relaunched), ProcessNotRunning (reported only: exit 0, `No running process matches`, `NoMatch` record, no watchdog task). Target picked at run time from Notepad, Character Map, Chrome, cmd, skipping any whose description already has a live process so the user's own windows are never closed. One break per run | ForceKilled and UserActionRequired branches (need a process that ignores WM_CLOSE on demand) |
| `Invoke-VpnStateCollection.ps1` (added later on 2026-11-02; test 1.1.0 the same afternoon once WireGuard was on the VM) | `VPN\_AutomatedTesting\` | NoVpnClientReported (reported only: stops every `WireGuardTunnel$*` service so the adapter disappears, deletes the key, expects the documented no-client row by value and registry kind; Restore starts the tunnel again and waits for the adapter), TunnelConnectedReported (reported only: starts the tunnel, deletes the key, expects Connected 1, ClientCount 1, AdapterName `WireGuard Tunnel`, TunnelMode Split, TunnelMtu 1420, DnsConfigured 1, DiscardRatePpm 0, HealthScore 100 Healthy, derivation in the file header), StaleCacheFromPriorClient (fixed: planted healthy, unhealthy or CollectionError residue is overwritten), CacheValueKindsWrong (fixed: swapped String/DWord kinds, MULTI_SZ and EXPAND_SZ kinds are replaced). The expected row is derived from the live adapter state at validation time, so the planting breaks pass in either tunnel state; the two tunnel breaks cannot share a run. The lab tunnel is the VM-to-VM WireGuard pair from `New-WireGuardLabPair.ps1` in the same folder | TunnelDown (WireGuard's adapter is Up even with a dead peer and vanishes when the service stops; OpenVPN's TAP adapter is the lever), flaps and connect failures (dead code, 13.2.o), MultipleVpnClients (needs a second client) |
| `Invoke-AutoRemediateGenericVPN.ps1` (added later on 2026-11-02) | `VPN\_AutomatedTesting\` | TunnelMtuTooHigh (fixed: tunnel set to 1500, script brings it to its fixed 1400), TunnelMtuTooLow (fixed: 1200, below the 1280 floor), TunnelDnsMissing (reported only: the step only flushes and re-registers, it never invents a server, so the list must still be empty afterwards even though the script says "Remediation ran"), VpnSupportServiceDisabled (fixed: RasMan stopped and Disabled, script sets Manual and starts it), NoVpnClientReported (reported only: tunnel service stopped, "No VPN client present", no cache write). The tunnel adapter is resolved at run time with the script's own structural test; Restore puts the captured MTU and DNS back and restarts the tunnel service only if they differ | orphaned routes (step 5 keys off candidate adapters that are not Up; WireGuard's adapter is Up or gone, so OpenVPN's TAP adapter is the lever), multiple clients, step 6 (disabled by default), a disabled BFE (firewall depends on it) |
| `Invoke-AutoRemediateOutlook.ps1` (added later on 2026-11-02 against 1.0.2; test 1.1.0 for script 1.1.0 the same night) | `ApplicationSpecific\Microsoft\Outlook\_AutomatedTesting\` | ThirdPartyAddinConflictGated (reported only: planted `DEXTest.LabAddin` with `LoadBehavior 3` in the user hive stays 3), ThirdPartyAddinConflict (fixed with `AllowDestructiveActions=true`: `LoadBehavior` 0; refuses to run if a real add-in is registered, since the script disables the first one it finds), OstOverThresholdGated (reported only: `DEXTest_lab.ost` fixture sized above any real OST, threshold passed through `CacheSizeWarningMB`, Warning names the tier that would apply), OstOverThreshold (fixed, tier 1: `SyncWindowSetting` 12 written to the user's Cached Mode key, `OstTier1AppliedAt` stamped, fixture untouched), OstRenameTier2 (fixed: tier 1 planted 10 days back with `AllowOstRename=true`, fixture renamed `DEXTest_lab_<stamp>.bak`, real OSTs intact; refuses to run while `OUTLOOK.EXE` is open), OstRenameDeferredClose (fixed: needs classic Outlook open, `CloseOutlookForRepair=true` with a 15 s grace; expects the "Dispatched" step, then `state\result.json` with Outcome Renamed, the fixture gone, Outlook relaunched under a new PID and the task unregistered; closes and relaunches the user's Outlook once), C2RUpdatesDisabled (reported only: Warning, exit 0). Gated and ungated breaks cannot share a run; one OST break per run | the Exchange sync-backlog and profile-health steps (need an Exchange profile), the C2R `ErrorCode` branch (13.2.s), the tier-2 "Wait" branch, the `UserActionRequired` outcome when the user keeps Outlook open past the grace, and the result-file ingestion into DEXRecords (the harness deletes its own result file on Restore) |
| `Invoke-AutoRemediateTimeSync.ps1` (added 2026-11-03) | `WindowsAutoRemediation\SystemHealth\_AutomatedTesting\` | W32TimeService (fixed; StoppedDisabled or StoppedManualOrDisabled), WorkgroupNoPeer (reported only: `Type=NoSync`; skipped on a domain member) | clock offset and stale sync (would need a clock change on the lab VM), hypervisor conflict, large-offset phase-correction path |
| `Invoke-AutoRemediateCertEnrollment.ps1` (added 2026-11-03) | same folder | AutoenrollmentTask (fixed: a CertificateServicesClient task disabled), ExpiredCertificate and WeakAlgorithmCertificate (reported only: self-signed `CN=DEXTest ...` in `LocalMachine\My`, removed by thumbprint on restore) | AD CS template expiry (`certutil -pulse` path needs a domain CA), AuthRoot staleness, policy flags |

Where a target writes no per-step `DEXRecords` value, the report-only validation reads the script's summary counters and its captured stdout instead; the file header says which.

### 13.2 Defects found while writing the break tests

Items a to d would have made the break test's result meaningless or made UEM report the wrong status; they were fixed on 2026-11-02 (versions in each entry) and the affected break tests were adjusted. The rest are open.

a. **`Enable-HardwareAcceleratedGPUScheduling.ps1`, fixed 2026-11-02 in 1.0.2.** (Was:) After a successful repair of the registry value the script still exits 1, because the failure count ignores the remediated flag. UEM shows `Failed` on every machine it fixes. It also writes no `DEXRecords` key, unlike the rest of the family, and step 4 reports "requires reboot" forever once the value is 2.
b. **`Invoke-RemediatePageFile.ps1`, fixed 2026-11-02 in 1.0.1.** (Was:) The manual-but-under-threshold case is documented as advisory, but the script exits 1 for it, so UEM records a failure for a condition it chose not to fix. The "Resetting to system-managed" message is written before the fix is attempted.
c. **`Invoke-RemediateSysMain.ps1`, fixed 2026-11-02 in 1.0.1.** (Was:) Detection checks only `Running`; a running service with startup type Disabled is reported Passed and vanishes at the next boot, although the header promises to set Automatic.
d. **`Invoke-AutoRemediateOneDrive.ps1`, fixed 2026-11-02 in 1.0.2.** (Was:) A step 1 failure that was remediated still exits 1. Also: every `Accounts` subkey is treated as an account, so `FileCoAuth` warns "not signed in" on every machine; the sync-error step drops Operational-log events when exactly one comes back; step 5's two warning branches are identical.
e. **`Invoke-DefenderDynamicPerformance.ps1`.** Drift is never detected once the `CurrentProfile` marker matches, and the marker is written even when `Set-MpPreference` failed (no error action), which then suppresses future re-applies. The cached score is never refreshed after a hardware change. The registry path uses `AIRWATCH\Extensions\HealthDetection`, outside the `DEXRecords` convention. Fixed 2026-11-05 in 1.2.0: the live `Get-MpPreference` values are compared with the target profile every run and re-applied on drift even when `CurrentProfile` matches; the three `Set-MpPreference` calls run with `-ErrorAction Stop` inside a try and `CurrentProfile` is written only after all three took (a failure logs, mirrors `Result ApplyFailed` and exits 1 so the next run retries); the score is cached with a `HardwareFingerprint` (BIOS date, logical processors, system disk media and bus) and recomputed when it changes; score, profile, settings and last run are mirrored under `HKLM:\SOFTWARE\AirWatch\Extension\DEXRecords\Defender\DynamicPerformance` while the `HealthDetection` cache stays as the working state the break test reads. The break test's header still says silent drift is not repaired; a drift break can now be added. The first non-elevated dry run on this VM showed the fingerprint doing its job: the cached score of 4 dated from the two-core days, the fingerprint read `bios=2024-06-03|cpu=4|disk=SSD/NVMe`, and the score was recomputed to 6 (still `Mid`, live settings matched, exit 0); the non-elevated cache write fails, which 1.2.0 now reports instead of claiming "cached it". Rerun on 1.2.0 `f5e48cac81fc` 2026-11-05 11:29 (elevated) Passed: both breaks (PriorityDriftMarkerRemoved, NonNumericScore) verified and repaired, machine restored; row 24 keeps Full Pass on 1.2.0.
f. **`Restart-WindowsUpdateServices.ps1`.** `Stop-Service cryptsvc -Force` takes AppLocker's `AppIDSvc` and `applockerfltr` down and never restarts them. Cannot repair a Disabled service. Header and banner name the script `Invoke-WindowsUpdateServices.ps1`. The catch block is dead because the service calls use `-ErrorAction Continue`. Fixed 2026-11-05 in 1.6.2.0: a Disabled service is set back to its Windows default start type (`wuauserv`/`bits`/`msiserver` Manual, `cryptsvc` Automatic) before the start, which is the right call here because a disabled update stack is the fault the script exists to repair; running dependents are recorded before `Stop-Service -Force` and started again afterwards (on this VM `cryptsvc` carries `AppIDSvc`, `applockerfltr` and `IsolationSession`, all stopped at the time); the service calls use `-ErrorAction Stop` so the catch runs, with the inner exception appended; the header, banner and `$HEAD` are corrected. The four-break test's strings and exit codes are unchanged; rerun `25ed65fb8da0` on 1.6.2.0 Passed (2026-11-05 10:55).
g. **`Invoke-AutoRemediateChrome.ps1`.** Step 3 checks the legacy `gupdate`/`gupdatem` service names (current Chrome ships `GoogleUpdaterService<ver>`), so it warns on every machine. Step 4 reads `UpdateDefault` under `Policies\Google\Chrome`; the policy lives under `Policies\Google\Update`, so the branch never fires. Under SYSTEM, `HKCU:` is SYSTEM's hive, so per-user orphaned hosts are never pruned. A cache-clear that throws because Chrome is running leaves status Warning and exit 0. Fixed 2026-11-05 in 1.0.2: step 3 looks up both updater generations by name (legacy `gupdate`/`gupdatem`, current `GoogleUpdaterService*`/`GoogleUpdaterInternalService*` through a `Win32_Service` LIKE query, never a full enumeration) and flags only a Disabled service or no service at all, since both generations run on a schedule and sit Stopped in between; step 4 reads `UpdateDefault` and the Chrome app-GUID override from `Policies\Google\Update` (and its WOW6432Node twin) and reports both the disabled and the manual-only values; step 6 resolves the logged-on user's SID and searches `HKEY_USERS\<SID>` as well as `HKCU:` (de-duplicated when they are the same hive) and the two machine hives, in detection and resolution alike; step 1 writes an explicit "Cache clear deferred: Chrome is running" line and returns instead of throwing, and counts files it could not delete. The four-break test does not patch the script and matches on step results, not message text; rerun `03ba04fe011b` on 1.0.2 Passed (2026-11-05 10:55).
h. **`Invoke-AutoRemediateAppXBloat.ps1`.** The built-in deny list cannot be disabled or replaced, only extended with `DenyListExtra`. See 13.3.
i. **`Invoke-AutoRemediateLogonTaskContention.ps1`.** The ISO 8601 duration parser only understands `PT..H..M..S`, so a delay written as `P1D` parses to 0 and is reduced to the minimum, contradicting "only ever increases". Disabled triggers on enabled tasks are rewritten. `Set-ScheduledTask` fails for principals with a stored password and forces exit 1 every run. Fixed 2026-11-05 in 1.0.3: the parser reads the full ISO 8601 form (`P1D`, `P1DT2H`, fractional seconds rounded up) and returns `$null` for anything else, which the discovery and the resolution both treat as "leave this trigger exactly as it is" and log; only enabled logon triggers are counted or rewritten; tasks whose principal `LogonType` is `Password` are split out before the fix list and reported in the step message (Warning when they are the only ones) instead of failing `Set-ScheduledTask` on every run. The two-break test validates against the summary counters and the fixtures' delays, not message text. Rerun on 1.0.3 `f3dba3f5c473` 2026-11-05 11:29 (elevated) Passed: the no-delay fixture got its delay, the twelve-task volume was reported and left alone, counters matched; row 21 keeps Full Pass on 1.0.3.
j. **`Invoke-AutoRemediateProfileBloat.ps1`.** Step 8 measures all of `AppData\Roaming` for every profile on every run with no age filter, the likeliest cause of a 300 s timeout. `Resolve-Path` on profile paths treats `[` and `]` as wildcards. Fixed 2026-11-05 in 1.0.3: step 8 sizes the roaming tree with an iterative .NET walk (`EnumerateFiles`/`EnumerateDirectories`, reparse points not followed) that stops as soon as the warn threshold is reached, since the answer is already "over", or when a 90 s step budget shared across the profiles runs out; a tree too large to size inside the budget is itself reported as a Warning ("too large to size in time"), because that is a logon problem in its own right. The Warning line keeps the `Oversized Roaming AppData:` prefix the break test matches. `Get-ProfilePaths` escapes the profile folder with `[WildcardPattern]::Escape` so only the relative part carries wildcards. Non-elevated WhatIf run on this VM: four profiles, step 8 took 0.9 s in total and stopped at 533.5 MB for `chase` ("at least 533.5 MB"), where 1.0.2 walked the whole tree. Steps 1 to 7 still walk their (bounded) cache folders twice; not changed. Rerun on 1.0.3 `e446f8bd2e99` 2026-11-05 13:25 (elevated) Passed: the draw was CrashDumps and UserTempFiles, both repaired, so the whole script including the new step 8 ran against the `DEXTestBloat` profile; the roaming-size break itself was not drawn and can be pinned with `-BreakName OversizedRoamingAppData`. Row 22 keeps Full Pass on 1.0.3.
k. **`Start-UserProfileCleanup.ps1`.** `ConvertToDateTime` on a null `LastUseTime` throws outside the try block and ends the whole run; this lab VM has two such profiles (`kioskUser0`). The log directory is created but never written. On a domain-joined host local accounts are never candidates and `Win32_UserAccount` enumerates the whole domain. Always exits 0. Fixed 2026-11-05 in 1.1.0 (6,030 chars): a null `LastUseTime` falls back to the `NTUSER.DAT` write time and a profile with neither is logged and skipped; every line goes to the console and to `C:\Temp\Logs\ProfileCleanup.log`; candidates are every non-special, unloaded profile whose SID is not the enrollment user's (resolved through `NTAccount`, local account first, with a logged warning when the name does not resolve), so no directory enumeration; exit 1 when a deletion failed. The break test's scratch-copy anchor moved to the new candidate filter. Rerun `a83bab70487a` on 1.1.0 Passed (2026-11-05 10:55), so the Full Pass now rests on 1.1.0.
l. **`Invoke-DriverUpdates.ps1`.** Does not read the driver-exclusion policy keys, so a policy-blocked search fails with a generic error. A pre-existing pending reboot is never reported in detect mode. Fixed 2026-11-05 in 1.0.1: before the search the script reads `Policies\...\WindowsUpdate\ExcludeWUDriversInQualityUpdate`, `Policies\...\DriverSearching\DontSearchWindowsUpdate` and `SearchOrderConfig` (policy and device setting) and, when any blocks drivers, says which and exits 0 without searching; the reboot signals (WU key, pending renames, and now CBS `RebootPending`) are gathered by one helper that runs before the search as well as after an install, so Detect mode prints a pre-existing pending reboot and its exit lines say so. Exit codes are unchanged. The break test (WuauservStopped) does not patch the script. Rerun on 1.0.1 `0ec8523cc211` 2026-11-05 11:30 (elevated) Passed: wuauserv restarted and the search completed through the new pre-check on an unblocked host; row 8 keeps Full Pass on 1.0.1. The policy-blocked and pending-reboot paths are not injectable by this harness and were read through the code only.
m. **All four WindowsLogon scripts, fixed 2026-11-02 in 1.0.2** (`Invoke-AutoRemediateAppXBloat.ps1`, `Invoke-AutoRemediateLogonTaskContention.ps1`, `Invoke-AutoRemediateProfileBloat.ps1` and the sibling `Invoke-AutoRemediateFSLogixExclusions.ps1`, which had the same mismatch). (Was:) Header says 1.0.1, `$SCRIPT_VERSION` logs 1.0.0. Findings go to summary counters under `AirWatch\Extensions\<Name>\Remediation`, not per-step `DEXRecords` values, so a runbook cannot tell which step warned. Now: header, `$SCRIPT_VERSION` and banner all read 1.0.2, and each script also writes `LastScanTime`, `ScriptVersion`, the counts and one `StepNN_<Name>` value per step under `HKLM:\Software\AirWatch\Extension\DEXRecords\WindowsLogon\<ShortName>` in its own try/catch. The summary counters are unchanged, so the three existing break tests still validate against them; a WhatIf run writes no DEXRecords, matching the scripts' existing rule that a dry run claims no state. The three break tests were not re-run against 1.0.2: on 2026-11-04 the user accepted the 1.0.1 passes as standing for 1.0.2 (the change adds the DEXRecords writes in their own try/catch and touches no detection or remediation logic), so rows 19, 21 and 22 keep Full Pass by that decision, as row 7 does for Wi-Fi.
n. **`Restart-WinService.ps1`.** A stopped service whose StartType is Disabled is reported "could not be started" and exits 1; the script never tries `Set-Service -StartupType`, so the one state a user cannot fix from the Services console is the one it leaves alone. `Stop-Service -Force` stops dependents (PrintNotify, Fax where present) and never restarts them. The reported reason is `$_.Exception.Message`, which for a disabled service is the generic "Cannot start service"; the cause sits in `InnerException`. The unanchored `*$ServiceName*` match on Name or DisplayName (already in the review notes) also means a dependent that matches the same pattern can be stopped by the first match's `-Force` before the loop reaches it, so its branch is chosen on stale state. Cosmetic: `$HEAD` begins with a line break, so every result line is preceded by a blank line. Fixed 2026-11-05 in 1.7.1.0, with one deliberate exception: a Disabled service is still left alone, because Disabled is an administrative decision this script should not override (the break test's `SpoolerDisabledAndStopped` expectation stands); it is now reported as "could not be started: its startup type is Disabled" instead of the generic wrapper text. Exact name or display-name match first, wildcard only as a fallback, and each service is re-read before it is handled; running dependents are recorded before `Stop-Service -Force` and started again afterwards (a trigger-started dependent that refuses is reported, not counted as a failure); error text appends the inner exceptions; the blank line is gone. The dry run also exposed a PowerShell 7 fault in 1.7.0.0's lookup: a plain `Get-Service` enumeration aborts on a protected service (`McmSvc`, "Cannot open ... service") even with `-ErrorAction SilentlyContinue`, returns nothing, and the script reported "no service matched 'Spooler'" under pwsh on this VM; as SYSTEM under Hub the ACL did not bite, which is why the UEM pass held. 1.7.1.0 never enumerates: exact `-Name`, then exact `-DisplayName`, then a WQL `LIKE` lookup through `Win32_Service` for the wildcard fallback. Dry runs on 5.1 and 7 with `Spooler`, `Print Spooler`, `rint Spoo` and an unknown name all give the documented lines and exit codes (7,877 chars). The three-break test still matches its strings; rerun `f8724f5670f6` on 1.7.1.0 Passed (2026-11-05 10:55).
o. **`Invoke-VpnStateCollection.ps1`.** Two findings that cap what the collector can ever report. (1) Flap matching cannot match: `Test-EventMatchesTunnel` compares NetworkProfile 10000/10001 event properties with the adapter `InterfaceDescription`, but those properties carry the profile name, description and GUID, never the adapter description (confirmed against the real WireGuard adapter: the event says `CBRADLEYSWIN11`, the adapter Name, while the collector looks for `WireGuard Tunnel`; matching on `Name` as well would fix it), so `FlapCount24h` is always 0, `FrequentReconnects` and `IntermittentReconnects` are unreachable, and `LastConnectTime` and `SessionDurationMinutes` never populate. (2) The built-in Windows VPN client is invisible: `Get-NetAdapter` without `-IncludeHidden` never returns the WAN Miniport adapters and RAS connections are not NetAdapters, so a device using only the Windows client reports `NoVpnClient`, and because the event sections run only when `ClientCount > 0`, the RasClient 20227 failures the script reads are counted only when some other visible tunnel adapter exists. (3) No liveness signal: Up plus a routable IPv4 is all "Connected" requires, so the lab WireGuard tunnel with a silent peer, no handshake and no received traffic scores 100 Healthy, and `DnsConfigured` means a server address is set on the adapter, not that it resolves; handshake age, received bytes or reachability of the tunnel DNS server would make the score mean something. Smaller: `FlapCount24h`/`ConnectFailureCount24h` are -1 when no client, 0 when no events, but -1 if the NetworkProfile query throws while the RasClient catch sets 0; the catch path writes only `HealthReason=CollectionError` and `LastRun`, so on a first-run failure the other 12 values do not exist; `LastRun` is written but not in the header's value table; the trailing `Exit 0` is unreachable. For the lab, a WireGuard tunnel comes Up with its configured IP, MTU 1420 and DNS even against an unreachable peer, so Connected, MTU, DNS and Full-versus-Split become testable without a server; OpenVPN's TAP adapter shows the TunnelDown (score 60) shape instead.
p. **`Restart-WinProcessGraceful.ps1`.** (1) The watchdog's per-tick catch classifies any exception as `ClosedGracefully` ("process handle invalidated"), including a `Stop-Process -Force` denied because the target is elevated and the watchdog is Limited, so `result.json` can claim a graceful close for a process that is still running; it should check `HasExited` first. (2) The self-cleanup logs "unregistered" unconditionally after a silenced `Unregister-ScheduledTask`; a Limited watchdog cannot delete the task the elevated launcher registered, and `WS1_ProcessGracefulWatchdog` is still present on the lab VM from 2026-10-30 while its log says it was removed. (3) The watchdog's HKLM `DEXRecords` mirror always fails under the Limited token, so `Status` stays `Dispatched` forever after a completed close; only `result.json` is authoritative, and the break test accepts either value for that reason. (4) Elevated processes are matched by the elevated launcher but invisible to the Limited watchdog, which then writes `NoMatch`; a documented limitation is needed. (5) The relaunch path is whichever matching process enumerates first, which for a packaged app is the WindowsApps path and for a helper binary sharing the description would be the wrong exe. (6) `[Convert]::ToBoolean($env:Restart)` throws on `1` or `yes`; the `-like "*$FileDescription*"` match does not escape wildcards; the trailing `Exit 0` is unreachable. The 2026-10-30 `result.json` on the lab VM shows ten Chrome processes closed gracefully and relaunched in about 10 s, so the Detached path itself works. Fixed 2026-11-05 in 2.2.0: (1) the per-tick catch asks `Get-Process -Id` whether the PID is gone before calling it `ClosedGracefully`; a refused `Stop-Process` on a still-running target is `Error` with the message and a note that an elevated target cannot be stopped by the Limited watchdog, and the retry-wait catch does the same check. (2) The task is registered with a one-shot trigger 5 s out (`-StartWhenAvailable` covers a slow registration) carrying an `EndBoundary` of budget + 60 s and `-DeleteExpiredTaskAfter PT1M`, so Task Scheduler deletes it a minute after the budget whether or not the watchdog could; the watchdog re-checks after its own `Unregister-ScheduledTask` and logs "unregistered" or "could not be unregistered from this token; Task Scheduler deletes it after its end boundary (<time>)". `Start-ScheduledTask` is no longer called (the trigger starts it), which also removes the double start a trigger plus an explicit start would have caused. The GENERAL runbook's note that `DeleteExpiredTaskAfter` is rejected without a trigger stays true; this is the variant with a trigger, proven on this VM with a probe task that fired 5 s after registration and carried `EndBoundary` and `DeleteExpiredTaskAfter PT1M` on read-back. (3) The launcher, which runs as SYSTEM, reads the previous `result.json` at the start of every run and, when its `CompletedAt` is not the one already mirrored, writes `LastResultStatus`, `LastResultCompletedAt`, `LastResultMatchedCount`, `LastResultClosedGracefullyCount`, `LastResultForceKilledCount`, `LastResultUserActionRequiredCount`, `LastResultUnsavedWorkSuspectedCount`, `LastResultInaccessibleCount`, `LastResultErrorCount`, `LastResultRestarted` and `LastResultTargetDescription` to the DEXRecords key; `Status` itself still reads `Dispatched` for the run in flight, and the watchdog's own mirror still succeeds in SYSTEM context. (4) After re-discovery the watchdog compares `state.MatchedPids` with what it can see; a dispatched PID that is still alive but did not match is recorded with outcome `Inaccessible` ("still running but not visible to this watchdog (elevated process, Limited token)"), counted in `InaccessibleCount`, blocks the restart and is logged, instead of the run reporting `NoMatch`. (5) The relaunch path is taken from the first windowed match, falling back to the first match with a path, so a helper binary or a packaged app's WindowsApps alias is not what comes back. (6) `ConvertTo-Bool` accepts 1/0/true/false/yes/no/on/off for `Restart`, `ForceOnlyIfUnresponsive` and `SkipIfUnsavedWork` and falls back to the default on anything else; the description match uses `[WildcardPattern]::Escape` in both launcher and watchdog; the trailing `Exit 0` after the function call is removed. Header and parameter text moved towards the README to keep the file at 31,131 characters (was 32,610 of the 32,767 limit). Not changed: `PID<n>_Result` values still accumulate in the key, and the companion sensor `process_graceful_lastresult.ps1` the README named does not exist in the repo (the README now says so; the `LastResult*` values are what a sensor would read). A non-elevated Inline run on this VM stopped at staging (the `ProgramData` folder is SYSTEM/Admins only), so the live proof had to come from the break test. Rerun on 2.2.0 `40a560a2b4d3` 2026-11-05 13:25 (elevated) Passed, but the seeded draw was ProcessNotRunning (Notepad, no match): it proves the launcher's NoMatch path on 2.2.0 (exit 0 in 1 s, DEXRecords `Status=NoMatch`, nothing dispatched) and not the watchdog. The pinned rerun `1ac93c400483` 2026-11-05 13:35 (elevated, `-BreakName ProcessRunningRestart`) Passed: Notepad launched as the user through the harness's Limited task, the launcher dispatched in 5.3 s (`Status=Dispatched`, `MatchedCount=1`), the Task Scheduler operational log shows the task registered at 13:35:26.6 and launched at 13:35:31.7 "due to a time trigger condition" (the new trigger, no `Start-ScheduledTask`), the watchdog closed PID 5432 gracefully, relaunched Notepad from its WindowsApps path (the only match, so the windowed-first rule had one candidate) and wrote `result.json` with `Status=Completed`, `ClosedGracefullyCount=1`, `InaccessibleCount=0`, `ErrorCount=0`, `Restarted=True`; the new log line "HKLM mirror skipped (not permitted for this token); result.json is authoritative" appeared as designed. The self-cleanup line was not observed: the harness's Restore stopped the task instance at 13:35:48.5 (event 330, return code 0x800704EB) and deleted the task at 13:35:50.5 (event 141) while the watchdog was still in its cleanup, 3.7 s after the mirror line, so the "unregistered" / "could not be unregistered" branch and `Watchdog end.` were cut off by the harness, not by the script. The harness now waits up to 20 s after `result.json` for this run's `Watchdog end.` line and prints the cleanup line before Restore. `LastResult*` was empty after the run because the fixture deletes the stale `result.json` before dispatch, so the launcher had nothing to mirror; the mirror is proven by any later launcher run (it reads the `result.json` this run left behind). What 2.2.0 still has unobserved: the task-expiry deletion by Task Scheduler itself (needs a watchdog that cannot unregister, which the harness run ends before), and the `Error`/`Inaccessible` branches (need an elevated target, which the harness deliberately does not create). Row 16 is Tested on the same basis as rows 14, 18 and 35: all three breaks passed on 2.1.0, the running-process break passed on 2.2.0, and the UEM pass stands.
q. **`Invoke-VpnStateCollection.ps1`, FIX FIRST, fixed 2026-11-02 in 1.0.1.** (Was:) Step 5 called `Get-NetAdapterStatistics -InterfaceIndex $tunnel.ifIndex`. The cmdlet has only `-Name` and `-InterfaceDescription`, and a parameter-binding error is terminating whatever `-ErrorAction` says, so on every device with an active tunnel the collector fell into its catch, wrote `HealthReason=CollectionError` and exited 1. The UEM `PASS - UEM` on 1.0.0 proved only the no-client path, which is the one path the script was never meant for. Found the first time the lab had a real tunnel (WireGuard, 2026-11-02 14:44); 1.0.1 uses `-Name $tunnel.Name` and on the same VM reports `Health score: 100 (Healthy)`.
r. **`Invoke-AutoRemediateGenericVPN.ps1`.** "Remediation ran" and the cached `RemediationsRun` count mean the resolution script returned without throwing, not that the fault was fixed: step 4 (flush and re-register, never adds a server) and a Disabled BFE in step 2 both report a remediation while changing nothing, so the summary over-reports fixes. Step 2 marks a stopped `RasMan` or `IKEEXT` as Failed, but `RasMan` is Manual and legitimately idle-stopped on any device without a RAS connection, so healthy devices get a Failed step, a service start and an inflated Failed count on every run. Step 3 always writes 1400, so a WireGuard tunnel at its optimum 1420 ends lower than its client set it. `ipconfig /registerdns` in step 4 is machine-wide, not tunnel-scoped. `Get-ActiveTunnelAdapter` returns the first Up candidate, so with two clients MTU and DNS are checked on one tunnel only. The no-client guard writes no cache at all, so `LastRun` cannot distinguish "never ran" from "no client", and the trailing `Exit 0` is unreachable.
s. **`Invoke-AutoRemediateOutlook.ps1`, two items fixed 2026-11-02 in 1.0.2.** (Was:) Step 4 returned Failed with "Will trigger an update attempt" when `UpdatesEnabled` is False, with no resolution script, so every device whose Office updates are managed by policy exited 1 on every run (this lab VM included). Now Warning, "updates are managed by policy or MDM outside this script". With exactly one add-in, OST, event or profile the counts printed blank (single pipeline object, no `.Count` in PS 5.1); the collections are now wrapped in `@()`. Still open: the step 4 `ErrorCode` branch has the same false promise ("Will trigger a retry") and exit 1; step 1's gated Warning carries no "set $AllowDestructiveActions" hint, unlike step 2 (section 6.3 step 2 above expects one and is wrong); step 1 never reads the `WOW6432Node` add-in key; the step 1 resolution disables the first third-party add-in found, not the ones it reported; `$_c2rClient` and `$color` are assigned and never used. Run time (seen 2026-11-03): the script normally finishes in 3 to 17 s, but two lab runs took 149 s (`32ab16c12640`, 1.0.2, 2026-11-02 19:58) and 102 s (the second run inside `2d605de6719e`), against a header timeout of 60 s and a published UEM timeout of 30 s, so under Hub both would have been `ScriptTimedOut`. The header timestamp each run prints puts most of that time before the script's first line of output: 136 s of the 149 (header at 20:00:30 on a run launched about 19:58:14, steps done 13 s later), and at least 37 s of the 102 (header 08:54:26, run complete by 08:55:31). Both were host-load events at PowerShell start: Office and Teams had been installed minutes before the first, and Outlook was relaunching under the OST helper during the second. The step 3 event query was not the stall, but it was the one cost that scales with the Application log, so 1.1.1 (2026-11-03) moves the `ProviderName` and `Level` filter into the `FilterHashtable`: on this VM 0.1 to 0.4 s against 2 to 10 s for the pipeline filter, same two events found. Script is 32,652 characters. The timeout risk from host load is not something the script can fix; the product-path UEM run measures it.

t. **`Invoke-VpnStateCollection.ps1` and the ten gated `vpn_*` sensors, found 2026-11-03 under Hub, fixed in 1.1.1.** (Was:) The sensor gate's quiet rerun starts `powershell.exe` on the persisted collector copy from inside Hub's sensor host (`AW.ProtectionAgent.PowershellExecutor64`). In that child, `Get-FileHash` was "not recognized as the name of a cmdlet" while `Get-NetAdapter`, `Get-Date`, `Select-Object` and the registry cmdlets all resolved, so `Save-CollectorCopy` took its WARN path and wrote `CollectorHash` empty. The row it then wrote was correct, but every later sensor sample would have hit the hash branch with an empty hash and flagged `Stale` until a scheduled collector run repaired it. The same cmdlet resolved fine when the sensor ran from an elevated console (gate test scenario C), so this is a property of the Hub-spawned child's environment that the lab could not show. Both the collector and the sensors now hash with `[Security.Cryptography.SHA256]` over `[IO.File]::ReadAllBytes`, which needs no module, and the collector logs the host's PowerShell version, bitness and `PSModulePath` on every run so the next Hub pass explains the difference. Closed 2026-11-03 11:56: UEM part four (`4514e3`) showed the quiet rerun from the Hub-spawned child leaving `CollectorHash` intact (10.2). The 1.1.1 collector's first Hub run (`ee64c2`, 09:52:58) explained it: the new Host line logged **PowerShell 7.2.24, x64**, `PSModulePath` starting with `C:\Program Files\Airwatch\AgentUI` and the SYSTEM profile's `Documents\PowerShell\Modules`, then `C:\Program Files\PowerShell\Modules`, then `System32\WindowsPowerShell\v1.0\Modules`. **Hub's script and sensor host is PowerShell 7, not Windows PowerShell 5.1**, and the sensor's child `powershell.exe` 5.1 inherited that 7-shaped `PSModulePath`, which is where `Get-FileHash` went missing. Every script in this repo is in fact running under 7.2 when Hub runs it, whatever its notes say about 5.1; the CDXML and CIM modules (`NetAdapter`, `ScheduledTasks`) load natively in 7, but anything 7 cannot load goes through the Windows PowerShell compatibility layer, which starts a 5.1 process per module, and 7-only semantics (`-split` with a negative count, `Get-FileHash` as a cmdlet, UTF-8 default encoding) apply. The lab harness runs the scripts under 5.1, so the lab and Hub do not share an engine; a `pwsh` lab pass is worth adding for anything timing-sensitive. Related observation, not a defect: Hub logs `[ERR] "Sensor Data Name: {0} returns {1} is invalid because expected type is {2}"` for `vpn_dns_configured` whenever it emits nothing on a no-client device; a Boolean sensor has no way to say "not applicable", and emitting nothing was the documented choice, so the error line is the cost of that choice.

u. **`Invoke-VpnStateCollection.ps1` and the ten gated `vpn_*` sensors, found 2026-11-03 under Hub (run `90b8b9`), fixed in 1.1.2.** (Was:) Hub does not run sensors one after another. Its process log shows a sensor sweep spread over several threads (thread ids 16, 35, 55, 76, 80, 90, 96 in one 10:18 sweep), so two sensors can read the cache in the same instant, both see the fingerprint changed, and both launch the collector before either has stamped `LastChecked`; the "claim first" stamp in the 1.1.0 gate never had a chance. At 10:13:28 two quiet reruns (run ids 2835 and 3807) started in the same second. 3807 lost the race for the shared log file, `Out-File` threw inside `Save-CollectorCopy` and again inside the main `try`, so 3807 wrote `CollectorHash` empty over 2835's good hash, then `HealthReason CollectionError`, exit 1. Sensors reading in that window reported `100`, `CollectionError;Stale` and `Connected False` for a tunnel that was up; 2835 then wrote the full connected row at 10:13:46 but the hash stayed empty, which would have made the next state change unrefreshable. The lab gate test runs the sensors one at a time and cannot show this. 1.1.2: the sensor gate holds a named mutex (`Global\DEX-VpnSensorGate`, wait up to 45 s) while it decides and refreshes, and re-reads the cache after acquiring it so a sensor queued behind a refresh takes the fast path; the collector holds `Global\DEX-VpnCollector` for its whole run (a second run waits up to 30 s, then exits 0 without writing); `Write-Log` retries three times and never throws. Worst-case sensor time rises to about 85 s against Hub's 120 s sensor timeout. A standard user could create either mutex first and hold it, which only degrades the sensors to `Stale`. Closed 2026-11-03 11:56: UEM part four (`4514e3`, both tunnels deactivated, ten sensors, no collector run) produced exactly one quiet rerun on this VM, a clean no-client row from every value-emitting sensor on both devices, and the hash unchanged (10.2).

v. **`logon_duration_measure.ps1` fails under Hub, found in the 2026-10-29 sensor sweep (`e505e2`) and read properly on 2026-11-03.** Both devices returned `{"Status":"Failed","Error":"Cannot marshal 'parameter #8': Non-blittable generic types cannot be marshaled."}`, and the inventory still said Tested. The same file runs clean on this VM under Windows PowerShell 5.1 and under pwsh 7.5.2 (real values: ProfileLoadMs 300, ActiveSetupMs 19210, 28 logon tasks), so the failure belongs to Hub's embedded PowerShell 7.2.24 (13.2.t), most likely one of the `Get-WinEvent` forms the sensor uses (`-FilterXPath` with `-MaxEvents`, or `-FilterHashtable` with `EndTime`); the VPN collector's `-FilterHashtable` with `ProviderName`, `Id` and `StartTime` ran fine under the same host at 10:28. Every `logon_*` scalar sensor reads this collector's cache, which is why they all returned -1/-2/-3 sentinels: not their fault, and not a pass either. Demoted to Needs Testing. The Outlook product-path run hit the identical error the same afternoon (z), which narrows it to the engine; the fix path and the probe are in z. Fixed 2026-11-05 in 1.1.0 (every query through the .NET `EventLogReader`; see z for the probe result that made it mandatory); the UEM proof is the sensor run recorded in 8.3.

w. **Two inventory rows typed Sensor are not sensors.** `Get-StartupApps.ps1` (UnmanagedAppReport) ends in `Format-Table -AutoSize`, so under Hub it reported the literal `Microsoft.PowerShell.Commands.Internal.Format.FormatStartData`; `Get-UserProfileSize.ps1` (DiskCleanup) is a multi-line `echo` report with a log file, so Hub dropped it (`NoResult`). Neither can pass as a sensor. Either retype the rows as Script (and give them an exit code) or give each a one-line JSON sensor twin. Left at Needs Testing.

x. **`sensor-getservice.ps1` can never report.** It emits the JSON of every running service, far over Hub's 1 KB sensor cap, so it was `NoResult` on both devices in `e505e2` while the inventory said Tested. Demoted. `logon_folder_redirection_map.ps1`, `logon_folder_redirection_latency_probe.ps1` and `performance_defender_scanorupdateactive.ps1` were also `NoResult` on both devices in that sweep and also said Tested; demoted until a fresh sweep explains them (the two folder-redirection sensors emit JSON that may exceed 1 KB). The fresh sweep (`460b25`, 2026-11-03 14:35) answered for the Defender one before the connector crashed: `performance_defender_scanorupdateactive` returned `Idle` from both devices, so its October `NoResult` was Hub timing and it is back at Tested. The folder-redirection pair sat in the batch the crash orphaned. Resolved by the full sweep on the hardened connector (`25a553`, 2026-11-05 08:59 to 09:26, 67 sensors on both devices, 67 Passed, 0 NoResult, no transport retries needed): `logon_folder_redirection_map` stored its 282-byte JSON (`RedirectedCount 0`, thirteen local folders) and `logon_folder_redirection_latency_probe` its `OverallSeverity NotApplicable` JSON on both devices, so their October `NoResult` was Hub timing too, and both return to Tested. `logon_duration_measure` is the one value in the sweep that carries `Status Failed` (the ARM64 `Get-WinEvent` marshal error, z); it stays demoted. The five skips are the inventory rows with no file (`Measure-GPLoadTime`, `Measure-GPLoadTimeEx`, `Measure-LogonDurationEx`) and the two non-sensors (w, and `sensor-getservice`).

y. **`scom_agent_health_reason.ps1` and `scom_agent_version.ps1` (cache readers) emit an empty string when no agent is installed**, which Hub rejects ("value is empty"), while their `_standalone` twins emit `NoAgentInstalled` and `-1`. The cache readers should emit the same sentinels when the cache is absent. Low priority while SCOM is deferred. Corrected and fixed 2026-11-05: the `-1` belongs to the score sensor; the version standalone twin also emits an empty string by design, since a String version has no honest sentinel, and the manifest keeps `allowEmpty` for both version sensors. `scom_agent_health_reason.ps1` now reports `NoAgentInstalled` when no agent is present (registry root or `HealthService` service), `CacheNotPopulated` when an agent exists but the scheduled sweep has not written the cache, and `CacheReadError` from its catch block; both engines return `NoAgentInstalled` on this VM, 3,616 chars, and the manifest expects a word instead of allowing empty. UEM rerun pending (next sensor sweep).

z. **`Get-WinEvent` throws under Hub's PowerShell 7.2.24, FIX FIRST, found 2026-11-03 13:37 in the Outlook product-path UEM run (`64af6b`).** Step 3 of `Invoke-AutoRemediateOutlook.ps1` 1.1.1 (`Get-WinEvent -FilterHashtable @{ LogName; ProviderName = '*Outlook*'; Level = 1, 2, 3; StartTime }`) ended "Unable to query Application event log: Cannot marshal 'parameter #8': Non-blittable generic types cannot be marshaled." on the device, the same error that failed `logon_duration_measure.ps1` on both devices in October (v). Both scripts run clean on this VM under Windows PowerShell 5.1 and pwsh 7.5.2, and a ten-form probe (`AutomatedTesting\Probe-HubGetWinEvent.ps1`) passes every form on both of those engines, so the fault is in the 7.2.24 engine Hub embeds, and the lab cannot reproduce it: this VM has no 7.2 runtime, and the agent could not fetch one (download of external code was refused by policy; the user can drop the portable `PowerShell-7.2.24-win-x64.zip` into the scratchpad or give the probe an inventory row so UEM runs it). Not every form fails: the VPN collector's `-FilterHashtable` with `ProviderName` (exact), `Id` and `StartTime` ran fine under the same host the same morning, so the wildcard `ProviderName` and the `Level` array, which make the cmdlet enumerate provider metadata, are the suspects. Until the probe has run on 7.2.24, the safe rewrite for both scripts is the .NET `System.Diagnostics.Eventing.Reader.EventLogReader` with an XPath query (form J in the probe, no provider enumeration), falling back to the cmdlet. The step is a Warning, not a Failed, so the Outlook exit code and Full Pass stand; the production value of step 3 is nil until this is fixed. **Narrowed 2026-11-04:** the user supplied `PowerShell-7.2.24-win-x64.zip`, and the probe passed every form under it (`engine=7.2.24 A=OK50 ... J=OK2`, I needing elevation as before), so the version alone is not the trigger. The lab VMs are Windows 11 ARM64 (Apple silicon under Fusion): Hub's `AW.ProtectionAgent.PowershellExecutor64.exe` and the `System.Management.Automation.dll` 7.2.24 beside it under `C:\Program Files\Airwatch\AgentUI` are ARM64 images, while the probe engine is x64 (emulated) and the installed pwsh 7.5.2, which also passes, is ARM64. The fault is therefore specific to PowerShell 7.2's event-log provider on ARM64, a marshalling bug that later releases do not have, and an x64 production fleet running the same Hub would not see it. The `-win-arm64` 7.2.24 zip would make the reproduction exact. Downgraded from FIX FIRST to a hardening item: the .NET `EventLogReader` rewrite of Outlook step 3 and `logon_duration_measure.ps1` (v) is still worth doing because it removes the dependency, but nothing in production is known to be affected. **Settled 2026-11-05 by running the probe under Hub itself** (sensor run `07e3c1`, both lab VMs; the connector excludes `AutomatedTesting`, so a temporary inventory row pointed at a copy in a Sensors folder, both removed after the run): every `Get-WinEvent` form fails there, A to I, including the exact-provider form E that the VPN collector was believed to use successfully (`engine=7.2.24 A=ERR[Cannot marshal 'parameter #8'...] ... I=ERR[...] J=OK2` on `CBRADLEYSWIN11`, the same on `CHASEWIN11_2` with `J=OK0`, no Outlook there), and only the .NET `EventLogReader` form J works. Rule from this: no script or sensor calls `Get-WinEvent` at all. Rewritten the same day with a pasted helper (`Get-DexEvent`, `Get-DexEventLog`: explicit log name, XPath built from Id, Provider, UserID and whole-second time bounds, newest first like the cmdlet): `logon_duration_measure.ps1` 1.1.0, `Measure-LogonDuration.ps1` 1.1.3, `Measure-LogonDurationMultiSession.ps1` 2.1.1 (plus a provider check by name only and a System/Application fallback), and Outlook step 3 inline in 1.1.2. Scratch comparisons on this VM: the collector's registry record and the multi-session session record are identical old to new (18 and 41 values), and runs drop from 18 to 19 s to 5 to 6 s under both 5.1 and 7.5 because the cmdlet's provider-metadata enumeration is gone. Two things the rewrite had to match: the cmdlet's StartTime/EndTime are whole-second bounds, and a logon's profile and Winlogon events land a few hundred ms before the TS-LSM EID 21 that anchors the window, so an exact bound dropped ProfileLoadMs until the helper floored it; and the old `-ErrorAction Stop` forms threw on "no events found", which left the printer phase at N/A where 0 is right. Log map confirmed on Windows 11 26200: TS-LSM 21/25 in their own Operational log, Winlogon 7001 in System, AppReadiness 209 in the Admin log (not Operational), User Profile Service 1/2 in `Microsoft-Windows-User Profile Service/Operational`. Proven under Hub the same morning: collector 1.1.3 `Completed` on both devices (`d17a02`), all 21 `logon_*` sensors passed with real values from its cache (`e5d833`, 8.3), and Outlook 1.1.2 `Completed` on both with step 3 reporting a real two-event Warning (`4ea50e`, 6.3). **Second wave, 2026-11-05 afternoon:** the same helper pasted into the 21 remaining scripts that read events, 35 call sites, so no `Get-WinEvent` is left outside `Archived\`: the six Office remediations (1.0.1, crash and hang history), OneDrive 1.0.3 (sync errors), SCOM Agent 1.0.1, Part 2 1.1.1 (its runtime version string had stayed at 1.0.0 while the header said 1.1.0), ClonedIdentity 1.0.3, HealthServiceCache 1.0.3 and the `scom_agent_health` sensor (Operations Manager and ESENT), `Start-DefenderFullScan` 1.0.3.3 and `performance_defender_scanorupdateactive` 1.0.2 (full-scan start and finish, now filtered on EID 1000/1001 server-side), `Enable-LogonAuditLogs` (`-ListLog` to `EventLogConfiguration`), `Get-AppVolumesMountProbe` 1.0.1 (logon anchors, disk-arrival channels with per-source provider lists, `svservice`), the four Horizon agent scripts 1.0.1 (session inventory, agent errors) and the VPN collector 1.1.3 (NetworkProfile flaps, RasClient failures; closes the "0 under Hub" half of o). Two additions to the helper for this wave: every record gets a `Message` property (`FormatDescription()`, or the raw property values joined when the provider ships no metadata, which is what `svservice` events need and what the cmdlet's own fallback text carried), so every `.Message -match` filter in those scripts reads unchanged; and `-ErrorStop` rethrows the reader's exception for callers that treat an unreadable log differently from an empty one (the SCOM Operations Manager reads mark the log unavailable; a device without the agent now reports `OpsLogAvailable` false instead of true). Verified on this VM with an 18-shape test against live logs under Windows PowerShell 5.1 and pwsh 7.5.2 (both ARM64), identical counts and fields on both engines, including `ToXml()`, `Properties`, `Group-Object Id`, `Sort-Object TimeCreated` and `Message` after the reader is disposed; every patched script then parsed clean and ran under 5.1 (sensors returned their JSON, remediations took their no-agent or WhatIf paths, the App Volumes probe found 8 `svservice` events with readable text, the VPN collector ran its event phases; the two SCOM launchers and the Horizon collector fail non-elevated on an HKLM write exactly as their pre-patch copies do). One bug caught by that test before it shipped: `$po.Properties.Add` on the wrapped record resolved to the event's own `Properties` list, not the PSObject member collection, so the first draft returned nothing from every query; `$po.PSObject.Properties.Add` is the shipped form. UEM run `73d34e` (2026-11-05 11:53 to 12:03, Test_Treddy, result file `test-result-one-wave2-73d34e.json`): all twelve inventory items in the set passed on both devices in two batches. `performance_defender_scanorupdateactive` 1.0.2 returned `Idle` on both (the Defender log query now runs under Hub instead of falling back to `Get-MpComputerStatus`); `scom_agent_health` returned its full JSON with `OpsLogAvailable` false and `HealthReason NoAgentInstalled`; the VPN collector 1.1.3, Enable-LogonAuditLogs, `Get-AppVolumesMountProbe` 1.0.1, OneDrive 1.0.3 and the six Office remediations 1.0.1 all `Completed`, and the 35.8 KB Excel script published without complaint, so the "32,767" limit is not reached by a 3.5 KB helper. Device-side on `CBRADLEYSWIN11`: Word DEXRecords at 11:54:55 (`ScriptVersion` 1.0.1, 9 steps, 8 Passed, 1 Warning, the crash step Passed on a real seven-day query), Excel 7 of 7 Passed, OneDrive 5 steps with the sync-error step Passed and two sign-in Warnings, the App Volumes probe report `C:\Windows\Temp\AppVolumes_MountProbe_HOST01_20261105-115445.txt` listing 12 `svservice` events (EID 217 and 240, six each) with logon anchors resolved, which the pre-patch probe could not produce under Hub at all. Two limits on what this run proves: the VPN collector reported `NoVpnClient` (WireGuard is gone from the VM), so its NetworkProfile and RasClient phases were skipped; and under Hub as SYSTEM the `svservice` records formatted to a "Details:" stub rather than the raw text seen under 5.1 interactively, so the probe lists IDs and counts but the per-ID sample line is less useful there. Inventory statuses are unchanged by this run: the Office six and the probe have no break test, and the SCOM sensor proved only the no-agent branch.

aa. **`Invoke-AutoRemediateTeams.ps1` 1.0.1 never saw New Teams under Hub, fixed 2026-11-03 in 1.0.2.** The first product-path UEM run (`f7fcd1`, 14:16, New Teams 26276.x installed for the user on `CBRADLEYSWIN11`) reported `Completed` on both devices but wrote no DEXRecords on this VM: the pre-flight used `Get-AppxPackage -Name MSTeams` without `-AllUsers`, and Hub runs as SYSTEM, whose own package list never contains a per-user MSIX, so the script printed "[Skipped] Microsoft Teams does not appear to be installed" and exited 0 on the one device that had it. Every production run against New Teams has been a no-op. 1.0.2 asks for all users' packages first (SYSTEM is allowed to) and falls back to the caller's list for an interactive run; the later steps already read `InstallLocation` from that object, which `-AllUsers` still supplies. Same lesson as the 1.0.0 VPN collector: `Completed` on a device without the product, or on a device where detection fails, proves only the skipped path; read DEXRecords on the device. Closed: the 1.0.2 rerun (`66f681`, 14:27) wrote DEXRecords on this VM (`TeamsVariant New (AppX)`, 2 Passed), so the product path runs under Hub now.

bb. **`Invoke-RebootWithUserDefer.ps1` 1.2.0.7 carried the 2026-10-30 campaign into the 2026-11-03 run; no toast seen; open, awaiting device data.** On 2026-11-04 the user read `CHASEWIN11_2`: the orchestrator task `\WorkspaceOneEx\RebootPrompt-Orchestrator` is present and `Ready`, `RebootPrompt.log` does not exist, and `HKLM:\Software\AirWatch\Extensions\AdvancedReboot` still holds `FirstRunAt 2026-10-30T11:03` and `Deadline 2026-10-30T15:03`, the values written by the first run (`ea5217`). The installer resets them only when `FirstRunAt - LastBootUpTime` exceeds `MaxHours`, which is true only for a machine that was already up for more than `MaxHours` before the first run and never after a reboot (the difference is then negative), so the second deployment (`4891ec`, 14:11) inherited a deadline that had passed four days earlier: from its first poll the orchestrator was in mandatory mode and, with an active session, would have skipped the deferral toast and gone to the countdown. The orchestrator's own post-reboot cleanup (`FirstRunAt - LastBootUpTime <= 0` removes the task, the key and the helpers) has not fired either, although the VM was powered off between 2026-11-03 and 2026-11-04; the key would be gone if it had. Two readings fit the evidence: the orchestrator never ran after 2026-11-03 14:11 (the main-thread file is missing, or the task's repetition window, `MaxHours + 1` hours from the original 2026-10-30 registration, had expired and the installer did not re-register it because the stale task was still present), or the shutdowns were Fast Startup hibernations and `LastBootUpTime` predates 2026-10-30 (then the orchestrator should have forced a reboot, which did not happen). The log cannot settle it: `Write-Log` is called from one line only ("No active user sessions."), every other decision goes to `Write-Verbose`, which a scheduled task discards. The user's second read-back the same morning settled it: `LastBootUpTime 2026-11-04 11:25` (a real reboot), the orchestrator task's `LastRunTime 2026-07-08 16:58`, `LastTaskResult 4294770688`, `NextRunTime` empty, `Description "2026:07:08 12:03:34"`, `StartBoundary 2026-07-08`, and only the two helper files (written 2026-11-03 14:08) in the folder. So the task on the device is a July relic from an earlier release: its install stamp is written in a form `-as [datetime]` cannot parse, so `taskOld` was never true, the installer saw a task and never re-registered it, and its repetition window (`MaxHours + 1` hours from July) had long lapsed, so the orchestrator never ran once in October or November. The registry campaign was written by the 2026-10-30 install (the key did not exist then) and kept by the 2026-11-03 one. Both UEM runs (`ea5217`, `4891ec`) therefore proved only that the installer exits 0. Fixed 2026-11-04 in 1.2.0.8: the installer resets `FirstRunAt`/`Deadline` when the stamp is unreadable, `LastBootUpTime` is later than `FirstRunAt`, or the stored deadline has passed; it unregisters and re-registers the orchestrator when the install stamp is unreadable or older than `MaxHours`, or `Get-ScheduledTaskInfo` shows no next run; and the orchestrator writes its poll, cleanup, deadline, no-session, forced-reboot and toast decisions to `RebootPrompt.log` instead of `Write-Verbose`, which a scheduled task discards. The task unregister calls now pass `-TaskPath` as well. Parse-clean, 22,461 characters. UEM reruns on `Test_JSpencerOnly` with a user signed in on `CHASEWIN11_2`: `6e05a8` (10:44) hit `NoResult` at the manifest's 5 min and its item was deleted before Hub reported (status endpoint 204 afterwards), a rerun at 12:32 died when this VM was powered off for more cores before it created anything, and `696abb` (12:41, window 8 min) `Completed` 67 s after the sync. Device-side confirmation came from the user's paste of `RebootPrompt.log` and the registry: a fresh campaign (`FirstRunAt 2026-11-04T12:43:07-05:00`, `Deadline 16:43:07`), the orchestrator polling at 12:43:26, 12:48:25 and 12:53:26 with `lastBoot 12:40:35` (the device had just been rebooted for BitLocker), "quser returned no output (no sessions)" on the first two polls because the console was at the sign-in screen, and "Toast task launched for chase (mandatory=False)" at 12:53:39 once the user had signed in. So on 1.2.0.8 the orchestrator runs, keeps its own log, and launches the prompt; the stale July task is gone. A third run, `acbd3b` (12:54, requested by the user because the console had been at the sign-in screen for the first), `Completed` 200 s after the sync against a live campaign and a working task, which 1.2.0.8 is meant to leave alone; the device log for that interval has not been read back yet, so the no-op claim rests on the code path. The full log pasted at about 14:05 (`device-evidence-CHASEWIN11_2-2026-11-04-RebootPrompt.log` in the bundle) shows fifteen polls from 12:43 to 13:59 with "Toast task launched for chase" on every poll from 12:53; that is by design, the orchestrator hands off every 5 min and the helper enforces the 30 min `ShowEveryMinutes` cadence from `LastShownAt`, so whether the user saw a prompt every 5 min or every 30 is the helper's doing and can be read from the nested state key (cc). The 13:48 and 13:53 polls are missing: the task is `MultipleInstances IgnoreNew`, so a helper launch that ran long (each poll waits 10 s per user) or a busy host swallowed two triggers; the 13:59 poll resumed on the usual schedule and the campaign timestamps were unchanged throughout. The user then found the prompt itself in the notification centre (Win+N) on `CHASEWIN11_2`: the toast was delivered to the session but did not pop, which is Windows' behaviour when the toast arrives while the desktop is not yet ready or Focus Assist is on, not the script's. Closed.

cc. **`Invoke-RebootWithUserDefer.ps1` toast helper: "Not now" is a dismiss, not a counted deferral, and the per-user state key is nested under the host name. Found 2026-11-04 reading the device after the prompt; open, low impact.** The helper resolves the user with `whoami`, which returns `host\user`, and uses it as a registry path segment, so the state lands in `HKLM:\Software\AirWatch\Extensions\AdvancedReboot\<host>\<user>` (on the device: `...\AdvancedReboot\chasewin11_2\chase`), two levels down; a one-level listing shows an empty `<host>` key and looks like the write failed. The "Not now" button's protocol handler is `mshta.exe "javascript:close()"`, a no-op despite the "Increment deferrals" comment: `$deferrals` is read from a value nothing ever writes, so the only brake on re-prompting is the `ShowEveryMinutes` cadence (30 min here, from `LastShownAt`) and the only end is the `MaxHours` deadline. Also `Set-State @{ Deadline = ... }` writes `Deadline` while `Get-State` reads `DeadlineAt`, so that re-sync never takes effect. None of this changes when the device reboots, so the reboot behaviour proven today stands. Fixed 2026-11-05 in 1.2.1.2: the helper takes the bare user name from `[Environment]::UserName` (state key one level down, `...\AdvancedReboot\<user>`), the deadline re-sync writes `DeadlineAt`, and the deferral-counter code is removed with the comment now saying what "Not now" does (dismiss; cadence and deadline govern). Parse-clean. Exercised by the 2026-11-05 10:44 TestMode run: the state key appeared as `AdvancedReboot\chase`, one level down (row 66). Closed. What remains for row 66 is the by-hand part: the prompt's appearance, a deferral, and the forced reboot at the deadline (section 11).

dd. **`Invoke-AutoRemediateZoom.ps1` never saw a machine-wide install, found 2026-11-05 when Zoom 7.2.5 was put on `CBRADLEYSWIN11`.** The fallback candidate list was `@("$env:ProgramFiles\Zoom\bin\Zoom.exe", "...(x86)...", (if ($_userProfile) { ... } else { $null }))`: a bare `if` statement inside parentheses is parsed as a command named `if`, the `CommandNotFoundException` surfaced on the console and aborted the `foreach` that iterates the list, so the Program Files path was never tested and the script printed `[Skipped] Zoom does not appear to be installed` with exit 0 on a device that had Zoom. Only an install with an HKLM `App Paths\Zoom.exe` entry (the MSI) was ever detected. Fixed in 1.0.2: the list is built as a plain array with a conditional `+=`, and the logged-on user's own `App Paths` entry under `HKU\<sid>` is checked before the path fallbacks. Live run on the VM afterwards: `Steps: 5 Version: 7.2.5.51704`, all Passed. Lesson for the family: `$x = if (...) {...}` and `@(if (...) {...})` are legal, because an assignment and the array subexpression accept statements, but a plain `( )` inside a comma list does not, so there it must be `$(if ...)`. A grep for the construct across the production scripts found exactly one more copy: `Invoke-AutoRemediateChrome.ps1` line 103, the same per-user candidate in the same fallback, fixed the same way in Chrome 1.0.3 the same day. It never bit on the lab VM because Chrome's installer writes the HKLM `App Paths\chrome.exe` entry the first check reads, so the 1.0.2 break-test pass stands; the fallback only matters for a Chrome installed without that entry. The `@(if ($AdapterName) ...)` forms in `Invoke-AutoRemediateWiFiSignalIssues.ps1` are the legal array-subexpression form and were left alone.

ee. **Findings from the 2026-11-05 break-test authoring for the on-VM products (Teams, Zoom, Office six, BITS, WMI).** (1) `Invoke-AutoRemediateTeams.ps1` step 6 returned `Failed` for a broken New Teams package whether or not `AllowDestructiveActions` was set; `Failed` always runs the resolution, which without the flag only printed a skip note and returned, so the engine tagged the DEXRecords value `[Remediated]` and exited 1 for a re-registration the script had declined to run. Fixed in 1.0.3: the step is gated like the others (`ResolveOnWarning = $AllowDestructiveActions`; detection returns `Warning` with the flag off and `Failed` with it on). Not injectable on the lab VM (needs a package whose `Status` is not `Ok`); live run on the VM unchanged (2 steps, Passed). (2) `Invoke-AutoRemediateZoom.ps1` step 4 matched a bare `401` anywhere in a log line (ports, byte counts, ids), and with the flag on a false match deletes the user's real auth and token files; 1.0.3 matches 401 only as a standalone number and drops a doubled backslash from the step 2 message. Still open in Zoom: the "create the Zoom key" branch of the step 5 resolution is unreachable (resolution runs only after detection found a key), cosmetic. (3) The Outlook and OneDrive break tests imported the framework from three directories up, which stopped resolving when the Microsoft products moved under `ApplicationSpecific\Microsoft` (commit e87eaea); both threw "DEXTestFramework.psm1 not found" at startup since then and are fixed to four ups; every other harness checked and correct. (4) `Get-DexRandomSubset` in the framework shuffled the caller's array in place (`@()` does not copy an `object[]`); it now clones first. Harmless to the existing harnesses, which pass fresh pipeline arrays. (5) `Invoke-AutoRemediateWMIRepository.ps1` step 3 queries `root\ccm` and returns `Failed` when it is absent, so a consistent repository on any device without the CM client records `Status=Failed`; and its TrustedInstaller guard fires during any Windows servicing, which is frequent on Windows 11, so many legitimate `Warning 0/3/0` records are to be expected. Left as designed for an SCCM fleet; the harness encodes the no-client outcome. (6) `Invoke-AutoRemediateBITSBacklog.ps1` exits 1 after it has successfully re-enabled and started a Disabled BITS, the engine-wide "a Failed step means exit 1" convention. Left as is. (7) **Gate bypass in all six Office scripts, fixed 2026-11-05 in 1.0.2 of each.** Step 3 (COM Add-in Conflict) returned `Failed` when the step 2 crash module matched an add-in name, with a message ending "set $AllowDestructiveActions=$true to apply"; the shared engine remediates every `Failed` regardless of the flag, so the add-in would have been disabled with the gate closed. Excel step 6 (XLSTART Content) had the same shape on its "Repeated crashes" branch and would have quarantined the startup folder ungated. Both now return `Failed` only while the flag is on and `Warning` otherwise (`ResolveOnWarning` is already the flag), messages unchanged. Not injectable by the harnesses (needs a real crash naming a module), so the fix is by inspection; the gated and ungated add-in breaks in the six harnesses cover the branch that is injectable. (8) `CrashWarnCount7d=0` is accepted by the Office scripts and means "indicated with zero crashes" (Word step 9 runs its Data-key reset path, Excel step 6 took its Failed branch); left as is because 0 is a legitimate "always indicated" setting now that the Failed branches are gated, and the Word harness relies on it to reach step 9. (9) `_DecodeResiliency` reports the first NUL-separated segment of three or more letters, which for the harness fixture (header, path, name) printed the DLL path rather than the add-in name; whether Office's real blob also places the path first is unverified, so real messages may name a path. Open. (10) Excel step 9 removes every `OPENn` value before rewriting the kept ones, so an exception between the two loops loses all registrations. Minor, open. (11) The Office scripts read `CrashWarnCount7d`, not `CrashWarnCount`, and none of them reads `WhatIf`; step 8 (C2R update health) is `Enabled = $false` in Access, OneNote and Publisher. (12) **Size limit, found while recording the Office rows.** The 2026-11-05 EventLogReader rewrite (commit 9e9d99e, about 3,500 characters per script) took `Invoke-AutoRemediateWord.ps1` from 30,428 to 33,987 characters and the same change put `Invoke-AutoRemediateExcel.ps1` (36,446), `Invoke-AutoRemediatePowerPoint.ps1` (33,628), `Invoke-AutoRemediateOutlook.ps1` (33,890), `Invoke-AutoRemediateTimeSync.ps1` (32,857), `Invoke-AutoRemediateSCOMAgent.ps1` (52,066), `Invoke-AutoRemediateSCOMClonedIdentity.ps1` (36,162), `Invoke-AutoRemediateSCOMHealthServiceCache.ps1` (36,131) and `scom_agent_health.ps1` (35,985) over the 32,767-character pre-2607 limit the GENERAL runbook's rule 15 applies (the three measurement scripts over it were already known exceptions). The 1.0.2 gate fix added about 470 characters to each Office script on top. The lab break tests run the files directly and are unaffected; publishing to a pre-2607 console is. Options are the runbook's: shrink the shared helper and comments, split by step order, or record the rows as `UEM skip`. Not changed here; this needs the owner of the rewrite and a decision from the user.

Reconciliation of the 2026-10-29 sensor sweep (done 2026-11-03): ten sensors that returned real values on both devices were promoted to `4) Complete - Tested` (`certificate_store_health`, the four `defender_*`, `logon_username`, `logon_data_collected_at`, `power_profile_status`, `time_sync_health`, `startup_app_list`); five that returned nothing or failed on both devices but carried Tested were demoted (v, x). The `scom_*` sensors stay at Needs Testing because a VM without the agent proves only the no-agent branch (the 1.0.0 VPN collector lesson), `logon_*` scalars until v is fixed, and the three archived `Measure-*` rows (`Measure-GPLoadTime`, `Measure-GPLoadTimeEx`, `Measure-LogonDurationEx`) have no file on disk and should be marked archived rather than Tested.

Reconciliation of the 2026-11-05 logon sweep (`e5d833`, after collector 1.1.3 ran under Hub in `d17a02`): fifteen `logon_*` sensors promoted to `4) Complete - Tested` on real values from both devices (`logon_time`, `logon_gp_start_time`, `logon_gp_duration_ms`, `logon_gp_scripts_duration_ms`, `logon_folder_redirect_duration_ms`, `logon_profile_load_duration_ms`, `logon_fslogix_attach_duration_ms`, `logon_activesetup_duration_ms`, `logon_appx_load_duration_ms`, `logon_printers_mapped_count`, `logon_printer_mapping_duration_ms`, `logon_task_count`, `logon_task_total_duration_ms`, `logon_duration_summary`; `logon_username` and `logon_data_collected_at` were already Tested). `logon_shell_ready_time` and `logon_total_duration_ms` stay at Needs Testing: no value and -1 on Windows 11 until the 7001 `Shell` filter is replaced (8.3).

### 13.3 Collateral decisions

Decision taken 2026-11-02: run all three on the snapshotted lab VM `CBRADLEYSWIN11` and revert the snapshot afterwards. The AppX run (da4f55c3d6f8) did remove the inbox consumer apps for every user on that VM, as predicted below.

1. **AppX bloat.** The target script applies its default consumer-app deny list on every run with no off switch, and the break test must set `RemoveForExistingUsers=true` to reach the step it tests, so a run deprovisions and removes the inbox consumer apps (Xbox, Bing Weather and News, Solitaire, Feedback Hub, Get Help, Maps, Clipchamp and others) for every user on the lab VM, including the signed-in one. Not reversible from the harness. Options: run it on the snapshotted VM and revert; or first add a `DenyListOverride` input to the script so the test (and customers) can supply a curated list.
2. **Profile bloat.** The script processes every non-special profile, so a run also deletes the signed-in user's own aged temp, browser, Teams, crash-dump and Recent items. Fine on the snapshotted VM; not on a working machine.
3. **Logon task contention.** Step 1 rewrites the delay on every enabled non-Microsoft AtLogOn task on the host, not only the fixtures. Same answer: snapshotted VM only.

### 13.4 How to run one

Elevated, on the marked lab VM, after a snapshot:

```powershell
.\<Script>_BreakTest.ps1 -Force -RemediationTest            # random break selection, result JSON written
.\<Script>_BreakTest.ps1 -Force -RemediationTest -BreakName <Name>   # one named break
.\<Script>_BreakTest.ps1 -Force -Restore                     # undo an in-flight run
```

`-Environment Snapshot` skips the restore phase when the host will revert anyway. Breaks flagged `RequiresReboot` need `-IncludeRebootBreaks`; none of the thirteen new tests has one. An elevated prompt opens in `C:\Windows\System32`, so the practical form is `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<absolute path to the test>" -Force -RemediationTest`.

The three tests added later on 2026-11-02 (`Restart-WinService`, `Restart-WinProcessGraceful`, `Invoke-VpnStateCollection`) drive one invocation of their target per run, so full coverage is one run per break with `-BreakName` (three each for the first two, four for the VPN collector, whose test 1.1.0 stops and starts the lab WireGuard tunnel service itself). `Restart-WinProcessGraceful_BreakTest.ps1` must run from the signed-in user's own elevated prompt (the watchdog shares that desktop) and skips any candidate app that already has a window open, so close Notepad and Chrome first to exercise them; otherwise it falls back to Character Map.

### 13.5 Run log, 2026-11-02

Elevated, lab VM `CBRADLEYSWIN11`, snapshot taken first. Result files are `C:\Temp\FixReport\<ScriptUnderTest>\<run id>.json`, copied to the evidence bundle under `lab-results/`. "Passed" means every break was verified before the remediation ran and every validation matched its expected outcome; the per-script rows in 1.2 carry the detail and the Full Pass status.

| Break test | Run id(s) | Outcome | Reading |
|---|---|---|---|
| `Invoke-RemediateMemoryCompression` | 075ce256c2af | Passed | |
| `Invoke-RemediatePageFile` | 70ec5b19ade0, 9e2d8e9b803e, f4b3611eecf8, 4e166254f72d, c845854c3e7e, 5e9fa8a3e6c3, 114fedf1ed3c; rerun 75c3e07e492d | Passed (c845854c3e7e reported-only break, 114fedf1ed3c fixed break; 75c3e07e492d fixed break again after the revert) | The five failures are all the same harness fault: `New-CimInstance`, `Set-CimInstance`, `Set-WmiInstance` and the WMI object's own `Put()` each answered "Value out of range" when writing a 2048 MB fixed page file, with 9 GB free on `C:` and 8 GB of RAM; the cause was not found. `Win32_PageFileSetting` is a view of the `PagingFiles` registry value, so the test now writes that value directly when WMI refuses, records it verbatim before the break and restores it verbatim. The one run that drew the ClearAutomaticFlagOnly method needed no size write and passed; run 114fedf1ed3c then took the registry fallback for the fixed break and passed, the script turning automatic management back on and writing `Status = Remediated`. |
| `Invoke-RemediateSysMain` | a1b442690696, 90575d8adf92 | Passed | Second run named the SysMainDisabledWhileRunning break. |
| `Enable-HardwareAcceleratedGPUScheduling` | 61f9d608ba6d | Passed | |
| `Restart-WindowsUpdateServices` | 3cbd00c57db4; rerun 25ed65fb8da0 on 1.6.2.0 (2026-11-05) | Passed | The 1.6.2.0 rerun drew WuauservStopped and CryptSvcStopped; both repaired, dependents handling exercised with none running. |
| `Invoke-DriverUpdates` | f6feb1b31416; rerun 0ec8523cc211 on 1.0.1 (2026-11-05) | Passed | The 1.0.1 rerun repaired WuauservStopped in 46 s with the policy pre-check and the pending-reboot helper in the path. |
| `Invoke-DefenderDynamicPerformance` | acd1081436f9; rerun f5e48cac81fc on 1.2.0 (2026-11-05) | Passed | The 1.2.0 rerun drew PriorityDriftMarkerRemoved and NonNumericScore; both repaired through the drift comparison and the fingerprinted cache. |
| `Invoke-AutoRemediateLogonTaskContention` | 4b1fd3dc15d5, b96db5bec056, 870d6373af80, 43252617a969; rerun 0ed69496da08; rerun f3dba3f5c473 on 1.0.3 (2026-11-05) | Passed (fourth run, the rerun after the revert, and the 1.0.3 rerun: delay repaired, 12-task volume reported and left) | First run: the harness counted zero qualifying tasks under elevation, its own ten fixtures included, and refused to run the remediation; its task enumeration now walks the Task Scheduler COM folders and reads each task individually. Second run ended `FalsePass` on the volume break, but the diagnostic line added to Verify went to the output stream, which the harness casts to `[bool]`, so Verify could not have returned false and the Validate failure has no diagnosis. Diagnostics now go to the host stream and Validate prints each component (fixtures untouched, still over threshold, reported). The script itself did what its header says: delayed the one fixture that needed it (+60 s), reported 19 AtLogOn tasks against the warn threshold of 8 and changed none of them. Third run (870d6373af80): with the diagnostic visible, the folder query found all 8 fixtures but the COM walk with per-task CIM reads returned no qualifying task, so the CIM reads themselves come back empty inside the elevated harness while a child `powershell.exe` sees everything; the harness now takes path, state and logon-trigger delays from the COM task definition, with no CIM in the enumeration, and prints the folder and task counts. Fourth run (43252617a969): 17 folders, 34 tasks, 12 qualifying, both breaks verified, both validations as expected, and the script's own `QualifyingTaskCount` matched the harness count. |
| `Invoke-AutoRemediateProfileBloat` | a70511beb91d, c5f156390a70, 259114dfef14, 2136e10ee79e; rerun 711bbbadf409; rerun e446f8bd2e99 on 1.0.3 (2026-11-05) | Passed (fourth run, the rerun after the revert, which drew OversizedRoamingAppData, reported only, and ShaderCaches, repaired, and the 1.0.3 rerun, which drew CrashDumps and UserTempFiles, both repaired) | `CreateProfile` returned 0x800706F7 (RPC_X_BAD_STUB_DATA). The fixture now falls back to a hidden process started as the test user with `-LoadUserProfile`, the method the profile-cleanup test already uses. Second run (c5f156390a70): the fallback created the profile and ShaderCaches verified, but RecentItems did not: 601 aged `.lnk` files were written to `Recent` without error and none was counted a moment later, while the same code counts 600 of 600 in a scratch folder on the same host. Third run (259114dfef14) with the diagnostics showed the cause: the helper that resolves fixture paths returned a one-element array, which PowerShell unrolls to a bare string, so indexing `[0]` gave the letter `C`, and the 601 shortcuts went to `C:\Windows\System32\C\` (the harness's working directory) while Verify looked in the profile. The helper now returns with the leading-comma idiom; the eight call sites that index `[0]` are unchanged. The stray `System32\C` folder was removed by hand on the VM. Fourth run (2136e10ee79e): drew ShaderCaches (RDP bitmap cache) and TeamsCache, both verified, both cleared with control files kept; the other seven breaks have not yet been drawn. |
| `Invoke-AutoRemediateAppXBloat` | f3daf194e657, da4f55c3d6f8; rerun 40c964fd36f8 | Passed (second run, and the rerun after the revert) | First run: Windows will not register a framework package in Developer Mode (0x80073CF9); the fixture is now a main package with one full-trust application whose executable is a copy of `cmd.exe`, never launched. Second run: the script removed the probe and, as 13.3 predicted, ten inbox consumer packages for every user on the VM. |
| `Invoke-AutoRemediateChrome` | ea3f7e8bbf4f; rerun 03ba04fe011b on 1.0.2 (2026-11-05) | Passed | The 1.0.2 rerun drew CrashLoop (reported) and OrphanedNativeMessagingHost in HKLM (pruned through the new hive list). |
| `Invoke-AutoRemediateOneDrive` | 2dd3df491bfa | Passed | |
| `Restart-WinService` (14:42) | 795e25b09857, 27398be0af27, 2ab15d7c8d96 | Passed | One break per run: SpoolerStopped fixed, SpoolerDisabledAndStopped and UnknownServiceName reported only, Spooler restored each time. Rerun f8724f5670f6 on 1.7.1.0 (2026-11-05): SpoolerStopped repaired through the exact-name lookup. |
| `Restart-WinProcessGraceful` (14:43) | 909a4e0e2236, bdd6b5d9ba62, fc7b3529f3ab; reruns 40a560a2b4d3 (ProcessNotRunning) and 1ac93c400483 (ProcessRunningRestart, pinned) on 2.2.0 (2026-11-05) | Passed | Notepad, Chrome and cmd were open, so the test used Character Map, launched as the signed-in user. The watchdog closed it gracefully in both runs (`result.json` Status Completed, Graceful 1, Forced 0), relaunched it when `Restart=true` (new PID 5776, 18 s after the original) and left nothing when `Restart=false`; the no-match run recorded `NoMatch` and dispatched nothing. |
| `Invoke-VpnStateCollection` (14:44) | 3cdde68c3ae0, 28c4658528e5, e0b9b0a51cc2 | Failed (harness) | All three ended `HarnessError "Invoke-VpnStateCollection : "`. Two causes, both found the same hour. The harness ran the collector under `$ErrorActionPreference = 'Stop'`, so the first stderr line became a terminating error and swallowed the detail; and the collector itself crashed, because the user had already brought a WireGuard tunnel up on this VM and step 5 called `Get-NetAdapterStatistics -InterfaceIndex`, a parameter the cmdlet does not have (13.2.q, fixed in 1.0.1). The first run also applied no break at all: with a single `-BreakName` the selection unrolled to a bare hashtable and the exclusivity filter removed it. Rerun with test 1.1.0 and collector 1.0.1 at 15:08-15:11: `f26937f84576` TunnelConnectedReported Passed (collector reported ClientCount 1, Connected, Split, MTU 1420, score 100 Healthy, matching the live derivation), `01c6dadd22f9` StaleCacheFromPriorClient Passed (12 planted discrepancies overwritten), `b91e95203a31` CacheValueKindsWrong Passed (four swapped kinds replaced). `f15c2e55a2b6` and `35ce4a7f6182` NoVpnClientReported ended BreakFailed: the harness reported one candidate adapter with an empty name and description 30 s after the tunnel service stopped and refused to run the collector. That "candidate" was the harness's own empty array: the candidate helper returned `,[object[]]@()` and every caller wrapped it in `@(...)`, so the count was 1 with the tunnel up or down (the connected breaks passed by accident of that count). Test 1.1.1 returns a plain array; rerun `e73c23ecf1ac` (15:20) Passed: tunnel service stopped, zero candidates verified, collector wrote the no-client row (score -1, NoVpnClient), tunnel restored. All four breaks have now passed on collector 1.0.1. |
| `Invoke-AutoRemediateGenericVPN` (19:53) | a902d1fdde65, 8149d16fe088, a53fc74b8558, 348f1ade7322, 3bd4c0e35566 | Passed (four); 3bd4c0e35566 FalsePass, harness | Against the live WireGuard tunnel. MTU 1500 and MTU 1200 both brought to the script's fixed 1400 and restored to 1420; DNS reset reported with the flush-only step leaving the list empty as designed; RasMan stopped and Disabled came back Manual and Running. The NoVpnClientReported run was a harness misread: the remediator took its guard path ("No VPN client present", exit 0, no cache write), but the cache stamp from the run launched five seconds earlier fell inside the harness's 5 s tolerance and read as "written by this run". Test 1.0.1 also compares the stamp with the one captured just before invoking; rerun `eebc79b8d26b` (23:58) Passed. All five breaks have now passed. |
| `Invoke-AutoRemediateOutlook` (19:58) | 32ab16c12640, 26d88480f115, 0b870c1748a3, b7d23957780b, 1acbb7db6d17 | Passed (four); b7d23957780b refused by design | Against classic Outlook 16.0.18925 signed into an outlook.com account (real OST 16 MB; fixture sized 273 MB with the threshold set to match). Planted add-in reported when gated and set to `LoadBehavior 0` when ungated; fixture OST reported when gated; `UpdatesEnabled=False` reported as Warning with exit 0 on 1.0.2 (1.0.1 would have exited 1). The ungated OST run (`b7d23957780b`) stopped itself because `OUTLOOK.EXE` was open and the harness will not kill a user's Outlook; rerun with Outlook closed pending. |
| `Invoke-AutoRemediateOutlook` on 1.1.0 (2026-11-03 08:26) | 17d802490671, adb65d1d0cbb, 7c1db1a7519c, 590f40e38794, 8eccf8929e22, c7c9e791ae0f; a135b9e86acc refused; a0a4367071fd, ff8b6dd9627d FalsePass | Passed (six) | Both add-in breaks, both gated OST breaks, tier 1 (`SyncWindowSetting` 12 written, fixture untouched), tier 2 with Outlook closed (fixture renamed) and the C2R Warning all passed. `a135b9e86acc` was the tier 2 run with Outlook still open, refused by design. The deferred close failed twice: `a0a4367071fd` ended `UserActionRequired` because Outlook did not close after the helper's single WM_CLOSE; `ff8b6dd9627d` closed, renamed and relaunched Outlook but left the one-shot task registered, because the limited helper cannot delete a task the elevated launcher registered (the script's next run removes it, which the harness did not exercise). Helper to retry the close during its wait; harness to run the script a second time and assert the cleanup and the result ingestion. Third attempt `0cb9cfebabdf` (08:41): close landed on the first attempt, fixture renamed, Outlook relaunched, and the second run ingested the outcome into DEXRecords; the task was still registered because the harness launched that second run five seconds after the result file appeared, while the helper was still finishing, so the task was Running and the script correctly left it alone. Harness 1.1.2 waits for the helper to exit first; fourth attempt `2d605de6719e` (08:52) Passed: close landed on the second request, fixture renamed, Outlook relaunched, helper settled in 33 s, the second run removed the task and recorded `Renamed` in DEXRecords. All seven breaks have now passed on 1.1.0. Durations worth noting: the script usually finishes in 3 to 17 s, but two runs took 149 s (`32ab16c12640`, 1.0.2, minutes after Office was installed) and 102 s (the second run here, while Outlook relaunched); in both the header timestamp shows the time went before the script's first line, so host load at PowerShell start, not a step. 1.1.1 bounds the step 3 query anyway; see 13.2.s. Rerun on 1.1.1 at 10:25: `223eb177b567` (add-in fix), `d8d1a083f0be` (C2R Warning) and `e823862823dd` (deferred close: three close attempts, renamed, helper settled in 6.3 s, second run cleaned up in 8.1 s) all Passed; script runs 3.2 s, 2.7 s, 8.1 s and 5 s. |
| `Start-UserProfileCleanup` | b2ca8814334e, 0c7bf67c2b55, 28180d46896e, 7027f9afc870; rerun 1b0af182287a | Passed (third and fourth runs, and the rerun after the revert, which drew StaleOversizedProfile, deleted, and EnrollmentUserProfileKept, left alone) | First two runs: the `0xFFFFFFFF` SID mask literal is an `[int32]` -1 in PowerShell 5.1 and the `[uint32]` cast failed on a real SID component; fixed with an `[int64]` mask. The passing runs deleted the 98.71 MB `DEXTestProfile` and left `DEXTestKeep` (2.71 MB) and the enrollment-user fixture in place, which together cover all three breaks. Rerun a83bab70487a on 1.1.0 (2026-11-05): StaleOversizedProfile deleted, EnrollmentUserProfileKept left alone, with the scratch anchor on the new SID filter. |
| `Invoke-AutoRemediateTimeSync` (2026-11-03 12:37 and 13:25) | 3042d520cb84 FalsePass (harness); 017c7d370050 | Passed | Script 1.0.1 and harness with the literal prefix match. W32TimeService StoppedManualOrDisabled fixed to Running/Manual; WorkgroupNoPeer reported, `Type=NoSync` left, restored. The restore's `Restart-Service` printed five "Waiting for service to stop" warnings, now suppressed. Clock sat on `Local CMOS Clock` afterwards until the live run on 2026-11-04 09:02 resynced it. |
| `Invoke-AutoRemediateCertEnrollment` (2026-11-03 12:40 and 13:28) | a509cfb91722 FalsePass (harness); 2df122ace6f8 | Passed | Script 1.0.1. WeakAlgorithmCertificate (sha1RSA) and ExpiredCertificate reported, left in place, removed by restore. |
| `Invoke-AutoRemediateCertEnrollment` (2026-11-04 10:13) | e1cfd894147c | Passed | AutoenrollmentTask (SystemTask disabled) repaired through the COM API in 3.8 s; WeakAlgorithmCertificate reported and left. Every break in this harness has now passed. |

**Reruns after the snapshot revert (12:57 to 13:38).** `CBRADLEYSWIN11` was reverted to its morning snapshot after the runs above, and the evidence bundle restored from a backup taken at about 10:54, so the result files for seven of the passes (c845854c3e7e, 114fedf1ed3c, 2136e10ee79e, 28180d46896e, 7027f9afc870, 43252617a969, da4f55c3d6f8) no longer exist anywhere; the run log above is their record. The five scripts were rerun on the fresh snapshot with the fixed harnesses and all passed first time: page file 75c3e07e492d (the WMI size write still answers "Value out of range" and the registry fallback took over, as designed), profile bloat 711bbbadf409, profile cleanup 1b0af182287a, logon task contention 0ed69496da08 (10 qualifying tasks against the threshold of 8), AppX bloat 40c964fd36f8. Those five files are on disk and in `lab-results/`, and the section 2 rows cite them.

Two harness rules came out of these runs and apply to every break test from now on: a Verify or Validate block writes nothing to the output stream except its verdict (the harness casts the block output with `[bool]`, and a two-element array is always true), and every catch block records the exception and line in the result file's `HarnessError` field so a failed run can be read without a console paste. Both are in place in all nineteen tests. A third, from the profile-bloat fixture: a helper that can return one path must return it with the leading-comma idiom (`return ,[string[]]@(...)`), or a caller's `[0]` indexes the string.

Page-file note for the operator: the failed PageFile runs each cleared `AutomaticManagedPagefile` before the WMI write failed, and Restore wrote the captured flag back. The run that passed (11:18) captured the flag already off with system-managed sizes (`C:\pagefile.sys 0 0`), and the host shows the same today; whether the flag was on before the first attempt at 10:44 was not recorded. If it was, re-enable it in System Properties (Advanced, Performance, Virtual memory, "Automatically manage paging file size for all drives"). The test now records the exact `PagingFiles` value before each break so this question does not come up again; run 114fedf1ed3c captured `C:\pagefile.sys 0 0` with the flag off as its baseline as well.

