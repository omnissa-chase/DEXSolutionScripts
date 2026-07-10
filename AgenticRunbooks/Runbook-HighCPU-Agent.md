# Agent Runbook -- High CPU Utilization (Omnissa Intelligent Hub)

**Trigger:** DEX experience score decline driven by CPU experience, a CPU utilization sensor
exceeding threshold, or a user-initiated "My device is slow" Hub interaction.

**Agent context:** The agent runs inside the Omnissa Intelligent Hub on the end user's
device. It has read access to DEX telemetry (CPU, memory, disk, network, process data,
experience scores, sensor history) and can build and execute Quickflows to run scripts,
MDM commands, install/remove apps, and push profiles.

**Goal:** Autonomously identify the root cause of elevated CPU, remediate where possible
without disruption to the user, clearly communicate what was done, and escalate to an
administrator when the root cause cannot be safely resolved automatically.

---

## Intervention Key

| Symbol | Meaning |
|--------|---------|
| AUTO   | Agent can resolve autonomously via Quickflow |
| USER   | Requires the end user to take action |
| ADMIN  | Requires an IT administrator to intervene |
| INFORM | Informational step only -- no remediation needed |

---

## Phase 1 -- Triage: Confirm and Characterize the Problem

Before taking any action, the agent establishes a baseline to scope the investigation.

### 1.1 Confirm CPU is Actually Elevated

Pull from DEX telemetry:

- Current CPU utilization (%) -- 1 min, 5 min, 15 min averages
- CPU experience score and trend (improving / stable / declining)
- Historical CPU percentile for this device vs. peer group (same model, same OS build)

**Decision:**

| Condition | Action |
|-----------|--------|
| CPU < 70% sustained and experience score is not declining | Notify user -- no issue detected at this time. Close runbook. |
| CPU 70-85% sustained | Proceed -- moderate concern |
| CPU > 85% sustained OR experience score significantly below peer group | Proceed -- high concern |

> Agent message to user: "I'm looking into your device's performance now. I'll update you
> when I find the cause."

---

### 1.2 Identify Top CPU-Consuming Processes

Pull from DEX process telemetry or run a Quickflow sensor to collect:

- Top 10 processes by CPU % (name, PID, CPU %, memory %, disk I/O)
- Process age (how long running)
- Whether each process is a known system process, security tool, or user application

**Classify each top process into a category:**

| Category | Examples | Next Phase |
|----------|---------|------------|
| Security / AV | MsMpEng.exe, SentinelAgent.exe, CylanceSvc.exe | Phase 2 |
| Windows Update / Servicing | TiWorker.exe, WUDFHost.exe, TrustedInstaller.exe | Phase 3 |
| Startup / background app | OneDrive.exe, Teams.exe, Discord.exe, Spotify.exe | Phase 4 |
| User application (foreground) | Photoshop.exe, Chrome.exe, devenv.exe | Phase 5 |
| Memory pressure spillover | System, Registry, svchost.exe (high RAM device) | Phase 6 |
| Unknown / unnamed process | Random character names, no publisher | Phase 7 |

---

## Phase 2 -- Antivirus / Security Tool Activity

**Indicator:** MsMpEng.exe, SentinelAgent, CrowdStrike, Carbon Black, or similar
AV/EDR process is in the top CPU consumers.

### 2.1 Determine if a Scan is Actively Running

Check DEX for:
- Disk I/O simultaneously elevated (classic AV scan signature: high disk read + high CPU)
- Network I/O normal or low (rules out update pull)
- Duration: has this process been elevated > 15 minutes?

**AUTO** -- If Microsoft Defender is the culprit and the org has the Defender
Performance Tuning CSP available:

- Build Quickflow: push a Defender performance profile via MDM (CSP:
  `./Device/Vendor/MSFT/Policy/Config/Defender/`) to reduce scan thread priority
- Or deploy the Windows Defender Exclusions profile if specific high-I/O paths
  are known (e.g. developer repo folders, OneDrive cache)

**INFORM** -- If a third-party AV is active: agent notifies the user that a scheduled
scan is in progress and expected to complete within 30-60 minutes. Log the event in DEX.

**ADMIN** -- If scans are occurring outside of the configured maintenance window or
more frequently than expected: raise a ticket to the AV team to review scan schedule
policy. The agent should file a support ticket on the user's behalf.

> Agent message to user: "Your security software is running a scheduled scan which is
> temporarily using extra CPU. This is normal and should complete within 30-60 minutes.
> I've logged this so IT can review whether scans can be scheduled for off-hours."

---

## Phase 3 -- Windows Update / Servicing Activity

**Indicator:** TiWorker.exe, WUDFHost.exe, TrustedInstaller.exe, or wuauclt.exe
elevated; disk I/O high simultaneously.

### 3.1 Check Update State

Pull from DEX / run Quickflow sensor:

- Pending update count and cumulative size
- Last successful update install date
- Disk space available on C: (updates need > 5 GB staging space)
- Pending reboot flag in registry

### 3.2 Validate Prerequisites

**AUTO** -- Check disk space:
- If C: < 5 GB free: trigger Disk Cleanup Quickflow (see Runbook-DiskCleanup-Agent)
- If C: < 5 GB after cleanup: escalate to ADMIN

**AUTO** -- Check Windows Update service health:
- Quickflow: run `Invoke-AutoRemediateWindowsUpdates.ps1` to validate wuauserv,
  BITS, CryptSvc, and DataStore integrity

**AUTO** -- Check for Event Log errors related to update failures:
- Quickflow sensor: query Windows Update event log for error codes 0x80070005,
  0x800706BE, 0x8007000E (common cryptography / access errors)
- If found: run winsock/IP stack remediation (see NetworkResolutionWizard)

**INFORM** -- If updates are actively downloading/installing and prerequisites are healthy:
notify user that updates are in progress and CPU impact is temporary.

**ADMIN** -- If updates have been failing for > 14 days, or if the WSUS/SCCM server
is unreachable: raise a ticket. The agent should note the error codes found.

> Agent message to user: "Windows is currently downloading or installing updates, which
> is temporarily increasing CPU usage. I've verified your device has enough disk space
> and the update services are healthy. This should finish soon."

---

## Phase 4 -- Excessive Startup Applications

**Indicator:** Multiple non-essential applications running in background with no active
user window; device has been running > 30 minutes since boot (not just startup burst).

### 4.1 Identify Startup Application Load

Pull from DEX or run Quickflow sensor:

- List of enabled startup entries (HKCU/HKLM Run keys + Task Manager startup list)
- Startup impact rating (High / Medium / Low) per application if available
- Compare count vs. peer group baseline

### 4.2 Classify Startup Entries

| Application Type | Safe to Auto-Disable? | Action |
|-----------------|----------------------|--------|
| Productivity tools (Spotify, Discord, gaming launchers) | Yes | AUTO |
| Cloud storage sync clients (OneDrive, Dropbox, Box) | Conditional -- check org policy | ADMIN if managed |
| Collaboration tools (Teams, Zoom, Slack) | No -- often required | INFORM |
| Security / management agents (AV, UEM Hub, VPN) | Never | INFORM |
| Unknown / unsigned publisher | No | ADMIN |

**AUTO** -- For clearly non-essential apps (gaming clients, media players, personal
productivity): build Quickflow script to disable startup entry via registry
(`HKCU:\Software\Microsoft\Windows\CurrentVersion\Run`).

> Agent message to user: "I found several apps that start automatically when you log in
> but don't need to. I've disabled [app names] from starting up automatically. This
> should reduce CPU usage on your next login. These apps are still installed -- they
> just won't start until you open them."

**ADMIN** -- If unknown or unsigned startup entries are found: flag for security team
review before any action is taken.

---

## Phase 5 -- Single Application Causing High CPU

**Indicator:** One specific process accounts for > 40% CPU sustained.

### 5.1 Identify Application Profile

Pull from DEX / Quickflow sensor:

- Application name, version, publisher
- Is this app managed/deployed by IT (check UEM app catalog)?
- Is an update available in UEM for this application?
- CPU usage trend: gradual increase (memory leak pattern) or sustained flat high?
- Memory usage: is it also elevated? Is it growing over time?
- Has this application crashed recently on this device?
- Disk I/O: is the app also showing high disk reads? (bottleneck indicator)
- Network I/O: is the app making frequent or high-latency network calls?

### 5.2 High CPU by Application Type

#### 5.2a -- Creative / Developer / High-Compute Applications
*Photoshop, video encoders, IDEs, databases, game dev tools*

**INFORM** -- This is expected behavior for this class of application. Verify with user
that the usage is intentional.

**AUTO** -- Check if GPU offloading is available and not configured:
- Quickflow sensor: check `HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers`
  for GPU scheduling state
- If Hardware-Accelerated GPU Scheduling (HAGS) is not enabled (Windows 11):
  Quickflow script to enable via registry (requires reboot -- prompt user)

**AUTO** -- Check if GPU driver is current:
- Compare installed GPU driver version against known latest via WMI
- If outdated: flag for ADMIN to push driver update via UEM

**USER** -- If app has in-app performance settings (render quality, threading):
guide the user to adjust these within the application.

#### 5.2b -- Memory Leak Pattern
*Gradual CPU + memory increase over session lifetime; app has crash history*

**AUTO** -- Check for available application update in UEM catalog:
- If update exists: offer to install via Quickflow
- Notify user that a newer version may resolve the issue

**USER** -- Ask user to save current work and restart the application.

**ADMIN** -- If no update is available and crashes are recurring: raise a ticket
to the application owner. Include crash dump paths from
`%LocalAppData%\CrashDumps` and `%AppData%\Microsoft\Windows\WER\ReportQueue`.

> Agent message to user: "The application [name] appears to be using more memory than
> expected, which is causing CPU impact. I've checked for updates -- [update available /
> no update available]. I recommend saving your work and restarting the app. I've also
> notified IT so they can investigate further."

#### 5.2c -- Disk I/O Bottleneck
*App CPU high; disk utilization simultaneously > 80%; other processes reading disk*

**INFORM** -- Another process (AV, Windows Update) is saturating the disk, causing
the user's application to queue. The CPU spike is a symptom, not the cause.
Follow Phase 2 or Phase 3 resolution first.

**USER** -- If disk I/O is isolated to the user's app: recommend saving work and
restarting the application to clear any hung I/O operations.

#### 5.2d -- Network-Related CPU Queuing
*App CPU high; network latency elevated; app is cloud-dependent (Teams, browser, ERP)*

Pull from DEX network telemetry:
- Latency to corporate endpoints / internet
- DNS resolution time
- VPN connected / disconnected state
- CRL/OCSP reachability (certificate validation failures cause retry loops)

**AUTO** -- If DNS or general connectivity is degraded: trigger
`Invoke-AutoRemediateNetworkStack.ps1` via Quickflow.

**AUTO** -- If network is healthy but app latency is high: check if app is on a
known slow endpoint. Collect response time data and attach to ticket.

**ADMIN** -- If CRL/OCSP endpoints are unreachable (common in strict corporate
firewall environments): raise a ticket to the network team with the blocked URL.
This is a known cause of crypto API CPU loops in .NET applications.

---

## Phase 6 -- Memory Pressure / Disk Paging

**Indicator:** High RAM utilization alongside CPU elevation; `System` or `svchost.exe`
high CPU; high disk I/O on pagefile.

### 6.1 Assess RAM Pressure

Pull from DEX:
- Total RAM vs. used RAM
- Page faults/sec (if sensor available)
- Committed memory vs. physical RAM
- Applications with top memory consumption

**INFORM** -- If the device is at design capacity (e.g. 8 GB RAM device with
modern workload): document for hardware refresh consideration. Raise to ADMIN.

**AUTO** -- If a specific application is consuming anomalous RAM (> 2x peer average):
follow Phase 5.2b (memory leak).

**AUTO** -- Run memory pressure quick check via Quickflow sensor, then cross-reference
with high memory runbook.

**ADMIN** -- If committed memory consistently exceeds physical RAM across multiple
days in DEX history: flag device for RAM upgrade or replacement via hardware
refresh workflow.

> Agent message to user: "Your device is running low on memory, which is causing
> performance slowdowns. I've identified which applications are using the most memory.
> I recommend closing applications you are not actively using. I've also flagged this
> with IT as your device may benefit from a hardware review."

---

## Phase 7 -- Unknown or Suspicious Process

**Indicator:** Unknown process name with no publisher, random character string as name,
or process running from a temp/user-writable path.

> **STOP -- Do not attempt auto-remediation.**

**ADMIN -- Security escalation required.**

1. Agent collects:
   - Full process path
   - Process hash (MD5/SHA256 via Quickflow sensor)
   - Parent process name and PID
   - Network connections from this process (if sensor available)
   - Persistence mechanism (startup key, scheduled task, service)

2. Agent immediately raises a P1/security ticket with all collected data.

3. Agent notifies user: "I've detected an unusual process on your device that I'm
   unable to identify. I've notified your IT security team and they will be in
   touch shortly. Please avoid opening any new applications or files until this
   is resolved."

4. If org policy allows: agent can trigger device isolation via MDM command
   (requires explicit admin approval workflow in Quickflow -- not autonomous).

---

## Phase 8 -- BIOS / Firmware Out of Date

**Indicator:** Device model has a known BIOS update that addresses CPU power management,
thermal throttling, or microcode errata (e.g. Spectre/Meltdown mitigations causing
known performance regression on older microcode).

Pull from DEX / Quickflow sensor:
- Current BIOS version and release date
- Device model and manufacturer

**ADMIN** -- BIOS updates cannot be automated safely via script in most enterprise
environments. Flag for the endpoint team to review:

- Check manufacturer advisory for whether the current BIOS version has known
  CPU performance issues
- Schedule BIOS update via SCCM/Intune BIOS management or manufacturer tooling
  (Dell Command Update, HP BIOS Config Utility, Lenovo System Update)

> Agent message to user: "I've noticed your device's firmware may be outdated. I've
> flagged this with IT who will schedule a firmware update for your device. No action
> is needed from you."

---

## Phase 9 -- No Root Cause Identified / Transient Spike

**Indicator:** CPU has returned to baseline by the time investigation completes, or
no single dominant cause was identified across all phases.

### 9.1 Check if Issue is Transient

- Review DEX CPU history: was this a one-time spike or recurring pattern?
- Review experience score trend: is this the first occurrence or part of a pattern?

**INFORM** -- If first occurrence and CPU now normal:
> "Your device's CPU usage has returned to normal. I didn't find a persistent cause.
> I've logged this event so if it recurs, IT will have a history to investigate."

**ADMIN** -- If recurring pattern with no clear cause:
- Collect a 5-minute ETW/WPR trace via Quickflow (requires pre-staged WPR tooling)
- Attach trace to escalation ticket for deeper analysis
- Raise ticket with all DEX telemetry collected across phases

---

## Quickflow Summary

| Quickflow | Type | Trigger Phase | Intervention |
|-----------|------|--------------|--------------|
| Collect top CPU processes (sensor) | Script | 1.2 | AUTO |
| Collect startup application list (sensor) | Script | 4.1 | AUTO |
| Disable non-essential startup entries | Script | 4.2 | AUTO |
| Run Invoke-AutoRemediateWindowsUpdates | Script | 3.2 | AUTO |
| Run Invoke-AutoRemediateNetworkStack | Script | 5.2d | AUTO |
| Run Disk Cleanup | Script | 3.2 | AUTO |
| Push Defender performance profile | MDM Profile | 2.1 | AUTO |
| Push GPU driver update | App/Script | 5.2a | ADMIN approval |
| Enable HAGS GPU scheduling (registry) | Script | 5.2a | AUTO + reboot prompt |
| Collect crash dump paths (sensor) | Script | 5.2b | AUTO |
| Collect unknown process hash/path (sensor) | Script | 7 | AUTO |
| Raise support ticket | Ticket automation | Any escalation | AUTO |
| Reboot device (deferred 5 min) | MDM Command / Script | Post-remediation | USER notified |

---

## Escalation Criteria

Escalate to an IT administrator (ADMIN) when any of the following are true:

- Unknown or unsigned process found in top CPU consumers (Phase 7)
- CPU has been elevated > 4 hours with no root cause identified
- Application crashes are recurring and no update is available (Phase 5.2b)
- RAM is consistently at capacity across > 3 days in DEX history (Phase 6)
- Windows Update failures persisting > 14 days (Phase 3)
- BIOS is significantly out of date on a model with known microcode errata (Phase 8)
- Any startup entry with unknown publisher found (Phase 4.2)
- Network remediation fails and CRL endpoints are unreachable (Phase 5.2d)

---

## Post-Resolution Monitoring

After any AUTO remediation, the agent should:

1. Re-poll CPU utilization 15 minutes after remediation completes
2. Compare experience score before/after
3. Confirm the remediating Quickflow ran successfully (check UEM script output)
4. Log the root cause and remediation action taken to DEX custom attributes
   for trend analysis
5. If CPU has not improved within 30 minutes of remediation: re-run Phase 1
   triage and escalate

---

## Related Runbooks and Scripts

| Resource | Location |
|----------|---------|
| Runbook-DiskCleanup-Agent | DiskCleanup/Runbook-DiskCleanup-Agent.md |
| Invoke-AutoRemediateWindowsUpdates | WindowsAutoRemediation/ |
| Invoke-AutoRemediateNetworkStack | WindowsAutoRemediation/ |
| Invoke-AutoRemediateAudioBluetooth | WindowsAutoRemediation/ |
| High Memory Runbook | *(to be created)* |
| NetworkResolutionWizard | ResolutionWizard/ |
