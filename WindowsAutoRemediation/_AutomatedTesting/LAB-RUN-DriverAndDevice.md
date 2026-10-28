# Lab Run: Driver and Device Remediation Break Tests

**Audience:** whoever is sitting at the disposable test VM with an elevated PowerShell 5.1
window open. Every command below is destructive to that VM only. Take the snapshot first.

## The short version

Everything in sections 0 to 5 is automated by `Invoke-DriverDeviceLabRun.ps1` in this folder.
From an **elevated Windows PowerShell 5.1 window on the VM console**, after the snapshot:

```powershell
Set-Location 'C:\Users\chase\repos\DEXSolutionScripts\WindowsAutoRemediation\_AutomatedTesting'

.\Invoke-DriverDeviceLabRun.ps1 -PlanOnly                     # preview every command, no elevation needed
.\Invoke-DriverDeviceLabRun.ps1 -Force                        # unit tests -> 7 break-test steps -> analysis -> verdicts
.\Invoke-DriverDeviceLabRun.ps1 -Force -IncludeRebootBreaks   # same, then launches the Printer reboot break last
.\Invoke-DriverDeviceLabRun.ps1 -AnalyzeOnly                  # after the VM comes back from that reboot
.\Invoke-DriverDeviceLabRun.ps1 -Force -UpdateInventory       # also flip CSV rows to "4) Complete - Tested" on all-pass
```

It refuses to run without elevation, without the test-host marker, without `-Force`, under
PowerShell 7, or with less than 5 GB free. It aborts if any unit test fails, stops on a `Dirty`
result or a harness that produced no result file, and writes logs plus `LabRunSummary.csv` to
`C:\Temp\DEXLabRuns\LabRun_<timestamp>\`. The manual steps below are the same procedure, kept
for reference and for running a single harness by hand.

**Scripts under test (six):**

| Script | Break test | Breaks exercised on a VMware VM |
|---|---|---|
| `Invoke-AutoRemediateAllDriverIssues.ps1` | `Invoke-AutoRemediateAllDriverIssues_BreakTest.ps1` | `UsbDriverDisabled` (disables the EHCI controller, which has nothing attached; the console mouse and keyboard sit on the xHCI controller and keep working) |
| `Invoke-AutoRemediateDriverIssues.ps1` | `Invoke-AutoRemediateDriverIssues_BreakTest.ps1` | same break, but the script is handed a `-DriverFilter` naming the device |
| `Invoke-AutoRemediateAudioBluetooth.ps1` | `Invoke-AutoRemediateAudioBluetooth_BreakTest.ps1` | `AudioServicesStopped`, `AudioDriverDisabled` (VMware HD Audio is present), `VolumeMuted`, `MicrophoneAccessDenied`, `BluetoothServiceStopped` (bthserv exists even without a radio) |
| `Invoke-AutoRemediateNetworkStack.ps1` | `Invoke-AutoRemediateNetworkStack_BreakTest.ps1` | `DhcpLeaseLoss` (Ethernet is DHCP; brief connectivity gap), `FirewallDisabled` |
| `Invoke-AutoRemediatePrinter.ps1` | `Invoke-AutoRemediatePrinter_BreakTest.ps1` | `SpoolerService`, `PrinterOffline` (Microsoft Print to PDF), `NetworkPrinterUnreachable`; `PrintFoundationFeature` needs a reboot and is opt-in |
| `Invoke-AutoRemediateWindowsUpdates.ps1` | `Invoke-AutoRemediateWindowsUpdates_BreakTest.ps1` | `WuauservStopped`, `BitsDisabled`, `CryptSvcStopped`, `DataStoreBloated` (sparse file, no real disk cost) |

`DriverPackageDeleted` is **not applicable on this VM**: the only `oemN.inf` packages are
the VMware mouse, NIC and display drivers, all of which the break test refuses to touch.
Do not pass `-IncludeDriverPackageBreak` here; it will throw a not-applicable error.

---

## 0. Before the snapshot

1. Free disk space. The run itself needs very little, but Windows Update remediation and
   `pnputil /scan-devices` both behave badly with a full system drive. 10 GB free is comfortable.
2. Confirm the test-host marker exists (it was created on 2026-10-28):
   ```powershell
   Get-Content 'C:\Temp\FixReport\.dex-test-machine'   # prints the computer name
   ```
3. Run the **non-destructive unit tests** first. They need no elevation and take under a
   minute. A failure here is a logic or scoping bug; fix it before breaking the VM.
   ```powershell
   & 'C:\Users\chase\repos\DEXSolutionScripts\WindowsAutoRemediation\_AutomatedTesting\Unit\Invoke-DriverUnitTests.ps1'
   ```
   Expected: `Failed: 0`.
4. **Take the snapshot now.**

## 1. Open the right kind of session

Run from the **VM console**, not RDP. `DhcpLeaseLoss` releases and renews the Ethernet
lease, which would drop an RDP session mid-test. The console mouse and keyboard are USB
devices on the xHCI controller and survive the `UsbDriverDisabled` break, which targets
the EHCI controller.

Open **Windows PowerShell 5.1 as Administrator** (not PowerShell 7). Then:

```powershell
Set-Location 'C:\Users\chase\repos\DEXSolutionScripts'
```

## 2. Run the full sweep (restore after every test)

Use `-Environment Physical` even though a snapshot exists. Physical restores each break
after its test, so test N+1 starts from a clean machine instead of inheriting test N's
damage. The snapshot is the safety net for a `Dirty` result, not the primary cleanup.

```powershell
.\AutomatedTesting\Invoke-AllBreakTests.ps1 -RemediationTest -Environment Physical -Force
```

This discovers all six break tests, runs each in its own process (two random breaks per
test), then prints the analysis. Budget 10 to 15 minutes. The two driver tests default
to `-RemediationAllowedActions Scan,Restart,Rollback,Reinstall` because a disabled device
cannot be re-enabled by anything short of Reinstall.

## 3. Run the breaks the sweep does not cover

```powershell
# Every break in each driver harness (there is only one applicable here, so this is
# mainly a determinism check: -BreakName pins the selection).
.\WindowsAutoRemediation\_AutomatedTesting\Invoke-AutoRemediateAllDriverIssues_BreakTest.ps1 -BreakName UsbDriverDisabled -RemediationTest -Force
.\WindowsAutoRemediation\_AutomatedTesting\Invoke-AutoRemediateDriverIssues_BreakTest.ps1    -BreakName UsbDriverDisabled -RemediationTest -Force

# Escalation-boundary probe: with the script's OWN defaults (no Reinstall) a disabled
# device is EXPECTED to stay broken. Overall should read Failed, not FalsePass.
.\WindowsAutoRemediation\_AutomatedTesting\Invoke-AutoRemediateAllDriverIssues_BreakTest.ps1 -BreakName UsbDriverDisabled -RemediationTest -RemediationAllowedActions Scan,Restart,Rollback -Force

# Audio / Bluetooth: run every break once (5 in the catalog, sweep picks 2).
.\WindowsAutoRemediation\_AutomatedTesting\Invoke-AutoRemediateAudioBluetooth_BreakTest.ps1 -BreakCount 5 -RemediationTest -Force

# Windows Update: all 4.
.\WindowsAutoRemediation\_AutomatedTesting\Invoke-AutoRemediateWindowsUpdates_BreakTest.ps1 -BreakCount 4 -RemediationTest -Force

# Printer: the 3 non-reboot breaks together, then the reboot one on its own LAST.
.\WindowsAutoRemediation\_AutomatedTesting\Invoke-AutoRemediatePrinter_BreakTest.ps1 -BreakCount 3 -RemediationTest -Force
.\WindowsAutoRemediation\_AutomatedTesting\Invoke-AutoRemediatePrinter_BreakTest.ps1 -BreakName PrintFoundationFeature -IncludeRebootBreaks -RemediationTest -Force
#   ^ reboots the VM twice and resumes itself via a scheduled task. Wait for it to
#     finish, then re-run the analysis in step 4.
```

## 4. Read the results

```powershell
.\AutomatedTesting\Invoke-FixReportAnalysis.ps1
```

| Overall | What to do |
|---|---|
| `Passed` | Done. Flip the script's inventory row to `4) Complete - Tested`. |
| `Failed` on the boundary probe only | Expected. That run proves Reinstall is required. |
| `FalsePass` | Script exited 0 while the device was still broken. Stop and investigate; this is the defect the harness exists to catch. |
| `BreakFailed` | The break never landed. Usually a hardware applicability problem, not a script bug. |
| `Dirty` | Restore failed. Revert the snapshot. |

Keep `C:\Temp\FixReport\Summary.csv` and the per-run JSON files. They are the evidence
for the status change in `SCRIPT-INVENTORY-CSV.csv`.

## 5. Afterwards

Revert the snapshot regardless of outcome. `Physical` mode restores each break, but
Windows Update and PnP state are not guaranteed to be byte-identical afterwards, and the
next lab run should start from the same baseline as this one.

---

## What changed on 2026-10-28 to make this runnable

- `Invoke-AutoRemediateAllDriverIssues.ps1` built its per-class scriptblocks with
  `GetNewClosure()`. A closure runs inside a new dynamic module that cannot see functions
  defined in the enclosing function, so every class step threw
  `Test-DriverMatch is not recognized` when run as a file (UEM, or this harness).
  Replaced with parameter passing.
- Both driver scripts ignored arguments on their command line because the `param` block
  lives inside the function (a UEM constraint). The break tests pass `-AllowedActions`
  and `-DriverFilter` that way, so the driver break tests could never have passed. The
  entry points now forward `@args`.
- 22 scripts used `($results | Where-Object ...).Count`, which is `$null` in PowerShell
  5.1 when exactly one object matches. A single failed step printed a blank count and
  exited 0. Wrapped in `@()`.
- Added the non-destructive unit-test layer under `_AutomatedTesting\Unit`.
- The first real lab run (13:26 on 2026-10-28) died inside the harness before applying any
  break: `Get-DexRandomSubset` in `DEXTestFramework.psm1` returned a one-element array, which
  PowerShell unwraps to the bare hashtable, so `(...)[0]` yielded `$null` and `& $null` threw.
  Every break with a single `Methods` entry, in all six harnesses, hit this. Fixed with a
  `,@()` return. `Unit\Invoke-DriverHarnessDryRun.ps1` now runs both driver harnesses end to
  end against stubbed hardware and the orchestrator refuses to break the VM if it fails.
- The orchestrator's own first-run bugs are fixed too: `@($list)` over a generic List throws
  "Argument types do not match" in 5.1 (now `.ToArray()`), and `Tee-Object` wrote UTF-16 logs
  (now UTF-8).
- The 14:14 and 14:15 runs each passed their first real break test
  (`Invoke-AutoRemediateAllDriverIssues` reinstalled a genuinely disabled USB host controller)
  but the orchestrator reported NO RESULT and stopped: it looked for the harness's
  `[Result] <path>` line, which the harnesses pipe to `Out-Null`. It now locates the result
  JSON by the TestId in the harness's Context line, with a newest-file fallback.
