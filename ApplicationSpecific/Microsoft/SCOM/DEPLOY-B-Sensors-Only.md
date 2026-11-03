# Solution B — Sensors Only, No Scripts

**The zero-script option.** Nine sensors in `Sensors/Standalone/` measure the device directly at
sample time. No scheduled scripts, no registry cache, nothing to deploy but the sensors themselves.

Use this when you cannot put scripts on the fleet — no script deployment permission, a change
freeze, a locked-down ring, or an evaluation where you want SCOM agent visibility in DEX today and
will decide about the sweep later.

Choosing between the two solutions:

| | [**Solution A**](DEPLOY-A-Sweep-Plus-Sensors.md) (scripts + sensors) | **Solution B** (this document) |
|---|---|---|
| Objects to deploy | 3 scripts + 7 sensors | 9 sensors |
| Checks covered | 14 of 14 | 8 of 14 |
| Health score range | 235 deductible points | 130 deductible points |
| Sees management server reachability | ✅ | ❌ |
| Sees event-log faults | ✅ | ❌ |
| Auto-remediates anything | ✅ (2 actions) | ❌ |
| Needs script deployment permission | Yes | No |
| Needs scheduling discipline | Yes | No |

---

## Table of Contents

1. [What you are deploying](#1-what-you-are-deploying)
2. [Read this before you commit](#2-read-this-before-you-commit)
3. [Prerequisites](#3-prerequisites)
4. [Test it locally first](#4-test-it-locally-first)
5. [UEM configuration](#5-uem-configuration)
6. [Validating the first fleet run](#6-validating-the-first-fleet-run)
7. [Measuring what you are missing](#7-measuring-what-you-are-missing)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. What you are deploying

Nine sensors from `Sensors/Standalone/`. Six replace a cached sensor from Solution A; three have no
equivalent there at all.

| Sensor | Type | Fallback | Reports |
|---|---|---|---|
| `scom_agent_health_score_standalone.ps1` | Integer | `-1` | Composite local health, 0–100 |
| `scom_agent_health_reason_standalone.ps1` | String | `""` | Largest single deduction |
| `scom_healthservice_running_standalone.ps1` | Boolean | *(no sample)* | Agent Running **and** start type Automatic |
| `scom_management_group_count_standalone.ps1` | Integer | `-1` | Management groups assigned: 0, 1, or multi-homed |
| `scom_cert_expiry_days_standalone.ps1` | Integer | `-1` | Days until the channel certificate expires |
| `scom_agent_version_standalone.ps1` | String | `""` | Four-part agent file version |
| `scom_config_age_hours_standalone.ps1` | Integer | `-1` | Hours since the connector config cache was written |
| `scom_state_folder_mb_standalone.ps1` | Integer | `-1` | Health Service State folder size |
| `scom_monitoringhost_memory_mb_standalone.ps1` | Integer | `-1` | HealthService + MonitoringHost working set |

The middle three — `healthservice_running`, `management_group_count`, `cert_expiry_days` — have no
cached counterpart. The sweep records all three metrics but exposes them only through the score, so
these are additions rather than replacements. They are also the three most useful signals here,
because each one names a fault the score alone will not.

> **Do not deploy `Sensors/` alongside `Sensors/Standalone/`.** That is Solution A. Running both
> gives you two columns reporting the same attribute under different names, doubles the sensor
> queue for one number, and they will disagree at the edges.

---

## 2. Read this before you commit

This is the part that determines whether Solution B is honest reporting or a false sense of
security in your environment.

Two whole classes of check cannot run inside a recurring sensor. **Network probes** are out because
a sensor runs on every device on every sample interval and the sensor queue is serialized —
one slow probe blocks every sensor behind it fleet-wide. **Event log queries** are out because a
`Get-WinEvent` pass costs seconds against a 5-second budget shared with every other sensor on the
device.

Removing the sweep script does not remove that constraint. It just decides who absorbs it. So the
standalone score uses the same point values, thresholds and reason names as the sweep, over a
strictly smaller rule set:

| Deduction | Points | Standalone | Why |
|---|---:|---|---|
| `HealthServiceStopped` | 40 | ✅ | Service query |
| `ManagementServerUnreachable` | 25 | ❌ | Needs a socket probe |
| `AgentNotRegistered` | 25 | ❌ | Needs the Operations Manager log |
| `NoManagementGroup` | 20 | ✅ | Registry |
| `ConnectorAuthenticationFailure` | 20 | ❌ | Needs the Operations Manager log |
| `HealthServiceStoreCorruption` | 20 | ❌ | Needs the ESENT log |
| `ConfigurationCacheStale` | 15 | ✅ | File timestamp |
| `AgentRuntimeFootprintHigh` | 15 | ✅ | Process query |
| `ChannelCertificateProblem` | 15 | ✅ | Certificate store |
| `TimeSkew` / `TimeSyncStale` | 15 | ⚠️ | Sync **age**, not measured offset |
| `WorkflowsUnloaded` | 10 | ❌ | Needs the Operations Manager log |
| `HealthServiceStateOversized` | 10 | ✅ | Folder size |
| `MultiHomedAgent` | 5 | ✅ | Registry |
| `IntermittentConnectivity` | 5 | ❌ | Needs the Operations Manager log |

The sweep can deduct **235** points. This set can deduct **130**.

**A standalone `100` therefore means "no locally visible fault", not "healthy".** A device that
cannot reach its management server at all — the most common real finding on a laptop fleet — still
scores 100 here.

Two reason values are named differently from Solution A on purpose, so the two datasets can never
be pooled by accident:

- **`HealthyLocal`** instead of `Healthy` — a weaker claim, deliberately worded as one.
- **`TimeSyncStale`** instead of `TimeSkew` — the sweep measures real clock offset with `w32tm.exe`;
  a sensor may not launch a process, so this reads the age of the last successful sync from the
  registry. Related signal, different measurement, different name.

There is deliberately **no standalone management-server-reachable sensor**. It is the one metric
with no honest local substitute, and inventing one would be worse than omitting it.

---

## 3. Prerequisites

- **Workspace ONE UEM** with Sensors enabled for Windows.
- **Execution context: SYSTEM.** The agent registry root, the install directory and
  `Cert:\LocalMachine\My` all require it. User context returns fallbacks for everything and looks
  exactly like a fleet with no agents.
- **PowerShell 5.1, x64.**
- **A test device with the SCOM agent installed** for section 4. An agentless device is worth
  testing too — it exercises the not-applicable paths — but proves nothing about the measurements.
- **No admin rights on the fleet beyond what sensors already have**, no AV exclusion, no scheduled
  tasks, no registry writes. These sensors are strictly read-only.

---

## 4. Test it locally first

Faster than Solution A's test — there is no state to set up and nothing to clean up afterwards.

### 4.1 Open the right shell

```powershell
$PSVersionTable.PSVersion              # 5.1.x
[Environment]::Is64BitProcess          # True
([Security.Principal.WindowsPrincipal] `
  [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)   # True
```

Copy `Sensors\Standalone` to a working directory, e.g. `C:\SCOMTest`, and `cd` there.

### 4.2 Run all nine at once

This is the whole test, and it checks the three things that matter — one value, right type, fast:

```powershell
Get-ChildItem .\Standalone\*.ps1 | ForEach-Object {
    $sw  = [System.Diagnostics.Stopwatch]::StartNew()
    $out = @(& $_.FullName)
    $sw.Stop()
    '{0,-45} values={1} ms={2,-5} => {3}' -f `
        $_.Name.Replace('scom_','').Replace('_standalone.ps1',''),
        $out.Count, $sw.ElapsedMilliseconds,
        $(if ($out.Count) { $out -join '|' } else { '<no value>' })
}
```

**What to expect on a device with the agent:**

```
agent_health_reason       values=1  ms=266  => HealthyLocal
agent_health_score        values=1  ms=39   => 100
agent_version             values=1  ms=13   => 10.22.10118.0
cert_expiry_days          values=1  ms=7    => -9998
config_age_hours          values=1  ms=28   => 3
healthservice_running     values=1  ms=4    => True
management_group_count    values=1  ms=6    => 1
monitoringhost_memory_mb  values=1  ms=3    => 214
state_folder_mb           values=1  ms=8    => 380
```

Three checks on that output:

1. **`values=1` on every sensor** — except `healthservice_running` on an agentless device, where
   `values=0` is correct. It deliberately emits nothing rather than a `$false` that would read as a
   real negative finding.
2. **Every `ms` well under 5,000.** Measured 3–266 ms across fixtures. See
   [4.5](#45-the-one-timing-risk-worth-checking) for the single sensor that can be slower.
3. **`cert_expiry_days = -9998` is normal**, not an error. It means no channel certificate is
   configured, which is expected for Kerberos-authenticated domain-joined agents. Sentinels:
   `-1` not measured, `-9999` a serial is configured but no matching certificate exists (the worst
   state — the agent cannot authenticate at all), `-9998` not applicable.

### 4.3 Check the score arithmetic by hand

The score is `100` minus every deduction that applies. Verify it against the individual sensors on
your test device so you trust it later:

```powershell
$score  = @(& .\Standalone\scom_agent_health_score_standalone.ps1)[0]
$reason = @(& .\Standalone\scom_agent_health_reason_standalone.ps1)[0]
"score=$score reason=$reason"

# then confirm the reason is consistent with the raw sensors:
@(& .\Standalone\scom_healthservice_running_standalone.ps1)      # False  -> -40
@(& .\Standalone\scom_management_group_count_standalone.ps1)     # 0 -> -20, >1 -> -5
@(& .\Standalone\scom_config_age_hours_standalone.ps1)           # >24 -> -15
@(& .\Standalone\scom_state_folder_mb_standalone.ps1)            # >1536 -> -10
```

The reason sensor reports **only the largest** deduction, so a device with four findings shows one.
That is by design; use the individual sensors to see the rest.

### 4.4 Test the agentless path

On a device with no SCOM agent, expected output is:

```
agent_health_reason       values=1  => NoAgentInstalled
agent_health_score        values=1  => -1
agent_version             values=1  => (empty string)
cert_expiry_days          values=1  => -1
config_age_hours          values=1  => -1
healthservice_running     values=0  => <no value>
management_group_count    values=1  => -1
monitoringhost_memory_mb  values=1  => -1
state_folder_mb           values=1  => -1
```

`-1` is **not a low score** — it means *not measured*. Filtering it out is the single most important
thing you will do with this data. See [section 6](#6-validating-the-first-fleet-run).

### 4.5 The one timing risk worth checking

`scom_state_folder_mb_standalone` is the only sensor here with an unbounded worst case: it walks
the Health Service State subtree with `Scripting.FileSystemObject`. In practice this returns in
well under a second, because state-folder bloat is almost always a handful of very large files
rather than a large file count — but a folder pathological in file count would be slower, and a
blocking COM call cannot be time-boxed from inside a sensor without a thread, which sensors may not
create.

Check it on your **worst** device, not your cleanest:

```powershell
1..5 | ForEach-Object {
    (Measure-Command { & .\Standalone\scom_state_folder_mb_standalone.ps1 }).TotalMilliseconds
}
```

If any run approaches 5,000 ms on a device representative of your fleet, do not deploy that one
sensor — deploy [Solution A](DEPLOY-A-Sweep-Plus-Sensors.md)'s cached `scom_state_folder_mb`
instead. A script has the budget for that walk; a sensor does not.

The composite score sensor protects itself differently: the folder walk runs **last** and is
skipped entirely if the sensor has already spent 2,500 ms, trading a 10-point deduction for a
guaranteed exit. So a slow state folder degrades the score's completeness rather than its runtime.

### 4.6 Clean up

Nothing to clean up. These sensors write no registry values, no files, and no scheduled tasks.
Delete the working directory and you are done.

---

## 5. UEM configuration

| Setting | Value |
|---|---|
| Script Type | PowerShell |
| Execution Context | **System** |
| Architecture | x64 |
| PowerShell Version | 5.1 |
| Trigger | Windows Sample Schedule |
| Assignment | **All** managed Windows devices |

Declare each sensor with the response data type from the table in
[section 1](#1-what-you-are-deploying). A type mismatch is the most common cause of a sensor that
appears to report nothing in Intelligence.

**Assign to all Windows devices, not just agent devices.** Every sensor returns a clean
not-applicable value on an agentless device, which makes unmonitored devices identifiable rather
than simply absent.

**Sample schedule.** Unlike Solution A there is no sweep to lag behind, so the schedule is a
straight cost/freshness trade. Daily is a sensible default. Going below hourly buys very little —
none of these metrics move faster than that in a way you would act on — and every sensor you add to
the schedule competes with every other sensor on the device.

**Suggested naming**, so the two solutions never get confused in a shared tenant:

```
[DEX] SCOM Agent Health Score (Local)
[DEX] SCOM Agent Health Reason (Local)
[DEX] SCOM HealthService Running
[DEX] SCOM Management Group Count
[DEX] SCOM Certificate Expiry Days
...
```

The `(Local)` suffix on the two composites is worth keeping. It is the reminder that a 100 here is
not a 100 from Solution A.

---

## 6. Validating the first fleet run

Give it one sample interval, then check in this order.

**1. Split on `scom_agent_health_reason_standalone` first.**

| Population | Meaning | Action |
|---|---|---|
| `NoAgentInstalled` | No agent on the device | Exclude from every rate and average. If this is most of the fleet, check the sensors are running as SYSTEM before concluding anything. |
| `HealthyLocal` | No locally visible fault | **Not the same as healthy** — see [section 2](#2-read-this-before-you-commit) |
| everything else | Real findings | Rank by count, not by device |

A fleet reporting almost entirely `NoAgentInstalled` when you know the agent is deployed means the
sensors are running in User context. That is the number-one deployment mistake here, and it is
silent — every sensor returns its honest not-measured value.

**2. Then `scom_agent_health_score_standalone`, with `-1` filtered out.**
Banding, same as Solution A: 100 clean, 85–99 minor, 60–84 degraded, below 60 the agent is not
doing its job. Read the band, not the digit — the gap between 85 and 90 is one threshold crossing,
not a trend.

**3. Then the three signals the score cannot name on its own:**

| Sensor | What to look for |
|---|---|
| `scom_healthservice_running_standalone` | `False` with the agent present — the device is grey in the Operations console. This is the highest-value single number in the set. |
| `scom_management_group_count_standalone` | Count the `0` population. On an endpoint fleet these are usually Log Analytics / Azure Monitor installs of the same MMA binary rather than broken SCOM agents — cross-reference `scom_agent_version_standalone` before raising it with the SCOM team. |
| `scom_cert_expiry_days_standalone` | Sort ascending. Triage order falls out correctly: `-9999` (missing certificate) first, then expired, then expiring. **Filter `-9998` out before counting** — it is the not-applicable population and a "less than 30" filter would otherwise swallow it. |

**4. Sanity-check one device end to end**, confirming the composite score agrees with the
individual sensors, the same way you did in [4.3](#43-check-the-score-arithmetic-by-hand).

---

## 7. Measuring what you are missing

Solution B's blind spots are known in kind but not in size — how many of *your* devices are failing
a check this set cannot see is an empirical question, and there is a way to answer it.

Run **`OneTimeSensor/scom_agent_health.ps1`** once against a representative sample. It is a
self-contained run-once collection that does the full fourteen-step assessment — including the
socket probe and the event log mining — and returns everything as one JSON object. It reads no
cache, so it works on a fleet where nothing else from this folder is deployed.

Compare its `HealthScore` against `scom_agent_health_score_standalone` on the same devices:

- **Gap small or zero** — Solution B is capturing what matters on your fleet. Stay put.
- **Gap large** — the faults you care about are in the six deductions Solution B cannot see.
  Deploy [Solution A](DEPLOY-A-Sweep-Plus-Sensors.md).

Two caveats on that sensor: it requires the Workspace ONE Intelligence **one-time / run-once**
sensor capability and **must not be scheduled as a recurring sensor** — it is kept in a separate
folder specifically so nobody does that by mistake. And when its `TimedOut` field is `true`, treat
its `HealthScore` as a floor rather than a verdict; whatever the skipped phases would have deducted
is missing from it.

---

## 8. Troubleshooting

| Symptom | Most likely cause |
|---|---|
| Almost every device reports `NoAgentInstalled` / `-1` | Sensors running in **User** context. They cannot read the agent registry root there and return their honest not-measured values. |
| A sensor reports nothing at all in Intelligence | Response data type declared wrong. Check it against the table in [section 1](#1-what-you-are-deploying). |
| `healthservice_running` has no sample on some devices | Correct behaviour on an agentless device — there is no honest boolean for "does not apply", so it emits nothing. |
| `cert_expiry_days` is `-9998` everywhere | Normal on a domain-joined fleet. Kerberos-authenticated agents have no channel certificate. |
| Scores look implausibly healthy | Expected — re-read [section 2](#2-read-this-before-you-commit). This set cannot see connectivity or event-log faults. Quantify it with [section 7](#7-measuring-what-you-are-missing). |
| `state_folder_mb` occasionally slow or `-1` | The subtree walk on a pathological folder. Switch that one sensor to the Solution A cached version. |
| Two columns for the same metric disagree | Both `Sensors/` and `Sensors/Standalone/` are deployed. Pick one set and retire the other. |
| `config_age_hours` differs from a colleague's reading by an hour | Expected. This sensor measures live and rounds to whole hours; Solution A's reads a cache written with one decimal place. Both are well inside the 24-hour staleness threshold. |
