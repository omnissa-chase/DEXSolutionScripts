# Automated testing through Workspace ONE UEM

**Audience:** whoever maintains the DEX scripts and the UEM script connector. This describes how a script or sensor in this repo is proven to work *as UEM runs it* (Hub, SYSTEM context, the published timeout, the real device) rather than only from an elevated console, and the tool that does it.

**Status:** tool written and dry-run against the tenant on 2026-10-28; live runs on 2026-10-29 proved create, assign, sync and device-side execution. See [What has been verified](#what-has-been-verified).

## Why a second layer

The break/fix harness in this folder proves a remediation script fixes what it claims, on a machine where the test runs the script directly. It cannot prove the thing that actually bites in production: the item as *published* runs cleanly under Hub. Those failures look like this in the tenant today:

| Published item | Status on the lab VM | Why |
|---|---|---|
| `Invoke-AutoRemediateDriverIssues` | Failed, `ScriptNonSuccessReturnCode` | Deployed without its required `DriverFilter` variable, exits 1 |
| `Invoke-AutoRemediateWindowsUpdates` | Failed, `ScriptNonSuccessReturnCode` | Exits 1 on an ARM64 VM; never seen in local testing |
| `PCCommands_SignOff 1.4.9` | Failed, timeout | Exceeds its UEM timeout |

None of these are visible from a local run. All of them are visible from the API in under a minute, which is what this layer automates.

## What UEM exposes

Everything below was read from the tenant's own API documentation (`api/help/Docs/mdmv1`, `api/help/Docs/mdmv2`) and confirmed with read-only calls against it.

**Scripts run as implicit workflows.** Assigning a script creates a one-step workflow whose step executes the script. UEM records the workflow's status per device, not the script's output. The step status carries a reason code:

| Device result | Workflow status | Reason |
|---|---|---|
| Exit code 0 | `Completed` | |
| Exit code other than 0 | `Failed` | `ScriptNonSuccessReturnCode` (12011) |
| Ran past the item's timeout | `Failed` | timeout |
| Not yet run on this device | 404, error 150019 | |

Hub retries failed workflows on its own ("failed workflow sync"), so a published script that exits 1 is re-run on every sync and stays `Failed`. A test must therefore use a fresh copy of the script, never the published one, or a stale status from an earlier run could be mistaken for the current result.

**Sensors return their value.** `GET api/mdm/devices/{uuid}/sensors` lists every sensor a device has reported, with the value and `last_executed_at`. This is the only channel that carries data back, so anything a test wants to *inspect* must be a sensor.

**Routes the tool uses**

| Step | Route | Notes |
|---|---|---|
| Create script | `POST api/mdm/groups/{og}/scripts` (v2) | Same payload as the publisher |
| Assign script | `POST api/mdm/scripts/{uuid}/updateassignments` (v2) | `deployment_mode AUTO`, `trigger_type EVENT`, `event_triggers [RUN_IMMEDIATELY]`. This is what the console calls Run Immediately |
| Script to workflow | `GET api/mdm/workflows/3/search/{scriptUuid}` (v1) | Entity type 3 is Script. The route documents the enum by name but only accepts the number |
| Create sensor | `POST api/mdm/devicesensors` (v2) | |
| Assign sensor | `POST api/mdm/devicesensors/{uuid}/assignment` (v2) | Scheduled trigger; the sync below makes it sample now |
| Force the device | `POST api/mdm/devices/{id}/commands?command=SyncWorkflows` and `=SyncSensors` (v1) | Queued commands, 202 on accept |
| Script result | `GET api/mdm/devices/{deviceUuid}/workflows/{workflowUuid}/status` (v1) | Status plus step reason |
| Sensor result | `GET api/mdm/devices/{deviceUuid}/sensors` (v2) | |
| Delete | `POST api/mdm/groups/{og}/scripts/bulkdelete`, `POST api/mdm/devicesensors/bulkdelete` (v1) | 204 |
| Smart group members | `GET api/mdm/smartgroups/{id}/devices`, then `GET api/mdm/devices/{id}` (v1) | The first gives ids, the status routes want uuids |

Also available but not used yet: `POST api/mdm/workflows/{uuid}/devices/search` (one call for every device's status on a workflow, handy for fleet-wide checks of the *published* items), `GET api/mdm/workflows/{uuid}/statuses/summary?organization_group_uuid=`, and `GET api/mdm/devices/{deviceUuid}/workflows/status` (every workflow on one device).

Not available: an on-demand "run this script on this device" call, and the script's console output. Hub does ship step logs to UEM, but no documented route reads them back.

## The tool

`Invoke-WsoContentTest.ps1` lives in the connector folder next to `Publish-WsoContent.ps1` and shares its configuration, libraries and credentials. Per run it:

1. Reads the inventory and this folder's `uem-tests.json`, and builds one case per selected item. Cases are built with the publisher's own functions (now in `Wso.ContentLib.psm1`), so the tested copy has the same context, architecture, timeout and variables the real item would.
2. Resolves the test smart group by exact name and lists its devices. Refuses an empty group, a group over `Test.MaxDevices`, a non-Windows member, or a group named `All *`.
3. In batches of `Test.BatchSize`: creates each item under a throwaway name (`DEXTEST_<runid>_<name>`), assigns it to the group, resolves the workflow, sends `SyncWorkflows` / `SyncSensors` to every device, and polls until each device has reported or the item's deadline passes. Devices are re-synced every `Test.ResyncMinutes` while anything is still pending.
4. Evaluates each case (below), deletes the batch's items, and moves on.
5. Writes `test-result.json` beside the connector, prints a verdict table, exits 1 if anything is not `Passed` or `Skipped`.

**Verdicts**

| Outcome | Meaning |
|---|---|
| `Passed` | Every device reported, and the report matched the expectation |
| `Failed` | A device reported the wrong workflow status, or a sensor value failed a check |
| `NoResult` | A device never reported within the deadline. Device offline, Hub unhealthy, or the sync command not honoured |
| `Error` | The API refused a create, assignment or workflow lookup. The tenant was not changed by that case |
| `Skipped` | Not run: manifest skip, High impact without `-IncludeHighImpact`, missing file, or required input with no values |

**Expectations** come from `uem-tests.json`, keyed on the inventory name:

| Key | Applies to | Meaning |
|---|---|---|
| `skip` | both | Never run; the string is the reason and goes into the result file |
| `expect` | scripts | `Completed` (default) or `Failed`. Use `Failed` to pin a guard, e.g. "exits 1 without its variable" |
| `variables` | scripts | Values for the `$env:`-backed parameters the publisher would declare as script variables |
| `match` | sensors | Regex the value must satisfy |
| `min` / `max` | sensors | Numeric bounds |
| `allowEmpty` | sensors | Accept an empty String value |
| `timeoutMinutes` | both | Override the wait for a result |
| `note` | both | Free text carried into the result file |

Without an entry, a script is expected to report `Completed` and a sensor to report a value that parses as its declared Data Type (Integer, Boolean, DateTime, or a non-empty String).

**Safety rules**

- Nothing is ever created under a real name. The published items are never read, updated, re-assigned or re-run by the tool.
- The smart group is the blast radius. Everything in it runs every selected script. Keep it to disposable VMs, and note that the Hub on those VMs will run the items as SYSTEM.
- High-impact items (inventory column `Potential End User Impact` = `1) High`) are skipped unless `-IncludeHighImpact`; manifest skips always win. Reboot, sign-off, lock and profile-deletion items are skipped in the manifest.
- `-WhatIf` performs every read and lists the exact cases and devices, then stops before the first write.
- `-Keep` leaves the test items in the tenant for inspection; `-CleanupOrphans` removes any `DEXTEST_*` items from an interrupted run.
- Run under Windows PowerShell 5.1, like the publisher. The library copy in the connector folder validates the server certificate through a callback PowerShell 7 does not honour.

## Setting it up

1. Put the lab VM (or VMs) in a smart group of their own. The `smart_group_import.ps1` sample in `WorkspaceOneAPI\wso_api_lib_samples` builds one from a CSV of computer names; the console works too. One VM is enough.
2. In `settings.config.json`, fill the `Test` block (`settings.config.template.json` has it): `SmartGroupName`, and adjust `MaxDevices`, `BatchSize` and the timeouts if the defaults (5, 10, 10 min scripts, 15 min sensors) do not fit.
3. Dry run:
   ```powershell
   .\Invoke-WsoContentTest.ps1 -WhatIf
   ```
4. Prove the round trip with one sensor and one harmless script, keeping the copies so they can be inspected in the console:
   ```powershell
   .\Invoke-WsoContentTest.ps1 -Name "device_is_virtual*","Invoke-AutoRemediateChrome*" -Keep
   .\Invoke-WsoContentTest.ps1 -CleanupOrphans
   ```
5. Run the inventory:
   ```powershell
   .\Invoke-WsoContentTest.ps1                 # everything not skipped
   .\Invoke-WsoContentTest.ps1 -Type Sensor    # sensors only; fast and read-only on the device
   ```

## Reading a failure

`ScriptNonSuccessReturnCode` means the script exited non-zero under Hub. The exit code itself is not reported, so the next step is the device: `C:\ProgramData\AirWatch\UnifiedAgent\Logs\AW.ProtectionAgent.PowershellExecutor64-<date>.log` has the host exit code and the script's error stream for every run, and `Workflow-<date>.log` has the step status Hub reported. Then run the script by hand under SYSTEM per `General-Testing-Guide.md` to reproduce.

A sensor `Failed` verdict carries the value, so the fix is usually in the script or in the manifest's expectation.

`NoResult` on every item means the device is not picking up assignments: check it is online, `Last Seen` is recent, and Hub's `WorkflowStepStatusReporting` is running (the Workflow log shows it every 30 minutes).

## What has been verified

Done on 2026-10-28, read-only against the tenant:

- Every route in the table above exists in the tenant's API documentation; the GET routes were called and return the documented shapes. The workflow status route returned the live `Failed` / `ScriptNonSuccessReturnCode` result for `Invoke-AutoRemediateWindowsUpdates` on the lab VM, which matches the Hub logs on that VM to the second.
- The tool's dry run resolves the smart group, lists its devices, builds every case from the real inventory and manifest, and stops before the first write.
- A PowerShell 5.1 harness over the case builder and the sensor checks: manifest variables land on the right parameter, manifest skips beat the impact filter, `-IncludeHighImpact` lifts the impact skip but not manifest skips, sensor names are sanitized, and the Integer / Boolean / DateTime / String / regex / min-max checks accept and reject what they should.

Done on 2026-10-29, first live run against `Test_Treddy` (run id `036de0`, two items, `-Keep`):

- Script create (`POST api/mdm/groups/{og}/scripts`) and sensor create plus sensor assignment work as written; the sensor copy was created, assigned and synced.
- Script assignment was refused with `errorCode 150032` ("necessary trigger attributes"). Probing the kept copy showed why: the tool's default body put `RUN_IMMEDIATELY` in an `event_triggers` list, and `RUN_IMMEDIATELY` is not a value of the server's `TriggerTypes` enum at all (`HTTP 400 Error converting value "RUN_IMMEDIATELY" to type AirWatch.UEM.Scripts.Contract.TriggerTypes`). The accepted body is `deployment_mode: AUTO` with `script_deployment: { trigger_type: EVENT, trigger_events: [LOGIN, STARTUP] }` (HTTP 204). Note the write shape is `trigger_events` / `trigger_schedule` while the GET read-back renames them `event_triggers` / `schedule_trigger`. Later the same day a tenant-side script assigned by the console showed `event_triggers = [RUN_IMMEDIATELY]`, so `RUN_IMMEDIATELY` is a valid *event* value, just not a trigger type. The body `script_deployment: { trigger_type: EVENT, trigger_events: [RUN_IMMEDIATELY] }` was then sent by the tool (run id `0bf8d0`) and accepted with HTTP 204. That is now the shape in `settings.config.json` under `BulkAssign.RunOnceAssignment` and in the tool's built-in default.
- Side finding from the same day: a script in `Failed` workflow state is re-run by Hub on every `SyncWorkflows` and every sign-in. A tenant test script that signs the user off (`PCCommands_SignOff 1.4.9`) was assigned to All Devices in that state and logged the lab user off at every sync, which killed every poller that was waiting on results. Its assignment was removed through `updateassignments` with an empty list (HTTP 204, 0 assignments after). Check All Devices assignments on a test tenant before relying on a long-running poller on an enrolled device.

Second live run the same day (run id `eed7da`, Chrome only, corrected body): create, assign and `SyncWorkflows` all accepted. On the lab VM, Hub's `Workflow-20261029.log` shows the step `DEXTEST_eed7da_Invoke-AutoRemediateChrome` in progress at 19:00:43Z and completed with `Success` at 19:00:52Z, about two minutes after the sync command; `AW.ProtectionAgent.PowershellExecutor64-20261029.log` shows host exit code 0; and the script's own record at `HKLM:\Software\AirWatch\Extension\DEXRecords\ChromeErrors` carries `LastScanTime 2026-10-29 15:00:51`, 5 passed, 1 warning. So an `AUTO` assignment with an `EVENT` trigger runs once on arrival without waiting for the event, and `SyncWorkflows` is honoured within minutes.

First full sensor sweep, 2026-10-29 (run id `e505e2`, 69 sensors on the two live devices, result file `test-result-sensors.json` in the connector folder): 52 passed, 5 failed, 12 no result. Hub's `AWProcessCommands-<date>.log` on the device explains every non-pass, and three rules follow from it:

- **A sensor value is capped at 1 KB.** Hub logs `"Sensor Data Name: {0} returns {1} is invalid because output length is greater than 1KB length"` and sends nothing. `sensor-getservice.ps1` (2.4 KB), `logon_folder_redirection_map.ps1` (1.2 KB) and `logon_folder_redirection_latency_probe.ps1` (2.5 KB) all hit it. The two folder-redirection sensors were restructured the same day to stay under the cap; the tenant's own published `logon_folder_redirection_map` and `device_running_service` sensors fail this way on every sample and need the same fix.
- **An empty value is rejected for Boolean and DateTime sensors.** Hub logs `returns "" is invalid because expected type is Boolean` (or `DateTime`) and stores nothing, so a typed sensor that emits nothing by design when its source is absent (`logon_time`, `logon_shell_ready_time`, `logon_gp_start_time`, `vpn_last_connect_time`, `vpn_dns_configured`, `scom_management_server_reachable`, `scom_healthservice_running_standalone`) shows as no result on a device without the product. The manifest marks these `expectNoValue` and the tool passes them when nothing is stored. A String sensor may return `""` and it is stored as an empty string; the five that do so by design (`vpn_adapter_name`, `vpn_health_reason`, `scom_agent_health_reason`, `scom_agent_version`, `scom_agent_version_standalone`) are marked `allowEmpty`.
- **Output must be one clean line.** Hub logs `failed sanity` for `Get-UserProfileSize.ps1` (34 lines of log text, exits 1; not sensor-shaped, now skipped in the manifest) and for `performance_defender_scanorupdateactive.ps1`, which prints `Idle` interactively; its `Get-WinEvent` calls were silenced in 1.0.1 on the assumption that an error record reached the output stream under Hub. To be confirmed on the next sweep.

Script sweep the same evening (run id in `test-result-scripts.json`, 44 runnable scripts, two live devices): `Restart-WinService.ps1` reported `Completed` on both devices with the manifest's `ServiceName = Spooler`, and it exits 1 without that variable, so **`script_variables` set at create time do populate `$env:` on the device** the same way console-set variables do. `Invoke-AutoRemediateDriverIssues.ps1` (`DriverFilter = VMware`) and `Invoke-DriverUpdates.ps1` (`Mode = Detect`) ran with their variables the same way.

Script sweep result (run id `6c8405`, 44 runnable, 16 manifest skips, result file `test-result-scripts.json`): 41 passed, 3 failed, 0 no result. The three failures and what they taught:

- **`Start-DiskCleanup.ps1`, `ScriptTimedOut (12007)` on one device.** The script's own host exited 0 in 5 s, but cleanmgr had been launched with the call operator and inherited the host's stdout pipe, so Hub kept "waiting for output" until the 30 s budget expired. Hub times the pipe, not the process. Fixed in 1.2.1 with `Start-Process`; re-run `0501f4` reported `Completed` on both devices. Any script that starts a long-lived child must not let it inherit the output handles.
- **`Invoke-AutoRemediateSCOMMonitoringHost.ps1`, `UnknownScriptError (12004)` on both devices.** The executor log shows `Launcher failed: Cannot bind argument to parameter 'Path' because it is an empty string`. **Hub feeds the script to PowerShell through stdin** (the executor logs `PowerShell executor (stdin)`), so `$PSCommandPath`, `$PSScriptRoot` and `$MyInvocation.MyCommand.Path` are all empty under UEM, and `Copy-Item -Path $PSCommandPath` throws. Ten scripts stage themselves this way (three SCOM and three SCCM launchers, `DEX_Start-WindowsUpdate.ps1`, and the `DeployScheduledTask` mode of both `Measure-LogonDuration` scripts); all now persist `$MyInvocation.MyCommand.ScriptBlock.ToString()`, which carries the full script text in both file and stdin mode (checked locally with a probe under `-File -` and `-Command -`). The first re-run (`300fde`) got past the self-copy and wrote `Status = Dispatched` to the registry, then failed on the next line: the three SCOM launchers passed `-WhatIf:$false` to `Register-ScheduledTask`, which has no `WhatIf` parameter (`Unregister-ScheduledTask` does; `Register-` and `Start-ScheduledTask` do not). Removed in the same 1.0.2. A second re-run (`9df1eb`) was inconclusive because the lab host suspended mid-run (clock-jump events on the VM, no workflow registration in Hub's log). The third (`5b5331`) got past registration's parameter binding and failed on the task XML: `The task XML is missing a required element or attribute. (41,4):EndBoundary`. `-DeleteExpiredTaskAfter` is only valid when the task has a trigger with an `EndBoundary`, and these launchers register a trigger-less task that they start by hand, so the setting makes registration fail outright. Removed from the three SCOM launchers, the three SCCM launchers and the OneDrive restart task (all of which already unregister their own task), and the runbook template corrected. Each of these was invisible interactively because the launchers were only ever exercised as files from an elevated console, never through Hub. The fourth re-run (`c99707`, 2026-10-30 00:21) reported `Completed` on both devices and the launcher log showed `Dispatched task 'WS1_SCOMMonitoringHost'`, but the payload Hub staged on the VM was 25,951 characters against a 30,629-character source and started at `[CmdletBinding(...)]`: **inside a function, `$MyInvocation.MyCommand.ScriptBlock` is the function body**, so the `#Requires` line, the header and, worse, the tail that reads `$env:RunAsPayload` and calls the function were all missing. The truncated payload therefore ran as a launcher, saw its own task as running, and exited 0 without doing anything (registry still `Dispatched`). Fix: capture `$script:SelfText = $MyInvocation.MyCommand.ScriptBlock.ToString()` at script scope on the line before the function and write that. In the fifth re-run (`37acca`, 2026-10-30 00:31, `Completed` on both devices, result file `test-result-launcher.json`) the staged payload is 30,780 bytes, the payload log records every step through `Payload complete`, and the registry reads `Status = Skipped:NoAgent`, `LastRunTime` set. A `Completed` from a launcher proves only that the launcher exited 0; the payload's own record is the evidence that matters.
- **`Enable-HardwareAcceleratedGPUScheduling.ps1`, exit 1 on both devices.** By design on the run that first enables HwSchMode; re-run `0501f4` reported `Completed` on both. Not a defect.

Side findings from the device logs during the sweep: the tenant's own published `Invoke-AutoRemediateDriverIssues` copy fails on every sync with `-DriverFilter is required` (no variable set on that assignment), and an error record `The term 'if' is not recognized` was logged for a batch-4 script (Zoom or GenericVPN) that still exited 0, which did not reproduce locally; Hub does not fail a step for error-stream output alone. Confirmation run `0501f4` (five items, result file `test-result-confirm.json`): 5 passed.

Not yet done:
- A device that is offline (the Latitude in `Test_Treddy`) makes every case wait its full deadline before `NoResult` is recorded. Keep test groups to devices that are on, or lower the timeouts for a quick pass.

## Next steps, in order

1. First live run (step 4). Fix whatever the real responses disagree with; the create/assign bodies and the delete routes are the likely spots.
2. Add the verdict to the inventory: a `-UpdateInventory` switch like the one on `Invoke-DriverDeviceLabRun.ps1`, flipping `Status` to `4) Complete - Tested` for items that passed on the lab build.
3. Fleet check of the *published* items: one `workflows/{uuid}/devices/search` call per published script to list every device where it is currently `Failed`. Cheap, read-only, and it would have caught all three rows in the first table.
4. Remote break/fix: a wrapper script that runs a `*_BreakTest.ps1` on the lab VM through UEM (it needs the test-host marker and `-Force`), with a companion sensor that reports `C:\Temp\FixReport\Summary.csv`. That closes the loop between the two harnesses without a console session on the VM.
5. Switch `Publish-WsoContent.ps1` to import `Wso.ContentLib.psm1` instead of carrying its own copies of the shared functions.
