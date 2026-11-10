<#
.SYNOPSIS
    Invoke-AutoRemediateHorizonAgent_BreakTest -- breaks the Horizon Agent on a session
    host in controlled, reversible ways, runs Invoke-AutoRemediateHorizonAgent.ps1, and
    validates that the right steps fixed or reported each break.

.DESCRIPTION
    Implements VDI/Horizon/SPEC.md section 11.3. Needs a host with the Horizon Agent
    installed and paired (the collector and the one-time sensor must already see the
    agent). Every break is its own cycle: capture -> apply -> verify -> run -> validate
    -> restore, so the next break starts from the restored baseline. Writes the uniform
    JSON result to C:\Temp\FixReport\Invoke-AutoRemediateHorizonAgent\ for
    Invoke-FixReportAnalysis.ps1.

    THIS SCRIPT STOPS THE HORIZON AGENT AND BLAST SERVICES, DISABLES A HORIZON FIREWALL
    RULE AND BLOCKS THE AGENT'S BROKER PORTS for about a minute each. Any Blast session
    on the host, including the one you may be running this from, will drop during the
    two service breaks and reconnect afterwards. Run it from the hypervisor console or
    an RDP session where possible. Run it only on a marked test host. See
    Assert-DexTestHost in DEXTestFramework.psm1.

    BREAKS (ExpectedOutcome: ExpectFixed = the run must repair it;
    ExpectReportedOnly = the run must report it and leave it alone)
      AgentServiceDisabled      agent service stopped and set Disabled -> step 1 sets it
                                Auto and starts it; "[Failed ] Horizon Agent Service:
                                ... -> Remediation ran"; exit 0
      BlastServiceStopped       Blast service stopped -> step 2 starts it
      FirewallRuleDisabled      one Horizon firewall rule disabled -> step 4 enables it
      BrokerPortBlocked         outbound block rule DEXTest-HorizonBrokerBlock for TCP
                                4001/4002 to every resolved broker -> step 6 reports
                                "Broker unreachable", exit 0, and the rule is still
                                there afterwards (the script must not touch rules it
                                did not match)
      StaleDisconnectedSession  (gated: -IncludeSessionBreaks) disconnects the harness's
                                own remote session with tsdiscon, runs the script with
                                HZN_TEST_DisconnectedStaleMinutes=0 -> step 7 reports
                                "disconnected session(s) older than 0 min"; nothing is
                                logged off. Reconnect to the host afterwards. Skipped on
                                a console session, which cannot be disconnected.

    Not covered (SPEC 11.3): NotPaired (needs unpairing), step 10 clone state (needs an
    instant clone), feature services (installation dependent).

    REBOOTS
    Nothing here needs a reboot and there is no resume plumbing.

.PARAMETER RemediationTest
    After a break is verified, run Invoke-AutoRemediateHorizonAgent.ps1 and validate.
    Without this the harness applies, verifies and restores each break.

.PARAMETER Environment
    Physical (default) restores after every break. Snapshot skips restore.

.PARAMETER Seed
    Replays an earlier run's break order. Recorded in the result.

.PARAMETER BreakName
    Force specific breaks (comma list or array) instead of a random selection.

.PARAMETER BreakCount
    How many breaks to run when selecting randomly. Default 4 (all ungated).

.PARAMETER IncludeSessionBreaks
    Allow StaleDisconnectedSession, which disconnects the session the harness runs in.

.PARAMETER Restore
    Undo an interrupted run's breaks from state.json and exit.

.PARAMETER Force
    Required acknowledgement that this machine's Horizon Agent will be broken.

.NOTES
    Script Name  : Invoke-AutoRemediateHorizonAgent_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-10
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediateHorizonAgent\
    Built from   : VDI/Horizon/SPEC.md rev 2, section 11.3

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

param(
    [switch]$RemediationTest,
    [ValidateSet('Snapshot', 'Physical')][string]$Environment = 'Physical',
    [int]$Seed = 0,
    [string[]]$BreakName,
    [int]$BreakCount = 4,
    [switch]$IncludeSessionBreaks,
    [switch]$IncludeRebootBreaks,
    [switch]$Restore,
    [switch]$Resume,
    [switch]$Force,
    [string[]]$ProductionDomainDenyList = @()
)

$ErrorActionPreference = 'Stop'

$ScriptUnderTest   = 'Invoke-AutoRemediateHorizonAgent'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediateHorizonAgent.ps1'
$CachePath         = 'HKLM:\Software\AirWatch\Extensions\VDI\Horizon\Agent'
$RemediationKey    = "$CachePath\Remediation"
$VariableNames     = @('HZN_TEST_DisconnectedStaleMinutes', 'WhatIf')
$BlockRuleName     = 'DEXTest-HorizonBrokerBlock'
$ServiceWaitSec    = 60

# KB resolution points, identical to the script under test (SPEC section 3).
$AgentServiceNames = @('wsnm'); $BlastServiceNames = @('VMBlast')
$AgentServiceDisplayPattern = '(?i)Horizon.*Agent|VMware View Agent'; $BlastServiceDisplayPattern = '(?i)Blast'
$AgentRegistryRoots = @('HKLM:\SOFTWARE\Omnissa\Horizon\Agent', 'HKLM:\SOFTWARE\VMware, Inc.\VMware VDM\Agent')
$BrokerValueCandidates = @('Broker', 'BrokerList', 'Brokers', 'ConnectionServer')
$BrokerPorts = @(4001, 4002)
$AgentFirewallRulePattern = '(?i)Horizon|Blast|PCoIP|VMware View|Omnissa'
$ViewClientBrokerVar = 'ViewClient_Broker_DNS_Name'

$modulePath = Join-Path $PSScriptRoot '..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "DEXTestFramework.psm1 not found at $modulePath" }
Import-Module $modulePath -Force

# -- Helpers ------------------------------------------------------------------

function Write-DexNote {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Message = '')
    Write-Host "  [Info   ] $Name$(if ($Message) { ": $Message" })" -ForegroundColor Gray
}

function Get-AgentService {
    $all = @(Get-Service -ErrorAction SilentlyContinue)
    foreach ($s in $all) { if ($AgentServiceNames -contains $s.Name) { return $s } }
    foreach ($s in $all) { if ($s.DisplayName -match $AgentServiceDisplayPattern -and $s.DisplayName -notmatch $BlastServiceDisplayPattern) { return $s } }
    return $null
}

function Get-BlastService {
    $all = @(Get-Service -ErrorAction SilentlyContinue)
    foreach ($s in $all) { if ($BlastServiceNames -contains $s.Name) { return $s } }
    foreach ($s in $all) { if ($s.DisplayName -match $BlastServiceDisplayPattern -and $s.DisplayName -match '(?i)Horizon|VMware|Omnissa') { return $s } }
    return $null
}

function Get-SvcState {
    # StartMode and State from Win32_Service, the same source the script under test reads.
    param([Parameter(Mandatory = $true)][string]$Name)
    $c = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    if (-not $c) { return $null }
    return @{ Name = $Name; StartMode = [string]$c.StartMode; State = [string]$c.State }
}

function Set-SvcStartMode {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Mode)
    $arg = switch -Regex ($Mode) { '^Auto' { 'auto' } '^Manual' { 'demand' } '^Disabled' { 'disabled' } default { 'auto' } }
    & sc.exe config $Name start= $arg | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "sc.exe config $Name start= $arg returned $LASTEXITCODE" }
}

function Wait-SvcState {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$State, [int]$TimeoutSec = 60)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        $s = Get-SvcState -Name $Name
        if ($s -and $s.State -eq $State) { return $true }
        Start-Sleep -Seconds 2
    } while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec)
    return $false
}

function Stop-SvcHard {
    param([Parameter(Mandatory = $true)][string]$Name)
    Stop-Service -Name $Name -Force -ErrorAction Stop
    if (-not (Wait-SvcState -Name $Name -State 'Stopped' -TimeoutSec $ServiceWaitSec)) { throw "$Name did not reach Stopped within $ServiceWaitSec s" }
}

function Restore-Service {
    param($Original)
    if (-not $Original) { return }
    Set-SvcStartMode -Name $Original.Name -Mode $Original.StartMode
    if ($Original.State -eq 'Running') {
        $now = Get-SvcState -Name $Original.Name
        if ($now.State -ne 'Running') { Start-Service -Name $Original.Name -ErrorAction Stop }
        if (-not (Wait-SvcState -Name $Original.Name -State 'Running' -TimeoutSec $ServiceWaitSec)) { throw "$($Original.Name) did not return to Running" }
    }
}

function Get-HorizonRules {
    @(Get-NetFirewallRule -ErrorAction Stop | Where-Object { $_.DisplayName -match $AgentFirewallRulePattern -or $_.DisplayGroup -match $AgentFirewallRulePattern })
}

function Get-HostName { param([string]$Raw) if ($Raw -match '^(?:[a-z]+://)?([^/:\s]+)') { return $matches[1].ToLower() }; return '' }

function Get-Brokers {
    # Same discovery as the script under test: registry candidates, then every loaded hive's ViewClient broker.
    $list = New-Object System.Collections.Generic.List[string]
    $root = $null
    foreach ($r in $AgentRegistryRoots) { if (Test-Path -LiteralPath $r) { $root = $r; break } }
    if ($root) {
        foreach ($k in @($root, (Join-Path $root 'Configuration'), (Join-Path (Split-Path $root -Parent) 'Node Manager'))) {
            if (-not (Test-Path -LiteralPath $k)) { continue }
            $p = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
            foreach ($vn in $BrokerValueCandidates) {
                if ($null -eq $p.$vn) { continue }
                foreach ($piece in ((([string[]]$p.$vn) -join ' ') -split '[;,\s]+')) { $h = Get-HostName $piece; if ($h -and -not $list.Contains($h)) { $list.Add($h) } }
            }
        }
    }
    foreach ($hive in @(Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-\d+-\d+-\d+-\d+$' })) {
        foreach ($ve in @(Get-ChildItem -Path "$($hive.PSPath)\Volatile Environment" -ErrorAction SilentlyContinue)) {
            $b = (Get-ItemProperty -Path $ve.PSPath -Name $ViewClientBrokerVar -ErrorAction SilentlyContinue).$ViewClientBrokerVar
            $h = Get-HostName ([string]$b); if ($h -and -not $list.Contains($h)) { $list.Add($h) }
        }
    }
    return ,@($list | Select-Object -First 3)
}

function Resolve-BrokerAddresses {
    param([string[]]$Brokers)
    $ips = New-Object System.Collections.Generic.List[string]
    foreach ($b in $Brokers) {
        try { foreach ($a in @(Resolve-DnsName -Name $b -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' })) { if (-not $ips.Contains([string]$a.IPAddress)) { $ips.Add([string]$a.IPAddress) } } } catch { }
    }
    return ,@($ips)
}

function Test-TcpPort {
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs = 2000)
    $tcp = New-Object System.Net.Sockets.TcpClient
    try { $ar = $tcp.BeginConnect($TargetHost, $Port, $null, $null); if ($ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { $tcp.EndConnect($ar); return [bool]$tcp.Connected }; return $false }
    catch { return $false } finally { $tcp.Close() }
}

function Get-DisconnectedSessions {
    # 'query session' rows whose state is Disc; the harness's own id is excluded by the caller when needed.
    $rows = @(& query.exe session 2>$null | Select-Object -Skip 1)
    $out = @()
    foreach ($r in $rows) {
        if ($r -match '^\s*>?(\S*)\s+(\S*)\s+(\d+)\s+(Disc|Active|Conn|Listen)') { if ($matches[4] -eq 'Disc') { $out += @{ Id = [int]$matches[3]; User = $matches[2] } } }
    }
    return ,@($out)
}

function Get-RemediationCache {
    $p = Get-ItemProperty -Path $RemediationKey -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    $n = 0; try { $n = [int]$p.RemediationsRun } catch { }
    return @{ RemediationsRun = $n; Steps = [string]$p.Steps; Status = [string]$p.Status; LastRun = [string]$p.LastRun }
}

function Test-DexRunOk {
    param([int]$ExpectedExit = 0)
    $r = $script:currentRun
    if (-not $r) { return $false }
    $ok = ([int]$r.ExitCode -eq $ExpectedExit)
    if (-not $ok) { Write-DexNote -Name 'Run' -Message "exit $($r.ExitCode), expected $ExpectedExit" }
    return $ok
}

function Test-DexOutput {
    param([Parameter(Mandatory = $true)][string]$Pattern, [string]$Label = 'Output')
    $r = $script:currentRun
    if (-not $r) { return $false }
    $ok = ([string]$r.Output -match $Pattern)
    if (-not $ok) { Write-DexNote -Name $Label -Message "no line matched /$Pattern/" }
    return $ok
}

function Test-DexCacheRemediated {
    $c = Get-RemediationCache
    if (-not $c) { Write-DexNote -Name 'Cache' -Message 'no Remediation key written'; return $false }
    $fresh = $false
    try { $fresh = ([datetime]::Parse($c.LastRun) -gt $script:currentRun.StartedAt.AddSeconds(-5)) } catch { }
    if (-not $fresh) { Write-DexNote -Name 'Cache' -Message "LastRun '$($c.LastRun)' is older than this run" }
    if ($c.RemediationsRun -lt 1) { Write-DexNote -Name 'Cache' -Message "RemediationsRun $($c.RemediationsRun)" }
    return ($fresh -and $c.RemediationsRun -ge 1)
}

# -- Break catalog ------------------------------------------------------------
# Capture returns what Restore needs; Apply breaks; Verify proves the break landed;
# Validate reads the end state after the run. Every block returns only its verdict on
# the output stream (the harness casts with [bool]); notes go to the host stream.
$BreakCatalog = @(

    @{
        Name            = 'AgentServiceDisabled'
        ExpectedOutcome = 'ExpectFixed'
        Gated           = $false
        Variables       = @{}
        Capture         = { $s = Get-AgentService; if (-not $s) { throw 'No Horizon Agent service found' }; Get-SvcState -Name $s.Name }
        Methods         = @(@{ Name = 'StopAndDisable'; Apply = {
            param($Original)
            Stop-SvcHard -Name $Original.Name
            Set-SvcStartMode -Name $Original.Name -Mode 'Disabled'
        } })
        Verify   = {
            param($Original)
            $s = Get-SvcState -Name $Original.Name
            Write-DexNote -Name 'Verify AgentServiceDisabled' -Message "$($Original.Name) $($s.State) / $($s.StartMode)"
            ($s.State -eq 'Stopped') -and ($s.StartMode -eq 'Disabled')
        }
        Validate = {
            param($Original)
            $running = Wait-SvcState -Name $Original.Name -State 'Running' -TimeoutSec $ServiceWaitSec
            $s = Get-SvcState -Name $Original.Name
            $line = Test-DexOutput -Pattern '\[Failed \] Horizon Agent Service: .*-> Remediation ran' -Label 'Step 1 line'
            $cache = Test-DexCacheRemediated
            Write-DexNote -Name 'Validate AgentServiceDisabled' -Message "running=$running mode=$($s.StartMode) line=$line cache=$cache"
            $running -and ($s.StartMode -ne 'Disabled') -and $line -and $cache -and (Test-DexRunOk)
        }
        Restore  = { param($Original) Restore-Service -Original $Original }
    },

    @{
        Name            = 'BlastServiceStopped'
        ExpectedOutcome = 'ExpectFixed'
        Gated           = $false
        Variables       = @{}
        Capture         = { $s = Get-BlastService; if (-not $s) { throw 'No Horizon Blast service found' }; Get-SvcState -Name $s.Name }
        Methods         = @(@{ Name = 'Stop'; Apply = { param($Original) Stop-SvcHard -Name $Original.Name } })
        Verify   = {
            param($Original)
            $s = Get-SvcState -Name $Original.Name
            Write-DexNote -Name 'Verify BlastServiceStopped' -Message "$($Original.Name) $($s.State)"
            ($s.State -eq 'Stopped')
        }
        Validate = {
            param($Original)
            $running = Wait-SvcState -Name $Original.Name -State 'Running' -TimeoutSec $ServiceWaitSec
            $line = Test-DexOutput -Pattern '\[Failed \] Horizon Blast Service: .*-> Remediation ran' -Label 'Step 2 line'
            $cache = Test-DexCacheRemediated
            Write-DexNote -Name 'Validate BlastServiceStopped' -Message "running=$running line=$line cache=$cache"
            $running -and $line -and $cache -and (Test-DexRunOk)
        }
        Restore  = { param($Original) Restore-Service -Original $Original }
    },

    @{
        Name            = 'FirewallRuleDisabled'
        ExpectedOutcome = 'ExpectFixed'
        Gated           = $false
        Variables       = @{}
        Capture         = {
            $rule = @(Get-HorizonRules | Where-Object { [string]$_.Enabled -eq 'True' } | Sort-Object DisplayName | Select-Object -First 1)
            if ($rule.Count -eq 0) { throw 'No enabled Horizon firewall rule found to disable' }
            @{ Name = [string]$rule[0].Name; DisplayName = [string]$rule[0].DisplayName; Enabled = 'True' }
        }
        Methods         = @(@{ Name = 'DisableOneRule'; Apply = { param($Original) Disable-NetFirewallRule -Name $Original.Name -ErrorAction Stop } })
        Verify   = {
            param($Original)
            $r = Get-NetFirewallRule -Name $Original.Name -ErrorAction Stop
            Write-DexNote -Name 'Verify FirewallRuleDisabled' -Message "$($Original.DisplayName) Enabled=$($r.Enabled)"
            ([string]$r.Enabled -ne 'True')
        }
        Validate = {
            param($Original)
            $r = Get-NetFirewallRule -Name $Original.Name -ErrorAction Stop
            $line = Test-DexOutput -Pattern ('\[Failed \] Horizon Firewall Rules: \d+ Horizon firewall rule\(s\) disabled: .*' + [regex]::Escape($Original.DisplayName) + '.*-> Remediation ran') -Label 'Step 4 line'
            $cache = Test-DexCacheRemediated
            Write-DexNote -Name 'Validate FirewallRuleDisabled' -Message "enabled=$($r.Enabled) line=$line cache=$cache"
            ([string]$r.Enabled -eq 'True') -and $line -and $cache -and (Test-DexRunOk)
        }
        Restore  = { param($Original) if ($Original.Enabled -eq 'True') { Enable-NetFirewallRule -Name $Original.Name -ErrorAction Stop } }
    },

    @{
        Name            = 'BrokerPortBlocked'
        ExpectedOutcome = 'ExpectReportedOnly'
        Gated           = $false
        Variables       = @{}
        Capture         = {
            $brokers = Get-Brokers
            if ($brokers.Count -eq 0) { throw 'No broker known on this host (registry candidates and ViewClient variables empty)' }
            $ips = Resolve-BrokerAddresses -Brokers $brokers
            if ($ips.Count -eq 0) { throw "Broker name(s) do not resolve: $($brokers -join ', ')" }
            @{ Brokers = $brokers; Addresses = $ips; RuleExisted = [bool](Get-NetFirewallRule -DisplayName $BlockRuleName -ErrorAction SilentlyContinue) }
        }
        Methods         = @(@{ Name = 'OutboundBlockRule'; Apply = {
            param($Original)
            if (Get-NetFirewallRule -DisplayName $BlockRuleName -ErrorAction SilentlyContinue) { Remove-NetFirewallRule -DisplayName $BlockRuleName -ErrorAction SilentlyContinue }
            New-NetFirewallRule -DisplayName $BlockRuleName -Direction Outbound -Action Block -Protocol TCP -RemotePort @($BrokerPorts) -RemoteAddress @($Original.Addresses) -Profile Any -Enabled True -ErrorAction Stop | Out-Null
            Start-Sleep -Seconds 2
        } })
        Verify   = {
            param($Original)
            $open = $false
            foreach ($b in @($Original.Brokers)) { foreach ($p in $BrokerPorts) { if (Test-TcpPort -TargetHost $b -Port $p) { $open = $true } } }
            $resolves = (Resolve-BrokerAddresses -Brokers @($Original.Brokers)).Count -gt 0
            Write-DexNote -Name 'Verify BrokerPortBlocked' -Message "brokers=$($Original.Brokers -join ',') ips=$($Original.Addresses -join ',') anyPortOpen=$open dnsResolves=$resolves"
            (-not $open) -and $resolves
        }
        Validate = {
            param($Original)
            $rule = [bool](Get-NetFirewallRule -DisplayName $BlockRuleName -ErrorAction SilentlyContinue)
            $dns  = Test-DexOutput -Pattern '\[Passed \] Broker DNS Resolution: Broker name\(s\) resolve' -Label 'Step 5 line'
            $line = Test-DexOutput -Pattern '\[Warning\] Broker Connectivity: Broker unreachable on TCP 4001/4002' -Label 'Step 6 line'
            Write-DexNote -Name 'Validate BrokerPortBlocked' -Message "ruleStillPresent=$rule dnsLine=$dns warningLine=$line"
            $rule -and $dns -and $line -and (Test-DexRunOk)
        }
        Restore  = { param($Original) if (-not $Original.RuleExisted) { Remove-NetFirewallRule -DisplayName $BlockRuleName -ErrorAction SilentlyContinue } }
    },

    @{
        Name            = 'StaleDisconnectedSession'
        ExpectedOutcome = 'ExpectReportedOnly'
        Gated           = $true
        Variables       = @{ HZN_TEST_DisconnectedStaleMinutes = '0' }
        Capture         = {
            $own = (Get-Process -Id $PID).SessionId
            $name = [string]$env:SESSIONNAME
            if ($name -match '^(?i)console$') { throw 'The harness runs on the console session, which tsdiscon cannot disconnect; run this break from an RDP or Blast session' }
            @{ OwnSessionId = $own; SessionName = $name; Existing = @(Get-DisconnectedSessions | ForEach-Object { $_.Id }) }
        }
        Methods         = @(@{ Name = 'DisconnectOwnSession'; Apply = {
            param($Original)
            if ((Get-DisconnectedSessions).Count -gt 0) { Write-DexNote -Name 'Apply StaleDisconnectedSession' -Message 'a disconnected session already exists; using it'; return }
            & tsdiscon.exe $Original.OwnSessionId | Out-Null
            Start-Sleep -Seconds 5
        } })
        Verify   = {
            param($Original)
            $d = Get-DisconnectedSessions
            Write-DexNote -Name 'Verify StaleDisconnectedSession' -Message "disconnected sessions: $(($d | ForEach-Object { "$($_.User)#$($_.Id)" }) -join ', ')"
            ($d.Count -gt 0)
        }
        Validate = {
            param($Original)
            $line = Test-DexOutput -Pattern '\[Warning\] Disconnected Sessions: \d+ disconnected session\(s\) older than 0 min' -Label 'Step 7 line'
            $still = (Get-DisconnectedSessions).Count -gt 0
            Write-DexNote -Name 'Validate StaleDisconnectedSession' -Message "warningLine=$line sessionStillThere=$still"
            $line -and $still -and (Test-DexRunOk)
        }
        Restore  = { param($Original) Write-DexNote -Name 'Restore StaleDisconnectedSession' -Message 'nothing to undo; reconnect to the host to resume the session' }
    }
)

function Invoke-ScriptUnderTest {
    param([hashtable]$Variables)
    foreach ($n in $VariableNames) {
        [Environment]::SetEnvironmentVariable($n, $(if ($Variables.ContainsKey($n)) { $Variables[$n] } else { $null }), 'Process')
    }
    $started = Get-Date
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RemediationScript 2>&1 | ForEach-Object { [string]$_ })
        $rc = $LASTEXITCODE
        $ErrorActionPreference = $prev
        $sw.Stop()
    } finally {
        foreach ($n in $VariableNames) { [Environment]::SetEnvironmentVariable($n, $null, 'Process') }
    }
    return @{
        Variables   = $Variables
        ExitCode    = $rc
        DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Output      = (($output -join "`n")).Trim()
        StartedAt   = $started
    }
}

# ==============================================================================
# Main
# ==============================================================================

Assert-DexTestHost -Force:$Force -ProductionDomainDenyList $ProductionDomainDenyList

Write-DexBanner -Title 'Invoke-AutoRemediateHorizonAgent_BreakTest' -Detail "Environment: $Environment"

if ($Resume) { throw 'This harness has no reboot resume; nothing here reboots.' }

function Get-BreakDefinition { param([string]$Name) $BreakCatalog | Where-Object { $_.Name -eq $Name } | Select-Object -First 1 }

# -- Restore-only mode ---------------------------------------------------------
if ($Restore) {
    $state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Resume
    $toRestore = @($state.Breaks); [array]::Reverse($toRestore)
    foreach ($b in $toRestore) {
        $def = Get-BreakDefinition -Name $b.Name
        try {
            & $def.Restore ([PSCustomObject]$b.OriginalState)
            Write-DexStep -Status 'Passed' -Name "Restore $($b.Name)"
        } catch {
            Write-DexStep -Status 'Failed' -Name "Restore $($b.Name)" -Message $_.Exception.Message
        }
    }
    $state.Phase = 'Restored'; $state.Overall = 'Restored'
    Write-DexTestResult -State $state | Out-Null
    Clear-DexTestState -State $state
    exit 0
}

# -- Pre-flight ------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $RemediationScript)) { throw "Script under test not found at $RemediationScript" }
$agentSvc = Get-AgentService
if (-not $agentSvc) { throw 'No Horizon Agent service on this host; this harness needs a Horizon session host (SPEC 11.3).' }
$blastSvc = Get-BlastService
Write-DexStep -Status 'Info' -Name 'Agent' -Message "$($agentSvc.Name) ($($agentSvc.DisplayName)) $($agentSvc.Status); Blast: $(if ($blastSvc) { "$($blastSvc.Name) $($blastSvc.Status)" } else { 'none' })"

$state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Seed $Seed -Environment $Environment
$state.RemediationTest = [bool]$RemediationTest
Write-DexStep -Status 'Info' -Name 'Context' -Message "TestId $($state.TestId)  Seed $($state.Seed)"

$exitCode = 0; $restoreFailed = $false; $runs = @(); $validation = @(); $anyBreakFailed = $false

try {
    $pool = @($BreakCatalog | Where-Object { -not $_.Gated -or $IncludeSessionBreaks })
    $candidates = if ($BreakName) {
        @($BreakCatalog | Where-Object { @($BreakName -split ',' | ForEach-Object { $_.Trim() }) -contains $_.Name })
    } else { $pool }
    if ($candidates.Count -eq 0) { throw 'No break matched the requested selection.' }
    foreach ($c in $candidates) { if ($c.Gated -and -not $IncludeSessionBreaks) { throw "$($c.Name) disconnects the session the harness runs in; pass -IncludeSessionBreaks to allow it." } }

    $selected = if ($BreakName) { $candidates } else { Get-DexRandomSubset -InputObject $candidates -Random $state.Random -Count $BreakCount }

    foreach ($def in $selected) {
        $method = (Get-DexRandomSubset -InputObject $def.Methods -Random $state.Random -Count 1)[0]
        $original = $null
        try { $original = & $def.Capture } catch {
            $anyBreakFailed = $true
            Write-DexStep -Status 'Failed' -Name "Capture $($def.Name)" -Message $_.Exception.Message
            $validation += @{ Name = $def.Name; Expected = 'break applied'; Actual = "not applicable: $($_.Exception.Message)"; Result = 'Fail' }
            continue
        }

        $b = @{
            Name = $def.Name; Method = $method.Name; ExpectedOutcome = $def.ExpectedOutcome; RequiresReboot = $false
            Applied = $false; BreakVerified = $false; Variables = $def.Variables; OriginalState = $original
        }
        $state.Breaks = @($state.Breaks) + @($b)
        Save-DexTestState -State $state

        try {
            & $method.Apply $original
            $b.Applied = $true
            Write-DexStep -Status 'Info' -Name "Break $($def.Name)" -Message "'$($method.Name)' applied"

            $b.BreakVerified = [bool](& $def.Verify $original)
            if ($b.BreakVerified) {
                Write-DexStep -Status 'Passed' -Name "Verify $($def.Name)" -Message 'break is in place'
            } else {
                $anyBreakFailed = $true
                Write-DexStep -Status 'Failed' -Name "Verify $($def.Name)" -Message 'break did not land; the run would prove nothing'
                $validation += @{ Name = $def.Name; Expected = 'break in place'; Actual = 'NOT as expected'; Result = 'Fail' }
                continue
            }

            if (-not $RemediationTest) { continue }

            $vars = ($def.Variables.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
            Write-DexStep -Status 'Info' -Name "Run $($def.Name)" -Message $(if ($vars) { $vars } else { 'no variables' })
            $script:currentRun = Invoke-ScriptUnderTest -Variables $def.Variables
            $script:currentRun.Scenario = $def.Name
            $runs += $script:currentRun
            Write-DexStep -Status 'Info' -Name "Run $($def.Name)" -Message "exit $($script:currentRun.ExitCode) in $($script:currentRun.DurationSec) s"

            $passed = [bool](& $def.Validate $original)
            $expected = if ($def.ExpectedOutcome -eq 'ExpectFixed') { 'component repaired by the script' } else { 'component detected and reported, left unmodified' }
            $validation += @{ Name = $def.Name; Expected = $expected; Actual = $(if ($passed) { 'as expected' } else { 'NOT as expected' }); Result = $(if ($passed) { 'Pass' } else { 'Fail' }) }
            Write-DexStep -Status $(if ($passed) { 'Passed' } else { 'Failed' }) -Name "Validate $($def.Name)" -Message $expected
        } finally {
            if ($Environment -eq 'Physical') {
                try {
                    & $def.Restore $original
                    Write-DexStep -Status 'Passed' -Name "Restore $($def.Name)"
                } catch {
                    $restoreFailed = $true
                    Write-DexStep -Status 'Failed' -Name "Restore $($def.Name)" -Message $_.Exception.Message
                }
            }
            $script:currentRun = $null
            $state.Validation = $validation
            Save-DexTestState -State $state
        }
    }

    $state.Phase = if ($RemediationTest) { 'Validated' } else { 'BreakVerified' }
    if ($runs.Count -gt 0) {
        $state.Remediation = @{
            ExitCode    = ($runs | ForEach-Object { [int]$_.ExitCode } | Measure-Object -Maximum).Maximum
            DurationSec = [math]::Round((($runs | ForEach-Object { $_.DurationSec }) | Measure-Object -Sum).Sum, 1)
            Output      = (($runs | ForEach-Object { "== $($_.Scenario) (exit $($_.ExitCode))`n$($_.Output)" }) -join "`n`n")
            Runs        = @($runs | ForEach-Object { @{ Scenario = $_.Scenario; ExitCode = $_.ExitCode; DurationSec = $_.DurationSec; Variables = $_.Variables } })
        }
    }

    $failedCount = @($validation | Where-Object { $_.Result -eq 'Fail' }).Count
    $state.Overall = if (-not $RemediationTest) { 'BreakOnly' }
                     elseif ($anyBreakFailed) { 'BreakFailed' }
                     elseif ($failedCount -eq 0) { 'Passed' }
                     elseif ($state.Remediation -and [int]$state.Remediation.ExitCode -eq 0) { 'FalsePass' }
                     else { 'Failed' }
} catch {
    Write-DexStep -Status 'Failed' -Name 'Harness' -Message $_.Exception.Message
    $state.HarnessError = "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    if ($state.Overall -eq 'Incomplete') { $state.Overall = 'Failed' }
    $exitCode = 1
}

if ($Environment -eq 'Physical') {
    if ($restoreFailed) {
        $state.Overall = 'Dirty'
        Write-DexStep -Status 'Failed' -Name 'Restore' -Message 'machine left modified -- run with -Restore or repair by hand'
    } else {
        $state.Phase = 'Restored'
        Write-DexStep -Status 'Passed' -Name 'Restore' -Message 'machine returned to baseline'
    }
}

Write-Output ''
Write-DexStep -Status $(switch ($state.Overall) { 'Passed' { 'Passed' } 'BreakOnly' { 'Info' } default { 'Failed' } }) -Name 'Overall' -Message $state.Overall

Write-DexTestResult -State $state | Out-Null
Clear-DexTestState -State $state

exit $exitCode
