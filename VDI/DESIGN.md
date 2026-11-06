# VDI Agent and Client Troubleshooters -- Design Doc

**Status:** Draft, 2026-11-03. Nothing in this folder is built yet.
**Order of delivery:** Horizon, then Citrix, then Microsoft. Within each platform: the
agent (session host side) and the client (endpoint side) first, then the components that
surround them.

---

## 1. Problem

A VDI session involves at least four machines: the endpoint running a client, a broker or
control plane, a gateway, and the virtual desktop or session host running an agent. Hub
and DEX only ever run on two of those: the endpoint and the session host. Everything this
folder ships therefore follows the same constraint as `VPN/` and `ApplicationSpecific/Microsoft/SCOM/`:

> A device-side script can fix what the local OS and the locally installed agent or
> client own. It can only *detect and name* a broker, gateway, licensing, image, or
> control-plane fault. Pretending otherwise produces a script that exits 0 while the user
> is still staring at "Agent Unreachable".

The highest-value things device-side tooling can do for VDI, in order:

1. Answer "which side is broken" with evidence. Agent-side and client-side telemetry on
   the same user, correlated by client device name, separates "the desktop is sick" from
   "the laptop or its network is sick" from "the broker is sick". That split is where most
   VDI ticket time goes today.
2. Fix the agent-local layer autonomously: stopped services, disabled firewall rules,
   stale DNS, orphaned disconnected sessions, a bootloader that needs a kick.
3. Measure protocol quality (RTT, packet loss, UDP vs TCP fallback) from the only place it
   is reliably exposed: the session host's performance counters and logs.
4. Hand the admin a precise escalation: registration state, event IDs, broker list, clone
   type, and what was already tried.

### 1.1 The non-persistent rule: relief now, image fix later

Instant clones, MCS and PVS catalogs, and pooled AVD hosts revert on logoff or reboot, so
nothing a script does there is permanent. That does **not** make the fix pointless. A real
image fix takes 24-48 hours in production (build, test, publish, recompose or re-provision
the pool). Until it lands, every fresh clone carries the same fault, and the scheduled
remediation is the only thing standing between the pool and the help desk. On a
non-persistent pool the remediation is therefore a **standing patch**: it runs on every
clone, every cycle, and the pool stays usable while the admin fixes the image.

So persistence changes how a fix is *reported*, not whether it runs:

- **Relief fixes run everywhere.** Service start, firewall re-enable, DNS flush, agent or
  bootloader restart, stale-session logoff, registration retry: all Tier 1 AUTO steps and
  the Tier 2 restart scripts run on `NonPersistent` exactly as on `Persistent`. They are
  idempotent, cheap, and help the users on the machine right now.
- **Every result records whether it is temporary.** Remediation caches `ReliefOnly = 1`
  when the host is non-persistent, and the run log says so in words: "Fixed for this
  clone; it will revert at the next refresh. The pool image needs the same fix."
- **The collector tells image faults from drift.** `FaultPresentAtBoot = 1` when the first
  collection after boot already shows the leading health reason: the fault came with the
  image or the provisioning step, not from anything that happened in the session. That is
  the signal an admin needs to open an image ticket instead of chasing individual clones.
  It is surfaced as a `;ImageFault` suffix on `*_health_reason` (same mechanism as the
  VPN sensors' `;Stale` suffix), so no extra sensor object is needed and a DEX filter on
  the suffix lists the whole affected pool.
- **Only one class of action is withheld on `NonPersistent`:** destructive state resets
  whose entire value is permanence and which cannot help the current session (identity
  reset, local cache rebuilds, config-file rewrites). Those report, name the parent image
  as the target, and are ADMIN. Resets of *shared* state (an FSLogix container on a share,
  a UPM store) are judged on their own merits because they survive the refresh.
- **Recurrence across refreshes is a DEX question, not a device question.** The registry
  cache reverts with the clone, so the device cannot count how many refreshes have shown
  the fault. DEX can: the same `;ImageFault` reason across many devices in one pool, or on
  the same device name across days, is the recurrence signal. Runbooks query it there.

`Persistence` is `Persistent`, `NonPersistent` or `Unknown`. `Unknown` is treated as
`NonPersistent` for reporting (say it may revert) and as `Persistent` for the withheld
class (do not run it). The SCOM `ClonedIdentity` script keeps its stricter rule because
an identity reset is the one action that is always wrong on a clone.

---

## 2. Shared architecture

Everything below is identical across the three platforms so that a runbook author, a
sensor consumer, and a break-test author only learn the shape once.

### 2.1 Two deployment targets, two smart groups

| Target | Where Hub runs | What ships there |
|---|---|---|
| **Session host** (virtual desktop, RDSH, AVD host, Cloud PC) | inside the image, SYSTEM | `*StateCollection` (agent), `Invoke-AutoRemediate*Agent`, agent sensors, FSLogix/UPM/DEM/App Volumes collectors |
| **Endpoint** (laptop, thin PC, physical desktop) | on the device | `*ClientStateCollection`, `Invoke-AutoRemediate*Client`, client sensors |

Agent-side and client-side scripts are **separate script objects** assigned to separate
smart groups. A single script that branches on role would double every object's size
against the 32,767-character UEM limit and make the inventory unreadable. The only shared
sensor is `vdi_platform` / `vdi_role` (2.3), which is safe to assign fleet-wide.

### 2.2 Pipeline per component

```
Invoke-<Platform><Component>StateCollection.ps1   (script, SYSTEM, scheduled 15-30 min)
    measures, probes, mines event logs, computes HealthScore + HealthReason
    writes flat values to HKLM:\Software\AirWatch\Extensions\VDI\<Platform>\<Component>
          |
          v
Sensors/<prefix>_*.ps1                             (recurring, < 2 s, pure cache readers)
OneTimeSensor/<prefix>_health.ps1                  (all-in-one JSON, on demand from the DEX
                                                    console, self-contained, 25 s budget; 2.7)
          |
          v
Invoke-AutoRemediate<Platform><Component>.ps1      (script, SYSTEM, on demand / Quickflow)
    check-then-apply over an ordered step table; AUTO for OS/agent-local layers,
    report for everything else; writes ...\<Component>\Remediation
          |
          v
Invoke-AutoRemediate<Platform><Component><Action>.ps1   (Tier 2, opt-in, gated)
    launcher/payload via one-shot scheduled task; ConfirmHighImpact; cooldown marker
          |
          v
Runbook-<Platform>-<Component>.md                  (agent runbook, VPN style)
_AutomatedTesting/Invoke-AutoRemediate*_BreakTest.ps1
```

Conventions inherited unchanged from the repo (see `GENERAL-SCRIPTS-SENSORS_RUNBOOK.md`
and the SCOM/VPN design notes), restated only where VDI forces a choice:

- **Registry contract:** `HKLM:\Software\AirWatch\Extensions\VDI\<Platform>\<Component>`,
  values written flat on that key. Numerics stored as `String` (`-1` = not measured),
  only genuine 0/1 flags as `DWORD`. `LastRun` written **last** as the commit marker.
- **HealthScore** 0-100, `-1` = component not installed (distinct from unhealthy).
  **HealthReason** = the single largest deduction. Each component has its own enum.
  Collectors also write `Persistence`, `BootTime`, and `FaultPresentAtBoot` (DWORD, set
  only on the first run after the recorded boot time); remediations write `ReliefOnly`
  (DWORD) next to their step results. See 1.1.
- **Sensors** are cache readers with type-valid fallbacks. v1 ships without the VPN 1.1.0
  self-refreshing gate; it can be added later with a platform fingerprint (agent service
  state + registration flag + session count) once the collectors are stable.
- **Remediation** steps follow the SCOM step-engine shape (`Res` helper, array-ordered
  steps, `Enabled` defaulting on). `WhatIf` via environment variable. Explicit `exit` on
  every path. Guard clause exits 0 in under a second when the component is absent.
- **Event logs** are read once per collector run and bucketed in memory. Providers are
  resolved at runtime by display name pattern, not hard-coded, because every one of the
  three vendors has renamed providers across versions (VMware to Omnissa, XenDesktop to
  Citrix Virtual Apps and Desktops, WVD to AVD).
- **Network probes** live only in collectors, with per-host timeouts of 2 s and a total
  probe budget of 10 s; a skipped probe is `-1` / "not measured", never "failed" (the SCOM
  one-time-sensor defect).
- **Size:** each collector and remediation is planned at two script objects (Part1/Part2)
  from the start where the step count exceeds eight, rather than discovering the limit
  after the fact as SCOM did.

### 2.3 Platform detection (fleet-wide, standalone sensors)

Two sensors with no cache dependency, safe to assign to every Windows device. They read
service and registry presence only (< 200 ms).

| Sensor | Type | Values |
|---|---|---|
| `vdi_platform` | String | `Horizon`, `Citrix`, `AVD`, `RDS`, `Multiple`, `None` |
| `vdi_role` | String | `SessionHost`, `Client`, `Both`, `None` |

Detection matrix (first match per column wins; `Both` when a host also has a client):

| Platform | Session host evidence | Client evidence |
|---|---|---|
| Horizon | Horizon Agent service (`wsnm`) or `...\Horizon\Agent` key under either registry root | Horizon Client uninstall entry, or client key under either root |
| Citrix | `HKLM:\SOFTWARE\Citrix\VirtualDesktopAgent` or Citrix Desktop Service | Citrix Workspace uninstall entry or `...\Citrix\ICA Client` |
| AVD | `HKLM:\SOFTWARE\Microsoft\RDInfraAgent` or `RDAgentBootLoader` service | Windows App package, `HKLM:\SOFTWARE\Microsoft\MSRDC`, or RDPClient feed key |
| RDS | `TermService` running on a Server SKU with the RDSH role, no AVD agent | mstsc only (reported as client `RDS` only if no other client) |

`vdi_platform` is also what the runbooks branch on first, and what the smart groups for the
platform-specific objects are built from (sensor-value smart groups).

### 2.4 Correlating the two sides

Every agent-side collector records, per session, the **client device name** and
**client IP** the protocol stack reports, plus the user. That is the join key between an
agent-side record and the endpoint's own DEX record, and it is the single most useful
field for an agent runbook ("the user's laptop is on Wi-Fi with 30% loss; the desktop is
fine").

| Platform | Source of client name / IP per session |
|---|---|
| Horizon | `ViewClient_Machine_Name`, `ViewClient_IP_Address`, `ViewClient_Protocol`, `ViewClient_Broker_DNS_Name` in `HKU\<SID>\Volatile Environment\<SessionId>` |
| Citrix | `HKLM:\SOFTWARE\Citrix\Ica\Session\<SessionId>\Connection` (`ClientName`, `ClientAddress`, `ClientVersion`) |
| Microsoft | `TerminalServices-LocalSessionManager` events (source address), already parsed by `Measure-LogonDurationMultiSession.ps1`; `WTSClientName` via `query session` as fallback |

Session inventory itself reuses the approach in
`GenericTroubleshooting/WindowsStartup/Measure-LogonDurationMultiSession.ps1` (LSM events,
provider-major queries), not `Win32_ComputerSystem.UserName`, for the reasons recorded
there. Per-session rows go to a `Sessions\<SID>` sub-key; the flat key carries the
device-level reduction (count, worst RTT, worst loss, oldest disconnected session).

### 2.5 What is already in the repo and is reused, not rebuilt

| Need | Existing asset |
|---|---|
| Logon duration on multi-session hosts, FSLogix/DEM/UPM phase timing | `Measure-LogonDurationMultiSession.ps1` |
| "Is this a VM" | `GenericTroubleshooting/VirtualizationDetection/device_is_virtual.ps1` |
| Endpoint network stack, DNS, gateway | `Invoke-AutoRemediateNetworkStack.ps1` |
| Endpoint VPN health (client-side VDI over VPN is the common case) | `VPN/` collector, sensors, runbook |
| Time skew (breaks Kerberos to broker, Citrix registration, AVD token) | `TimeSyncHealth` (cross-referenced, not duplicated) |
| Step engine, `Res` helper, launcher/payload, `ConfirmHighImpact`, cooldown | SCOM Tier 1 / Tier 2 scripts |
| Break-test harness, safety interlock, fix-report analysis | `AutomatedTesting/` |

### 2.6 Sensor naming

`<platform>_<component>_<metric>`, lower snake case, kept short because UEM sensor names
are typed by hand into smart-group and dashboard filters:

| Prefix | Component |
|---|---|
| `hzn_agent_`, `hzn_client_`, `hzn_blast_` | Horizon Agent, Horizon Client, Blast protocol |
| `av_agent_`, `dem_` | App Volumes Agent, Dynamic Environment Manager |
| `ctx_vda_`, `ctx_cwa_`, `ctx_hdx_` | Citrix VDA, Workspace app, HDX protocol |
| `ctx_upm_`, `wem_agent_` | Profile Management, WEM Agent |
| `avd_host_`, `avd_client_`, `rdp_` | AVD/W365 session host agent, Microsoft clients, RDP transport |
| `fsl_`, `rds_` | FSLogix (shared across all three), classic RDS licensing/broker |

**Never duplicate what DEX already captures.** Workspace ONE DEX has native Horizon
session telemetry (protocol RTT, packet loss, bandwidth, frame rate, session state and
counts, client device name, IP and version, session start time) and UEM application
inventory has every agent and client version. A recurring sensor for any of those is a
second, worse copy of a value DEX already trends. The rule for every platform in this
folder: a scalar sensor ships only for a value DEX does not have, which in practice is
the composite health score and reason, the image-fault flag, clone type and persistence,
service and firewall state, broker reachability from the desktop, and client-log
failure counts. Everything else is measured into the collector cache (the score needs
it, and the all-in-one sensor returns it on demand) but gets no sensor file in this
repository at all. Each platform's SPEC carries a "DEX-native overlap" column and the
internal build confirms it against the DEX data catalog.

**Shipped versus cache-only.** Each component's sensor list below is split into **Ship**
(a UEM sensor object is created) and **Cache only** (the collector writes the value and a
runbook or Quickflow can read it from the registry, but no sensor object exists until a
customer asks). The ship set is what the runbooks branch on: health score and reason,
version, session counts, protocol quality, and the client-name correlation key. The four
main agents and clients do not get an `_installed` sensor because `vdi_platform` /
`vdi_role` already answer that fleet-wide; surrounding components do, because nothing
else covers them. About 70 sensors ship across all phases; roughly 40 more stay cache-only.
Every cache-only value is still reachable on demand through the component's all-in-one
sensor (2.7), so "cache only" never means "unavailable to an investigation".

### 2.7 All-in-one JSON sensors (`OneTimeSensor/`)

The DEX console is gaining the ability to run a sensor on demand against one device and,
ideally, to parse JSON sensor output. For an investigation that is far more efficient
than reading fifteen scalar sensors whose samples are up to 30 minutes old. Each
component therefore ships **one all-in-one sensor** alongside its scalar set, following
the precedent of `ApplicationSpecific/Microsoft/SCOM/OneTimeSensor/scom_agent_health.ps1`:

| Property | Rule |
|---|---|
| Name | `<prefix>_health`, e.g. `hzn_agent_health`, `ctx_vda_health`, `avd_host_health`, `fsl_health` |
| Data type | String, one compressed JSON object, nothing else on the output stream |
| Context | SYSTEM; one-time / run-once only, never scheduled recurring (it probes and mines logs) |
| Budget | Self-enforced 25 s Stopwatch, phases ordered cheapest first, UEM 30 s ceiling is the backstop only |
| Cache | Reads **no** cache for its own component: it measures live, so it works on a device where the collector has never run and its numbers are current at the moment the analyst asks. It **does** read the caches of related components (below). Writes nothing. |
| Sentinels | `-1` unknown, `-2` not applicable, `-4` timed out before this phase ran; `TimedOut` true means `HealthScore` is a floor, not a verdict |
| Score | Same deduction table, thresholds and reason names as the collector, kept in sync by hand in the same edit, and checked by a parity test (6.2) |
| Size | Under 1,024 bytes compressed, by construction: Hub drops any sensor value over 1 KB (UEM-API-TESTING-SPEC.md, found 2026-11-05), so the sensor serializes, measures, and drops rows from its arrays until the string fits (pattern: `WindowsAutoRemediation\Performance\OneTimeSensor\startup_apps_health.ps1`). `Sessions` and `Errors24h` therefore carry only the few worst rows, and the flat scalar keys must fit on their own. The earlier 4 KB target predates the cap being measured. |

**JSON shape** (flat top level so a console can map keys to columns without walking a
tree; arrays only where the data is genuinely per-row):

```
{
  "SchemaVersion": 1,
  "Component": "HorizonAgent",  "Platform": "Horizon",  "Role": "SessionHost",
  "Collected": "2026-11-03T14:02:11",  "ElapsedMs": 6120,  "TimedOut": false,
  "Installed": true,  "Version": "2406",  "BrandRoot": "Omnissa",
  "Persistence": "NonPersistent",  "CloneType": "InstantClone",  "UptimeMinutes": 412,
  "HealthScore": 55,  "HealthReason": "BrokerUnreachable",
  "NextStep": "ADMIN",  "NextStepDetail": "Invoke-AutoRemediateHorizonAgent.ps1 step 6",
  "AgentServiceRunning": true,  "BlastServiceRunning": true,
  "BrokerCount": 2,  "BrokerResolvable": true,  "BrokerReachable": false,  "BrokerProbeMs": 2004,
  "SessionCount": 3,  "DisconnectedSessionCount": 1,  "OldestDisconnectedMinutes": 95,
  "BlastRttMsMax": 48,  "BlastPacketLossPpmMax": 1200,  "BlastTcpFallbackSessions": 0,
  "AgentErrorCount24h": 2,
  "Sessions": [ { "Id": 2, "User": "jdoe", "ClientName": "L-JDOE-01", "ClientIp": "10.1.4.22",
                  "Protocol": "Blast", "Transport": "UDP", "State": "Active",
                  "RttMs": 48, "LossPpm": 1200, "DurationMin": 131 } ],
  "Errors24h": [ { "Id": 1004, "Count": 2 } ],
  "Related": { "AppVolumes": { "Score": 100, "Reason": "Healthy", "CacheAgeMin": 12 },
               "FSLogix":    { "Score": -1,  "Reason": "",        "CacheAgeMin": -1 },
               "DEM":        { "Score": 80,  "Reason": "ConfigShareSlow", "CacheAgeMin": 12 } }
}
```

Rules behind the shape:

- **No nulls.** Every numeric key is present with a sentinel; every string key is present
  with `""`. A parser never has to special-case a missing key.
- **Booleans are booleans**, numbers are numbers, enums are strings. No `"true"` strings,
  no numbers-as-strings, so the console can type columns on first sight.
- **`NextStep`** is `AUTO`, `USER`, `ADMIN` or `NONE`, with `NextStepDetail` naming the
  script and step. This is the one piece of runbook knowledge carried in the sensor,
  because an analyst looking at a JSON blob in a console wants to know what to run next
  without opening the runbook.
- **`Related`** carries only score, reason and cache age for the surrounding components,
  read from their registry caches in milliseconds. It answers "is it the agent or is it
  FSLogix" in one pull without blowing the budget; the component's own all-in-one sensor
  is the next pull when `Related` points at it.
- **`UptimeMinutes`** plus `Persistence` lets the console apply the 1.1 image-fault
  reasoning (a fault on a 4-minute-old clone came from the image) without the sensor
  needing the collector's `FaultPresentAtBoot`.
- **Session rows carry the correlation key** (`ClientName`, `ClientIp`) so the analyst can
  pivot to the endpoint's record from the same screen.

**Phase order inside the sensor**, so a timeout drops the most expensive data first:
registry and services (ms); session inventory and `ViewClient_*` / ICA session keys
(< 1 s); one performance-counter sample (1-2 s); network probes, at most 3 hosts, 2 s each;
event log, bounded by `MaxEvents`, last. Score is computed from whatever was measured.

**The duplication hazard** is the same as SCOM's: the deduction table lives in the
collector and in this sensor. Mitigation is a parity test in `_AutomatedTesting`
(`Test-<Component>ScoreParity.ps1`) that runs collector and all-in-one sensor against the
same fixture and asserts identical `HealthScore` and `HealthReason`. SCOM did that check
by hand; here it is a script, because there will be thirteen such pairs.

**Until the console parses JSON**, the value is still a readable string in the sensor
detail view and in exports, and `ConvertFrom-Json` handles it in any PowerShell tooling,
so nothing is lost by shipping it now.

**One per component, not one per role.** A single "everything on this session host"
sensor was considered and rejected for v1: the SCOM precedent is already at 32,739 of
32,767 characters for one component, and the budget cannot fit live measurement of five
components in 25 s. The `Related` block is the compromise. If the script-size limit or
the one-time budget grows, a role-level composite becomes a follow-on.

---

## 3. Horizon (Omnissa, formerly VMware)

### 3.0 The rebrand problem

Horizon 8 2406 and later install under Omnissa names; 2312 and earlier under VMware names.
Customers run both for years. Every Horizon script resolves **both roots** and records
which one it found (`BrandRoot = VMware | Omnissa`):

| Thing | Legacy (VMware) | Rebranded (Omnissa) -- verify on lab agent |
|---|---|---|
| Agent registry | `HKLM:\SOFTWARE\VMware, Inc.\VMware VDM\Agent` | `HKLM:\SOFTWARE\Omnissa\Horizon\Agent` |
| Node Manager / broker config | `HKLM:\SOFTWARE\VMware, Inc.\VMware VDM\Node Manager` | `HKLM:\SOFTWARE\Omnissa\Horizon\Node Manager` (present on this VM, written by App Volumes 4.21) |
| Blast config | `HKLM:\SOFTWARE\VMware, Inc.\VMware Blast\Config` | `HKLM:\SOFTWARE\Omnissa\Horizon\Blast\Config` (verify) |
| Client config (per user) | `HKCU:\SOFTWARE\VMware, Inc.\VMware VDM\Client` | `HKCU:\SOFTWARE\Omnissa\Horizon\Client` (verify) |
| Client policy | `HKLM:\SOFTWARE\Policies\VMware, Inc.\VMware VDM\Client` | `HKLM:\SOFTWARE\Policies\Omnissa\Horizon\Client` (verify) |
| Agent logs | `%ProgramData%\VMware\VDM\logs` | `%ProgramData%\Omnissa\logs\...` (verify) |
| Client logs | `%LOCALAPPDATA%\VMware\VDM\Logs` | `%LOCALAPPDATA%\Omnissa\...` (verify) |
| Services | `wsnm` (agent), `VMBlast` (Blast) -- display names rebranded, short names expected unchanged (verify) | |
| Perf counters | `VMware Blast Session Counters`, `VMware Blast Imaging Counters` | possibly renamed (verify with `Get-Counter -ListSet '*Blast*'`) |

The volatile `ViewClient_*` session variables are expected to keep their names.

### 3.1 Horizon Agent (session host)

**Collector:** `Invoke-HorizonAgentStateCollection.ps1`, budget 30 s, scheduled 15-30 min.
**Cache:** `...\VDI\Horizon\Agent` (+ `Sessions\<SID>`).

What it measures, in order (steps marked * need a network probe or event-log pass):

| # | Measurement | Source | Cached as |
|---|---|---|---|
| 1 | Agent installed, version, brand root | Uninstall key, registry root probe | `Installed` (DWORD), `Version`, `BrandRoot` |
| 2 | Core services: `wsnm`, `VMBlast` | `Get-Service` | `AgentServiceRunning`, `BlastServiceRunning` (DWORD) |
| 3 | Feature services present and their state (USB arbitration, printing, scanner, serial, RTAV, WebRTC/Teams redirection) | `Get-Service` by display-name pattern `Horizon|VMware View|Blast|ThinPrint|TP AutoConnect|USB Arbitration` | `FeatureServiceCount`, `FeatureServicesStopped` (names, `;`-joined) |
| 4 | Paired broker list | Node Manager / Agent Configuration broker value (name to verify) | `BrokerCount`, `BrokerList` |
| 5* | Broker DNS resolution and TCP 4001 / 4002 reachability | `Resolve-DnsName`, `TcpClient` with 2 s timeout | `BrokerResolvable`, `BrokerReachable` (DWORD), `BrokerProbeResult` |
| 6 | Horizon firewall rules enabled (agent installs its own group) | `Get-NetFirewallRule -DisplayGroup` pattern | `FirewallRulesDisabled` (count) |
| 7 | Session inventory: active, disconnected, oldest disconnected age; per-session client name/IP/protocol/broker from `ViewClient_*` | LSM events + `HKU\<SID>\Volatile Environment` | `SessionCount`, `DisconnectedSessionCount`, `OldestDisconnectedMinutes`, `Sessions\<SID>\*` |
| 8 | Blast quality per session: RTT, packet loss (uplink), estimated bandwidth, FPS; device reduction = worst | `\VMware Blast Session Counters(session id: N; (main))\RTT`, `\Packet Loss (Uplink)`, `\Estimated Bandwidth (Uplink)`; imaging counters for FPS | `BlastRttMsMax`, `BlastPacketLossPpmMax`, `BlastBandwidthKbpsMin`, `BlastFpsMin` |
| 9 | Blast transport: UDP enabled in config; per-session TCP fallback | Blast `Config\UdpEnabled`; session transport from Blast log or counter (source to verify) | `BlastUdpEnabled`, `BlastTcpFallbackSessions` |
| 10 | PCoIP quality if any session is PCoIP | `PCoIP Session Network Statistics` counters | `PcoipRttMsMax`, `PcoipLossPpmMax` |
| 11* | Agent errors last 24 h | Application log, provider resolved by `Horizon|VMware View` pattern, Level <= Error | `AgentErrorCount24h` |
| 12 | Clone type and persistence | Instant-clone artifacts under the agent key / ClonePrep markers (exact value to verify); fallback `Unknown` | `CloneType` (`InstantClone`/`FullClone`/`Physical`/`Unknown`), `Persistence` |
| 13 | Time sync | `TimeSyncHealth` cache, not re-measured | `TimeSyncStale` (DWORD) |
| 14 | Score | deduction table below | `HealthScore`, `HealthReason`, `LastRun` |

**HealthReason enum and deductions** (largest wins; `-1` when not installed):

| Reason | Points | Trigger |
|---|---:|---|
| `AgentServiceStopped` | 40 | `wsnm` not running |
| `NotPaired` | 35 | `BrokerCount` = 0 |
| `BrokerUnresolvable` | 30 | DNS fails for every broker |
| `BrokerUnreachable` | 30 | TCP 4001/4002 fails for every broker |
| `BlastServiceStopped` | 25 | `VMBlast` not running (sessions can still broker over PCoIP/RDP) |
| `HighPacketLoss` | 20 | `BlastPacketLossPpmMax` > 20000 (2%) |
| `HighRtt` | 15 | `BlastRttMsMax` > 250 |
| `BlastTcpFallback` | 15 | any session on TCP with `UdpEnabled` = 1 |
| `FirewallRulesDisabled` | 15 | any Horizon rule disabled |
| `AgentErrorsElevated` | 10 | `AgentErrorCount24h` >= 10 |
| `StaleDisconnectedSessions` | 10 | `OldestDisconnectedMinutes` > 480 |
| `FeatureServiceStopped` | 5 | any installed feature service with Automatic start not running |
| `TimeSyncStale` | 5 | from `TimeSyncHealth` |
| `CollectionError` | n/a | score `-1`, reason set, `LastRun` not advanced |
| `Healthy` | 0 | |

**Sensors** (`Sensors/`). Ship (10): `hzn_agent_version`, `hzn_agent_health_score`,
`hzn_agent_health_reason`, `hzn_agent_session_count`,
`hzn_agent_disconnected_session_count`, `hzn_blast_rtt_ms`, `hzn_blast_packet_loss_ppm`,
`hzn_blast_tcp_fallback_sessions`, `hzn_agent_clone_type`, `hzn_agent_last_client_name`
(the correlation key for the most recent session).
Cache only: `AgentServiceRunning`, `BlastServiceRunning`, `BrokerCount`,
`BrokerReachable`, `OldestDisconnectedMinutes`, `BlastBandwidthKbpsMin`, `BlastFpsMin`,
`AgentErrorCount24h`, `FeatureServicesStopped`, `FirewallRulesDisabled`.

**Remediation:** `Invoke-AutoRemediateHorizonAgent.ps1` (Part1 services/firewall/DNS,
Part2 sessions/report if size forces a split):

| # | Step | Action |
|---|---|---|
| 1 | Agent service (`wsnm`) | AUTO -- `sc.exe config`/`start`; skipped if an agent install/upgrade is in progress |
| 2 | Blast service | AUTO -- same |
| 3 | Feature services | AUTO -- start Automatic services that are stopped; never change start type of Manual ones |
| 4 | Horizon firewall rules | AUTO -- re-enable disabled rules in the Horizon display group |
| 5 | Broker DNS | AUTO -- flush and re-register; report if still unresolvable |
| 6 | Broker TCP | report -- names firewall/UAG/Connection Server as owner |
| 7 | Disconnected sessions older than threshold | Opt-in (`Enabled = $false`) -- `logoff <id>`; default report. ControlUp gap row 151. |
| 8 | Blast quality / TCP fallback | report -- UDP 22443 (or 8443 via UAG) path is network-owned |
| 9 | Agent errors | report -- top 3 event IDs with counts |
| 10 | Not paired / clone-prep incomplete | report -- ADMIN; names the parent image when `FaultPresentAtBoot` = 1 |

Steps 1-7 run on non-persistent clones as relief (1.1); the run log and `ReliefOnly` say
the fix reverts at the next refresh.

Tier 2: `Invoke-AutoRemediateHorizonAgentRestart.ps1` -- restarts `wsnm` (and `VMBlast`),
which is the standard first fix for "Agent Unreachable" in the Horizon console. It can
interrupt in-flight session negotiation, so it requires no active sessions **or**
`ConfirmHighImpact`, and a 24 h cooldown. It runs on non-persistent clones: an unreachable
clone is useless to the pool, and a restart that brings it back is pure relief. Re-pairing
(agent reinstall) is ADMIN only and is the withheld class on a clone: fix the image.

### 3.2 Horizon Client (endpoint)

**Collector:** `Invoke-HorizonClientStateCollection.ps1`, cache `...\VDI\Horizon\Client`.
Runs as SYSTEM but must read the **logged-on user's** HKCU for server list and the user's
`%LOCALAPPDATA%` for logs; it resolves the console user's SID via the explorer process
owner, the pattern the Outlook remediation already uses.

| # | Measurement | Source |
|---|---|---|
| 1 | Installed, version, brand root | Uninstall entry `Omnissa Horizon Client|VMware Horizon Client` |
| 2 | USB arbitration service | `Get-Service` display-name `USB Arbitration` |
| 3 | Configured servers (user + policy) | HKCU client key `Server`/recent list, policy key |
| 4* | Server reachability: TCP 443 to each; TCP 8443 (UAG Blast) or 22443 (direct) | `TcpClient`, 2 s each |
| 5 | Certificate checking mode | client/policy `CertCheckMode` (verify name) |
| 6* | Connection failures and last successful connect, last protocol, last server | client log tail (bounded read of newest `vmware-horizon-client*.txt` / rebranded name), 24 h window |
| 7 | Teams/WebRTC redirection plug-in present on client | feature DLL/registry presence |
| 8 | Endpoint network context | `VPN` and `NetworkStack` caches read, not re-measured |
| 9 | Score | below |

| Reason | Points | Trigger |
|---|---:|---|
| `ServerUnresolvable` | 35 | DNS fails for every configured server |
| `ServerUnreachable443` | 35 | TCP 443 fails for every configured server |
| `BlastPortUnreachable` | 25 | 443 works but 8443/22443 fails (classic "logs in, black screen, disconnects") |
| `RepeatedConnectFailures` | 25 | >= 5 failures in 24 h |
| `UsbServiceStopped` | 10 | |
| `ClientOutdated` | 10 | version below the fleet floor (tunable) |
| `CertCheckDisabled` | 5 | mode allows untrusted (security hygiene; report) |
| `VpnDegraded` | 5 | `vpn_health_score` < 50 on this endpoint (pointer to the VPN runbook) |

**Sensors.** Ship (5): `hzn_client_version`, `hzn_client_health_score`,
`hzn_client_health_reason`, `hzn_client_connect_failure_count_24h`,
`hzn_client_last_connect_time`.
Cache only: `ServerReachable`, `BlastPortReachable`, `LastServer`, `UsbServiceRunning`,
`CertCheckMode`.

**Remediation:** `Invoke-AutoRemediateHorizonClient.ps1`: USB arbitration service (AUTO),
DNS flush (AUTO), client firewall rules (AUTO), WinHTTP proxy / `netsh winhttp` report,
outdated client (report, ADMIN via UEM app deploy), server unreachable (report, routes to
`NetworkStack` and `VPN` scripts), corrupt client prefs (Opt-in: rename the user's client
prefs folder; off by default). Most client-side failures are network, so the client
runbook spends two of its phases inside the existing VPN and network runbooks.

### 3.3 Surrounding components (Horizon)

**App Volumes Agent** -- `Invoke-AppVolumesAgentStateCollection.ps1`,
cache `...\VDI\Horizon\AppVolumes`. Verified on this VM (4.21):
services `svservice` (App Volumes Service) and `AVSubService`;
`HKLM:\SOFTWARE\Omnissa\AppVolumes\Agent` with `Manager_Address`, `Manager_Port`,
`ProductVersion`, `SvService_Management`, `Hypervisor_Type`; legacy root
`HKLM:\SOFTWARE\WOW6432Node\CloudVolumes\Agent`; log
`C:\Program Files\Omnissa\AppVolumes\Agent\Logs\svservice.log` (950 KB here, read tail only).
Sensors, ship (4): `av_agent_installed`, `av_agent_version`, `av_agent_health_score`,
`av_agent_health_reason` (`ManagerNotConfigured`, `ManagerUnreachable`, `ServiceStopped`,
`AttachFailures`, `Healthy`). Cache only: `ServiceRunning`, `ManagerConfigured`,
`ManagerReachable`, `AttachFailures24h`, `VolumesAttached` (count from log/driver state,
verify source).
Remediation: service start (AUTO); manager not configured / unreachable (report, ADMIN);
volumes not attached for a user (USER: log off and on). **This VM is already the
"installed, service stopped, no manager" fixture** -- the first break test in the folder
needs no setup.

**Dynamic Environment Manager** -- FlexEngine has no service; it runs at logon/logoff via
GPO. Collector reads the DEM policy (`HKCU\Software\Policies\Immidio\Flex Profiles\Arguments`
legacy; rebranded path to verify) for config and profile-archive shares, probes SMB 445 to
each, and parses the per-user `FlexEngine.log` tail for the last import status and duration.
Sensors, ship (4): `dem_configured`, `dem_last_import_duration_ms`, `dem_health_score`,
`dem_health_reason`. Cache only: `ConfigShareReachable`, `ProfileShareReachable`,
`LastImportStatus`. Remediation is report/USER only (DEM state is on the share; a device
can only tell you the share is unreachable). Ties into the logon-duration collector's
DEM phase rather than re-timing it.

**Protocol (Blast / PCoIP)** -- measured in the agent collector (3.1 steps 8-10). No separate
object; a `Runbook-Horizon-Protocol.md` phase set lives inside the agent runbook.

**Printing, USB, CDR, RTAV, scanner, serial, Teams optimization** -- feature services are
covered by agent steps 3 and remediation step 3. Teams optimization gets one extra sensor,
`hzn_agent_teams_redirection_ready` (WebRTC redirection service running and the Teams
VDI registry flag set), because "Teams calls are terrible in VDI" is a top-five ticket and
the fix is usually that one service.

**Connection Server, UAG, vCenter, instant-clone recovery, pool enable/disable, session
shadowing, send-message** (SCRIPT-GAPS rows 146-157) -- not device-side. They need broker
credentials and the Horizon REST API. Recorded as a possible later "Horizon REST connector"
for the agent runbooks, outside this folder.

---

## 4. Citrix (Virtual Apps and Desktops / DaaS)

### 4.1 VDA (session host)

**Collector:** `Invoke-CitrixVdaStateCollection.ps1`, cache `...\VDI\Citrix\VDA`.

| # | Measurement | Source |
|---|---|---|
| 1 | Installed, version | `HKLM:\SOFTWARE\Citrix\VirtualDesktopAgent`, uninstall entry |
| 2 | Core services by display name: Citrix Desktop Service (`BrokerAgent`), Citrix ICA Service (`PorticaService`), Citrix Stack Control Service, Citrix Print Manager Service, Citrix Profile Management, Citrix WEM Agent Host Service, Citrix Telemetry, Citrix EUEM, Citrix Rendezvous (short names to verify) | `Get-Service` |
| 3 | Controller list and SIDs | `ListOfDDCs`, `ListOfSIDs` on the VDA key |
| 4* | DDC DNS and TCP 80/443 reachability per controller | `Resolve-DnsName`, `TcpClient` |
| 5* | Registration state and history | Application log, provider `Citrix Desktop Service`: 1017 could not register / retrying, 1022 failed for 5 min (reduced rate), 1002 cannot connect to DDC, 1018 "Access this computer from the network" right missing, 1023 refused `AgentNotContactable`; success ID (1012 expected, verify). Latest event decides `Registered`; counts over 24 h |
| 6 | Session inventory + client name/address/version per session | `HKLM:\SOFTWARE\Citrix\Ica\Session\<Id>\Connection` + LSM events |
| 7 | ICA RTT and HDX transport (EDT vs TCP) per session | `root\Citrix\euem` (round-trip classes) and `root\Citrix\hdx` (transport/virtual-channel enum classes); class names resolved at build time on a VDA |
| 8 | Rendezvous state (DaaS) | VDA key / Rendezvous service state (verify) |
| 9 | Citrix firewall rules enabled (1494, 2598, 80/443 inbound from DDC) | `Get-NetFirewallRule` |
| 10 | Provisioning type / persistence | PVS target device service (`BNDevice`) present => `NonPersistent`; MCS identity disk markers (verify); else `Unknown` |
| 11* | VDA errors 24 h | Application log, providers `Citrix*`, Level <= Error |
| 12 | Time sync | `TimeSyncHealth` cache |
| 13 | Score | below |

| Reason | Points | Trigger |
|---|---:|---|
| `DesktopServiceStopped` | 40 | |
| `NoControllersConfigured` | 35 | `ListOfDDCs` empty |
| `NotRegistered` | 35 | latest registration event is 1017/1022 |
| `ControllerUnreachable` | 30 | DNS or TCP fails for every DDC (1002 corroborates) |
| `AgentNotContactable` | 30 | 1023 in window (DDC cannot reach VDA: firewall/NTLM, CTX340030) |
| `NetworkLogonRightMissing` | 25 | 1018 in window (GPO; ADMIN) |
| `IcaServiceStopped` | 25 | |
| `HighIcaRtt` | 15 | worst session RTT > 250 ms |
| `EdtFallback` | 15 | EDT enabled by policy, session on TCP |
| `FirewallRulesDisabled` | 15 | |
| `StaleDisconnectedSessions` | 10 | > 480 min |
| `VdaErrorsElevated` | 10 | >= 10 in 24 h |
| `FeatureServiceStopped` | 5 | |
| `TimeSyncStale` | 5 | |
| `CollectionError` / `Healthy` | | |

**Sensors.** Ship (10): `ctx_vda_version`, `ctx_vda_health_score`,
`ctx_vda_health_reason`, `ctx_vda_registered`, `ctx_vda_session_count`,
`ctx_vda_disconnected_session_count`, `ctx_hdx_rtt_ms`, `ctx_hdx_transport`,
`ctx_vda_provisioning_type`, `ctx_vda_last_client_name`.
Cache only: `RegistrationFailures24h`, `DdcCount`, `DdcReachable`,
`DesktopServiceRunning`, `IcaServiceRunning`, `EdtFallbackSessions`, `ErrorCount24h`,
`RendezvousState`, `FirewallRulesDisabled`.

**Remediation:** `Invoke-AutoRemediateCitrixVda.ps1`:

| # | Step | Action |
|---|---|---|
| 1 | Citrix Desktop Service | AUTO -- start / un-disable |
| 2 | Citrix ICA Service, Stack Control, Print Manager, Profile Management, WEM, EUEM | AUTO -- start stopped Automatic services |
| 3 | Citrix firewall rules | AUTO -- re-enable |
| 4 | DDC DNS | AUTO -- flush/re-register; report if still unresolvable |
| 5 | DDC TCP 80/443 | report |
| 6 | Registration retry | Opt-in -- restart Citrix Desktop Service to force re-registration; ICA sessions survive but the VDA is unregistered for seconds. 1 h cooldown. Default report. |
| 7 | `AgentNotContactable` (1023) | report -- ADMIN: inbound firewall from DDC, or `allowNtlm` in `BrokerAgent.exe.config` (CTX340030); never edits the config file |
| 8 | 1018 network logon right | report -- ADMIN (GPO) |
| 9 | Disconnected sessions | Opt-in logoff, default report |
| 10 | EDT fallback / high RTT | report -- UDP 1494/2598 or Gateway Service path |
| 11 | Empty `ListOfDDCs` | report -- ADMIN; never writes the value (wrong controllers are worse than none) |

Steps 1-6 and 9 run on MCS/PVS clones as relief (1.1). Tier 2:
`Invoke-AutoRemediateCitrixVdaRestart.ps1` (Desktop Service + ICA Service restart, gated
like the Horizon one, runs on clones). An unregistered VDA that is already unregistered
at first boot (`FaultPresentAtBoot` = 1) is an image or provisioning fault: the restart
still runs for relief, and the report names the master image or vDisk as the real target.

### 4.2 Citrix Workspace app (endpoint)

**Collector:** `Invoke-CitrixWorkspaceAppStateCollection.ps1`, cache `...\VDI\Citrix\WorkspaceApp`.

| # | Measurement | Source |
|---|---|---|
| 1 | Installed, version | uninstall entry `Citrix Workspace`, `HKLM:\SOFTWARE\WOW6432Node\Citrix\ICA Client` |
| 2 | Services: Citrix Workspace Updater, Citrix Authentication Manager / `CtxSvcHost` family (verify) | `Get-Service` |
| 3 | Store / workspace URLs for the console user | `HKCU:\Software\Citrix\Receiver\SR\Store*` (verify), policy keys |
| 4* | Store TCP 443, Gateway 443; UDP 443 for EDT cannot be probed, reported `Unknown` | `TcpClient` |
| 5 | Active ICA sessions | `wfica32.exe` process count |
| 6* | Connection failures 24 h, SSL errors (classic error 4 / 61 = cert chain) | Application log `Citrix*` providers and client log tail (paths to verify) |
| 7 | Auto-update disabled / version below floor | registry + version compare |
| 8 | Endpoint network context | `VPN` and `NetworkStack` caches |

Reasons: `StoreUnresolvable` 35, `StoreUnreachable` 35, `GatewayUnreachable` 25,
`RepeatedConnectFailures` 25, `SslTrustFailures` 20 (missing root CA; ADMIN),
`ServiceStopped` 10, `ClientOutdated` 10, `VpnDegraded` 5.

**Sensors.** Ship (5): `ctx_cwa_version`, `ctx_cwa_health_score`,
`ctx_cwa_health_reason`, `ctx_cwa_connect_failure_count_24h`, `ctx_cwa_last_connect_time`.
Cache only: `StoreCount`, `StoreReachable`, `SessionCount`, `SslErrorCount24h`
(surfaces as the `SslTrustFailures` reason).

**Remediation:** `Invoke-AutoRemediateCitrixWorkspaceApp.ps1`: services (AUTO), DNS (AUTO),
proxy report, outdated (report/ADMIN), SSL trust (report/ADMIN, names the CA), Workspace app
reset via the vendor clean-up tool (Opt-in, destroys user store config, off by default).

### 4.3 Surrounding components (Citrix)

- **Profile Management (UPM):** `ctxProfile` service, policy
  `HKLM:\SOFTWARE\Policies\Citrix\UserProfileManager` (`PSEnabled`, `PathToUserStore`), log
  under `%SystemRoot%\System32\LogFiles\UserProfileManager\` (default; verify). Sensors,
  ship (4): `ctx_upm_enabled`, `ctx_upm_logon_errors_24h`, `ctx_upm_health_score`,
  `ctx_upm_health_reason`; cache only: `ServiceRunning`, `StoreReachable`. Remediation:
  service AUTO; store unreachable report; everything else is image/policy.
- **WEM Agent:** agent host service, infrastructure server / Citrix Cloud reachability,
  cache age, last refresh. Sensors, ship (3): `wem_agent_installed`,
  `wem_agent_health_score`, `wem_agent_health_reason`; cache only: `ServiceRunning`,
  `ServerReachable`, `CacheAgeHours`. Remediation: service AUTO, cache refresh (Opt-in,
  runs the agent's own refresh command, fine on clones since it is relief), rest report.
- **HDX / EDT / Rendezvous:** inside the VDA collector; `ctx_hdx_*` sensors above.
- **Teams HDX optimization:** `ctx_vda_teams_optimized_ready` (HDX Teams redirection
  components present, Teams VDI flag). Same rationale as Horizon.
- **PVS target / MCS:** `ctx_vda_provisioning_type` plus, for PVS, write-cache fill
  percentage (`ctx_pvs_write_cache_pct`) from the target-device status interface
  (source to verify). Report only; a full write cache is an image/sizing decision.
- **Cloud Connectors, DDCs, StoreFront, Gateway, Director:** out of scope (server-side).

---

## 5. Microsoft (Azure Virtual Desktop, Windows 365, RDS)

### 5.1 AVD / Windows 365 session host

Windows 365 Cloud PCs run the same AVD agent, are always persistent, and are Intune-managed;
the scripts behave identically and `Persistence = Persistent` is set when a Cloud PC is
detected (detection marker to verify). Pooled AVD hosts are `NonPersistent` unless the
host pool is personal, which is not knowable on-device, so the default is `Unknown`:
relief fixes and the agent restart run, results are reported as possibly temporary, and
only the withheld class (1.1) is held back.

**Collector:** `Invoke-AvdSessionHostStateCollection.ps1`, cache `...\VDI\Microsoft\SessionHost`.

| # | Measurement | Source |
|---|---|---|
| 1 | Agent installed, version | `HKLM:\SOFTWARE\Microsoft\RDInfraAgent`, `C:\Program Files\Microsoft RDInfra\RDAgent_<ver>` |
| 2 | Services: `RDAgentBootLoader`, `RDAgent`, Geneva monitoring agent, `TermService`, `UmRdpService`, `RDWebRTCSvc` | `Get-Service` |
| 3 | Registration: `IsRegistered` = 1 and `RegistrationToken` blank (confirmed by Microsoft agent troubleshooting doc); `IsRegistered` = 0 usually means the token expired | registry |
| 4 | SxS stack listener present (`rdp-sxs*` WinStation) and `fDenyTSConnections` = 0 | `HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations`, policy key |
| 5* | Required URL reachability (broker, `*.wvd.microsoft.com`, login, catalog, Geneva, IMDS `169.254.169.254`, host health `168.63.129.16`) | `TcpClient` 443 with 2 s each; optionally dispatches the agent's own `WVDAgentUrlTool.exe` asynchronously and reads its output next run |
| 6* | Agent health-check outcomes as the agent itself logs them (domain joined, domain trust, FSLogix, SxS listener, URLs, monitoring agent, metadata service, encryption, WebRTC, app attach, UDP transport -- full list to verify against the current "session host statuses and health checks" doc) | Application log providers `WVD-Agent`, `WVD-Agent-Updater`, `RDAgentBootLoader`; `RemoteDesktopServices` log |
| 7 | Session inventory, client name/IP per session | LSM events (existing parser) |
| 8 | RDP transport and quality per session: UDP (Shortpath) vs TCP, RTT, loss | `RemoteFX Network(*)` counters (`Current UDP RTT`, `Current TCP RTT`, `Loss Rate`); `RdpCoreCDV/Operational` 135 transport-type event (verify) |
| 9 | Teams WebRTC redirector ready | `RDWebRTCSvc` + `HKLM:\SOFTWARE\Microsoft\Teams\IsWVDEnvironment` = 1 |
| 10 | FSLogix health | `...\VDI\Shared\FSLogix` cache (5.3), not re-measured |
| 11* | Agent errors 24 h | same providers, Level <= Error |
| 12 | Persistence | Cloud PC marker (verify) else `Unknown` |
| 13 | Score | below |

| Reason | Points | Trigger |
|---|---:|---|
| `BootLoaderStopped` | 40 | the documented first fix for "Unavailable" |
| `NotRegistered` | 40 | `IsRegistered` = 0 -- needs a new token, ADMIN |
| `AgentStopped` | 35 | |
| `SxsListenerMissing` | 30 | |
| `TsConnectionsDenied` | 30 | `fDenyTSConnections` = 1 |
| `BrokerUrlsUnreachable` | 30 | broker/login URLs fail |
| `ImdsUnreachable` | 20 | "Needs Assistance" class |
| `MonitoringAgentUnhealthy` | 10 | "Needs Assistance" class |
| `RdpTcpFallback` | 15 | Shortpath expected, sessions on TCP |
| `HighRdpRtt` | 15 | > 250 ms |
| `TeamsRedirectorStopped` | 10 | |
| `FsLogixUnhealthy` | 10 | from shared cache |
| `StaleDisconnectedSessions` | 10 | |
| `AgentErrorsElevated` | 10 | |
| `CollectionError` / `Healthy` | | |

**Sensors.** Ship (11): `avd_host_agent_version`, `avd_host_health_score`,
`avd_host_health_reason`, `avd_host_registered`, `avd_host_session_count`,
`avd_host_disconnected_session_count`, `rdp_transport`, `rdp_rtt_ms`, `rdp_loss_ppm`,
`avd_host_teams_redirector_ready`, `avd_host_last_client_name`.
Cache only: `BootLoaderRunning`, `AgentRunning`, `SxsListenerOk`, `BrokerUrlsReachable`,
`ImdsReachable`, `ErrorCount24h`, `HealthCheckFailures` (names, `;`-joined).

**Remediation:** `Invoke-AutoRemediateAvdSessionHost.ps1`:

| # | Step | Action |
|---|---|---|
| 1 | `RDAgentBootLoader` | AUTO -- start / un-disable |
| 2 | `RDAgent`, Geneva agent, `TermService`, `UmRdpService`, `RDWebRTCSvc` | AUTO |
| 3 | `fDenyTSConnections` = 1 | AUTO -- set 0 (policy value left alone; if policy-enforced, report ADMIN) |
| 4 | Remote Desktop / Shortpath firewall rules | AUTO -- re-enable the Remote Desktop group; Shortpath UDP 3390 rule only if the Shortpath policy is already enabled |
| 5 | Required URLs unreachable | AUTO flush DNS; then report -- proxy/firewall ADMIN |
| 6 | `IsRegistered` = 0 | report -- ADMIN must issue a new registration token; the device cannot |
| 7 | SxS listener missing | report -- agent/stack reinstall, ADMIN |
| 8 | Disconnected sessions | Opt-in logoff, default report |
| 9 | TCP fallback / high RTT | report -- Shortpath policy, STUN/TURN egress |
| 10 | Agent errors | report |

Steps 1-5 and 8 run on pooled hosts as relief (1.1). Tier 2:
`Invoke-AutoRemediateAvdAgentRestart.ps1` -- stop `RDAgent`, restart `RDAgentBootLoader`
(which re-launches the agent and re-runs health checks). Cooldown 1 h, no
`ConfirmHighImpact` needed (it is the vendor's own documented remedy and sessions survive),
runs on pooled hosts, but skipped while any session is in the connecting state. A host that
is already `Unavailable` at first boot is an image fault; the restart still runs, and the
report names the host pool image.

### 5.2 Microsoft clients (endpoint)

Three clients coexist: **Windows App** (Store package; identity to verify), the **Remote
Desktop client** `msrdc.exe` (`HKLM:\SOFTWARE\Microsoft\MSRDC`, per-user feeds under
`HKCU:\SOFTWARE\Microsoft\RdClientRadc`), and **mstsc** (in-box, RDS/direct RDP only).

**Collector:** `Invoke-MicrosoftRdClientStateCollection.ps1`, cache `...\VDI\Microsoft\Client`.

| # | Measurement | Source |
|---|---|---|
| 1 | Client type(s) present, versions | Store package (`Get-AppxPackage -AllUsers`), MSRDC key, mstsc file version |
| 2 | Subscribed workspaces / feeds for the console user | `RdClientRadc` (msrdc) / Windows App equivalent (verify) |
| 3* | Feed and gateway reachability (`rdweb.wvd.microsoft.com`, `rdgateway.wvd.microsoft.com`, `client.wvd.microsoft.com`, 443) | `TcpClient` |
| 4* | Connect attempts, failures, last disconnect reason code, UDP multi-transport used | `Microsoft-Windows-TerminalServices-RDPClient/Operational` (1024 attempt, 1026 disconnect + reason, 1027 connected, 1105 multi-transport; verify set), 24 h |
| 5 | Credential cache entries for `TERMSRV/*` | `cmdkey /list` parse (count only) |
| 6 | Endpoint network context | `VPN` and `NetworkStack` caches |

Reasons: `FeedUnreachable` 35, `GatewayUnreachable` 30, `RepeatedConnectFailures` 25,
`NoClientInstalled` 20 (when the device is in a VDI-user smart group), `ClientOutdated` 10,
`TcpOnlyTransport` 10 (never saw 1105), `VpnDegraded` 5.

**Sensors.** Ship (6): `avd_client_type`, `avd_client_version`, `avd_client_health_score`,
`avd_client_health_reason`, `avd_client_connect_failure_count_24h`,
`avd_client_last_connect_time`.
Cache only: `FeedCount`, `FeedReachable`, `LastDisconnectReason`, `UdpUsed` (surfaces as
the `TcpOnlyTransport` reason), `TermsrvCredentialCount`.

**Remediation:** `Invoke-AutoRemediateMicrosoftRdClient.ps1`: DNS (AUTO), proxy report,
Store client stale (report; Store updates are user/Intune-owned), msrdc outdated (ADMIN
app deploy), stale `TERMSRV` credential entries (Opt-in: delete; off by default), feed
refresh (USER instruction).

### 5.3 Surrounding components (Microsoft, and shared)

- **FSLogix** (`VDI/Shared/FSLogix`, because Horizon and Citrix fleets use it too): services `frxsvc`, `frxccds`; `HKLM:\SOFTWARE\FSLogix\Profiles` (`Enabled`,
  `VHDLocations` / `CCDLocations`), per-session state under `Profiles\Sessions\<SID>`
  (value names to verify), logs `%ProgramData%\FSLogix\Logs\Profile\`, operational event
  log (`Microsoft-FSLogix-Apps/Operational`, verify). Collector probes SMB 445 to every
  VHD/CCD location host, parses the last 24 h of profile log for Status/Reason/Error
  triples, and counts local temp-profile fallbacks. Sensors, ship (6): `fsl_enabled`,
  `fsl_version`, `fsl_attach_failures_24h`, `fsl_temp_profile_count`, `fsl_health_score`,
  `fsl_health_reason`; cache only: `ServiceRunning`, `StorageReachable`,
  `ProfileSizeMbMax`. Remediation: service AUTO; storage unreachable report; orphaned
  `local_<user>` temp profiles cleanup Opt-in (destructive, `ConfirmHighImpact`; allowed on
  non-persistent hosts because a leftover temp profile blocks the *next* logon on that
  clone until refresh, so removing it is relief); locked VHD (another host holds the
  handle) report with the holding host from the log.
- **RDP Shortpath**: inside 5.1 (`rdp_transport`). Managed-network Shortpath needs the
  listener policy and a UDP 3390 rule; both are reported, the rule is AUTO only when the
  policy is already on.
- **Teams WebRTC redirector**: inside 5.1.
- **MSIX app attach / App attach**: `avd_host_appattach_failures_24h` from the agent log;
  report only.
- **Classic RDS session hosts** (`rds_` sensors, collector
  `Invoke-RdsSessionHostStateCollection.ps1`): licensing grace timer
  (`HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\GracePeriod`, days left),
  configured license servers and mode (policy key `...\Windows NT\Terminal Services`),
  license server TCP 135/445 reachability, "no license server" events (1128/1129, verify),
  broker membership, `fDenyTSConnections`, Remote Desktop firewall group. Sensors, ship
  (4): `rds_licensing_grace_days_left`, `rds_licensing_mode`, `rds_health_score`,
  `rds_health_reason`; cache only: `LicenseServerCount`, `LicenseServerReachable`,
  `BrokerConfigured`, `TsConnectionsAllowed`. Remediation:
  `fDenyTSConnections` and firewall AUTO, everything licensing-related is report/ADMIN
  (deleting the grace-period key is a well-known hack and is deliberately **not** offered).
- **Windows 365 specifics**: nothing extra on the device beyond persistence. Whether Hub is
  present on Cloud PCs in the target customers is an open question (6.3).

---

## 6. Delivery plan

### 6.1 Phases and deliverables

Each phase ships the full set for its components: collector(s), scalar sensors, the
all-in-one JSON sensor (2.7), Tier 1 remediation, any Tier 2 script, `Runbook-*.md`,
`_AutomatedTesting/*_BreakTest.ps1` and `Test-*ScoreParity.ps1`, `README.md` section,
`SCRIPT-INVENTORY-CSV.csv` rows, `TEST-VALIDATION.md` rows.

| Phase | Scope | Objects (approx.) | Lab needed |
|---|---|---:|---|
| 0 | `vdi_platform`, `vdi_role`; folder README; this doc | 2 sensors | this VM |
| 1 | Horizon Agent + Horizon Client | 2 collectors, 15 sensors, 2 remediations, 1 Tier 2, 2 runbooks, 2 break tests | Horizon lab: 1 Connection Server, 1 instant-clone pool, 1 full-clone VM, this VM as client |
| 2 | App Volumes, DEM, Teams redirection sensor | 2 collectors, 9 sensors, 1 remediation | this VM (App Volumes present), DEM share |
| 3 | Citrix VDA + Workspace app | 2 collectors, 15 sensors, 2 remediations, 1 Tier 2, 2 runbooks, 2 break tests | Citrix lab or DaaS trial: 1 DDC/Cloud Connector, 1 MCS VDA, Workspace app on this VM |
| 4 | UPM, WEM, PVS, Teams sensors | 2 collectors, 9 sensors, 1 remediation | same |
| 5 | AVD session host + Microsoft clients | 2 collectors, 17 sensors, 2 remediations, 1 Tier 2, 2 runbooks, 2 break tests | AVD host pool (1 pooled host), msrdc + Windows App on this VM |
| 6 | FSLogix (shared), RDS classic, app attach | 2 collectors, 11 sensors, 2 remediations | AVD host + one Server RDSH |

Shipped scalar sensor total: 78 objects (2 + 15 + 9 + 15 + 9 + 17 + 11). Roughly 45 more
values are cache-only and can be promoted to sensors per customer without touching a
collector. On top of that, one all-in-one JSON sensor per component: 13 objects (Horizon
Agent, Horizon Client, App Volumes, DEM, Citrix VDA, Workspace app, UPM, WEM, AVD host,
Microsoft client, FSLogix, RDS, plus a thin `vdi_platform_health` that only returns the
detection matrix and the `Related` block for every component found, as the first pull of
any investigation).

Phase 1 is the template; its collector, step engine and break test are copied for phases 3
and 5 with the measurement table swapped. Budget the Horizon pair to be reviewed hardest.

### 6.2 Break tests per platform (what can be broken safely on a lab host)

| Platform | Breaks that are safe and reversible | Excluded |
|---|---|---|
| Horizon agent | stop/disable `wsnm`, `VMBlast`, feature services; disable Horizon firewall rules; set bogus broker DNS via hosts file; create a disconnected session via a second RDP logon and `tsdiscon` | unpairing the agent (needs reinstall); instant-clone image edits |
| Horizon client | stop USB arbitration; hosts-file poison the server name; block 8443 with a firewall rule | corrupting prefs on a real user |
| Citrix VDA | stop Desktop/ICA services; disable rules; empty `ListOfDDCs` **copy** (restore from backup value); hosts-file poison DDC | `BrokerAgent.exe.config` edits |
| AVD host | stop `RDAgentBootLoader`/`RDAgent`; `fDenyTSConnections` = 1; disable RD firewall group; hosts-file poison `rdbroker` | clearing `IsRegistered` (needs a new token to recover) |
| FSLogix | stop `frxsvc`; set `VHDLocations` to an unreachable share **copy**; seed a `local_test` temp profile folder | detaching a live user's VHD |

All use `Assert-DexTestHost` and the existing restore pattern. Every break test's
`ExpectFixed` list excludes report-only steps so a false pass cannot hide behind them.

Each component also gets a non-destructive `Test-<Component>ScoreParity.ps1`: run the
collector, then the all-in-one sensor, on the same host within the same minute, parse the
JSON, and assert `HealthScore` and `HealthReason` match the cache. It runs before any
break test and again after, so a break that the collector scores and the sensor misses
(or the reverse) is caught the first time, not in production.

### 6.3 Decisions

Decided 2026-11-03:

1. **Folder:** top-level `VDI/` with `Horizon/`, `Citrix/`, `Microsoft/`, `Shared/`
   sub-folders, matching `VPN/`. This doc lives at `VDI/DESIGN.md`; the empty
   `ApplicationSpecific/VDI/` folder is gone.
2. **Sensor count:** ship the health score and reason, version, session counts, protocol
   quality and the correlation key per component (78 scalar objects, see 6.1); everything
   else is cache-only until a customer asks. Per-component lists above are split
   accordingly. Separately, every component ships an all-in-one JSON sensor for on-demand
   runs from the DEX console (2.7), because for an investigation one live JSON pull beats
   fifteen stale scalars; the console is expected to parse JSON.
3. **Non-persistent hosts:** relief fixes run everywhere and are reported as temporary;
   `FaultPresentAtBoot` marks image faults; only permanence-only destructive resets are
   withheld (1.1). Reason: a production image fix takes 24-48 h, and the scheduled
   remediation keeps the pool usable in the meantime.

Still open:

4. **Windows 365 and Hub:** confirm whether target customers run Hub on Cloud PCs. If not,
   the AVD host work still applies to AVD; W365 becomes client-side only.
5. **Disconnected-session logoff default:** Opt-in everywhere above. If customers want it
   AUTO with a threshold (ControlUp row 151 suggests demand), it becomes a tunable on the
   remediation script with a default of 8 h, still `Enabled = $false` on first ship.
6. **Self-refreshing gate:** v1 cache readers only, or VPN 1.1.0 gate from day one. The
   gate matters most for `*_registered` and `*_service_running`, which are exactly the
   values a help-desk agent reads during an incident. Recommendation: v1 without, add in
   the first point release once the collectors are stable, as VPN did.

### 6.4 Verify at build time (not assumptions to ship on)

Each of these is resolved on the lab host before the matching code is written, and the
answer goes into the script header.

| Item | How to verify |
|---|---|
| Omnissa-branded registry roots, log folders, service display names, client log file name | `Get-ChildItem HKLM:\SOFTWARE\Omnissa -Recurse -Depth 2`; `Get-Service *Horizon*,*Blast*,*Omnissa*`; `Get-ChildItem $env:ProgramData\Omnissa` |
| Blast counter set and instance names after rebrand; whether a jitter counter exists | `Get-Counter -ListSet '*Blast*' \| Select-Object CounterSetName, Counter, PathsWithInstances` |
| Agent broker-list value name; instant-clone marker value | inspect the agent key on an instant-clone and a full-clone VM |
| Blast per-session transport (UDP/TCP) source | Blast log vs counter vs `ViewClient_*` |
| Citrix service short names; registration-success event ID; `root\Citrix\euem` and `root\Citrix\hdx` class names | `Get-Service *Citrix*`; `Get-WinEvent -ProviderName 'Citrix Desktop Service' -MaxEvents 50`; `Get-CimClass -Namespace root\Citrix\hdx` |
| Workspace app store registry, log paths, updater service names | `Get-ChildItem HKCU:\Software\Citrix -Recurse -Depth 2` on a configured client |
| AVD health-check list and how each is logged locally; `RdpCoreCDV` 135 transport event; `RemoteFX Network` counter availability on AVD | Microsoft "session host statuses and health checks" page; `Get-WinEvent -LogName 'Microsoft-Windows-RemoteDesktopServices-RdpCoreCDV/Operational'`; `Get-Counter -ListSet 'RemoteFX Network'` |
| Windows App package identity and feed storage; RDPClient event ID set | `Get-AppxPackage -AllUsers *Windows365*,*WindowsApp*`; `Get-WinEvent -LogName 'Microsoft-Windows-TerminalServices-RDPClient/Operational' -MaxEvents 100` |
| Cloud PC detection marker | inspect a W365 Cloud PC registry (`HKLM:\SOFTWARE\Microsoft\Windows365*`, IMDS tags) |
| FSLogix per-session registry value names; operational log name; `frx.exe` output format | `Get-ChildItem HKLM:\SOFTWARE\FSLogix\Profiles\Sessions -Recurse`; `Get-WinEvent -ListLog *FSLogix*` |
| App Volumes attached-volume source | `svservice.log` tail vs `svdriver` parameters on this VM |
| RDS licensing event IDs, grace-period value decoding | `Get-WinEvent -LogName 'Microsoft-Windows-TerminalServices-Licensing/Operational'` on an RDSH |
| Maximum sensor value length UEM and DEX store and display, and whether the on-demand run returns the full string; sets the `Sessions` / `Errors24h` caps in 2.7 | push a test sensor returning 2 KB, 4 KB, 8 KB strings through `Invoke-WsoContentTest.ps1` and read back via the API |
| DEX console JSON parsing: which shape it expects (flat keys, nested objects, arrays) and whether `SchemaVersion` is honoured | confirm with the DEX console team before phase 1's all-in-one sensor is finalised; the 2.7 shape is the proposal |

---

## 7. Explicitly out of scope

- Anything that runs on a broker, controller, connection server, gateway, StoreFront,
  Director, Cloud Connector, or the Azure control plane.
- Horizon REST / Citrix SDK / Azure ARM actions (recover instant clone, enable pool, shadow,
  send message, logoff from the broker). These are a possible "VDI control-plane
  connector" for the agent runbooks, not device scripts.
- Golden-image hygiene (Optimization Tool, BIS-F, sysprep). Detected via persistence and
  named for ADMIN, never edited.
- Linux and macOS session hosts and clients.
- Thin clients (IGEL has its own folder under `ApplicationSpecific/`).

---

## 8. Sources used for vendor facts in this draft

- Microsoft, Troubleshoot common Azure Virtual Desktop Agent issues (RDAgentBootLoader,
  `IsRegistered`, `RegistrationToken`, event sources):
  https://learn.microsoft.com/azure/virtual-desktop/troubleshoot-agent
- Microsoft, Session host statuses and health checks:
  https://learn.microsoft.com/azure/virtual-desktop/troubleshoot-statuses-checks
- Citrix CTX133769 (VDA registration events 1017/1022):
  https://support.citrix.com/s/article/CTX133769-vda-registration-failure-with-event-id-1001
- Citrix CTX136668 (registration troubleshooting, 1018/1022):
  https://support.citrix.com/external/article/CTX136668/how-to-troubleshoot-virtual-delivery-age.html
- Citrix CTX213546 (event 1002):
  https://support.citrix.com/external/article/CTX213546/xendesktop-vda-registration-in-an-ad-mu.html
- Citrix CTX340030 (event 1023 `AgentNotContactable`, `allowNtlm`):
  https://support.citrix.com/external/article/340030/vda-failing-to-register-with-the-error-t.html
- Citrix CTX227530 (Citrix Desktop Service stopped):
  https://support.citrix.com/external/article/CTX227530/citrix-desktop-service-is-not-running-or.html
- VMware Horizon console administration, Blast session counters (RTT, Packet Loss (Uplink),
  Estimated Bandwidth (Uplink)):
  https://docs.vmware.com/en/VMware-Horizon/2306/horizon-console-administration/GUID-3BDDA228-84A9-4805-AD72-C15A42F91622.html
- ControlUp, Analyze VMware Blast Session (counter instance format `session id: N; (main)`):
  https://www.controlup.com/script-library-posts/analyze-vmware-blast-session/
- VMware Horizon 2006 installation guide (legacy `HKLM\SOFTWARE\VMware, Inc.\VMware VDM` keys):
  https://docs.vmware.com/en/VMware-Horizon/2006/horizon-installation/GUID-6CBEE2CA-EA5A-43C3-86A8-1910859E4AF7.html
