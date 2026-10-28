# Automated testing through Workspace ONE UEM

**Audience:** whoever maintains the DEX scripts and the UEM script connector. This describes how a script or sensor in this repo is proven to work *as UEM runs it* (Hub, SYSTEM context, the published timeout, the real device) rather than only from an elevated console, and the tool that does it.

**Status:** tool written and dry-run against the tenant on 2026-10-28; first live run still to be done. See [What has been verified](#what-has-been-verified).

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

Not yet done, because it writes to the tenant and runs scripts on a device:

- The create, assign, sync, poll, delete loop end to end. Step 4 above is that run.
- How quickly `SyncWorkflows` and `SyncSensors` are honoured. The defaults assume minutes, not seconds.
- Whether a script created with `script_variables` values populates `$env:` on the device the way the console-set ones do.

## Next steps, in order

1. First live run (step 4). Fix whatever the real responses disagree with; the create/assign bodies and the delete routes are the likely spots.
2. Add the verdict to the inventory: a `-UpdateInventory` switch like the one on `Invoke-DriverDeviceLabRun.ps1`, flipping `Status` to `4) Complete - Tested` for items that passed on the lab build.
3. Fleet check of the *published* items: one `workflows/{uuid}/devices/search` call per published script to list every device where it is currently `Failed`. Cheap, read-only, and it would have caught all three rows in the first table.
4. Remote break/fix: a wrapper script that runs a `*_BreakTest.ps1` on the lab VM through UEM (it needs the test-host marker and `-Force`), with a companion sensor that reports `C:\Temp\FixReport\Summary.csv`. That closes the loop between the two harnesses without a console session on the VM.
5. Switch `Publish-WsoContent.ps1` to import `Wso.ContentLib.psm1` instead of carrying its own copies of the shared functions.
