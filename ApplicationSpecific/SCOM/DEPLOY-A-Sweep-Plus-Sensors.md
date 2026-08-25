# Solution A — Sweep Scripts + Cached Sensors

**The full-coverage option.** Three scheduled scripts run a 14-step assessment of the Operations
Manager agent and cache every metric; seven lightweight sensors read that cache and report to DEX.

Choosing between the two solutions:

| | **Solution A** (this document) | **Solution B** ([sensors only](DEPLOY-B-Sensors-Only.md)) |
|---|---|---|
| Objects to deploy | 3 scripts + 7 sensors | 9 sensors |
| Checks covered | 14 of 14 | 8 of 14 |
| Health score range | 235 deductible points | 130 deductible points |
| Sees management server reachability | ✅ | ❌ |
| Sees event-log faults (auth, registration, workflows, store corruption) | ✅ | ❌ |
| Auto-remediates anything | ✅ (2 actions) | ❌ |
| Needs script deployment permission | Yes | No |
| Needs scheduling discipline | Yes — Part 3 must run last | No |

Pick A unless you cannot deploy scripts to the fleet. It is the only option that sees the faults
that actually take an agent offline.

---

## Table of Contents

1. [What you are deploying](#1-what-you-are-deploying)
2. [Prerequisites](#2-prerequisites)
3. [Test it locally first](#3-test-it-locally-first)
4. [UEM configuration](#4-uem-configuration)
5. [Validating the first fleet run](#5-validating-the-first-fleet-run)
6. [Rollout rings](#6-rollout-rings)
7. [Adding the Tier 2 remediation scripts](#7-adding-the-tier-2-remediation-scripts)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. What you are deploying

**Three script objects.** The 14-step sweep is 48,336 characters against UEM's 32,767-character
limit, so it ships split into three objects that share one registry cache at
`HKLM:\Software\AirWatch\Extensions\SCOM`.

| Script | Steps | Chars | Auto-remediates |
|---|---|---:|---|
| `Invoke-AutoRemediateSCOMAgentPart1.ps1` | 1–5 — service state, startup delay, management group, MS connectivity, config freshness | 22,350 | Service start + start-type fix; DNS flush |
| `Invoke-AutoRemediateSCOMAgentPart2.ps1` | 6–10 — state folder, store DB, runtime footprint, connector failures, workflow health | 26,090 | Nothing |
| `Invoke-AutoRemediateSCOMAgentPart3.ps1` | 11–14 — channel certificate, agent version, time skew, sub-services — **plus the health score** | 27,705 | Nothing |

**Seven sensors**, all pure cache readers from `Sensors/`. They contain no detection logic, make no
network calls, and finish in well under two seconds.

| Sensor | Type | Fallback |
|---|---|---|
| `scom_agent_health_score.ps1` | Integer | `-1` |
| `scom_agent_health_reason.ps1` | String | `""` |
| `scom_management_server_reachable.ps1` | Boolean | *(no sample)* |
| `scom_agent_version.ps1` | String | `""` |
| `scom_config_age_hours.ps1` | Integer | `-1` |
| `scom_state_folder_mb.ps1` | Integer | `-1` |
| `scom_monitoringhost_memory_mb.ps1` | Integer | `-1` |

> **Do not deploy `Invoke-AutoRemediateSCOMAgent.ps1`.** It is the combined reference
> implementation, 48,336 characters, and UEM will reject it. It is kept in the folder for reading,
> not for assignment.
>
> **Do not deploy `Sensors/Standalone/` alongside these.** That is Solution B. Running both gives
> you two columns reporting the same attribute under different names, and they will disagree at the
> edges.

---

## 2. Prerequisites

- **Workspace ONE UEM** with Scripts and Sensors enabled for Windows.
- **Execution context: SYSTEM** for every script and sensor. Service control, the
  `Operations Manager` event log, the agent install directory and
  `HKLM\SOFTWARE\Microsoft\Microsoft Operations Manager` all require it. User context produces
  empty results or access-denied errors.
- **PowerShell 5.1, x64.** All scripts declare `#Requires -Version 5.1`.
- **A test device with the SCOM agent installed** for the local test in section 3. An agentless
  device is still worth testing (it exercises the guard clause) but proves nothing about the
  fourteen checks.
- **No AV/EDR exclusion needed for Solution A.** The three sweep parts run inline. Exclusions are
  only required if you later add the Tier 2 scripts — see [section 7](#7-adding-the-tier-2-remediation-scripts).

---

## 3. Test it locally first

Do this on one real device before touching UEM. The whole pass takes about ten minutes.

### 3.1 Open the right shell

Everything below needs an **elevated PowerShell 5.1 (x64)**. Confirm all three:

```powershell
$PSVersionTable.PSVersion              # 5.1.x
[Environment]::Is64BitProcess          # True
([Security.Principal.WindowsPrincipal] `
  [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)   # True
```

Copy the three `Part*.ps1` files and the `Sensors` folder to a working directory, e.g. `C:\SCOMTest`,
and `cd` there.

### 3.2 Record the starting state

So you can tell what the scripts changed, and so you can put it back:

```powershell
Get-Service HealthService -ErrorAction SilentlyContinue |
    Select-Object Status, StartType
Test-Path 'HKLM:\SOFTWARE\Microsoft\Microsoft Operations Manager\3.0'
Test-Path 'HKLM:\Software\AirWatch\Extensions\SCOM'    # expect False on a clean device
```

If `HealthService` is missing and the registry root is absent, you are on an agentless device. Skip
to [3.7](#37-agentless-device-check) — the other steps will exit immediately by design.

### 3.3 Dry run

The `WhatIf` environment variable is the UEM-compatible dry-run switch. Absent, empty or
unparseable means a live run, so it fails safe in the direction of "do the normal thing".

```powershell
$env:WhatIf = 'true'
.\Invoke-AutoRemediateSCOMAgentPart1.ps1
$LASTEXITCODE
```

You should see fourteen-step-style console output for steps 1–5, with any remediation announced as
`What if:` rather than performed.

> **`WhatIf` suppresses remediation, not caching.** The registry writes are deliberately marked
> `-WhatIf:$false`, because the cache is evidence rather than state. A dry run still populates
> `HKLM:\Software\AirWatch\Extensions\SCOM`, which is what makes step 3.5 possible without ever
> changing the device. This is intentional, not a bug.

Repeat for Parts 2 and 3, then clear the variable:

```powershell
.\Invoke-AutoRemediateSCOMAgentPart2.ps1 ; $LASTEXITCODE
.\Invoke-AutoRemediateSCOMAgentPart3.ps1 ; $LASTEXITCODE
Remove-Item Env:\WhatIf
```

**Expected exit codes:** `0` when every step in that part passed or warned — or when no agent is
installed. `1` when at least one step failed. A `1` here is a finding about the device, not a
failure of the script.

### 3.4 Live run, in order

Part 3 reads Parts 1 and 2 out of the registry, so order matters even locally:

```powershell
.\Invoke-AutoRemediateSCOMAgentPart1.ps1 ; "Part1 exit = $LASTEXITCODE"
.\Invoke-AutoRemediateSCOMAgentPart2.ps1 ; "Part2 exit = $LASTEXITCODE"
.\Invoke-AutoRemediateSCOMAgentPart3.ps1 ; "Part3 exit = $LASTEXITCODE"
```

Part 3 prints the health score on its last line, e.g. `Health score: 85 (ConfigurationCacheStale)`.

### 3.5 Inspect the cache

```powershell
Get-ItemProperty 'HKLM:\Software\AirWatch\Extensions\SCOM' |
    Select-Object * -Exclude PS* | Format-List
```

Check these four things, in this order:

| Value | Expect | If not |
|---|---|---|
| `ScoreComplete` | `1` | Parts 1 or 2 did not run, or did not finish — see [3.6](#36-negative-test-the-incomplete-sweep) |
| `HealthScore` | `0`–`100`, or `-1` on an agentless device | `-1` with `ScoreComplete = 0` means incomplete, not unhealthy |
| `Part1RunTime` / `Part2RunTime` / `Part3RunTime` | three recent timestamps | a missing one means that part failed before finishing |
| `AgentVersion`, `StateFolderMB`, `ConfigAgeHours` | populated | an empty value means that step could not measure |

Each part writes its `PartNRunTime` **last, deliberately** — it is a commit marker, not a start
marker. A timestamp that is present means everything before it was written.

### 3.6 Negative test: the incomplete sweep

This is the failure mode most likely to bite you in production, so prove it works before you rely
on it. Delete the two witness timestamps and run Part 3 on its own:

```powershell
Remove-ItemProperty 'HKLM:\Software\AirWatch\Extensions\SCOM' `
    -Name Part1RunTime, Part2RunTime -ErrorAction SilentlyContinue

.\Invoke-AutoRemediateSCOMAgentPart3.ps1 | Out-Null

Get-ItemProperty 'HKLM:\Software\AirWatch\Extensions\SCOM' |
    Select-Object HealthScore, HealthReason, ScoreComplete
```

**Expected:** `HealthScore = -1`, `HealthReason = IncompleteSweep`, `ScoreComplete = 0`.

Part 3 publishes that sentinel rather than a partial score because every scoring rule matches on a
positive threshold — a missing metric can never deduct, so a partial score is always *too high*.
Caching one would tell every sensor the agent is healthier than anyone measured.

Re-run Parts 1 and 2 to restore a complete cache before continuing.

### 3.7 Agentless device check

On a device with no agent, every part should exit `0` immediately and write:

```powershell
Get-ItemProperty 'HKLM:\Software\AirWatch\Extensions\SCOM' |
    Select-Object AgentInstalled, HealthScore, HealthReason, Status
# AgentInstalled = 0, HealthScore = -1, HealthReason = NoAgentInstalled, Status = NotApplicable
```

This is why you assign the scripts to **all** Windows devices rather than only agent devices —
unmonitored devices become identifiable in DEX rather than simply absent.

### 3.8 Run the sensors

Each sensor must emit **exactly one value**. Anything else is a defect that UEM will record as a
type mismatch:

```powershell
Get-ChildItem .\Sensors\*.ps1 | ForEach-Object {
    $sw  = [System.Diagnostics.Stopwatch]::StartNew()
    $out = @(& $_.FullName)
    $sw.Stop()
    '{0,-40} values={1} ms={2,-5} => {3}' -f `
        $_.Name, $out.Count, $sw.ElapsedMilliseconds, ($out -join '|')
}
```

**Expected:** `values=1` for every sensor except `scom_management_server_reachable` on a device
where the sweep could not determine reachability, where `values=0` is correct — it deliberately
emits nothing rather than a `$false` that would read as a real outage. Every sensor should be well
under 2,000 ms.

### 3.9 Time it against the UEM timeouts

Part 2 does the event-log work and is always the slowest. Confirm it fits inside the timeout you
are about to configure:

```powershell
1..3 | ForEach-Object {
    (Measure-Command { & '.\Invoke-AutoRemediateSCOMAgentPart2.ps1' }).TotalSeconds
}
```

If any run approaches 90 seconds on your slowest hardware class, raise the timeout for Part 2 in
UEM before deploying rather than after.

### 3.10 Optional: test in real SYSTEM context

Elevated admin is close to SYSTEM, but UEM runs as SYSTEM and a handful of paths behave
differently. No third-party tools needed:

```powershell
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\SCOMTest\Invoke-AutoRemediateSCOMAgentPart1.ps1"'
Register-ScheduledTask -TaskName 'SCOMSweepTest' -Action $action `
    -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName 'SCOMSweepTest'

# ...wait for it to finish, then:
Unregister-ScheduledTask -TaskName 'SCOMSweepTest' -Confirm:$false
```

Read the result from the registry cache and from
`C:\Windows\Temp\UEM_AutoRemediateSCOMAgentPart1.log` — a scheduled task has no console.

### 3.11 Clean up the test device

```powershell
Remove-Item 'HKLM:\Software\AirWatch\Extensions\SCOM' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:SystemRoot\Temp\UEM_AutoRemediateSCOMAgentPart*.log" -ErrorAction SilentlyContinue
Get-ScheduledTask -TaskName 'SCOMSweepTest' -ErrorAction SilentlyContinue |
    Unregister-ScheduledTask -Confirm:$false
```

> Removing that key also removes the Tier 2 sub-keys (`HealthServiceCache`, `MonitoringHost`,
> `ClonedIdentity`) including their cooldown timestamps. That is fine on a test device and
> **not** something to do on a production one — clearing a cooldown re-arms a destructive script.

If Part 1 started `HealthService` during the live run and you want the device back exactly as it
was, set the service back yourself; the script does not track a rollback for that.

---

## 4. UEM configuration

### 4.1 Script objects

Settings shared by all three:

| Setting | Value |
|---|---|
| Script Type | PowerShell |
| Execution Context | System |
| Architecture | x64 |
| PowerShell Version | 5.1 |
| Show Script Output | Enabled (for troubleshooting) |
| Trigger | Scheduled — every 24 hours |
| Assignment | **All** managed Windows devices |

Per-script:

| Script | Suggested name | Timeout | Schedule |
|---|---|---|---|
| Part 1 | `[DEX] SCOM Agent Health — Part 1 (Connectivity)` | 60 s | Daily |
| Part 2 | `[DEX] SCOM Agent Health — Part 2 (State & Events)` | 90 s | Daily, same window as Part 1 |
| Part 3 | `[DEX] SCOM Agent Health — Part 3 (Certs & Score)` | 60 s | Daily, **at least 15 minutes after Parts 1 and 2** |

**Environment variables**, all three scripts:

| Variable | Effect |
|---|---|
| `WhatIf` = `true` | Dry run — detection only, no remediation. Absent or unparseable means a live run. |

> **Part 3 must run last.** If it runs first, or if Parts 1 or 2 fail, it publishes
> `HealthScore = -1` / `HealthReason = IncompleteSweep` / `ScoreComplete = 0` rather than a
> misleadingly high partial score. That is the designed behaviour, but it means a scheduling
> mistake shows up as a fleet of `-1`s rather than as bad data — see
> [section 8](#8-troubleshooting).

### 4.2 Sensors

| Setting | Value |
|---|---|
| Execution Context | System |
| Architecture | x64 |
| Trigger | Windows Sample Schedule |
| Assignment | Same smart group as the scripts |

Set the sample schedule to **match or lag the sweep schedule**. Sampling more often than the sweep
runs just re-reads the same cached values and burns sensor-queue time fleet-wide for nothing.

Declare each sensor with the response data type from the table in
[section 1](#1-what-you-are-deploying). A mismatch there is the most common cause of a sensor that
"reports nothing" in Intelligence.

---

## 5. Validating the first fleet run

Give it 24 hours plus one sensor sample interval, then check these in order. Each one isolates a
different failure.

**1. Are the scripts running at all?**
Look at script execution status in UEM. A device with no execution record was never assigned or is
not checking in — that is a UEM problem, not a SCOM one.

**2. What fraction of devices report `ScoreComplete = 1`?**
This is the single most useful number in the whole deployment. If it is not near 100%, your
scheduling is wrong and every score you are looking at is a sentinel rather than a measurement. Fix
this before reading anything else.

**3. Split the fleet three ways on `scom_agent_health_reason`:**

| Population | Meaning | Action |
|---|---|---|
| `NoAgentInstalled` | No agent on the device | Exclude from every rate and average. Confirm the count matches what you expect — a surprise here is usually a scope problem. |
| `IncompleteSweep` | Part 1 or 2 has not run in 26h | Scheduling fault, not a health finding |
| everything else | Real findings | Rank by count, not by device |

**4. Only now look at `scom_agent_health_score`.**
Filter out `-1` **before** averaging or ranking. A fleet of healthy devices that never had the
agent installed will otherwise drag every average down and make the dashboard meaningless.

**5. Sanity-check one device end to end.**
Pick a device reporting a specific reason, open it, and confirm the individual sensors agree —
e.g. a device reporting `HealthServiceStateOversized` should have a large `scom_state_folder_mb`.
If they disagree, see [section 8](#8-troubleshooting).

---

## 6. Rollout rings

| Ring | Size | Duration | Gate to proceed |
|---|---|---|---|
| 0 — bench | 1–3 devices | manual | Section 3 passes on real hardware |
| 1 — pilot | 20–50 devices, mixed hardware | 3 days | `ScoreComplete = 1` on ≥95%, no script timeouts |
| 2 — one business unit | ~500 | 1 week | Score distribution looks plausible; reason mix stable day to day |
| 3 — fleet | all | ongoing | — |

Include at least one VDI or Horizon/AVD session host in ring 1. Agent footprint is multiplied by
session density there, and it is the environment where a 90-second Part 2 timeout is most likely to
be tight.

---

## 7. Adding the Tier 2 remediation scripts

**Do not deploy these until the sweep has run for at least a week** and you have used its sensor
output to build targeted smart groups. Deploying a Tier 2 script fleet-wide defeats the design.

| Script | Fixes | Targeting signal |
|---|---|---|
| `Invoke-AutoRemediateSCOMHealthServiceCache.ps1` | State flush — **destructive** | `HealthServiceStoreCorruption`, `ConfigurationCacheStale`, `HealthServiceStateOversized` |
| `Invoke-AutoRemediateSCOMMonitoringHost.ps1` | Agent recycle | `AgentRuntimeFootprintHigh` |
| `Invoke-AutoRemediateSCOMClonedIdentity.ps1` | Identity reset — **destructive** | `AgentNotRegistered` on confirmed clones |

Two things change for Tier 2:

1. **An AV/EDR exclusion is required.** All three use a launcher/payload pattern — the script
   copies itself to `C:\ProgramData\AirWatch\Extensions\SCOM`, registers a one-shot SYSTEM
   scheduled task and exits in about five seconds. If your AV blocks execution from that path the
   payload **silently no-ops and the launcher still reports success**. Add the exclusion first,
   then confirm on a pilot device that `Status` under
   `HKLM:\Software\AirWatch\Extensions\SCOM\<ScriptName>` advances past `Dispatched` to
   `Completed`, `RolledBack`, `Failed`, `SkippedCooldown` or `Skipped:<reason>`.

2. **The two destructive scripts need `ConfirmHighImpact` = `true`** as an environment variable.
   It fails closed: absent, empty or unparseable means nothing happens. Test that on the bench
   before deploying — set it to `banana` and confirm the script refuses to act.

See [README §6](README.md#6-deploying-the-opt-in-spin-off-scripts) for each script's full gate list
and cooldowns.

---

## 8. Troubleshooting

| Symptom | Most likely cause |
|---|---|
| Every device reports `HealthScore = -1` | Scripts not assigned, not running as SYSTEM, or Part 3 running before Parts 1 and 2. Check `ScoreComplete` and the three `PartNRunTime` values. |
| `HealthReason = IncompleteSweep` on many devices | Scheduling. Part 3 must run at least 15 minutes after Parts 1 and 2, and within 26 hours of them. |
| Sensors return fallbacks but the sweep clearly ran | Sensor running in User context, or declared with the wrong response data type. |
| Sensors disagree with each other | Normal briefly — sensors read a cache that advances in sweep-sized steps. Persistent disagreement means a part is failing partway; check for a missing `PartNRunTime`. |
| A whole ring reports `ManagementServerUnreachable` at once | Server-side or network. Nothing in this folder will clear it. |
| `NoManagementGroup` on devices that should be monitored | Often a Log Analytics / Azure Monitor install of the same MMA binary rather than a broken SCOM agent. Cross-reference `scom_agent_version`. |
| Script times out in UEM | Almost always Part 2 on slow storage. Raise its timeout; do not lower `$EventLookbackHours` first. |

Full troubleshooting reference: [README §11](README.md#11-troubleshooting).
