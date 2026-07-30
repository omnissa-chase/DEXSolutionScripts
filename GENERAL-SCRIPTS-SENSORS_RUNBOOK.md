# Agent Runbook: Omnissa Workspace ONE UEM — Scripts & Sensors

> **Purpose:** This runbook is **normative** for AI agents generating PowerShell scripts and sensors for Omnissa Workspace ONE UEM. It is written to be followed mechanically at authoring time, not read as advice.
>
> **How to read the rule language:**
> - **MUST / MUST NOT** — a hard constraint. Generated code that violates it is defective. Do not ship it.
> - **SHOULD / SHOULD NOT** — strong default. Deviating requires an explicit, stated reason in the script header.
> - **MAY** — permitted option, use judgment.
>
> When a request is ambiguous, **stop and ask** rather than guessing. Prefer safety, compatibility, and explicitness over cleverness.

---

## Table of Contents

1. [Agent Behavior Guidelines](#1-agent-behavior-guidelines)
2. [Runtime Target](#2-runtime-target)
3. [Execution Time Budgets](#3-execution-time-budgets)
4. [Asynchronous Execution Patterns](#4-asynchronous-execution-patterns)
5. [Script Authoring Rules](#5-script-authoring-rules)
6. [WhatIf / ShouldProcess Support](#6-whatif--shouldprocess-support)
7. [Check-Then-Apply Pattern](#7-check-then-apply-pattern)
8. [High-Impact Actions and Admin Confirmation](#8-high-impact-actions-and-admin-confirmation)
9. [Script Variables — Current UEM Limitations](#9-script-variables--current-uem-limitations)
10. [Sensor Authoring Rules](#10-sensor-authoring-rules)
11. [Exit Codes](#11-exit-codes)
12. [Error Handling Patterns](#12-error-handling-patterns)
13. [Registry and File Storage Conventions](#13-registry-and-file-storage-conventions)
14. [Logging Conventions](#14-logging-conventions)
15. [Caching Pattern: Script Writes, Sensor Reads](#15-caching-pattern-script-writes-sensor-reads)
16. [On-Disk Script Pattern](#16-on-disk-script-pattern)
17. [Scheduled Task Pattern](#17-scheduled-task-pattern)
18. [Measuring Disk Space](#18-measuring-disk-space)
19. [Anti-Patterns to Avoid](#19-anti-patterns-to-avoid)
20. [Quick Reference Checklist](#20-quick-reference-checklist)

---

## 1. Agent Behavior Guidelines

- **MUST NOT use third-party libraries, modules, or NuGet/PSGallery packages.** Only built-in Windows PowerShell 5.1 cmdlets, .NET Framework classes shipped with Windows, WMI/CIM, COM objects present on a stock Windows install, and in-box executables (`sc.exe`, `winmgmt.exe`, `robocopy.exe`). If a task appears to require an external module, solve it with in-box tooling or state that it cannot be done safely.
- **MUST target Windows PowerShell 5.1 (x64)** unless the user explicitly requests PowerShell 7 *and* confirms their environment supports it.
- **MUST NOT assume the execution context.** Scripts run as SYSTEM unless stated otherwise. Sensors declare their own context.
- **MUST NOT generate code that runs indefinitely.** Every script has a predictable end state.
- **MUST respect the execution time budget.** See [§3](#3-execution-time-budgets). Anything that can exceed the synchronous ceiling is dispatched asynchronously.
- **MUST include error handling.** An unhandled terminating exception can block the Hub or Freestyle execution pipeline.
- **MUST exit explicitly on every code path.** See [§11](#11-exit-codes).
- **SHOULD follow check-then-apply.** Detect actual state, then remediate only what is genuinely wrong. See [§7](#7-check-then-apply-pattern).
- **MUST gate high-impact actions** behind an explicit admin confirmation variable. See [§8](#8-high-impact-actions-and-admin-confirmation).
- **MUST support `-WhatIf`** in any script that changes state. See [§6](#6-whatif--shouldprocess-support).
- **MUST NOT use `Write-Host` in a sensor.** Sensor output goes to the pipeline via `Write-Output` / `echo`. See [§10](#10-sensor-authoring-rules).
- **SHOULD prefer registry storage** for cached state when running as SYSTEM.
- **MUST NOT emit smart quotes, curly apostrophes, or non-ASCII characters** in generated code. These cause silent parse failures when scripts move between platforms and consoles.
- **MUST ask clarifying questions** when the request is ambiguous about script vs. sensor — the rules differ materially.

---

## 2. Runtime Target

| Setting | Value |
|---|---|
| **Default shell** | Windows PowerShell 5.1 (`powershell.exe`) |
| **Architecture** | x64 |
| **Execution context** | SYSTEM (unless specified) |
| **PowerShell 7** | Only if explicitly requested AND environment confirmed |
| **Third-party modules** | Never — in-box only |
| **macOS authors** | Warn about smart quotes, CRLF/LF issues, Unicode corruption |

### PowerShell 5 vs. PowerShell 7 — When to Use Each

**Use PowerShell 5 (default):**
- Built into Windows 10 and Windows 11, no deployment required
- Full access to COM, WMI, classic .NET Framework, and Win32 automation
- All enterprise management documentation and modules target PS5

**Use PowerShell 7 only when:**
- The user has explicitly confirmed PS7 is deployed to endpoints
- The specific task requires a PS7-only feature (e.g., `ForEach-Object -Parallel`)
- Compatibility with WMI/COM has been validated for the scenario

### No Third-Party Dependencies

Endpoints may have no internet access, no PSGallery trust, and no pre-staged modules. A script that assumes a module exists fails across a large share of the fleet.

| Need | MUST NOT use | Use instead |
|---|---|---|
| JSON | External parsers | `ConvertTo-Json` / `ConvertFrom-Json` |
| Scheduled tasks | Third-party schedulers | `ScheduledTasks` module (in-box) or `schtasks.exe` |
| Archives | 7-Zip, external DLLs | `Expand-Archive` / `Compress-Archive`, `System.IO.Compression` |
| HTTP | External REST modules | `Invoke-RestMethod` / `Invoke-WebRequest` (never in a sensor) |
| AD queries | `ActiveDirectory` module (RSAT, not guaranteed) | `System.DirectoryServices` / ADSI |
| Folder sizing | External utilities | See [§18](#18-measuring-disk-space) |

---

## 3. Execution Time Budgets

Execution time is the most common cause of a script that works on a test device behaving badly in production. Hub script execution and the sensor queue are both **serialized** — a slow item blocks everything behind it.

### Budgets

| Workload | Ideal | Acceptable | Hard Ceiling | Beyond ceiling |
|---|---|---|---|---|
| **Sensor** (recurring) | < 2 s | < 5 s | 30 s (UEM max) | Not allowed — split into script + cached sensor |
| **Sensor** (one-time DEX collection) | < 5 s | < 15 s | 30 s (UEM max) | Not allowed |
| **Script** (synchronous) | < 10 s | < 30 s | 60 s | MUST dispatch asynchronously |
| **Script** (async payload) | n/a | n/a | Self-enforced | MUST self-enforce a deadline |

### Why 60 Seconds Is Already Too Long

While a synchronous script runs, **no other action can start** on that device. A 60-second script means a full minute in which no other script, sensor, or Freestyle step proceeds. Across a fleet-wide scheduled deployment, the queue backs up badly.

Treat **30 seconds as the design target** and **60 seconds as a ceiling requiring justification**. If a script *can* exceed 60 seconds under any realistic failure condition — not just the happy path — it MUST be dispatched asynchronously.

### Estimate Worst Case, Not Best Case

| Operation | Budget as |
|---|---|
| `Get-Service` / `Get-Process` / registry read | < 100 ms |
| Single WMI/CIM query (in-box class) | 100 ms - 1 s |
| WMI query against a custom/CM namespace | 1 - 3 s |
| `Get-CimInstance Win32_Process` with CommandLine | ~1 s |
| `Start-Service` (blocking) | Up to the SCM timeout, ~30 s |
| Network probe (per host, per port) | The full timeout — assume it always times out |
| `winmgmt /salvagerepository` | 30 s - 3 min |
| `ccmeval.exe` | Multiple minutes |
| Recursive file enumeration | Unbounded — see [§18](#18-measuring-disk-space) |
| Any `Start-Sleep` | Exactly what you wrote, every time |

---

## 4. Asynchronous Execution Patterns

When a workload cannot fit the synchronous budget, the delivered script becomes a **launcher** that dispatches the real work and exits immediately. Two dispatch mechanisms are supported. Neither is universally correct.

### 4.1 Decision Matrix

| Factor | Scheduled Task | `System.Diagnostics.Process` (ShellExecute) |
|---|---|---|
| Requires AV/EDR path exception | **Yes** — `C:\ProgramData\AirWatch\Extensions` | No task registration, but the payload on disk is still scanned |
| Enforced execution time limit | Yes (`-ExecutionTimeLimit`) | No — payload must self-enforce |
| Survives parent process exit | Yes | Yes (when `UseShellExecute = $true`) |
| Survives a reboot mid-run | Yes (`-StartWhenAvailable`) | No |
| Troubleshooting visibility | Task Scheduler history + last result | Log file only |
| Can target the interactive user | Yes (principal / `-UserId`) | No — inherits caller context (SYSTEM, session 0) |
| Setup complexity | Higher | Lower |
| Flagged as suspicious by EDR | Sometimes — script-created tasks are a common heuristic | Less often |

**Default:** scheduled task, *provided* the customer can add the AV exception. Fall back to `System.Diagnostics.Process` when they cannot.

### 4.2 Scheduled Task Dispatch — AV Exception Required

This project stages payloads under `C:\ProgramData\AirWatch\Extensions`. Many AV/EDR products will quarantine scripts written there by a SYSTEM process, or block the task registration outright.

> **Admin prerequisite — state this in any deliverable using this pattern:**
>
> Add an exclusion for `C:\ProgramData\AirWatch\Extensions\` and subfolders in the endpoint AV/EDR product. Without it the payload may be silently quarantined, and the task will appear to succeed while doing nothing.

```powershell
# === Launcher: dispatch payload via one-shot scheduled task, then exit ===
param([switch]$RunAsPayload)

$TaskName   = "WS1_MyLongRunningWork"
$BaseDir    = "C:\ProgramData\AirWatch\Extensions\MyApp"
$PayloadPs1 = Join-Path $BaseDir "Invoke-MyWork.ps1"

if (-not $RunAsPayload) {
    try {
        # Concurrency gate - see 4.5
        $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($existing -and $existing.State -eq 'Running') {
            Write-Output "$HEAD Payload already running. Skipping dispatch."
            exit 0
        }

        if (-not (Test-Path $BaseDir)) {
            New-Item -ItemType Directory -Path $BaseDir -Force -ErrorAction Stop | Out-Null
        }

        # Self-copy: the UEM temp copy of this script is deleted after execution.
        Copy-Item -Path $PSCommandPath -Destination $PayloadPs1 -Force -ErrorAction Stop

        if ($existing) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        }

        $action    = New-ScheduledTaskAction -Execute "powershell.exe" `
                        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PayloadPs1`" -RunAsPayload"
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit "00:10:00" `
                        -DeleteExpiredTaskAfter "00:01:00" -StartWhenAvailable -AllowStartIfOnBatteries

        Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal `
            -Settings $settings -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop

        Write-Output "$HEAD Dispatched '$TaskName'. Results will be written to the registry."
        exit 0
    }
    catch {
        Write-Error "$HEAD Launcher failed: $($_.Exception.Message)"
        exit 1
    }
}

# --- Payload runs below this line, in the scheduled task context ---
exit 0
```

### 4.3 Process Dispatch — No Task Registration

`UseShellExecute = $true` is the load-bearing detail. It launches the child through the shell so the child **does not inherit the parent's stdio handles**. With `UseShellExecute = $false`, Hub can keep waiting on those inherited handles even after the parent exits — which defeats the entire purpose of dispatching.

```powershell
# === Launcher: dispatch payload as a detached process, then exit ===
param([switch]$RunAsPayload)

$BaseDir    = "C:\ProgramData\AirWatch\Extensions\MyApp"
$PayloadPs1 = Join-Path $BaseDir "Invoke-MyWork.ps1"

if (-not $RunAsPayload) {
    try {
        if (-not (Test-Path $BaseDir)) {
            New-Item -ItemType Directory -Path $BaseDir -Force -ErrorAction Stop | Out-Null
        }
        Copy-Item -Path $PSCommandPath -Destination $PayloadPs1 -Force -ErrorAction Stop

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName  = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PayloadPs1`" -RunAsPayload"

        # Detaches the child from this process's stdio handles. Without it, Hub may
        # block waiting on inherited handles even after this script exits.
        $psi.UseShellExecute = $true
        $psi.WindowStyle     = [System.Diagnostics.ProcessWindowStyle]::Hidden

        # NOTE: CreateNoWindow and stream redirection are IGNORED when UseShellExecute
        # is $true. Do not set them. The payload MUST log to a file, not to stdout.

        $proc = [System.Diagnostics.Process]::Start($psi)
        Write-Output "$HEAD Dispatched payload as PID $($proc.Id)."
        exit 0
    }
    catch {
        Write-Error "$HEAD Launcher failed: $($_.Exception.Message)"
        exit 1
    }
}

# --- Payload runs below this line, detached ---
exit 0
```

### 4.4 Async Payload Requirements

Because the launcher's exit code no longer reflects the outcome, an async payload MUST:

1. **Self-enforce a maximum runtime.** Nothing external will stop it (process dispatch), or it will be killed without cleanup (task dispatch).
2. **Write results to the registry** so a companion sensor can report the real outcome.
3. **Stamp a `Dispatched` status in the launcher**, so dashboards do not read "no data" while the payload runs.
4. **Clean up after itself** — unregister the task, remove state files.
5. **Log to a file**, never to stdout — nothing is capturing stdout.

```powershell
# Self-enforced deadline inside an async payload
$Deadline = (Get-Date).AddMinutes(10)

while ($workRemaining) {
    if ((Get-Date) -gt $Deadline) {
        Write-Log "Deadline exceeded - aborting."
        Set-ItemProperty -Path $RegPath -Name "Status" -Value "TimedOut" -Type String
        exit 1
    }
    # ... one unit of work ...
}
```

### 4.5 Preventing Concurrent Execution

An async payload can be re-triggered by UEM while a previous run is still going. Use **three layers**, each with a distinct job.

#### Layer 1 — Launcher gate (cheap, mechanism-specific)

Catches the common case in milliseconds without touching the payload.

```powershell
# Task dispatch
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing -and $existing.State -eq 'Running') {
    Write-Output "$HEAD Payload already running. Skipping dispatch."
    exit 0
}
```

```powershell
# Process dispatch - match on command line, exclude self
$leaf = Split-Path $PayloadPs1 -Leaf
$running = Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
           Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like "*$leaf*" }
if ($running) {
    Write-Output "$HEAD Payload already running (PID $($running[0].ProcessId)). Skipping dispatch."
    exit 0
}
```

#### Layer 2 — Payload lock (authoritative)

A `Global\`-prefixed named mutex. This is **kernel-managed**, so it is released automatically when the owning process dies by any means — crash, kill, or power loss. There is no stale-lock failure mode. SYSTEM already holds `SeCreateGlobalPrivilege`, so the `Global\` namespace works.

```powershell
$MutexName = "Global\WS1_DEX_MyWork"
$mutex = $null
$owned = $false
try {
    $mutex = New-Object System.Threading.Mutex($false, $MutexName)

    try {
        $owned = $mutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        # Previous owner died without releasing. We now own it - and we know the
        # prior run did not finish cleanly, which is worth logging.
        $owned = $true
        Write-Log "Acquired abandoned mutex; previous run terminated unexpectedly."
    }

    if (-not $owned) {
        Write-Log "Another instance holds the lock. Exiting."
        exit 0
    }

    # ... payload work ...
    exit 0
}
finally {
    if ($owned) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
```

#### Layer 3 — Registry status (reporting only)

```powershell
Set-ItemProperty -Path $RegPath -Name "Status" -Value "Running" -Type String
# Values: Dispatched | Running | Completed | TimedOut | Failed
```

> **MUST NOT use a registry flag as the lock.** A hard kill, bugcheck, or power loss leaves the flag set with nothing to clear it, and the script is deadlocked permanently. The registry reports state; the mutex enforces it.

#### Concurrency vs. Cooldown

These are different problems, and the mutex only solves the first.

| Concern | Question | Mechanism |
|---|---|---|
| **Concurrency** | "Is another copy running right now?" | Named mutex (Layer 2) |
| **Cooldown** | "Did this already run recently enough to skip?" | Registry `LastRunTime` + minimum interval |

```powershell
# Cooldown gate - skip if it ran successfully within the window
$MinIntervalHours = 12
$last = (Get-ItemProperty -Path $RegPath -Name "LastRunTime" -ErrorAction SilentlyContinue).LastRunTime
if ($last) {
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($last, [ref]$parsed)) {
        if ((Get-Date) -lt $parsed.AddHours($MinIntervalHours)) {
            Write-Output "$HEAD Ran at $parsed, within the ${MinIntervalHours}h cooldown. Skipping."
            exit 0
        }
    }
}
```

---

## 5. Script Authoring Rules

Scripts are delivered and executed by Workspace ONE Hub or Freestyle Orchestrator. They must be well-behaved guests in that pipeline.

1. Scripts MUST **exit explicitly on every code path** — every `catch`, every early return, every guard clause. See [§11](#11-exit-codes).
2. Scripts MUST NOT **hang, loop indefinitely, or wait for user input**.
3. Scripts MUST **fit the synchronous budget** or dispatch asynchronously. See [§3](#3-execution-time-budgets).
4. Scripts MUST **handle foreseeable errors** with `try/catch`.
5. Scripts MUST **support `-WhatIf`** when they change state. See [§6](#6-whatif--shouldprocess-support).
6. Scripts SHOULD **check before they apply**. See [§7](#7-check-then-apply-pattern).
7. Scripts MUST **gate high-impact actions** behind an admin confirmation variable. See [§8](#8-high-impact-actions-and-admin-confirmation).
8. Scripts SHOULD **use the run-ID logging header**. See [§14](#14-logging-conventions).
9. Async scripts MUST **guard against concurrent execution**. See [§4.5](#45-preventing-concurrent-execution).
10. Scripts MUST NOT **launch uncontrolled background work** that outlives the script, except via the sanctioned async patterns.
11. Scripts SHOULD **suppress incidental pipeline output** (`| Out-Null` / `[void]`).
12. Scripts SHOULD **cache expensive results** to the registry for sensors to consume.
13. Scripts MUST NOT **use `Get-ChildItem` to calculate disk space**. See [§18](#18-measuring-disk-space).
14. Scripts SHOULD **hard-code tunables** rather than exposing UEM variables. See [§9](#9-script-variables--current-uem-limitations).

### Minimal Script Template

```powershell
#Requires -Version 5.1
<#
.SYNOPSIS
    Brief description of what this script does.
.NOTES
    Script Name  : Invoke-MyScript.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : [Author Name]
    Last Modified: yyyy-MM-dd
    Timeout      : 15 seconds
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param()

$SCRIPT_VERSION = "1.0.0"

# -- WhatIf bridge -------------------------------------------------------------
# UEM cannot set $WhatIfPreference directly. Bridge it from an environment
# variable. Absent, empty, or unparseable => $false (live run).
$WhatIfPreference = $false
if ($env:WhatIf) {
    try   { $WhatIfPreference = [System.Convert]::ToBoolean($env:WhatIf) }
    catch { $WhatIfPreference = $false }
}

# -- Run header ----------------------------------------------------------------
$RunEventId = ([Random]::new()).Next(1000, 9999)
Write-Host "[$RunEventId] Executing script, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'  WhatIf=$WhatIfPreference"
$HEAD = "`r`n[$RunEventId]"

try {
    # -- CHECK -----------------------------------------------------------------
    $needsRemediation = $false
    # ... detection logic ...

    if (-not $needsRemediation) {
        Write-Output "$HEAD No action required."
        exit 0
    }

    # -- APPLY -----------------------------------------------------------------
    if ($PSCmdlet.ShouldProcess("TargetName", "ActionDescription")) {
        # ... remediation logic ...
        Write-Output "$HEAD Remediation applied."
    }

    exit 0
}
catch {
    Write-Error "$HEAD ERROR: $($_.Exception.Message)"
    exit 1
}
```

---

## 6. WhatIf / ShouldProcess Support

Every script that **changes state** MUST declare `SupportsShouldProcess` and guard its mutating actions, giving admins a dry run to validate a deployment before it touches anything.

### The UEM Constraint

UEM has no native way to pass `-WhatIf` to a delivered script. Until it does, bridge the value from an environment variable and set `$WhatIfPreference` manually.

```powershell
[CmdletBinding(SupportsShouldProcess = $true)]
param()

# Default to a LIVE run. Only an explicit, parseable "true" enables WhatIf.
$WhatIfPreference = $false
if ($env:WhatIf) {
    try   { $WhatIfPreference = [System.Convert]::ToBoolean($env:WhatIf) }
    catch { $WhatIfPreference = $false }
}
```

### Rules

| Rule | Detail |
|---|---|
| Default is **live** | A missing, empty, or garbage `$env:WhatIf` MUST resolve to `$false`. Never fail into WhatIf mode — an admin expecting remediation would get a silent no-op. |
| Parse defensively | `[System.Convert]::ToBoolean` throws on unparseable input. Always wrap in `try/catch`. |
| Guard every mutation | Wrap each state-changing action in `$PSCmdlet.ShouldProcess(...)`. |
| Report the mode | Echo `WhatIf=$WhatIfPreference` in the run header so the log is unambiguous. |
| In-box cmdlets inherit it | Cmdlets that natively support ShouldProcess (`Stop-Process`, `Remove-Item`, `Set-Service`, ...) honor the script-scope `$WhatIfPreference` automatically. **External executables do not** — guard those explicitly. |

```powershell
# In-box cmdlet: honors $WhatIfPreference automatically
Stop-Service -Name "wuauserv" -ErrorAction SilentlyContinue

# External executable: MUST be guarded explicitly
if ($PSCmdlet.ShouldProcess("CcmExec", "Set start type to delayed-auto")) {
    & sc.exe config CcmExec start= delayed-auto | Out-Null
}
```

---

## 7. Check-Then-Apply Pattern

**This is the preferred structure for all remediation scripts.**

Rather than relying on inventory or sensor data that may be stale, incomplete, or unavailable, the script determines actual current state on the device and remediates only what is genuinely wrong. This makes a script:

- **Safe to run repeatedly** — a healthy device is a no-op
- **Independent of external data** — no reliance on a sensor having run first
- **Composable** — related remediations combine into one deployment
- **Self-reporting** — the check result has value even when nothing is remediated

### Step Schema

Only these fields are supported. Do not invent others.

```powershell
$Steps = @(
    @{
        Name             = 'Descriptive Check Name'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            # MUST return exactly one of:
            #   @{ Status = 'Passed';  Message = '...' }   -> no action
            #   @{ Status = 'Warning'; Message = '...' }   -> action only if ResolveOnWarning
            #   @{ Status = 'Failed';  Message = '...' }   -> action
        }
        ResolutionScript = {
            # Runs only when detection warrants it.
            # $null for detection-only / reporting-only steps.
        }
    }
)
```

### Engine Contract

```powershell
$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($step in ($Steps | Where-Object { $_.Enabled } | Sort-Object { [int]$_.Order })) {
    # Detection runs in try/catch; a thrown detection is a step failure,
    # not a script failure.
    $shouldRemediate = ($status -eq 'Failed') -or ($status -eq 'Warning' -and $step.ResolveOnWarning)
}
```

### Rules

| Rule | Detail |
|---|---|
| Detection never mutates | A detection script MUST be safe to run on any device at any time. |
| Resolution is idempotent | Running it twice MUST NOT make things worse. |
| Detection-only is valid | Set `ResolutionScript = $null` for anything informational or owned by another team. |
| Combine related checks | One deployment covering 8 related checks beats 8 deployments. |
| Split by blast radius, not topic | Low-impact checks belong together; high-impact remediations get their own script. |
| Report, do not assume | `Remediated = $true` means "the resolution ran", not "the problem is fixed". |

### Optional: Post-Remediation Verification

Re-running detection after remediation is the natural completion of check-then-apply, but it is **optional and not currently standard** — it cannot be mandated until the fleet-wide Intelligent Hub version floor moves. Treat it as opt-in.

```powershell
# Optional additional field. Default $null. Do not add it unless asked.
VerificationScript = $null
```

When present, it re-runs the detection logic after the resolution and reports `Verified` / `NotVerified` alongside `Remediated`. Do not add it to a step by default, and do not report a fix as confirmed without it.

### When NOT to Combine

Split a remediation into its own script when it:

- Restarts a **shared** subsystem (WMI, the networking stack, a service other products depend on)
- Cancels or removes work owned by **another product**
- Pulls significant content over the **WAN**
- Can leave the device in a **worse state** than the problem it fixes
- Requires an **admin decision** rather than an automatic one

---

## 8. High-Impact Actions and Admin Confirmation

A high-impact action MUST NOT run merely because a script was assigned. It requires explicit, deliberate admin confirmation.

### What Counts as High Impact

- Destructive or irreversible operations (repository resets, profile deletion, uninstalls)
- Restarting shared services other products depend on
- Terminating processes that may hold unsaved user data
- Anything that forces a reboot or drops an active user session
- Bulk content removal that triggers fleet-wide re-download

### Pattern

```powershell
# -- Admin confirmation gate ---------------------------------------------------
# High-impact action. FAILS CLOSED: absent or unparseable => do not proceed.
$ConfirmHighImpact = $false
if ($env:ConfirmHighImpact) {
    try   { $ConfirmHighImpact = [System.Convert]::ToBoolean($env:ConfirmHighImpact) }
    catch { $ConfirmHighImpact = $false }
}

if (-not $ConfirmHighImpact) {
    Write-Output "$HEAD SKIPPED: This script performs a high-impact action."
    Write-Output "$HEAD Set the ConfirmHighImpact variable to 'true' on the script object to enable it."
    Write-Output "$HEAD Detection results below are reported for review; no changes were made."
    # Still report what WOULD have been done - detection output has value on its own.
    exit 0
}
```

### Confirmation Gate vs. WhatIf

Both belong on a high-impact script. They solve different problems.

| | Default | Purpose |
|---|---|---|
| `$env:WhatIf` | `$false` (live) | Dry-run any script to preview changes |
| `$env:ConfirmHighImpact` | `$false` (blocked) | Prevent a dangerous script from running by accident |

**The fail directions are opposite by design.** WhatIf defaults to acting; the confirmation gate defaults to not acting.

### Exit Code on a Blocked Gate

Exit `0`, not `1`. The script did exactly what it was designed to do — correctly declined an unconfirmed action. Exiting `1` would flood the console with false failures.

---

## 9. Script Variables — Current UEM Limitations

**Avoid script variables unless absolutely necessary.**

### The Constraint

UEM supports variables **only on the script object itself** — not per assignment, not per deployment. Therefore:

- One script object = one set of values for the entire fleet
- You cannot assign the same script to two smart groups with different thresholds
- Changing a value affects every device the script is assigned to
- There is no per-ring or per-region override

A script written to "take a threshold as a variable" gives no real flexibility while adding a configuration surface that can be misconfigured.

### Guidance

| Situation | Approach |
|---|---|
| Thresholds, timeouts, tunables | Hard-code in a `# -- Tunables --` block at the top. Document them so an admin can fork the script object. |
| Different values per ring | Create a second script object. Explicit and auditable. |
| Behavior switches (`WhatIf`, `ConfirmHighImpact`) | Environment variable is appropriate — per-deployment intent, not per-device config. |
| Device/user lookup values | **Valid use case.** UEM populates these dynamically per device. |

### The Valid Use Case

Device and user lookup values are resolved by UEM at delivery time and are genuinely dynamic per device. This is the **only** category where a script variable provides something a hard-coded value cannot.

```powershell
param(
    [string]$DeviceSerial   = $env:DeviceSerialNumber,
    [string]$EnrollmentUser = $env:EnrollmentUser
)
```

### Pattern for Tunables

```powershell
# -- Tunables ------------------------------------------------------------------
# Hard-coded deliberately: UEM variables are per-script-object, not per-assignment,
# so exposing these would give no real deployment flexibility.
# Fork this script object if a ring needs different values.
$CacheUsedWarnPercent = 80
$StaleCacheDays       = 30
$MaxDeletePerRun      = 50
```

---

## 10. Sensor Authoring Rules

Sensors are lightweight, read-only scripts that return a **single value**. They run on the Windows Sample Schedule or on device events (login/logout), and are **serialized** — a blocking sensor delays every sensor behind it.

Per Omnissa documentation: *"Sensors data is not stored locally on Windows devices. A sensor runs PowerShell code that evaluates an attribute on a system and reports that data to Omnissa Intelligence. After it evaluates and reports, the PowerShell process terminates."*

### Output MUST Use Write-Output, Never Write-Host

This is the single most common sensor defect. From the Omnissa documentation:

> "The Write-Host string in a script directly writes to the screen, and **it does not report the sensor output to Omnissa Intelligence**. However, the string Write-Output does write to the pipeline, so use it instead of Write-Host. Update applicable scripts to Write-Output or echo (**echo is an alias for Write-Output**)."

```powershell
# NON-WORKING - documented by Omnissa as producing no sensor output
$os = Get-TimeZone
write-host $os
```

```powershell
# WORKING
$os = Get-TimeZone
write-output $os
```

`echo` is acceptable and is what the official samples use, because it is an alias for `Write-Output`. A bare expression also works, but `Write-Output` is explicit and preferred for generated code.

### Rules

1. A sensor MUST return **exactly one value**.
2. The value MUST be written with **`Write-Output` (or `echo`)**. MUST NOT use `Write-Host`.
3. The sensor MUST **`return` immediately after writing the value**, confirming execution completed.
4. The return type MUST match the declared **Response Data Type**: `String`, `Integer`, `Boolean`, or `Date Time`.
5. **Nothing else may be written to the output stream.** No progress messages, no logging, no debug output, no run headers.
6. The sensor MUST be wrapped in **`try/catch`** and use **`-ErrorAction SilentlyContinue`** on every read.
7. The sensor MUST emit a **type-valid value on the error path** — see the fallback table.
8. Sensors MUST complete in **under 5 seconds**. See [§3](#3-execution-time-budgets).
9. Sensors MUST NOT launch external processes, jobs, or threads.
10. Sensors MUST NOT write to disk or the registry — that is a script's job.
11. Sensors MUST NOT make network calls.
12. Sensors SHOULD read from a **cache written by a script** when data is expensive to compute.
13. Date Time sensors MUST emit **ISO format** — per the docs, *"any sensor that returns a date-time data type value uses the ISO format."* Use `Get-Date -Format s`.

### Fallback Values by Type

An erroring sensor must still produce something the declared type accepts, or UEM records a type mismatch rather than a clean unknown.

| Response Data Type | Fallback on error | Rationale |
|---|---|---|
| **String** | `""` (empty string) | Type-valid and unambiguous. Avoid `"Unknown"` — indistinguishable from a legitimate value. |
| **Integer** | `-1` | A sentinel no real measurement produces. |
| **Boolean** | *(none — bare `return`)* | Any boolean fallback is a lie. `$false` reads as a real negative finding. |
| **Date Time** | *(none — bare `return`)* | There is no safe sentinel date. |

For Boolean and Date Time, exit without writing a value. UEM records no sample for that interval, which is honest — better than a fabricated result.

### Template — String

```powershell
#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : my_sensor_name
    Data Type    : String
    Architecture : Any (x86/x64)
    Context      : System
    Author       : [Author Name]
    Last Modified: yyyy-MM-dd
    Timeout      : < 5 seconds
#>

try {
    $cached = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\MyCategory" `
                  -Name "MyValue" -ErrorAction SilentlyContinue

    if ($null -eq $cached -or [string]::IsNullOrEmpty($cached.MyValue)) {
        Write-Output ""
        return
    }

    Write-Output $cached.MyValue
    return
}
catch {
    Write-Output ""
    return
}
```

### Template — Integer

```powershell
try {
    $cached = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\MyCategory" `
                  -Name "MyCount" -ErrorAction SilentlyContinue

    if ($null -eq $cached) {
        Write-Output -1
        return
    }

    Write-Output ([int]$cached.MyCount)
    return
}
catch {
    Write-Output -1
    return
}
```

### Template — Boolean

```powershell
try {
    $svc = Get-Service -Name "CcmExec" -ErrorAction SilentlyContinue

    if ($null -eq $svc) {
        # No safe boolean fallback - return without a value.
        return
    }

    Write-Output ($svc.Status -eq 'Running')
    return
}
catch {
    return
}
```

### Template — Date Time

```powershell
try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\MyCategory" `
                -Name "LastRunTime" -ErrorAction SilentlyContinue

    if ($null -eq $prop -or [string]::IsNullOrEmpty($prop.LastRunTime)) {
        return
    }

    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse($prop.LastRunTime, [ref]$parsed)) {
        return
    }

    # ISO format is required for date-time sensors.
    Write-Output ($parsed.ToString('s'))
    return
}
catch {
    return
}
```

### When a Sensor Is Too Slow

If the data cannot be gathered in under 5 seconds, **split the work**:

1. A **script** performs the expensive collection on a schedule and caches the result to the registry
2. A **sensor** reads that cached value in milliseconds

This is mandatory for recurring sensors, which execute constantly across the fleet. See [§15](#15-caching-pattern-script-writes-sensor-reads).

### Event-Triggered Sensors

Sensors can be triggered by device events rather than only the sample schedule. Prefer this when the underlying data changes only in response to a discrete event — it removes constant polling and keeps the sensor queue clear.

Good candidates: service state changes, hardware/driver events, security log events, installation events.

### One-Time DEX Collection

There is a narrow case — a **one-time DEX data collection**, not a recurring sensor — where extending toward the 30-second UEM maximum is defensible.

Before doing so, confirm:

- The sensor genuinely runs **once**, not on a recurring schedule
- The collection cannot be restructured as script-writes / sensor-reads
- The admin accepts that the sensor queue is blocked for that duration
- 30 seconds is the **hard UEM maximum** — there is no higher value

If any of these are unclear, **ask the user for the execution context** before writing a sensor that exceeds 5 seconds.

---

## 11. Exit Codes

Scripts MUST use deliberate exit codes. Never let PowerShell exit with an ambiguous or default code.

| Exit Code | Meaning |
|---|---|
| `0` | Success (including "no action required" and "high-impact gate declined") |
| `1` | Failure / general error |
| `3010` | Success, reboot required (standard Windows) |
| `1641` | Success, reboot initiated |

### Every Path MUST Exit

Including the paths that are easy to overlook:

```powershell
# Guard clause
if (-not (Test-Path $required)) {
    Write-Output "$HEAD Prerequisite missing."
    exit 1
}

# Confirmation gate
if (-not $ConfirmHighImpact) {
    Write-Output "$HEAD Not confirmed; no action taken."
    exit 0
}

# Concurrency gate
if (-not $owned) {
    Write-Output "$HEAD Another instance is running."
    exit 0
}

# Nothing to do
if ($items.Count -eq 0) {
    Write-Output "$HEAD Nothing to process."
    exit 0
}

# Catch block
catch {
    Write-Error "$HEAD ERROR: $($_.Exception.Message)"
    exit 1
}

# Normal completion
exit 0
```

A script that falls off the end without an `exit` returns the exit code of the last command executed, which is effectively random.

> **Note:** Sensors do not use exit codes. Their result is the value written to the output stream.

---

## 12. Error Handling Patterns

### Basic try/catch with the run header

```powershell
try {
    $result = Get-ItemProperty -Path "HKLM:\Software\SomeKey" -ErrorAction Stop
}
catch {
    Write-Error "$HEAD Failed to read registry key: $($_.Exception.Message)"
    exit 1
}
```

### Suppress unintended pipeline output

```powershell
# New-Item writes the created object to the pipeline - suppress it
New-Item -Path "HKLM:\Software\AirWatch\Extensions\MyApp" -Force | Out-Null

# Same for other cmdlets that return objects you don't need
[void](Some-Cmdlet -Param "value")
```

### Time-boxed network probe

`WaitOne()` alone is not sufficient — it also returns `$true` when the connection completed *with a refusal*. `EndConnect()` throws in that case, which is what actually distinguishes reachable from refused.

```powershell
$reachable = $false
$tcp = New-Object System.Net.Sockets.TcpClient
try {
    $ar = $tcp.BeginConnect($targetHost, 443, $null, $null)
    if ($ar.AsyncWaitHandle.WaitOne(3000, $false)) {
        $tcp.EndConnect($ar)
        $reachable = $tcp.Connected
    }
}
catch { }
finally { $tcp.Close() }
```

### Non-blocking service start

`Start-Service` blocks until the service reaches Running or the SCM timeout (~30 s) elapses. On a broken device that alone can consume the entire script budget.

```powershell
& sc.exe start MyService | Out-Null   # returns at START_PENDING
```

### Parsing WMI/DMTF dates

`[datetime]` cannot cast a DMTF date such as `20260701120000.000000+000`. The cast fails silently inside a `try/catch`, leaving `$null` and quietly disabling any age-based logic that depends on it.

```powershell
$parsed = $null
if ($raw -match '^(\d{14})') {
    $parsed = [datetime]::ParseExact($matches[1], 'yyyyMMddHHmmss', $null)
}
# Treat an unparseable date as UNKNOWN and skip the item.
# Never let "unknown age" fall through into "old enough to delete".
```

### Enumerating a COM collection you intend to modify

Removing items from a live COM collection while enumerating it throws or silently skips entries. Snapshot first.

```powershell
$elements = @($cache.GetCacheElements())   # snapshot into an array
foreach ($e in $elements) { $cache.DeleteCacheElement($e.CacheElementId) }
```

---

## 13. Registry and File Storage Conventions

Use these paths consistently so that sensors and scripts can find each other's data reliably.

### Registry (preferred for SYSTEM context)

```
HKLM:\Software\AirWatch\Extensions\{ScriptCategoryOrName}\
```

Example values under this key:

| Value Name | Type | Example |
|---|---|---|
| `Status` | String | `"Installed"` |
| `LastRun` | String | `"2026-05-05T14:30:00"` |
| `Version` | String | `"1.4.2"` |
| `IsCompliant` | DWORD | `1` |

```powershell
# Writing to registry (script)
$regPath = "HKLM:\Software\AirWatch\Extensions\MyApp"
if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}
Set-ItemProperty -Path $regPath -Name "Status" -Value "Installed" -Type String
Set-ItemProperty -Path $regPath -Name "LastRun" -Value (Get-Date -Format "o") -Type String
```

### Files (when structured data is needed)

```
C:\ProgramData\AirWatch\Extensions\{ScriptCategoryOrName}\
```

> **AV exception required.** Scripts and payloads staged here are commonly quarantined by AV/EDR. Any deliverable writing here MUST document the exclusion requirement.

```powershell
# Writing a JSON cache file (script)
$dataPath = "C:\ProgramData\AirWatch\Extensions\MyApp"
if (-not (Test-Path $dataPath)) {
    New-Item -ItemType Directory -Path $dataPath -Force | Out-Null
}
$data = @{ Status = "Ready"; Version = "2.1.0"; Timestamp = (Get-Date -Format "o") }
$data | ConvertTo-Json | Set-Content -Path "$dataPath\state.json" -Encoding UTF8

# Reading the JSON cache (sensor)
try {
    $json = Get-Content -Path "C:\ProgramData\AirWatch\Extensions\MyApp\state.json" -Raw -ErrorAction Stop
    $data = $json | ConvertFrom-Json
    Write-Output $data.Status
    return
}
catch {
    Write-Output ""
    return
}
```

---

## 14. Logging Conventions

### Run-ID Header Pattern

Every script run gets a random 4-digit ID that prefixes every line it emits. When an admin reads interleaved output from multiple runs — or compares a console result against a device log — the ID makes it unambiguous which run produced which line.

```powershell
$SCRIPT_VERSION = "1.0.0"

$RunEventId = ([Random]::new()).Next(1000, 9999)
Write-Host "[$RunEventId] Executing script, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'"
$HEAD = "`r`n[$RunEventId]"

# Prefix EVERY subsequent output line with $HEAD
Write-Output  "$HEAD Service 'wuauserv' is already running."
Write-Warning "$HEAD Service not found on this system."
Write-Error   "$HEAD ERROR: $($_.Exception.Message)"
```

The leading `` `r`n `` in `$HEAD` forces each entry onto its own line regardless of how the host buffers output. Use `HH` (24-hour), not `hh`, so timestamps are unambiguous without an AM/PM designator.

### Rules

| Rule | Detail |
|---|---|
| **Run header** | First line of every script: run ID, script version, start timestamp, and WhatIf mode |
| **Prefix everything** | Every `Write-Output` / `Write-Host` / `Write-Warning` / `Write-Error` gets `$HEAD` |
| **Log path** | `$env:SystemRoot\Temp\UEM_<ScriptName>.log` when file logging is needed |
| **Format** | Timestamp + message, UTF-8 encoded |
| **Sensors** | **Never log.** The output stream carries the value and nothing else. |
| **Async payloads** | MUST log to file — nothing captures their stdout |
| **Log size** | Keep small; never log inside tight loops |
| **Rotation** | For repeated long-running scripts, trim or rotate |

```powershell
$LogPath = "$env:SystemRoot\Temp\UEM_MyScriptName.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] [$RunEventId] [$Level] $Message" | Out-File -FilePath $LogPath -Append -Encoding UTF8
}

Write-Log "Starting script."
Write-Log "An error occurred." -Level "ERROR"
```

---

## 15. Caching Pattern: Script Writes, Sensor Reads

This is the most important architectural pattern for keeping sensors fast. Never have a sensor do expensive work. Instead:

1. A **script** runs the expensive operation and stores the result
2. A **sensor** reads the cached result in milliseconds

```powershell
# === SCRIPT: Discover software and cache the result ===

$regPath = "HKLM:\Software\AirWatch\Extensions\SoftwareAudit"
if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}

try {
    # Expensive: enumerate installed software
    $installed = Get-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" `
        -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*Office*" }

    $status = if ($installed) { "Installed" } else { "NotFound" }
    Set-ItemProperty -Path $regPath -Name "OfficeStatus" -Value $status -Type String
    Set-ItemProperty -Path $regPath -Name "LastAudit" -Value (Get-Date -Format "o") -Type String

    exit 0
}
catch {
    Set-ItemProperty -Path $regPath -Name "OfficeStatus" -Value "Error" -Type String
    exit 1
}
```

```powershell
# === SENSOR: Read the cached result (fast, no expensive work) ===
# Response Data Type: String

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\SoftwareAudit" `
                -Name "OfficeStatus" -ErrorAction SilentlyContinue

    if ($null -eq $prop -or [string]::IsNullOrEmpty($prop.OfficeStatus)) {
        Write-Output ""
        return
    }

    Write-Output $prop.OfficeStatus
    return
}
catch {
    Write-Output ""
    return
}
```

---

## 16. On-Disk Script Pattern

Use this pattern when you want to write reusable logic to disk once via Freestyle, then call it repeatedly — without redeploying the script from Workspace ONE each time.

> **AV exception required** for `C:\ProgramData\AirWatch\Extensions`.

```powershell
# === Freestyle Delivery Script: Write logic to disk ===

$scriptDir  = "C:\ProgramData\AirWatch\Extensions\MyApp"
$scriptPath = "$scriptDir\Invoke-MyAppSetup.ps1"

if (-not (Test-Path $scriptDir)) {
    New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null
}

$scriptContent = @'
# Invoke-MyAppSetup.ps1
# Called on-demand; logic lives here, not in the delivery layer
param([string]$Mode = "Install")

$LogPath = "$env:SystemRoot\Temp\UEM_MyAppSetup.log"
function Write-Log { param($m) "$(Get-Date -Format 'o')  $m" | Out-File $LogPath -Append -Encoding UTF8 }

try {
    Write-Log "Running in mode: $Mode"
    # ... actual logic here ...
    Write-Log "Done."
    exit 0
}
catch {
    Write-Log "ERROR: $_"
    exit 1
}
'@

$scriptContent | Set-Content -Path $scriptPath -Encoding UTF8

# Call it immediately if needed
& powershell.exe -ExecutionPolicy Bypass -NonInteractive -File $scriptPath -Mode "Install"
exit $LASTEXITCODE
```

---

## 17. Scheduled Task Pattern

Use scheduled tasks when you need to run code outside the Hub/Freestyle execution thread — long-running work, UI prompts, toast notifications, user-context execution, or reboot dialogs.

> **Admin prerequisite:** an AV/EDR exclusion for `C:\ProgramData\AirWatch\Extensions\`. Without it the payload may be quarantined and the task will appear to succeed while doing nothing. Always state this in the deliverable.

```powershell
# === Script: Register and trigger a one-time scheduled task ===

$taskName   = "WS1_MyAppNotification"
$scriptPath = "C:\ProgramData\AirWatch\Extensions\MyApp\Show-Notification.ps1"

# Remove any previous instance
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

# Build the action
$action  = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$scriptPath`""

# Trigger: run once, immediately (30-second delay to let Hub finish)
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(30)

# Run as the logged-on user (interactive session)
$principal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Users" -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -DeleteExpiredTaskAfter (New-TimeSpan -Minutes 30)

Register-ScheduledTask -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Force | Out-Null

exit 0
```

> **Cleanup:** The task is configured to self-delete 30 minutes after expiration. For longer-lived tasks, add explicit cleanup logic in the called script.

### Task Settings Reference

| Setting | Purpose |
|---|---|
| `-ExecutionTimeLimit` | Hard cap. Always set it — the main advantage over process dispatch. |
| `-DeleteExpiredTaskAfter` | Self-cleanup so tasks do not accumulate. |
| `-StartWhenAvailable` | Runs after a missed window (device was off). |
| `-AllowStartIfOnBatteries` | Required for laptops; otherwise the task silently will not run. |
| `-Hidden` | Keeps the task out of the default Task Scheduler view. |

---

## 18. Measuring Disk Space

**MUST NOT use `Get-ChildItem` to calculate disk space.**

`Get-ChildItem -Recurse` constructs a full `FileInfo` object for every file, follows reparse points, and has unbounded runtime on large trees. On a user profile or content cache it can take minutes and consume significant memory — a guaranteed timeout in both scripts and sensors.

### Volume-Level Free/Used Space

```powershell
$disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
$freeGB  = [math]::Round($disk.FreeSpace / 1GB, 2)
$totalGB = [math]::Round($disk.Size / 1GB, 2)
$usedGB  = [math]::Round(($disk.Size - $disk.FreeSpace) / 1GB, 2)
```

```powershell
# Alternative when CIM is unavailable
$drive  = Get-PSDrive -Name C -ErrorAction SilentlyContinue
$freeGB = [math]::Round($drive.Free / 1GB, 2)
```

### Folder Size

Use the in-box `Scripting.FileSystemObject` COM object. It computes folder size natively without materializing PowerShell objects — typically an order of magnitude faster than `Get-ChildItem -Recurse`.

```powershell
$folderSizeMB = -1
$fso = $null
try {
    $fso    = New-Object -ComObject Scripting.FileSystemObject
    $folder = $fso.GetFolder($targetPath)
    $folderSizeMB = [math]::Round($folder.Size / 1MB, 2)
}
catch { }
finally {
    if ($fso) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($fso) }
}
```

For very large trees where even FSO is too slow, use `robocopy` in list-only mode. `/XJ` excludes junction points, without which the walk can loop or double-count.

```powershell
$out = & robocopy.exe $targetPath "$env:TEMP\null" /L /S /NJH /BYTES /FP /NC /NDL /NFL /TS /XJ 2>&1
```

### Comparison

| Method | Speed | Use for |
|---|---|---|
| `Win32_LogicalDisk` (CIM) | Fastest | Volume free/used/total — always prefer |
| `Get-PSDrive` | Fast | Volume free space when CIM is unavailable |
| `Scripting.FileSystemObject` | Fast | Folder / subtree size |
| `robocopy /L` | Moderate | Very large trees; also yields file counts |
| `[System.IO.Directory]::EnumerateFiles()` | Moderate | When per-file filtering is needed, not just a total |
| `Get-ChildItem -Recurse` | **Slowest** | **Never for sizing** |

---

## 19. Anti-Patterns to Avoid

The agent MUST NOT generate these patterns.

| Anti-Pattern | Why It's Harmful | Better Alternative |
|---|---|---|
| Third-party modules or packages | Not present on endpoints; fails fleet-wide | In-box cmdlets, .NET Framework, WMI/CIM, COM |
| `Write-Host` for sensor output | Writes to the screen, not the pipeline — Omnissa Intelligence receives nothing | `Write-Output` or `echo` |
| Logging or progress output in a sensor | Corrupts the single-value contract | Sensors emit the value and nothing else |
| Sensor with no value on the error path | Type mismatch instead of a clean unknown | `""` (String), `-1` (Integer), bare `return` (Boolean/Date Time) |
| Non-ISO date from a Date Time sensor | UEM cannot parse it | `Get-Date -Format s` |
| `Get-ChildItem -Recurse` for sizing | Unbounded runtime, high memory | `Win32_LogicalDisk`, FSO, or `robocopy /L` |
| Synchronous work over 60 seconds | Blocks every other action on the device | Dispatch via scheduled task or detached process |
| Sensor over 5 seconds | Blocks the entire sensor queue | Script writes cache, sensor reads it |
| Registry flag used as a concurrency lock | Survives a hard kill or bugcheck — permanent deadlock | `Global\` named mutex; registry for reporting only |
| Blind remediation without detection | Acts on healthy devices; not idempotent | Check-then-apply |
| High-impact action with no confirmation gate | Destructive action runs by accident | `$env:ConfirmHighImpact`, fails closed |
| State-changing script with no `-WhatIf` | No dry-run capability for admins | `[CmdletBinding(SupportsShouldProcess=$true)]` |
| WhatIf defaulting to `$true` | Silent no-op when the admin expected remediation | Default `$false`; only explicit "true" enables it |
| Script variables for thresholds | UEM variables are per-script-object, not per-assignment | Hard-code tunables; fork the script object per ring |
| Infinite loops or `while ($true)` | Blocks Hub/Freestyle indefinitely | Deadline-bounded loop in an async payload |
| Missing `exit` on any code path | Returns the last command's exit code — effectively random | Explicit `exit` in every branch and every `catch` |
| `Start-Service` in a time-boxed script | Blocks for the full ~30 s SCM timeout | `& sc.exe start <name>` returns at START_PENDING |
| `WaitOne()` alone for a TCP probe | Reports refused connections as reachable | Add `EndConnect()` and check `.Connected` |
| `UseShellExecute = $false` for detached work | Child inherits stdio handles; Hub keeps waiting | `UseShellExecute = $true` |
| `[datetime]` cast on a WMI/DMTF date | Does not cast; fails silently and disables age logic | `ParseExact` on the `yyyyMMddHHmmss` prefix |
| Treating an unparseable date as "old" | Over-deletes when age is actually unknown | Unknown age MUST skip, never delete |
| Deleting from a live COM collection while enumerating | Throws or silently skips items | Snapshot to an array first |
| Sensors that call external executables | Slow, unpredictable, can hang | Cache results from a script |
| Sensors that write to registry/disk | Side effects in a read-only role | Use a companion script to write |
| `Start-Sleep` without a deadline guard | Hangs if the condition never resolves | Deadline check inside the loop |
| `hh` in a timestamp format | 12-hour clock with no AM/PM — ambiguous | Use `HH` |
| Smart quotes or Unicode from copy-paste | Silent parse failures | Retype quotes; validate encoding |
| Staging to `ProgramData\AirWatch\Extensions` without documenting the AV exception | Payload quarantined; task "succeeds" doing nothing | State the exclusion requirement in the deliverable |
| PowerShell 7 syntax in a PS5 script | Incompatible syntax or module failures | Target PS5 unless explicitly confirmed |

---

## 20. Quick Reference Checklist

### For Scripts

- [ ] Targets Windows PowerShell 5.1 x64
- [ ] No third-party modules or packages
- [ ] Runs as SYSTEM (or specified context)
- [ ] Completes within 30 s (60 s absolute ceiling) or dispatches asynchronously
- [ ] `[CmdletBinding(SupportsShouldProcess=$true)]` with the `$env:WhatIf` bridge, defaulting to `$false`
- [ ] Every mutating action guarded by `ShouldProcess` — including external executables
- [ ] Follows check-then-apply; detection never mutates, resolution is idempotent
- [ ] High-impact actions gated behind `$env:ConfirmHighImpact`, failing closed
- [ ] Run-ID header emitted; `$HEAD` prefixed on every output line
- [ ] Explicit `exit` on every code path, including every `catch` and guard clause
- [ ] `try/catch` wrapping all significant logic
- [ ] Tunables hard-coded in a block at the top, not exposed as UEM variables
- [ ] No `Get-ChildItem` for disk space calculations
- [ ] No uncontrolled background jobs
- [ ] No user-interactive prompts (unless using the scheduled task pattern)
- [ ] `New-Item` and similar cmdlets piped to `| Out-Null`
- [ ] Caches expensive results to registry for sensor consumption
- [ ] AV exception documented if staging to `ProgramData\AirWatch\Extensions`

### Additionally, For Async Scripts

- [ ] Launcher gates on dispatch-mechanism state before dispatching
- [ ] Payload holds a `Global\` named mutex for its lifetime, released in `finally`
- [ ] `AbandonedMutexException` handled as "acquired, prior run died"
- [ ] Payload self-enforces a deadline
- [ ] Payload logs to file, never stdout
- [ ] Registry status stamped: `Dispatched` / `Running` / `Completed` / `TimedOut` / `Failed`
- [ ] Payload cleans up its own task and state files

### For Sensors

- [ ] Completes in under 5 seconds (30 s only for a confirmed one-time DEX collection)
- [ ] Emits the value with `Write-Output` or `echo` — **never `Write-Host`**
- [ ] `return`s immediately after writing the value
- [ ] Nothing else on the output stream — no logging, headers, or progress
- [ ] Type-valid fallback on error: `""` (String), `-1` (Integer), bare `return` (Boolean/Date Time)
- [ ] Date Time values emitted in ISO format via `Get-Date -Format s`
- [ ] Wrapped in `try/catch` with `-ErrorAction SilentlyContinue` on every read
- [ ] Returns exactly one value
- [ ] No external process calls or job launches
- [ ] No network calls
- [ ] No file system or registry writes
- [ ] No expensive I/O or deep enumeration
- [ ] Reads from a script-written cache when data is expensive
- [ ] Considered an event trigger instead of interval polling

---

*Runbook version: 2.0 — July 2026*
*Sources: Going Lightspeed Part 2: Scripts & Sensors; Omnissa Workspace ONE UEM "Collect Data with Sensors" product documentation; DEXSolutionScripts field practice.*
