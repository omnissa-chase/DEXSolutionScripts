# Break/Fix Test Harness

Automated tests that deliberately break a component, run the matching
`Invoke-AutoRemediate*.ps1` script, and verify it actually fixed what it claims to fix.
The single highest-value thing this catches is a **false pass** — a remediation script
that exits 0 and reports success while the component is still broken.

**This harness is destructive by design.** Only run it against a disposable VM or a
machine explicitly marked as a test host. See [Safety interlock](#safety-interlock).

## Layout

```
_AutomatedTesting/                          <- this folder: shared framework + orchestrators
    DEXTestFramework.psm1                    <- shared plumbing every break test imports
    Invoke-AllBreakTests.ps1                 <- discovers and runs every *_BreakTest.ps1
    Invoke-FixReportAnalysis.ps1             <- aggregates C:\Temp\FixReport\*.json into a summary

<Domain>/_AutomatedTesting/                  <- one per script domain, next to the script under test
    Invoke-AutoRemediate<X>_BreakTest.ps1
```

Break tests live next to the script they target (e.g.
`WindowsAutoRemediation\_AutomatedTesting\Invoke-AutoRemediatePrinter_BreakTest.ps1` tests
`WindowsAutoRemediation\Invoke-AutoRemediatePrinter.ps1`), not in this shared folder.
`Invoke-AllBreakTests.ps1` finds them by searching the whole repo for
`*_BreakTest.ps1` files sitting in any folder named `_AutomatedTesting`.

Current catalog:

| Script under test | Break test | Scope |
|---|---|---|
| `Invoke-AutoRemediatePrinter.ps1` | `Invoke-AutoRemediatePrinter_BreakTest.ps1` | 9 steps; 4 report-only steps excluded from ExpectFixed; 1 reboot-requiring break gated behind `-IncludeRebootBreaks` |
| `Invoke-AutoRemediateNetworkStack.ps1` | `Invoke-AutoRemediateNetworkStack_BreakTest.ps1` | 2 of 7 steps (`DhcpLeaseLoss`, `FirewallDisabled`); adapter-disable/Winsock-reset steps deferred — they can sever the session running the test |

## Safety interlock

Every break test calls `Assert-DexTestHost`, which refuses to run unless **all** of:

1. The session is elevated (Administrator).
2. A marker file exists at `C:\Temp\FixReport\.dex-test-machine`, created once per test host:
   ```powershell
   New-Item -ItemType Directory -Path 'C:\Temp\FixReport' -Force | Out-Null
   Set-Content -Path 'C:\Temp\FixReport\.dex-test-machine' -Value $env:COMPUTERNAME
   ```
3. `-Force` is passed, acknowledging the run is destructive.
4. The machine's domain (if any) does not match an entry in `-ProductionDomainDenyList`.

## Running one break test

```powershell
# Break 2 random components, report only (no remediation run):
.\WindowsAutoRemediation\_AutomatedTesting\Invoke-AutoRemediatePrinter_BreakTest.ps1 -Force

# Break, remediate, and validate the fix:
.\WindowsAutoRemediation\_AutomatedTesting\Invoke-AutoRemediatePrinter_BreakTest.ps1 -RemediationTest -Force

# Force a specific break instead of a random selection:
.\WindowsAutoRemediation\_AutomatedTesting\Invoke-AutoRemediateNetworkStack_BreakTest.ps1 -BreakName FirewallDisabled -RemediationTest -Force

# Replay an earlier run's random selection exactly:
.\WindowsAutoRemediation\_AutomatedTesting\Invoke-AutoRemediatePrinter_BreakTest.ps1 -Seed 12345 -RemediationTest -Force

# Undo an in-flight run's breaks without remediating:
.\WindowsAutoRemediation\_AutomatedTesting\Invoke-AutoRemediatePrinter_BreakTest.ps1 -Restore -Force
```

Every run writes a result to `C:\Temp\FixReport\<ScriptUnderTest>\<TestId>.json`.

## Running the whole suite

```powershell
.\_AutomatedTesting\Invoke-AllBreakTests.ps1 -RemediationTest -Force
```

Reboot-requiring breaks are excluded from the sweep by design — a reboot mid-run would
terminate the orchestrator. Run those individually with `-IncludeRebootBreaks` on the
specific break test, then re-run the analyser to pick the result up.

## Analysing results

```powershell
.\_AutomatedTesting\Invoke-FixReportAnalysis.ps1
```

Prints a per-script summary and CSV (`Summary.csv`), and exits 1 if any run needs
attention. `Overall` outcomes:

| Outcome | Meaning |
|---|---|
| `Passed` | Break landed, remediation fixed it, validation confirmed it |
| `Restored` / `BreakOnly` | Break-only run (no `-RemediationTest`); machine restored / left broken |
| `FalsePass` | **Remediation reported success but the component was still broken** |
| `BreakFailed` | The break never actually landed — the run proves nothing |
| `Failed` | Remediation ran but validation failed |
| `Abandoned` | Run did not complete (e.g. interrupted, crashed) |
| `Dirty` | Restore failed — the machine is still modified and needs manual cleanup |

## Authoring a new break test

Copy the closest existing `*_BreakTest.ps1` as a template and adjust the `$BreakCatalog`.
Each entry needs:

- `Name`, `ExpectedOutcome` (`ExpectFixed` or `ExpectReportedOnly`), `RequiresReboot`, `ConnectivityRisk`
- `Methods[]` — one or more `{ Name; Apply }` scriptblocks that break the component
- `Capture` — returns a hashtable of original state, captured **before** `Apply` runs
- `Verify` — returns `$true`/`$false` proving the break actually landed (never assume it did)
- `Validate` — returns `$true`/`$false`, or `@{ Passed = $bool; Detail = 'diagnostic string' }`
  for checks covering more than one underlying condition
- `Restore` — takes the captured original state and undoes the break

Keep breaks that could sever the session running the test (disabling the adapter used
for a remote session, resetting Winsock, etc.) out of the default catalog. Gate them
behind an opt-in switch instead, matching `-IncludeRebootBreaks` on the Printer harness.
