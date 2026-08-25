# SCOM Agent Troubleshooter — Design Doc

## Problem
Customer needs a troubleshooter + resolution scripts for the System Center Operations Manager
agent (`HealthService` / Microsoft Monitoring Agent) across desktops, laptops, and VDI/Horizon/AVD
sessions. This is **agent-side only** — a device-side script can never fix a management server,
gateway, or operational database problem. It can only detect that condition and say so.

## Architecture
Mirrors the existing `ApplicationSpecific/SCCM` two-tier pattern:

```
Tier 1 — fleet-wide, low blast radius (3 script objects, share one registry cache)
  Invoke-AutoRemediateSCOMAgentPart1.ps1   <- steps 1-5,  remediates 1 & 4
  Invoke-AutoRemediateSCOMAgentPart2.ps1   <- steps 6-10, report only, owns the event-log pass
  Invoke-AutoRemediateSCOMAgentPart3.ps1   <- steps 11-14 + health score. RUNS LAST
  Invoke-AutoRemediateSCOMAgent.ps1        <- combined reference copy, NOT deployable

Tier 2 — opt-in, targeted rings only
  Invoke-AutoRemediateSCOMHealthServiceCache.ps1   <- state flush (DESTRUCTIVE)
  Invoke-AutoRemediateSCOMMonitoringHost.ps1       <- agent recycle
  Invoke-AutoRemediateSCOMClonedIdentity.ps1       <- identity reset (DESTRUCTIVE, highest blast radius)

Sensors — read what Tier 1 caches, no independent detection logic
  Sensors/*.ps1              <- 7 recurring, <2s cache readers (works today)
  OneTimeSensor/*.ps1        <- heavier one-shot JSON sensor (needs upcoming DEX one-time sensor run capability)
```

Registry contract (plural `Extensions`, matching VPN/logon-sensor convention, not the SCCM
`Extension` outlier): `HKLM:\Software\AirWatch\Extensions\SCOM\...`
- `SCOM` itself — Tier 1 writes its values **flat onto this key** every run (Status, HealthScore,
  HealthReason, per-metric values). Sensors only ever read here. (The original sketch had an
  `AgentHealth` sub-key; it was dropped during implementation because a sub-key bought nothing —
  the Tier 2 sub-keys already namespace themselves, and a flatter path keeps each sensor to a
  single `Get-ItemProperty`.)
- `SCOM\HealthServiceCache`, `SCOM\MonitoringHost`, `SCOM\ClonedIdentity` — each Tier 2 script's own
  result + cooldown marker.

Numerics are stored as `String`, not `DWORD`: several carry `-1` for "not measured", and a DWORD
reads that back as 4294967295. `AgentInstalled`, `MsReachable` and `ServiceRunning` are the only
DWORDs, because they are genuinely 0/1.

## Tier 1 sweep — `Invoke-AutoRemediateSCOMAgent.ps1`
14 steps, budget 45s (deploy at 120s UEM timeout). Guard clause exits 0 immediately if no
`HealthService` service and no install directory. Only two steps act automatically:

| # | Step | Action |
|---|---|---|
| 1 | HealthService Service State | AUTO — `sc.exe config/start`, skipped if agent install is in progress |
| 2 | HealthService Startup Delay | report |
| 3 | Management Group Registration | report → names ClonedIdentity spin-off |
| 4 | Management Server Connectivity (TCP 5723) | AUTO — flush DNS only |
| 5 | Configuration Cache Freshness | report → names HealthServiceCache spin-off |
| 6 | Health Service State Folder Size | report → names HealthServiceCache spin-off |
| 7 | Health Service Store Database (ESENT 477/490/623) | report → names HealthServiceCache spin-off |
| 8 | Agent Runtime Footprint (MonitoringHost CPU/RAM) | report → names MonitoringHost spin-off |
| 9 | Connector Connectivity Failures (20070/20071/21006/21016) | report, classifies server-side vs local |
| 10 | Workflow Health (1103/1102/4001/21405) | report |
| 11 | Channel Certificate Health | report (PKI-owned) |
| 12 | Agent Version | report |
| 13 | Time Synchronisation Skew | report, cross-references TimeSyncHealth rather than duplicating |
| 14 | Optional Agent Sub-services (AdtAgent, APM) | report |

Runtime guardrails: the `Operations Manager` event log is read **once** and bucketed in memory
(steps 9/10 reuse it); folder sizes use `Scripting.FileSystemObject` not `Get-ChildItem -Recurse`;
service start uses `sc.exe` (returns at START_PENDING) not `Start-Service`; the engine wraps every detection call in
try/catch, with three steps carrying an inner one for local recovery, because `Get-WinEvent -FilterHashtable` can throw a terminating error past
`-ErrorAction SilentlyContinue` when a log/provider is absent.

## Tier 2 spin-offs
All three follow the SCCM launcher/payload pattern: the UEM-delivered script copies itself to
`C:\ProgramData\AirWatch\Extensions\SCOM`, registers a one-shot SYSTEM scheduled task, exits in
~5s, and the payload does the real work outside UEM's timeout window, self-unregistering after.
Requires an AV/EDR exclusion on that path or the payload silently no-ops.

**HealthServiceCache** (flush) and **ClonedIdentity** (identity reset) are both marked
DESTRUCTIVE and gated behind a required `ConfirmHighImpact` environment variable — absent or
unparseable means nothing happens (fail closed). Both rename-then-delete the state folder so a
failed restart can roll back, and both use a cooldown marker to prevent repeat action on the same
device.

- **HealthServiceCache**: aborts unless the management server answers on its configured port
  first (flushing when the agent can't re-provision leaves it permanently grey), and unless a real
  signal (stale config / ESENT errors / oversized folder) is present, not just age.
- **MonitoringHost recycle**: no `ConfirmHighImpact` gate — recycling only restarts the agent's
  own service, nothing else depends on it, and no data is at risk. Instead it requires two
  independent sustained-load samples plus a once-per-day cap, because a single CPU reading proves
  nothing.
- **ClonedIdentity**: highest blast radius of the three. Requires **both** image-baked-state
  detection and rejection-evidence confirmation — either alone aborts. Explicitly documents that
  it's the wrong tool for non-persistent VDI (fix the parent image instead) and that the
  management server may still need an admin to approve/clean up the old registration.

## Sensors
- `Sensors/` — recurring, pure cache readers of the flat `SCOM` key, one value via
  `Write-Output`/`return`, type-valid fallbacks. Deployable today. All seven built:
  `scom_agent_health_score`, `scom_agent_health_reason`, `scom_management_server_reachable`,
  `scom_agent_version`, `scom_config_age_hours`, `scom_state_folder_mb`,
  `scom_monitoringhost_memory_mb`.
- `OneTimeSensor/scom_agent_health.ps1` — a heavier, self-contained JSON sensor for the upcoming
  DEX/UEM Intelligence-triggered one-time sensor run. Kept in a separate folder so nobody
  schedules it as a recurring sensor by mistake. README calls out explicitly that this piece isn't
  usable until that DEX capability ships.

  Now covers all 14 sweep steps: the startup-delay phase (sweep step 2) was the one gap and
  has been added, using the same process-start-vs-boot heuristic from data already in hand.
  Its health score agrees with the split sweep on the same device (both 45 on the test
  fixture).

  It duplicates the sweep's deduction table rather than reading the cache, because it must stay
  self-contained. That duplication is a maintenance hazard and is flagged in the file header:
  change the sweep's deductions and change them here in the same edit. One deliberate divergence —
  `TimeSkew` here is driven by time-sync age from the registry rather than measured clock skew,
  because a sensor must not launch `w32tm.exe`.

- `Sensors/Standalone/` — a second recurring set that measures the device directly instead of
  reading the cache, for fleets that will not deploy the sweep scripts. Nine sensors. Six are
  twins of the cached set (`score`, `reason`, `agent_version`, `config_age_hours`,
  `state_folder_mb`, `monitoringhost_memory_mb`); three have no cached equivalent
  (`healthservice_running`, `management_group_count`, `cert_expiry_days`) because the sweep
  records those metrics but exposes them only through the score. Deploy one set or the other.

### Why the standalone set is not just "the cached set without the cache"

The cache exists because two whole classes of check cannot run inside a 5-second recurring
sensor: **network probes** and **event log queries**. Removing the script does not remove that
constraint, it just moves who absorbs it. So the standalone score is a strict subset — same point
values, same thresholds, same reason names, 130 deductible points against the sweep's 235:

| Lost | Points | Needs |
|---|---:|---|
| `ManagementServerUnreachable` | 25 | a socket probe |
| `AgentNotRegistered` | 25 | the Operations Manager log |
| `ConnectorAuthenticationFailure` | 20 | the Operations Manager log |
| `HealthServiceStoreCorruption` | 20 | the ESENT log |
| `WorkflowsUnloaded` | 10 | the Operations Manager log |
| `IntermittentConnectivity` | 5 | the Operations Manager log |

**A standalone 100 therefore means "no locally visible fault", not "healthy"** — a device that
cannot reach its management server at all still scores 100. That is stated in the file header, in
the README, and in the inventory notes, because it is the one way this set can mislead.

Two reason values are renamed so the datasets can never be pooled by accident: `HealthyLocal`
rather than `Healthy`, and `TimeSyncStale` rather than `TimeSkew` (sync age from the registry, not
measured offset — same reason as the one-time sensor).

Two smaller decisions worth recording:

- **No standalone `management_server_reachable`.** It is the one metric with no honest local
  substitute, and faking one would be worse than omitting it.
- **`state_folder_mb_standalone` accepts an unbounded worst case.** FSO walks the subtree in
  native code and a blocking COM call cannot be time-boxed without a thread, which sensors may not
  create. Accepted because the bloat case is a few very large files, not a large file count. The
  composite score is protected differently: the folder walk runs last and is skipped entirely if
  the sensor has already spent 2500 ms, trading a 10-point deduction for a guaranteed exit.

### A real defect found while building this

`scom_config_age_hours` and `scom_state_folder_mb` were returning `-1` on almost every device.
Both metrics are written by the sweep with one decimal place (`"412.7"`), and
`[int]::TryParse` rejects a decimal point outright — so the parse failed and the sensor emitted
its not-measured sentinel. Silent, and indistinguishable from "the sweep never ran".

Both now parse as `[double]` (invariant culture, then current culture) and round. Verified against
`12.4`, `12`, `0.0`, `banana` and empty. The other cached sensors are unaffected —
`RuntimeMemoryMB` and `CertExpiryDays` are rounded to whole numbers before they are written, and
`AgentVersion` is a string.

## Status
All built, parse-clean, and verified. `README.md` and the twelve `SCRIPT-INVENTORY-CSV.csv` rows
are in place.

**Verification performed** (on a device with no SCOM agent, plus a synthetic HKCU/temp-dir agent
fixture; all test registry keys and fixtures removed afterwards, no residue on HKLM, no scheduled
tasks, no `C:\ProgramData` payload directory):
- Parse-check: 12/12 files clean.
- Sensor timing: all seven recurring sensors well under budget, correct sentinels with no cache
  (`-1` / `""` / no-sample) and correct values against a seeded cache; malformed input falls back
  rather than throwing.
- One-time sensor: valid JSON on both the guard-clause path and the agent-present path; deadline
  mechanism verified by forcing the budget to zero (skipped phases report `-4`, `TimedOut` true).
- Tier 2: all three exit 0 with nothing remediated on a no-agent device. Both DESTRUCTIVE scripts
  verified fail-closed with `ConfirmHighImpact` absent *and* unparseable (`banana`) — state intact,
  every downstream gate blocked.
- `HealthServiceCache` full destructive path exercised end to end against the fixture: all five
  gates cleared, flush ran, service failed to start, and **the rollback restored the original state
  folder** (`Status = RolledBack`, exit 1). This is the single most important safety property in
  the folder and it works.

**Defects found and fixed during verification:**
1. `(pipeline).Count` returns *empty* under Windows PowerShell 5.1 when exactly **one** object
   matches. This silently broke the `$passed`/`$warnings`/`$failed`/`$remCount` summary counters in
   all four scripts — and in Tier 1 it propagated into the cached `Status` value and the exit code,
   so a device with exactly one failing step reported `Passed` and exited `0`. Fixed by wrapping
   all sixteen sites in `@()`. (Detection-site counts were already wrapped correctly.)
2. Registry writes inside `try`/`catch` were not actually guarded: a registry `PermissionDenied` is
   a *non-terminating* error and sails straight past `catch`. Added `-ErrorAction Stop` to every
   `$RegPath` write across all four scripts so the existing handlers work. For the two DESTRUCTIVE
   scripts this also means a cooldown marker that cannot be written now fails the run loudly —
   correct, since the cooldown is what prevents repeat destructive action.
3. One-time sensor: an unmeasured management server probe (skipped by the deadline) was scored as a
   *failed* probe, fabricating a 25-point outage on a slow device. Now gated on `MsProbeResult`.
4. One-time sensor: `HealthScore` reported `-2` for "no agent" while the sweep and
   `scom_agent_health_score` both use `-1` for the same condition. Aligned to `-1`.

## UEM script size limit — resolved

Everything now fits the 32,767-character limit.

| Script | Original | Now | Headroom |
|---|---:|---:|---:|
| `Invoke-AutoRemediateSCOMAgentPart1.ps1` | — | 21,931 | 10,836 |
| `Invoke-AutoRemediateSCOMAgentPart2.ps1` | — | 25,671 | 7,096 |
| `Invoke-AutoRemediateSCOMAgentPart3.ps1` | — | 26,601 | 6,166 |
| `Invoke-AutoRemediateSCOMHealthServiceCache.ps1` | 38,284 | 32,717 | 50 |
| `Invoke-AutoRemediateSCOMClonedIdentity.ps1` | 36,185 | 31,173 | 1,594 |
| `Invoke-AutoRemediateSCOMMonitoringHost.ps1` | 30,535 | 29,114 | 3,653 |
| `OneTimeSensor/scom_agent_health.ps1` | 32,717 | 32,739 | 28 |
| `Invoke-AutoRemediateSCOMAgent.ps1` | 54,369 | 48,336 | **reference only, not deployable** |

`HealthServiceCache` (50) and the one-time sensor (28) are at the edge — the next edit to
either needs space freed first.

### The three-way split

Consolidation alone could not close Tier 1's gap: after all of it the file was 48,336 with
20,596 of scaffolding, leaving a 12,171 step budget per object against 27,740 of steps.
Two objects give 24,342 — 3,398 short. Three was the minimum.

The split is by step range, with the event-log pass and `Get-FolderSizeMB` living only in
Part 2 because only steps 6, 7, 9 and 10 need them. Tunables and shared-metric declarations
are duplicated in full across all three deliberately: the scoring thresholds must match the
detection thresholds, and splitting them invites silent drift.

**Scoring is the hard part.** The health score needs metrics from all 14 steps, but no single
object measures them all. Part 3 therefore reads Parts 1 and 2's metrics back from the
registry and applies the full 14-rule deduction table to the union. Consequences:

- **Part 3 must run last.** Schedule it at least 15 minutes after the others.
- Every cross-part read returns `-1` when absent, and every rule matches on a positive
  threshold or an explicit `-eq 0`, so **a missing metric can never deduct**. A partial score
  is therefore always too HIGH, never too low.
- Which is why a partial score is never published. If `Part1RunTime` or `Part2RunTime` is
  missing or older than `$StalePartHours` (26h), Part 3 writes `HealthScore = -1` /
  `HealthReason = IncompleteSweep` and `ScoreComplete = 0`. Caching the partial number would
  tell every sensor the agent is healthier than anyone measured.
- The sensors needed **no changes** — the sentinel is published by the writer, so they stay
  pure cache readers.

**Completeness is checked twice, because either check alone can lie.** Each part writes its
`PartNRunTime` marker **last**, after all its metrics, so it is a commit marker rather than a
start marker: a write that fails part-way (every write uses `-ErrorAction Stop`) leaves the
marker absent and Part 3 correctly treats that part as not-run. Part 3 additionally requires a
witness metric per part (`ServiceRunning` for Part 1, `StateFolderMB` for Part 2), which covers
a partially deleted key where markers survive but metrics do not.

This was found the hard way: one parity run produced 60 instead of 45 — exactly one missing
15-point `ConfigurationCacheStale` deduction — while still reporting `ScoreComplete = 1`. The
original ordering wrote the marker first, so a partial write looked complete. Both scenarios now
verify correctly: markers-with-no-metrics yields `-1` / `IncompleteSweep` / `ScoreComplete = 0`.

**Verified:** running Parts 1→2→3 against a synthetic agent fixture produces **byte-identical
values for all 29 registry keys** the monolith writes, identical 14-step console output, and
the same health score (45). Part 3 alone against an empty cache correctly yields
`-1` / `IncompleteSweep` / `ScoreComplete = 0`, and both sensors report it without modification.

### What the consolidation did

All behaviour-preserving, each verified by running pre- and post-consolidation scripts against
the same fixture at the same instant and diffing console output, exit code, and every cached
registry value:

- **`Res` helper** replacing 59 (Tier 1) / 57 (Tier 2) `return @{ Status; Message }` wrappers.
- **Constant step metadata removed** — `Order`, `Enabled = $true`, `ResolveOnWarning = $false`
  were identical on every step in every script; `ResolutionScript = $null` dropped from steps
  that do not act. The engine takes order from array position and treats a missing `Enabled`
  as enabled, so a step can still ship disabled by adding the key back.
- **Header rationale moved to `README.md`** with a pointer left in each script.
- Banner padding, decorative rules, and selected comment/message condensation.

### One measurement that contradicted the plan

**The scoring deduction table was not a size win.** Converting the 14 `if` blocks to a data
table plus loop came out **59 characters larger**, not ~1,375 smaller as estimated —
`Test = { … }` scriptblock syntax costs more than the `if` bodies it replaces. It was kept
because it now mirrors the one-time sensor's table and removes the drift hazard, but it is not
consolidation.

### Also flagged
`Measure-LogonDuration.ps1` trimmed 33,269 → 32,596 (171 headroom). The inventory row for
`Measure-LogonDurationEx.ps1` has a stale URL — the file now lives in
`GenericTroubleshooting/WindowsStartup/Archived/`. Pre-existing, not corrected here.

## Explicitly out of scope
Azure Monitor Agent (AMA) coexistence/migration, an agentic runbook
(`Runbook-SCOM-Agent.md` in the VPN style), interactive TroubleshootingWizard DiagSteps. All three
are reasonable follow-ons, not part of this deliverable.
