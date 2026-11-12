# AVD Session Host and Windows App Troubleshooter -- Build Contract

**Spec revision:** 1 (2026-11-10). **Design:** `VDI/DESIGN.md` sections 1, 2, 5.
**Scope:** the Azure Virtual Desktop session host (agent, boot loader, side-by-side stack,
Geneva monitoring task, RDP transport) and the Microsoft endpoint client (Windows App,
with the out-of-support Remote Desktop client `msrdc` detected as legacy). Windows 365
Cloud PCs run the same agent and are covered by the session-host set with
`Persistence = Persistent`. FSLogix, classic RDS licensing and app attach are phase 6 and
are not in this contract. Phase 0 platform sensors (`vdi_platform`, `vdi_role`) are
already shipped under the Horizon contract and are reused unchanged.

## 0. How to use this document

Same rules as `VDI/Horizon/SPEC.md` section 0: two builds (public, this repository;
internal, a private repository built by a corporate-approved agent from this spec plus
the internal knowledge base), interchangeable at every interface. **MUST** / **MUST
NOT** are hard constraints; **SHOULD** is the default unless the script header says why
not; **MAY** is a choice. `GENERAL-SCRIPTS-SENSORS_RUNBOOK.md` applies throughout.

Research basis: every vendor fact below was read from the current Microsoft Learn pages
on 2026-11-10 (listed in `VDI/DESIGN.md` section 8) unless its row in section 3 says
otherwise. Nothing has been verified on an AVD host yet; the lab has none (section 11.5).

---

## 1. File manifest

All paths relative to `VDI/`. Versions start at `1.0.0`. Every deployable `.ps1` MUST
measure under 32,767 characters (`(Get-Content -Raw).Length`, runbook rule 15, binding
until at least March 2027); the budget column is the planning ceiling. The session-host
remediation is specified as **two parts from the start**: fourteen steps plus the pasted
`Get-DexEvent` reader do not fit one script, and the SCOM precedent says split by step
order, never by concern.

| Path | Kind | Context | Budget (chars) | Timeout (deploy) |
|---|---|---|---|---|
| `Microsoft/Invoke-AvdSessionHostStateCollection.ps1` | script, scheduled 15-30 min | System | 31,500 (split Part1/Part2 if the internal build needs more) | 30 s budget, deploy at 60 s |
| `Microsoft/Invoke-MicrosoftRdClientStateCollection.ps1` | script, scheduled 30-60 min | System | 28,000 | 30 s budget, deploy at 60 s |
| `Microsoft/Invoke-AutoRemediateAvdSessionHostPart1.ps1` | script, on demand / Quickflow; steps 1-7 | System | 30,000 | 30 s, deploy at 60 s |
| `Microsoft/Invoke-AutoRemediateAvdSessionHostPart2.ps1` | script, on demand / Quickflow; steps 8-14 | System | 30,000 | 30 s, deploy at 60 s |
| `Microsoft/Invoke-AutoRemediateMicrosoftRdClient.ps1` | script, on demand / Quickflow | System | 28,000 | 30 s, deploy at 60 s |
| `Microsoft/Invoke-AutoRemediateAvdAgentRestart.ps1` | script, Tier 2 launcher/payload | System | 24,000 | launcher 10 s; payload 5 min self-limit |
| `Microsoft/Sensors/avd_host_*.ps1` (4), `avd_client_*.ps1` (3) | sensors, ship set | System | 4,000 each | < 2 s |
| `Microsoft/OneTimeSensor/avd_host_health.ps1` | sensor, String (JSON), one-time only | System | 32,000 | 25 s self-enforced |
| `Microsoft/OneTimeSensor/avd_client_health.ps1` | sensor, String (JSON), one-time only | System | 26,000 | 25 s self-enforced |
| `Microsoft/Runbook-AVD-SessionHost.md` | agent runbook | | | |
| `Microsoft/Runbook-AVD-Client.md` | agent runbook | | | |
| `Microsoft/README.md` | deployment guide | | | |
| `Microsoft/_AutomatedTesting/Invoke-AutoRemediateAvdSessionHost_BreakTest.ps1` | break test (both parts) | Administrator | | |
| `Microsoft/_AutomatedTesting/Invoke-AutoRemediateMicrosoftRdClient_BreakTest.ps1` | break test | Administrator | | |
| `Microsoft/_AutomatedTesting/Test-AvdScoreParity.ps1` | non-destructive | Administrator | | |
| `Microsoft/_AutomatedTesting/Test-AvdNoAgentPath.ps1` | non-destructive, runs on any device | Administrator | | |

Inventory rows (`SCRIPT-INVENTORY-CSV.csv`) and `AutomatedTesting/TEST-VALIDATION.md`
entries are required for every script and sensor above.

---

## 2. Runtime contract

Everything in `VDI/Horizon/SPEC.md` section 2 applies, plus the rules learned since it
was written (2026-11-05, `TEST-VALIDATION.md` 13.2.z):

- **Windows PowerShell 5.1 is the floor and the target.** Hub runs 5.1 on x64 and an
  embedded PowerShell 7.2 on ARM64; nothing may rely on 7-only syntax or behaviour.
- **No `Get-WinEvent` anywhere.** Every event read goes through the pasted
  `Get-DexEvent` / `Get-DexEventLog` .NET reader (`Invoke-AutoRemediateWord.ps1` is the
  clean copy; compact form permitted near the size limit). It fails under Hub's ARM64
  engine in every form.
- **Scheduled tasks are read through COM** (`New-Object -ComObject Schedule.Service`),
  not `schtasks.exe` and not the `ScheduledTasks` module, so the Geneva task check works
  in the one-time sensor (no process launch) and under both engines.
- **IMDS and broker health are HTTP GETs**, `System.Net.HttpWebRequest`, `Proxy = $null`
  for IMDS (the metadata service must be reached without a proxy), 2,000 ms timeout,
  one attempt, never a retry.
- Collectors complete in 30 s worst case: event passes bounded by `MaxEventsScanned`
  (2000), TCP probes `BeginConnect` / `WaitOne` / `EndConnect` with `NetTimeoutMs`
  (2000), at most `MaxProbeHosts` (5) hosts per run, one performance-counter sample.
- One-time sensors: single compressed JSON line **under 1,000 bytes** by construction
  (Hub stores nothing over 1 KB), Schema 2 compact keys and a trim ladder (section 7),
  no process launch, no writes, 25 s `Stopwatch`.
- Sensors run on several Hub threads at once; scalar sensors are pure cache readers and
  need no mutex. Collectors hold `Global\DEX-AvdHostCollector` /
  `Global\DEX-RdClientCollector` for their lifetime.
- Report-only steps return `Warning`, never `Failed`.

---

## 3. KB resolution points

Same mechanism as Horizon: a named variable per unconfirmed fact, candidates tried in
order, the match recorded in the cache, fallback to "not measured". The internal build
replaces the candidate list in the named variable only and records
`KB-AVD-nn: <answer> (source: <internal doc id>)` in the header. Status: `Unverified`
(public default is a guess), `Public` (confirmed from Microsoft docs or a lab host),
`Internal` (organisation-specific).

| ID | Fact | Public default (candidates in order) | Variable | Lands in | Verify with | Status |
|---|---|---|---|---|---|---|
| KB-AVD-00 | Whether Omnissa Intelligence / DEX has any AVD or Windows 365 data source (session metrics, client name, versions) that a sensor here would duplicate | none found publicly (DEX virtual-session data is Horizon only) | none; drives the "DEX-native overlap" column in section 6 | sensor ship set | internal DEX data catalog | Internal |
| KB-AVD-01 | Agent registry key and the values that matter | `HKLM:\SOFTWARE\Microsoft\RDInfraAgent`: `IsRegistered` (DWORD), `RegistrationToken` (blank when registered), `BrokerResourceIdURI`, `BrokerResourceIdURIGlobal`, `HostPoolArmPath` (secondary source; host pool name is its last segment) | `$AgentRegistryKey`, `$AgentValueNames` | host collector, Part1 steps 7-8, Tier 2, one-time sensor, `vdi_platform` | `Get-ItemProperty HKLM:\SOFTWARE\Microsoft\RDInfraAgent` on a registered host | Public for `IsRegistered`, `RegistrationToken`, `BrokerResourceIdURI*` (troubleshoot-agent doc); Unverified for `HostPoolArmPath` |
| KB-AVD-02 | Service short names | `RDAgentBootLoader` (display `Remote Desktop Agent Loader`), `RDAgent` (display `Remote Desktop Services Infrastructure Agent`), `TermService`, `UmRdpService`; fallback DisplayName match | `$BootLoaderServiceNames`, `$AgentServiceNames` | all host scripts | `Get-Service RDAgentBootLoader, RDAgent` | Public (troubleshoot-agent doc names both) |
| KB-AVD-03 | Geneva monitoring agent: how it runs and what proves it healthy | **not a service**: scheduled task `GenevaTask_<version>` MUST exist, be Enabled and not Disabled/Queued-forever; uninstall entry `Remote Desktop Services Infrastructure Geneva Agent`; installer `Microsoft.RDInfra.Geneva.Installer-x64-<ver>.msi` and log `GenevaInstall.txt` under `C:\Program Files\Microsoft RDInfra` | `$GenevaTaskPattern` (`^GenevaTask_`), `$RdInfraRoot` | host collector, Part1 step 6, one-time sensor | `(New-Object -ComObject Schedule.Service)` root folder tasks matching `GenevaTask_*`; `Get-ChildItem 'C:\Program Files\Microsoft RDInfra'` | Public (troubleshoot-agent MonitoringAgentCheck section); the "more than one version installed" rule is also documented |
| KB-AVD-04 | Side-by-side stack listener evidence in the registry | `HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\rdp-sxs*` sub-keys with `fEnableWinStation = 1` and `fReverseConnectMode = 1`; `WinStations\ReverseConnectionListener` names the active one; `Terminal Server\ClusterSettings\SessionDirectoryListener` = `rdp-sxs<version>`; `qwinsta.exe` `STATE = Listen` for `rdp-sxs*` (collector only) | `$SxsWinStationPattern`, `$SxsListenerValueNames` | host collector, Part1 step 5, one-time sensor (registry only) | `qwinsta` and the WinStations key on a healthy host | Public (troubleshoot-agent stack-listener section) |
| KB-AVD-05 | Required FQDNs the host probes, commercial cloud | broker from `BrokerResourceIdURI` host and `BrokerResourceIdURIGlobal` host (`rdbroker.wvd.microsoft.com`), `login.microsoftonline.com`, `gcs.prod.monitoring.core.windows.net`, `mrsglobalsteus2prod.blob.core.windows.net`, then FQDNs listed in the newest `WVD-Agent` event **3701** (region-specific); all TCP 443; capped at `MaxProbeHosts` | `$RequiredUrlCandidates`, `$UrlEventId` (3701) | host collector, Part2 step 8, one-time sensor | required-fqdn-endpoint doc; event 3701 on a registered host | Public (FQDN list and the 3701 tip are both documented); 3701 message format Unverified |
| KB-AVD-06 | Required FQDNs, Azure Government | detected when `BrokerResourceIdURI` ends in `.wvd.azure.us` or IMDS `azEnvironment` is `AzureUSGovernmentCloud`: `rdbroker.wvd.azure.us`, `login.microsoftonline.us`, `gcs.monitoring.core.usgovcloudapi.net`, `mrsglobalstugviffx.blob.core.usgovcloudapi.net` | `$RequiredUrlCandidatesGov`, `$CloudDetection` | same | required-fqdn-endpoint doc, Government tab | Public |
| KB-AVD-07 | Broker health endpoint and its success text | `<BrokerResourceIdURI>/api/health` and `<BrokerResourceIdURIGlobal>/api/health` return HTTP 200 with body containing `RD Broker is Healthy` | `$BrokerHealthPath`, `$BrokerHealthyText` | host collector, Part2 step 8, one-time sensor | troubleshoot-agent INVALID_FORM section | Public |
| KB-AVD-08 | IMDS probe | `http://169.254.169.254/metadata/instance?api-version=2021-02-01`, header `Metadata: true`, no proxy, 2 s; parse `compute.azEnvironment`, `compute.vmSize`, `compute.name`, `compute.location` | `$ImdsUrl`, `$ImdsApiVersion` | host collector, Part2 step 9, one-time sensor, persistence (KB-AVD-14) | any Azure VM | Public (IMDS doc; the MetaDataServiceCheck remedy names 169.254.169.254) |
| KB-AVD-09 | Agent event providers and the IDs with meaning | Application log, providers `WVD-Agent`, `WVD-Agent-Updater`, `RDAgentBootLoader`, `MsiInstaller` (errors only); ID map: `3277` install/update/registration failure (message tokens `INVALID_REGISTRATION_TOKEN`, `EXPIRED_MACHINE_TOKEN`, `INVALID_FORM`, `ENDPOINT_NOT_FOUND`, `NAME_ALREADY_REGISTERED`, `InstallMsiException`, `DownloadMsiException`, `InstallationHealthCheckFailedException`), `3019` web-socket transport URLs unreachable, `3703` gateway URL not accessible, `3389` update reverted (`MissingMethodException`, .NET below 4.7.2), `3701`/`3702` FQDN lists (informational); System log `7000`/`7011` for `RDAgentBootLoader` start timeouts | `$AgentEventProviders`, `$AgentEventIdMeanings`, `$RegistrationFailureTokens` | host collector, Part1 step 7, Part2 step 13, one-time sensor, runbook | troubleshoot-agent doc; a host with a known failure | Public for the IDs and tokens listed; the full provider event catalogue Unverified |
| KB-AVD-10 | Health-check outcomes as the agent reports them locally | **not readable locally in the public build**: the agent reports `DomainJoinedCheck`, `DomainTrustCheck`, `SxSStackListenerCheck`, `UrlsAccessibleCheck`, `MonitoringAgentCheck`, `MetaDataServiceCheck`, `AppAttachHealthCheck`, `WebRTCRedirectorCheck`, `SupportedEncryptionCheck`, `FSLogixHealthCheck` to the broker; no documented registry or event carries the per-check result. The collector **re-derives** the first six itself (section 9.1) and leaves `HealthCheckSource = Derived` | `$HealthCheckSource`, `$HealthCheckEventIds` (empty) | host collector, one-time sensor | find a local artifact (registry under `RDInfraAgent`, or a WVD-Agent event) that lists the check names with pass/fail | Unverified |
| KB-AVD-11 | RDP transport per session (Shortpath vs TCP) | `Microsoft-Windows-RemoteDesktopServices-RdpCoreCDV/Operational` event **135**, message `The multi-transport connection finished for tunnel: 1, its transport type set to UDP` (or `TCP`, with a reason such as `UDP Handshake Timeout`); newest per session in the last 24 h | `$TransportLogName`, `$TransportEventId` (135), `$TransportRegex` (`transport type set to (UDP\|TCP)`) | host collector, Part2 step 10, one-time sensor | configure-rdp-shortpath doc "Verify" tab | Public (documented); per-session correlation Unverified |
| KB-AVD-12 | Transport policy values | `HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\SelectTransport` (`1` = TCP only, `2` = UDP and TCP, absent = default UDP on); managed-network listener `fUseUdpPortRedirector = 1` with `UdpPortNumber` (default `3390`) under the same policy key; per-type Shortpath disables (NAT traversal / Relay) value names unknown | `$TransportPolicyKey`, `$SelectTransportValue`, `$ShortpathListenerValues`, `$ShortpathTypeValues` (empty) | host collector, Part2 step 10, one-time sensor | configure-rdp-shortpath doc confirms `SelectTransport`; the listener values come from the AVD ADMX and need a host with the policy applied | Public for `SelectTransport`; Unverified for the listener and per-type values |
| KB-AVD-13 | Network quality counters | `\RemoteFX Network(<instance>)\Current UDP RTT`, `Current TCP RTT`, `Current UDP Bandwidth`, `Loss Rate`; `\User Input Delay per Session(<instance>)\Max Input Delay`; one instance per session suffixed with the session number, no `_Total`; `Max Input Delay` is enabled by default on Windows 10 1809+ / Server 2019+ | `$NetworkCounterSet`, `$NetworkCounterNames`, `$InputDelayCounter` | host collector, Part2 step 10, one-time sensor | `Get-Counter -ListSet 'RemoteFX Network','User Input Delay per Session'` | Public (Insights glossary, RemoteFX counter doc); instance naming Unverified on multi-session |
| KB-AVD-14 | Windows 365 Cloud PC marker and persistence | candidates in order: `Win32_ComputerSystemProduct.Name` or `Win32_ComputerSystem.Model` matching `^Cloud PC`; computer name matching `^CPC-`; neither matched = not a Cloud PC. `Persistence`: `Persistent` for a Cloud PC, else `Unknown` (pooled vs personal host pool is not knowable on-device) | `$CloudPcDetection`, `$CloudPcModelPattern`, `$CloudPcNamePattern` | host collector, Part2 step 14, one-time sensor | `Get-CimInstance Win32_ComputerSystemProduct` on a Cloud PC; Intune lists Cloud PC models as `Cloud PC Enterprise 2vCPU/8GB/128GB` | Unverified (no documented on-device marker; the model string is a secondary-source observation) |
| KB-AVD-15 | Teams media optimisation evidence | `HKLM:\SOFTWARE\Microsoft\Teams\IsWVDEnvironment = 1`; WebRTC Redirector service short name `RDWebRTCSvc` (display `Remote Desktop WebRTC Redirector Service`); new Teams may use SlimCore instead (bundled with Windows App >= 1.3.252), so a missing redirector is a Warning, not a failure | `$TeamsRegistryKey`, `$WebRtcServiceNames` | host collector, Part2 step 11, one-time sensor | teams-on-avd doc confirms the registry value; `Get-Service *WebRTC*` for the short name | Public for the registry value; Unverified for the service short name |
| KB-AVD-16 | Agent, stack and boot loader versions and install folders | uninstall `DisplayName` exactly `Remote Desktop Services Infrastructure Agent`, `Remote Desktop Agent Boot Loader`, `Remote Desktop Services SxS Network Stack`, `Remote Desktop Services Infrastructure Geneva Agent` (highest `DisplayVersion` of each; count of each, since three agent/stack versions are kept and the doc says to uninstall old Geneva versions); folders `C:\Program Files\Microsoft RDInfra\RDAgent_<ver>` holding `WVDAgentUrlTool.exe` (needs agent >= 1.0.2944.400 and .NET 4.6.2) | `$UninstallNames`, `$RdInfraRoot` | host collector, Part2 step 13, one-time sensor, `vdi_platform` | Programs and Features on a host | Public (names from the troubleshoot-agent uninstall list; tool folder from the URL-tool doc) |
| KB-AVD-17 | Per-session client name and address | `HKU\<SID>\Volatile Environment\<SessionId>` values `CLIENTNAME`, `SESSIONNAME` (carries the `rdp-sxs<ver>#n` stack name); client address from the TS-LSM event 21 message | `$SessionVarNames` | host collector, one-time sensor | read inside an AVD session | Unverified (standard RDP behaviour; not AVD-specific documentation) |
| KB-AVD-18 | Windows App package identity and per-user registration | package family `MicrosoftCorporationII.Windows365_8wekyb3d8bbwe`; all-users staging under `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Applications\MicrosoftCorporationII.Windows365_*`; per-user registration under `HKU\<SID>\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages\MicrosoftCorporationII.Windows365_<ver>_<arch>__8wekyb3d8bbwe`; version parsed from the key name; Store product `9N1F85V9T8BN` | `$WindowsAppPackagePattern` | client collector, remediation, one-time sensor, `vdi_platform` | `Get-AppxPackage -AllUsers *Windows365*` on a device with Windows App | Unverified (family name is a secondary-source observation; the Store id is documented) |
| KB-AVD-19 | Legacy client detection | `HKLM:\SOFTWARE\Microsoft\MSRDC` and uninstall `DisplayName` `Remote Desktop`; **out of support since 2026-03-27**; `mstsc.exe` file version noted but never scored (RDS only) | `$MsrdcRegistryKey`, `$LegacyClientEos` | client collector, remediation step 5, one-time sensor | Windows IT Pro blog end-of-support post | Public |
| KB-AVD-20 | Client service endpoints to probe | `rdweb.wvd.microsoft.com`, `rdgateway.wvd.microsoft.com`, `rdbroker.wvd.microsoft.com`, `login.microsoftonline.com`, `windows.cloud.microsoft`; TCP 443; Government: `rdweb.wvd.azure.us`, `login.microsoftonline.us`; capped at `MaxProbeHosts` | `$ClientEndpointCandidates`, `$ClientEndpointCandidatesGov` | client collector, remediation steps 1-2, one-time sensor | required-fqdn-endpoint doc, end-user devices table | Public (the `*.wvd.microsoft.com` and `windows.cloud.microsoft` wildcards are documented; the specific `rdweb`/`rdgateway`/`rdbroker` hosts are the conventional names and need confirming) |
| KB-AVD-21 | Client connection events | `Microsoft-Windows-TerminalServices-RDPClient/Operational`: `1024` connect attempt (server name in message), `1026` disconnect with `Reason = <code>`, `1027` connected (domain, session id), `1105` multi-transport established/ended; reason codes `1` user disconnect, `2` user logoff, others are failures | `$ClientEventLogName`, `$ClientEventIds`, `$BenignDisconnectReasons` (`1,2`), `$UdpEvidenceEventId` (1105, meaning Unverified) | client collector, remediation step 4, one-time sensor | one good and one failed Windows App connection, then read the log | Unverified for 1105's meaning; Public for 1024/1026/1027 |
| KB-AVD-22 | Windows App log folder and failure line patterns | `%LOCALAPPDATA%\Temp\DiagOutputDir\Windows365\Logs` (the doc says `%temp%\DiagOutputDir\Windows365\Logs`); legacy `msrdc` ETL traces `%LOCALAPPDATA%\Temp\DiagOutputDir\RdClientAutoTrace` (known to grow to gigabytes); failure regex `(?i)(error\|failed\|exception).{0,80}(connect\|feed\|workspace\|token\|auth)` | `$ClientLogDirs`, `$ClientTraceDir`, `$ClientLogFailureRegex` | client collector, remediation steps 4 and 10, one-time sensor | troubleshoot-collect-logs doc (Windows tab) | Public for the folders; Unverified for the regex |
| KB-AVD-23 | Client UDP policy | `HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\Client\fClientDisableUDP` (`1` = UDP off) | `$ClientUdpPolicyValue` | client collector, remediation step 3, one-time sensor | configure-rdp-shortpath doc, client section | Public |
| KB-AVD-24 | Windows App version floor | none (`''` disables `ClientOutdated`) | `$ClientVersionFloor` | client collector, remediation step 6 | org standard | Internal |
| KB-AVD-25 | Where Windows App stores subscribed workspaces for a user | not measured in the public build (`WorkspaceCount = -1`); legacy `msrdc` feeds under `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RdClientRadc\Feeds` are counted when present | `$WorkspaceSource` (`Msrdc` or `None`) | client collector, one-time sensor | Process Monitor on a subscribed Windows App | Unverified |
| KB-AVD-26 | Hub on pooled AVD multi-session hosts and on Cloud PCs | unknown whether target customers enrol multi-session hosts or Cloud PCs in UEM; the scripts assume Hub is present wherever they run | none | README, delivery decisions | UEM Windows enrollment docs; customer inventory | Internal |

A resolved KB point that turns out to be **public knowledge** MUST be fed back into the
public build's candidate list. An organisation-specific answer stays internal.

### 3.1 Lab findings, 2026-11-10 (`avdpersonal-1`, UEM run `DEXTEST` probe bundle, 6 of 6 passed)

Host: personal host pool `avdpersonal`, Azure `Standard_D2as_v5`, centralus, image
`windows-11/win11-26h2-ent`, Entra-joined (not AD), agent 1.0.15732.100, stack
1.0.2608.28600, no remote session at probe time. Raw values:
`_resolutionresults/uem-results/test-result-avd-kbprobe.json`. These findings override
the table above where they differ; the code MUST follow this list.

| KB | Finding | Status now |
|---|---|---|
| 01 | Key present; `IsRegistered = 1`, `RegistrationToken` blank, `BrokerResourceIdURI` and `BrokerResourceIdURIGlobal` present, and **`HostPoolArmPath` exists** (`.../Microsoft.DesktopVirtualization/hostpools/avdpersonal`). Broker hosts carry a tenant GUID prefix (`<guid>.rdbroker-g-us-r1.wvd.microsoft.com`), so the static name `rdbroker.wvd.microsoft.com` is a fallback only. Other values seen: `AADTenantId`, `AgentExecutionMode`, `AgentFeatureConfiguration`, `AgentState`, `AgentUpdateActivityId`, `AttestedIMDSData`, `AzureResourceId`, `AzureSystemLabelState`, `AzureVmId`, `AzureVmImageId`, `AzureVmImageType`, `AzureVmLocation` (list truncated at 220 characters; the rest is unread) | Public |
| 02 | `RDAgentBootLoader` and `RDAgent` both exist as services, Running, start mode Auto. `TermService` and `UmRdpService` are Running with start mode **Manual**, so start mode MUST NOT be scored for them. The `RDAgent` display name does not contain "Remote Desktop Services Infra"; match on the short name | Public |
| 03 | Task `GenevaTask_46-24-3` (dashes, not dots), Enabled, state 4 (Running), last result 267009 (still running), which is the healthy shape. A second agent task exists: `RDAgentBootLoader_Startup`. The Geneva uninstall name **includes the version** (`Remote Desktop Services Infrastructure Geneva Agent 46.24.3`), so match by prefix | Public |
| 04 | One WinStation `rdp-sxs260828600` with `fEnableWinStation = 1`, `fReverseConnectMode = 1`; `ReverseConnectionListener` and `SessionDirectoryListener` both name it | Public |
| 05 | Event 3701 message is `Accessible URLs: <host> <host> ...`, space-separated, tenant-GUID-prefixed hosts. Parse with `\S+\.(wvd\.microsoft\.com\|windows\.net\|microsoft\.com)` after the colon | Public |
| 07 | Both health URLs return 200 with a **JSON** body beginning `{ "Health": "RDBroker is ...`; there is no space in `RDBroker`. `$BrokerHealthyText` becomes the regex `RD ?Broker is Healthy` | Public |
| 08 | IMDS 200 in 89 ms; `azEnvironment` is **`AzurePublicCloud`** (not `AzureCloud`); `publisher`, `offer/sku`, `vmSize`, `location`, `name`, `resourceGroupName` all populated. The `Cloud` cache value keeps the IMDS spelling | Public |
| 09 | 54 events in 7 days: providers `RDAgentBootLoader` (44) and `WVD-Agent` (10); ids `3389` x38, `3019` x8, `0` x6, `3701` x2; **none at Error level**. On a healthy host 3389 and 3019 are routine informational events, so an id alone means nothing: count Level <= 2 only, and classify 3277/3389/3019 by message token | Public for the id/level rule; message text of 3389/3019 unread |
| 10 | `AgentState` and `AgentFeatureConfiguration` under the agent key are the first local leads for the agent's own status; values unread | Unverified, lead found |
| 11, 17 | No RdpCoreCDV 135/131 events and no remote-session volatile environment: nobody was connected | Unverified, needs a live session |
| 12, 15 | No transport, Shortpath or Teams values set on this host (all defaults) | Unverified |
| 13 | `User Input Delay per Session` instances are the bare session ids plus `Max` (`0`, `1`, `Max`); read the per-id instances, ignore `Max`. `RemoteFX Network` has no instance without a remote session | Public for input delay; RemoteFX instance naming Unverified |
| 14 | A personal AVD VM reports `Microsoft Corporation` / `Virtual Machine` with product version `Hyper-V UEFI Release v4.1`: nothing distinguishes it from any Azure VM, so the Cloud PC model pattern does not false-positive here. New persistence lead: the host pool type is not in what was read, but `AzureVmImageType` and the unread tail of the agent key are worth a second probe | Unverified for Cloud PC; personal-vs-pooled still open |
| 16 | Uninstall names confirmed: `Remote Desktop Agent Boot Loader` (two versions installed, 1.0.13074.100 and 1.0.8925.0), `Remote Desktop Services Infrastructure Agent`, `Remote Desktop Services SxS Network Stack`, Geneva as in 03. Multiple boot-loader versions are normal and MUST NOT warn | Public |
| other | `ProductName` reads `Windows 10 Enterprise` on a Windows 11 26H2 image, so `OsSkuSupported` MUST test `EditionID` (`Enterprise`, `ServerRdsh` for multi-session, `Server*`), not the product name. Entra-joined with `PartOfDomain = 0`: `SecureChannelOk = -2`, `DomainJoinedCheck` passes on either join. `WinHttpSettings` exists on every device, so proxy detection must decode the blob, not test for the value. DNS is Azure-provided `168.63.129.16` | Public |

Open defect found by the same run: `vdi_platform` returned `Multiple` and `vdi_role`
returned `Both` on this host. The Appx pattern
`^MicrosoftCorporationII\.Windows365|WindowsApp|...` is unanchored after the first
alternative, so any package containing `WindowsApp` (for example the Windows App
Runtime) counts as a Microsoft client. Fixed in both sensors at 1.0.1 (pattern grouped).

Second probe, same day (3 of 3 passed, `test-result-avd-kbprobe2.json`):

- `Multiple` / `Both` are **correct** for this host: an Omnissa Horizon Client 8.20.0 is
  installed on it (with DEM and Workspace ONE Experience Management), so it is an AVD
  session host and a Horizon client at once. The AVD collector and the Horizon client
  collector both apply to it; smart groups for AVD hosts MUST key on the AVD agent, not
  on `vdi_platform = AVD`.
- **KB-AVD-10 lead confirmed:** the agent key has sub-keys `HealthCheckReport`,
  `AVDAgentProvisioning`, `Data` and `SxsStack`. `HealthCheckReport` is the likely local
  source for the per-check results (contents unread; next probe). Top-level `AgentState`
  is `19` on this Available host, `AgentExecutionMode` `0`, `AzureVmImageType`
  `Marketplace`, and a `BrokerURI` value exists alongside the two `BrokerResourceIdURI*`
  values (regional host without the tenant GUID prefix).

---

## 4. Registry contract

Root: `HKLM:\Software\AirWatch\Extensions\VDI\Microsoft`. Numerics are `String`; `-1`
means not measured; only genuine 0/1 facts are `DWORD`. Every write uses
`-ErrorAction Stop` inside the collector's single try/catch; `LastRun` is written
**last** as the commit marker; `Sessions\<Id>` is rewritten wholesale each run and
capped at `MaxSessionsCached` (50).

### 4.1 `...\Microsoft\SessionHost` (written by `Invoke-AvdSessionHostStateCollection.ps1`)

| Value | Type | Meaning |
|---|---|---|
| `Installed` | DWORD | agent key present (KB-AVD-01) |
| `AgentVersion`, `BootLoaderVersion`, `StackVersion`, `GenevaVersion` | String | highest `DisplayVersion` per KB-AVD-16, `''` if absent |
| `AgentVersionCount`, `StackVersionCount`, `GenevaVersionCount` | String | installed versions of each (the agent keeps three) |
| `IsRegistered` | DWORD | from the agent key; `-1` as String when absent |
| `RegistrationTokenPresent` | DWORD | token value non-blank (with `IsRegistered = 0` means a pending re-registration; with `1` means the last registration did not clear it) |
| `BrokerUri`, `BrokerUriGlobal`, `HostPoolArmPath`, `HostPoolName` | String | from the agent key; `HostPoolName` is the ARM path's last segment or `''` |
| `Cloud` | String | `AzureCloud`, `AzureUSGovernment`, `Unknown` (KB-AVD-06) |
| `BootLoaderRunning`, `AgentRunning`, `TermServiceRunning`, `UmRdpRunning` | DWORD | |
| `BootLoaderStartMode`, `AgentStartMode` | String | |
| `BootLoaderStartTimeouts24h` | String | System log 7000/7011 for the boot loader |
| `TsConnectionsDenied`, `TsConnectionsDeniedByPolicy` | DWORD | `fDenyTSConnections` live key and policy key |
| `SxsListenerOk` | DWORD | at least one `rdp-sxs*` WinStation enabled and in reverse-connect mode, and the cluster listener names it (KB-AVD-04) |
| `SxsListenerName`, `SxsListenerState` | String | e.g. `rdp-sxs240906400`, `Listen` from `qwinsta` or `Unknown` |
| `GenevaTaskPresent`, `GenevaTaskEnabled` | DWORD | KB-AVD-03 |
| `GenevaTaskName`, `GenevaTaskState`, `GenevaTaskLastResult` | String | COM `State` enum name; last run result as decimal |
| `DomainJoined`, `EntraJoined` | DWORD | `Win32_ComputerSystem.PartOfDomain`; `HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo` has a sub-key |
| `SecureChannelOk` | String | `1`/`0`/`-1`; `Test-ComputerSecureChannel` only when AD-joined, else `-2` |
| `UrlProbeCount`, `UrlReachableCount`, `UrlUnreachable` | String | `UrlUnreachable` is `;`-joined host names |
| `UrlSource` | String | `Registry`, `Registry+Event3701`, `Static` |
| `BrokerHealthy`, `BrokerHealthyGlobal` | String | `1`/`0`/`-1` from KB-AVD-07 |
| `BrokerHealthMs` | String | |
| `ImdsReachable` | String | `1`/`0`/`-1` |
| `ImdsVmSize`, `ImdsLocation`, `ImdsEnvironment` | String | |
| `DerivedStatus` | String | `Available`, `NeedsAssistance`, `Unavailable`, `NotRegistered`, `Unknown` (section 5.3) |
| `HealthCheckFailures` | String | `;`-joined derived check names, e.g. `UrlsAccessibleCheck;MonitoringAgentCheck` |
| `HealthCheckSource` | String | `Derived` (KB-AVD-10) |
| `SelectTransportPolicy` | String | `-1` absent, else the value |
| `ShortpathListenerEnabled`, `ShortpathListenerPort` | String | KB-AVD-12 |
| `ShortpathFirewallRuleOk` | String | `1`/`0`/`-2` (not applicable when the listener is off) |
| `SessionCount`, `ActiveSessionCount`, `DisconnectedSessionCount`, `OldestDisconnectedMinutes` | String | LSM inventory |
| `UdpSessionCount`, `TcpSessionCount`, `TransportUnknownCount` | String | event 135 per session (KB-AVD-11) |
| `RdpRttMsMax`, `RdpLossPpmMax`, `RdpUdpBandwidthKbpsMin`, `InputDelayMsMax` | String | counters (KB-AVD-13); `-1` when no instance |
| `LastClientName`, `LastClientIp` | String | newest session's `CLIENTNAME` / address (correlation key; cache only, not a sensor) |
| `TeamsWvdEnvironment` | String | `1`/`0`/`-1` |
| `WebRtcServicePresent`, `WebRtcServiceRunning` | DWORD | |
| `AgentErrorCount24h`, `AgentErrorIds24h` | String | `AgentErrorIds24h` = `id:count;...` top 5 |
| `RegistrationFailureToken` | String | newest 3277 token from KB-AVD-09, `''` if none in 24 h |
| `SystemDriveFreeGb` | String | one decimal |
| `DotNetRelease` | String | `NDP\v4\Full\Release` value |
| `OsSku`, `OsSkuSupported` | String | `ProductName`; `1` when it contains `Enterprise`, `multi-session` or `Server`, else `0` |
| `UptimeMinutes`, `BootTime` | String | |
| `CloudPc`, `Persistence` | String | `1`/`0`; `Persistent` / `Unknown` (KB-AVD-14) |
| `FaultPresentAtBoot` | DWORD | section 5.3 of the Horizon spec, same rule |
| `HealthScore`, `HealthReason`, `Deductions` | String | `Deductions` = `Reason:Points;...` |
| `CollectionResult`, `ScriptVersion`, `RunId`, `LastRun` | String | `LastRun` last |
| `Sessions\<Id>` | sub-key | `User`, `ClientName`, `ClientIp`, `State`, `Transport`, `StackName`, `LogonTime`, `DurationMin`, `DisconnectedMin`, `RttMs`, `LossPpm`, `InputDelayMs` |

### 4.2 `...\Microsoft\SessionHost\Remediation` (written by both Part1 and Part2)

Each part writes its own slice: `Part1Steps`, `Part1Result`, `Part1LastRun`,
`Part1RemediationsRun` and the `Part2*` equivalents, plus shared `ReliefOnly` (DWORD),
`Persistence`, `ScriptVersion`. `PartNSteps` is `1:Passed;2:Failed+Rem;...` using the
global step numbers.

### 4.3 `...\Microsoft\SessionHost\Restart` (written by `Invoke-AutoRemediateAvdAgentRestart.ps1`)

`Status` (`Dispatched`, `Running`, `Completed`, `TimedOut`, `Failed`,
`SkippedNotInstalled`, `SkippedCooldown`, `SkippedActiveSessions`), `Result`,
`LastRestartTime`, `RegisteredAfter` (`1`/`0`/`-1`), `BootLoaderRunningAfter`,
`AgentRunningAfter`, `ScriptVersion`.

### 4.4 `...\Microsoft\Client` (written by `Invoke-MicrosoftRdClientStateCollection.ps1`)

| Value | Type | Meaning |
|---|---|---|
| `Installed` | DWORD | any of Windows App, `msrdc` present |
| `WindowsAppPresent`, `WindowsAppVersion`, `WindowsAppUser` | DWORD, String, String | KB-AVD-18; version for the console user, else the highest all-users version |
| `LegacyClientPresent`, `LegacyClientVersion` | DWORD, String | KB-AVD-19 |
| `MstscVersion` | String | file version, informational |
| `ClientType` | String | `WindowsApp`, `Msrdc`, `Both`, `None` |
| `ConsoleUser`, `ConsoleUserSid` | String | |
| `UdpDisabledByPolicy` | String | `1`/`0`/`-1` (KB-AVD-23) |
| `Cloud` | String | `AzureCloud` default; `AzureUSGovernment` when a Government feed is seen |
| `EndpointProbeCount`, `EndpointReachableCount`, `EndpointUnreachable`, `EndpointResolvable` | String | KB-AVD-20 |
| `WorkspaceCount`, `WorkspaceSource` | String | KB-AVD-25 |
| `ConnectAttempts24h`, `ConnectSuccess24h`, `ConnectFailures24h` | String | KB-AVD-21 |
| `LastConnectTime`, `LastServer`, `LastDisconnectReason`, `LastDisconnectTime` | String | |
| `UdpEvidence24h` | String | count of 1105 events, `-1` when the meaning is unsettled |
| `LogFileUsed`, `LogParseResult`, `LogFailureCount24h` | String | KB-AVD-22 |
| `TraceFolderMb` | String | size of `RdClientAutoTrace`, `-2` when absent |
| `TermsrvCredentialCount` | String | `cmdkey /list` parse |
| `VpnHealthScore`, `VpnHealthReason`, `NetworkStackStatus` | String | related caches |
| `HealthScore`, `HealthReason`, `Deductions`, `CollectionResult`, `ScriptVersion`, `RunId`, `LastRun` | String | |

---

## 5. Health model

### 5.1 Session host deductions

Score = 100 minus the sum, floored at 0. `HealthReason` = the reason with the most
points; ties broken by table order. A metric that is `-1` never deducts.

| Order | Reason | Points | Condition | Public build can emit |
|---|---|---:|---|---|
| 1 | `BootLoaderStopped` | 40 | `BootLoaderRunning = 0` (the documented first fix for Unavailable) | yes |
| 2 | `NotRegistered` | 40 | `IsRegistered = 0` | yes |
| 3 | `AgentStopped` | 35 | `AgentRunning = 0` while the boot loader runs | yes |
| 4 | `SxsListenerMissing` | 30 | `SxsListenerOk = 0` (fatal check) | yes |
| 5 | `TsConnectionsDenied` | 30 | `TsConnectionsDenied = 1` | yes |
| 6 | `DomainTrustBroken` | 30 | `SecureChannelOk = 0` (fatal check) | yes |
| 7 | `BrokerUnreachable` | 30 | `BrokerHealthy = 0` and `BrokerHealthyGlobal = 0`, or the broker host is in `UrlUnreachable` | yes |
| 8 | `RdsServiceStopped` | 25 | `TermServiceRunning = 0` or `UmRdpRunning = 0` | yes |
| 9 | `RegistrationFailing` | 25 | `RegistrationFailureToken` non-empty and `IsRegistered = 1` (the agent is logging 3277 while claiming registered) | yes |
| 10 | `RequiredUrlsUnreachable` | 20 | `UrlUnreachable` non-empty, broker excluded (Needs Assistance class) | yes |
| 11 | `ImdsUnreachable` | 20 | `ImdsReachable = 0` | yes |
| 12 | `UnsupportedSku` | 20 | `OsSkuSupported = 0` (the stack installs but never activates) | yes |
| 13 | `MonitoringAgentUnhealthy` | 10 | `GenevaTaskPresent = 0` or `GenevaTaskEnabled = 0` | yes |
| 14 | `HighInputDelay` | 15 | `InputDelayMsMax > InputDelayWarnMs` (500, the Insights "poor" floor) | yes |
| 15 | `HighRdpRtt` | 15 | `RdpRttMsMax > RdpRttWarnMs` (250) | yes |
| 16 | `HighPacketLoss` | 15 | `RdpLossPpmMax > RdpLossWarnPpm` (20000) | yes |
| 17 | `RdpTcpFallback` | 10 | `TcpSessionCount > 0` and `SelectTransportPolicy <> 1` (UDP expected, sessions on TCP) | yes |
| 18 | `TransportForcedTcp` | 10 | `SelectTransportPolicy = 1` | yes |
| 19 | `TeamsRedirectorStopped` | 10 | `TeamsWvdEnvironment = 1` and `WebRtcServicePresent = 1` and `WebRtcServiceRunning = 0` | yes |
| 20 | `StaleDisconnectedSessions` | 10 | `OldestDisconnectedMinutes > DisconnectedStaleMinutes` (480) | yes |
| 21 | `AgentErrorsElevated` | 10 | `AgentErrorCount24h >= AgentErrorWarnCount` (10) | yes |
| 22 | `LowDiskSpace` | 10 | `SystemDriveFreeGb < DiskFreeWarnGb` (2; agent updates fail with `DownloadMsiException`) | yes |
| 23 | `BootLoaderStartTimeouts` | 5 | `BootLoaderStartTimeouts24h > 0` | yes |
| 24 | `DotNetBelow472` | 5 | `DotNetRelease < 461808` (agent updates revert) | yes |
| 25 | `ShortpathRuleMissing` | 5 | `ShortpathListenerEnabled = 1` and `ShortpathFirewallRuleOk = 0` | yes |
| | `Healthy` | 0 | no deductions | |
| | `NotInstalled` | score `-1` | guard path | |
| | `CollectionError` | score `-1` | unhandled exception; `LastRun` not advanced | |

`NotRegistered` and `RegistrationFailing` are mutually exclusive by condition.
`BrokerUnreachable` and `RequiredUrlsUnreachable` may both fire (the broker host is
excluded from the second). The internal build MUST keep every row and MAY add rows
numbered 26+ once KB-AVD-10 settles (e.g. `AppAttachUnhealthy`, `FsLogixUnhealthy` from
the agent's own check results).

### 5.2 Client deductions

| Order | Reason | Points | Condition |
|---|---|---:|---|
| 1 | `EndpointUnresolvable` | 35 | `EndpointResolvable = 0` for every probed endpoint |
| 2 | `EndpointUnreachable443` | 35 | some endpoint resolves, none answers on 443 |
| 3 | `RepeatedConnectFailures` | 25 | `ConnectFailures24h >= ConnectFailureWarnCount` (5) |
| 4 | `NoClientInstalled` | 20 | `Installed = 0` (the device is in a VDI-user smart group by assignment, so absence is a finding) |
| 5 | `LegacyClientOnly` | 15 | `LegacyClientPresent = 1` and `WindowsAppPresent = 0` (out of support since 2026-03-27) |
| 6 | `UdpDisabledByPolicy` | 10 | `UdpDisabledByPolicy = 1` (Shortpath impossible) |
| 7 | `ClientOutdated` | 10 | `ClientVersionFloor` set and `WindowsAppVersion < floor` |
| 8 | `LegacyClientPresent` | 5 | `LegacyClientPresent = 1` and Windows App also present |
| 9 | `TraceFolderBloated` | 5 | `TraceFolderMb > TraceFolderWarnMb` (2048) |
| 10 | `VpnDegraded` | 5 | `VpnHealthScore` between 0 and 49 |
| | `Healthy`, `NotInstalled`, `CollectionError` | | as host; note `NotInstalled` is only the one-time sensor's guard, the collector scores `NoClientInstalled` |

### 5.3 Derived status

`DerivedStatus` approximates the portal's session-host status from local evidence so a
help-desk agent sees `Unavailable` without portal access:

| Status | Condition (first match) |
|---|---|
| `NotRegistered` | `IsRegistered = 0` |
| `Unavailable` | any of `BootLoaderStopped`, `AgentStopped`, `SxsListenerMissing`, `DomainTrustBroken`, `BrokerUnreachable`, `TsConnectionsDenied`, `RdsServiceStopped` |
| `NeedsAssistance` | any of `RequiredUrlsUnreachable`, `ImdsUnreachable`, `MonitoringAgentUnhealthy` (the three documented Needs Assistance checks) |
| `Available` | none of the above and `Installed = 1` |
| `Unknown` | `Installed = 0` or collection error |

`HealthCheckFailures` lists the derived check names in the agent's own vocabulary
(`DomainJoinedCheck` when neither AD nor Entra joined, `DomainTrustCheck`,
`SxSStackListenerCheck`, `UrlsAccessibleCheck`, `MonitoringAgentCheck`,
`MetaDataServiceCheck`) so the runbook and the portal speak the same names.

### 5.4 Boot, persistence and the image-fault flag

Identical to the Horizon rule (`VDI/Horizon/SPEC.md` 5.3): `FaultPresentAtBoot` decided
on the first run after boot, `avd_host_health_reason` appends `;ImageFault` when it is
`1` and the reason is not `Healthy`. `Persistence` is `Persistent` for a Cloud PC and
`Unknown` otherwise; it drives `ReliefOnly` wording only. A Cloud PC is never a pooled
clone, so `ReliefOnly = 0` there.

---

## 6. Scalar sensor contract

No sensor may duplicate a value DEX already captures. KB-AVD-00 found no AVD data source
in DEX publicly, so the overlap column is provisional; the ship set is kept lean anyway
because the all-in-one sensor (section 7) returns everything on demand.

| Sensor | Type | Cache value | Fallback | DEX-native overlap | Ship |
|---|---|---|---|---|---|
| `avd_host_health_score` | Integer | `SessionHost\HealthScore` | `-1` | none | **ship** |
| `avd_host_health_reason` | String | `SessionHost\HealthReason` (+ `;ImageFault`) | `''` | none | **ship** |
| `avd_host_status` | String | `SessionHost\DerivedStatus` | `''` | portal only, not DEX | **ship** |
| `avd_host_pool_name` | String | `SessionHost\HostPoolName` | `''` | none (correlation key for the console) | **ship** |
| `avd_client_health_score` | Integer | `Client\HealthScore` | `-1` | none | **ship** |
| `avd_client_health_reason` | String | `Client\HealthReason` | `''` | none | **ship** |
| `avd_client_connect_failure_count_24h` | Integer | `Client\ConnectFailures24h` | `-1` | none found | **ship** |
| `avd_host_registered` | Boolean | `IsRegistered` | bare return | none; folded into `avd_host_status` | not shipped |
| `avd_host_session_count`, `avd_host_disconnected_session_count` | Integer | | | session state (verify KB-AVD-00) | not shipped |
| `rdp_transport`, `rdp_rtt_ms`, `rdp_loss_ppm`, `avd_host_input_delay_ms` | | | | protocol metrics (verify KB-AVD-00) | not shipped |
| `avd_host_agent_version`, `avd_client_type`, `avd_client_version` | | | | UEM app inventory (MSI and Appx) | not shipped |
| `avd_host_last_client_name` | String | | | client device name (verify) | not shipped; cache only |
| `avd_host_teams_redirector_ready` | Boolean | | | none; folded into the reason | not shipped |

Sensor template rules are the Horizon ones (cache reader, double-parse then round,
type-valid fallback, `Write-Output`, `return`). Not-shipped values stay contracted in
the cache; a customer may promote any of them without touching a collector.

---

## 7. All-in-one JSON sensor contract

`OneTimeSensor/avd_host_health.ps1` and `OneTimeSensor/avd_client_health.ps1`. One-time
only. Schema 2 compact keys from day one (the Horizon rev 2 lesson), fixed: the
internal build MAY add keys, MUST NOT rename or remove any, MUST bump `Schema` when it
adds one. Sentinels `-1` unknown, `-2` not applicable, `-4` timed out; no nulls; the
headline (`Score`, `Reason`, `Next`, `Detail`) is emitted first; the compressed JSON is
measured and trimmed in the fixed order below until under 1,000 bytes.

### 7.1 `avd_host_health`

Phase order: 1 registry, services, uninstall entries, Geneva task (COM), policy values;
2 session inventory (LSM events + volatile environment) and transport events (135);
3 counters, one sample; 4 broker health GET, IMDS GET, URL TCP probes (max 5 hosts);
5 Application log errors; 6 related caches; 7 score.

| Key | Long name | Type | Phase | Notes |
|---|---|---|---|---|
| `Schema`, `Comp` | `SchemaVersion` (`2`), `Component` (`AvdSessionHost`) | int, string | | |
| `At`, `Ms`, `TO` | `Collected`, `ElapsedMs`, `TimedOut` | string, int, bool | | |
| `Inst`, `Ver`, `Stack`, `Cloud` | `Installed`, `AgentVersion`, `StackVersion`, `Cloud` | bool, string, string, string | 1 | |
| `Score`, `Reason`, `Next`, `Detail` | `HealthScore`, `HealthReason`, `NextStep`, `NextStepDetail` | int, string, string, string | 7 | |
| `Stat`, `Chk` | `DerivedStatus`, `HealthCheckFailures` | string, string[] | 7 | 5.3 |
| `Reg`, `Tok`, `Pool` | `IsRegistered`, `RegistrationTokenPresent`, `HostPoolName` | int, int, string | 1 | |
| `BL`, `BLRun`, `BLMode`, `Ag`, `AgRun` | `BootLoaderService`, `BootLoaderRunning`, `BootLoaderStartMode`, `AgentService`, `AgentRunning` | string, bool, string, string, bool | 1 | |
| `TS`, `Deny`, `DenyPol` | `TermServiceRunning`, `TsConnectionsDenied`, `TsConnectionsDeniedByPolicy` | bool, int, int | 1 | |
| `Sxs`, `SxsName` | `SxsListenerOk`, `SxsListenerName` | int, string | 1 | registry only here (no `qwinsta`) |
| `Gen`, `GenOn`, `GenSt` | `GenevaTaskPresent`, `GenevaTaskEnabled`, `GenevaTaskState` | int, int, string | 1 | |
| `Dom`, `Entra`, `Trust` | `DomainJoined`, `EntraJoined`, `SecureChannelOk` | int, int, int | 1 | `Trust` is `-2` when not AD-joined; the sensor skips the secure-channel test when under 8 s remain |
| `Sku`, `SkuOk`, `Net`, `Disk` | `OsSku`, `OsSkuSupported`, `DotNetRelease`, `SystemDriveFreeGb` | string, int, int, number | 1 | |
| `Up`, `CPC`, `Pers` | `UptimeMinutes`, `CloudPc`, `Persistence` | int, int, string | 1 | |
| `Sess`, `Act`, `Disc`, `DiscMin` | `SessionCount`, `ActiveSessionCount`, `DisconnectedSessionCount`, `OldestDisconnectedMinutes` | int | 2 | |
| `Udp`, `Tcp`, `TrPol`, `SP`, `SPPort`, `SPRule` | `UdpSessionCount`, `TcpSessionCount`, `SelectTransportPolicy`, `ShortpathListenerEnabled`, `ShortpathListenerPort`, `ShortpathFirewallRuleOk` | int | 1-2 | |
| `Rtt`, `Loss`, `Bw`, `InD` | `RdpRttMsMax`, `RdpLossPpmMax`, `RdpUdpBandwidthKbpsMin`, `InputDelayMsMax` | int | 3 | |
| `Brk`, `BrkG`, `BrkOk`, `BrkGOk`, `BrkMs` | `BrokerUri` host, `BrokerUriGlobal` host, `BrokerHealthy`, `BrokerHealthyGlobal`, `BrokerHealthMs` | string, string, int, int, int | 4 | |
| `Imds`, `VmSize`, `Loc` | `ImdsReachable`, `ImdsVmSize`, `ImdsLocation` | int, string, string | 4 | |
| `Url`, `UrlOk`, `UrlBad`, `UrlSrc` | `UrlProbeCount`, `UrlReachableCount`, `UrlUnreachable`, `UrlSource` | int, int, string[], string | 4 | |
| `Teams`, `WebRtc`, `WebRtcRun` | `TeamsWvdEnvironment`, `WebRtcServicePresent`, `WebRtcServiceRunning` | int | 1 | |
| `Err`, `Errs`, `RegTok` | `AgentErrorCount24h`, `Errors24h`, `RegistrationFailureToken` | int, int[][], string | 5 | `Errs` rows `[Id, Count]`, max 5 |
| `S` | `Sessions` | object[] | 2-3 | rows `{ Id, U, CN, IP, St, Tr, Min, DMin, Rtt, Loss, InD }`; worst `InD` first; max 10 before trimming |
| `Rel` | `Related` | object | 6 | `{ "FSL": [Score, Reason, CacheAgeMin], "VPN": [...] }` from the FSLogix and VPN caches |
| `Ded` | `Deductions` | array[] | 7 | rows `[Reason, Points]`, largest first |

Trim ladder: `S` rows beyond two (last first); `Rel` to `{}`; `Errs` to `[]`; `UrlBad`
to its first entry; `Chk` to its first entry; `Ded` to its first row; `S` to one row;
`Detail` to `''`; `Sku` to `''`; the last `S` row. Flat scalars always survive. Target
sizes: under 650 bytes with no agent; a busy host trims to under 1,000.

### 7.2 `avd_client_health`

Phases: 1 registry, packages, console user, policy; 2 RDPClient events and log tail;
3 endpoint DNS + 443 (max 5 hosts); 4 related caches; 5 score.

| Key | Long name | Type | Phase |
|---|---|---|---|
| `Schema`, `Comp` | `SchemaVersion` (`2`), `Component` (`MicrosoftRdClient`) | int, string | |
| `At`, `Ms`, `TO` | `Collected`, `ElapsedMs`, `TimedOut` | string, int, bool | |
| `Inst`, `Type`, `Ver`, `LegVer`, `User` | `Installed`, `ClientType`, `WindowsAppVersion`, `LegacyClientVersion`, `ConsoleUser` | bool, string, string, string, string | 1 |
| `Score`, `Reason`, `Next`, `Detail` | as host | | 5 |
| `UdpOff`, `Cloud` | `UdpDisabledByPolicy`, `Cloud` | int, string | 1 |
| `Ep`, `EpOk`, `EpBad`, `EpDns`, `EpMs` | `EndpointProbeCount`, `EndpointReachableCount`, `EndpointUnreachable`, `EndpointResolvable`, `ProbeMs` | int, int, string[], int, int | 3 |
| `WS`, `WSSrc` | `WorkspaceCount`, `WorkspaceSource` | int, string | 1 |
| `Att24`, `Ok24`, `Fail24`, `Udp24` | `ConnectAttempts24h`, `ConnectSuccess24h`, `ConnectFailures24h`, `UdpEvidence24h` | int | 2 |
| `LastAt`, `LastSrv`, `LastDR`, `LastDAt` | `LastConnectTime`, `LastServer`, `LastDisconnectReason`, `LastDisconnectTime` | string, string, int, string | 2 |
| `Log`, `LogRes`, `LogFail`, `TraceMb`, `Cred` | `LogFileUsed`, `LogParseResult`, `LogFailureCount24h`, `TraceFolderMb`, `TermsrvCredentialCount` | string, string, int, int, int | 1-2 |
| `Rel` | `Related`: `{ "VPN": [...], "Net": [...] }` | object | 4 |
| `Ded` | `Deductions` | array[] | 5 |

Trim ladder: `Log` to its file name; `Rel` to `{}`; `EpBad` to its first entry; `Ded`
to its first row; `LastSrv` to `''`; `Log` to `''`; `Detail` to `''`.

### 7.3 `NextStep` mapping (both sensors)

| Reason | NextStep | NextStepDetail |
|---|---|---|
| `BootLoaderStopped`, `AgentStopped`, `RdsServiceStopped` | `AUTO` | `Invoke-AutoRemediateAvdSessionHostPart1.ps1 step 1/2/3` |
| `TsConnectionsDenied` | `AUTO` | `Part1 step 4; ADMIN if set by policy` |
| `SxsListenerMissing` | `AUTO` | `Part1 step 5 (re-enables the WinStation); ADMIN stack reinstall if it persists` |
| `MonitoringAgentUnhealthy` | `AUTO` | `Part1 step 6 (enables and runs the Geneva task); ADMIN reinstall from C:\Program Files\Microsoft RDInfra if missing` |
| `NotRegistered`, `RegistrationFailing` | `ADMIN` | `new registration key from the host pool, then Invoke-AutoRemediateAvdAgentRestart.ps1; Runbook-AVD-SessionHost.md phase 2` |
| `DomainTrustBroken` | `ADMIN` | `reset the computer account secure channel; Runbook phase 2` |
| `BrokerUnreachable`, `RequiredUrlsUnreachable` | `AUTO` | `Part2 step 8 (DNS flush, then report); ADMIN firewall/proxy for the listed FQDNs` |
| `ImdsUnreachable` | `ADMIN` | `proxy bypass for 169.254.169.254 (winhttp); Part2 step 9 reports the current proxy` |
| `UnsupportedSku` | `ADMIN` | `host pool image must be Enterprise, multi-session or Server` |
| `HighInputDelay` | `ADMIN` | `host CPU/memory pressure; see Runbook phase 4` |
| `HighRdpRtt`, `HighPacketLoss`, `RdpTcpFallback` | `ADMIN` | `network path / Shortpath (UDP 3478 to 51.5.0.0/16, STUN); correlate with the endpoint via LastClientName` |
| `TransportForcedTcp`, `ShortpathRuleMissing` | `AUTO` | `Part2 step 10 (rule only when the listener policy is on); policy is ADMIN` |
| `TeamsRedirectorStopped` | `AUTO` | `Part2 step 11` |
| `StaleDisconnectedSessions` | `AUTO` | `Part2 step 12 (opt-in)` |
| `AgentErrorsElevated`, `BootLoaderStartTimeouts`, `LowDiskSpace`, `DotNetBelow472` | `ADMIN` | `Part2 step 13; Runbook phase 6` |
| `EndpointUnresolvable` | `AUTO` | `Invoke-AutoRemediateMicrosoftRdClient.ps1 step 1` |
| `EndpointUnreachable443` | `ADMIN` | `proxy / firewall for *.wvd.microsoft.com and windows.cloud.microsoft; run Invoke-AutoRemediateNetworkStack.ps1 first` |
| `RepeatedConnectFailures` | `USER` | `Runbook-AVD-Client.md phase 3` |
| `NoClientInstalled`, `LegacyClientOnly`, `LegacyClientPresent`, `ClientOutdated` | `ADMIN` | `deploy Windows App (Store 9N1F85V9T8BN or MSIX) via UEM; remove msrdc` |
| `UdpDisabledByPolicy` | `ADMIN` | `client policy "Turn Off UDP On Client"` |
| `TraceFolderBloated` | `AUTO` | `Invoke-AutoRemediateMicrosoftRdClient.ps1 step 10` |
| `VpnDegraded` | `AUTO` | `VPN/Invoke-AutoRemediateGenericVPN.ps1` |
| `Healthy`, `NotInstalled` | `NONE` | `''` |

---

## 8. Remediation contract

### 8.1 `Invoke-AutoRemediateAvdSessionHostPart1.ps1` (steps 1-7: the Unavailable class)

Guard: no agent key (KB-AVD-01) prints
`No Azure Virtual Desktop agent present on this device. Nothing to process.` and exits
`0` without writing the cache. Tunables: `ServicePollSeconds` 60, `NetTimeoutMs` 2000,
`EventLookbackHours` 24, `MaxEventsScanned` 2000.

| # | Name | Mode | Detection -> Status: message | Resolution |
|---|---|---|---|---|
| 1 | `Agent Boot Loader Service` | AUTO | absent -> Failed: `Boot loader service not found (tried <names>) -- the agent key exists but the service is missing; reinstall the Remote Desktop Agent Boot Loader` / not Running or Disabled -> Failed: `Boot loader service (<name>) is <State> (StartMode: <mode>) -- the session host cannot register or stay Available` / Passed: `Boot loader service (<name>) is Running (StartMode: <mode>)` | if Disabled: `sc.exe config <name> start= delayed-auto`; `sc.exe start <name>`; poll 10 s; if it stops again within 10 s append ` -- stopped again after start: registration failure likely (see step 7)` to the step result |
| 2 | `Agent Service` | AUTO | not Running -> Failed: `Agent service (<name>) is <State> -- the boot loader should start it; starting now` / Passed: `Agent service (<name>) is Running` | `sc.exe start <name>` |
| 3 | `Remote Desktop Services` | AUTO | `TermService` or `UmRdpService` not Running -> Failed: `Remote Desktop Services not running: <name (State)>, ...` / Passed: `Remote Desktop Services running (TermService, UmRdpService)` | `sc.exe start` each; never changes start type |
| 4 | `Remote Desktop Connections Allowed` | AUTO | policy key `fDenyTSConnections = 1` -> Warning: `Remote Desktop connections are denied by policy (HKLM\SOFTWARE\Policies\...\fDenyTSConnections = 1) -- set by Intune or Group Policy; not fixable from the device` / live key `= 1` -> Failed: `Remote Desktop connections are denied (fDenyTSConnections = 1) -- no session can connect` / Passed: `Remote Desktop connections allowed` | set the live `fDenyTSConnections` to `0`; the policy value is never touched |
| 5 | `SxS Stack Listener` | AUTO | no `rdp-sxs*` WinStation -> Warning: `No side-by-side stack listener registered -- stack not installed or not activated (Pro SKU?); reinstall the Remote Desktop Services SxS Network Stack` / WinStation present with `fEnableWinStation` or `fReverseConnectMode` not `1` -> Failed: `Stack listener <name> is registered but disabled (fEnableWinStation=<v>, fReverseConnectMode=<v>) -- the documented fix is to set both to 1 and restart` / Passed: `Stack listener <name> enabled (reverse connect mode on<, qwinsta Listen>)` | set both values to `1` on every `rdp-sxs*` WinStation; append ` -- restart required for the listener to come up` |
| 6 | `Monitoring Agent Task` | AUTO | no `GenevaTask_*` -> Warning: `Geneva monitoring task not found -- reinstall Microsoft.RDInfra.Geneva.Installer-x64-<ver>.msi from C:\Program Files\Microsoft RDInfra (host shows Needs Assistance)` / task Disabled -> Failed: `Geneva monitoring task <name> is disabled -- sessions connect but log nothing; enabling and running it` / more than one Geneva version installed -> Warning: `<n> Geneva agent versions installed (<versions>) -- uninstall the older ones` / Passed: `Geneva monitoring task <name> enabled (state <state>)` | COM: `Enabled = $true`, then `Run()` |
| 7 | `Registration` | report | `IsRegistered = 0` and token blank -> Warning: `Session host is not registered (IsRegistered = 0, no token) -- generate a registration key for the host pool and write it to RDInfraAgent\RegistrationToken, then restart RDAgentBootLoader` / `IsRegistered = 0` and token present -> Warning: `Registration pending (token present, IsRegistered = 0) -- restart RDAgentBootLoader to apply it (Tier 2 restart)` / 3277 token in 24 h -> Warning: `Agent reports <token> (event 3277, <n> in 24 h) -- <meaning>` / Passed: `Registered (IsRegistered = 1, token cleared)` | none |

### 8.2 `Invoke-AutoRemediateAvdSessionHostPart2.ps1` (steps 8-14: connectivity, quality, sessions, readiness)

Same guard and header. Tunables: `NetTimeoutMs` 2000, `MaxProbeHosts` 5,
`DisconnectedStaleMinutes` 480, `RdpRttWarnMs` 250, `RdpLossWarnPpm` 20000,
`InputDelayWarnMs` 500, `AgentErrorWarnCount` 10, `DiskFreeWarnGb` 2,
`EventLookbackHours` 24, `MaxEventsScanned` 2000.

| # | Name | Mode | Detection -> Status: message | Resolution |
|---|---|---|---|---|
| 8 | `Broker and Required URLs` | AUTO (flush) then report | broker health GET fails on both URIs -> Failed: `Broker not healthy: <host> (<result>), <host> (<result>) -- the agent cannot reach the service; flushing DNS, then firewall or proxy path is ADMIN` / other required FQDNs fail -> Warning: `Required FQDN(s) unreachable on 443: <list> (source <UrlSource>) -- host will show Needs Assistance; allow them outbound` / Passed: `Broker healthy (<host> in <ms> ms); <n>/<m> required FQDNs reachable` | `ipconfig /flushdns`; re-run the broker GET once; the message is re-evaluated by the summary only |
| 9 | `Instance Metadata Service` | report | GET fails -> Warning: `IMDS (169.254.169.254) unreachable: <result> -- winhttp proxy is <proxy or direct>; add a bypass for 169.254.169.254 (host shows Needs Assistance)` / Passed: `IMDS reachable (<vmSize>, <location>, <environment>)` | none |
| 10 | `RDP Transport and Shortpath` | AUTO (rule only) | `SelectTransport = 1` -> Warning: `RDP transport policy forces TCP (SelectTransport = 1) -- Shortpath cannot be used; policy is ADMIN` / listener policy on and no enabled inbound UDP rule for `<port>` -> Failed: `Shortpath listener enabled on UDP <port> but no enabled inbound firewall rule allows it -- creating rule DEX-AVD-Shortpath-UDP-<port>` / TCP sessions while UDP allowed -> Warning: `<n> of <m> session(s) on TCP (UDP expected): <user (reason)>, ... -- STUN/TURN egress (UDP 3478 to 51.5.0.0/16) or client-side UDP; correlate with the endpoint` / Passed: `Transport policy default; <n> session(s) on UDP, <m> on TCP` | `New-NetFirewallRule -DisplayName DEX-AVD-Shortpath-UDP-<port> -Direction Inbound -Protocol UDP -LocalPort <port> -Action Allow`; only when the listener policy is on |
| 11 | `Teams Media Redirector` | AUTO | `IsWVDEnvironment` absent -> Passed: `Teams media optimisation not configured on this host -- not applicable` / configured, service missing -> Warning: `IsWVDEnvironment = 1 but the WebRTC Redirector Service is not installed -- new Teams may use SlimCore; otherwise install the redirector MSI` / stopped -> Failed: `WebRTC Redirector Service (<name>) is <State> -- Teams calls fall back to unoptimised media` / Passed: `WebRTC Redirector Service running; IsWVDEnvironment = 1` | `sc.exe start <name>` |
| 12 | `Disconnected Sessions` | opt-in (`ResolveOnWarning = $false`) | stale -> Warning: `<n> disconnected session(s) older than <threshold> min: <user> (id <id>, <min> min), ...` / Passed: `No disconnected sessions older than <threshold> min` | `logoff <id>` each |
| 13 | `Agent Update Readiness` | report | errors over threshold -> Warning: `<n> agent error events in the last <h> h; top IDs: <id:count, ...>` / free space under threshold -> Warning: `System drive has <gb> GB free (threshold <t> GB) -- agent updates fail with DownloadMsiException` / .NET release < 461808 -> Warning: `.NET Framework release <release> is below 4.7.2 -- agent updates revert (event 3389)` / boot-loader start timeouts -> Warning: `<n> service start timeout(s) for RDAgentBootLoader in <h> h (System 7000/7011) -- set Automatic (Delayed Start) and raise ServicesPipeTimeout` / more than one condition -> Warning with the messages joined by ` | ` / Passed: `<n> agent errors in <h> h; <gb> GB free; .NET release <release>` | none |
| 14 | `Persistence and Image Fault` | report | Horizon step 10 rules verbatim, with `Cloud PC` substituted for `non-persistent clone` wording when `CloudPc = 1`: `Leading fault (<reason>) was present at first boot -- likely image or provisioning, not session drift` | none |

Step 14 reads the collector cache only; every other detection measures live. Summary,
registry persist (4.2) and exit code per 8.5. After the summary, when `ReliefOnly = 1`,
print `Persistence is <value>: remediations above are relief for this host and revert at the next refresh.`

### 8.3 `Invoke-AutoRemediateMicrosoftRdClient.ps1`

Guard: neither Windows App nor `msrdc` present prints
`No Windows App or Remote Desktop client present on this device. Nothing to process.`
and exits `0`. Tunables: `ConnectFailureWarnCount` 5, `NetTimeoutMs` 2000,
`MaxProbeHosts` 5, `ClientVersionFloor` `''`, `LogTailBytes` 524288,
`TraceFolderWarnMb` 2048, `TraceFileAgeDays` 7.

| # | Name | Mode | Detection -> Status: message | Resolution |
|---|---|---|---|---|
| 1 | `Service Endpoint DNS` | AUTO | none resolve -> Failed: `Service endpoint(s) do not resolve: <list> -- DNS client or suffix problem` / Passed: `Service endpoints resolve: <list>` | flush and register DNS |
| 2 | `Service Endpoint Connectivity (443)` | report | not testable -> Passed: `Not testable (see step 1)` / Warning: `No service endpoint answers on TCP 443: <list> -- VPN, proxy or firewall; run Invoke-AutoRemediateNetworkStack.ps1 and the VPN remediation first` / partial -> Warning: `<n>/<m> endpoints unreachable: <list>` / Passed: `Service endpoints reachable (<host>:443 in <ms> ms)` | none |
| 3 | `Client UDP Policy` | report | `fClientDisableUDP = 1` -> Warning: `UDP is disabled on this client by policy (fClientDisableUDP = 1) -- Shortpath cannot be used; every session falls back to TCP` / Passed: `Client UDP enabled (policy default)` | none |
| 4 | `Connection Failures (24h)` | report | over threshold -> Warning: `<n> failed connection(s) in the last 24 h for <user>; last server <server>, last disconnect reason <code>` / log unreadable -> Passed: `RDPClient log not readable (<result>)` / Passed: `<n> failed connection(s) in the last 24 h (<m> attempts)` | none |
| 5 | `Legacy Remote Desktop Client` | report | `msrdc` present, no Windows App -> Warning: `Remote Desktop client <version> is the only client and has been out of support since 2026-03-27 -- deploy Windows App via UEM` / both -> Warning: `Legacy Remote Desktop client <version> still installed alongside Windows App -- remove it` / Passed: `No legacy Remote Desktop client` | none |
| 6 | `Windows App Version` | report | floor unset -> Passed: `Windows App <version>; no version floor configured` / below -> Warning: `Windows App <version> is below the floor <floor> -- Store or MSIX update via UEM` / not installed -> Warning: `Windows App not installed for <user> -- deploy Store 9N1F85V9T8BN or the MSIX` / Passed: `Windows App <version> meets the floor <floor>` | none |
| 7 | `Endpoint Network Context` | report | VPN degraded -> Warning: `VPN health score <score> (<reason>) on this endpoint -- run VPN/Invoke-AutoRemediateGenericVPN.ps1 before troubleshooting the client` / Passed: `VPN health score <score or n/a>; network stack <status or n/a>` | none |
| 8 | `Stale TERMSRV Credentials` | opt-in, `Enabled = $false` | entries present and failures >= threshold -> Failed: `<n> TERMSRV/* credential entries cached for <user> with repeated failures -- removing them` / Passed: `<n> TERMSRV/* credential entries; left in place` | `cmdkey /delete:<target>` each (user context via scheduled task; see README) |
| 9 | `Windows App Cache Reset` | opt-in, `Enabled = $false`, `ConfirmHighImpact` | failures >= threshold and package LocalCache present -> Failed: `Windows App cache reset is enabled and <n> failures were seen -- renaming <path>` / Passed: `Windows App cache left in place` | rename `%LOCALAPPDATA%\Packages\<family>\LocalCache` to `LocalCache.bak-<yyyyMMddHHmm>` while Windows App is not running |
| 10 | `Client Trace Folder` | AUTO | `RdClientAutoTrace` over threshold -> Failed: `Client trace folder is <mb> MB (threshold <t> MB) -- deleting trace files older than <d> days` / Passed: `Client trace folder <mb> MB` / absent -> Passed: `No client trace folder` | delete `*.etl` older than `TraceFileAgeDays` in the folder; never the folder itself |

### 8.4 `Invoke-AutoRemediateAvdAgentRestart.ps1` (Tier 2)

Launcher/payload via one-shot SYSTEM scheduled task `WS1_AvdAgentRestart`, payload at
`C:\ProgramData\AirWatch\Extensions\VDI\Microsoft\Invoke-AutoRemediateAvdAgentRestart.ps1`
(AV exclusion documented in README). This is Microsoft's own documented remedy
(restart `RDAgentBootLoader`, which re-launches the agent, re-runs the health checks and
applies a pending registration token); sessions survive it. Gates, each exiting `0`
with a `Status` from 4.3:

1. Not installed -> `SkippedNotInstalled`.
2. `LastRestartTime` younger than `CooldownHours` (1) -> `SkippedCooldown`.
3. Any session in the connecting state (LSM event 21 within the last 60 s with no
   matching 22/25) and `ConfirmHighImpact` not true -> `SkippedActiveSessions`. Active
   established sessions do **not** block it (the restart does not drop them).

Payload: `sc.exe stop RDAgent` (poll 60 s), `Restart-Service RDAgentBootLoader`
(`sc.exe stop` then `start`, poll 60 s each), wait 30 s, read `IsRegistered` and both
service states, write 4.3, unregister its task, exit `0` when the boot loader and agent
are Running else `1`. `WhatIf` honoured as Horizon.

### 8.5 Exit codes (all Tier 1 scripts)

`0` when no step is `Failed`, or every `Failed` step's resolution ran without throwing.
`1` when any `Failed` step had no resolution, or its resolution threw. Report-only steps
return `Warning` and never affect the exit code. Guard paths exit `0`. Part1 and Part2
exit independently; a Quickflow runs Part1 then Part2.

---

## 9. Collector contract (what is measured and how)

### 9.1 Session host collector phases and sources

| Phase | Measures | Source | Bound |
|---|---|---|---|
| 1 | agent key values, uninstall versions and counts, services and start modes, `fDenyTSConnections` (live and policy), WinStations (`rdp-sxs*` values, `ReverseConnectionListener`, `SessionDirectoryListener`), `qwinsta` listener state, Geneva task via COM, transport policy values, Shortpath listener values and matching inbound UDP rule, Teams key and WebRTC service, OS SKU, .NET release, free space, boot time | registry, `Win32_Service`, `qwinsta.exe` (one call, 5 s cap), `Schedule.Service`, `Get-NetFirewallRule` (one filtered call) | ms |
| 2 | session inventory (TS-LSM 21/23/24/25, newest first decides state), `CLIENTNAME` and `SESSIONNAME` from the volatile environment, per-session transport from RdpCoreCDV 135 (newest per session id in `EventLookbackHours`) | `Get-DexEvent` on both logs, `MaxEventsScanned` | < 2 s |
| 3 | `RemoteFX Network` and `User Input Delay per Session` counters, one sample; instance-to-session mapping by the numeric suffix | `Get-Counter` with both paths in one call, `-ErrorAction SilentlyContinue` | 1-2 s |
| 4 | domain / Entra join, secure channel (`Test-ComputerSecureChannel`, only when AD-joined; wrapped in a 5 s runspace-free timeout by skipping it when under 8 s remain), broker health GETs, IMDS GET, required FQDN TCP 443 probes (`UrlSource` records whether event 3701 contributed) | `HttpWebRequest`, `TcpClient` pattern | <= 5 hosts x 2 s + 3 GETs x 2 s |
| 5 | agent error events, 3277 token, boot-loader start timeouts | `Get-DexEvent` Application (providers KB-AVD-09, Level <= 2) and System (7000/7011 with `RDAgentBootLoader` in the message) | `MaxEventsScanned` |
| 6 | derived status and health-check names (5.3), Cloud PC and persistence (KB-AVD-14), `FaultPresentAtBoot` | | ms |
| 7 | score, cache write, `LastRun` | | |

Worst case 30 s: the secure-channel test and phase 4 probes are the risk; the collector
checks the stopwatch before each probe and records `-4` for anything it skips.

### 9.2 Client collector phases and sources

| Phase | Measures | Source |
|---|---|---|
| 1 | console user (`Win32_ComputerSystem.UserName` -> SID -> profile), Windows App per-user and all-users registration and version, `msrdc` key and version, `mstsc.exe` version, client UDP policy, `RdClientRadc` feeds, `TERMSRV` credential count (`cmdkey /list` under the user's token via the existing `Start-AsUser` pattern, else `-1`) | registry, file version, `cmdkey.exe` |
| 2 | RDPClient events 1024/1026/1027/1105 in 24 h, last server and disconnect reason, Windows App log tail (`LogTailBytes`) with the failure regex, `RdClientAutoTrace` size | `Get-DexEvent`, `System.IO` |
| 3 | endpoint DNS and 443 probes (max 5) | `Dns.GetHostAddresses` with the same timeout, `TcpClient` pattern |
| 4 | VPN and NetworkStack caches | registry |
| 5 | score, cache, `LastRun` | |

---

## 10. Runbook contract

Both runbooks follow `VPN/Runbook-VPN-Agent.md` as the Horizon ones do. The session-host
runbook's phase 2 ("Unavailable or NotRegistered") MUST instruct the agent to read
`avd_host_status` and `HealthCheckFailures` first, map them to the portal's status
vocabulary, and run `Invoke-AutoRemediateAvdAgentRestart.ps1` before escalating a
registration problem. Phase 4 ("quality") MUST instruct the agent to pull
`avd_client_health` on the device named by the cached `LastClientName` before blaming
the host. The client runbook's phase 3 MUST cover the Windows App sign-in and workspace
refresh steps and the end-user device FQDN list.

---

## 11. Test contract

### 11.1 `Test-AvdNoAgentPath.ps1` (runs on any device, elevated)

Mirrors `Test-HorizonNoAgentPath.ps1`: both collectors on the not-installed path
(`HealthScore -1`, `HealthReason NotInstalled`, `LastRun` written), all three Tier 1
remediations print their guard line and exit `0`, the Tier 2 launcher writes
`SkippedNotInstalled`, the seven scalar sensors return type-valid fallbacks, both
one-time sensors return a single JSON line under 1,000 bytes with every Schema 2 key
present and no nulls, then a seeded cache (including `FaultPresentAtBoot = 1`) is read
back by every sensor including the `;ImageFault` suffix, then cleanup.

### 11.2 `Test-AvdScoreParity.ps1` (needs an AVD host)

Collector then one-time sensor within the same minute; `Score` and `Reason` must match.
Tolerated divergence: `DomainTrustBroken:30` when the sensor skipped the secure-channel
test for budget (`Trust = -4`), reported as `TOLERATED`.

### 11.3 `Invoke-AutoRemediateAvdSessionHost_BreakTest.ps1` (needs an AVD host)

| Break | Lever | Verify | Expect | Validate | Restore |
|---|---|---|---|---|---|
| `BootLoaderDisabled` | stop `RDAgentBootLoader`, set Disabled | Stopped, Disabled | Fixed (Part1 step 1) | Running within 60 s, start mode not Disabled, line `[Failed ] Agent Boot Loader Service: ... -> Remediation ran`, exit 0 | captured mode and state |
| `AgentStopped` | stop `RDAgent` | Stopped | Fixed (step 2) | Running, line `[Failed ] Agent Service: ...` | start |
| `TsConnectionsDenied` | set live `fDenyTSConnections = 1` | value 1 | Fixed (step 4) | value 0, line `[Failed ] Remote Desktop Connections Allowed: ...` | captured value |
| `GenevaTaskDisabled` | disable the `GenevaTask_*` task via COM | `Enabled False` | Fixed (step 6) | `Enabled True`, line `[Failed ] Monitoring Agent Task: ...` | captured state |
| `BrokerBlocked` | outbound firewall block rule `DEXTest-AvdBrokerBlock` for TCP 443 to the resolved addresses of both broker hosts | the broker health GET fails while DNS resolves | Fixed-then-ReportedOnly (step 8: flush runs, broker still failing is recorded as Failed with the resolution having run; exit 0) | line `[Failed ] Broker and Required URLs: Broker not healthy ...`, block rule still present | remove the rule |
| `ImdsBlocked` | outbound block rule `DEXTest-AvdImdsBlock` for TCP 80 to 169.254.169.254 | IMDS GET fails | ReportedOnly (step 9) | line `[Warning] Instance Metadata Service: IMDS (169.254.169.254) unreachable ...` | remove the rule |
| `TransportForcedTcp` | policy copy: `SelectTransport = 1` | value 1 | ReportedOnly (step 10) | line `[Warning] RDP Transport and Shortpath: RDP transport policy forces TCP ...` | captured value or delete |
| `StaleDisconnectedSession` | `tsdiscon` on the harness's own session, threshold override `AVD_TEST_DisconnectedStaleMinutes` honoured only when `C:\Temp\FixReport\.dex-test-machine` exists; gated behind `-IncludeSessionBreaks` | Disconnected | ReportedOnly; Fixed with `-EnableSessionLogoff` | line `[Warning] Disconnected Sessions: 1 disconnected session(s) ...` | reconnect |

Not covered: registration (clearing `IsRegistered` needs a new token to recover, and
`NAME_ALREADY_REGISTERED` is a real risk), stack reinstall, domain trust, Cloud PC
persistence (needs a Cloud PC). The `BrokerBlocked` break takes the host to
`Unavailable` in the portal for the duration (about 90 s); established sessions survive
because they ride the gateway, but the harness MUST print that warning and require
`-Confirm` on a host that is not the lab host. Block-rule names MUST NOT match any
pattern the scripts count.

### 11.4 `Invoke-AutoRemediateMicrosoftRdClient_BreakTest.ps1` (needs Windows App; installable on this VM from the Store)

| Break | Lever | Expect | Validate | Restore |
|---|---|---|---|---|
| `EndpointBlocked` | outbound block rule `DEXTest-AvdClientBlock` for TCP 443 to the resolved addresses of `rdweb.wvd.microsoft.com` | ReportedOnly (step 2) | `[Warning] Service Endpoint Connectivity (443): ...` | remove the rule |
| `ClientUdpDisabled` | policy copy `fClientDisableUDP = 1` | ReportedOnly (step 3) | `[Warning] Client UDP Policy: UDP is disabled on this client by policy ...` | captured value or delete |
| `TraceFolderBloated` | seed `RdClientAutoTrace` with 2.1 GB of `*.etl` files dated 10 days old (sparse files) | Fixed (step 10) | folder under threshold, line `[Failed ] Client Trace Folder: ... -> Remediation ran` | remove any seeded files that remain |
| `LegacyClientPresent` | create the `HKLM:\SOFTWARE\Microsoft\MSRDC` key copy with a `Version` marker | ReportedOnly (step 5) | `[Warning] Legacy Remote Desktop Client: ...` | delete the key only if the harness created it |

### 11.5 Lab hosts needed

| Host | For | Notes |
|---|---|---|
| AVD pooled session host (multi-session), registered, enrolled in UEM | host collector, sensors, both remediation parts, parity, Tier 2, break tests | the primary target; confirms KB-AVD-01/03/04/05/09/11/13/16/17; also answers KB-AVD-26 |
| Windows 365 Cloud PC enrolled in UEM | KB-AVD-14, `Persistence`, `ReliefOnly = 0` path | optional for phase 5; needed before the Cloud PC wording ships |
| This VM with Windows App from the Store | client collector, sensors, client breaks, parity | no host pool needed for most breaks; a workspace with at least one assigned resource for the event breaks |
| Azure Government host | KB-AVD-06 | only if a customer needs it |

---

## 12. What the internal build may change

| May | Must not |
|---|---|
| Replace candidate lists in KB-point variables with the settled answer, keeping the fallback | Rename any variable, file, sensor, registry value, JSON key, reason, step or tunable |
| Emit health-check names from the agent's own results once KB-AVD-10 settles (`HealthCheckSource = Agent`) and add reasons numbered 26+ | Change any point value or threshold default without recording it in the header and README |
| Append steps after step 14 (host) / step 10 (client) | Reorder, renumber or re-split the existing steps, or change their message templates |
| Add JSON keys (bump `Schema`) | Remove or retype existing keys |
| Add scalar sensors from the not-shipped list | Change the ship set's names or types |
| Set `$SCRIPT_VARIANT = 'internal'`; `ScriptVersion` is written as `<version>+internal` | Commit anything to this repository |
| Add organisation-specific runbook phases | Remove the public phases |

The internal build MUST pass `Test-AvdNoAgentPath.ps1`, `Test-AvdScoreParity.ps1` and
both break tests from this repository unchanged, and MUST record
`Built from VDI/Microsoft/SPEC.md rev 1` in every script header.

---

## 13. Change control

As `VDI/Horizon/SPEC.md` section 13: interface changes bump the revision and are logged
below; public answers go back into the candidate lists; organisation-specific answers are
marked `Internal` with no answer recorded; inventory and `TEST-VALIDATION.md` rows move
in the same change.

## Revision history

- **Rev 1, 2026-11-10.** Initial contract from the 2026-11-10 research pass against the
  current Microsoft Learn pages (session host statuses and health checks, troubleshoot
  agent, required FQDNs, RDP Shortpath and its configuration page, agent overview, URL
  tool, Teams on AVD, Windows App log collection, Insights glossary). Design corrections
  carried into `VDI/DESIGN.md` section 5 the same day: the Geneva monitoring agent is a
  scheduled task, not a service; AVD needs no inbound firewall rules (reverse connect),
  so only the Shortpath managed-network listener rule is ever created; the Remote
  Desktop client `msrdc` left support on 2026-03-27, so Windows App is the client and
  `msrdc` is a legacy finding; the session-host remediation is two parts from the
  start; the scalar ship set is seven sensors under the no-DEX-duplication rule; break
  levers are named outbound block rules, never hosts-file edits. Conventions inherited
  from the 2026-11-05 learnings: no `Get-WinEvent`, 5.1 floor, Schema 2 compact JSON
  under 1,000 bytes, size limit binding.
