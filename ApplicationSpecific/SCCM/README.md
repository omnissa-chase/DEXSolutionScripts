# SCCM Client Health — DEX Deployment Guide

> **Scope:** This guide covers deploying the SCCM/MECM client health scripts in this folder via
> **Omnissa Workspace ONE UEM** and surfacing results in **Workspace ONE DEX**.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Script Summary and Deployment Order](#2-script-summary-and-deployment-order)
3. [Deployment Settings — All Scripts](#3-deployment-settings--all-scripts)
4. [Deploying the Main Health Sweep](#4-deploying-the-main-health-sweep)
5. [DEX Sensors — Capturing Results](#5-dex-sensors--capturing-results)
6. [Deploying the Opt-In Spin-Off Scripts](#6-deploying-the-opt-in-spin-off-scripts)
7. [Recommended DEX Dashboards and Alerts](#7-recommended-dex-dashboards-and-alerts)
8. [Suggested Rollout Rings](#8-suggested-rollout-rings)
9. [Tunable Reference](#9-tunable-reference)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Overview

This folder contains five PowerShell scripts that detect and remediate common SCCM/MECM client
health problems. They follow the same step-engine pattern used across all DEX solution scripts:
each step returns `Passed`, `Warning`, or `Failed`, remediations run automatically where safe,
and the script exits `0` (all passed) or `1` (at least one step failed) so Workspace ONE UEM
can report compliance state and DEX can trend it.

**Architecture — two tiers:**

```
Tier 1 — Run fleet-wide (low blast radius)
  Invoke-AutoRemediateSCCMClient.ps1     <- 14-step health sweep, detects only for risky steps

Tier 2 — Deploy to targeted rings only (opt-in, higher impact)
  Invoke-AutoRemediateWMIRepository.ps1  <- WMI salvage (restarts Winmgmt)
  Invoke-AutoRemediateCcmCache.ps1       <- Cache purge (DP/WAN re-download cost)
  Invoke-AutoRemediateBITSBacklog.ps1    <- Stalled CCM BITS job removal
  Invoke-AutoRemediateOrphanedCcmSetup.ps1 <- Orphaned install process cleanup
```

Use the DEX custom attribute written by the main sweep to decide which devices need a Tier 2
script — target by signal, not by collection.

---

## 2. Script Summary and Deployment Order

| Script | Tier | Auto-Remediates | Deploy When |
|---|---|---|---|
| `Invoke-AutoRemediateSCCMClient.ps1` | 1 | Service start, DNS flush, policy trigger | Always — broad health baseline |
| `Invoke-AutoRemediateWMIRepository.ps1` | 2 | WMI salvage (double-verified) | Main sweep reports WMI inconsistency |
| `Invoke-AutoRemediateCcmCache.ps1` | 2 | Stale cache element purge | Main sweep reports cache > 80% |
| `Invoke-AutoRemediateBITSBacklog.ps1` | 2 | Stalled CCM BITS job removal | Main sweep reports stalled CCM jobs |
| `Invoke-AutoRemediateOrphanedCcmSetup.ps1` | 2 | Kill confirmed-stuck ccmsetup | Main sweep reports ccmsetup runtime > 4h |

Deploy **Tier 1 first**. Use its output to build targeted smart groups before deploying any
Tier 2 script.

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

> **Never run these in User context.** WMI, service control, BITS, and the CM namespaces
> all require SYSTEM or local Administrator. User context will silently produce empty results
> or access-denied exceptions.

---

## 4. Deploying the Main Health Sweep

### Script: `Invoke-AutoRemediateSCCMClient.ps1`

**UEM Script Configuration**

| Setting | Value |
|---|---|
| Name | `[DEX] SCCM Client Health Sweep` |
| Execution Context | System |
| Timeout | 120 seconds |
| Trigger | Scheduled — every 24 hours |
| Assignment | All managed Windows devices with SCCM client installed |

**Timeout note:** The stated 60-second budget is the happy path. Budget 120 seconds in UEM to
absorb the case where CcmExec is stopped (service start adds time) or the MP probe times out
on both ports.

**What it remediates automatically:**

| Step | Auto-Action |
|---|---|
| 1 — CcmExec Service State | Sets start type to Automatic (Delayed) and starts service |
| 7 — MP Connectivity | Flushes DNS (local-side only; MP outage is server-side) |
| 8 — Policy Retrieval Freshness | Triggers machine policy retrieval + evaluation cycles |

**What it reports but does NOT act on:**

Steps 3 (WMI), 5 (cache), 10 (BITS), 14 (ccmsetup) are detection-only. Their messages name
the spin-off script to deploy. Use DEX Custom Attributes (section 5) to surface these signals.

**Exit Codes**

| Exit Code | Meaning in DEX |
|---|---|
| `0` | All steps passed or warnings only — client healthy |
| `1` | At least one step failed — client needs attention |

---

## 5. DEX Sensors — Capturing Results

Sensors read the step results written by each script run and surface them as DEX attributes.
Create the following sensors in the UEM console under **Resources → Sensors**.

### 5.1 Overall Client Health Status

Returns the last exit code of the main sweep as a compliant/non-compliant signal.

```powershell
# Sensor: SCCM_ClientHealthStatus
# Return Type: Boolean
# Frequency: On-demand or every 24h (match the script schedule)

$log = Get-WinEvent -LogName System -MaxEvents 100 -ErrorAction SilentlyContinue |
       Where-Object { $_.Id -eq 7036 -and $_.Message -match 'CcmExec' } |
       Select-Object -First 1

# Simpler signal: check that CcmExec is running and the CM namespace responds.
$svc    = (Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue).Status
$client = Get-CimInstance -Namespace 'root\ccm' -ClassName 'SMS_Client' -ErrorAction SilentlyContinue

if ($svc -eq 'Running' -and $client) { return $true }
return $false
```

### 5.2 Client Version

```powershell
# Sensor: SCCM_ClientVersion
# Return Type: String

$client = Get-CimInstance -Namespace 'root\ccm' -ClassName 'SMS_Client' -ErrorAction SilentlyContinue
if ($client) { return $client.ClientVersion }
return 'Unavailable'
```

### 5.3 WMI Repository State

```powershell
# Sensor: SCCM_WMIRepositoryConsistency
# Return Type: String

$out  = & "$env:SystemRoot\System32\wbem\winmgmt.exe" /verifyrepository 2>&1
$code = $LASTEXITCODE
if ($code -eq 0) { return 'Consistent' }
return "Inconsistent: $($out -join ' ')"
```

### 5.4 Cache Utilization Percent

```powershell
# Sensor: SCCM_CacheUtilizationPct
# Return Type: Integer

$cfg = Get-CimInstance -Namespace 'root\ccm\SoftMgmtAgent' -ClassName 'CacheConfig' `
           -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $cfg -or $cfg.Size -le 0) { return -1 }

$elements = @(Get-CimInstance -Namespace 'root\ccm\SoftMgmtAgent' -ClassName 'CacheInfoEx' `
                  -ErrorAction SilentlyContinue)
$usedMB   = [math]::Round((($elements | Measure-Object -Property ContentSize -Sum).Sum) / 1024)
$pct      = [math]::Round(($usedMB / [int]$cfg.Size) * 100)
return $pct
```

### 5.5 Stalled CCM BITS Job Count

```powershell
# Sensor: SCCM_StalledBITSJobCount
# Return Type: Integer

$cutoff  = (Get-Date).AddHours(-4)
$stalled = @(
    Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue |
    Where-Object {
        $_.DisplayName -like 'CCMDTS*' -and
        $_.JobState -eq 'Error' -and
        $_.CreationTime -lt $cutoff
    }
)
return $stalled.Count
```

### 5.6 Management Point Reachability

```powershell
# Sensor: SCCM_MPReachable
# Return Type: Boolean

$mp = (Get-CimInstance -Namespace 'root\ccm' -ClassName 'SMS_Authority' `
           -ErrorAction SilentlyContinue | Select-Object -First 1).CurrentManagementPoint
if (-not $mp) { return $false }

foreach ($port in 443, 80) {
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $tcp.BeginConnect($mp, $port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne(3000, $false)) {
            $tcp.EndConnect($ar)
            if ($tcp.Connected) { return $true }
        }
    } catch {
    } finally { $tcp.Close() }
}
return $false
```

---

## 6. Deploying the Opt-In Spin-Off Scripts

Each spin-off should be deployed as a **separate script** against a **targeted smart group**
built from the DEX sensor data collected in section 5. Deploy to a pilot ring first, observe
sensor values the following day, then expand.

---

### 6.1 WMI Repository Remediation

**Script:** `Invoke-AutoRemediateWMIRepository.ps1`

| UEM Setting | Value |
|---|---|
| Name | `[DEX] SCCM - Remediate WMI Repository` |
| Timeout | 300 seconds |
| Trigger | On-demand / Freestyle (not scheduled) |

**Target smart group — build from sensor `SCCM_WMIRepositoryConsistency`:**
- Value contains `Inconsistent`

**What to watch for:**
- The script double-verifies before acting. A single inconsistent result that clears on re-check
  is logged as a false positive and no salvage runs. Check UEM script output to confirm which
  outcome occurred.
- After the script runs, let sensors collect for 24 hours. Devices that remain inconsistent
  after two runs are candidates for manual imaging review.

> **Warning:** This script restarts the Winmgmt service. Schedule it during the device's
> maintenance window or use a Freestyle trigger off-hours. Do not deploy during business
> hours to devices with live monitoring agents that depend on WMI.

---

### 6.2 Cache Cleanup

**Script:** `Invoke-AutoRemediateCcmCache.ps1`

| UEM Setting | Value |
|---|---|
| Name | `[DEX] SCCM - Remediate Cache` |
| Timeout | 120 seconds |
| Trigger | Scheduled — once, with a randomised delay (see note) |

**Target smart group — build from sensor `SCCM_CacheUtilizationPct`:**
- Value greater than `80`

**Staggered deployment — critical:**
Every device that purges cache may re-request content from a distribution point. Deploying
simultaneously to a large collection creates a synchronised WAN/DP spike.

Use UEM's **deployment time window** with **randomisation** enabled, or split the assignment
into rings by building multiple smart groups:
- Ring 1: devices above 95% (most urgent) — deploy immediately
- Ring 2: devices 80–95% — deploy 48 hours later

The `$MaxDeletePerRun = 50` cap inside the script also limits per-execution load. Devices
above 80% that still clear only 50 elements per run will need multiple scheduled runs to
fully recover.

---

### 6.3 BITS Job Cleanup

**Script:** `Invoke-AutoRemediateBITSBacklog.ps1`

| UEM Setting | Value |
|---|---|
| Name | `[DEX] SCCM - Remediate BITS Backlog` |
| Timeout | 60 seconds |
| Trigger | On-demand or Freestyle |

**Target smart group — build from sensor `SCCM_StalledBITSJobCount`:**
- Value greater than `0`

**What to watch for:**
- The script scopes exclusively to `CCMDTS*` jobs. Windows Update and Delivery Optimization
  jobs are surveyed and reported but never removed. Confirm via UEM script output that only
  CCM jobs appear in the removed list.
- After running, trigger a DEX check-in and confirm `SCCM_StalledBITSJobCount` returns `0`.
  If not, CcmExec re-created the job, which points to a content or DP problem rather than a
  BITS problem — escalate to the site admin.

---

### 6.4 Orphaned CcmSetup Cleanup

**Script:** `Invoke-AutoRemediateOrphanedCcmSetup.ps1`

| UEM Setting | Value |
|---|---|
| Name | `[DEX] SCCM - Remediate Orphaned CcmSetup` |
| Timeout | 120 seconds |
| Trigger | On-demand only (not scheduled) |

**Target smart group — identify from main sweep output:**
- Script output contains `ccmsetup.exe running for` and `threshold`

**Do not deploy on a schedule.** ccmsetup running for 4+ hours may legitimately be a slow
WAN install. Review `ccmsetup.log` on at least a sample of targeted devices before deploying.

**The script's own guards will abort if:**
- Content is actively downloading (live BITS transfer or growing folder)
- ccmsetup.log does not confirm a retry-loop pattern
- ccmsetup has been running less than 4 hours

**After running:** Step 4 of the script reports whether CcmExec is intact. If that step
returns `Failed`, the client is likely partially installed and needs a manual
`ccmsetup /uninstall` followed by a reinstall push from the site server.

---

## 7. Recommended DEX Dashboards and Alerts

### Suggested Custom Attributes to Promote

| Attribute | Source Sensor | Threshold for Alert |
|---|---|---|
| SCCM Client Healthy | `SCCM_ClientHealthStatus` | False → alert |
| Client Version | `SCCM_ClientVersion` | Mismatch vs. expected version string |
| WMI Repository | `SCCM_WMIRepositoryConsistency` | Contains "Inconsistent" |
| Cache Utilization | `SCCM_CacheUtilizationPct` | > 80 → warning, > 95 → critical |
| Stalled BITS Jobs | `SCCM_StalledBITSJobCount` | > 0 → warning |
| MP Reachable | `SCCM_MPReachable` | False → alert |

### DEX Experience Score Impact

The main sweep exits `1` when any step hard-fails, which UEM surfaces as a non-compliant
script run. Map this to a DEX **experience factor** to let client health influence the device
experience score:

1. In DEX, go to **Experience → Experience Factors → Add Factor**
2. Source: the `[DEX] SCCM Client Health Sweep` script compliance state
3. Weighting: start at 10–15% and adjust based on how predictive it proves for your fleet

---

## 8. Suggested Rollout Rings

| Ring | Scope | What to Validate |
|---|---|---|
| Pilot (1–5%) | IT devices, volunteered users | Script output readable, sensors returning expected values, no unintended side effects |
| Ring 1 (10%) | Representative sample across models and OS builds | Exit code distribution, false-positive rate on WMI step, cache sensor values |
| Ring 2 (50%) | Broad fleet minus high-sensitivity devices | At-scale DP load from any cache purge activity |
| Production (100%) | All Windows managed devices | Ongoing via DEX dashboard |

Wait at least **24 hours** between rings, and collect sensor data after each before expanding.

---

## 9. Tunable Reference

The tunables block at the top of each script controls detection thresholds. Adjust to match
your environment's norms before deployment — the defaults are conservative starting points.

### `Invoke-AutoRemediateSCCMClient.ps1`

| Variable | Default | When to Change |
|---|---|---|
| `$StartupDelayWarnSeconds` | `300` | Increase for environments with full-disk encryption or many logon scripts that legitimately delay WMI start |
| `$WmiRepoWarnMB` | `500` | Decrease if your baseline repo is consistently much smaller; many environments sit at 25–150MB |
| `$CacheUsedWarnPercent` | `80` | Adjust to your DP capacity and deployment frequency |
| `$PolicyStaleHours` | `48` | Match your CM policy polling interval; default CM interval is 60 minutes |
| `$CertExpiryWarnDays` | `30` | Match your PKI renewal lead time |
| `$CcmSetupOrphanMinutes` | `120` | Increase to 240+ for remote/VPN fleets with slow DP links |
| `$NetTimeoutMs` | `3000` | Increase to 5000 on high-latency WAN or satellite links |

### `Invoke-AutoRemediateCcmCache.ps1`

| Variable | Default | When to Change |
|---|---|---|
| `$CacheUsedWarnPercent` | `80` | Match to the value in the main sweep sensor |
| `$StaleCacheDays` | `30` | Decrease for high-deployment-frequency environments; increase for quarterly-patching fleets |
| `$MaxDeletePerRun` | `50` | Decrease to reduce per-run DP load; increase for devices that must be cleared in a single window |

### `Invoke-AutoRemediateOrphanedCcmSetup.ps1`

| Variable | Default | When to Change |
|---|---|---|
| `$OrphanMinutes` | `240` | Increase for satellite/high-latency fleets; never decrease below 180 |
| `$ProgressWaitSec` | `8` | Increase if devices have very slow disk I/O that makes growth hard to detect in the sample window |
| `$MinRetryCount` | `3` | Decrease to `2` if logs show the loop pattern manifests quickly in your client version |

---

## 10. Troubleshooting

### Script shows all steps as Passed but CcmExec is clearly broken

**Most likely cause:** WMI is broken at the `Win32_Service` level so `Get-Service` returns
nothing. Step 1 returns `Failed` in this case, but if WMI is in a partial-failure state
it may return an empty result that step 1 treats as Passed.

**Action:** Deploy `Invoke-AutoRemediateWMIRepository.ps1` to the device.

---

### Step 7 (Management Point) fails on all devices simultaneously

**Most likely cause:** The MP itself is down or a network change blocked 443/80 to it.
This is a server-side issue — the script only flushes DNS (the local-only fix). Escalate
to the CM / network team. Filter the alert to avoid noise: if > 20% of devices report
`SCCM_MPReachable = False` at the same time, suppress individual device tickets and file
one infrastructure ticket.

---

### Cache cleanup script ran but cache is still at 90%+

**Most likely causes:**
1. The `$MaxDeletePerRun = 50` cap was hit — re-run the script once more
2. Elements are younger than `$StaleCacheDays` — they are in active use, the cache size is
   by design; consider increasing the CM client cache size via a CM client settings policy
   instead of purging

---

### `Invoke-AutoRemediateOrphanedCcmSetup.ps1` keeps aborting at the download guard

ccmsetup is actively fetching content — it is not stuck. The retry-loop guard will fire only
after downloads stall and retries appear in the log. If this repeats across days, the content
source (DP) is the problem, not the client. Confirm DP disk space and content validation in
the CM console.

---

### WMI script step 3 (post-salvage) fails with "root\ccm unavailable"

Salvage completed but removed the CM MOF classes. CcmExec needs to re-register its WMI
providers. In most cases, restarting CcmExec (`sc.exe start CcmExec`) resolves this — the
script attempts this automatically. If the namespace is still absent after a restart, a full
client repair (`ccmsetup /forceinstall`) is required. Trigger this from the CM console
client push rather than from this script.

---

*These scripts are provided "AS IS". Deploy to a non-production ring first. See LICENSE for
full terms.*
