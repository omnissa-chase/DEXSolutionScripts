# Horizon Agent and Client Troubleshooter -- Build Contract

**Spec revision:** 2 (2026-11-10). **Design:** `VDI/DESIGN.md` sections 1, 2, 3.
**Scope:** Horizon Agent (session host) and Horizon Client (endpoint). Phase 0 platform
sensors are included because the Horizon runbooks depend on them. App Volumes, DEM and the
other surrounding components are phase 2 and are not in this contract.

## 0. How to use this document

This is a contract, not a narrative. Two builds are produced from it:

| Build | Where | Built from | Who |
|---|---|---|---|
| **Public** | this repository, `VDI/Horizon/` | public documentation plus runtime resolution of anything uncertain | Claude Code, this session |
| **Internal** | a private repository, never this one | this spec plus the internal knowledge base, which settles every KB point in section 3 | a corporate-approved agent |

The two builds must be **interchangeable at every interface**: the same file names, sensor
names and types, registry keys and value names, JSON keys, health-reason names and points,
step names, step order and message templates, exit codes, and tunable names. A DEX
dashboard, a runbook, a break test or an inventory row written against one build must work
unchanged against the other. Section 12 lists what the internal build may change; nothing
else may.

Rule language: **MUST** / **MUST NOT** are hard constraints; **SHOULD** is the default
unless the script header states why not; **MAY** is a choice. Everything in
`GENERAL-SCRIPTS-SENSORS_RUNBOOK.md` applies and is not repeated here.

---

## 1. File manifest

All paths relative to `VDI/`. Versions start at `1.0.0`. Every `.ps1` MUST be under
32,767 characters; the budget column is the planning ceiling so there is room for the
internal build's additions.

| Path | Kind | Context | Budget (chars) | Timeout (deploy) |
|---|---|---|---|---|
| `Sensors/vdi_platform.ps1` | sensor, String | System | 6,000 | < 2 s |
| `Sensors/vdi_role.ps1` | sensor, String | System | 6,000 | < 2 s |
| `Horizon/Invoke-HorizonAgentStateCollection.ps1` | script, scheduled 15-30 min | System | 31,500 (public build is ~31,000; settling KB candidate lists shrinks it, and an internal build that needs more MUST split into Part1/Part2 as SCOM did) | 30 s budget, deploy at 60 s |
| `Horizon/Invoke-HorizonClientStateCollection.ps1` | script, scheduled 30-60 min | System | 26,000 | 30 s budget, deploy at 60 s |
| `Horizon/Invoke-AutoRemediateHorizonAgent.ps1` | script, on demand / Quickflow | System | 30,000 | 30 s, deploy at 60 s |
| `Horizon/Invoke-AutoRemediateHorizonClient.ps1` | script, on demand / Quickflow | System | 28,000 | 30 s, deploy at 60 s |
| `Horizon/Invoke-AutoRemediateHorizonAgentRestart.ps1` | script, Tier 2 launcher/payload | System | 24,000 | launcher 10 s; payload 5 min self-limit |
| `Horizon/Sensors/hzn_agent_*.ps1` (3), `hzn_client_*.ps1` (3) | sensors, ship set | System | 4,000 each | < 2 s |
| `Horizon/OneTimeSensor/hzn_agent_health.ps1` | sensor, String (JSON), one-time only | System | 32,000 | 25 s self-enforced |
| `Horizon/OneTimeSensor/hzn_client_health.ps1` | sensor, String (JSON), one-time only | System | 26,000 | 25 s self-enforced |
| `Horizon/Runbook-Horizon-Agent.md` | agent runbook | | | |
| `Horizon/Runbook-Horizon-Client.md` | agent runbook | | | |
| `Horizon/README.md` | deployment guide | | | |
| `Horizon/_AutomatedTesting/Invoke-AutoRemediateHorizonAgent_BreakTest.ps1` | break test | Administrator | | |
| `Horizon/_AutomatedTesting/Invoke-AutoRemediateHorizonClient_BreakTest.ps1` | break test | Administrator | | |
| `Horizon/_AutomatedTesting/Test-HorizonScoreParity.ps1` | non-destructive | Administrator | | |
| `Horizon/_AutomatedTesting/Test-HorizonNoAgentPath.ps1` | non-destructive, runs on any device | Administrator | | |

Inventory rows (`SCRIPT-INVENTORY-CSV.csv`) and `AutomatedTesting/TEST-VALIDATION.md`
entries are required for every script and sensor above.

---

## 2. Runtime contract

- Windows PowerShell 5.1 x64, in-box cmdlets only, SYSTEM context, ASCII source.
- Collectors and remediations: run header, `$HEAD` prefix, `Write-Log` to
  `%SystemRoot%\Temp\UEM_<ScriptName>.log`, explicit `exit` on every path.
- Collectors MUST complete in 30 s worst case. The event-log pass is bounded by
  `MaxEventsScanned`; every TCP probe uses the `BeginConnect` / `WaitOne` / `EndConnect`
  pattern with `NetTimeoutMs`; at most `MaxProbeHosts` hosts are probed per run.
- Remediations: `SupportsShouldProcess`, `$env:WhatIf` bridge defaulting to live,
  check-then-apply engine exactly as `ApplicationSpecific/Microsoft/SCOM/Invoke-AutoRemediateSCOMAgentPart1.ps1`
  (array-ordered steps, `Enabled` absent means enabled, `Res` helper, detection in
  try/catch, summary block, registry persist, exit code). Report-only steps MUST return
  `Warning`, never `Failed`, so exit codes mean what section 8.4 says.
- Scalar sensors: cache readers only; no process launch, no network, no writes;
  type-valid fallback; numeric cache values parsed as `double` (invariant then current
  culture) and rounded, because collectors write some values with decimals.
- One-time sensors: live measurement, `Stopwatch` budget, sentinels `-1` / `-2` / `-4`,
  single compressed JSON line **under 1,000 bytes** (Hub drops any sensor value over
  1 KB; the sensor trims its arrays and long strings in a fixed order until it fits,
  section 7), nothing else on the output stream, no process launch (so no `Add-Type`,
  no `w32tm.exe`, no `ipconfig`).
- The param block sits **inside** the function (the Workspace ONE engine does not bind a
  script-scope param block, and `$PSCmdlet` is null there); entry point at the bottom.

---

## 3. KB resolution points

Each row is a fact the public build could not confirm from public documentation. The
public build handles it by runtime resolution (try candidates, record which matched, fall
back to "not measured"). The internal build replaces the candidate list with the known
answer **in the named variable only**, keeps the fallback, and records the source in the
script header as `KB-HZN-nn: <answer> (source: <internal doc id>)`.

Status values: `Unverified` (public default is a guess), `Public` (confirmed from public
docs or this lab), `Internal` (settled by the internal build; the public build keeps its
candidate list).

| ID | Fact | Public default (candidates in order) | Variable | Lands in | Verify with | Status |
|---|---|---|---|---|---|---|
| KB-HZN-01 | Agent registry roots after the Omnissa rebrand | `HKLM:\SOFTWARE\Omnissa\Horizon\Agent`, `HKLM:\SOFTWARE\VMware, Inc.\VMware VDM\Agent`; `BrandRoot` = first match | `$AgentRegistryRoots` | agent collector, agent remediation, agent one-time sensor, `vdi_platform` | `Get-ChildItem HKLM:\SOFTWARE\Omnissa -Recurse -Depth 2` on a 2406+ agent | Public (2026-11-10, VDIW11-12, agent 8.20.0 build 2609: `BrandRoot Omnissa`, so the Omnissa root exists) |
| KB-HZN-02 | Agent and Blast service short names | `wsnm` (agent), `VMBlast` (Blast); fallback DisplayName match `Horizon.*Agent`, `Blast` | `$AgentServiceNames`, `$BlastServiceNames` | all agent scripts | `Get-Service \| ? DisplayName -match 'Horizon\|Blast'` | Public (2026-11-10: agent service is `WSNM`, matched by the `wsnm` candidate; a Blast service was found and Running) |
| KB-HZN-03 | Feature service display-name pattern and exclusions | include `Horizon\|Blast\|ThinPrint\|TP AutoConnect\|USB Arbitration\|View Agent\|Omnissa`; exclude `VMware Tools\|Assist\|App Volumes\|Workspace ONE\|Intelligent Hub\|VGAuth\|vm3d\|VMwareCAF` | `$FeatureServiceInclude`, `$FeatureServiceExclude` | agent collector, remediation, one-time sensor | same as 02 on a full-feature agent install | Public with one open point (2026-11-10: 7 feature services matched; `omn-instantclone-ga` was Automatic but Stopped on a host whose clone type is Unknown, costing 5 points as `FeatureServiceStopped;ImageFault`. Decide whether that service belongs in the exclude list when the host is not an instant clone) |
| KB-HZN-04 | Where the agent records its paired Connection Server(s), and the value that proves pairing | registry value names tried under each root and its `Configuration` / `Node Manager` sub-keys: `Broker`, `BrokerList`, `Brokers`, `ConnectionServer`; plus every `ViewClient_Broker_DNS_Name` seen in sessions (`BrokerSource = Session`) | `$BrokerValueCandidates` | agent collector, one-time sensor | inspect the agent key on a paired VM; find the value that empties when the agent is unpaired | Public (2026-11-10: two brokers `wdc-vcm01` and `wdc-vcm02` found, `BrokerSource Both`, so one registry candidate matched and the session variable agreed; which value name matched is in the collector cache, not yet read) |
| KB-HZN-05 | Agent-to-broker ports and whether enhanced message security changes them | TCP 4001 and 4002, reachable if either answers | `$BrokerPorts` | agent collector, remediation step 6, one-time sensor | Horizon network ports doc for the deployed version | Public (4001/4002 JMS) |
| KB-HZN-06 | Blast performance counter set names and instance format | `VMware Blast Session Counters`, `Omnissa Blast Session Counters`; imaging set `VMware Blast Imaging Counters`, `Omnissa Blast Imaging Counters`; instance `session id: N; (main)`; counters `RTT`, `Packet Loss (Uplink)`, `Estimated Bandwidth (Uplink)`, imaging `Frame Rate` | `$BlastSessionCounterSets`, `$BlastImagingCounterSets`, `$BlastCounterNames` | agent collector, one-time sensor | `Get-Counter -ListSet '*Blast*' \| Select CounterSetName, PathsWithInstances` | Unverified for 8.20 (2026-11-10: a live Blast session was present and `BlastSessionCount` stayed 0, so neither candidate set name exists on build 2609; verify with `Get-Counter -ListSet` on VDIW11-12) |
| KB-HZN-07 | Firewall rule naming for the agent | DisplayName or DisplayGroup matching `Horizon\|Blast\|PCoIP\|VMware View\|Omnissa` | `$AgentFirewallRulePattern` | agent collector, remediation step 4 | `Get-NetFirewallRule \| ? DisplayName -match 'Horizon\|Blast\|PCoIP'` | Public (2026-11-10: 12 rules matched, none disabled) |
| KB-HZN-08 | Blast configuration key and the UDP-enabled value | `HKLM:\SOFTWARE\Omnissa\Horizon\Blast\Config`, `HKLM:\SOFTWARE\VMware, Inc.\VMware Blast\Config`; value `UdpEnabled` | `$BlastConfigRoots`, `$BlastUdpValueName` | agent collector, one-time sensor | inspect on an agent; Blast GPO reference | Unverified (2026-11-10: neither config root exists on build 2609, `BlastUdpEnabled -1`) |
| KB-HZN-09 | Per-session Blast transport (UDP vs TCP) | **not measured** in the public build: `BlastTcpFallbackSessions = -1`; `BlastTcpFallback` reason never emitted | `$BlastTransportSource` (`None`) | agent collector, one-time sensor | Blast agent log line or counter that states the transport per session | Unverified |
| KB-HZN-10 | Clone type and persistence markers | heuristic only: `InstantClone` if any `*cloneprep*` file exists under an agent log directory candidate (KB-HZN-12); else `Unknown`. `Persistence`: `NonPersistent` for `InstantClone`, else `Unknown` | `$CloneTypeDetection` | agent collector, remediation step 10, one-time sensor | compare an instant clone and a full clone: registry values under the agent key, ClonePrep artifacts | Unverified (2026-11-10: `Unknown` on VDIW11-12, which carries the `omn-instantclone-ga` service; no `*cloneprep*` file under either log directory) |
| KB-HZN-11 | Agent event providers and the event IDs that mean something | Application log, providers matching `Horizon\|VMware View\|VMware Blast\|Omnissa`, Level 1-2 counted as errors; no per-ID semantics | `$AgentEventProviderPattern`, `$AgentEventIdMeanings` (empty) | agent collector, one-time sensor, runbook | `Get-WinEvent -ListProvider '*Horizon*','*VMware*','*Omnissa*'` | Unverified (2026-11-10: 0 errors in 24 h on VDIW11-12, so the provider pattern is untested) |
| KB-HZN-12 | Agent log directories | `%ProgramData%\Omnissa\logs`, `%ProgramData%\VMware\VDM\logs` | `$AgentLogDirs` | agent collector (clone heuristic), runbook evidence | `Get-ChildItem $env:ProgramData\Omnissa, $env:ProgramData\VMware\VDM` | Unverified |
| KB-HZN-13 | `ViewClient_*` session variable names and location | `HKU\<SID>\Volatile Environment\<SessionId>`: `ViewClient_Machine_Name`, `ViewClient_IP_Address`, `ViewClient_Protocol`, `ViewClient_Broker_DNS_Name`, `ViewClient_LoggedOn_Username`, `ViewClient_Type` | `$ViewClientVarNames` | agent collector, one-time sensor | `Get-ItemProperty "Registry::HKEY_USERS\<sid>\Volatile Environment\<id>"` inside a Horizon session | Public (2026-11-10: `ViewClient_Machine_Name`, `ViewClient_IP_Address`, `ViewClient_Protocol` and `ViewClient_Broker_DNS_Name` all read on build 2609; `ClientName 172-16-44-85-Chr`, protocol Blast) |
| KB-HZN-14 | Client install detection, version and directory | Uninstall `DisplayName` matching `(Omnissa\|VMware) Horizon Client`; `DisplayVersion`; `InstallLocation` | `$ClientUninstallPattern` | client collector, remediation, one-time sensor, `vdi_platform` | Uninstall keys on a client device | Public |
| KB-HZN-15 | Client configuration: server list, policy key, certificate-check value | `HKCU\SOFTWARE\Omnissa\Horizon\Client`, `HKCU\SOFTWARE\VMware, Inc.\VMware VDM\Client`; servers from sub-key `Server`/`RecentServers` names or values `ServerURL`, `Server`; policy `HKLM\SOFTWARE\Policies\Omnissa\Horizon\Client`, `HKLM\SOFTWARE\Policies\VMware, Inc.\VMware VDM\Client` value `Server`; cert mode value `CertCheckMode` (0 = never check, 1 = warn, 2 = reject) | `$ClientRegistryRoots`, `$ClientPolicyRoots`, `$ClientServerValueCandidates`, `$CertCheckValueName` | client collector, remediation steps 3-5 and 8, one-time sensor | inspect HKCU on a configured client; client GPO reference | Unverified |
| KB-HZN-16 | Client log directory, file pattern, and the connect success / failure line patterns | `%LOCALAPPDATA%\Omnissa\Horizon\Logs`, `%LOCALAPPDATA%\VMware\VDM\Logs`; files `*horizon*client*.txt`, `vmware-horizon-client-*.txt`; success regex `(?i)connected to|session.*established|login succeeded`; failure regex `(?i)(connect(ion)? (failed|error|refused)|unable to (connect|resolve)|certificate.*(invalid|rejected)|authentication failed)` | `$ClientLogDirs`, `$ClientLogFilePatterns`, `$ClientLogSuccessRegex`, `$ClientLogFailureRegex` | client collector, one-time sensor | tail a client log after one good and one failed connection | Unverified |
| KB-HZN-17 | Client USB arbitration service name | `vmware-usbarbitrator`; fallback DisplayName `USB Arbitration` | `$ClientUsbServiceNames` | client collector, remediation step 1, one-time sensor | `Get-Service \| ? DisplayName -match 'USB Arbitration'` | Unverified |
| KB-HZN-18 | Client firewall rule naming | DisplayName matching `Horizon Client\|VMware Horizon\|Omnissa Horizon` | `$ClientFirewallRulePattern` | client collector, remediation step 2 | `Get-NetFirewallRule` on a client | Unverified |
| KB-HZN-19 | Client-side Blast port: 8443 (UAG) vs 22443 (direct), and how to tell | probe 8443 first; if closed probe 22443; `BlastPortProbed` records which answered; both closed = `BlastPortReachable 0` | `$ClientBlastPorts` | client collector, remediation step 5, one-time sensor | org network design: UAG in path or not | Internal (org-specific) |
| KB-HZN-20 | Client version floor | none (`''` disables the `ClientOutdated` reason) | `$ClientVersionFloor` | client collector, remediation step 7, one-time sensor | org standard | Internal (org decision) |
| KB-HZN-21 | PCoIP counter set name | `PCoIP Session Network Statistics`; counters `Round Trip Latency ms`, `RX Packet Loss Percent`, `TX Packet Loss Percent` | `$PcoipCounterSets`, `$PcoipCounterNames` | agent collector, one-time sensor | `Get-Counter -ListSet 'PCoIP*'` | Unverified |
| KB-HZN-22 | Horizon versions deployed in the org | not used by code; drives which `BrandRoot` the runbooks expect and the client floor | none | runbooks, README | org inventory | Internal |

A resolved KB point that turns out to be **public knowledge** (vendor documentation) MUST
be fed back into the public build's candidate list. A resolved point that is
**organisation-specific** stays in the internal build only.

---

## 4. Registry contract

Root: `HKLM:\Software\AirWatch\Extensions\VDI\Horizon`. Numerics are `String`; `-1` means
not measured; only genuine 0/1 facts are `DWORD`. Every write uses `-ErrorAction Stop`
inside the collector's single try/catch; `LastRun` is written **last** as the commit
marker.

### 4.1 `...\Horizon\Agent` (written by `Invoke-HorizonAgentStateCollection.ps1`)

| Value | Type | Meaning | Not-installed path writes |
|---|---|---|---|
| `ScriptVersion` | String | collector version | yes |
| `Installed` | DWORD | agent present (KB-HZN-01/02/14 evidence) | `0` |
| `Version` | String | agent `DisplayVersion` or `''` | `''` |
| `BrandRoot` | String | `Omnissa`, `VMware`, `''` | `''` |
| `AgentRegistryRoot` | String | root that matched | `''` |
| `AgentServiceName` | String | short name matched | |
| `AgentServiceRunning` | DWORD | | |
| `AgentServiceStartMode` | String | `Auto`, `Manual`, `Disabled`, `''` | |
| `BlastServicePresent` | DWORD | | |
| `BlastServiceRunning` | DWORD | | |
| `FeatureServiceCount` | String | automatic-start feature services found | |
| `FeatureServicesStopped` | String | `;`-joined names, `''` when none | |
| `FirewallRuleCount` | String | rules matching KB-HZN-07 | |
| `FirewallRulesDisabled` | String | count of those with `Enabled = False` | |
| `BrokerCount` | String | | |
| `BrokerList` | String | `;`-joined FQDNs | |
| `BrokerSource` | String | `Registry`, `Session`, `Both`, `None` | |
| `BrokerResolvable` | DWORD | at least one broker resolves | |
| `BrokerReachable` | DWORD | at least one broker answers on a KB-HZN-05 port | |
| `BrokerProbeResult` | String | `Reachable`, `Unreachable`, `Unresolvable`, `NoBroker`, `NotProbed` | |
| `BrokerProbeMs` | String | | |
| `SessionCount` | String | sessions whose last LSM event is logon/reconnect | |
| `DisconnectedSessionCount` | String | | |
| `OldestDisconnectedMinutes` | String | `-1` when none | |
| `LastUser` | String | user of the most recent session event | |
| `LastClientName` | String | `ViewClient_Machine_Name` of that session or `''` | |
| `LastClientIp` | String | | |
| `LastProtocol` | String | `Blast`, `PCoIP`, `RDP`, `''` | |
| `LastSessionBroker` | String | `ViewClient_Broker_DNS_Name` | |
| `BlastSessionCount` | String | counter instances found | |
| `BlastCounterSet` | String | set name that answered, `''` | |
| `BlastRttMsMax` | String | worst session | |
| `BlastPacketLossPpmMax` | String | worst session, parts per million | |
| `BlastBandwidthKbpsMin` | String | | |
| `BlastFpsMin` | String | | |
| `BlastUdpEnabled` | String | `1`, `0`, `-1` unknown | |
| `BlastTcpFallbackSessions` | String | `-1` in the public build (KB-HZN-09) | |
| `PcoipSessionCount` | String | | |
| `PcoipRttMsMax` | String | | |
| `PcoipLossPpmMax` | String | | |
| `AgentEventProvider` | String | `;`-joined providers matched | |
| `AgentErrorCount24h` | String | | |
| `AgentTopErrorIds` | String | `id:count;id:count` up to 5 | |
| `CloneType` | String | `InstantClone`, `FullClone`, `Physical`, `Unknown` | |
| `Persistence` | String | `Persistent`, `NonPersistent`, `Unknown` | |
| `TimeSkewSeconds` | String | from `w32tm /query /status`, `-1` unknown | |
| `SyncAgeHours` | String | | |
| `BootTime` | String | ISO `s` | |
| `UptimeMinutes` | String | | |
| `FaultPresentAtBoot` | DWORD | see 5.3 | |
| `HealthScore` | String | `0-100`, `-1` | `-1` |
| `HealthReason` | String | section 5.1 | `NotInstalled` |
| `Deductions` | String | `Reason:Points;...` ordered by points desc, `''` when healthy | `''` |
| `Status` | String | `Healthy`, `Degraded`, `NotApplicable`, `CollectionError` | `NotApplicable` |
| `CollectionDurationMs` | String | | yes |
| `LastAttempt` | String | ISO `o`, written first | yes |
| `LastRun` | String | ISO `o`, written last, only on success | yes |

Sub-key `...\Agent\Sessions\<SessionId>`, rewritten each run (subtree deleted first, at
most `MaxSessionsCached` = 50): `User`, `Sid`, `State` (`Active`, `Disconnected`),
`ClientName`, `ClientIp`, `Protocol`, `Broker`, `LogonTime`, `DisconnectTime`,
`DurationMin`, `DisconnectedMin`, `RttMs`, `LossPpm`, `BandwidthKbps`, `Fps` (all String).

### 4.2 `...\Horizon\Agent\Remediation` (written by `Invoke-AutoRemediateHorizonAgent.ps1`)

`ScriptVersion`, `LastRun` (o), `Status` (`Passed`, `Warning`, `Failed`), `Passed`,
`Warnings`, `Failed`, `RemediationsRun`, `RemediationErrors` (String counts), `Steps`
(String: `1:Passed;2:Failed+Rem;3:Warning;...` where `+Rem` means the resolution ran and
`+Err` means it threw), `Persistence` (String, copied from the collector cache or
`Unknown`), `ReliefOnly` (DWORD: `1` when `Persistence` is not `Persistent`),
`WhatIf` (DWORD). The guard path (no agent) writes nothing.

### 4.3 `...\Horizon\Agent\Restart` (written by `Invoke-AutoRemediateHorizonAgentRestart.ps1`)

`ScriptVersion`, `Status` (`Dispatched`, `Running`, `Completed`, `Failed`, `TimedOut`,
`SkippedCooldown`, `SkippedActiveSessions`, `SkippedNotInstalled`), `LastDispatchTime`,
`LastRunTime`, `LastRestartTime` (cooldown anchor, written only after a restart was
performed), `Result` (String message), `AgentServiceRunningAfter`,
`BlastServiceRunningAfter` (DWORD), `ActiveSessionsAtRun` (String).

### 4.4 `...\Horizon\Client` (written by `Invoke-HorizonClientStateCollection.ps1`)

| Value | Type | Meaning |
|---|---|---|
| `ScriptVersion`, `Installed` (DWORD), `Version`, `BrandRoot`, `InstallLocation` | | as agent |
| `ClientUser`, `ClientUserSid` | String | console user whose HKCU and logs were read; `''` when none |
| `UsbServiceName`, `UsbServiceRunning` | String | `-1` when service absent |
| `ServerCount`, `ServerList`, `ServerSource` | String | `Policy`, `User`, `Log`, `Multiple`, `None` |
| `ServerResolvable`, `Server443Reachable` | DWORD | |
| `BlastPortReachable` | String | `1`, `0`, `-1` not probed |
| `BlastPortProbed` | String | `8443`, `22443`, `''` |
| `ProbeResult`, `ProbeMs` | String | as agent |
| `CertCheckMode` | String | raw value or `''` |
| `LogFileUsed`, `LogParseResult` | String | `Parsed`, `NoLog`, `NoUser`, `TooLarge`, `Error` |
| `ConnectFailureCount24h`, `ConnectSuccessCount24h` | String | |
| `LastConnectTime` | String | ISO `s` or `''` |
| `LastServer`, `LastProtocol` | String | from the log when parseable |
| `VpnHealthScore`, `VpnHealthReason` | String | copied from `...\Extensions\VPN` if present, `-1`/`''` |
| `NetworkStackStatus` | String | copied from the NetworkStack remediation cache if present |
| `HealthScore`, `HealthReason`, `Deductions`, `Status`, `CollectionDurationMs`, `LastAttempt`, `LastRun` | | as agent |

Sub-key `...\Client\Remediation`: same shape as 4.2 without `Persistence` / `ReliefOnly`.

---

## 5. Health model

### 5.1 Agent deductions

Score = 100 minus the sum, floored at 0. `HealthReason` = the reason with the most
points; ties broken by table order. A metric that is `-1` never deducts.

| Order | Reason | Points | Condition | Public build can emit |
|---|---|---:|---|---|
| 1 | `AgentServiceStopped` | 40 | `AgentServiceRunning = 0` | yes |
| 2 | `NotPaired` | 35 | pairing value (KB-HZN-04) proves unpaired | **no** (KB-HZN-04) |
| 3 | `BrokerUnresolvable` | 30 | `BrokerCount > 0` and none resolves | yes |
| 4 | `BrokerUnreachable` | 30 | some broker resolves and none answers on KB-HZN-05 ports | yes |
| 5 | `BlastServiceStopped` | 25 | `BlastServicePresent = 1` and `BlastServiceRunning = 0` | yes |
| 6 | `HighPacketLoss` | 20 | `BlastPacketLossPpmMax > BlastLossWarnPpm` (20000) or `PcoipLossPpmMax >` same | yes |
| 7 | `HighRtt` | 15 | `BlastRttMsMax > BlastRttWarnMs` (250) or `PcoipRttMsMax >` same | yes |
| 8 | `BlastTcpFallback` | 15 | `BlastTcpFallbackSessions > 0` and `BlastUdpEnabled = 1` | **no** (KB-HZN-09) |
| 9 | `FirewallRulesDisabled` | 15 | `FirewallRulesDisabled > 0` | yes |
| 10 | `NoBrokerKnown` | 10 | `BrokerCount = 0` (the public build's honest substitute for `NotPaired`) | yes |
| 11 | `AgentErrorsElevated` | 10 | `AgentErrorCount24h >= AgentErrorWarnCount` (10) | yes |
| 12 | `StaleDisconnectedSessions` | 10 | `OldestDisconnectedMinutes > DisconnectedStaleMinutes` (480) | yes |
| 13 | `FeatureServiceStopped` | 5 | `FeatureServicesStopped` non-empty | yes |
| 14 | `TimeSyncStale` | 5 | `SyncAgeHours > SyncStaleHours` (48) or `TimeSkewSeconds > TimeSkewWarnSeconds` (120) | yes |
| | `Healthy` | 0 | no deductions | |
| | `NotInstalled` | score `-1` | guard path | |
| | `CollectionError` | score `-1` | unhandled exception; `LastRun` not advanced | |

The internal build MUST keep every row, including rows it cannot emit, and MAY emit rows
2 and 8 once their KB points are settled. When `NotPaired` is emitted, `NoBrokerKnown`
MUST NOT also be emitted for the same condition.

### 5.2 Client deductions

| Order | Reason | Points | Condition |
|---|---|---:|---|
| 1 | `ServerUnresolvable` | 35 | `ServerCount > 0` and none resolves |
| 2 | `ServerUnreachable443` | 35 | some server resolves, none answers on 443 |
| 3 | `BlastPortUnreachable` | 25 | 443 reachable and `BlastPortReachable = 0` |
| 4 | `RepeatedConnectFailures` | 25 | `ConnectFailureCount24h >= ConnectFailureWarnCount` (5) |
| 5 | `NoServerKnown` | 10 | `ServerCount = 0` |
| 6 | `UsbServiceStopped` | 10 | `UsbServiceRunning = 0` |
| 7 | `ClientOutdated` | 10 | `ClientVersionFloor` set and `Version < floor` (System.Version compare) |
| 8 | `CertCheckDisabled` | 5 | `CertCheckMode = 0` |
| 9 | `VpnDegraded` | 5 | `VpnHealthScore` between 0 and 49 |
| | `Healthy`, `NotInstalled`, `CollectionError` | | as agent |

### 5.3 Boot, persistence and the image-fault flag

- `BootTime` = `Win32_OperatingSystem.LastBootUpTime` formatted `s`.
- `FaultPresentAtBoot` is set to `1` on a run where (a) the cached `BootTime` differs from
  the current one or is absent (first run since boot) and (b) `HealthReason` is not
  `Healthy`. It is set to `0` on a first-run-since-boot that is healthy. On later runs in
  the same boot it is **left unchanged**. It therefore answers "was the leading fault
  already there when this machine came up".
- `hzn_agent_health_reason` appends `;ImageFault` when `FaultPresentAtBoot = 1` and the
  reason is not `Healthy`, regardless of `Persistence` (a persistent VM with a fault at
  boot is still worth knowing about). No other sensor carries the suffix.
- `Persistence` drives `ReliefOnly` in the remediation cache and the wording of step 10's
  message. It never disables a step in `Invoke-AutoRemediateHorizonAgent.ps1`. The Tier 2
  restart runs regardless of persistence.

---

## 6. Scalar sensor contract

Every sensor: `#Requires -Version 5.1`, `.NOTES` header (name, type, version, context,
timeout, requires), single `try/catch`, one `Write-Output`, immediate `return`.
Integer sensors parse the cache value as `double` and round. Boolean sensors emit nothing
when the value is absent.

**No sensor duplicates a value Workspace ONE DEX already captures.** The DEX Horizon
integration carries per-session protocol metrics (Blast and PCoIP RTT, packet loss,
bandwidth, frame rate), session state and counts, client device name, IP and version,
and the session start time; UEM application inventory carries the agent and client
versions. Those values stay in the collector cache, because the health score needs them
and the all-in-one sensor (section 7) returns them on demand, but no recurring sensor
object is created for them by default. The collector cache is the only place they are
written on the device, so the on-demand pull and the score never disagree with each
other, and DEX remains the system of record for the metric itself.

| Sensor | Type | Cache value | Fallback | Ship | DEX-native overlap |
|---|---|---|---|---|---|
| `vdi_platform` | String | none (live, < 200 ms) | `''` | **Ship** | none |
| `vdi_role` | String | none (live) | `''` | **Ship** | none |
| `hzn_agent_health_score` | Integer | `Agent\HealthScore` | `-1` | **Ship** | none (composite computed here) |
| `hzn_agent_health_reason` | String | `Agent\HealthReason` + `;ImageFault` rule | `''` | **Ship** | none |
| `hzn_agent_clone_type` | String | `Agent\CloneType` | `''` | **Ship** (confirm: Horizon pool type may be in the DEX Horizon inventory; keep until confirmed, because the device-side value also drives `Persistence`) | partial |
| `hzn_client_health_score` | Integer | `Client\HealthScore` | `-1` | **Ship** | none |
| `hzn_client_health_reason` | String | `Client\HealthReason` | `''` | **Ship** | none |
| `hzn_client_connect_failure_count_24h` | Integer | `Client\ConnectFailureCount24h` | `-1` | **Ship** | none (client log only) |
| `hzn_agent_version` | String | `Agent\Version` | | Not shipped | UEM app inventory |
| `hzn_agent_session_count` | Integer | `Agent\SessionCount` | | Not shipped | DEX Horizon sessions |
| `hzn_agent_disconnected_session_count` | Integer | `Agent\DisconnectedSessionCount` | | Not shipped | DEX Horizon session state |
| `hzn_blast_rtt_ms` | Integer | `Agent\BlastRttMsMax` | | Not shipped | DEX Horizon protocol metrics |
| `hzn_blast_packet_loss_ppm` | Integer | `Agent\BlastPacketLossPpmMax` | | Not shipped | DEX Horizon protocol metrics |
| `hzn_blast_tcp_fallback_sessions` | Integer | `Agent\BlastTcpFallbackSessions` | | Not shipped (also `-1` in the public build, KB-HZN-09) | confirm whether DEX exposes transport |
| `hzn_agent_last_client_name` | String | `Agent\LastClientName` | | Not shipped | DEX Horizon session client name |
| `hzn_client_version` | String | `Client\Version` | | Not shipped | UEM app inventory, DEX session client version |
| `hzn_client_last_connect_time` | Date Time | `Client\LastConnectTime` | | Not shipped | DEX Horizon session start |

The `Not shipped` rows have no sensor file in this repository (removed 2026-11-03 at the
user's direction). They stay in the table so the cache value names remain contracted:
the collector writes them, the all-in-one sensor returns them, and the runbooks read
`LastClientName` from either. A fleet without the DEX Horizon integration can author a
sensor for any of them from the cache value in under ten lines, following the ship-set
files as the template.

---

## 7. All-in-one JSON sensor contract

`OneTimeSensor/hzn_agent_health.ps1` and `OneTimeSensor/hzn_client_health.ps1`. One-time
only. Keys are **fixed**: the internal build MAY add keys, MUST NOT rename or remove any,
and MUST bump `Schema` when it adds one. Sentinels: `-1` unknown, `-2` not applicable,
`-4` timed out. No nulls; absent strings are `''`; arrays may be empty.

**Rev 2 (2026-11-10): compact keys and a trim ladder.** Hub stores no sensor value over
1 KB (measured, `AutomatedTesting/UEM-API-TESTING-SPEC.md`; largest value ever returned
914 bytes). The rev 1 key set serialized to 1,174 bytes with nothing installed, so it
could never be stored. Rev 2 keeps every rev 1 value under a short key (tables below,
rev 1 name beside each), emits the headline (`Score`, `Reason`, `Next`, `Detail`) first,
measures the compressed JSON and trims in a fixed order until it is under 1,000 bytes.
Everything measured is still written to the collector cache; the all-in-one sensor is
the on-demand view of it, not the system of record. The parity test compares `Score`
and `Reason`; the no-agent test asserts every rev 2 key is present.

### 7.1 `hzn_agent_health`

Phase order (cheapest first; a deadline drops later phases): 1 registry and services;
2 session inventory (LSM events + volatile environment); 3 Blast/PCoIP counters, one
sample; 4 broker DNS + TCP (max `MaxProbeHosts` = 3); 5 Application log errors; 6 related
caches; 7 score. Measured sizes: 628 bytes with no agent; a busy host with four sessions,
two brokers, three error ids and five deductions trims to 988 bytes.

| Key | Rev 1 name | Type | Phase | Notes |
|---|---|---|---|---|
| `Schema` | `SchemaVersion` | int | | `2` |
| `Comp` | `Component` | string | | `HorizonAgent` (`Platform` and `Role` dropped: implied by `Comp`) |
| `At`, `Ms`, `TO` | `Collected`, `ElapsedMs`, `TimedOut` | string, int, bool | | |
| `Inst`, `Ver`, `Root` | `Installed`, `Version`, `BrandRoot` | bool, string, string | 1 | |
| `Score`, `Reason` | `HealthScore`, `HealthReason` | int, string | 7 | same enum as 5.1; `TimeSyncStale` here uses `SyncH` only |
| `Next`, `Detail` | `NextStep`, `NextStepDetail` | string | 7 | table 7.3 |
| `Svc`, `SvcRun`, `SvcMode` | `AgentServiceName`, `AgentServiceRunning`, `AgentServiceStartMode` | string, bool, string | 1 | |
| `Blast`, `BlastRun` | `BlastServicePresent`, `BlastServiceRunning` | bool | 1 | |
| `Feat`, `FeatStop` | `FeatureServiceCount`, `FeatureServicesStopped` | int, string[] | 1 | |
| `Fw`, `FwOff` | `FirewallRuleCount`, `FirewallRulesDisabled` | int | 1 | |
| `Udp` | `BlastUdpEnabled` | int | 1 | `1`/`0`/`-1` |
| `Up`, `Clone`, `Pers` | `UptimeMinutes`, `CloneType`, `Persistence` | int, string, string | 1 | |
| `SyncH` | `SyncAgeHours` | int | 1 | W32Time `LastKnownGoodTime` as FILETIME, `-1` if unreadable |
| `Sess`, `Disc`, `DiscMin` | `SessionCount`, `DisconnectedSessionCount`, `OldestDisconnectedMinutes` | int | 2 | |
| `BSess`, `Rtt`, `Loss`, `Bw`, `Fps`, `Tcp`, `CSet` | `BlastSessionCount`, `BlastRttMsMax`, `BlastPacketLossPpmMax`, `BlastBandwidthKbpsMin`, `BlastFpsMin`, `BlastTcpFallbackSessions`, `BlastCounterSet` | int x6, string | 3 | |
| `PSess`, `PRtt`, `PLoss` | `PcoipSessionCount`, `PcoipRttMsMax`, `PcoipLossPpmMax` | int | 3 | |
| `Brk`, `BrkList`, `BrkSrc` | `BrokerCount`, `BrokerList`, `BrokerSource` | int, string[], string | 4 | |
| `BrkDns`, `BrkTcp`, `BrkRes`, `BrkMs` | `BrokerResolvable`, `BrokerReachable`, `BrokerProbeResult`, `BrokerProbeMs` | bool, bool, string, int | 4 | `BrkRes` includes `TimedOut` |
| `Err`, `Errs` | `AgentErrorCount24h`, `Errors24h` | int, int[][] | 5 | `Errs` rows are `[Id, Count]`, max 5 |
| `S` | `Sessions` | object[] | 2-3 | rows `{ Id, U, CN, IP, P, B, St, Rtt, Loss, Min, DMin }` for `Id, User, ClientName, ClientIp, Protocol, Broker, State, RttMs, LossPpm, DurationMin, DisconnectedMin`; worst `Rtt` first, max 10 before trimming |
| `Rel` | `Related` | object | 6 | `{ "AV": [Score, Reason, CacheAgeMin], "FSL": [...], "DEM": [...], "VPN": [...] }` from the AppVolumes, FSLogix, DEM and VPN caches; `-1` / `''` when absent |
| `Ded` | `Deductions` | array[] | 7 | rows `[Reason, Points]`, largest first |

Trim ladder, applied one step at a time until the compressed JSON is under 1,000 bytes:
`S` rows beyond two (last first); `Rel` to `{}`; `Errs` to `[]`; `FeatStop` to `[]`;
`BrkList` to its first entry; `CSet` to `''`; `Ded` to its first row; `S` to one row;
`Detail` to `''`; the last `S` row. The flat scalars always survive.
### 7.2 `hzn_client_health`

Phases: 1 registry, services, console user; 2 log tail; 3 server DNS + 443 + Blast port
(max 3 hosts); 4 related caches (VPN, NetworkStack); 5 score. Measured sizes: 471 bytes
with no client; a configured client with three servers and five deductions trims to
under 1,000 bytes.

| Key | Rev 1 name | Type | Phase |
|---|---|---|---|
| `Schema`, `Comp` | `SchemaVersion` (`2`), `Component` (`HorizonClient`; `Platform` and `Role` dropped) | int, string | |
| `At`, `Ms`, `TO` | `Collected`, `ElapsedMs`, `TimedOut` | string, int, bool | |
| `Inst`, `Ver`, `Root` | `Installed`, `Version`, `BrandRoot` | bool, string, string | 1 |
| `Score`, `Reason`, `Next`, `Detail` | `HealthScore`, `HealthReason`, `NextStep`, `NextStepDetail` | int, string, string, string | 5 |
| `Dir`, `User` | `InstallLocation`, `ClientUser` | string | 1 |
| `Usb`, `UsbRun` | `UsbServiceName`, `UsbServiceRunning` | string, int (`1/0/-1`) | 1 |
| `Srv`, `SrvList`, `SrvSrc` | `ServerCount`, `ServerList`, `ServerSource` | int, string[], string | 1-2 |
| `SrvDns`, `Srv443`, `BlastPort`, `BlastProbed`, `Res`, `PMs` | `ServerResolvable`, `Server443Reachable`, `BlastPortReachable`, `BlastPortProbed`, `ProbeResult`, `ProbeMs` | bool, bool, int, string, string, int | 3 |
| `Cert` | `CertCheckMode` | string | 1 |
| `Log`, `LogRes` | `LogFileUsed`, `LogParseResult` | string | 2 |
| `Fail24`, `Ok24`, `LastAt`, `LastSrv`, `LastProto` | `ConnectFailureCount24h`, `ConnectSuccessCount24h`, `LastConnectTime`, `LastServer`, `LastProtocol` | int, int, string, string, string | 2 |
| `Rel` | `Related` | object: `{ "VPN": [Score, Reason, CacheAgeMin], "Net": [...] }` | 4 |
| `Ded` | `Deductions` | array[] of `[Reason, Points]` | 5 |

Trim ladder: `Log` to its file name; `Rel` to `{}`; `SrvList` to its first entry; `Ded`
to its first row; `Dir` to `''`; `Log` to `''`; `Detail` to `''`.
### 7.3 `NextStep` mapping (both sensors)

| Reason | NextStep | NextStepDetail |
|---|---|---|
| `AgentServiceStopped`, `BlastServiceStopped`, `FeatureServiceStopped`, `FirewallRulesDisabled` | `AUTO` | `Invoke-AutoRemediateHorizonAgent.ps1 step 1/2/3/4` |
| `BrokerUnresolvable` | `AUTO` | `Invoke-AutoRemediateHorizonAgent.ps1 step 5 (flush); ADMIN if it persists` |
| `BrokerUnreachable`, `NotPaired`, `NoBrokerKnown` | `ADMIN` | `Connection Server / UAG / firewall path; see Runbook-Horizon-Agent.md phase 2` |
| `HighPacketLoss`, `HighRtt`, `BlastTcpFallback` | `ADMIN` | `network path; correlate with the endpoint via LastClientName` |
| `StaleDisconnectedSessions` | `AUTO` | `Invoke-AutoRemediateHorizonAgent.ps1 step 7 (opt-in)` |
| `AgentErrorsElevated` | `ADMIN` | `Runbook-Horizon-Agent.md phase 6` |
| `TimeSyncStale` | `AUTO` | `GenericTroubleshooting/TimeSyncHealth` |
| `ServerUnresolvable` | `AUTO` | `Invoke-AutoRemediateHorizonClient.ps1 step 3` |
| `ServerUnreachable443`, `BlastPortUnreachable` | `ADMIN` | `network / UAG; WindowsAutoRemediation/Invoke-AutoRemediateNetworkStack.ps1 first` |
| `RepeatedConnectFailures` | `USER` | `Runbook-Horizon-Client.md phase 3` |
| `UsbServiceStopped` | `AUTO` | `Invoke-AutoRemediateHorizonClient.ps1 step 1` |
| `ClientOutdated` | `ADMIN` | `deploy current client via UEM apps` |
| `CertCheckDisabled` | `ADMIN` | `client policy` |
| `VpnDegraded` | `AUTO` | `VPN/Invoke-AutoRemediateGenericVPN.ps1` |
| `NoServerKnown` | `USER` | `open the client and add the server` |
| `Healthy`, `NotInstalled` | `NONE` | `''` |

---

## 8. Remediation contract

### 8.1 `Invoke-AutoRemediateHorizonAgent.ps1`

Guard: no agent (KB-HZN-01/02 evidence) prints
`No Horizon Agent present on this device. Nothing to process.` and exits `0` without
writing the cache. Tunables (hard-coded block): `DisconnectedStaleMinutes` 480,
`BlastRttWarnMs` 250, `BlastLossWarnPpm` 20000, `AgentErrorWarnCount` 10, `NetTimeoutMs`
2000, `MaxProbeHosts` 3, `EventLookbackHours` 24, `MaxEventsScanned` 2000.

Message templates are exact. `<...>` are substitutions. Break tests match on them.

| # | Name | Mode | Detection -> Status: message | Resolution |
|---|---|---|---|---|
| 1 | `Horizon Agent Service` | AUTO | absent -> Failed: `Horizon Agent service not found (tried <names>) -- agent registry keys exist but the service is missing` / not Running or Disabled -> Failed: `Horizon Agent service (<name>) is <State> (StartMode: <mode>) -- the desktop cannot pair with the Connection Server or accept sessions` / else Passed: `Horizon Agent service (<name>) is Running (StartMode: <mode>)` | if Disabled: `sc.exe config <name> start= auto`; then `sc.exe start <name>` |
| 2 | `Horizon Blast Service` | AUTO | not present -> Passed: `Blast service not installed -- not applicable` / not Running or Disabled -> Failed: `Blast service (<name>) is <State> (StartMode: <mode>) -- Blast sessions cannot connect; PCoIP and RDP are unaffected` / Passed: `Blast service (<name>) is Running (StartMode: <mode>)` | same as 1 |
| 3 | `Horizon Feature Services` | AUTO | stopped automatic services -> Failed: `Automatic feature service(s) not running: <name (State)>, ...` / none found -> Passed: `No Horizon feature services found` / Passed: `All <n> automatic feature services running` | `sc.exe start <name>` for each; never changes start type |
| 4 | `Horizon Firewall Rules` | AUTO | none match -> Warning: `No Horizon firewall rules found -- rule naming may differ from the pattern (KB-HZN-07)` / disabled -> Failed: `<n> Horizon firewall rule(s) disabled: <DisplayName>, ...` / Passed: `<n> Horizon firewall rule(s) enabled` | `Enable-NetFirewallRule` on each disabled rule |
| 5 | `Broker DNS Resolution` | AUTO | no broker -> Warning: `No broker known on this device -- pairing state cannot be checked (KB-HZN-04)` / none resolve -> Failed: `Broker name(s) do not resolve: <list> -- DNS client or suffix search list problem` / Passed: `Broker name(s) resolve: <list>` | `ipconfig /flushdns`, `ipconfig /registerdns`, then re-resolve; message is re-evaluated by the summary only |
| 6 | `Broker Connectivity` | report | no broker or unresolvable -> Passed: `Not testable (see step 5)` / none reachable -> Warning: `Broker unreachable on TCP <ports>: <list> -- Connection Server, UAG or firewall path; not fixable from the desktop` / Passed: `Broker reachable: <host>:<port> in <ms> ms` | none |
| 7 | `Disconnected Sessions` | opt-in (`ResolveOnWarning = $false`; set `$true` to log off) | stale -> Warning: `<n> disconnected session(s) older than <threshold> min: <user> (id <id>, <min> min), ...` / Passed: `No disconnected sessions older than <threshold> min` | `logoff <id>` for each stale session |
| 8 | `Blast Session Quality` | report | no sessions -> Passed: `No Blast sessions` / over threshold -> Warning: `Worst Blast session RTT <ms> ms, loss <ppm> ppm (thresholds <rtt> ms, <loss> ppm) -- network path between client and desktop; correlate with the client device` / Passed: `Worst Blast session RTT <ms> ms, loss <ppm> ppm across <n> session(s)` | none |
| 9 | `Agent Errors` | report | over threshold -> Warning: `<n> Horizon error events in the last <h> h; top IDs: <id:count, ...>` / Passed: `<n> Horizon error events in the last <h> h` / log unreadable -> Warning: `Application log not readable -- error count unknown` | none |
| 10 | `Pairing and Clone State` | report | cache missing -> Passed: `No collector cache -- image-fault check skipped` / `FaultPresentAtBoot = 1` and `Persistence = NonPersistent` -> Warning: `Leading fault (<reason>) was present at first boot of a non-persistent clone -- fixes here are relief only; the parent image needs the same fix` / `FaultPresentAtBoot = 1` otherwise -> Warning: `Leading fault (<reason>) was present at boot -- likely image or provisioning, not session drift` / Passed: `No fault present at boot (persistence: <value>)` | none |

Step 1 reads the collector cache only for step 10; every other detection measures live
(check-then-apply). Summary, registry persist (4.2) and exit code per 8.4. After the
summary, when `ReliefOnly = 1`, print
`Persistence is <value>: remediations above are relief for this clone and revert at the next refresh.`

### 8.2 `Invoke-AutoRemediateHorizonClient.ps1`

Guard: no client (KB-HZN-14) prints
`No Horizon Client present on this device. Nothing to process.` and exits `0`.
Tunables: `ConnectFailureWarnCount` 5, `NetTimeoutMs` 2000, `MaxProbeHosts` 3,
`ClientVersionFloor` `''`, `LogTailBytes` 524288.

| # | Name | Mode | Detection -> Status: message | Resolution |
|---|---|---|---|---|
| 1 | `Horizon Client USB Service` | AUTO | absent -> Passed: `USB arbitration service not installed -- USB redirection not available` / stopped or Disabled -> Failed: `USB arbitration service (<name>) is <State> (StartMode: <mode>) -- USB redirection will fail in sessions` / Passed: `USB arbitration service (<name>) is Running (StartMode: <mode>)` | `sc.exe config ... start= auto` if Disabled; `sc.exe start` |
| 2 | `Horizon Client Firewall Rules` | AUTO | none -> Passed: `No Horizon Client firewall rules found` / disabled -> Failed: `<n> Horizon Client firewall rule(s) disabled: <list>` / Passed: `<n> Horizon Client firewall rule(s) enabled` | `Enable-NetFirewallRule` |
| 3 | `Server DNS Resolution` | AUTO | no server -> Warning: `No Horizon server configured for <user> -- nothing to test` / none resolve -> Failed: `Server name(s) do not resolve: <list>` / Passed: `Server name(s) resolve: <list>` | flush and register DNS |
| 4 | `Server Connectivity (443)` | report | not testable -> Passed: `Not testable (see step 3)` / Warning: `No Horizon server answers on TCP 443: <list> -- VPN, proxy or network path; run Invoke-AutoRemediateNetworkStack.ps1 and the VPN remediation first` / Passed: `Server reachable: <host>:443 in <ms> ms` | none |
| 5 | `Blast Port Connectivity` | report | 443 unreachable -> Passed: `Not testable (see step 4)` / Warning: `Server answers on 443 but not on Blast ports <ports>: <host> -- sessions will authenticate and then fail to display; UAG or firewall` / Passed: `Blast port <port> reachable on <host>` | none |
| 6 | `Connection Failures (24h)` | report | no log -> Passed: `No client log readable (<LogParseResult>)` / Warning: `<n> connection failure(s) in the last 24 h for <user>; last server <server>` / Passed: `<n> connection failure(s) in the last 24 h` | none |
| 7 | `Client Version` | report | floor unset -> Passed: `Client <version>; no version floor configured` / below -> Warning: `Client <version> is below the floor <floor> -- deploy the current client via UEM` / Passed: `Client <version> meets the floor <floor>` | none |
| 8 | `Certificate Checking Mode` | report | `0` -> Warning: `Certificate checking is disabled (CertCheckMode 0) -- connections to a spoofed server would succeed; set by policy` / Passed: `Certificate checking mode <value>` / unknown -> Passed: `Certificate checking mode not set (client default)` | none |
| 9 | `Endpoint Network Context` | report | VPN degraded -> Warning: `VPN health score <score> (<reason>) on this endpoint -- run VPN/Invoke-AutoRemediateGenericVPN.ps1 before troubleshooting Horizon` / Passed: `VPN health score <score or n/a>; network stack <status or n/a>` | none |
| 10 | `Client Preferences Reset` | opt-in, `Enabled = $false`, `ConfirmHighImpact` | failures >= threshold and prefs folder present -> Failed: `Client preferences reset is enabled and <n> failures were seen -- renaming <path>` / Passed: `Client preferences left in place` | rename the user's client prefs folder to `<name>.bak-<yyyyMMddHHmm>` |

### 8.3 `Invoke-AutoRemediateHorizonAgentRestart.ps1` (Tier 2)

Launcher/payload via one-shot SYSTEM scheduled task `WS1_HorizonAgentRestart`, payload at
`C:\ProgramData\AirWatch\Extensions\VDI\Horizon\Invoke-AutoRemediateHorizonAgentRestart.ps1`
(AV exclusion required, documented in README). Gates, in order, each exiting `0` with a
`Status` from 4.3:

1. Not installed -> `SkippedNotInstalled`.
2. `LastRestartTime` younger than `CooldownHours` (24) -> `SkippedCooldown`.
3. Active sessions > 0 (LSM inventory) and `ConfirmHighImpact` not true ->
   `SkippedActiveSessions`. With zero active sessions no confirmation is needed: an
   unreachable desktop with nobody on it is the exact case this script exists for.

Payload: stop Blast service, stop agent service (`sc.exe stop`, poll up to 60 s), start
agent, start Blast, poll both up to 60 s, write 4.3, unregister its task, exit `0` if both
Running else `1`. `WhatIf` honoured (dispatches, then the payload logs what it would do and
writes `Status = Completed` with `Result = WhatIf`).

### 8.4 Exit codes (both Tier 1 scripts)

`0` when no step is `Failed`, or every `Failed` step's resolution ran without throwing.
`1` when any `Failed` step had no resolution, or its resolution threw. Report-only steps
return `Warning` and never affect the exit code. Guard paths exit `0`.

---

## 9. Collector contract (what is measured and how)

### 9.1 Agent collector phases and sources

| # | What | How (public build) | Budget |
|---|---|---|---|
| 1 | Install, version, brand root, services, feature services, firewall rules, Blast config | KB-HZN-01/02/03/07/08; Uninstall keys both views | < 1 s |
| 2 | Session inventory | `Microsoft-Windows-TerminalServices-LocalSessionManager/Operational` events 21 (logon), 22 (shell start, ignored), 23 (logoff), 24 (disconnect), 25 (reconnect) in the last `SessionLookbackHours` (72), `MaxEventsScanned` newest first; last event per session ID decides `State`; sessions whose last event is 23 are dropped; user SID from the event; `ViewClient_*` from `Registry::HKEY_USERS\<SID>\Volatile Environment\<SessionId>` (KB-HZN-13). RDS sessions without `ViewClient_*` are still counted | < 3 s |
| 3 | Blast / PCoIP counters | `Get-Counter -Counter '\<set>(*)\<counter>' -MaxSamples 1`, candidate sets in order (KB-HZN-06/21); instance parsed with `session id:\s*(\d+)`; per-session rows joined to phase 2 by session ID | < 3 s |
| 4 | Broker list and probe | KB-HZN-04 values plus session brokers; `Resolve-DnsName -Type A -DnsOnly` per host; TCP on KB-HZN-05 ports; stop at first reachable | < 8 s |
| 5 | Agent errors | `Get-WinEvent -FilterHashtable @{LogName='Application'; Level=1,2; StartTime=-24h} -MaxEvents` then provider filter (KB-HZN-11) in memory | < 4 s |
| 6 | Clone type, persistence, time sync, boot | KB-HZN-10/12; `w32tm.exe /query /status` parsed as SCOM does; `Win32_OperatingSystem` | < 2 s |
| 7 | Score, `FaultPresentAtBoot`, registry write | section 5 | < 1 s |

### 9.2 Client collector phases and sources

| # | What | How |
|---|---|---|
| 1 | Install, version, brand root, USB service, console user | KB-HZN-14/17; `Win32_ComputerSystem.UserName` -> SID via `NTAccount.Translate`; profile path from `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\<SID>\ProfileImagePath` |
| 2 | Servers | policy roots, then user roots (KB-HZN-15); de-duplicated, hostnames only (URL parsed) |
| 3 | Log tail | newest file matching KB-HZN-16 under the user's log dirs; read the last `LogTailBytes` only; lines with a parseable timestamp inside 24 h classified by the success/failure regexes; `LastServer` from the newest success line when it contains a hostname |
| 4 | Probes | DNS, 443, Blast ports (KB-HZN-19) on at most `MaxProbeHosts` |
| 5 | Related caches | `...\Extensions\VPN` (`HealthScore`, `HealthReason`), `...\Extensions\NetworkStack\Remediation\Status` if present |
| 6 | Score and write | section 5.2 |

---

## 10. Runbook contract

Both runbooks follow `VPN/Runbook-VPN-Agent.md`: trigger, agent context, goal, scope table
(reason -> fixable generically?), intervention key, sensor reference, triage phase that
reads the all-in-one sensor first when the console supports it and the scalar set
otherwise, one phase per reason group, Quickflow summary, decision tree, escalation
criteria with the evidence list. The agent runbook's phase 2 ("broker unreachable")
MUST instruct the agent to pull `hzn_client_health` on the device named by
`hzn_agent_last_client_name` before escalating.

---

## 11. Test contract

### 11.1 `Test-HorizonNoAgentPath.ps1` (runs on this lab VM today)

Non-destructive. Runs each script in a child `powershell.exe -File` the way UEM does and
asserts: collector writes `Installed 0`, `HealthScore -1`, `HealthReason NotInstalled`,
`Status NotApplicable`, `LastRun`, exit `0`; remediation prints the guard line, writes no
`Remediation` key, exit `0`; Tier 2 writes `SkippedNotInstalled`, registers no task, exit
`0`; every scalar sensor emits exactly one line of the right type and the documented
fallback; both one-time sensors emit one line of valid JSON with `Installed false`,
`HealthReason NotInstalled`, every key present. Then seeds a synthetic agent cache
(every 4.1 value) and asserts every scalar sensor returns the seeded value, including the
`;ImageFault` suffix rule and the decimal parse. Cleans up its seeded keys. Ran
2026-11-10 13:21 on `CBRADLEYSWIN11`: `20261110_132101` PASS, 49 of 49 assertions
(one-time sensors 627 and 470 bytes, 406 and 283 ms).

### 11.2 `Test-HorizonScoreParity.ps1` (needs a Horizon host)

Runs the collector, then `hzn_agent_health.ps1` within 60 s, asserts identical
`HealthScore` and `HealthReason`, and prints both deduction lists side by side. Same for
the client pair on an endpoint. Non-destructive. Ran 2026-11-10 12:17 on `VDIW11-12`:
`20261110_121717` PASS (agent 95 = 95, `FeatureServiceStopped:5` on both sides).

### 11.3 `Invoke-AutoRemediateHorizonAgent_BreakTest.ps1` (needs a Horizon host)

| Break | Lever | Verify | Expect | Validate | Restore |
|---|---|---|---|---|---|
| `AgentServiceDisabled` | stop agent service, set Disabled | `Win32_Service` StartMode Disabled, State Stopped | Fixed | StartMode Auto, Running within 60 s, line `[Failed ] Horizon Agent Service: ... -> Remediation ran`, exit 0, cache `RemediationsRun >= 1` | captured mode and state |
| `BlastServiceStopped` | stop Blast service | Stopped | Fixed | Running within 60 s, line `[Failed ] Horizon Blast Service: ... -> Remediation ran`, exit 0 | captured state |
| `FirewallRuleDisabled` | `Disable-NetFirewallRule` on one matching rule | `Enabled False` | Fixed | `Enabled True`, line `[Failed ] Horizon Firewall Rules: 1 Horizon firewall rule(s) disabled: ... -> Remediation ran`, exit 0 | re-enable if it was enabled |
| `BrokerPortBlocked` | outbound firewall block rule (`DEXTest-BrokerBlock`; the name must not match the script's rule pattern) for TCP 4001 and 4002 to every resolved broker | `Test-NetConnection` to the broker on 4001 fails while DNS still resolves | ReportedOnly | line `[Warning] Broker Connectivity: Broker unreachable on TCP ...`, exit 0, and the block rule still present afterwards (the remediation must not touch rules it did not match) | remove the block rule |
| `StaleDisconnectedSession` | second interactive logon (`-TestUser`), `tsdiscon`, cache `OldestDisconnectedMinutes` cannot be aged, so the harness passes `-DisconnectedStaleMinutes 0` through a tunable override env var `HZN_TEST_DisconnectedStaleMinutes` honoured only when `C:\Temp\FixReport\.dex-test-machine` exists | session Disconnected | ReportedOnly by default; Fixed with `-EnableSessionLogoff` (sets `ResolveOnWarning`) | line `[Warning] Disconnected Sessions: 1 disconnected session(s) ...`; with logoff enabled the session is gone | log off the test session |

`AgentServiceDisabled` and `BlastServiceStopped` may pair; `StaleDisconnectedSession`
runs alone. Not covered: `NotPaired` (needs unpairing), clone-state step 10 (needs an
instant clone), feature services (installation-dependent; the harness lists what it finds).
First run 2026-11-10 12:19 on `VDIW11-12` (harness 1.0.0): `7e1a44595c17` Passed, all four
ungated breaks drawn and validated, 90.7 s of script time. Harness 1.0.1 renames the block
rule because the first name contained "Horizon" and the script counted it as a Horizon rule.

### 11.4 `Invoke-AutoRemediateHorizonClient_BreakTest.ps1` (needs a client; installable on this VM)

| Break | Lever | Expect | Validate |
|---|---|---|---|
| `UsbServiceDisabled` | stop + Disabled | Fixed | Running, not Disabled, line `[Failed ] Horizon Client USB Service: ...-> Remediation ran` |
| `ClientFirewallRuleDisabled` | disable one rule | Fixed | enabled, line `[Failed ] Horizon Client Firewall Rules: ...` |
| `ServerHostsPoisoned` | hosts entry for the configured server to `127.0.0.2` | ReportedOnly | `[Warning] Server Connectivity (443): No Horizon server answers ...` |
| `ServerUnresolvable` | configure a server name under a non-existent TLD in the test user's HKCU (`-TestServer`) | ReportedOnly | `[Failed ] Server DNS Resolution: Server name(s) do not resolve: ... -> Remediation ran` and still unresolvable afterwards |

### 11.5 Lab hosts needed

| Host | For | Notes |
|---|---|---|
| Horizon session host, full clone, paired | agent collector, sensors, remediation breaks, parity, Tier 2 | the primary target |
| Horizon instant-clone pool member | step 10, `CloneType`, `Persistence`, `FaultPresentAtBoot` across a refresh | a pool of 1 is enough |
| Connection Server reachable from both | broker probes | existing lab CS |
| This VM with Horizon Client installed | client collector, sensors, client breaks, client parity | free download; no broker needed for most breaks |

---

## 12. What the internal build may change

| May | Must not |
|---|---|
| Replace candidate lists in KB-point variables with the settled answer, keeping the fallback | Rename any variable, file, sensor, registry value, JSON key, reason, step or tunable |
| Emit `NotPaired` and `BlastTcpFallback` once KB-HZN-04 / 09 are settled | Change any point value or threshold default without recording it in the header and README |
| Append steps after step 10 (agent) / step 10 (client), numbered 11+ | Reorder or renumber existing steps, or change their message templates |
| Add JSON keys (bump `SchemaVersion`) | Remove or retype existing keys |
| Add scalar sensors from the cache-only list | Change the ship set's names or types |
| Set `$SCRIPT_VARIANT = 'internal'`; `ScriptVersion` is written as `<version>+internal` | Commit anything to this repository |
| Add organisation-specific runbook phases | Remove the public phases |

The internal build MUST pass `Test-HorizonNoAgentPath.ps1`, `Test-HorizonScoreParity.ps1`
and both break tests from this repository unchanged, and MUST record the spec revision it
was built from in every script header (`Built from VDI/Horizon/SPEC.md rev 1`).

---

## 13. Change control

1. A change to any interface (sections 4-8) bumps the spec revision and is recorded in a
   `## Revision history` entry at the end of this file with the date and the reason.
2. A KB point whose answer is public knowledge is moved to `Public` and the candidate list
   in the public code is updated to put the answer first.
3. A KB point whose answer is organisation-specific is marked `Internal` here with no
   answer recorded.
4. The inventory and `TEST-VALIDATION.md` rows are updated in the same change.

## Revision history

- **Rev 1, 2026-11-03.** Initial contract. Decisions carried in from `VDI/DESIGN.md`:
  top-level `VDI/` folder, relief fixes run on non-persistent hosts, `FaultPresentAtBoot`
  and the `;ImageFault` suffix, report-only steps return `Warning`. Same day: the scalar
  ship set was cut from 15 to 6 because no sensor may duplicate a value DEX already
  captures (session metrics, session state, client name, versions); the nine overlapping
  sensor files were removed from the repository, their cache values stay contracted.
- **Rev 2, 2026-11-10.** Section 7 one-time sensors move to `Schema` 2 with compact keys
  and a trim ladder, because Hub stores no sensor value over 1 KB and the rev 1 key set
  was 1,174 bytes with nothing installed (`hzn_agent_health.ps1` 1.1.0,
  `hzn_client_health.ps1` 1.1.0, both contract tests updated). Every rev 1 value is kept
  under its new key; `Platform` and `Role` are dropped as implied by `Comp`. Same day:
  `Invoke-HorizonAgentStateCollection.ps1` 1.0.2 trimmed from 34,393 to 32,306
  characters (comments only) to fit the 32,767 limit; inventory rows and the UEM test
  manifest entries for all 15 files added; first UEM run against the enrolled Horizon
  session host `VDIW11-12` (smart group `Test_HorizonHost`). Afternoon:
  `_AutomatedTesting/Invoke-AutoRemediateHorizonAgent_BreakTest.ps1` 1.0.0 written to
  11.3 (the session break is gated behind `-IncludeSessionBreaks` and uses `tsdiscon`
  on the harness's own session instead of a `-TestUser` logon) and delivered to the host
  as UEM internal app 4791 with the whole Horizon set under `C:\DEXLab`. Results from the
  host: parity `20261110_121717` PASS, break test `7e1a44595c17` Passed (all four ungated
  breaks); harness 1.0.1 renames the block rule; `Invoke-AutoRemediateHorizonAgent.ps1`
  is `4) Complete - Tested`. Then `Test-HorizonNoAgentPath.ps1` `20261110_132101` PASS on
  the lab VM (49 of 49), which moves the agent collector, `hzn_agent_health` and the three
  agent scalar sensors to `4) Complete - Tested` as well; client side waits on a client.
