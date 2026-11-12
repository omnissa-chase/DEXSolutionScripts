<#
.SYNOPSIS
    Invoke-AutoRemediateHorizonClient_BreakTest -- break test for Invoke-AutoRemediateHorizonClient.ps1
    on a device with the Omnissa (or VMware) Horizon Client installed (SPEC 11.4).

.DESCRIPTION
    Injects a client-side fault, proves it landed, runs the remediation exactly as UEM does
    (child powershell.exe -File, variables through the environment) and checks both the
    repair and the restore. Needs a Horizon Client; no Connection Server is needed, the
    server breaks seed their own server name in the console user's client key.

    Breaks (SPEC 11.4), all ungated:
      UsbServiceDisabled          USB arbitration service stopped and Disabled -> step 1
                                  sets it Automatic and starts it
      ClientFirewallRuleDisabled  one Horizon Client firewall rule disabled -> step 2
                                  enables it (when the install shipped no rule, the harness
                                  creates one named "Omnissa Horizon Client (DEXTest)" and
                                  removes it afterwards)
      ServerUnresolvable          DefaultServer = hzn-dex-test.invalid in the console user's
                                  client key (any configured client key is moved aside and
                                  put back) -> step 3 reports "do not resolve", flushes the
                                  resolver and the name still does not resolve; exit 0
      ServerHostsPoisoned         a DNS-resolvable server name (a configured one, else
                                  www.omnissa.com seeded the same way) pointed at 127.0.0.2
                                  through the hosts file -> step 3 resolves (DNS only),
                                  step 4 reports "No Horizon server answers on TCP 443";
                                  the hosts line is left for Restore to remove

    Every block emits only its verdict on the output stream; notes go to the host stream.
    Result: C:\Temp\FixReport\Invoke-AutoRemediateHorizonClient\<TestId>.json.

.PARAMETER RemediationTest
    Run the script under test after each break and validate. Without it: break, verify, restore.
.PARAMETER Environment
    Physical (default): every break is restored in a finally block. Snapshot: nothing is restored.
.PARAMETER Seed
    Random seed for the draw (0 = new seed, printed and stored in the result).
.PARAMETER BreakName
    Pin the breaks (comma list or array) instead of drawing BreakCount of them.
.PARAMETER BreakCount
    How many breaks to draw (default 4, which is all of them).
.PARAMETER Restore
    Replay the Restore blocks from the saved state of an interrupted run, then exit.
.PARAMETER Force
    Required by Assert-DexTestHost together with the C:\Temp\FixReport\.dex-test-machine marker.

.EXAMPLE
    .\Invoke-AutoRemediateHorizonClient_BreakTest.ps1 -RemediationTest -Force
.EXAMPLE
    .\Invoke-AutoRemediateHorizonClient_BreakTest.ps1 -RemediationTest -Force -BreakName ServerHostsPoisoned

.NOTES
    Script Name  : Invoke-AutoRemediateHorizonClient_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated), signed in as the console user
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-12

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
    [switch]$IncludeRebootBreaks,
    [switch]$Restore,
    [switch]$Resume,
    [switch]$Force,
    [string[]]$ProductionDomainDenyList = @()
)

$ErrorActionPreference = 'Stop'

$ScriptUnderTest   = 'Invoke-AutoRemediateHorizonClient'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediateHorizonClient.ps1'
$CachePath         = 'HKLM:\Software\AirWatch\Extensions\VDI\Horizon\Client'
$RemediationKey    = "$CachePath\Remediation"
$VariableNames     = @('WhatIf')
$ServiceWaitSec    = 60
$TestRuleName      = 'Omnissa Horizon Client (DEXTest)'   # must MATCH the script's client rule pattern
$TestServerName    = 'hzn-dex-test.invalid'
$PoisonCandidates  = @('www.omnissa.com', 'www.microsoft.com')
$PoisonAddress     = '127.0.0.2'
$HostsPath         = "$env:SystemRoot\System32\drivers\etc\hosts"
$HostsTag          = '# DEXTest-HorizonClient'
$BackupSuffix      = '_DEXBackup'

# KB resolution points, identical to the script under test (SPEC section 3).
$ClientUninstallPattern      = '(?i)^(Omnissa|VMware) Horizon Client'
$ClientRegistryRoots         = @('SOFTWARE\Omnissa\Horizon\Client', 'SOFTWARE\VMware, Inc.\VMware VDM\Client')
$ClientPolicyRoots           = @('HKLM\SOFTWARE\Policies\Omnissa\Horizon\Client', 'HKLM\SOFTWARE\Policies\VMware, Inc.\VMware VDM\Client')
$ClientServerValueCandidates = @('Server', 'ServerURL', 'DefaultServer', 'RecentServers')
$ClientUsbServiceNames       = @('vmware-usbarbitrator')
$ClientUsbDisplayPattern     = '(?i)USB Arbitration'
$ClientFirewallRulePattern   = '(?i)Horizon Client|VMware Horizon|Omnissa Horizon'
$ClientExeCandidates         = @("$env:ProgramFiles\Omnissa\Omnissa Horizon Client\horizon-client.exe", "${env:ProgramFiles(x86)}\Omnissa\Omnissa Horizon Client\horizon-client.exe", "${env:ProgramFiles(x86)}\VMware\VMware Horizon View Client\vmware-view.exe")

$modulePath = Join-Path $PSScriptRoot '..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "DEXTestFramework.psm1 not found at $modulePath" }
Import-Module $modulePath -Force

# -- Helpers ------------------------------------------------------------------

function Write-DexNote {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Message = '')
    Write-Host "  [Info   ] $Name$(if ($Message) { ": $Message" })" -ForegroundColor Gray
}

function Get-UsbService {
    $all = @(Get-Service -ErrorAction SilentlyContinue)
    foreach ($s in $all) { if ($ClientUsbServiceNames -contains $s.Name) { return $s } }
    foreach ($s in $all) { if ($s.DisplayName -match $ClientUsbDisplayPattern) { return $s } }
    return $null
}

function Get-SvcState {
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

function Get-ClientRules {
    @(Get-NetFirewallRule -ErrorAction Stop | Where-Object { $_.DisplayName -match $ClientFirewallRulePattern -or $_.DisplayGroup -match $ClientFirewallRulePattern })
}

function Get-ClientExe { foreach ($p in $ClientExeCandidates) { if (Test-Path -LiteralPath $p) { return $p } }; return '' }

function Get-HostName { param([string]$Raw) if ($Raw -match '^(?:[a-z]+://)?([A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9-]{2,})') { return $matches[1].ToLower() }; return '' }

function Get-ConsoleUser {
    # The same answer the script under test derives: Win32_ComputerSystem.UserName and its SID.
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $name = if ($cs -and $cs.UserName) { [string]$cs.UserName } else { '' }
    if (-not $name) { throw 'No console user (Win32_ComputerSystem.UserName is empty); sign in on the console first' }
    $sid = ([Security.Principal.NTAccount]$name).Translate([Security.Principal.SecurityIdentifier]).Value
    if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid")) { throw "Hive of $name ($sid) is not loaded" }
    return @{ Name = $name; Sid = $sid }
}

function Get-ClientKeyPaths {
    # reg.exe paths of every client key the script under test reads for servers: policy roots, then the console user's roots.
    param([string]$Sid)
    $list = @()
    foreach ($k in $ClientPolicyRoots) { $list += $k }
    foreach ($rel in $ClientRegistryRoots) { $list += "HKU\$Sid\$rel" }
    return ,@($list)
}

function ConvertTo-PsRegPath { param([string]$RegExePath) return "Registry::$($RegExePath -replace '^HKU\\', 'HKEY_USERS\' -replace '^HKLM\\', 'HKEY_LOCAL_MACHINE\')" }

function Get-ConfiguredServers {
    # Mirror of the script's Add-ServersFromKey over the same keys.
    param([string]$Sid)
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($rp in (Get-ClientKeyPaths -Sid $Sid)) {
        $k = ConvertTo-PsRegPath $rp
        if (-not (Test-Path -LiteralPath $k)) { continue }
        $p = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
        foreach ($vn in $ClientServerValueCandidates) {
            if ($null -eq $p.$vn) { continue }
            foreach ($piece in ((([string[]]$p.$vn) -join ' ') -split '[;,\s]+')) { $h = Get-HostName $piece; if ($h -and -not $list.Contains($h)) { $list.Add($h) } }
        }
        foreach ($sub in @(Get-ChildItem -Path $k -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '(?i)server' })) {
            $h = Get-HostName $sub.PSChildName; if ($h -and -not $list.Contains($h)) { $list.Add($h) }
            $sp = Get-ItemProperty -Path $sub.PSPath -ErrorAction SilentlyContinue
            foreach ($prop in @($sp.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' -and $_.Value -is [string] })) { $h = Get-HostName ([string]$prop.Value); if ($h -and -not $list.Contains($h)) { $list.Add($h) } }
            foreach ($leaf in @(Get-ChildItem -Path $sub.PSPath -ErrorAction SilentlyContinue)) { $h = Get-HostName $leaf.PSChildName; if ($h -and -not $list.Contains($h)) { $list.Add($h) } }
        }
    }
    return ,@($list)
}

function Invoke-RegExe {
    param([string[]]$Arguments)
    $out = & reg.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "reg.exe $($Arguments -join ' ') returned $LASTEXITCODE : $out" }
}

function Move-KeyAside {
    # Copies the key to <key>_DEXBackup and deletes the original; returns the backup path (or '' when the key did not exist).
    param([string]$RegExePath)
    if (-not (Test-Path -LiteralPath (ConvertTo-PsRegPath $RegExePath))) { return '' }
    $backup = "$RegExePath$BackupSuffix"
    if (Test-Path -LiteralPath (ConvertTo-PsRegPath $backup)) { Invoke-RegExe @('delete', $backup, '/f') }
    Invoke-RegExe @('copy', $RegExePath, $backup, '/s', '/f')
    Invoke-RegExe @('delete', $RegExePath, '/f')
    return $backup
}

function Restore-KeyFromBackup {
    param([string]$RegExePath)
    $backup = "$RegExePath$BackupSuffix"
    if (Test-Path -LiteralPath (ConvertTo-PsRegPath $RegExePath)) { Invoke-RegExe @('delete', $RegExePath, '/f') }
    if (Test-Path -LiteralPath (ConvertTo-PsRegPath $backup)) {
        Invoke-RegExe @('copy', $backup, $RegExePath, '/s', '/f')
        Invoke-RegExe @('delete', $backup, '/f')
    }
}

function Set-SeededServer {
    # Moves every client key aside and writes one fresh user key holding only DefaultServer = $Name.
    param([string]$Sid, [string]$Name)
    $moved = @()
    foreach ($rp in (Get-ClientKeyPaths -Sid $Sid)) { $b = Move-KeyAside -RegExePath $rp; if ($b) { $moved += $rp } }
    $primary = "HKU\$Sid\$($ClientRegistryRoots[0])"
    Invoke-RegExe @('add', $primary, '/v', 'DefaultServer', '/t', 'REG_SZ', '/d', $Name, '/f')
    return @{ Primary = $primary; Moved = $moved }
}

function Undo-SeededServer {
    param($Seed)
    if (-not $Seed) { return }
    if ($Seed.Primary -and (Test-Path -LiteralPath (ConvertTo-PsRegPath $Seed.Primary))) { Invoke-RegExe @('delete', $Seed.Primary, '/f') }
    foreach ($rp in @($Seed.Moved)) { Restore-KeyFromBackup -RegExePath $rp }
}

function Resolve-A {
    param([string]$Name)
    try { return ,@(Resolve-DnsName -Name $Name -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } | ForEach-Object { [string]$_.IPAddress }) } catch { return ,@() }
}

function Get-OsAddresses {
    # What the script's TcpClient will connect to: the OS resolver, hosts file included.
    param([string]$Name)
    try { return ,@([Net.Dns]::GetHostAddresses($Name) | ForEach-Object { $_.IPAddressToString }) } catch { return ,@() }
}

function Add-HostsLine {
    param([string]$Name)
    $line = "$PoisonAddress $Name $HostsTag"
    $text = [IO.File]::ReadAllText($HostsPath)
    if (-not $text.EndsWith("`n")) { $text += "`r`n" }
    [IO.File]::WriteAllText($HostsPath, $text + $line + "`r`n")
    & ipconfig.exe /flushdns | Out-Null
}

function Remove-HostsLines {
    $lines = @([IO.File]::ReadAllLines($HostsPath) | Where-Object { $_ -notmatch [regex]::Escape($HostsTag) })
    [IO.File]::WriteAllLines($HostsPath, $lines)
    & ipconfig.exe /flushdns | Out-Null
}

function Test-TcpPort {
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs = 2000)
    $tcp = New-Object System.Net.Sockets.TcpClient
    try { $ar = $tcp.BeginConnect($TargetHost, $Port, $null, $null); if ($ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { $tcp.EndConnect($ar); return [bool]$tcp.Connected }; return $false }
    catch { return $false } finally { $tcp.Close() }
}

function Get-RemediationCache {
    $p = Get-ItemProperty -Path $RemediationKey -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    $n = 0; try { $n = [int]$p.RemediationsRun } catch { }
    return @{ RemediationsRun = $n; Status = [string]$p.Status; LastRun = [string]$p.LastRun }
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
        Name            = 'UsbServiceDisabled'
        ExpectedOutcome = 'ExpectFixed'
        Variables       = @{}
        Capture         = { $s = Get-UsbService; if (-not $s) { throw 'No USB arbitration service found (the client was installed without USB redirection)' }; Get-SvcState -Name $s.Name }
        Methods         = @(@{ Name = 'StopAndDisable'; Apply = {
            param($Original)
            Stop-SvcHard -Name $Original.Name
            Set-SvcStartMode -Name $Original.Name -Mode 'Disabled'
        } })
        Verify   = {
            param($Original)
            $s = Get-SvcState -Name $Original.Name
            Write-DexNote -Name 'Verify UsbServiceDisabled' -Message "$($Original.Name) $($s.State) / $($s.StartMode)"
            ($s.State -eq 'Stopped') -and ($s.StartMode -eq 'Disabled')
        }
        Validate = {
            param($Original)
            $running = Wait-SvcState -Name $Original.Name -State 'Running' -TimeoutSec $ServiceWaitSec
            $s = Get-SvcState -Name $Original.Name
            $line = Test-DexOutput -Pattern '\[Failed \] Horizon Client USB Service: .*-> Remediation ran' -Label 'Step 1 line'
            $cache = Test-DexCacheRemediated
            Write-DexNote -Name 'Validate UsbServiceDisabled' -Message "running=$running mode=$($s.StartMode) line=$line cache=$cache"
            $running -and ($s.StartMode -ne 'Disabled') -and $line -and $cache -and (Test-DexRunOk)
        }
        Restore  = { param($Original) Restore-Service -Original $Original }
    },

    @{
        Name            = 'ClientFirewallRuleDisabled'
        ExpectedOutcome = 'ExpectFixed'
        Variables       = @{}
        Capture         = {
            $rule = @(Get-ClientRules | Where-Object { [string]$_.Enabled -eq 'True' } | Sort-Object DisplayName | Select-Object -First 1)
            if ($rule.Count -gt 0) { return @{ Name = [string]$rule[0].Name; DisplayName = [string]$rule[0].DisplayName; Enabled = 'True'; Created = $false } }
            $exe = Get-ClientExe
            if (-not $exe) { throw 'No Horizon Client firewall rule and no client executable to create one for' }
            if (Get-NetFirewallRule -DisplayName $TestRuleName -ErrorAction SilentlyContinue) { Remove-NetFirewallRule -DisplayName $TestRuleName -ErrorAction SilentlyContinue }
            $r = New-NetFirewallRule -DisplayName $TestRuleName -Direction Inbound -Action Allow -Program $exe -Profile Any -Enabled True -ErrorAction Stop
            Write-DexNote -Name 'Capture ClientFirewallRuleDisabled' -Message "no client rule shipped; created '$TestRuleName' for $exe"
            @{ Name = [string]$r.Name; DisplayName = $TestRuleName; Enabled = 'True'; Created = $true }
        }
        Methods         = @(@{ Name = 'DisableOneRule'; Apply = { param($Original) Disable-NetFirewallRule -Name $Original.Name -ErrorAction Stop } })
        Verify   = {
            param($Original)
            $r = Get-NetFirewallRule -Name $Original.Name -ErrorAction Stop
            Write-DexNote -Name 'Verify ClientFirewallRuleDisabled' -Message "$($Original.DisplayName) Enabled=$($r.Enabled)"
            ([string]$r.Enabled -ne 'True')
        }
        Validate = {
            param($Original)
            $r = Get-NetFirewallRule -Name $Original.Name -ErrorAction Stop
            $line = Test-DexOutput -Pattern ('\[Failed \] Horizon Client Firewall Rules: \d+ Horizon Client firewall rule\(s\) disabled: .*' + [regex]::Escape($Original.DisplayName) + '.*-> Remediation ran') -Label 'Step 2 line'
            $cache = Test-DexCacheRemediated
            Write-DexNote -Name 'Validate ClientFirewallRuleDisabled' -Message "enabled=$($r.Enabled) line=$line cache=$cache"
            ([string]$r.Enabled -eq 'True') -and $line -and $cache -and (Test-DexRunOk)
        }
        Restore  = {
            param($Original)
            if ($Original.Created) { Remove-NetFirewallRule -Name $Original.Name -ErrorAction SilentlyContinue }
            elseif ($Original.Enabled -eq 'True') { Enable-NetFirewallRule -Name $Original.Name -ErrorAction Stop }
        }
    },

    @{
        Name            = 'ServerUnresolvable'
        ExpectedOutcome = 'ExpectReportedOnly'
        Variables       = @{}
        Capture         = {
            $u = Get-ConsoleUser
            if ((Resolve-A -Name $TestServerName).Count -gt 0) { throw "$TestServerName resolves on this network; the break cannot be made" }
            @{ Sid = $u.Sid; User = $u.Name; Before = @(Get-ConfiguredServers -Sid $u.Sid); Seed = $null }
        }
        Methods         = @(@{ Name = 'SeedUnresolvableServer'; Apply = {
            param($Original)
            $Original.Seed = Set-SeededServer -Sid $Original.Sid -Name $TestServerName
            & ipconfig.exe /flushdns | Out-Null
        } })
        Verify   = {
            param($Original)
            $now = @(Get-ConfiguredServers -Sid $Original.Sid)
            $resolves = (Resolve-A -Name $TestServerName).Count -gt 0
            Write-DexNote -Name 'Verify ServerUnresolvable' -Message "configured=[$($now -join ',')] (was [$($Original.Before -join ',')]) resolves=$resolves"
            ($now.Count -eq 1) -and ($now[0] -eq $TestServerName) -and (-not $resolves)
        }
        Validate = {
            param($Original)
            $line = Test-DexOutput -Pattern ('\[Failed \] Server DNS Resolution: Server name\(s\) do not resolve: .*' + [regex]::Escape($TestServerName) + '.*-> Remediation ran') -Label 'Step 3 line'
            $next = Test-DexOutput -Pattern '\[Passed \] Server Connectivity \(443\): Not testable' -Label 'Step 4 line'
            $still = (Resolve-A -Name $TestServerName).Count -eq 0
            $cache = Test-DexCacheRemediated
            Write-DexNote -Name 'Validate ServerUnresolvable' -Message "line=$line step4=$next stillUnresolvable=$still cache=$cache"
            $line -and $next -and $still -and $cache -and (Test-DexRunOk)
        }
        Restore  = { param($Original) Undo-SeededServer -Seed $Original.Seed }
    },

    @{
        Name            = 'ServerHostsPoisoned'
        ExpectedOutcome = 'ExpectReportedOnly'
        Variables       = @{}
        Capture         = {
            $u = Get-ConsoleUser
            $configured = @(Get-ConfiguredServers -Sid $u.Sid)
            $name = ''; $seeded = $false
            foreach ($c in $configured) { if ((Resolve-A -Name $c).Count -gt 0) { $name = $c; break } }
            if (-not $name) { foreach ($c in $PoisonCandidates) { if ((Resolve-A -Name $c).Count -gt 0) { $name = $c; $seeded = $true; break } } }
            if (-not $name) { throw "No DNS-resolvable server name available (configured: $($configured -join ', '); candidates: $($PoisonCandidates -join ', '))" }
            if (([IO.File]::ReadAllText($HostsPath)) -match [regex]::Escape($HostsTag)) { throw "A $HostsTag line is already in $HostsPath; remove it first" }
            @{ Sid = $u.Sid; Name = $name; Seeded = $seeded; Seed = $null; DnsAddresses = @(Resolve-A -Name $name) }
        }
        Methods         = @(@{ Name = 'HostsFileToLoopback'; Apply = {
            param($Original)
            if ($Original.Seeded) { $Original.Seed = Set-SeededServer -Sid $Original.Sid -Name $Original.Name }
            Add-HostsLine -Name $Original.Name
        } })
        Verify   = {
            param($Original)
            $os = @(Get-OsAddresses -Name $Original.Name)
            $dns = @(Resolve-A -Name $Original.Name)
            $open = Test-TcpPort -TargetHost $Original.Name -Port 443
            Write-DexNote -Name 'Verify ServerHostsPoisoned' -Message "$($Original.Name): os=[$($os -join ',')] dns=[$($dns -join ',')] port443Open=$open"
            ($os -contains $PoisonAddress) -and ($dns.Count -gt 0) -and (-not $open)
        }
        Validate = {
            param($Original)
            $dnsLine = Test-DexOutput -Pattern ('\[Passed \] Server DNS Resolution: Server name\(s\) resolve: .*' + [regex]::Escape($Original.Name)) -Label 'Step 3 line'
            $line = Test-DexOutput -Pattern ('\[Warning\] Server Connectivity \(443\): No Horizon server answers on TCP 443: .*' + [regex]::Escape($Original.Name)) -Label 'Step 4 line'
            $hosts = (([IO.File]::ReadAllText($HostsPath)) -match [regex]::Escape($HostsTag))
            Write-DexNote -Name 'Validate ServerHostsPoisoned' -Message "dnsLine=$dnsLine warningLine=$line hostsLineStillThere=$hosts"
            $dnsLine -and $line -and $hosts -and (Test-DexRunOk)
        }
        Restore  = {
            param($Original)
            Remove-HostsLines
            if ($Original.Seeded) { Undo-SeededServer -Seed $Original.Seed }
        }
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

Write-DexBanner -Title 'Invoke-AutoRemediateHorizonClient_BreakTest' -Detail "Environment: $Environment"

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
$uninst = @(Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match $ClientUninstallPattern })
if ($uninst.Count -eq 0) { throw 'No Horizon Client on this device; this harness needs the client installed (SPEC 11.4).' }
$consoleUser = Get-ConsoleUser
$usbSvc = Get-UsbService
Write-DexStep -Status 'Info' -Name 'Client' -Message "$($uninst[0].DisplayName) $($uninst[0].DisplayVersion); console user $($consoleUser.Name); USB service: $(if ($usbSvc) { "$($usbSvc.Name) $($usbSvc.Status)" } else { 'none' }); client rules: $((Get-ClientRules).Count)"

$state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Seed $Seed -Environment $Environment
$state.RemediationTest = [bool]$RemediationTest
Write-DexStep -Status 'Info' -Name 'Context' -Message "TestId $($state.TestId)  Seed $($state.Seed)"

$exitCode = 0; $restoreFailed = $false; $runs = @(); $validation = @(); $anyBreakFailed = $false

try {
    $candidates = if ($BreakName) {
        @($BreakCatalog | Where-Object { @($BreakName -split ',' | ForEach-Object { $_.Trim() }) -contains $_.Name })
    } else { @($BreakCatalog) }
    if ($candidates.Count -eq 0) { throw 'No break matched the requested selection.' }

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
            Save-DexTestState -State $state   # Apply may have filled in Seed; Restore mode needs it
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
