# SCOM Agent Health — DEX Deployment Guide

> **Scope:** This guide covers deploying the System Center Operations Manager agent health
> scripts in this folder via **Omnissa Workspace ONE UEM** and surfacing results in
> **Workspace ONE DEX**.

## Start here — pick a deployment

This README is the full reference for everything in the folder. If you are deploying rather than
reading, start with one of the two step-by-step guides instead. Each is self-contained and includes
a local test procedure.

| Guide | Deploy | Coverage | Choose it when |
|---|---|---|---|
| **[Solution A — Sweep + Sensors](DEPLOY-A-Sweep-Plus-Sensors.md)** | 3 scripts + 7 sensors | **14 of 14 checks**, 235-point score, 2 auto-remediations | Default. The only option that sees connectivity and event-log faults. |
| **[Solution B — Sensors Only](DEPLOY-B-Sensors-Only.md)** | 9 sensors | 8 of 14 checks, 130-point score, no remediation | You cannot deploy scripts — no permission, change freeze, locked-down ring, or a quick evaluation. |

**Deploy one or the other, never both.** Six of Solution B's sensors report the same attributes as
Solution A's cached set under different names; running both doubles the sensor queue for one number
and gives you two columns that disagree at the edges.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Script Summary and Deployment Order](#2-script-summary-and-deployment-order)
3. [Deployment Settings — All Scripts](#3-deployment-settings--all-scripts)
4. [Deploying the Main Health Sweep](#4-deploying-the-main-health-sweep)
5. [DEX Sensors — Capturing Results](#5-dex-sensors--capturing-results)
6. [Deploying the Opt-In Spin-Off Scripts](#6-deploying-the-opt-in-spin-off-scripts)
7. [VDI, Horizon, AVD and Golden Images](#7-vdi-horizon-avd-and-golden-images)
8. [Recommended DEX Dashboards and Alerts](#8-recommended-dex-dashboards-and-alerts)
9. [Suggested Rollout Rings](#9-suggested-rollout-rings)
10. [Tunable Reference](#10-tunable-reference)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Overview

This folder contains six deployable PowerShell scripts and eight sensors that detect and remediate common
Operations Manager agent (`HealthService` / Microsoft Monitoring Agent) health problems. They
follow the same step-engine pattern used across all DEX solution scripts: each step returns
`Passed`, `Warning`, or `Failed`, remediations run automatically where safe, and the script exits
`0` (all passed) or `1` (at least one step failed) so Workspace ONE UEM can report compliance
state and DEX can trend it.

### Scope — agent side only

**Read this before deploying anything here.** These scripts run on the monitored endpoint. They
never touch a management server, a gateway, or the operational database. Where a failure is
genuinely server-side — the agent was never approved, the SPN is wrong, the channel certificate
has expired, the management server is down — the step says so explicitly and takes **no action**.

That boundary is the point, not a limitation. A device-side script cannot fix a management group
problem, and a script that pretends otherwise produces a green dashboard over a grey agent. When
a reason like `ManagementServerUnreachable` or `AgentNotRegistered` appears across many devices
at once, that is a management-group or PKI incident and nothing in this folder will clear it —
escalate to whoever owns the SCOM infrastructure.

### Architecture — two tiers

```
Tier 1 — Run fleet-wide (low blast radius)
  Invoke-AutoRemediateSCOMAgentPart1.ps1            <- steps 1-5, auto-remediates 1 & 4
  Invoke-AutoRemediateSCOMAgentPart2.ps1            <- steps 6-10, report only
  Invoke-AutoRemediateSCOMAgentPart3.ps1            <- steps 11-14 + health score. RUNS LAST
  Invoke-AutoRemediateSCOMAgent.ps1                 <- combined reference copy, NOT deployable (48,336 chars)

Tier 2 — Deploy to targeted rings only (opt-in, higher impact)
  Invoke-AutoRemediateSCOMHealthServiceCache.ps1    <- State flush (DESTRUCTIVE)
  Invoke-AutoRemediateSCOMMonitoringHost.ps1        <- Agent recycle
  Invoke-AutoRemediateSCOMClonedIdentity.ps1        <- Identity reset (DESTRUCTIVE, highest blast radius)

Sensors — read what Tier 1 caches, no independent detection logic
  Sensors/*.ps1              <- recurring, <2s cache readers (deployable today)
  OneTimeSensor/*.ps1        <- heavier one-shot JSON sensor (needs the DEX one-time sensor run capability)
```

Use the DEX sensor values written by the main sweep to decide which devices need a Tier 2 script —
target by signal, not by collection.

### The MMA / Log Analytics caveat

`HealthService.exe` — the Microsoft Monitoring Agent — is the **same binary** used by the Azure
Log Analytics agent (formerly OMS). A device can therefore have the agent installed, report a
valid `scom_agent_version`, and be reporting to a Log Analytics workspace rather than to any SCOM
management group at all.

On such a device the sweep reports `NoManagementGroup`, which is correct but not actionable: there
is no SCOM management group because the agent was never meant to have one. **Filter these out
before treating `NoManagementGroup` as a fleet problem.** The cleanest discriminator is
`scom_agent_health_reason` = `NoManagementGroup` combined with a non-empty `scom_agent_version` —
that pairing means "agent present, not a SCOM agent". Confirm against your Azure Monitor
inventory before acting.

None of the Tier 2 scripts should be pointed at a Log Analytics-only device. `ClonedIdentity` in
particular would reset an identity that no SCOM management group is tracking.

---

## 2. Script Summary and Deployment Order

| Script | Tier | Auto-Remediates | Deploy When |
|---|---|---|---|
| `Invoke-AutoRemediateSCOMAgentPart1.ps1` | 1 | Service start, DNS flush | Always — deploy first |
| `Invoke-AutoRemediateSCOMAgentPart2.ps1` | 1 | Nothing | Always — deploy alongside Part 1 |
| `Invoke-AutoRemediateSCOMAgentPart3.ps1` | 1 | Nothing (computes the score) | Always — **schedule after Parts 1 and 2** |
| `Invoke-AutoRemediateSCOMHealthServiceCache.ps1` | 2 | Health Service State flush | Sweep reports stale config, ESENT errors, or oversized state |
| `Invoke-AutoRemediateSCOMMonitoringHost.ps1` | 2 | Agent service recycle | Sweep reports sustained high CPU/RAM footprint |
| `Invoke-AutoRemediateSCOMClonedIdentity.ps1` | 2 | Agent identity reset | Sweep reports registration rejection on a confirmed clone |

Deploy **all three Tier 1 parts first**, with Part 3 scheduled last. Let them run for at least 24 hours and use its sensor output to build
targeted smart groups before deploying any Tier 2 script. Deploying a Tier 2 script fleet-wide
defeats the entire design.

If deploying scripts is not an option on your fleet, `Sensors/Standalone/` gives you a
sensors-only deployment that measures the device directly — at the cost of every check that needs
a network call or an event log query. See [§5](#standalone-sensors--no-sweep-script-required).

---

## 3. Deployment Settings — All Scripts

These settings apply to every script in this folder unless the individual section below
overrides them.

| UEM Setting | Value |
|---|---|
| Script Type | PowerShell |
| Execution Context | System |
| Architecture | x64 |
| PowerShell Version | 5.1 |
| Run As | SYSTEM |
| Show Script Output | Enabled (for troubleshooting) |

> **Never run these in User context.** Service control, the `Operations Manager` event log, the
> agent install directory, and `HKLM\SOFTWARE\Microsoft\Microsoft Operations Manager` all require
> SYSTEM or local Administrator. User context produces empty results or access-denied exceptions.

### AV/EDR exclusion — required for Tier 2

All three Tier 2 scripts use a launcher/payload pattern: the UEM-delivered script copies itself to
`C:\ProgramData\AirWatch\Extensions\SCOM`, registers a one-shot SYSTEM scheduled task, and exits
in about 5 seconds so the real work happens outside UEM's timeout window.

**If your AV or EDR product blocks script execution from that path, the payload silently no-ops.**
The launcher will still report success, because from its point of view dispatch succeeded. Add the
exclusion before deploying, then confirm on a pilot device that the `Status` value under
`HKLM:\Software\AirWatch\Extensions\SCOM\<ScriptName>` advances past `Dispatched`.

---

## 4. Deploying the Main Health Sweep

### The sweep ships as three script objects

The 14-step sweep is **48,336 characters against UEM's 32,767-character script limit**, so it is
split into three script objects that share one registry cache:

| Script | Steps | Size | Auto-remediates |
|---|---|---:|---|
| `Invoke-AutoRemediateSCOMAgentPart1.ps1` | 1–5 | 22,350 | Service start, DNS flush |
| `Invoke-AutoRemediateSCOMAgentPart2.ps1` | 6–10 | 26,090 | Nothing |
| `Invoke-AutoRemediateSCOMAgentPart3.ps1` | 11–14 | 27,705 | Nothing — **also computes the health score** |

`Invoke-AutoRemediateSCOMAgent.ps1` is the combined original. It is **kept as the reference
implementation and is not deployable** — it exceeds the limit. Do not assign it.

> **Part 3 must run last.** It measures only steps 11–14 itself and reads every other metric back
> from the registry, where Parts 1 and 2 cached it. Schedule Part 1 and Part 2 first, then Part 3
> at least 15 minutes later.

**What happens if Part 3 runs first, or Parts 1/2 fail:** Part 3 detects that `Part1RunTime` or
`Part2RunTime` is missing or older than `$StalePartHours` (26h) and publishes
`HealthScore = -1` / `HealthReason = IncompleteSweep` rather than a partial score. That is
deliberate — missing metrics cannot deduct, so a partial score is always *too high*, and caching
it would tell every sensor the agent is healthier than anyone measured. `ScoreComplete = 0` records
the condition.

**UEM Script Configuration (all three)**

| Setting | Value |
|---|---|
| Execution Context | System |
| Trigger | Scheduled — every 24 hours |
| Assignment | All managed Windows devices |

| Script | Name | Timeout |
|---|---|---|
| Part 1 | `[DEX] SCOM Agent Health — Part 1 (Connectivity)` | 60 seconds |
| Part 2 | `[DEX] SCOM Agent Health — Part 2 (State & Events)` | 90 seconds |
| Part 3 | `[DEX] SCOM Agent Health — Part 3 (Certs & Score)` | 60 seconds |

Part 2 carries the event-log work — one bucketed pass over the `Operations Manager` log shared by
steps 9 and 10, plus a guarded ESENT query for step 7 — so it gets the longest timeout.

**Assignment note:** assign to *all* Windows devices, not just those with the agent. Each part has
a guard clause that exits `0` immediately when there is no `HealthService` service and no agent
registry root, and writes `AgentInstalled = 0` / `HealthScore = -1` so unmonitored devices are
identifiable in DEX rather than simply absent.

**Environment variables (all three)**

| Variable | Effect |
|---|---|
| `WhatIf` = `true` | Dry run — detection only, no remediation. Absent or unparseable means a live run. |

**What Part 1 remediates automatically:**

| Step | Auto-Action |
|---|---|
| 1 — HealthService Service State | Sets start type to Automatic and starts the service (skipped if an agent install is in progress) |
| 4 — Management Server Connectivity | Flushes DNS only — the local half of the problem. An MS outage is server-side. |

Parts 2 and 3 remediate nothing at all. Steps 3, 5, 6, 7, 8 and 9 name the Tier 2 spin-off that
would address them; everything else is informational or explicitly someone else's to fix (step 11
is PKI-owned; step 13 cross-references `GenericTroubleshooting/TimeSyncHealth`).

**Registry keys written per part**

| Part | Writes |
|---|---|
| 1 | `ManagementServer`, `ManagementGroupCount`, `ConfigAgeHours`, `MsReachable`, `ServiceRunning`, `Part1*` |
| 2 | `StateFolderMB`, `StoreDbMB`, `StoreDbErrors24h`, `RuntimeMemoryMB`, `RuntimeCpuPercent`, `MonitoringHostCount`, `ConnectFailures24h`, `AuthFailures24h`, `NotRegistered24h`, `UnloadedWorkflows24h`, `ScriptFailures24h`, `Part2*` |
| 3 | `CertExpiryDays`, `AgentVersion`, `TimeSkewSeconds`, `Part3*`, and the aggregate: `Status`, `HealthScore`, `HealthReason`, `Passed`, `Warnings`, `Failed`, `RemediationsRun`, `ScoreComplete`, `LastRunTime` |

**Exit Codes (per part)**

| Exit Code | Meaning in DEX |
|---|---|
| `0` | All that part's steps passed or warned — or no agent installed |
| `1` | At least one step in that part failed |

---
## 5. DEX Sensors — Capturing Results

The sweep writes every metric to `HKLM:\Software\AirWatch\Extensions\SCOM`. The sensors in
`Sensors/` are **pure cache readers** — they contain no detection logic of their own, make no
network calls, and complete in well under 2 seconds. That split is deliberate: sensors are
serialized fleet-wide, so a sensor that did its own event-log mining would block every other
sensor behind it on every sample interval.

**Every sensor in `Sensors/` depends on the three Tier 1 parts being scheduled.** Without them they
all return their fallback values forever. Set the sensor sample schedule to match or lag the sweep
schedule — sampling more often than the sweep runs just re-reads the same cached values.

If you do not want to deploy the sweep scripts at all, `Sensors/Standalone/` measures the device
directly instead. See [Standalone sensors](#standalone-sensors--no-sweep-script-required) below for
what that costs you.

| Sensor | Type | Fallback | Reports |
|---|---|---|---|
| `scom_agent_health_score.ps1` | Integer | `-1` | Composite health, 0–100 |
| `scom_agent_health_reason.ps1` | String | `""` | Largest single deduction from the score |
| `scom_management_server_reachable.ps1` | Boolean | *(no sample)* | MS answered on its configured port at the last sweep |
| `scom_agent_version.ps1` | String | `""` | Four-part agent file version |
| `scom_config_age_hours.ps1` | Integer | `-1` | Hours since the connector config cache was written |
| `scom_state_folder_mb.ps1` | Integer | `-1` | Health Service State folder size |
| `scom_monitoringhost_memory_mb.ps1` | Integer | `-1` | HealthService + MonitoringHost combined working set |

### Reading the sentinels

**`-1` is not a low score.** For every Integer sensor here, `-1` means *not measured* — no agent
installed, or that metric could not be read. It is a different fact from a genuine bad reading.

Filter `-1` out **before** averaging or ranking anything. A fleet of healthy devices that simply
never had the agent installed will otherwise drag every average down and make the dashboard
meaningless.

`scom_management_server_reachable` deliberately emits **no value at all** when it cannot tell,
rather than `$false`. Any boolean fallback would be a lie — `$false` reads as a real "the
management server is down" finding, and a missing cache means the sweep has not run, not that the
management group is broken.

### Health reason values

Ordered by deduction weight. The score is `100` minus every deduction that applies; the reason is
the single largest one.

| Reason | Points | Owner |
|---|---|---|
| `HealthServiceStopped` | 40 | Device — Tier 1 auto-remediates |
| `ManagementServerUnreachable` | 25 | **Server / network** |
| `AgentNotRegistered` | 25 | **Server** — approval or ClonedIdentity |
| `NoManagementGroup` | 20 | Server — or a Log Analytics-only agent (see §1) |
| `ConnectorAuthenticationFailure` | 20 | **Server** — Kerberos/SPN or cert trust |
| `HealthServiceStoreCorruption` | 20 | Device — HealthServiceCache |
| `ConfigurationCacheStale` | 15 | Device — HealthServiceCache |
| `AgentRuntimeFootprintHigh` | 15 | Device — MonitoringHost |
| `ChannelCertificateProblem` | 15 | **PKI** |
| `TimeSkew` | 15 | Device — see `GenericTroubleshooting/TimeSyncHealth` |
| `WorkflowsUnloaded` | 10 | Mixed — usually management pack authoring |
| `HealthServiceStateOversized` | 10 | Device — HealthServiceCache |
| `MultiHomedAgent` | 5 | Config — intentional or not, confirm on end-user devices |
| `IntermittentConnectivity` | 5 | Mixed |
| `Healthy` | — | — |
| `NoAgentInstalled` | — | Not a fault — exclude from all reporting |
| `IncompleteSweep` | — | Part 1 or 2 has not run in 26h. **Not a health finding** — a scheduling fault. Score is `-1`. |

Rows marked **Server** or **PKI** will not improve no matter what you deploy from this folder.

### Standalone sensors — no sweep script required

`Sensors/Standalone/` holds a second, independent set that measures the device directly at sample
time. No registry cache, no scheduled script, nothing to deploy but the sensor itself. Use this set
when you want SCOM agent visibility in DEX without putting the Tier 1 sweep on the fleet.

**Deploy one set or the other, never both.** Where a standalone sensor has a cached twin, the two
report the same attribute under different names — running both doubles the sensor queue for one
number and gives you two columns that will disagree at the edges.

| Standalone sensor | Type | Fallback | Cached twin |
|---|---|---|---|
| `scom_agent_health_score_standalone.ps1` | Integer | `-1` | `scom_agent_health_score.ps1` |
| `scom_agent_health_reason_standalone.ps1` | String | `""` | `scom_agent_health_reason.ps1` |
| `scom_agent_version_standalone.ps1` | String | `""` | `scom_agent_version.ps1` |
| `scom_config_age_hours_standalone.ps1` | Integer | `-1` | `scom_config_age_hours.ps1` |
| `scom_state_folder_mb_standalone.ps1` | Integer | `-1` | `scom_state_folder_mb.ps1` |
| `scom_monitoringhost_memory_mb_standalone.ps1` | Integer | `-1` | `scom_monitoringhost_memory_mb.ps1` |
| `scom_healthservice_running_standalone.ps1` | Boolean | *(no sample)* | **none — new** |
| `scom_management_group_count_standalone.ps1` | Integer | `-1` | **none — new** |
| `scom_cert_expiry_days_standalone.ps1` | Integer | `-1` | **none — new** |

The last three have no cached equivalent. The sweep records all three metrics but exposes them only
through the health score, so these are additions rather than replacements — and they are the three
most useful standalone signals, because each one is a fault the score alone will not name.

There is deliberately **no standalone `scom_management_server_reachable`**. Answering it means
opening a TCP connection to the management server, and a recurring sensor must not make network
calls — it runs on every device on every sample interval, and the sensor queue is serialized. That
sensor stays cache-backed, or you use the one-time sensor below.

#### What the standalone score cannot see

This is the part worth reading before choosing. `scom_agent_health_score_standalone` uses the same
point values, the same thresholds and the same reason names as the sweep, over a strictly smaller
set of rules:

| Deduction | Points | Standalone | Why |
|---|---:|---|---|
| `HealthServiceStopped` | 40 | ✅ | Service query |
| `ManagementServerUnreachable` | 25 | ❌ | Needs a socket probe |
| `AgentNotRegistered` | 25 | ❌ | Needs the Operations Manager event log |
| `NoManagementGroup` | 20 | ✅ | Registry |
| `ConnectorAuthenticationFailure` | 20 | ❌ | Needs the Operations Manager event log |
| `HealthServiceStoreCorruption` | 20 | ❌ | Needs the ESENT event log |
| `ConfigurationCacheStale` | 15 | ✅ | File timestamp |
| `AgentRuntimeFootprintHigh` | 15 | ✅ | Process query |
| `ChannelCertificateProblem` | 15 | ✅ | Certificate store |
| `TimeSkew` / `TimeSyncStale` | 15 | ⚠️ | Sync **age**, not measured skew — see below |
| `WorkflowsUnloaded` | 10 | ❌ | Needs the Operations Manager event log |
| `HealthServiceStateOversized` | 10 | ✅ | Folder size |
| `MultiHomedAgent` | 5 | ✅ | Registry |
| `IntermittentConnectivity` | 5 | ❌ | Needs the Operations Manager event log |

The sweep can deduct **235** points. The standalone set can deduct **130**.

**So a standalone `100` means "no locally visible fault", not "healthy".** A device that cannot
reach its management server at all — the single most common real finding on a laptop fleet — still
scores 100 here. Every event-log-derived signal is missing for the same reason: a `Get-WinEvent`
pass costs seconds, and sensors have a 5-second budget they share with every other sensor on the
device.

Two reason values differ from the cached set on purpose, so the two datasets can never be silently
pooled:

- **`HealthyLocal`** instead of `Healthy` — it means nothing local is wrong, which is a weaker
  claim.
- **`TimeSyncStale`** instead of `TimeSkew` — the sweep measures real clock offset with `w32tm.exe`;
  a sensor may not launch a process, so the standalone version reads the age of the last successful
  sync from the registry instead. Related signal, different measurement, different name.

#### Recommended use

Run `OneTimeSensor/scom_agent_health.ps1` **once** against the same fleet. It does the full
fourteen-step assessment in a single collection, and the gap between its `HealthScore` and the
standalone score is a direct measurement of what you are giving up. If that gap is small on your
fleet, the standalone set is enough. If it is large, deploy the sweep.

One runtime note: `scom_state_folder_mb_standalone` is the only sensor here with an unbounded worst
case, because it walks the state folder subtree. In practice it returns in well under a second —
state-folder bloat is almost always a handful of very large files, not a large file count — but on
a fleet known to have deep per-workflow cache sprawl, use the cached twin instead. A script has the
budget for that walk; a sensor does not.
### One-time sensor — `OneTimeSensor/scom_agent_health.ps1`

> **This is not deployable as a recurring sensor and is not usable until the DEX/Workspace ONE
> Intelligence one-time ("run-once") sensor capability ships.** It is kept in a separate folder
> specifically so nobody schedules it by mistake.

It returns the entire agent picture — every metric above plus failover server count, store DB
size, per-category event counts, certificate expiry, and a `Findings` array — as one compact JSON
object. It is fully self-contained: it does its own detection and reads no cache, so it works on a
device where the sweep has never run.

It mines the `Operations Manager` event log and makes a real TCP probe to the management server,
which is why it must stay one-time only. It self-enforces a 25-second deadline under the 30-second
UEM hard ceiling; phases skipped by that deadline report `-4` and `TimedOut` is set `true`.

**When `TimedOut` is `true`, treat `HealthScore` as a floor, not a verdict** — whatever the skipped
phases would have deducted is missing from it. Filter on `TimedOut` before trending, the same way
you filter on `-1`.

Use it for a single on-demand pull against one device or a small set. Use the sweep plus `Sensors/`
for continuous fleet reporting.

---

## 6. Deploying the Opt-In Spin-Off Scripts

Each spin-off should be deployed as a **separate script** against a **targeted smart group** built
from the sensor data in section 5. Deploy to a pilot ring first, observe sensor values the
following day, then expand.

All three share the launcher/payload pattern described in section 3 — **the AV/EDR exclusion is a
prerequisite, not an optimisation.**

### The `ConfirmHighImpact` gate

`HealthServiceCache` and `ClonedIdentity` are marked **DESTRUCTIVE** and will do nothing at all
unless the `ConfirmHighImpact` environment variable is set to `true` on the UEM script object.

The gate **fails closed**: absent, empty, or unparseable all mean "do nothing". Setting it to
`banana` is exactly as safe as not setting it. When the gate blocks, the script still runs full
detection and reports what it *would* have done, so you can review the finding before granting
confirmation.

This is a deliberate second key. Targeting the right smart group is the first.

---

### 6.1 Health Service State Flush — **DESTRUCTIVE**

**Script:** `Invoke-AutoRemediateSCOMHealthServiceCache.ps1`

| UEM Setting | Value |
|---|---|
| Name | `[DEX] SCOM - Flush Health Service State` |
| Timeout | 120 seconds (launcher only — the payload runs up to 15 minutes as a scheduled task) |
| Trigger | On-demand / Freestyle (not scheduled) |
| Environment | `ConfirmHighImpact` = `true` (**required**), `WhatIf` = `true` for a dry run |

**Target smart group — build from `scom_state_folder_mb` and `scom_agent_health_reason`:**
- `scom_state_folder_mb` greater than `1536`, **or**
- `scom_agent_health_reason` equals `HealthServiceStoreCorruption` or `ConfigurationCacheStale`

**What it does:** stops HealthService, renames the `Health Service State` folder, starts the
service, and waits for the agent to re-download its configuration from the management server.
Rename-then-delete, not delete — if the service fails to start, the original folder is restored.

**Gates that must all pass before it acts:**

1. `ConfirmHighImpact` is `true`
2. An agent is installed and no install is in progress
3. **The management server answers on its configured port** — flushing an agent that cannot
   re-provision leaves it permanently grey. This gate is why the script refuses to run during an
   MS outage, which is precisely when a stale-config alert storm would tempt you to run it.
4. A real signal is present: stale configuration, ESENT store errors, or an oversized state folder
5. The 7-day cooldown has elapsed on this device

**Staggered deployment — critical:**
Every flushed agent re-downloads its full configuration from the management group. Deploying
simultaneously to a large collection creates a synchronised load spike on the management servers
*and* the operational database — the same failure mode as a mass DP re-download in SCCM.

Use UEM's deployment time window with randomisation enabled, or split into rings:
- Ring 1: devices above 3000 MB — deploy immediately
- Ring 2: devices 1536–3000 MB — deploy 48 hours later

**Why it is never run fleet-wide:**

- Deleting Health Service State forces the agent to re-download its **entire** configuration from
  the management server. One device is trivial. A collection of them at once is a synchronised
  config-distribution spike against the management group and its operational database — the
  endpoints look healthier while the management infrastructure absorbs the cost.
- The state store holds unsent data. Anything queued and not yet uploaded — performance samples,
  alerts, discovery data — is discarded permanently. There is no way to recover it, and the console
  will show a gap for that window.
- An agent that cannot reach its management server at the moment of the flush is left with **no**
  configuration and no way to obtain one. It stops monitoring entirely and goes grey until
  connectivity returns. Gate 3 exists solely to prevent this, and it is not optional.
- **On a multi-homed Microsoft Monitoring Agent this folder is shared with the Log Analytics /
  Azure Monitor side of the agent.** Flushing it resets that workload too, whether or not you
  intended to touch it. Check before deploying to any device that also reports to a Log Analytics
  workspace.

**What it does not do:** no agent repair, reinstall, or re-registration. If a flush does not fix
the device, that is an escalation — not a reason to escalate the action taken. Identity problems
belong to `Invoke-AutoRemediateSCOMClonedIdentity.ps1`.

> **Warning:** This deletes accumulated agent state, including queued data the agent had not yet
> uploaded. That data is lost. Confirm the management server is healthy first.

---

### 6.2 Agent Recycle

**Script:** `Invoke-AutoRemediateSCOMMonitoringHost.ps1`

| UEM Setting | Value |
|---|---|
| Name | `[DEX] SCOM - Recycle Agent` |
| Timeout | 120 seconds (launcher only — the payload runs up to 10 minutes as a scheduled task) |
| Trigger | Scheduled — daily, or on-demand |
| Environment | `WhatIf` = `true` for a dry run |

**Target smart group — build from `scom_monitoringhost_memory_mb`:**
- Value greater than `500`, or `scom_agent_health_reason` equals `AgentRuntimeFootprintHigh`

**No `ConfirmHighImpact` gate, and that is intentional.** Recycling restarts only the agent's own
service. Nothing else on the device depends on it, no data is at risk, and the agent rebuilds
its runtime state on start. Gating it behind the same key as a state flush would train
administrators to set `ConfirmHighImpact` reflexively — which is exactly what must not happen
for the two scripts that genuinely destroy data.

**What replaces the gate:**

1. **Two independent load samples**, 45 seconds apart. A single CPU reading proves nothing — a
   management pack discovery cycle legitimately spikes the agent.
2. **A once-per-day cap** (20-hour cooldown), so a device with a genuinely heavy management pack
   load is not recycled in a loop.
3. Agents that started in the last 15 minutes, or received configuration in the last 15 minutes,
   are skipped — that load burst is expected and recycling would restart the cycle.

**What to watch for:** a device that keeps qualifying day after day is not a device the recycle
will fix. It is a management pack scoping problem — the agent is doing the work it was told to do.
Look at what is targeted at that device before recycling it again.

---

### 6.3 Cloned Identity Reset — **DESTRUCTIVE, HIGHEST BLAST RADIUS**

**Script:** `Invoke-AutoRemediateSCOMClonedIdentity.ps1`

| UEM Setting | Value |
|---|---|
| Name | `[DEX] SCOM - Reset Cloned Agent Identity` |
| Timeout | 120 seconds (launcher only — the payload runs up to 15 minutes as a scheduled task) |
| Trigger | On-demand only |
| Environment | `ConfirmHighImpact` = `true` (**required**), `WhatIf` = `true` for a dry run |

**Target smart group — build from `scom_agent_health_reason`:**
- Equals `AgentNotRegistered`, **and** the device is a known clone from a golden image

**Read section 7 before deploying this to anything.**

**The problem this solves:** an Operations Manager agent's identity lives in its Health Service
State folder, **not** in its registry configuration. Capture a golden image with the agent already
installed *and started*, and every machine deployed from that image inherits the same agent
identity. The management server accepts one of them and rejects the rest — so a VDI pool or a
freshly imaged laptop fleet shows a rotating set of grey agents that no amount of restarting
fixes. Each device looks individually healthy while the management group sees one flapping
computer.

The correct fix is upstream: capture the image with the agent installed but its state folder
absent, or install the agent post-deployment. **This script exists for the fleet that has already
been deployed from a bad image.**

**What it does:** stops the agent, removes the image-baked Health Service State that carries the
parent image's identity, and lets the agent re-register with the management group under its own.

**Why it is never run fleet-wide:**

- Resetting identity discards all agent state and forces a fresh registration. Run against a
  healthy fleet it produces a wave of new registrations *and* a wave of orphaned records
  server-side.
- **A device-side script cannot see that another device shares its identity.** It can only observe
  that this agent is being rejected *and* that its state predates this machine. That is strong
  circumstantial evidence, not proof — which is why both signals are required and the confirmation
  gate is mandatory.
- On non-persistent VDI it is the wrong tool entirely (section 7).

**It requires two independent confirmations, and either one alone aborts:**

1. **Image-baked state detection** — the agent state predates the OS install (beyond a 30-minute
   grace window), meaning it came from the image rather than from this machine's own registration.
2. **Rejection evidence** — at least 3 management server rejection events in the last 24 hours.
   The management group is actively refusing this agent.

Both must be true. Image-baked state alone is common and harmless on a machine that later
re-registered successfully. Rejection events alone usually mean an approval problem, not a clone —
and resetting identity would not fix it.

> **The management server may still need an administrator.** A reset makes the agent request
> registration under its correct identity, but if your management group requires manual approval,
> or the stale duplicate registration is still present server-side, someone with console access
> must approve the new agent and clean up the old record. **This script cannot do that half of the
> job**, and on a management group with manual approval it will leave the device pending until
> someone acts.

---

## 7. VDI, Horizon, AVD and Golden Images

The agent behaves differently on non-persistent infrastructure, and two of the Tier 2 scripts are
actively wrong there.

### Non-persistent VDI — fix the parent image, not the session

**`Invoke-AutoRemediateSCOMClonedIdentity.ps1` is the wrong tool for non-persistent VDI.** If
sessions are recreated from a golden image on every logoff, resetting identity inside a session
buys you nothing — the reset is discarded with the session, and the next session boots with the
same image-baked state and the same problem. You will see the same devices qualify forever.

The fix belongs in the image: stop the agent and clear `Health Service State` **before** sealing,
so every clone starts without a baked identity. Run the reset script once against the image
during preparation if you need to, then reseal.

Use `ClonedIdentity` on **persistent** VDI, physical clones, and re-imaged machines — anywhere the
reset actually survives.

### Agent footprint is multiplied by session density

On a Horizon or AVD session host, `scom_monitoringhost_memory_mb` is per-session, and the host pays
for all of them at once. An agent footprint that is unremarkable on a laptop is real host memory
pressure at 40 sessions. This usually surfaces as a host capacity problem rather than as a SCOM
problem, which is why it is easy to miss.

The recycle script helps at the margin, but the durable fix is management pack scoping — do not
target desktop-oriented management packs at session hosts.

### State folder size is real capacity

`Health Service State` on a small-disk VDI or a thin laptop is genuine capacity, not just a number.
The 1536 MB default threshold is a fleet-wide compromise; on a 40 GB non-persistent disk it is
already far too generous. Fork the script object with a lower `$StateFolderWarnMB` for those rings
rather than lowering it fleet-wide.

### Multi-homing

`MultiHomedAgent` is only a 5-point deduction because multi-homing is legitimate. But every
management group runs its **full workflow set independently** — two groups means double the CPU,
memory, and disk for the same monitoring. On an end-user device, and especially on a session host,
confirm that was intended.

---

## 8. Recommended DEX Dashboards and Alerts

### Suggested Custom Attributes to Promote

| Attribute | Source Sensor | Threshold for Alert |
|---|---|---|
| SCOM Agent Health Score | `scom_agent_health_score` | `< 70` → warning, `< 40` → critical (**exclude `-1`**) |
| SCOM Health Reason | `scom_agent_health_reason` | Group by value; exclude `NoAgentInstalled` |
| Management Server Reachable | `scom_management_server_reachable` | `False` → alert (see fleet-wide note below) |
| Agent Version | `scom_agent_version` | Group by exact value to find outliers |
| Config Age (hours) | `scom_config_age_hours` | `> 24` → warning (**exclude `-1`**) |
| State Folder MB | `scom_state_folder_mb` | `> 1536` → warning (**exclude `-1`**) |
| Agent Memory MB | `scom_monitoringhost_memory_mb` | `> 500` → warning (**exclude `-1`**) |

> **Version sorting:** `scom_agent_version` is a String, and string comparison does not order
> versions correctly — `10.19.10552.0` sorts *below* `10.19.1082.0`. Group by exact value rather
> than filtering on greater-than.

### Alert on the fleet shape, not the device

The most useful SCOM alert is not "this device is unhealthy" — it is **"many devices became
unhealthy for the same reason at the same time."**

Configure a rate-of-change alert on the *count* of devices reporting each server-side reason:

- `ManagementServerUnreachable` count spikes → management server or network incident
- `ConnectorAuthenticationFailure` count spikes → Kerberos/SPN or certificate trust change
- `ChannelCertificateProblem` count spikes → a PKI batch is expiring
- `AgentNotRegistered` count spikes → approval policy change, or an image rollout carrying a
  baked identity

Per-device alerts on these reasons will generate noise proportional to your fleet size and point
every one of them at a device that cannot fix itself.

### DEX Experience Score Impact

The main sweep exits `1` when any step hard-fails, which UEM surfaces as a non-compliant script
run. Map this to a DEX **experience factor** to let agent health influence the device score:

1. In DEX, go to **Experience → Experience Factors → Add Factor**
2. Source: the `[DEX] SCOM Agent Health Sweep` script compliance state
3. Weighting: start at 5–10% and adjust based on how predictive it proves for your fleet

Weight this lower than you would SCCM client health. A broken SCOM agent degrades *your visibility
into* the device; a broken SCCM client degrades the device itself.

---

## 9. Suggested Rollout Rings

| Ring | Scope | What to Validate |
|---|---|---|
| Pilot (1–5%) | IT devices, volunteered users | Script output readable, sensors returning expected values, guard clause exits cleanly on devices with no agent |
| Ring 1 (10%) | Representative sample across models, OS builds, and at least one VDI pool | Exit code distribution, `-1` rate (how many devices have no agent), health score distribution |
| Ring 2 (50%) | Broad fleet minus session hosts | At-scale management server load; confirm no reason value dominates unexpectedly |
| Production (100%) | All Windows managed devices | Ongoing via DEX dashboard |

Wait at least **24 hours** between rings and collect sensor data after each before expanding.

**For Tier 2 scripts, ring sizes should be far smaller** — start with a handful of named devices,
verify the cached `Status` value and the script log at
`%SystemRoot%\Temp\UEM_AutoRemediateSCOM*.log`, and only then expand to tens. A `HealthServiceCache`
rollout that is too broad is a self-inflicted management server outage.

---

## 10. Tunable Reference

The tunables block at the top of each script controls detection thresholds. They are hard-coded
deliberately: UEM variables are per-script-object, not per-assignment, so exposing them would give
no real deployment flexibility. **Fork the script object if a ring needs different values** — this
is the supported way to give VDI a lower state-folder threshold than laptops.

### `Invoke-AutoRemediateSCOMAgent.ps1`

| Variable | Default | When to Change |
|---|---|---|
| `$StartupDelayWarnSeconds` | `300` | Increase for encrypted disks or heavy logon script chains that legitimately delay service start |
| `$ConfigStaleHours` | `24` | Match your management pack change cadence; a stable group legitimately shows older caches |
| `$StateFolderWarnMB` | `1536` | **Lower for VDI and small-disk laptops.** 1536 MB is a fleet-wide compromise |
| `$StoreDbWarnMB` | `768` | Lower alongside `$StateFolderWarnMB` on constrained disks |
| `$RuntimeMemoryWarnMB` | `400` | Raise for devices with genuinely heavy management pack scope; lower for session hosts |
| `$RuntimeCpuWarnPercent` | `15` | Average since process start, not instantaneous — a long-running agent will look calm |
| `$ConnectFailureWarnCount` | `5` | Lower on a stable LAN fleet; raise for mobile/VPN devices that legitimately drop |
| `$UnloadedWorkflowWarnCount` | `3` | Lower if you want earlier warning of management pack authoring problems |
| `$CertExpiryWarnDays` | `30` | Match your PKI renewal lead time |
| `$TimeSkewWarnSeconds` | `120` | Kerberos fails outright at 300s; leave headroom below that |
| `$SyncStaleHours` | `48` | Match your time service polling interval |
| `$NetTimeoutMs` | `3000` | Increase to 5000 on high-latency WAN or satellite links |
| `$EventLookbackHours` | `24` | Match the sweep schedule — a longer window than the schedule double-counts |
| `$MaxEventsScanned` | `2000` | Ceiling on the single event log pass; raise only if you also raise the UEM timeout |

### Part 3 only

| Variable | Default | When to Change |
|---|---|---|
| `$StalePartHours` | `26` | How old Part 1/Part 2 results may be before the score is published as `IncompleteSweep`. Slightly over 24h so a normal daily cycle never trips it; raise only if your parts run further apart. |

### `Invoke-AutoRemediateSCOMHealthServiceCache.ps1`

| Variable | Default | When to Change |
|---|---|---|
| `$ConfigStaleHours` | `24` | Keep aligned with the sweep's value or the two disagree about what "stale" means |
| `$StateFolderWarnMB` | `1536` | Keep aligned with the sweep's value |
| `$MinIntervalDays` | `7` | Cooldown. Raise it; lowering it means repeat flushes on a device whose real problem is elsewhere |
| `$ServiceStopTimeoutS` / `$ServiceStartTimeoutS` | `60` | Raise on slow disks where the agent is genuinely slow to stop or start |
| `$ConfigWaitSeconds` | `300` | How long to wait for re-download. Raise on high-latency links to a distant management server |
| `$ConfigPollSeconds` | `15` | Poll interval while waiting |
| `$BackupRetentionHours` | `24` | How long a rolled-back state folder is kept before cleanup |
| `$MaxRuntimeMinutes` | `15` | Self-enforced deadline for the scheduled-task payload |
| `$NetTimeoutMs` | `5000` | Management server probe. Longer than the sweep's, because a false negative here blocks the flush |

### `Invoke-AutoRemediateSCOMMonitoringHost.ps1`

| Variable | Default | When to Change |
|---|---|---|
| `$CpuWarnPercent` | `20` | Interval CPU across agent processes as a share of one machine |
| `$MemoryWarnMB` | `500` | Combined HealthService + MonitoringHost working set. Lower for session hosts |
| `$SampleIntervalSecs` | `45` | Gap between the two load samples. Shorter samples are more likely to catch the same transient twice |
| `$MinIntervalHours` | `20` | Cooldown — effectively once per device per day. Do not lower |
| `$RecentStartMinutes` | `15` | An agent this recently started is still loading configuration |
| `$ConfigFreshMinutes` | `15` | Config this recently downloaded means a load burst is expected |
| `$MaxRuntimeMinutes` | `10` | Self-enforced deadline for the payload |

### `Invoke-AutoRemediateSCOMClonedIdentity.ps1`

| Variable | Default | When to Change |
|---|---|---|
| `$RejectionLookbackHours` | `24` | Window searched for management server rejection events |
| `$MinRejectionCount` | `3` | Rejections needed before the evidence counts. Lowering this weakens the second confirmation |
| `$StateAgeGraceMinutes` | `30` | How much the agent state may legitimately predate OS install before it counts as image-baked |
| `$MinIntervalDays` | `14` | Cooldown. The longest of the three, because a repeat reset means the diagnosis was wrong |
| `$RegistrationWaitSecs` | `300` | How long to wait for re-registration. Raise if your management group has manual approval |
| `$MaxRuntimeMinutes` | `15` | Self-enforced deadline for the payload |

---

## 11. Troubleshooting

### `HealthScore = -1` with `HealthReason = IncompleteSweep`

Part 3 ran but Part 1 or Part 2 had not run inside 26 hours, so the score would have been computed
from a fraction of the metrics. This is a **scheduling fault, not a health finding** — the agent
may be perfectly fine.

Check `Part1RunTime`, `Part2RunTime` and `Part3RunTime` under
`HKLM:\Software\AirWatch\Extensions\SCOM`. The usual causes:

- Part 3 is scheduled at the same time as, or before, Parts 1 and 2. Stagger it at least 15 minutes later.
- Part 1 or Part 2 is not assigned to the device, or its assignment failed.
- Part 2 timed out. It carries the event-log pass and needs the longest timeout of the three.

`ScoreComplete = 0` records the same condition as a DWORD if you would rather alert on that.

### Sensors disagree with each other

Check `ScoreComplete` first. When it is `0`, `HealthScore` and `HealthReason` are sentinels while
the per-metric sensors (`scom_state_folder_mb`, `scom_config_age_hours`, and so on) still report
whatever their owning part last cached. That is intended — a stale per-metric value is still a real
measurement, while a partial *score* is not.
### Every device reports `HealthScore = -1`

The sweep has not run, or it ran and found no agent. Check `AgentInstalled` under
`HKLM:\Software\AirWatch\Extensions\SCOM` — `0` means the guard clause fired (no `HealthService`
service and no agent registry root), which is a correct result on an unmonitored device.

If `AgentInstalled` is absent entirely, the sweep never executed. Confirm the script is assigned,
running in **System** context, and that `LastRunTime` exists.

### Sensors return fallback values but the sweep clearly ran

The sensors read `HKLM:\Software\AirWatch\Extensions\SCOM` (the plural `Extensions`, matching the
VPN and logon sensor convention — **not** the `Extension` singular used by the SCCM scripts). If
you adapted a sensor from the SCCM folder, check that path first.

Then confirm the sensor is running in System context. A sensor in User context cannot read HKLM
reliably and will silently return its fallback.

### A whole ring reports `ManagementServerUnreachable` simultaneously

That is a management server, network, or firewall problem, not a device problem. Nothing in this
folder will fix it, and **do not deploy `HealthServiceCache` while it is true** — the flush gate
exists precisely to stop that, but targeting a smart group built during the outage would queue up
a mass flush for the moment the gate clears.

Confirm TCP 5723 from a representative device, then escalate to whoever owns the management group.

### `NoManagementGroup` on devices that should be monitored

Two possibilities, and they are easy to confuse:

1. The agent is a **Log Analytics agent**, not a SCOM agent — same binary, no SCOM management
   group. See section 1. Check whether `scom_agent_version` is populated; if it is, the agent is
   installed and healthy, just not yours.
2. The agent was genuinely never assigned or its assignment was removed server-side. This is a
   management server action — approve or assign the agent in the console.

### Tier 2 script reports success but nothing happened

Check `Status` under `HKLM:\Software\AirWatch\Extensions\SCOM\<ScriptName>`:

| Status | Meaning |
|---|---|
| `Dispatched` and never advances | The scheduled task never ran the payload — **almost always the missing AV/EDR exclusion** (section 3) |
| `SkippedCooldown` | The cooldown has not elapsed. Check `LastRunTime` / `LastRecycleTime` / `LastResetTime` |
| `Skipped:NotConfirmed` | `ConfirmHighImpact` was absent or unparseable. Note that `banana` is treated as "no" |
| `Skipped:<other>` | A gate blocked it. `BlockReason` names which one |
| `RolledBack` | It acted, the service failed to restart, and the original state was restored |

The payload log is at `%SystemRoot%\Temp\UEM_AutoRemediateSCOM*.log` and records every gate
decision.

### `HealthServiceCache` keeps aborting before it flushes

Read `BlockReason`. The two common ones:

- **Management server unreachable** — working as designed. An agent that cannot re-provision after
  a flush is left permanently grey, so the script refuses. Fix connectivity first.
- **No flush signal** — the device qualified on age alone. Configuration age by itself is not
  corruption; a stable management group that has not changed a management pack in a week
  legitimately shows an old cache. The script requires ESENT store errors, an oversized state
  folder, or genuinely stale configuration, not simply an old timestamp.

### `ClonedIdentity` never fires on devices that are obviously clones

It requires **both** image-baked state **and** at least 3 rejection events in 24 hours. A clone
that re-registered successfully has no rejection events, and does not need the script.

If the device is non-persistent VDI, the script is the wrong tool entirely — see section 7.

### The agent recycle keeps re-qualifying the same devices

The recycle is not failing; the agent genuinely has that much work. Recycling reclaims accumulated
runtime state, not scope. Look at what management packs target those devices — a desktop-oriented
management pack aimed at a session host will reproduce the footprint within hours of every recycle.
