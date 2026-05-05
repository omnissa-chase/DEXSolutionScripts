# Agent Runbook: Omnissa Workspace ONE UEM — Scripts & Sensors

> **Purpose:** This runbook is intended for use by an AI coding agent operating inside the Omnissa Workspace ONE console. It provides grounded rules, patterns, and validated code examples for generating PowerShell scripts and sensors. When in doubt, prefer safety, compatibility, and explicitness over cleverness.

---

## Table of Contents

1. [Agent Behavior Guidelines](#1-agent-behavior-guidelines)
2. [Runtime Target](#2-runtime-target)
3. [Script Authoring Rules](#3-script-authoring-rules)
4. [Sensor Authoring Rules](#4-sensor-authoring-rules)
5. [Exit Codes](#5-exit-codes)
6. [Error Handling Patterns](#6-error-handling-patterns)
7. [Registry and File Storage Conventions](#7-registry-and-file-storage-conventions)
8. [Logging Conventions](#8-logging-conventions)
9. [Caching Pattern: Script Writes, Sensor Reads](#9-caching-pattern-script-writes-sensor-reads)
10. [On-Disk Script Pattern](#10-on-disk-script-pattern)
11. [Scheduled Task Pattern](#11-scheduled-task-pattern)
12. [Anti-Patterns to Avoid](#12-anti-patterns-to-avoid)
13. [Quick Reference Checklist](#13-quick-reference-checklist)

---

## 1. Agent Behavior Guidelines

These are the top-level instructions the agent must follow when generating any script or sensor for Workspace ONE UEM.

- **Always target Windows PowerShell 5 (x64)** unless the user explicitly requests PowerShell 7 and confirms their environment supports it.
- **Never assume the user context.** Scripts run as SYSTEM unless stated otherwise.
- **Do not generate scripts that run indefinitely.** Every script must have a predictable end state.
- **Always include error handling.** An unhandled exception that terminates a script unexpectedly can block Hub or Freestyle execution.
- **When asked to generate a sensor**, output only the logic needed to return a single typed value. Sensors are not general-purpose scripts.
- **Prefer registry storage for cached state** over files when scripts run as SYSTEM.
- **Do not use smart quotes, curly apostrophes, or non-ASCII characters** in generated code. These cause silent failures when scripts are pasted across platforms.
- **Ask clarifying questions** if the user's request is ambiguous about whether the target is a script or a sensor — the rules are meaningfully different.

---

## 2. Runtime Target

| Setting | Value |
|---|---|
| **Default shell** | Windows PowerShell 5.1 (`powershell.exe`) |
| **Architecture** | x64 |
| **Execution context** | SYSTEM (unless user specifies user context) |
| **PowerShell 7** | Only if explicitly requested AND environment confirmed |
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

---

## 3. Script Authoring Rules

Scripts in Workspace ONE UEM are delivered and executed by Workspace ONE Hub or Freestyle Orchestrator. They must be well-behaved guests in that execution pipeline.

### Rules

1. Scripts must **exit with an explicit exit code** (`exit 0`, `exit 1`, etc.)
2. Scripts must **not hang, loop indefinitely, or wait for user input**
3. Scripts must **handle all foreseeable errors** with `try/catch`
4. Scripts should **log to a known local path** (see [Logging Conventions](#8-logging-conventions))
5. Scripts should **not launch uncontrolled background jobs** that outlive the script
6. Scripts should **suppress output** from cmdlets that write to the pipeline unintentionally (use `| Out-Null` where needed)
7. Scripts should **cache expensive results** to the registry or disk for sensors to consume (see [Caching Pattern](#9-caching-pattern-script-writes-sensor-reads))

### Minimal Script Template

```powershell
#Requires -Version 5.1
<#
.SYNOPSIS
    Brief description of what this script does.
.NOTES
    Author:      [Author Name]
    Version:     1.0
    Target:      Windows PowerShell 5.1 x64, SYSTEM context
    WS1 Type:    Script (not sensor)
#>

$LogPath = "$env:SystemRoot\Temp\UEM_ScriptName.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp  $Message" | Out-File -FilePath $LogPath -Append -Encoding UTF8
}

try {
    Write-Log "Script started."

    # --- Main logic goes here ---

    Write-Log "Script completed successfully."
    exit 0
}
catch {
    Write-Log "ERROR: $_"
    exit 1
}
```

---

## 4. Sensor Authoring Rules

Sensors are lightweight, read-only scripts that return a **single value** to Workspace ONE. They run on a scheduled interval (or near-real-time in Hub 2602+) and are serialized — a blocking sensor delays all sensors behind it.

### Rules

1. A sensor **must return exactly one value** on the last line of output
2. The return type must match the sensor's declared type: `String`, `Integer`, `Boolean`, or `DateTime`
3. Sensors **must always have a fallback value** — never exit without outputting something
4. Sensors **must not launch external processes, jobs, or threads**
5. Sensors **must not perform expensive I/O** (large file scans, deep registry recursion, network calls)
6. Sensors **must not write to disk or the registry** — that is a script's job
7. Sensors **should read from a cache** written by a script when the data is expensive to compute

### Minimal Sensor Template

```powershell
#Requires -Version 5.1
<#
.SYNOPSIS
    Returns a single value describing device state.
.NOTES
    Target:      Windows PowerShell 5.1 x64, SYSTEM context
    WS1 Type:    Sensor
    Return Type: String  (change as appropriate: String | Integer | Boolean | DateTime)
#>

try {
    $value = "Unknown"  # Safe fallback — always set this first

    # --- Read logic here. Keep it fast and simple. ---
    # Example: read from registry cache written by a companion script
    $regPath = "HKLM:\Software\AirWatch\Extensions\MyCategory"
    if (Test-Path $regPath) {
        $cached = Get-ItemProperty -Path $regPath -Name "MyValue" -ErrorAction SilentlyContinue
        if ($null -ne $cached) {
            $value = $cached.MyValue
        }
    }

    # Output exactly one value — this is what Workspace ONE captures
    $value
}
catch {
    # Return the fallback on any error — never let the sensor exit without a value
    "Unknown"
}
```

---

## 5. Exit Codes

Scripts must use deliberate exit codes. Do not let PowerShell exit with an ambiguous or default code.

| Exit Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Failure / general error |
| `3010` | Success, reboot required (standard Windows) |
| `1641` | Success, reboot initiated |

```powershell
# Always end scripts with an explicit exit
exit 0   # success
exit 1   # failure
exit 3010  # success, reboot required
```

> **Note:** Sensors do not use exit codes. Their result is the value written to the output stream.

---

## 6. Error Handling Patterns

### Basic try/catch with logging

```powershell
try {
    # Risky operation
    $result = Get-ItemProperty -Path "HKLM:\Software\SomeKey" -ErrorAction Stop
}
catch {
    Write-Log "Failed to read registry key: $_"
    exit 1
}
```

### Defensive registry read (sensor-safe)

```powershell
$value = "NotFound"
$regPath = "HKLM:\Software\AirWatch\Extensions\MyApp"
if (Test-Path $regPath) {
    $prop = Get-ItemProperty -Path $regPath -Name "Status" -ErrorAction SilentlyContinue
    if ($null -ne $prop -and $prop.Status) {
        $value = $prop.Status
    }
}
$value  # sensor output
```

### Suppress unintended pipeline output

```powershell
# New-Item writes the created object to the pipeline — suppress it
New-Item -Path "HKLM:\Software\AirWatch\Extensions\MyApp" -Force | Out-Null

# Same for other cmdlets that return objects you don't need
[void](Some-Cmdlet -Param "value")
```

### Timeout guard for potentially blocking operations

```powershell
$job = Start-Job {
    # Work that might hang
    Start-Sleep -Seconds 30
    "done"
}
$completed = Wait-Job $job -Timeout 20
if ($null -eq $completed) {
    Stop-Job $job
    Remove-Job $job
    Write-Log "Operation timed out."
    exit 1
}
$result = Receive-Job $job
Remove-Job $job
```

---

## 7. Registry and File Storage Conventions

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
    $data.Status
}
catch {
    "Unknown"
}
```

---

## 8. Logging Conventions

| Rule | Detail |
|---|---|
| **Log path** | `$env:SystemRoot\Temp\UEM_<ScriptName>.log` |
| **Format** | Timestamp + message, UTF-8 encoded |
| **Sensors** | Do not log — stay silent |
| **Log size** | Keep small; do not log in tight loops |
| **Rotation** | For long-running repeated scripts, consider trimming or rotating the log |

```powershell
$LogPath = "$env:SystemRoot\Temp\UEM_MyScriptName.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] [$Level] $Message" | Out-File -FilePath $LogPath -Append -Encoding UTF8
}

Write-Log "Starting script."
Write-Log "An error occurred." -Level "ERROR"
```

---

## 9. Caching Pattern: Script Writes, Sensor Reads

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

try {
    $value = "Unknown"
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\SoftwareAudit" `
        -Name "OfficeStatus" -ErrorAction SilentlyContinue
    if ($null -ne $prop) {
        $value = $prop.OfficeStatus
    }
    $value
}
catch {
    "Unknown"
}
```

---

## 10. On-Disk Script Pattern

Use this pattern when you want to write reusable logic to disk once via Freestyle, then call it repeatedly — without redeploying the script from Workspace ONE each time.

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

## 11. Scheduled Task Pattern

Use scheduled tasks when you need to run code outside the Hub/Freestyle execution thread — for example, UI prompts, toast notifications, user-context execution, or reboot dialogs.

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

---

## 12. Anti-Patterns to Avoid

The agent must never generate these patterns for Workspace ONE UEM scripts or sensors.

| Anti-Pattern | Why It's Harmful | Better Alternative |
|---|---|---|
| Infinite loops or `while ($true)` | Blocks Hub/Freestyle indefinitely | Use a scheduled task for repeating work |
| Sensors that call external executables | Slow, unpredictable, can hang | Cache results from a script |
| Sensors that write to registry/disk | Side effects in a read-only role | Use a companion script to write |
| Scripts with no exit code | Workspace ONE interprets result inconsistently | Always `exit 0` or `exit 1` |
| `Start-Sleep` without a timeout guard | Script hangs if condition never resolves | Use `Wait-Job` with `-Timeout` |
| Recursive registry or file system scans in sensors | Too slow for sensor cadence | Pre-compute in a script, cache result |
| Smart quotes or Unicode from macOS copy-paste | Silent parse failures | Retype quotes or validate encoding |
| Using `Write-Host` for sensor output | Goes to information stream, not output stream | Use bare value or `Write-Output` |
| No `try/catch` around any registry/file read | Unhandled terminating error blocks sensor queue | Always wrap with `try/catch` |
| PowerShell 7 syntax in a PS5 script | Incompatible syntax or module failures | Target PS5 unless explicitly confirmed |

---

## 13. Quick Reference Checklist

Use this checklist before finalizing any generated script or sensor.

### For Scripts

- [ ] Targets Windows PowerShell 5.1 x64
- [ ] Runs as SYSTEM (or specified context)
- [ ] Has `try/catch` wrapping all significant logic
- [ ] Ends with explicit `exit 0` or `exit 1`
- [ ] Logs to `$env:SystemRoot\Temp\UEM_<Name>.log`
- [ ] No uncontrolled background jobs
- [ ] No user-interactive prompts (unless using scheduled task pattern)
- [ ] `New-Item` and similar cmdlets pipe to `| Out-Null`
- [ ] Caches expensive results to registry or disk for sensor consumption

### For Sensors

- [ ] Returns exactly one value on the output stream
- [ ] Has a fallback value set before any logic runs
- [ ] No external process calls or job launches
- [ ] No file system writes or registry writes
- [ ] No expensive I/O or deep enumeration
- [ ] Wrapped in `try/catch` with fallback value in the catch block
- [ ] No `Write-Host` — use bare value or `Write-Output`

---

*Runbook version: 1.0 — May 2026*
*Source: Going Lightspeed Part 2: Scripts & Sensors*
