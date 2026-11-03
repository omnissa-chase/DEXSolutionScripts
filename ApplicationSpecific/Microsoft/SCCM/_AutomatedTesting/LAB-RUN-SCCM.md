# Lab Run: SCCM Client Health Scripts

**Audience:** the person running these on their own Configuration Manager lab client. You
do not need Workspace ONE, DEX, or any knowledge of this repo. You need one domain-joined
Windows 10 or 11 VM with the ConfigMgr client installed and healthy, a snapshot of it, and
about 30 minutes.

## What you are testing

Five PowerShell scripts that check and repair common ConfigMgr client problems. In
production they run under Workspace ONE as SYSTEM. Here they run the same way, as files,
in an elevated Windows PowerShell 5.1 window, driven by one harness that records
everything and zips it up for you to send back.

| Script | What it does on a healthy client |
|---|---|
| `Invoke-AutoRemediateSCCMClient.ps1` | 14 health checks. Starts CcmExec if stopped, flushes DNS if the MP is unreachable, triggers a policy refresh if policy is stale. Everything else is report-only. |
| `Invoke-AutoRemediateWMIRepository.ps1` | Verifies the WMI repository twice. Only salvages when both checks fail. On a healthy client it reports consistent and does nothing. |
| `Invoke-AutoRemediateCcmCache.ps1` | Reads cache utilisation. Only purges stale elements above 80 percent. On a healthy client it reports the figure and does nothing. |
| `Invoke-AutoRemediateBITSBacklog.ps1` | Removes stalled ConfigMgr BITS jobs only. Never touches other products' jobs. |
| `Invoke-AutoRemediateOrphanedCcmSetup.ps1` | Kills a ccmsetup.exe that is provably stuck in a retry loop. With no ccmsetup running it reports that and exits. |

Three of them (WMI, cache, ccmsetup) start a one-shot scheduled task to do the work and
write their result to the registry under
`HKLM:\Software\AirWatch\Extension\DEXRecords\SCCM\`. The harness waits for the task and
reads that record.

## Before you start

1. **Take a snapshot of the VM.** The harness restores everything it changes, but the
   snapshot is the safety net.
2. Copy the **whole repository** onto the VM, for example to `C:\DEXSolutionScripts`. The
   harness imports a shared module from `AutomatedTesting\`, so the SCCM folder alone is
   not enough.
3. Open **Windows PowerShell 5.1 as Administrator**. Not PowerShell 7. Check with
   `$PSVersionTable.PSVersion` and expect 5.1.
4. Mark the VM as a disposable test host. The harness refuses to run without this file:
   ```powershell
   New-Item -ItemType Directory -Path 'C:\Temp\FixReport' -Force | Out-Null
   Set-Content -Path 'C:\Temp\FixReport\.dex-test-machine' -Value $env:COMPUTERNAME
   ```
5. Confirm the client is healthy and talking to its site:
   ```powershell
   Get-Service CcmExec
   Get-CimInstance -Namespace root\ccm -ClassName SMS_Authority | Select-Object Name, CurrentManagementPoint
   ```

## Run it

```powershell
Set-Location 'C:\DEXSolutionScripts\ApplicationSpecific\Microsoft\SCCM\_AutomatedTesting'

.\Invoke-SCCMLabRun.ps1 -PlanOnly                       # shows what will run; changes nothing
.\Invoke-SCCMLabRun.ps1 -Force                          # baseline: every script once, client untouched
.\Invoke-SCCMLabRun.ps1 -Force -IncludeScenarios        # baseline plus the five reversible scenarios
```

The baseline takes 5 to 10 minutes, most of it waiting for the three scheduled tasks. The
scenarios add about 10 minutes. The run ends with a table and a line that reads
`Send back: C:\Temp\DEXLabRuns\SCCM_<timestamp>.zip`. That zip is the whole deliverable.

If something goes wrong mid-run, each scenario restores its own change before the next one
starts. If the final table shows `Restored: False` on any row, revert the snapshot.

## What the scenarios do

Each scenario captures the current state, makes one reversible change, proves the change
landed, runs the script, checks the script's printed message and the end state, and puts
the original back.

| Scenario | Change | What must happen |
|---|---|---|
| `CcmExecStopped` | Stops the CcmExec service | Step 1 reports it Stopped, remediation runs, service is Running again within 90 s with start type Automatic (Delayed) |
| `CcmExecManualStart` | Sets CcmExec start type to Manual | Step 1 reports the Manual start type, remediation sets Automatic (Delayed), service keeps running |
| `PolicyLogStale` | Dates `PolicyAgent.log` three days back | Step 8 warns, triggers a machine policy refresh, and the client writes the log again within 90 s |
| `BitsDisabled` | Sets BITS to Disabled | BITS script step 1 reports it, sets Manual, starts the service |
| `ForeignBitsJobKept` | Creates a suspended BITS job that is not a ConfigMgr job | BITS script step 3 names it as not touched, and the job still exists afterwards |

To run just one: `.\Invoke-SCCMLabRun.ps1 -Force -Scenario BitsDisabled`.

## What is deliberately not automated

These would need a genuinely broken client and cannot be undone by a script, so they are
left to you only if you want to go further. Each is optional. Revert the snapshot after.

- **Stuck ccmsetup retry loop.** On a second throwaway VM, run the client installer against
  a management point that does not exist, for example `ccmsetup.exe /mp:nosuchhost
  SMSSITECODE=XXX`, and leave it for a little over four hours so `ccmsetup.log` fills with
  retry entries. Then run `Invoke-AutoRemediateOrphanedCcmSetup.ps1` elevated and watch the
  registry record under `DEXRecords\SCCM\OrphanedCcmSetup`: before four hours the guards
  should abort with `Warning`; after, `CcmSetupKilled` should read 1. Running it earlier
  than four hours is itself a useful test: it must refuse.
- **Full client cache.** Deploy enough packages to the VM to push `ccmcache` above 80
  percent, wait 30 days, or lower the site's cache size setting instead. Then run
  `Invoke-AutoRemediateCcmCache.ps1` and check `ElementsRemoved` and `MBFreed` in its
  registry record.
- **Inconsistent WMI repository.** Not recommended even in a lab. The baseline already
  proves the script reports a consistent repository and takes no action.

## What to send back

The zip. It contains:

| File | What it is |
|---|---|
| `LabInfo.json` | Client version, site, management point, OS build, service state before the run |
| `Summary.csv` | One row per script run or scenario with pass or fail and the exit code |
| `Results.json` | Every check, every message, and the full output of every run |
| `*_<script>.txt` | Raw console output of each script run |
| `LabRun.log` | The harness's own log |

If a run fails, the raw output file for it is the first thing to look at. Nothing in the
bundle contains credentials. It does contain your computer name, site code and
management point hostname, so trim `LabInfo.json` if that matters to you.

## If the harness refuses to start

| Message | Fix |
|---|---|
| `Run this in Windows PowerShell 5.1` | Open "Windows PowerShell", not "PowerShell 7" |
| `REFUSING TO RUN. Test-host marker not found` | Step 4 above |
| `REFUSING TO RUN. Break tests are destructive; pass -Force` | Add `-Force` |
| `DEXTestFramework.psm1 not found` | Copy the whole repo, not just the SCCM folder |
| `No CcmExec service on this machine` | Install the ConfigMgr client first |
