<#
.SYNOPSIS
    Horizon Agent restart (Tier 2, opt-in) -- the standard first fix for a desktop the
    Connection Server reports as Agent Unreachable.

.DESCRIPTION
    Launcher/payload. The UEM-delivered copy persists itself to
    C:\ProgramData\AirWatch\Extensions\VDI\Horizon, registers a one-shot SYSTEM scheduled
    task (WS1_HorizonAgentRestart), starts it and exits within seconds. The payload stops
    the Blast service, stops the agent service, starts the agent, starts Blast, waits for
    both to reach Running, writes its result to
    HKLM:\Software\AirWatch\Extensions\VDI\Horizon\Agent\Restart and unregisters its task.

    GATES, each exiting 0 with a Status in the cache:
      SkippedNotInstalled     no Horizon Agent on this device
      SkippedCooldown         a restart ran inside the last $CooldownHours (24) hours
      SkippedActiveSessions   active sessions exist and ConfirmHighImpact is not true.
                              With no active session no confirmation is needed: an
                              unreachable desktop with nobody on it is the exact case
                              this script exists for.

    Runs on non-persistent clones: a clone the broker cannot reach is useless to the
    pool, and a restart that brings it back is pure relief (VDI/DESIGN.md 1.1).

    AV/EDR EXCLUSION REQUIRED for C:\ProgramData\AirWatch\Extensions\ -- without it the
    payload may be quarantined and the task "succeeds" doing nothing. See README.

.NOTES
    Script Name  : Invoke-AutoRemediateHorizonAgentRestart.ps1
    Version      : 1.0.1
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05 (1.0.1: session events read through the .NET EventLogReader; Get-WinEvent fails in every form under Hub's ARM64 PowerShell 7.2 engine)
    Timeout      : launcher under 10 seconds; payload self-limited to 5 minutes
    Built from   : VDI/Horizon/SPEC.md rev 1

    Environment variables:
      WhatIf = true              Dispatches; the payload logs what it would do and writes Result = WhatIf.
      ConfirmHighImpact = true   Allows the restart while sessions are active.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
#region --- Event log reader --------------------------------------------------------------------
# Get-WinEvent fails in every form under Hub's ARM64 PowerShell 7.2 engine ("Cannot marshal
# 'parameter #8'"), so events are read through System.Diagnostics.Eventing.Reader, which behaves
# the same on Windows PowerShell 5.1 and PowerShell 7. Get-WinEvent semantics are kept: newest
# first unless -Oldest, StartTime/EndTime are whole-second bounds, a failed read yields an empty
# result unless -ErrorStop. Each record carries a Message property (FormatDescription(), falling
# back to the raw property values when the provider ships no message metadata).
function Get-DexEvent {
    param(
        [Parameter(Mandatory = $true)][string]$LogName,
        [int[]]$Id,
        [string[]]$ProviderName,
        [int[]]$Level,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [string]$XPath,
        [int]$MaxEvents = 0,
        [switch]$Oldest,
        [switch]$ErrorStop
    )
    $sys = New-Object System.Collections.Generic.List[string]
    if ($Id)           { $sys.Add('(' + (@($Id | ForEach-Object { "EventID=$_" }) -join ' or ') + ')') }
    if ($ProviderName) { $sys.Add('(' + (@($ProviderName | ForEach-Object { "Provider[@Name='$_']" }) -join ' or ') + ')') }
    if ($Level)        { $sys.Add('(' + (@($Level | ForEach-Object { "Level=$_" }) -join ' or ') + ')') }
    $when = New-Object System.Collections.Generic.List[string]
    if ($PSBoundParameters.ContainsKey('StartTime')) {
        $t = $StartTime.ToUniversalTime(); $t = $t.AddTicks(-($t.Ticks % [TimeSpan]::TicksPerSecond))
        $when.Add("@SystemTime>='" + $t.ToString('o') + "'")
    }
    if ($PSBoundParameters.ContainsKey('EndTime')) {
        $t = $EndTime.ToUniversalTime()
        if ($t.Ticks % [TimeSpan]::TicksPerSecond) { $t = $t.AddTicks([TimeSpan]::TicksPerSecond - ($t.Ticks % [TimeSpan]::TicksPerSecond)) }
        $when.Add("@SystemTime<='" + $t.ToString('o') + "'")
    }
    if ($when.Count -gt 0) { $sys.Add('TimeCreated[' + ($when -join ' and ') + ']') }
    $query = if ($XPath) { $XPath } elseif ($sys.Count -gt 0) { '*[System[' + ($sys -join ' and ') + ']]' } else { '*' }
    $getMessage = {
        $m = $null
        try { $m = $this.FormatDescription() } catch { }
        if (-not $m) { $m = (@($this.Properties | ForEach-Object { "$($_.Value)" }) -join "`n") }
        $m
    }
    $out = New-Object System.Collections.Generic.List[object]
    $reader = $null
    try {
        $q = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery($LogName, [System.Diagnostics.Eventing.Reader.PathType]::LogName, $query)
        $q.ReverseDirection = -not $Oldest
        $reader = New-Object System.Diagnostics.Eventing.Reader.EventLogReader($q)
        while (($MaxEvents -le 0 -or $out.Count -lt $MaxEvents) -and ($null -ne ($record = $reader.ReadEvent()))) {
            $po = [System.Management.Automation.PSObject]::AsPSObject($record)
            $po.PSObject.Properties.Add((New-Object System.Management.Automation.PSScriptProperty('Message', $getMessage)))
            $out.Add($po)
        }
    } catch {
        if ($ErrorStop) { throw }
    } finally {
        if ($reader) { $reader.Dispose() }
    }
    return $out.ToArray()
}
function Get-DexEventLog {
    param([Parameter(Mandatory = $true)][string]$LogName)
    try { return New-Object System.Diagnostics.Eventing.Reader.EventLogConfiguration($LogName) } catch { return $null }
}
#endregion

# Captured at script scope: Hub feeds the script through stdin, so $PSCommandPath is empty
# and this string is the only copy of the full text that can be persisted for the task.
$script:SelfText = $MyInvocation.MyCommand.ScriptBlock.ToString()

function Invoke-AutoRemediateHorizonAgentRestart {
[CmdletBinding(SupportsShouldProcess = $true)]
param([switch]$RunAsPayload)

$SCRIPT_VERSION = '1.0.1'
$SCRIPT_VARIANT = ''
$RegPath    = 'HKLM:\Software\AirWatch\Extensions\VDI\Horizon\Agent\Restart'
$LogPath    = "$env:SystemRoot\Temp\UEM_AutoRemediateHorizonAgentRestart.log"
$TaskName   = 'WS1_HorizonAgentRestart'
$BaseDir    = 'C:\ProgramData\AirWatch\Extensions\VDI\Horizon'
$PayloadPs1 = Join-Path $BaseDir 'Invoke-AutoRemediateHorizonAgentRestart.ps1'

# -- Tunables --
$CooldownHours        = 24
$ServiceWaitSeconds   = 60
$SessionLookbackHours = 72
$MaxEventsScanned     = 2000

# -- KB resolution points (identical to the collector) --
$AgentRegistryRoots = @('HKLM:\SOFTWARE\Omnissa\Horizon\Agent', 'HKLM:\SOFTWARE\VMware, Inc.\VMware VDM\Agent')  # KB-HZN-01
$AgentServiceNames = @('wsnm'); $BlastServiceNames = @('VMBlast')                                                # KB-HZN-02
$AgentServiceDisplayPattern = '(?i)Horizon.*Agent|VMware View Agent'; $BlastServiceDisplayPattern = '(?i)Blast'
$AgentUninstallPattern = '(?i)^(Omnissa|VMware) Horizon.*Agent'                                                  # KB-HZN-14

$WhatIfPreference = $false
if ($env:WhatIf) { try { $WhatIfPreference = [System.Convert]::ToBoolean($env:WhatIf) } catch { $WhatIfPreference = $false } }
$ConfirmHighImpact = $false
if ($env:ConfirmHighImpact) { try { $ConfirmHighImpact = [System.Convert]::ToBoolean($env:ConfirmHighImpact) } catch { $ConfirmHighImpact = $false } }

$RunEventId = ([Random]::new()).Next(1000, 9999)
$mode = if ($RunAsPayload) { 'payload' } else { 'launcher' }
Write-Output "[$RunEventId] Executing Invoke-AutoRemediateHorizonAgentRestart ($mode), $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'  WhatIf=$WhatIfPreference"
$HEAD = "`r`n[$RunEventId]"

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$RunEventId] [$mode] [$Level] $Message" |
        Out-File -FilePath $LogPath -Append -Encoding UTF8 -WhatIf:$false -ErrorAction SilentlyContinue
}
function Set-Val {
    param([string]$Name, $Value, [string]$Type = 'String')
    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop -WhatIf:$false | Out-Null }
    Set-ItemProperty -Path $RegPath -Name $Name -Value $Value -Type $Type -ErrorAction Stop -WhatIf:$false
}
function Get-AgentServices {
    $all = @(Get-Service -ErrorAction SilentlyContinue); $a = $null; $b = $null
    foreach ($s in $all) { if ($AgentServiceNames -contains $s.Name) { $a = $s; break } }
    if (-not $a) { foreach ($s in $all) { if ($s.DisplayName -match $AgentServiceDisplayPattern -and $s.DisplayName -notmatch $BlastServiceDisplayPattern) { $a = $s; break } } }
    foreach ($s in $all) { if ($BlastServiceNames -contains $s.Name) { $b = $s; break } }
    if (-not $b) { foreach ($s in $all) { if ($s.DisplayName -match $BlastServiceDisplayPattern -and $s.DisplayName -match '(?i)Horizon|VMware|Omnissa') { $b = $s; break } } }
    return @{ Agent = $a; Blast = $b }
}
function Wait-ServiceStatus {
    param([string]$Name, [string]$Status, [int]$Seconds)
    $deadline = (Get-Date).AddSeconds($Seconds)
    do { $s = Get-Service -Name $Name -ErrorAction SilentlyContinue; if ($s -and [string]$s.Status -eq $Status) { return $true }; Start-Sleep -Seconds 2 } while ((Get-Date) -lt $deadline)
    return $false
}
function Get-ActiveSessionCount {
    try {
        $ev = @(Get-DexEvent -LogName 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational' -Id 21, 23, 24, 25 -StartTime (Get-Date).AddHours(-$SessionLookbackHours) -MaxEvents $MaxEventsScanned -ErrorStop)
    }
    catch { if ($_.Exception.Message -match 'No events were found') { return 0 }; return -1 }
    $decided = @{}; $active = 0
    foreach ($e in $ev) {
        $u = ([xml]$e.ToXml()).Event.UserData.EventXML; $sid = [int]$u.SessionID
        if ($sid -le 0 -or $decided.ContainsKey($sid)) { continue }
        $decided[$sid] = $true
        if ($e.Id -eq 21 -or $e.Id -eq 25) { $active++ }
    }
    return $active
}

# -- Gate 1: installed --
$agentRoot = $null
foreach ($r in $AgentRegistryRoots) { if (Test-Path -LiteralPath $r) { $agentRoot = $r; break } }
$svc = Get-AgentServices
$uninst = @(Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $AgentUninstallPattern })
if (-not $agentRoot -and -not $svc.Agent -and $uninst.Count -eq 0) {
    Write-Output "$HEAD No Horizon Agent present on this device. Nothing to process."
    try { Set-Val 'Status' 'SkippedNotInstalled'; Set-Val 'LastRunTime' (Get-Date -Format 'o') } catch { }
    Write-Log 'No Horizon Agent detected. Exiting.'
    exit 0
}
if (-not $svc.Agent) {
    Write-Output "$HEAD Horizon Agent service not found (tried $($AgentServiceNames -join ', ')) -- nothing to restart; the agent install is broken (ADMIN)."
    try { Set-Val 'Status' 'Failed'; Set-Val 'Result' 'AgentServiceMissing'; Set-Val 'LastRunTime' (Get-Date -Format 'o') } catch { }
    exit 1
}

# -- Gate 2: cooldown --
$prior = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
if ($prior -and $prior.LastRestartTime) {
    $t = [datetime]::MinValue
    if ([datetime]::TryParse([string]$prior.LastRestartTime, [ref]$t) -and $t -gt (Get-Date).AddHours(-$CooldownHours)) {
        Write-Output "$HEAD Last restart was at $($t.ToString('yyyy-MM-dd HH:mm:ss')), inside the $CooldownHours h cooldown. Skipping."
        try { Set-Val 'Status' 'SkippedCooldown'; Set-Val 'LastRunTime' (Get-Date -Format 'o') } catch { }
        exit 0
    }
}

# -- Gate 3: active sessions --
$active = Get-ActiveSessionCount
if ($active -gt 0 -and -not $ConfirmHighImpact) {
    Write-Output "$HEAD $active active session(s) on this host and ConfirmHighImpact is not set. A restart can interrupt session negotiation; set ConfirmHighImpact=true to proceed anyway. Skipping."
    try { Set-Val 'Status' 'SkippedActiveSessions'; Set-Val 'ActiveSessionsAtRun' ([string]$active); Set-Val 'LastRunTime' (Get-Date -Format 'o') } catch { }
    exit 0
}

if (-not $RunAsPayload) {
    # -- Launcher --
    try {
        $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($existing -and $existing.State -eq 'Running') { Write-Output "$HEAD Payload already running. Skipping dispatch."; exit 0 }
        if (-not (Test-Path $BaseDir)) { New-Item -ItemType Directory -Path $BaseDir -Force -ErrorAction Stop -WhatIf:$false | Out-Null }
        Set-Content -LiteralPath $PayloadPs1 -Value $script:SelfText -Encoding UTF8 -Force -ErrorAction Stop -WhatIf:$false
        $ver = if ($SCRIPT_VARIANT) { "$SCRIPT_VERSION+$SCRIPT_VARIANT" } else { $SCRIPT_VERSION }
        Set-Val 'ScriptVersion' $ver; Set-Val 'Status' 'Dispatched'; Set-Val 'LastDispatchTime' (Get-Date -Format 'o'); Set-Val 'ActiveSessionsAtRun' ([string]$active)
        if ($existing) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue }
        # Task Scheduler does not inherit this environment: forward whitelisted values only.
        $fwd = "`$env:RunAsPayload='true';"
        foreach ($n in @('WhatIf', 'ConfirmHighImpact')) {
            $v = ([string][Environment]::GetEnvironmentVariable($n)).Trim().ToLower()
            if ($v -match '^(true|false|1|0|yes|no)$') { $fwd += " `$env:$n='$v';" }
        }
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"$fwd & '$PayloadPs1'`""
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit '00:05:00' -StartWhenAvailable -AllowStartIfOnBatteries
        Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        Write-Output "$HEAD Dispatched '$TaskName'. Results will appear at: $RegPath"
        Write-Log "Dispatched task '$TaskName'."
        exit 0
    }
    catch {
        Write-Error "$HEAD Launcher failed: $($_.Exception.Message)"
        Write-Log "Launcher failed: $($_.Exception.Message)" -Level 'ERROR'
        try { Set-Val 'Status' 'Failed'; Set-Val 'Result' "LauncherFailed: $($_.Exception.Message)" } catch { }
        exit 1
    }
}

# -- Payload --
$mutex = $null
try {
    $mutex = New-Object System.Threading.Mutex($false, 'Global\WS1_HorizonAgentRestart')
    $owned = $false
    try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { Write-Log 'Another payload holds the mutex. Exiting.'; exit 0 }

    Set-Val 'Status' 'Running'; Set-Val 'LastRunTime' (Get-Date -Format 'o')
    $agent = $svc.Agent; $blast = $svc.Blast
    Write-Log "Restarting agent service $($agent.Name)$(if ($blast) { " and Blast service $($blast.Name)" }); active sessions $active"

    if ($WhatIfPreference) {
        Write-Log "WhatIf: would stop $(if ($blast) { $blast.Name + ', ' })$($agent.Name), then start them again."
        Set-Val 'Status' 'Completed'; Set-Val 'Result' 'WhatIf'
        exit 0
    }

    if ($blast -and $blast.Status -ne 'Stopped') { & sc.exe stop $blast.Name | Out-Null; [void](Wait-ServiceStatus -Name $blast.Name -Status 'Stopped' -Seconds $ServiceWaitSeconds) }
    if ($agent.Status -ne 'Stopped') { & sc.exe stop $agent.Name | Out-Null }
    if (-not (Wait-ServiceStatus -Name $agent.Name -Status 'Stopped' -Seconds $ServiceWaitSeconds)) { Write-Log "$($agent.Name) did not stop within $ServiceWaitSeconds s; forcing its process" -Level 'WARN'; $pid1 = (Get-CimInstance Win32_Service -Filter "Name='$($agent.Name)'" -ErrorAction SilentlyContinue).ProcessId; if ($pid1) { Stop-Process -Id $pid1 -Force -ErrorAction SilentlyContinue } }

    $cimA = Get-CimInstance Win32_Service -Filter "Name='$($agent.Name)'" -ErrorAction SilentlyContinue
    if ($cimA -and $cimA.StartMode -eq 'Disabled') { & sc.exe config $agent.Name start= auto | Out-Null }
    & sc.exe start $agent.Name | Out-Null
    $agentOk = Wait-ServiceStatus -Name $agent.Name -Status 'Running' -Seconds $ServiceWaitSeconds
    $blastOk = $true
    if ($blast) {
        $cimB = Get-CimInstance Win32_Service -Filter "Name='$($blast.Name)'" -ErrorAction SilentlyContinue
        if ($cimB -and $cimB.StartMode -eq 'Disabled') { & sc.exe config $blast.Name start= auto | Out-Null }
        & sc.exe start $blast.Name | Out-Null
        $blastOk = Wait-ServiceStatus -Name $blast.Name -Status 'Running' -Seconds $ServiceWaitSeconds
    }

    Set-Val 'AgentServiceRunningAfter' ([int]$agentOk) 'DWord'
    Set-Val 'BlastServiceRunningAfter' ([int]$blastOk) 'DWord'
    Set-Val 'LastRestartTime' (Get-Date -Format 'o')
    if ($agentOk -and $blastOk) {
        Set-Val 'Status' 'Completed'; Set-Val 'Result' 'Restarted'
        Write-Log 'Restart completed; both services Running.'
        exit 0
    }
    Set-Val 'Status' 'Failed'; Set-Val 'Result' "AgentRunning=$agentOk BlastRunning=$blastOk"
    Write-Log "Restart finished but a service is not Running (agent $agentOk, Blast $blastOk)" -Level 'ERROR'
    exit 1
}
catch {
    Write-Log "Payload failed: $($_.Exception.Message)" -Level 'ERROR'
    try { Set-Val 'Status' 'Failed'; Set-Val 'Result' "PayloadFailed: $($_.Exception.Message)" } catch { }
    exit 1
}
finally {
    if ($mutex) { try { $mutex.ReleaseMutex() } catch { }; $mutex.Dispose() }
    if ($RunAsPayload) { if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue } }
}
}

# Entry point. The payload is started by the task with $env:RunAsPayload set, because the
# Workspace ONE engine does not bind a script-scope param block.
$RunAsPayload = $false
if ($env:RunAsPayload) { try { $RunAsPayload = [System.Convert]::ToBoolean($env:RunAsPayload) } catch { $RunAsPayload = $false } }
Invoke-AutoRemediateHorizonAgentRestart -RunAsPayload:$RunAsPayload
