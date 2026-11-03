<#
.SYNOPSIS
    Horizon Agent remediation (session host side) -- fixes what the desktop owns,
    reports the rest.

.DESCRIPTION
    Ten check-then-apply steps against the Horizon Agent on a virtual desktop or
    session host. Pairs with Invoke-HorizonAgentStateCollection.ps1: that script
    measures and scores, this one corrects. Every detection measures live; only step 10
    reads the collector cache.

      1  Horizon Agent Service      AUTO   sc.exe config/start
      2  Horizon Blast Service      AUTO   sc.exe config/start
      3  Horizon Feature Services   AUTO   sc.exe start (never changes start type)
      4  Horizon Firewall Rules     AUTO   Enable-NetFirewallRule
      5  Broker DNS Resolution      AUTO   flush and re-register DNS
      6  Broker Connectivity        report Connection Server / UAG / firewall path
      7  Disconnected Sessions      opt-in report by default; ResolveOnWarning = $true logs off
      8  Blast Session Quality      report network path; correlate with the client device
      9  Agent Errors               report
     10  Pairing and Clone State    report image fault vs session drift (SPEC 5.3)

    RELIEF ON NON-PERSISTENT HOSTS. Every step runs on an instant clone exactly as on a
    full clone. The fix reverts at the next refresh, and the summary says so
    (ReliefOnly = 1 in the cache). That is deliberate: an image fix takes a day or two to
    reach production, and a scheduled run of this script keeps the pool usable until it
    does. See VDI/DESIGN.md 1.1.

    Report-only steps return Warning, never Failed, so the exit code means "an automatic
    fix could not be applied" and nothing else (SPEC 8.4). Message templates are exact;
    the break test matches on them. Contract: VDI/Horizon/SPEC.md rev 1, section 8.1.

    Results are written to HKLM:\Software\AirWatch\Extensions\VDI\Horizon\Agent\Remediation.
    The collector's own values are left untouched.

.NOTES
    Script Name  : Invoke-AutoRemediateHorizonAgent.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Timeout      : 30 seconds (deploy with a 60 second UEM timeout)
    Built from   : VDI/Horizon/SPEC.md rev 1

    Environment variables:
      WhatIf = true    Dry run. Absent/unparseable => live run.
      HZN_TEST_DisconnectedStaleMinutes   Test override, honoured only on a marked
                                          break-test host (C:\Temp\FixReport\.dex-test-machine).

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
function Invoke-AutoRemediateHorizonAgent {
[CmdletBinding(SupportsShouldProcess = $true)]
param()

$SCRIPT_VERSION = '1.0.0'
$SCRIPT_VARIANT = ''
$CachePath = 'HKLM:\Software\AirWatch\Extensions\VDI\Horizon\Agent'
$RegPath   = "$CachePath\Remediation"
$LogPath   = "$env:SystemRoot\Temp\UEM_AutoRemediateHorizonAgent.log"

# -- Tunables --
$DisconnectedStaleMinutes = 480
$BlastRttWarnMs           = 250
$BlastLossWarnPpm         = 20000
$AgentErrorWarnCount      = 10
$NetTimeoutMs             = 2000
$MaxProbeHosts            = 3
$EventLookbackHours       = 24
$SessionLookbackHours     = 72
$MaxEventsScanned         = 2000
if ($env:HZN_TEST_DisconnectedStaleMinutes -and (Test-Path -LiteralPath 'C:\Temp\FixReport\.dex-test-machine')) {
    try { $DisconnectedStaleMinutes = [int]$env:HZN_TEST_DisconnectedStaleMinutes } catch { }
}

# -- KB resolution points (VDI/Horizon/SPEC.md section 3); identical to the collector --
$AgentRegistryRoots = @('HKLM:\SOFTWARE\Omnissa\Horizon\Agent', 'HKLM:\SOFTWARE\VMware, Inc.\VMware VDM\Agent')  # KB-HZN-01
$AgentServiceNames = @('wsnm'); $BlastServiceNames = @('VMBlast')                                                # KB-HZN-02
$AgentServiceDisplayPattern = '(?i)Horizon.*Agent|VMware View Agent'; $BlastServiceDisplayPattern = '(?i)Blast'
$FeatureServiceInclude = '(?i)Horizon|Blast|ThinPrint|TP AutoConnect|USB Arbitration|View Agent|Omnissa'        # KB-HZN-03
$FeatureServiceExclude = '(?i)VMware Tools|Assist|App Volumes|Workspace ONE|Intelligent Hub|VGAuth|vm3d|VMwareCAF'
$BrokerValueCandidates = @('Broker', 'BrokerList', 'Brokers', 'ConnectionServer')                                # KB-HZN-04
$BrokerPorts = @(4001, 4002)                                                                                     # KB-HZN-05
$BlastSessionCounterSets = @('VMware Blast Session Counters', 'Omnissa Blast Session Counters')                  # KB-HZN-06
$BlastCounterNames = @{ Rtt = 'RTT'; Loss = 'Packet Loss (Uplink)' }
$AgentFirewallRulePattern = '(?i)Horizon|Blast|PCoIP|VMware View|Omnissa'                                        # KB-HZN-07
$AgentEventProviderPattern = '(?i)Horizon|VMware View|VMware Blast|Omnissa'                                      # KB-HZN-11
$ViewClientBrokerVar = 'ViewClient_Broker_DNS_Name'                                                              # KB-HZN-13
$AgentUninstallPattern = '(?i)^(Omnissa|VMware) Horizon.*Agent'                                                  # KB-HZN-14

# -- WhatIf bridge: UEM cannot set $WhatIfPreference; absent/unparseable => live run --
$WhatIfPreference = $false
if ($env:WhatIf) { try { $WhatIfPreference = [System.Convert]::ToBoolean($env:WhatIf) } catch { $WhatIfPreference = $false } }

$RunEventId = ([Random]::new()).Next(1000, 9999)
Write-Output "[$RunEventId] Executing Invoke-AutoRemediateHorizonAgent, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'  WhatIf=$WhatIfPreference"
$HEAD = "`r`n[$RunEventId]"

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$RunEventId] [$Level] $Message" |
        Out-File -FilePath $LogPath -Append -Encoding UTF8 -WhatIf:$false -ErrorAction SilentlyContinue
}
function Res { param([string]$S, [string]$M) return @{ Status = $S; Message = $M } }

function Test-TcpPort {
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs)
    $tcp = New-Object System.Net.Sockets.TcpClient
    try { $ar = $tcp.BeginConnect($TargetHost, $Port, $null, $null); if ($ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { $tcp.EndConnect($ar); return [bool]$tcp.Connected }; return $false }
    catch { return $false } finally { $tcp.Close() }
}
function Get-HostName { param([string]$Raw) if ($Raw -match '^(?:[a-z]+://)?([^/:\s]+)') { return $matches[1].ToLower() }; return '' }

function Get-SvcMode {
    param($Svc)
    $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($Svc.Name)'" -ErrorAction SilentlyContinue
    if ($cim) { return [string]$cim.StartMode }; return [string]$Svc.StartType
}
function Start-SvcWithRepair {
    # Disabled -> auto, then a non-blocking start. sc.exe is external, so it is guarded explicitly.
    param($Svc)
    $mode = Get-SvcMode $Svc
    if ($mode -eq 'Disabled' -and $PSCmdlet.ShouldProcess($Svc.Name, 'Set start type to auto')) { & sc.exe config $Svc.Name start= auto | Out-Null }
    if ($Svc.Status -ne 'Running' -and $PSCmdlet.ShouldProcess($Svc.Name, 'Start service')) { & sc.exe start $Svc.Name | Out-Null }
}

# -- Discovery and guard --
$agentRoot = $null
foreach ($r in $AgentRegistryRoots) { if (Test-Path -LiteralPath $r) { $agentRoot = $r; break } }
$uninst = @(Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match $AgentUninstallPattern })
$allSvc = @(Get-Service -ErrorAction SilentlyContinue)
$agentSvc = $null; $blastSvc = $null
foreach ($s in $allSvc) { if ($AgentServiceNames -contains $s.Name) { $agentSvc = $s; break } }
if (-not $agentSvc) { foreach ($s in $allSvc) { if ($s.DisplayName -match $AgentServiceDisplayPattern -and $s.DisplayName -notmatch $BlastServiceDisplayPattern) { $agentSvc = $s; break } } }
foreach ($s in $allSvc) { if ($BlastServiceNames -contains $s.Name) { $blastSvc = $s; break } }
if (-not $blastSvc) { foreach ($s in $allSvc) { if ($s.DisplayName -match $BlastServiceDisplayPattern -and $s.DisplayName -match '(?i)Horizon|VMware|Omnissa') { $blastSvc = $s; break } } }

if (-not $agentRoot -and -not $agentSvc -and $uninst.Count -eq 0) {
    Write-Output "$HEAD No Horizon Agent present on this device. Nothing to process."
    Write-Log 'No Horizon Agent detected. Exiting.'
    exit 0
}

# Shared between steps 5 and 6.
$Script:Brokers = New-Object System.Collections.Generic.List[string]
$Script:BrokersResolved = New-Object System.Collections.Generic.List[string]

$Steps = @(

    @{
        Name = 'Horizon Agent Service'
        DetectionScript = {
            if (-not $agentSvc) { return Res Failed "Horizon Agent service not found (tried $($AgentServiceNames -join ', ')) -- agent registry keys exist but the service is missing" }
            $agentSvc.Refresh(); $mode = Get-SvcMode $agentSvc
            if ($agentSvc.Status -ne 'Running' -or $mode -eq 'Disabled') { return Res Failed "Horizon Agent service ($($agentSvc.Name)) is $($agentSvc.Status) (StartMode: $mode) -- the desktop cannot pair with the Connection Server or accept sessions" }
            return Res Passed "Horizon Agent service ($($agentSvc.Name)) is Running (StartMode: $mode)"
        }
        ResolutionScript = { if ($agentSvc) { Start-SvcWithRepair $agentSvc } }
    },

    @{
        Name = 'Horizon Blast Service'
        DetectionScript = {
            if (-not $blastSvc) { return Res Passed 'Blast service not installed -- not applicable' }
            $blastSvc.Refresh(); $mode = Get-SvcMode $blastSvc
            if ($blastSvc.Status -ne 'Running' -or $mode -eq 'Disabled') { return Res Failed "Blast service ($($blastSvc.Name)) is $($blastSvc.Status) (StartMode: $mode) -- Blast sessions cannot connect; PCoIP and RDP are unaffected" }
            return Res Passed "Blast service ($($blastSvc.Name)) is Running (StartMode: $mode)"
        }
        ResolutionScript = { if ($blastSvc) { Start-SvcWithRepair $blastSvc } }
    },

    @{
        Name = 'Horizon Feature Services'
        DetectionScript = {
            $Script:Feat = @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
                $_.DisplayName -match $FeatureServiceInclude -and $_.DisplayName -notmatch $FeatureServiceExclude -and
                (-not $agentSvc -or $_.Name -ne $agentSvc.Name) -and (-not $blastSvc -or $_.Name -ne $blastSvc.Name) -and [string]$_.StartType -eq 'Automatic' })
            if ($Script:Feat.Count -eq 0) { return Res Passed 'No Horizon feature services found' }
            $stopped = @($Script:Feat | Where-Object { $_.Status -ne 'Running' })
            if ($stopped.Count -gt 0) { return Res Failed "Automatic feature service(s) not running: $(($stopped | ForEach-Object { "$($_.Name) ($($_.Status))" }) -join ', ')" }
            return Res Passed "All $($Script:Feat.Count) automatic feature services running"
        }
        ResolutionScript = {
            foreach ($s in @($Script:Feat | Where-Object { $_.Status -ne 'Running' })) {
                if ($PSCmdlet.ShouldProcess($s.Name, 'Start service')) { & sc.exe start $s.Name | Out-Null }
            }
        }
    },

    @{
        Name = 'Horizon Firewall Rules'
        DetectionScript = {
            $Script:Rules = @(Get-NetFirewallRule -ErrorAction Stop | Where-Object { $_.DisplayName -match $AgentFirewallRulePattern -or $_.DisplayGroup -match $AgentFirewallRulePattern })
            if ($Script:Rules.Count -eq 0) { return Res Warning 'No Horizon firewall rules found -- rule naming may differ from the pattern (KB-HZN-07)' }
            $off = @($Script:Rules | Where-Object { [string]$_.Enabled -ne 'True' })
            if ($off.Count -gt 0) { return Res Failed "$($off.Count) Horizon firewall rule(s) disabled: $(($off | ForEach-Object { $_.DisplayName }) -join ', ')" }
            return Res Passed "$($Script:Rules.Count) Horizon firewall rule(s) enabled"
        }
        ResolutionScript = {
            # Enable-NetFirewallRule supports ShouldProcess natively and honours $WhatIfPreference.
            foreach ($r in @($Script:Rules | Where-Object { [string]$_.Enabled -ne 'True' })) { Enable-NetFirewallRule -Name $r.Name -ErrorAction Stop }
        }
    },

    @{
        Name = 'Broker DNS Resolution'
        DetectionScript = {
            if ($agentRoot) {
                foreach ($k in @($agentRoot, (Join-Path $agentRoot 'Configuration'), (Join-Path (Split-Path $agentRoot -Parent) 'Node Manager'))) {
                    if (-not (Test-Path -LiteralPath $k)) { continue }
                    $p = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
                    foreach ($vn in $BrokerValueCandidates) {
                        if ($null -eq $p.$vn) { continue }
                        foreach ($piece in ((([string[]]$p.$vn) -join ' ') -split '[;,\s]+')) { $h = Get-HostName $piece; if ($h -and -not $Script:Brokers.Contains($h)) { $Script:Brokers.Add($h) } }
                    }
                }
            }
            # Brokers seen by live sessions (ViewClient_Broker_DNS_Name in each loaded user hive).
            foreach ($hive in @(Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-\d+-\d+-\d+-\d+$' })) {
                foreach ($ve in @(Get-ChildItem -Path "$($hive.PSPath)\Volatile Environment" -ErrorAction SilentlyContinue)) {
                    $b = (Get-ItemProperty -Path $ve.PSPath -Name $ViewClientBrokerVar -ErrorAction SilentlyContinue).$ViewClientBrokerVar
                    $h = Get-HostName ([string]$b); if ($h -and -not $Script:Brokers.Contains($h)) { $Script:Brokers.Add($h) }
                }
            }
            if ($Script:Brokers.Count -eq 0) { return Res Warning 'No broker known on this device -- pairing state cannot be checked (KB-HZN-04)' }
            $Script:BrokersResolved.Clear()
            foreach ($b in ($Script:Brokers | Select-Object -First $MaxProbeHosts)) {
                try { if (Resolve-DnsName -Name $b -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' }) { $Script:BrokersResolved.Add($b) } } catch { }
            }
            if ($Script:BrokersResolved.Count -eq 0) { return Res Failed "Broker name(s) do not resolve: $($Script:Brokers -join ', ') -- DNS client or suffix search list problem" }
            return Res Passed "Broker name(s) resolve: $($Script:BrokersResolved -join ', ')"
        }
        ResolutionScript = {
            if ($PSCmdlet.ShouldProcess('DNS resolver cache', 'Flush and re-register')) {
                & ipconfig.exe /flushdns | Out-Null; & ipconfig.exe /registerdns | Out-Null
                foreach ($b in ($Script:Brokers | Select-Object -First $MaxProbeHosts)) {
                    try { if (Resolve-DnsName -Name $b -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' }) { if (-not $Script:BrokersResolved.Contains($b)) { $Script:BrokersResolved.Add($b) } } } catch { }
                }
            }
        }
    },

    @{
        Name = 'Broker Connectivity'
        DetectionScript = {
            if ($Script:BrokersResolved.Count -eq 0) { return Res Passed 'Not testable (see step 5)' }
            foreach ($b in $Script:BrokersResolved) {
                foreach ($port in $BrokerPorts) {
                    $sw = [System.Diagnostics.Stopwatch]::StartNew()
                    if (Test-TcpPort -TargetHost $b -Port $port -TimeoutMs $NetTimeoutMs) { return Res Passed "Broker reachable: ${b}:$port in $([int]$sw.Elapsed.TotalMilliseconds) ms" }
                }
            }
            return Res Warning "Broker unreachable on TCP $($BrokerPorts -join '/'): $($Script:BrokersResolved -join ', ') -- Connection Server, UAG or firewall path; not fixable from the desktop"
        }
    },

    @{
        Name = 'Disconnected Sessions'
        ResolveOnWarning = $false     # set $true to log off disconnected sessions older than $DisconnectedStaleMinutes
        DetectionScript = {
            $Script:Stale = @()
            $decided = @{}
            try {
                $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'; Id = 21, 23, 24, 25; StartTime = (Get-Date).AddHours(-$SessionLookbackHours) } -MaxEvents $MaxEventsScanned -ErrorAction Stop)
            }
            catch { if ($_.Exception.Message -match 'No events were found') { $ev = @() } else { return Res Warning "Session inventory not readable -- $($_.Exception.Message)" } }
            foreach ($e in $ev) {
                $u = ([xml]$e.ToXml()).Event.UserData.EventXML
                $sid = [int]$u.SessionID; if ($sid -le 0 -or $decided.ContainsKey($sid)) { continue }
                $decided[$sid] = $true
                if ($e.Id -ne 24) { continue }
                $age = [int]((Get-Date) - $e.TimeCreated).TotalMinutes
                if ($age -gt $DisconnectedStaleMinutes) { $Script:Stale += ,@{ Id = $sid; User = [string]$u.User; Min = $age } }
            }
            if ($Script:Stale.Count -gt 0) { return Res Warning "$($Script:Stale.Count) disconnected session(s) older than $DisconnectedStaleMinutes min: $(($Script:Stale | ForEach-Object { "$($_.User) (id $($_.Id), $($_.Min) min)" }) -join ', ')" }
            return Res Passed "No disconnected sessions older than $DisconnectedStaleMinutes min"
        }
        ResolutionScript = {
            foreach ($s in $Script:Stale) { if ($PSCmdlet.ShouldProcess("session $($s.Id) ($($s.User))", 'Log off')) { & logoff.exe $s.Id | Out-Null } }
        }
    },

    @{
        Name = 'Blast Session Quality'
        DetectionScript = {
            $rows = @{}; $set = ''
            foreach ($cs in $BlastSessionCounterSets) {
                try {
                    $c = Get-Counter -Counter @("\$cs(*)\$($BlastCounterNames.Rtt)", "\$cs(*)\$($BlastCounterNames.Loss)") -MaxSamples 1 -ErrorAction Stop
                    foreach ($smp in @($c.CounterSamples)) {
                        if ($smp.Path -notmatch '(?i)session id:\s*(\d+)') { continue }
                        $id = [int]$matches[1]; if (-not $rows.ContainsKey($id)) { $rows[$id] = @{ Rtt = -1; Loss = -1 } }
                        if ($smp.Path -match [regex]::Escape($BlastCounterNames.Rtt) + '$') { $rows[$id].Rtt = [int]$smp.CookedValue } else { $rows[$id].Loss = [int]($smp.CookedValue * 10000) }
                    }
                    $set = $cs; break
                }
                catch { }
            }
            if (-not $set -or $rows.Count -eq 0) { return Res Passed 'No Blast sessions' }
            $rtt = ($rows.Values | ForEach-Object { $_.Rtt } | Measure-Object -Maximum).Maximum
            $loss = ($rows.Values | ForEach-Object { $_.Loss } | Measure-Object -Maximum).Maximum
            if ($rtt -gt $BlastRttWarnMs -or $loss -gt $BlastLossWarnPpm) { return Res Warning "Worst Blast session RTT $rtt ms, loss $loss ppm (thresholds $BlastRttWarnMs ms, $BlastLossWarnPpm ppm) -- network path between client and desktop; correlate with the client device" }
            return Res Passed "Worst Blast session RTT $rtt ms, loss $loss ppm across $($rows.Count) session(s)"
        }
    },

    @{
        Name = 'Agent Errors'
        DetectionScript = {
            try {
                $errs = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 1, 2; StartTime = (Get-Date).AddHours(-$EventLookbackHours) } -MaxEvents $MaxEventsScanned -ErrorAction Stop | Where-Object { $_.ProviderName -match $AgentEventProviderPattern })
            }
            catch { if ($_.Exception.Message -match 'No events were found') { $errs = @() } else { return Res Warning 'Application log not readable -- error count unknown' } }
            if ($errs.Count -ge $AgentErrorWarnCount) {
                $top = (@($errs | Group-Object Id | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Name):$($_.Count)" }) -join ', ')
                return Res Warning "$($errs.Count) Horizon error events in the last $EventLookbackHours h; top IDs: $top"
            }
            return Res Passed "$($errs.Count) Horizon error events in the last $EventLookbackHours h"
        }
    },

    @{
        Name = 'Pairing and Clone State'
        DetectionScript = {
            $c = Get-ItemProperty -Path $CachePath -ErrorAction SilentlyContinue
            if (-not $c -or -not $c.LastRun) { return Res Passed 'No collector cache -- image-fault check skipped' }
            $pers = if ($c.Persistence) { [string]$c.Persistence } else { 'Unknown' }
            $atBoot = 0; try { $atBoot = [int]$c.FaultPresentAtBoot } catch { }
            if ($atBoot -eq 1 -and $pers -eq 'NonPersistent') { return Res Warning "Leading fault ($($c.HealthReason)) was present at first boot of a non-persistent clone -- fixes here are relief only; the parent image needs the same fix" }
            if ($atBoot -eq 1) { return Res Warning "Leading fault ($($c.HealthReason)) was present at boot -- likely image or provisioning, not session drift" }
            return Res Passed "No fault present at boot (persistence: $pers)"
        }
    }
)

# -- Execution engine (array order; Enabled absent means enabled) --
$activeSteps = @($Steps | Where-Object { -not $_.ContainsKey('Enabled') -or $_.Enabled })
$results = [System.Collections.Generic.List[PSCustomObject]]::new()
Write-Output "`r`n-- HorizonAgentResolutionWizard ---------------------------------------"
Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)"
Write-Output '----------------------------------------------------------------'
$i = 0
foreach ($step in $activeSteps) {
    $i++; $status = 'Failed'; $message = 'Detection script did not return a result.'; $remediated = $false; $remError = ''
    try { $r = & $step.DetectionScript; $status = $r.Status; $message = $r.Message }
    catch { $status = 'Failed'; $message = "Detection exception: $($_.Exception.Message)" }
    $should = ($status -eq 'Failed') -or ($status -eq 'Warning' -and $step.ResolveOnWarning)
    if ($should -and $step.ResolutionScript) {
        try { & $step.ResolutionScript | Out-Null; $remediated = $true } catch { $remError = $_.Exception.Message }
    }
    $note = if ($remediated) { '  -> Remediation ran' } elseif ($remError) { "  -> Remediation ERROR: $remError" } else { '' }
    Write-Output "`r`n  [$($status.PadRight(7))] $($step.Name): $message$note"
    Write-Log "[$status] $($step.Name): $message$note"
    $results.Add([PSCustomObject]@{ Order = $i; Name = $step.Name; Status = $status; Remediated = $remediated; RemError = $remError; HasFix = [bool]$step.ResolutionScript })
}

$passed = @($results | Where-Object { $_.Status -eq 'Passed' }).Count
$warnings = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed = @($results | Where-Object { $_.Status -eq 'Failed' }).Count
$remCount = @($results | Where-Object { $_.Remediated }).Count
$remErrors = @($results | Where-Object { $_.RemError }).Count
$unfixed = @($results | Where-Object { $_.Status -eq 'Failed' -and (-not $_.Remediated -or $_.RemError) }).Count

$cache = Get-ItemProperty -Path $CachePath -ErrorAction SilentlyContinue
$persistence = if ($cache -and $cache.Persistence) { [string]$cache.Persistence } else { 'Unknown' }
$reliefOnly = [int]($persistence -ne 'Persistent')

Write-Output "`r`n----------------------------------------------------------------"
Write-Output "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations run: $remCount  |  Remediation errors: $remErrors"
if ($reliefOnly -eq 1 -and $remCount -gt 0) { Write-Output "  Persistence is ${persistence}: remediations above are relief for this clone and revert at the next refresh." }
Write-Output "----------------------------------------------------------------`r`n"

try {
    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop -WhatIf:$false | Out-Null }
    $ver = if ($SCRIPT_VARIANT) { "$SCRIPT_VERSION+$SCRIPT_VARIANT" } else { $SCRIPT_VERSION }
    $stepsStr = (@($results | ForEach-Object { "$($_.Order):$($_.Status)$(if ($_.Remediated) { '+Rem' })$(if ($_.RemError) { '+Err' })" }) -join ';')
    $vals = [ordered]@{ ScriptVersion = $ver; Status = $(if ($failed -gt 0) { 'Failed' } elseif ($warnings -gt 0) { 'Warning' } else { 'Passed' })
                        Passed = [string]$passed; Warnings = [string]$warnings; Failed = [string]$failed; RemediationsRun = [string]$remCount
                        RemediationErrors = [string]$remErrors; Steps = $stepsStr; Persistence = $persistence }
    foreach ($k in $vals.Keys) { Set-ItemProperty -Path $RegPath -Name $k -Value $vals[$k] -Type String -ErrorAction Stop -WhatIf:$false }
    Set-ItemProperty -Path $RegPath -Name 'ReliefOnly' -Value $reliefOnly -Type DWord -ErrorAction Stop -WhatIf:$false
    Set-ItemProperty -Path $RegPath -Name 'WhatIf' -Value ([int]$WhatIfPreference) -Type DWord -ErrorAction Stop -WhatIf:$false
    Set-ItemProperty -Path $RegPath -Name 'LastRun' -Value (Get-Date -Format 'o') -Type String -ErrorAction Stop -WhatIf:$false
    Write-Log "Results cached to $RegPath"
}
catch { Write-Log "Failed to cache results: $($_.Exception.Message)" -Level 'ERROR' }

if ($unfixed -gt 0) { exit 1 }
exit 0
}

# Entry point. The param block is inside the function because the Workspace ONE engine
# does not bind a script-scope param block and $PSCmdlet is null there.
Invoke-AutoRemediateHorizonAgent
