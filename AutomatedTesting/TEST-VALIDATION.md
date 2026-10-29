# Test Validation - Resolution Scripts

**Audience:** engineers validating resolution (non-sensor) scripts before they are marked `4) Complete - Tested` in `SCRIPT-INVENTORY-CSV.csv` and published through Workspace ONE UEM.

**Scope:** every resolution script in the repo outside `Archived`, `Deprecated`, `TroubleshootingWizard`, `_RAWDATA`, `Sensors` and `OneTimeSensor`. 66 scripts in 7 groups. Sensors are covered by `UEM-API-TESTING-SPEC.md` and `General-Testing-Guide.md`, not here.

**Last updated:** 2026-10-29 (defect fixes applied and statuses revised). Lab evidence in this document comes from the runs recorded in `C:\Temp\FixReport\Summary.csv` and `C:\Temp\DEXLabRuns\LabRun_20261028_14*\` on the lab VM.

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
| `PASS - UNIT` | Pester unit tests pass. No hardware-level proof |
| `TESTED - MANUAL` | Inventory says `4) Complete - Tested`. The test was manual and no result artefact is in the repo. Steps below reproduce it |
| `NEEDS TEST` | Steps written, not yet executed |
| `NEEDS TEST - PRODUCT VM` | Steps written, but the product is not on the lab VM. Needs a VM with the product installed |
| `MANUAL ONLY` | Session-ending or destructive to user data. Never run through the harness or the UEM test group. Manual steps given |
| `FIX FIRST` | A defect found during review makes a test meaningless until the script is corrected |

### 1.2 Lab environment

| Item | Value |
|---|---|
| Host | `CBRADLEYSWIN11`, VMware VM, Windows 11 Pro build 26200, WORKGROUP |
| Snapshot | Taken before the 2026-10-28 runs. Revert to it after any `Dirty` harness result or any `MANUAL ONLY` test |
| Test marker | `C:\Temp\FixReport\.dex-test-machine` exists (required by `Assert-DexTestHost`) |
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

Scripts with hard-coded tunables and no variables at all, where the file itself must be edited before publishing: `Start-UserProfileCleanup.ps1` (`$DAYS_INACTIVE`, `$SIZE_THRESHOLD_MB`, `$ENROLLMENTUSER`), `Invoke_RebootWithUserDefer_1.2.0.7.ps1` (`$MaxHours`, `$ShowEveryMinutes`, `$RebootCountdownSeconds`), `Invoke-SimpleReboot.ps1` (`$CountdownSeconds`).

Inventory discrepancy: `SCRIPT-INVENTORY-CSV.csv` marks `Invoke-AutoRemediateDriverIssues.ps1` and `Invoke-AutoRemediateAllDriverIssues.ps1` as `Requires Input = Yes`, but both default `DriverFilter` to empty (all devices) and run without any variable. The six scripts in the first table are the ones that truly require one; the inventory agrees on all six.

---

## 2. Summary

| # | Script | Group | Inventory status | Impact | Automated coverage | Validation status |
|---|---|---|---|---|---|---|
| 1 | `Invoke-AutoRemediateAllDriverIssues.ps1` | Device / driver | Needs Testing | Critical | Break test, 21 unit tests, UEM entry | `PASS - LAB` 2026-10-28 |
| 2 | `Invoke-AutoRemediateDriverIssues.ps1` | Device / driver | Needs Testing | Critical | Break test, 9 unit tests, UEM entry | `PASS - LAB` 2026-10-28 |
| 3 | `Invoke-AutoRemediateAudioBluetooth.ps1` | Device / driver | Needs Testing | Medium | Break test (5 breaks) | `PASS - LAB` 2026-10-28 (after v1.0.2 fixes) |
| 4 | `Invoke-AutoRemediateNetworkStack.ps1` | Device / driver | Needs Testing | High | Break test (2 breaks), UEM skip | `PASS - LAB` 2026-10-28 |
| 5 | `Invoke-AutoRemediateWindowsUpdates.ps1` | Device / driver | Needs Testing | Medium | Break test (4 breaks) | `PASS - LAB` 2026-10-28 |
| 6 | `Invoke-AutoRemediatePrinter.ps1` | Device / driver | Needs Testing | Low | Break test (4 breaks incl. reboot) | `PASS - LAB` 2026-10-28 |
| 7 | `Invoke-AutoRemediateWiFiSignalIssues.ps1` | Windows remediation | Needs Testing | Medium | none | `NEEDS TEST - PRODUCT VM` (no Wi-Fi adapter) |
| 8 | `Invoke-DriverUpdates.ps1` | Windows remediation | Needs Testing | Medium | none | `NEEDS TEST` |
| 9 | `Invoke-RemediateMemoryCompression.ps1` | Windows remediation | Needs Testing | Low | none | `NEEDS TEST` |
| 10 | `Invoke-RemediatePageFile.ps1` | Windows remediation | Needs Testing | Medium | none | `NEEDS TEST` |
| 11 | `Invoke-RemediateSysMain.ps1` | Windows remediation | Needs Testing | Low | none | `NEEDS TEST` |
| 12 | `Disable-NonEssentialStartupApps.ps1` | Windows remediation | Needs Testing | Medium | none | `TESTED - MANUAL` (User path, 2026-10-29); SYSTEM path `NEEDS TEST` |
| 13 | `Enable-HardwareAcceleratedGPUScheduling.ps1` | Windows remediation | Needs Testing | Medium | none | `NEEDS TEST` |
| 14 | `Restart-WindowsUpdateServices.ps1` | Windows remediation | Needs Testing | Medium | none | `NEEDS TEST` |
| 15 | `Restart-WinProcess.ps1` | Windows remediation | Needs Testing | High | UEM skip (needs variables) | `TESTED - MANUAL` (fixed and verified 2026-10-29) |
| 16 | `Restart-WinProcessGraceful.ps1` | Windows remediation | Needs Testing | High | UEM skip (needs variables) | `NEEDS TEST` |
| 17 | `Restart-WinProcessGracefulEx.ps1` | Windows remediation | NOT IN CSV | - | none | `NEEDS TEST` (fixed 2026-10-29; prototype, not for publication) |
| 18 | `Restart-WinService.ps1` | Windows remediation | Needs Testing | Medium | UEM entry (Spooler) | `NEEDS TEST` |
| 19 | `Invoke-AutoRemediateAppXBloat.ps1` | Windows logon | Needs Testing | Medium | none | `NEEDS TEST` |
| 20 | `Invoke-AutoRemediateFSLogixExclusions.ps1` | Windows logon | Needs Testing | None | none | `NEEDS TEST - PRODUCT VM` (no FSLogix) |
| 21 | `Invoke-AutoRemediateLogonTaskContention.ps1` | Windows logon | Needs Testing | Low | none | `NEEDS TEST` |
| 22 | `Invoke-AutoRemediateProfileBloat.ps1` | Windows logon | Needs Testing | Low | none | `NEEDS TEST` |
| 23 | `Invoke-CrowdStrikeServiceRemediation.ps1` | Antivirus | Needs Testing | Medium | none | `NEEDS TEST - PRODUCT VM` (fixed 2026-10-29) |
| 24 | `Invoke-DefenderDynamicPerformance.ps1` | Antivirus | Needs Testing | Low | none | `NEEDS TEST` (rewritten 2026-10-29) |
| 25 | `Invoke-DefenderEnableCloudBlock_BAFS.ps1` | Antivirus | Tested | Low | none | `TESTED - MANUAL` |
| 26 | `Invoke-DefenderPauseScan.ps1` | Antivirus | Tested | Low | none | `TESTED - MANUAL` |
| 27 | `Invoke-DefenderServiceRemediation.ps1` | Antivirus | Tested | Low | none | `TESTED - MANUAL` |
| 28 | `Invoke-DefenderUpdateSignatures.ps1` | Antivirus | Tested | Low | none | `TESTED - MANUAL` |
| 29 | `Start-DefenderFullScan.ps1` | Antivirus | Needs Testing | Low | none | `NEEDS TEST` (fixed 2026-10-29) |
| 30 | `Start-DefenderThreatReport_1.4.8.4.ps1` | Antivirus | Tested | Low | none | `TESTED - MANUAL` |
| 31 | `Invoke-TrellixCPUPriority.ps1` | Antivirus | Needs Testing | Low | none | `NEEDS TEST - PRODUCT VM` |
| 32 | `Invoke-TrellixLocalUpdate.ps1` | Antivirus | Needs Testing | Low | none | `NEEDS TEST - PRODUCT VM` |
| 33 | `Invoke-TrellixRefreshPolicies.ps1` | Antivirus | Needs Testing | Low | none | `NEEDS TEST - PRODUCT VM` |
| 34 | `Invoke-TrendMicroServiceRemediation.ps1` | Antivirus | Needs Testing | Medium | none | `NEEDS TEST - PRODUCT VM` |
| 35 | `Invoke-AutoRemediateChrome.ps1` | Application | Needs Testing | Low | none | `NEEDS TEST` |
| 36 | `Invoke-AutoRemediateOneDrive.ps1` | Application | Needs Testing | Medium | none | `NEEDS TEST` |
| 37 | `Invoke-AutoRemediateOutlook.ps1` | Application | Needs Testing | Medium | none | `NEEDS TEST - PRODUCT VM` |
| 38 | `Invoke-AutoRemediateTeams.ps1` | Application | Needs Testing | Medium | none | `NEEDS TEST - PRODUCT VM` |
| 39 | `Invoke-AutoRemediateZoom.ps1` | Application | Needs Testing | Medium | none | `NEEDS TEST - PRODUCT VM` |
| 40 | `Invoke-AutoRemediateBITSBacklog.ps1` | Application (SCCM) | NOT IN CSV | - | none | `NEEDS TEST - PRODUCT VM` |
| 41 | `Invoke-AutoRemediateCcmCache.ps1` | Application (SCCM) | NOT IN CSV | - | none | `NEEDS TEST - PRODUCT VM` |
| 42 | `Invoke-AutoRemediateOrphanedCcmSetup.ps1` | Application (SCCM) | NOT IN CSV | - | none | `NEEDS TEST - PRODUCT VM` |
| 43 | `Invoke-AutoRemediateSCCMClient.ps1` | Application (SCCM) | NOT IN CSV | - | none | `NEEDS TEST - PRODUCT VM` |
| 44 | `Invoke-AutoRemediateWMIRepository.ps1` | Application (SCCM) | NOT IN CSV | - | none | `NEEDS TEST - PRODUCT VM` |
| 45 | `Invoke-AutoRemediateSCOMAgent.ps1` | Application (SCOM) | Needs Testing | Medium | none | Reference only (48,336 chars, over the UEM limit) |
| 46 | `Invoke-AutoRemediateSCOMAgentPart1.ps1` | Application (SCOM) | Needs Testing | Medium | none | `NEEDS TEST - PRODUCT VM` |
| 47 | `Invoke-AutoRemediateSCOMAgentPart2.ps1` | Application (SCOM) | Needs Testing | Low | none | `NEEDS TEST - PRODUCT VM` |
| 48 | `Invoke-AutoRemediateSCOMAgentPart3.ps1` | Application (SCOM) | Needs Testing | Low | none | `NEEDS TEST - PRODUCT VM` (fixed 2026-10-29) |
| 49 | `Invoke-AutoRemediateSCOMClonedIdentity.ps1` | Application (SCOM) | Needs Testing | High | UEM skip | `NEEDS TEST - PRODUCT VM` (fixed 2026-10-29) |
| 50 | `Invoke-AutoRemediateSCOMHealthServiceCache.ps1` | Application (SCOM) | Needs Testing | High | UEM skip | `NEEDS TEST - PRODUCT VM` (fixed 2026-10-29) |
| 51 | `Invoke-AutoRemediateSCOMMonitoringHost.ps1` | Application (SCOM) | Needs Testing | Medium | none | `NEEDS TEST - PRODUCT VM` |
| 52 | `Start-ClearRecycleBin.ps1` | Disk cleanup | Tested | Low | none | `TESTED - MANUAL` |
| 53 | `Start-DiskCleanup.ps1` | Disk cleanup | Tested | Low | none | `TESTED - MANUAL` |
| 54 | `Start-UserProfileCleanup.ps1` | Disk cleanup | Needs Testing | High | UEM skip | `MANUAL ONLY` |
| 55 | `Get-AppVolumesMountProbe.ps1` | Generic troubleshooting | NOT IN CSV | - | none | `NEEDS TEST - PRODUCT VM` |
| 56 | `Enable-LogonAuditLogs.ps1` | Generic troubleshooting | Tested | Low | none | `TESTED - MANUAL` |
| 57 | `Measure-LogonDuration.ps1` | Generic troubleshooting | Tested | Low | none | `TESTED - MANUAL` |
| 58 | `Measure-LogonDurationMultiSession.ps1` | Generic troubleshooting | NOT IN CSV | - | none | `NEEDS TEST` |
| 59 | `DEX_Invoke-SignoffWindows.ps1` | MDM commands | Tested | High | UEM skip | `MANUAL ONLY` |
| 60 | `DEX_LockDevice-BitlockEncryptionActivated.ps1` | MDM commands | Needs Testing | Critical | UEM skip | `MANUAL ONLY` (intent confirmed by inventory; header and error handling fixed 2026-10-29) |
| 61 | `DEX_Start-LockDeviceSoft.ps1` | MDM commands | Tested | Low | UEM skip | `MANUAL ONLY` |
| 62 | `Invoke-AutoRemediateGenericVPN.ps1` | VPN | Needs Testing | Medium | none | `NEEDS TEST - PRODUCT VM` |
| 63 | `Invoke-VpnStateCollection.ps1` | VPN | Needs Testing | Low | none | `NEEDS TEST` |
| 64 | `Invoke_RebootWithUserDefer_1.2.0.7.ps1` | Reboot | Tested | High | UEM skip | `MANUAL ONLY` (orchestrator and toast defects fixed 2026-10-29; needs one end-to-end re-run) |
| 65 | `Invoke-SimpleReboot.ps1` | Reboot | Tested | High | UEM skip | `MANUAL ONLY` |
| 66 | `SmartReboot.ps1` | Reboot | Tested | Low | none | `TESTED - MANUAL` |

Counts after the 2026-10-29 fixes: 6 `PASS - LAB`, 12 `TESTED - MANUAL`, 0 `FIX FIRST`, 6 `MANUAL ONLY`, 1 reference-only copy, 23 `NEEDS TEST - PRODUCT VM`, 18 `NEEDS TEST` (plus the SYSTEM path of `Disable-NonEssentialStartupApps.ps1`). 8 scripts have no inventory row. `Restart-WinProcessSoft.ps1` (0 bytes) is excluded from the count.

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

**Status:** `PASS - LAB`. Evidence: `C:\Temp\FixReport\Invoke-AutoRemediateAllDriverIssues\250c0e222440.json` (Passed, UsbDriverDisabled, 2026-10-28 14:57) and `172ec542622b.json` (boundary probe, Failed as expected). Five passing runs and four expected-failure probes recorded in `Summary.csv` across the day. Unit tests 21/21.

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

**Status:** `PASS - LAB`. Evidence: `C:\Temp\FixReport\Invoke-AutoRemediateDriverIssues\ac4fd4a9f531.json` (Passed, 14:57). Four passing runs today, zero failures. Unit tests 9/9.

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

**Status:** `PASS - LAB`. Evidence: `C:\Temp\FixReport\Invoke-AutoRemediateAudioBluetooth\972720efc3e4.json` (Passed, 5/5 breaks validated, 14:58) and `782c100fb879.json` (Passed, 14:55). The two 14:29 and 14:32 runs validated only 3 of 5; the v1.0.2 changes below fixed the remaining two.

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

**Status:** `PASS - LAB` for the two safe steps. Evidence: `C:\Temp\FixReport\Invoke-AutoRemediateNetworkStack\89bb2f85208e.json` (Passed, 14:59), four passing runs today. Adapter and Winsock steps remain manually verified only, by design.

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

**Status:** `PASS - LAB`. Evidence: `C:\Temp\FixReport\Invoke-AutoRemediateWindowsUpdates\9a0da4c96876.json` (Passed, 4/4, 14:59), four passing runs today.

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

**Status:** `PASS - LAB`, all four breaks. Evidence: `b9ab66452785.json` (PrinterOffline + NetworkPrinterUnreachable, Passed, 14:59), `e80561c2f791.json` (SpoolerService, Passed, 14:59), `1265da746055.json` (PrintFoundationFeature, Passed after 2 reboots, 15:02), all under `C:\Temp\FixReport\Invoke-AutoRemediatePrinter\`.

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

**Status:** `NEEDS TEST - PRODUCT VM`. Fixed 2026-10-29 (v1.0.1.0), parse-checked, not yet run against Falcon.

**Review notes.** Fixed: the service array was the Trend Micro list, so the script never referenced a CrowdStrike service. It now targets `CSFalconService`, re-reads the service after the start attempt, prints a tamper-protection hint when it stays stopped, and exits `1` in that case instead of always `0`. On a device without Falcon it prints "No CrowdStrike Falcon services are installed" and exits `0`.

### 4.2 `Invoke-DefenderDynamicPerformance.ps1`

| Field | Value |
|---|---|
| Path / version | `AntiVirusResolutionScripts\MicrosoftDefender\Invoke-DefenderDynamicPerformance.ps1`, no version variable |
| Inventory | `3) Complete - Needs Testing`, impact Low |
| Inputs | none (reads `$env:SystemDrive`, `HKLM:\SOFTWARE\AIRWATCH\Extensions\HealthDetection`) |
| Prerequisites | Microsoft Defender AV, Storage module (`Get-PhysicalDisk`) |
| Automated coverage | none |

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

**Status:** `NEEDS TEST`. Rewritten 2026-10-29 (v1.1.0), parse-checked, not yet run elevated. Expected output now: `Computed performance score N ... and cached it.`, `Applying Defender CPU profile 'Mid' (was '')`, a final `ScanAvgCPULoadFactor=50 EnableLowCpuPriority=False ...` line, exit `0`; second run `Using cached performance score N` and `... is already applied. No changes made.` Registry values are `PerformanceScore` and `CurrentProfile`.

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

**Status:** `TESTED - MANUAL`.

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

**Status:** `TESTED - MANUAL`.

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

**Status:** `TESTED - MANUAL`.

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

**Status:** `TESTED - MANUAL`.

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

**Status:** `NEEDS TEST`. Fixed 2026-10-29 (v1.0.3.2), parse-checked, not yet run.

**Review notes.** Fixed: `$healthDetectionPath` is now assigned before the branch, so the task-present path reads `FullScanInProgress` correctly; the event and `Get-MpComputerStatus` paths both normalise to `[DateTime]` before comparing, so a finished scan is no longer reported as running; `Start-MpScan` uses `-ErrorAction Stop` so the catch and exit `1` are reachable. Remaining: `-MaxEvents 100` can miss the start event on busy logs.

### 4.8 `Start-DefenderThreatReport_1.4.8.4.ps1`

| Field | Value |
|---|---|
| Path / version | `AntiVirusResolutionScripts\MicrosoftDefender\ThreatReporting\Start-DefenderThreatReport_1.4.8.4.ps1`, v1.4.8.4 |
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

**Status:** `TESTED - MANUAL`.

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

**Status:** `NEEDS TEST - PRODUCT VM`.

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

**Status:** `NEEDS TEST - PRODUCT VM`.

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

**Status:** `NEEDS TEST - PRODUCT VM`.

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

**Status:** `NEEDS TEST - PRODUCT VM`.

**Review notes.** Header promises a real-time protection check that does not exist in the body. Always exits `0`. Identical body to 4.1.

---

## 5. Windows remediation scripts (no harness)

Seventeen scripts under `WindowsAutoRemediation\` outside the six harness-covered ones. Nine are step-engine scripts, the rest are plain or `ShouldProcess` scripts. None has a break test; every test below is manual. All run as SYSTEM under UEM unless noted. Several share one defect worth knowing up front: when a step is `Failed` and then successfully remediated, the script still exits `1` on that run, so the first UEM run of a broken device reports Failed and the second reports Completed. That is by design in these scripts but should be read as "remediated" not "broken".

Also present in `ProcessManagement\`: `Restart-WinProcessSoft.ps1` is a 0-byte placeholder. It is not counted and must not be published.

### 5.1 `Invoke-AutoRemediateWiFiSignalIssues.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\Invoke-AutoRemediateWiFiSignalIssues.ps1`, v1.0.1 |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
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

**Status:** `NEEDS TEST - PRODUCT VM`.

**Review notes.** Bounces the adapter on a mere warning, including when Wi-Fi is simply not connected. Disables USB selective suspend system-wide even for non-USB adapters. Exit `1` after a successful fix. Step 3 recommends `Invoke-DriverUpdates.ps1` but does not call it.

### 5.2 `Invoke-DriverUpdates.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\DriverUpdates\Invoke-DriverUpdates.ps1` |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | `$env:Mode` (`Detect` default, `Install`), `$env:DriverFilter` (regex on title), `$env:AllowReboot` (`True`/`False`), `$env:MaxUpdates` (default 10) |
| Prerequisites | `wuauserv`, `Microsoft.Update.Session` COM, reachable Windows Update or WSUS, driver updates not excluded by policy |
| Automated coverage | none |

**Purpose.** Searches Windows Update for driver updates. Detect mode lists them and exits `1` when any exist. Install mode downloads and installs, forces a reboot flag for high-risk classes (audio, GPU, USB controllers, storage, chipset) and exits `3010` when a reboot is needed and `AllowReboot` is true.

**Test steps**

1. Precheck what WU offers: `(New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().Search("IsInstalled=0 and Type='Driver'").Updates | Select Title`. A fresh VM usually has at least one optional driver.
2. Detect: `$env:Mode='Detect'` then run. Expect `[RebootReq]`/`[NoReboot]` lines, `N driver update(s) available. Run with -Mode Install to apply.`, exit `1`. With `$env:DriverFilter='ZZZNOMATCH'` expect `No driver updates to act on.`, exit `0`.
3. Install (snapshot first): `$env:Mode='Install'; $env:AllowReboot='True'` then run. Expect `Install results:` with `[OK]` lines, `Summary: N installed, 0 failed, RebootRequired: True|False`, exit `3010` or `0`.
4. Reboot-flag path without a real install: create `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired` before an Install run and expect `3010`. Remove the key afterwards.
5. Verify in Device Manager or `Get-PnpDeviceProperty` that the driver version changed; rerun Detect and expect exit `0`.

**Status:** `NEEDS TEST`.

**Review notes.** Detect exit `1` is indistinguishable from an error exit `1`; UEM will show Failed whenever updates exist. Malformed `$env:AllowReboot` or `$env:MaxUpdates` throws in the param block and the script falls through to a trailing `Exit 0`. WU search and download can exceed the 120-second timeout noted in the header.

### 5.3 `Invoke-RemediateMemoryCompression.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\Memory\Invoke-RemediateMemoryCompression.ps1` |
| Inventory | `3) Complete - Needs Testing`, impact Low |
| Inputs | none |
| Prerequisites | `Get-MMAgent`/`Enable-MMAgent` (Windows 10 or later) |
| Automated coverage | none |

**Purpose.** Re-enables memory compression when `Get-MMAgent` reports it disabled and records the result under `HKLM:\Software\AirWatch\Extension\DEXRecords\MemoryErrors\MemoryCompression`.

**Test steps**

1. Baseline: `(Get-MMAgent).MemoryCompression`.
2. Break: `Disable-MMAgent -MemoryCompression`. Confirm `False`.
3. Run the script.
4. Expect `[Remediated] Memory compression is disabled. Enabling now.`, `[Registry] Results written to ...`, exit `0`. Second run: `[Passed] Memory compression is enabled.`
5. Verify `(Get-MMAgent).MemoryCompression` is `True`; registry `Status = Remediated`.
6. Restore: none; or `Disable-MMAgent -MemoryCompression` if the image disables it on purpose.

**Status:** `NEEDS TEST`.

**Review notes.** Still attempts the fix when detection throws. Registry path uses `Extension` (singular) while the WindowsLogon scripts use `Extensions`. Some SSD or VDI baselines disable compression deliberately.

### 5.4 `Invoke-RemediatePageFile.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\Memory\Invoke-RemediatePageFile.ps1` |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | `$env:PageFileUsageFailPercent` (default 80) |
| Prerequisites | `Win32_ComputerSystem`, `Win32_PageFileUsage` |
| Automated coverage | none |

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

**Status:** `NEEDS TEST`.

**Review notes.** Both advisory Warning states exit `1`, which UEM reports as Failed with nothing to fix. A malformed threshold variable throws in the param block and the script falls through to `Exit 0`.

### 5.5 `Invoke-RemediateSysMain.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\Memory\Invoke-RemediateSysMain.ps1` |
| Inventory | `3) Complete - Needs Testing`, impact Low |
| Inputs | none |
| Prerequisites | `SysMain` service |
| Automated coverage | none |

**Purpose.** Sets SysMain (Superfetch) to Automatic and starts it. Records to `...\DEXRecords\MemoryErrors\SysMain`.

**Test steps**

1. Break: `Stop-Service SysMain -Force; Set-Service SysMain -StartupType Disabled`.
2. Run. Expect `[Remediated] SysMain is disabled. Setting to Automatic and starting.`, exit `0`.
3. Verify `Get-Service SysMain | Select Status,StartType` is Running / Automatic; rerun prints `[Passed] SysMain is running (StartType: Automatic)`.
4. Restore: none.

**Status:** `NEEDS TEST`.

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

**Status:** `TESTED - MANUAL` for the User-context path (2026-10-29, v1.0.2: planted `SpotifyLabTest` Run value and `DiscordLabTest.lnk` removed, exit `1` then `0`). `NEEDS TEST` for the SYSTEM path: run elevated via `PsExec64 -s` with a console user logged on and confirm the banner reads `Target user: <console user>` and the entries in that user's hive are removed.

**Review notes.** Fixed: under SYSTEM the script now resolves the console user and targets `HKEY_USERS\<SID>\...\Run` and that user's Startup folder; with no console user it reports and exits `0`. Header context updated. Remaining: substring matching gives false positives (`itch` matches Twitch, `Steam` matches SteamVR); removes org-deployed per-user Dropbox or Discord; no WhatIf; exit `1` on the run that fixes things.

### 5.7 `Enable-HardwareAcceleratedGPUScheduling.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\Performance\Enable-HardwareAcceleratedGPUScheduling.ps1` |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | none |
| Prerequisites | Windows 10 2004 (build 19041) or later; a real GPU with a WDDM 2.7 driver for the setting to matter |
| Automated coverage | none |

**Purpose.** Four steps: OS build check, GPU driver WDDM version (report), HAGS registry state (sets `HwSchMode = 2`), pending reboot flag (report).

**Test steps**

1. Break: `Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -Value 1 -Type DWord` (or remove the value).
2. Run. Expect `[Failed ] HAGS Registry State: HAGS is disabled (HwSchMode = 1). Will enable. -> Remediation ran`, `[Warning] Pending Reboot Flag: Reboot pending for: HAGS enabled ...`, exit `1` this run. On the VM also expect `[Warning] GPU Driver WDDM Version` for the VMware SVGA driver.
3. Verify `(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers').HwSchMode` is `2`. On real hardware reboot and check Settings > System > Display > Graphics > Default settings.
4. Restore: set the value back to the baseline.

**Status:** `NEEDS TEST`.

**Review notes.** Step 4 treats `HwSchMode = 2` as "reboot pending" forever, so the script warns on every run after enabling. Writes the value even when no capable GPU was found. Uses `Get-WmiObject` (PS 5.1 only).

### 5.8 `Restart-WindowsUpdateServices.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\ProcessManagement\Restart-WindowsUpdateServices.ps1`, v1.6.1.0 |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | none (`$ForceRestart = $true` hard-coded) |
| Prerequisites | `wuauserv`, `bits`, `cryptsvc`, `msiserver` |
| Automated coverage | none |

**Purpose.** Stops and starts all four services unconditionally, then exits `1` if any is not running.

**Test steps**

1. Break: `Stop-Service wuauserv,bits -Force`.
2. Run. Expect `[nnnn] wuauserv stopped.` / `started.` for each, `SUCCESS. 4 of 4 service(s) running.`, exit `0`.
3. Failure path: `Set-Service wuauserv -StartupType Disabled; Stop-Service wuauserv`. Run, expect `FAILED. Only 3 of 4 service(s) are running after remediation.`, exit `1`. Restore with `Set-Service wuauserv -StartupType Manual`.
4. Verify `Get-Service wuauserv,bits,cryptsvc,msiserver | Select Name,Status` all Running. Note `msiserver` is left running where it is normally stopped.

**Status:** `NEEDS TEST`.

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

**Status:** `TESTED - MANUAL` (2026-10-29, v1.1.0, all four steps above passed on the lab VM, non-elevated). Remove the `uem-tests.json` skip once variables are set on the UEM item.

**Review notes.** Fixed: `$ProcessName` was never assigned, so every match ended in exit `1` without stopping anything. Processes are now stopped by Id, relaunch uses the recorded executable path, and `StartService` is parsed as a boolean string (`'false'` was previously true). Still a force-kill with no save prompt by design.

### 5.10 `Restart-WinProcessGraceful.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\ProcessManagement\Restart-WinProcessGraceful.ps1` |
| Inventory | `3) Complete - Needs Testing`, impact High |
| Inputs | **REQUIRED UEM variable** `FileDescription` (exit 1 without it); `GracefulTimeoutSec` (15), `Restart`, `ForceOnlyIfUnresponsive` (true), `UnresponsiveSampleCount` (3), `UserActionRetryCount` (1), `UserActionRetryDelaySec` (300), `SkipIfUnsavedWork`, `Mode` (`Detached` default, `Inline`) |
| Prerequisites | Task Scheduler, an interactive user for hang detection, AV exclusion on `C:\ProgramData\AirWatch\Extensions\ProcessGraceful` |
| Automated coverage | `uem-tests.json` skip (needs variables) |

**Purpose.** Launcher that writes a watchdog script and dispatches it as a scheduled task in the user's session. The watchdog asks matching processes to close, force-kills only processes confirmed hung, retries after a delay, optionally relaunches, and writes `state\result.json` plus a DEXRecords key.

**Test steps** (launch from `pwsh.exe` so the launcher's own description does not match)

1. Graceful close: `Start-Process notepad; $env:FileDescription='Notepad'; $env:Mode='Inline'; $env:GracefulTimeoutSec='10'; $env:UserActionRetryCount='0'`. Run. Expect `Watchdog finished inline with exit code 0.`, Notepad gone, `result.json` with `Outcome = ClosedGracefully`.
2. User action required: type text in Notepad first (title becomes `*Untitled`), same run. Expect `UserActionRequired`, Notepad still open. Add `$env:SkipIfUnsavedWork='True'` and expect `UnsavedWorkSuspected`.
3. Hung process (as the logged-on admin, not SYSTEM): start a PowerShell window that shows a form and sleeps, set `$env:FileDescription='Windows PowerShell'`, run. Expect `ForceKilled` after the unresponsive samples.
4. Detached path: clear `$env:Mode`, run via `PsExec64 -s` or UEM. Expect `Watchdog dispatched as scheduled task 'WS1_ProcessGracefulWatchdog' (User context).`, exit `0`, then read `C:\ProgramData\AirWatch\Extensions\ProcessGraceful\state\result.json` for the real outcome.
5. Verify `Get-ScheduledTask WS1_ProcessGracefulWatchdog` returns nothing after completion; `Get-ItemProperty 'HKLM:\Software\AirWatch\Extension\DEXRecords\ProcessGraceful'` shows `Status = Completed` and counts.
6. Restore: delete the ProcessGraceful folder and registry key.

**Status:** `NEEDS TEST`.

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

**Status:** `NEEDS TEST`. Fixed 2026-10-29 (v0.9.1), parse-checked. Still a prototype superseded by `Restart-WinProcessGraceful.ps1`; not a publication candidate.

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

**Status:** `NEEDS TEST`. Ready for the UEM test group as configured in the manifest.

**Review notes.** Substring matching can hit many services (`Update` matches `wuauserv`, `UsoSvc`, `WaaSMedicSvc`, Edge and Google update services) and restarts all of them. `Stop-Service -Force` stops dependents without restarting them. Stop, 1-second pause and start of a slow service can exceed the 15-second timeout in the header.

### 5.13 `Invoke-AutoRemediateAppXBloat.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\WindowsLogon\Invoke-AutoRemediateAppXBloat.ps1`, v1.0.0 (header says 1.0.1) |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | `$env:DenyListExtra` (comma-separated patterns), `$env:RemoveForExistingUsers` (`true|1|yes|y`), `$env:WhatIf` |
| Prerequisites | DISM AppX cmdlets; SYSTEM |
| Automated coverage | none |

**Purpose.** Two steps: deprovision a curated deny list of consumer inbox AppX packages for future users; optionally remove them for existing users. A safelist (Calculator, Store, Photos, Terminal, Notepad, shell components, runtime frameworks) cannot be overridden.

**Test steps** (snapshot first; a stock Windows 11 image is already in the "broken" state)

1. Confirm candidates: `Get-AppxProvisionedPackage -Online | Where-Object DisplayName -in 'Microsoft.BingWeather','Microsoft.MicrosoftSolitaireCollection','Clipchamp.Clipchamp'`.
2. Dry run: `$env:WhatIf='true'`, run. Expect the `[Failed ]` detection lines, `WhatIf run -- registry cache left untouched.` in `C:\Windows\Temp\UEM_AutoRemediateAppXBloat.log`, no registry change, exit `0`.
3. Live: clear `$env:WhatIf`, run. Expect `[Failed ] Deprovision Non-Essential AppX (Future Users): N provisioned package(s) match the deny list: ... -> Removal applied`, `Remediations applied: 1`, exit `0`.
4. Existing users: `$env:RemoveForExistingUsers='true'` with `Get-AppxPackage -AllUsers Microsoft.BingWeather` still present. Expect step 2 `-> Removal applied`.
5. Verify the packages are gone from both cmdlets; `HKLM:\Software\AirWatch\Extensions\AppXBloat\Remediation` shows `RemediationsRun = 1`, `RemediationErrors = 0`. Rerun prints `No matching packages are provisioned for new users`.
6. Re-arm for another run: revert the snapshot or point `$env:DenyListExtra='Microsoft.WindowsAlarms'` at a still-provisioned package.

**Status:** `NEEDS TEST`.

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

**Status:** `NEEDS TEST - PRODUCT VM` (simulation above is acceptable for logic validation).

**Review notes.** Tamper Protection or Intune-managed exclusions (`DisableLocalAdminMerge`) make `Add-MpPreference` fail or be ignored, giving a perpetual Failed. Under SYSTEM `$env:TEMP` equals `C:\Windows\Temp`, so two path entries duplicate. Version constant and header disagree.

### 5.15 `Invoke-AutoRemediateLogonTaskContention.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\WindowsLogon\Invoke-AutoRemediateLogonTaskContention.ps1`, v1.0.0 |
| Inventory | `3) Complete - Needs Testing`, impact Low |
| Inputs | `$env:MinDelaySeconds` (60), `$env:StaggerSeconds` (30), `$env:TaskVolumeWarnCount` (8), `$env:WhatIf` |
| Prerequisites | ScheduledTasks module |
| Automated coverage | none |

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

**Status:** `NEEDS TEST`.

**Review notes.** The ISO 8601 parser handles only `PT#H#M#S`; a delay stored as `P0DT0H1M0S` or `P1D` parses as 0 and can be lowered. `Set-ScheduledTask` fails for tasks with a stored password. Delaying vendor agents is user-visible.

### 5.16 `Invoke-AutoRemediateProfileBloat.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsAutoRemediation\WindowsLogon\Invoke-AutoRemediateProfileBloat.ps1`, v1.0.0 |
| Inventory | `3) Complete - Needs Testing`, impact Low |
| Inputs | `$env:MinFileAgeDays` (7), `$env:MinSizeThresholdMB` (50), `$env:RoamingWarnMB` (500), `$env:HiveWarnMB` (100), `$env:WhatIf` |
| Prerequisites | `Win32_UserProfile`; SYSTEM to reach every profile |
| Automated coverage | none |

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

**Status:** `NEEDS TEST`.

**Review notes.** Step 7 deletes `CustomDestinations` and `AutomaticDestinations`, which hold user-pinned Jump List items (not pure cache). Deleting `WER\ReportQueue` discards un-uploaded crash reports. Large profiles can exceed the 300-second header timeout because each step walks its tree twice.

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
| Automated coverage | none |

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

**Status:** `NEEDS TEST`.

**Review notes.** No step returns `Failed` by design, so exit `1` only follows a detection exception. Step 6 reads `HKCU:` which under SYSTEM is the SYSTEM hive, unlike the `HKU\<SID>` approach used elsewhere. Recursive cache sizing can be slow on very large caches.

### 6.2 `Invoke-AutoRemediateOneDrive.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\OneDrive\Invoke-AutoRemediateOneDrive.ps1`, v1.0.1 |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | `$env:AllowDestructiveActions` (reserved, unused) |
| Prerequisites | OneDrive.exe present (else `[Skipped]`); resolvable user SID; `FileSyncHelper` service |
| Automated coverage | none |

**Purpose.** Five steps: Auto-start / Process Health (restores the `Run` key and starts OneDrive in the user session via a temporary scheduled task), Account Sign-in State (report), Sync Error Detection (report), Files On-Demand Service (starts `FileSyncHelper` unless Disabled), Known Folder Move Status (report). Writes `...\DEXRecords\OneDriveErrors`.

**Test steps** (lab VM, user logged on, run as SYSTEM)

1. Break as the user: `Stop-Process -Name OneDrive -Force; Remove-ItemProperty HKCU:\Software\Microsoft\Windows\CurrentVersion\Run -Name OneDrive`. Elevated: `Stop-Service FileSyncHelper`. Optional sync-error event: `New-EventLog -LogName Application -Source OneDriveLabTest; Write-EventLog -LogName Application -Source OneDriveLabTest -EntryType Error -EventId 100 -Message 'OneDrive sync test error'`.
2. Run. Expect `[Failed ] OneDrive Auto-start / Process Health: OneDrive is not running and the auto-start Run key is missing. ... -> Remediation ran`, `[Warning] Sync Error Detection ...`, `[Warning] Files On-Demand Service: FileSyncHelper service is not running ... -> Remediation ran`, exit `1` this run (Failed counted before remediation), `0` on rerun.
3. Verify `Get-Process OneDrive -IncludeUserName` shows the process in the user's session, the `Run` value is back, `(Get-Service FileSyncHelper).Status` is Running, and `Get-ScheduledTask DEX-TempStartOneDrive` returns nothing.
4. Disabled service path: `Set-Service FileSyncHelper -StartupType Disabled`, rerun, expect `[Info] FileSyncHelper is Disabled -- skipping restart...`. Restore to Manual.
5. Restore: `Remove-EventLog -Source OneDriveLabTest`.

**Status:** `NEEDS TEST`.

**Review notes.** Starting OneDrive is user-visible. Step 5 has two identical `if` branches; the second is dead code. Step 3 scans every Level-2 Application event in 24 hours with a wildcard on Message and can be slow.

### 6.3 `Invoke-AutoRemediateOutlook.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\Outlook\Invoke-AutoRemediateOutlook.ps1`, v1.0.1 |
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

**Status:** `NEEDS TEST - PRODUCT VM`.

**Review notes.** With exactly one add-in the count in the message prints blank (single-object `.Count` in PS 5.1). Step 4 messages promise an update attempt that never happens (no resolution) and still yield exit `1`. Step 3 queries seven days of Application events without a level filter in the query hash. OST rename forces a full mailbox resync.

### 6.4 `Invoke-AutoRemediateTeams.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\Teams\Invoke-AutoRemediateTeams.ps1`, v1.0.1 |
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

**Status:** `NEEDS TEST - PRODUCT VM` (the fake-install path above validates the Classic steps on the lab VM).

**Review notes.** `Get-AppxPackage MSTeams` as SYSTEM returns only SYSTEM's packages, so New Teams is unlikely to be detected without `-AllUsers`, and `Add-AppxPackage -Register` as SYSTEM registers for SYSTEM. Step 6 prints `-> Remediation ran` even when it only printed the skip message, and returns Failed regardless of the flag. Step 4's `error|failed|exception` regex is loose.

### 6.5 `Invoke-AutoRemediateZoom.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\Zoom\Invoke-AutoRemediateZoom.ps1`, v1.0.1 |
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

**Status:** `NEEDS TEST - PRODUCT VM` (fake-install path validates logic on the lab VM).

**Review notes.** The regex term `401` matches any `401` substring. Step 5 triggers the per-app Allow even in the global-Deny case where the message says only the user can fix it. Step 4 forces a re-login.

### 6.6 `Invoke-AutoRemediateBITSBacklog.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\SCCM\Invoke-AutoRemediateBITSBacklog.ps1` |
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
| Path / version | `ApplicationSpecific\SCCM\Invoke-AutoRemediateCcmCache.ps1` |
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
| Path / version | `ApplicationSpecific\SCCM\Invoke-AutoRemediateOrphanedCcmSetup.ps1` |
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
| Path / version | `ApplicationSpecific\SCCM\Invoke-AutoRemediateSCCMClient.ps1` |
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
| Path / version | `ApplicationSpecific\SCCM\Invoke-AutoRemediateWMIRepository.ps1` |
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
| Path / version | `ApplicationSpecific\SCOM\Invoke-AutoRemediateSCOMAgent.ps1`, v1.0.0 |
| Inventory | `3) Complete - Needs Testing`, impact Medium |
| Inputs | `$env:WhatIf` |
| Prerequisites | SCOM agent (`HealthService`, `HKLM:\SOFTWARE\Microsoft\Microsoft Operations Manager\3.0`) |
| Automated coverage | none |

**Purpose.** Combined fourteen-step sweep with a health score. Reference copy only: at 48,336 characters it exceeds the UEM 32,767-character limit, and the README says not to deploy it. Parts 1 to 3 below are the deployable split.

**Test steps.** Use Parts 1 to 3. A synthetic fixture for the monolith is the same as 6.12.

**Status:** Reference only. Not a publication candidate; mark it so in the inventory.

### 6.12 `Invoke-AutoRemediateSCOMAgentPart1.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\SCOM\Invoke-AutoRemediateSCOMAgentPart1.ps1`, `$SCRIPT_VERSION` 1.0.0 (header says 1.1.0) |
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

**Status:** `NEEDS TEST - PRODUCT VM` (fixture validates the registry and connectivity logic on the lab VM).

**Review notes.** Version constant and header disagree. Step 1 resolution skips if any process named `setup` is running.

### 6.13 `Invoke-AutoRemediateSCOMAgentPart2.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\SCOM\Invoke-AutoRemediateSCOMAgentPart2.ps1`, v1.0.0 |
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

**Status:** `NEEDS TEST - PRODUCT VM` (Agent Runtime Footprint needs real processes).

**Review notes.** Most expensive part (90-second budget in the README). Writes decimal strings such as `1700.2` that Part 3 cannot parse (see 6.14).

### 6.14 `Invoke-AutoRemediateSCOMAgentPart3.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\SCOM\Invoke-AutoRemediateSCOMAgentPart3.ps1`, v1.0.0 |
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

**Status:** `NEEDS TEST - PRODUCT VM`. Fixed 2026-10-29 (v1.1.1), parse-checked. Re-run the fixture in step 2 and confirm the score drops when `StateFolderMB` is over 1536 and `ConfigAgeHours` over 24.

**Review notes.** Fixed: `Get-Cached` now parses culture-invariant doubles and rounds, so the decimal strings Part 2 writes no longer read back as -1 and the `ConfigurationCacheStale`, `HealthServiceStateOversized` and CPU deductions apply. Remaining: exit code does not reflect Part 1 or 2 failures (by design, documented in the README).

### 6.15 `Invoke-AutoRemediateSCOMClonedIdentity.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\SCOM\Invoke-AutoRemediateSCOMClonedIdentity.ps1` |
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

**Status:** `NEEDS TEST - PRODUCT VM`. Fixed 2026-10-29 (v1.0.1, 32,633 characters), parse-checked. Re-run the fixture via the launcher (not the payload directly) to prove the forwarded `ConfirmHighImpact` reaches the task; expect `Status = RolledBack` on the fixture and `Status = Reset`, exit `0`, on a real agent.

**Review notes.** Fixed: the launcher now forwards whitelisted `ConfirmHighImpact` and `WhatIf` values (`true|false|1|0|yes|no` only, lower-cased) into the task command line, so the payload sees them under UEM; the aggregate no longer counts the action step's designed `Failed` once its remediation ran, so a successful reset reports `Reset` and exit `0`; a WhatIf run reports `Skipped:WhatIf` and a deadline abort `Skipped:TimedOut`. Still the highest blast radius in the repo; wrong tool for non-persistent VDI.

### 6.16 `Invoke-AutoRemediateSCOMHealthServiceCache.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\SCOM\Invoke-AutoRemediateSCOMHealthServiceCache.ps1` |
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

**Status:** `NEEDS TEST - PRODUCT VM`. Fixed 2026-10-29 (v1.0.1, 32,692 characters), parse-checked. Re-run the gate variants via the launcher, confirm a `Skipped:*` run does not write `LastFlushTime`, and that a real flush reports `Completed`, exit `0`.

**Review notes.** Fixed: the cooldown gate reads `LastFlushTime`, written only when a flush happened (`LastRunTime` is still written every run for reporting); same forwarding and aggregate fixes as 6.15, so a successful flush reports `Completed`. The file was 33,580 characters on disk before this change, already over the UEM limit despite `DESIGN.md` saying 32,717; comment text was trimmed to bring it to 32,692. Any future edit must re-check the size.

### 6.17 `Invoke-AutoRemediateSCOMMonitoringHost.ps1`

| Field | Value |
|---|---|
| Path / version | `ApplicationSpecific\SCOM\Invoke-AutoRemediateSCOMMonitoringHost.ps1` |
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

**Status:** `NEEDS TEST - PRODUCT VM`.

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

**Status:** `TESTED - MANUAL`.

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

**Status:** `TESTED - MANUAL`.

**Review notes.** The default 900-second wait needs a UEM timeout near 20 minutes; without the wait use 30 seconds. Hard-coded `C:`. Header script name differs from the file name. A pending Windows Update install can legitimately make a waiting run hit the ceiling.

### 7.3 `Start-UserProfileCleanup.ps1`

| Field | Value |
|---|---|
| Path / version | `DiskCleanup\Start-UserProfileCleanup.ps1` |
| Inventory | `3) Complete - Needs Testing`, impact High |
| Inputs | none; hard-coded `$ENROLLMENTUSER = "Administrator"`, `$DAYS_INACTIVE = 30`, `$SIZE_THRESHOLD_MB = 500` |
| Prerequisites | PS 5.1 (`Get-WmiObject`), SYSTEM |
| Automated coverage | `uem-tests.json` skip |

**Purpose.** Deletes whole local profiles that are both inactive beyond the threshold and larger than the size threshold, via `Remove-WmiObject` on `Win32_UserProfile`.

**Test steps** (per `General-Testing-Guide.md` section 2.2; snapshot first)

1. Create a disposable profile: `net user dexprobe 'Pr0be!Pass#2026' /add; runas /user:dexprobe "cmd /c exit"`. Confirm `C:\Users\dexprobe` exists.
2. Safe negative first: edit a scratch copy with `$DAYS_INACTIVE = 3650`. Run. Expect every profile `Examining profile: ...` and no `Deleted profile:` line.
3. Positive: set `$ENROLLMENTUSER` to your own account, `$DAYS_INACTIVE = 0`, `$SIZE_THRESHOLD_MB = 0`. Run as SYSTEM. Expect `Deleted profile: C:\Users\dexprobe`, `Profile cleanup complete.`, exit `0`.
4. Verify `Test-Path C:\Users\dexprobe` false; `Get-CimInstance Win32_UserProfile | Where-Object LocalPath -like '*dexprobe*'` empty; the `ProfileList` SID key gone.
5. Restore: `net user dexprobe /delete`; discard the scratch copy.

**Status:** `MANUAL ONLY`. Never add to the UEM test group or the harness.

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

**Status:** `TESTED - MANUAL`.

**Review notes.** The marker is written even when a log reports `[FAILED]`, so later runs skip and never retry, and `-Force` cannot be reached from UEM.

### 8.3 `Measure-LogonDuration.ps1`

| Field | Value |
|---|---|
| Path / version | `GenericTroubleshooting\WindowsStartup\Measure-LogonDuration.ps1`, collector v1.1.0 |
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

**Status:** `TESTED - MANUAL`.

**Review notes.** `TotalLogonDurationSec` is based on Winlogon event 7001, which fires almost at logon time, so expect 0 to 1 second rather than real time-to-desktop. Registry and task failures only warn.

### 8.4 `Measure-LogonDurationMultiSession.ps1`

| Field | Value |
|---|---|
| Path / version | `GenericTroubleshooting\WindowsStartup\Measure-LogonDurationMultiSession.ps1`, collector v2.0.0 |
| Inventory | NOT IN CSV |
| Inputs | `DeployMode`, `SessionScope` (`LastLogon`, `AllActive`, `AllSince`, `AllUsers`), `AllUsers`, `LookbackHours` (24), `MaxSessions` (50), `TargetUser`, `ExcludeUserPattern`, `AggregateWindowHours` (24), `TimeBudgetSeconds` (240), `RepeatMinutes` (15), `ConfigureLoggingFirst`, `NoExit`; each as parameter or `$env:` |
| Prerequisites | `TerminalServices-LocalSessionManager/Operational` log; elevation |
| Automated coverage | none |

**Purpose.** Multi-session variant for shared hosts. Measures every attributable logon, writes per-user records under `...\LogonDuration\Sessions\<SID>`, the newest to the flat key, and P50/P95 aggregates under `...\LogonDuration\Aggregate`. Can install a recurring SYSTEM task.

**Test steps**

1. Log on two users (console plus RDP). Elevated: `.\Measure-LogonDurationMultiSession.ps1 -AllUsers -NoExit`. Expect `-- Event source resolution ---`, a `-- Measured ---` table with one row per user, `-- Aggregate ---` with P50/P95, and the readback for all three keys.
2. `-SessionScope AllSince` twice: second run prints `No sessions in scope need measuring. Refreshing the aggregate only.`
3. Task: `-DeployMode DeployScheduledTask -ConfigureLoggingFirst $true`. Verify the task shows `AtLogOn (30s delay) + every 15 minute(s)`.
4. Verify `Get-ChildItem HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration\Sessions` has one key per user; aggregate `SessionCount` equals distinct users.
5. Restore: unregister `DEXTools_MeasureLogonDurationMultiSession`, remove the DEXTools folder and the LogonDuration key.

**Status:** `NEEDS TEST`. Needs an inventory row.

**Review notes.** `$script:ExitCode` is never set to anything but 0, so every path exits `0`, including no logons found and write failures. Sensors should map `Ambiguous` to -4.

---

## 9. MDM command scripts

All three end or weaken the console session. They are skipped in `uem-tests.json` and must never be run through the harness or against a VM you are working from.

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

**Status:** `MANUAL ONLY`.

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

**Status:** `MANUAL ONLY`. Header and error handling fixed 2026-10-29 (v1.1.0), parse-checked, behaviour unchanged.

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

**Status:** `MANUAL ONLY` (safe, but it interrupts the operator's session).

**Review notes.** With no console user the `tsdiscon` error is swallowed and exit is still `0`. `$WhatIfPreference` is checked but never settable.

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

**Status:** `NEEDS TEST - PRODUCT VM`.

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

**Status:** `NEEDS TEST` (the no-client path runs on the lab VM; tunnel states need 10.1's setup).

**Review notes.** Flap and last-connect correlation compares NetworkProfile event text to the adapter `InterfaceDescription`, which may never match, leaving `FlapCount24h` at 0 on real tunnels. Verify on the lab tunnel. Any virtual adapter not in the exclusion list (Tailscale, ZeroTier, WARP, OpenVPN TAP) counts as a VPN client.

---

## 11. Reboot scripts

### 11.1 `Invoke_RebootWithUserDefer_1.2.0.7.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsReboot\InteractiveReboot\Invoke_RebootWithUserDefer_1.2.0.7.ps1`, v1.2.0.7 |
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

**Status:** `MANUAL ONLY`. Fixed 2026-10-29; main script and both extracted helpers parse clean under PowerShell 5.1. The deferral flow still needs one end-to-end run on the snapshot (steps 1 to 4) because the inventory's "Tested" predates these fixes.

**Review notes.** Fixed: `if($mandatoryReboot=$true)` (assignment) is now a comparison, so the no-users path reboots only after the deadline; `Write-Log` is defined inside the orchestrator and appends to `RebootPrompt.log` under the AdvancedReboot folder; `$shutdown` is assigned before the protocol handler commands are built, so "Reboot now" and the abort handler are well-formed; the task Description stamp and `Deadline` value are ISO round-trip strings and are parsed invariantly; the leaked `New-ItemProperty` output is suppressed. Remaining, harmless: the toast writes a per-user `Deadline` value that is never read (the reader uses `DeadlineAt`), `Deferrals` is never populated, a verbose line references two undefined path variables, and the file has no version string (the readme says 1.2.0.7).

### 11.2 `Invoke-SimpleReboot.ps1`

| Field | Value |
|---|---|
| Path / version | `WindowsReboot\InteractiveReboot\Invoke-SimpleReboot.ps1` |
| Inventory | `4) Complete - Tested`, impact High |
| Inputs | none; `$CountdownSeconds = 300` |
| Prerequisites | `shutdown.exe`, PS 5.1 (`Get-WmiObject`) |
| Automated coverage | `uem-tests.json` skip |

**Purpose.** With a console user: `shutdown.exe /r /f /t 300` with a message. Without: immediate forced reboot.

**Test steps**

1. Console user logged on, elevated run. Expect `Console user detected: <user>`, `Scheduling reboot in 300 seconds...`, the Windows sign-out banner, exit `0`.
2. Within 300 seconds `shutdown /a`. System log shows 1074 then 1075.
3. No-user branch: disposable snapshot only; reboots immediately.

**Status:** `MANUAL ONLY`.

**Review notes.** Typo `manueagement` in the no-user message. Does not detect an already pending shutdown (error 1190) and still exits `0`.

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

1. Move the six `PASS - LAB` scripts to `4) Complete - Tested` in the inventory (`Invoke-DriverDeviceLabRun.ps1 -UpdateInventory` does this from the latest results).
2. All eleven `FIX FIRST` items were corrected on 2026-10-29 (see each script's review notes). Still open: delete or move the empty `Restart-WinProcessSoft.ps1`; `Restart-WinProcessGracefulEx.ps1` works again but remains a prototype superseded by `Restart-WinProcessGraceful.ps1`; `DESIGN.md` in the SCOM folder lists stale file sizes.
3. Add inventory rows for the five SCCM scripts, `Get-AppVolumesMountProbe.ps1`, `Measure-LogonDurationMultiSession.ps1` and `Restart-WinProcessGracefulEx.ps1` (or exclude them explicitly).
4. Run the `NEEDS TEST` group on the lab VM in this order, cheapest first: 5.3, 5.5, 5.8, 5.12, 8.4, 10.2, 5.7, 5.15, 5.16, 5.13, 5.4, 5.2, 5.10.
5. Stand up one product VM each for Defender-adjacent (CrowdStrike, Trellix, Trend Micro), Microsoft 365 (Outlook, Teams), Zoom, SCCM, SCOM, FSLogix and VPN, and work through the `NEEDS TEST - PRODUCT VM` group.
6. Once a script passes here, add or adjust its `uem-tests.json` entry and run it through the UEM test group per `UEM-API-TESTING-SPEC.md`.

