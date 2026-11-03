<#
.SYNOPSIS
    Horizon Client remediation (endpoint side) -- fixes what the endpoint owns, reports
    the rest.

.DESCRIPTION
    Ten check-then-apply steps against the Horizon Client on a physical endpoint. Pairs
    with Invoke-HorizonClientStateCollection.ps1. Runs as SYSTEM, reads the console
    user's configuration and client log. Most client-side failures are network, so steps
    4, 5 and 9 route to the NetworkStack and VPN remediations rather than guessing.

      1  Horizon Client USB Service     AUTO   sc.exe config/start
      2  Horizon Client Firewall Rules  AUTO   Enable-NetFirewallRule
      3  Server DNS Resolution          AUTO   flush and re-register DNS
      4  Server Connectivity (443)      report
      5  Blast Port Connectivity        report 8443 (UAG) then 22443 (direct)
      6  Connection Failures (24h)      report from the user's client log
      7  Client Version                 report against an optional floor
      8  Certificate Checking Mode      report
      9  Endpoint Network Context       report VPN and network-stack caches
     10  Client Preferences Reset       OFF BY DEFAULT, ConfirmHighImpact, renames the prefs folder

    Report-only steps return Warning, never Failed (SPEC 8.4). Message templates are
    exact; the break test matches on them. Contract: VDI/Horizon/SPEC.md rev 1, 8.2.
    Results: HKLM:\Software\AirWatch\Extensions\VDI\Horizon\Client\Remediation.

.NOTES
    Script Name  : Invoke-AutoRemediateHorizonClient.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Timeout      : 30 seconds (deploy with a 60 second UEM timeout)
    Built from   : VDI/Horizon/SPEC.md rev 1

    Environment variables:
      WhatIf = true              Dry run. Absent/unparseable => live run.
      ConfirmHighImpact = true   Required for step 10 (which also ships Enabled = $false).

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
function Invoke-AutoRemediateHorizonClient {
[CmdletBinding(SupportsShouldProcess = $true)]
param()

$SCRIPT_VERSION = '1.0.0'
$SCRIPT_VARIANT = ''
$CachePath = 'HKLM:\Software\AirWatch\Extensions\VDI\Horizon\Client'
$RegPath   = "$CachePath\Remediation"
$LogPath   = "$env:SystemRoot\Temp\UEM_AutoRemediateHorizonClient.log"

# -- Tunables --
$ConnectFailureWarnCount = 5
$NetTimeoutMs            = 2000
$MaxProbeHosts           = 3
$ClientVersionFloor      = ''        # KB-HZN-20
$LogTailBytes            = 524288
$LogLookbackHours        = 24

# -- KB resolution points (VDI/Horizon/SPEC.md section 3); identical to the collector --
$ClientUninstallPattern      = '(?i)^(Omnissa|VMware) Horizon Client'                                                   # KB-HZN-14
$ClientRegistryRoots         = @('SOFTWARE\Omnissa\Horizon\Client', 'SOFTWARE\VMware, Inc.\VMware VDM\Client')         # KB-HZN-15
$ClientPolicyRoots           = @('HKLM:\SOFTWARE\Policies\Omnissa\Horizon\Client', 'HKLM:\SOFTWARE\Policies\VMware, Inc.\VMware VDM\Client')
$ClientServerValueCandidates = @('Server', 'ServerURL', 'DefaultServer', 'RecentServers')
$CertCheckValueName          = 'CertCheckMode'
$ClientPrefsDirs             = @('AppData\Roaming\Omnissa\Horizon\Client', 'AppData\Roaming\VMware\VMware Horizon View Client')  # KB-HZN-15 (prefs)
$ClientLogDirs               = @('AppData\Local\Omnissa\Horizon\Logs', 'AppData\Local\VMware\VDM\Logs')               # KB-HZN-16
$ClientLogFilePatterns       = @('*horizon*client*.txt', 'vmware-horizon-client-*.txt', 'vmware-horizon-client*.log')
$ClientLogFailureRegex       = '(?i)connect(ion)? (failed|error|refused)|unable to (connect|resolve)|certificate.*(invalid|rejected)|authentication failed|tunnel.*(failed|error)'
$ClientUsbServiceNames       = @('vmware-usbarbitrator')                                                                 # KB-HZN-17
$ClientUsbDisplayPattern     = '(?i)USB Arbitration'
$ClientFirewallRulePattern   = '(?i)Horizon Client|VMware Horizon|Omnissa Horizon'                                       # KB-HZN-18
$ClientBlastPorts            = @(8443, 22443)                                                                            # KB-HZN-19
$VpnCachePath                = 'HKLM:\Software\AirWatch\Extensions\VPN'
$NetworkStackCachePaths      = @('HKLM:\Software\AirWatch\Extensions\NetworkStack\Remediation', 'HKLM:\Software\AirWatch\Extensions\NetworkStack')

$WhatIfPreference = $false
if ($env:WhatIf) { try { $WhatIfPreference = [System.Convert]::ToBoolean($env:WhatIf) } catch { $WhatIfPreference = $false } }
$ConfirmHighImpact = $false
if ($env:ConfirmHighImpact) { try { $ConfirmHighImpact = [System.Convert]::ToBoolean($env:ConfirmHighImpact) } catch { $ConfirmHighImpact = $false } }

$RunEventId = ([Random]::new()).Next(1000, 9999)
Write-Output "[$RunEventId] Executing Invoke-AutoRemediateHorizonClient, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'  WhatIf=$WhatIfPreference"
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
function Get-HostName { param([string]$Raw) if ($Raw -match '^(?:[a-z]+://)?([A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9-]{2,})') { return $matches[1].ToLower() }; return '' }
function Get-SvcMode { param($Svc) $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($Svc.Name)'" -ErrorAction SilentlyContinue; if ($cim) { return [string]$cim.StartMode }; return [string]$Svc.StartType }

# -- Discovery and guard --
$uninst = @(Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match $ClientUninstallPattern })
if ($uninst.Count -eq 0) {
    Write-Output "$HEAD No Horizon Client present on this device. Nothing to process."
    Write-Log 'No Horizon Client detected. Exiting.'
    exit 0
}
$clientVersion = [string]$uninst[0].DisplayVersion

$cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
$userName = if ($cs -and $cs.UserName) { [string]$cs.UserName } else { '' }
$userSid = ''; $profilePath = ''
if ($userName) {
    try { $userSid = ([Security.Principal.NTAccount]$userName).Translate([Security.Principal.SecurityIdentifier]).Value } catch { }
    if ($userSid) { $pl = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$userSid" -ErrorAction SilentlyContinue; if ($pl) { $profilePath = [string]$pl.ProfileImagePath } }
}

$Script:Servers = New-Object System.Collections.Generic.List[string]
$Script:Resolved = New-Object System.Collections.Generic.List[string]
$Script:Reachable = ''
$Script:Failures = -1

function Add-ServersFromKey {
    param([string]$Key)
    if (-not (Test-Path -LiteralPath $Key)) { return }
    $p = Get-ItemProperty -Path $Key -ErrorAction SilentlyContinue
    foreach ($vn in $ClientServerValueCandidates) {
        if ($null -eq $p.$vn) { continue }
        foreach ($piece in ((([string[]]$p.$vn) -join ' ') -split '[;,\s]+')) { $h = Get-HostName $piece; if ($h -and -not $Script:Servers.Contains($h)) { $Script:Servers.Add($h) } }
    }
    foreach ($sub in @(Get-ChildItem -Path $Key -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '(?i)server' })) {
        $h = Get-HostName $sub.PSChildName; if ($h -and -not $Script:Servers.Contains($h)) { $Script:Servers.Add($h) }
        $sp = Get-ItemProperty -Path $sub.PSPath -ErrorAction SilentlyContinue
        foreach ($prop in @($sp.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' -and $_.Value -is [string] })) { $h = Get-HostName ([string]$prop.Value); if ($h -and -not $Script:Servers.Contains($h)) { $Script:Servers.Add($h) } }
        foreach ($leaf in @(Get-ChildItem -Path $sub.PSPath -ErrorAction SilentlyContinue)) { $h = Get-HostName $leaf.PSChildName; if ($h -and -not $Script:Servers.Contains($h)) { $Script:Servers.Add($h) } }
    }
}

$Steps = @(

    @{
        Name = 'Horizon Client USB Service'
        DetectionScript = {
            $Script:Usb = $null
            foreach ($s in @(Get-Service -ErrorAction SilentlyContinue)) { if ($ClientUsbServiceNames -contains $s.Name -or $s.DisplayName -match $ClientUsbDisplayPattern) { $Script:Usb = $s; break } }
            if (-not $Script:Usb) { return Res Passed 'USB arbitration service not installed -- USB redirection not available' }
            $mode = Get-SvcMode $Script:Usb
            if ($Script:Usb.Status -ne 'Running' -or $mode -eq 'Disabled') { return Res Failed "USB arbitration service ($($Script:Usb.Name)) is $($Script:Usb.Status) (StartMode: $mode) -- USB redirection will fail in sessions" }
            return Res Passed "USB arbitration service ($($Script:Usb.Name)) is Running (StartMode: $mode)"
        }
        ResolutionScript = {
            if (-not $Script:Usb) { return }
            if ((Get-SvcMode $Script:Usb) -eq 'Disabled' -and $PSCmdlet.ShouldProcess($Script:Usb.Name, 'Set start type to auto')) { & sc.exe config $Script:Usb.Name start= auto | Out-Null }
            if ($Script:Usb.Status -ne 'Running' -and $PSCmdlet.ShouldProcess($Script:Usb.Name, 'Start service')) { & sc.exe start $Script:Usb.Name | Out-Null }
        }
    },

    @{
        Name = 'Horizon Client Firewall Rules'
        DetectionScript = {
            $Script:Rules = @(Get-NetFirewallRule -ErrorAction Stop | Where-Object { $_.DisplayName -match $ClientFirewallRulePattern -or $_.DisplayGroup -match $ClientFirewallRulePattern })
            if ($Script:Rules.Count -eq 0) { return Res Passed 'No Horizon Client firewall rules found' }
            $off = @($Script:Rules | Where-Object { [string]$_.Enabled -ne 'True' })
            if ($off.Count -gt 0) { return Res Failed "$($off.Count) Horizon Client firewall rule(s) disabled: $(($off | ForEach-Object { $_.DisplayName }) -join ', ')" }
            return Res Passed "$($Script:Rules.Count) Horizon Client firewall rule(s) enabled"
        }
        ResolutionScript = { foreach ($r in @($Script:Rules | Where-Object { [string]$_.Enabled -ne 'True' })) { Enable-NetFirewallRule -Name $r.Name -ErrorAction Stop } }
    },

    @{
        Name = 'Server DNS Resolution'
        DetectionScript = {
            foreach ($k in $ClientPolicyRoots) { Add-ServersFromKey -Key $k }
            if ($userSid) { foreach ($rel in $ClientRegistryRoots) { Add-ServersFromKey -Key "Registry::HKEY_USERS\$userSid\$rel" } }
            if ($Script:Servers.Count -eq 0) { return Res Warning "No Horizon server configured for $(if ($userName) { $userName } else { 'the console user' }) -- nothing to test" }
            $Script:Resolved.Clear()
            foreach ($h in ($Script:Servers | Select-Object -First $MaxProbeHosts)) { try { if (Resolve-DnsName -Name $h -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' }) { $Script:Resolved.Add($h) } } catch { } }
            if ($Script:Resolved.Count -eq 0) { return Res Failed "Server name(s) do not resolve: $($Script:Servers -join ', ')" }
            return Res Passed "Server name(s) resolve: $($Script:Resolved -join ', ')"
        }
        ResolutionScript = {
            if ($PSCmdlet.ShouldProcess('DNS resolver cache', 'Flush and re-register')) {
                & ipconfig.exe /flushdns | Out-Null; & ipconfig.exe /registerdns | Out-Null
                foreach ($h in ($Script:Servers | Select-Object -First $MaxProbeHosts)) { try { if (Resolve-DnsName -Name $h -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' }) { if (-not $Script:Resolved.Contains($h)) { $Script:Resolved.Add($h) } } } catch { } }
            }
        }
    },

    @{
        Name = 'Server Connectivity (443)'
        DetectionScript = {
            if ($Script:Resolved.Count -eq 0) { return Res Passed 'Not testable (see step 3)' }
            foreach ($h in $Script:Resolved) {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                if (Test-TcpPort -TargetHost $h -Port 443 -TimeoutMs $NetTimeoutMs) { $Script:Reachable = $h; return Res Passed "Server reachable: ${h}:443 in $([int]$sw.Elapsed.TotalMilliseconds) ms" }
            }
            return Res Warning "No Horizon server answers on TCP 443: $($Script:Resolved -join ', ') -- VPN, proxy or network path; run Invoke-AutoRemediateNetworkStack.ps1 and the VPN remediation first"
        }
    },

    @{
        Name = 'Blast Port Connectivity'
        DetectionScript = {
            if (-not $Script:Reachable) { return Res Passed 'Not testable (see step 4)' }
            foreach ($bp in $ClientBlastPorts) { if (Test-TcpPort -TargetHost $Script:Reachable -Port $bp -TimeoutMs $NetTimeoutMs) { return Res Passed "Blast port $bp reachable on $($Script:Reachable)" } }
            return Res Warning "Server answers on 443 but not on Blast ports $($ClientBlastPorts -join '/'): $($Script:Reachable) -- sessions will authenticate and then fail to display; UAG or firewall"
        }
    },

    @{
        Name = 'Connection Failures (24h)'
        DetectionScript = {
            if (-not $profilePath) { return Res Passed 'No client log readable (NoUser)' }
            $logFile = $null
            foreach ($rel in $ClientLogDirs) {
                $dir = Join-Path $profilePath $rel; if (-not (Test-Path -LiteralPath $dir)) { continue }
                foreach ($pat in $ClientLogFilePatterns) { $f = Get-ChildItem -Path $dir -Filter $pat -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if ($f -and (-not $logFile -or $f.LastWriteTime -gt $logFile.LastWriteTime)) { $logFile = $f } }
            }
            if (-not $logFile) { return Res Passed 'No client log readable (NoLog)' }
            try {
                $fs = [System.IO.File]::Open($logFile.FullName, 'Open', 'Read', 'ReadWrite')
                try { $len = $fs.Length; $take = [math]::Min($len, $LogTailBytes); $fs.Seek($len - $take, 'Begin') | Out-Null; $buf = New-Object byte[] $take; $fs.Read($buf, 0, $take) | Out-Null } finally { $fs.Close() }
                $since = (Get-Date).AddHours(-$LogLookbackHours); $fail = 0; $last = ''
                foreach ($line in ([System.Text.Encoding]::UTF8.GetString($buf) -split "`r?`n")) {
                    if ($line -notmatch '^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2})') { continue }
                    $ts = [datetime]::MinValue; if (-not [datetime]::TryParse($matches[1].Replace('T', ' '), [ref]$ts) -or $ts -lt $since) { continue }
                    if ($line -match $ClientLogFailureRegex) { $fail++; if ($line -match '(?i)(?:server|broker|host|url)[=:\s"]+(?:[a-z]+://)?([A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9-]{2,})') { $last = $matches[1].ToLower() } }
                }
                $Script:Failures = $fail
            }
            catch { return Res Passed 'No client log readable (Error)' }
            if ($Script:Failures -ge $ConnectFailureWarnCount) { return Res Warning "$($Script:Failures) connection failure(s) in the last 24 h for $userName; last server $(if ($last) { $last } else { 'unknown' })" }
            return Res Passed "$($Script:Failures) connection failure(s) in the last 24 h"
        }
    },

    @{
        Name = 'Client Version'
        DetectionScript = {
            if (-not $ClientVersionFloor) { return Res Passed "Client $clientVersion; no version floor configured" }
            try { if ([version]$clientVersion -lt [version]$ClientVersionFloor) { return Res Warning "Client $clientVersion is below the floor $ClientVersionFloor -- deploy the current client via UEM" } } catch { }
            return Res Passed "Client $clientVersion meets the floor $ClientVersionFloor"
        }
    },

    @{
        Name = 'Certificate Checking Mode'
        DetectionScript = {
            $mode = $null
            if ($userSid) { foreach ($rel in $ClientRegistryRoots) { $v = (Get-ItemProperty -Path "Registry::HKEY_USERS\$userSid\$rel" -Name $CertCheckValueName -ErrorAction SilentlyContinue).$CertCheckValueName; if ($null -ne $v -and $null -eq $mode) { $mode = $v } } }
            foreach ($k in $ClientPolicyRoots) { $v = (Get-ItemProperty -Path $k -Name $CertCheckValueName -ErrorAction SilentlyContinue).$CertCheckValueName; if ($null -ne $v) { $mode = $v } }
            if ($null -eq $mode) { return Res Passed 'Certificate checking mode not set (client default)' }
            if ([string]$mode -eq '0') { return Res Warning 'Certificate checking is disabled (CertCheckMode 0) -- connections to a spoofed server would succeed; set by policy' }
            return Res Passed "Certificate checking mode $mode"
        }
    },

    @{
        Name = 'Endpoint Network Context'
        DetectionScript = {
            $vpn = Get-ItemProperty -Path $VpnCachePath -ErrorAction SilentlyContinue
            $vs = -1; $vr = ''
            if ($vpn) { $d = 0.0; if ($null -ne $vpn.HealthScore -and [double]::TryParse([string]$vpn.HealthScore, [ref]$d)) { $vs = [int]$d }; $vr = [string]$vpn.HealthReason }
            $ns = ''; foreach ($k in $NetworkStackCachePaths) { $p = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue; if ($p -and $p.Status) { $ns = [string]$p.Status; break } }
            if ($vs -ge 0 -and $vs -lt 50) { return Res Warning "VPN health score $vs ($vr) on this endpoint -- run VPN/Invoke-AutoRemediateGenericVPN.ps1 before troubleshooting Horizon" }
            return Res Passed "VPN health score $(if ($vs -ge 0) { $vs } else { 'n/a' }); network stack $(if ($ns) { $ns } else { 'n/a' })"
        }
    },

    @{
        Name = 'Client Preferences Reset'
        Enabled = $false       # opt-in: destroys the user's saved servers and settings; also requires ConfirmHighImpact
        DetectionScript = {
            if (-not $ConfirmHighImpact) { return Res Passed 'Client preferences left in place (ConfirmHighImpact not set)' }
            if (-not $profilePath -or $Script:Failures -lt $ConnectFailureWarnCount) { return Res Passed 'Client preferences left in place' }
            $Script:PrefsDir = ''
            foreach ($rel in $ClientPrefsDirs) { $d = Join-Path $profilePath $rel; if (Test-Path -LiteralPath $d) { $Script:PrefsDir = $d; break } }
            if (-not $Script:PrefsDir) { return Res Passed 'Client preferences left in place' }
            return Res Failed "Client preferences reset is enabled and $($Script:Failures) failures were seen -- renaming $($Script:PrefsDir)"
        }
        ResolutionScript = {
            if ($Script:PrefsDir -and $PSCmdlet.ShouldProcess($Script:PrefsDir, 'Rename preferences folder')) {
                Rename-Item -LiteralPath $Script:PrefsDir -NewName ("$(Split-Path $Script:PrefsDir -Leaf).bak-$(Get-Date -Format 'yyyyMMddHHmm')") -ErrorAction Stop
            }
        }
    }
)

$activeSteps = @($Steps | Where-Object { -not $_.ContainsKey('Enabled') -or $_.Enabled })
$results = [System.Collections.Generic.List[PSCustomObject]]::new()
Write-Output "`r`n-- HorizonClientResolutionWizard --------------------------------------"
Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)   User: $(if ($userName) { $userName } else { '(none)' })"
Write-Output '----------------------------------------------------------------'
$i = 0
foreach ($step in $activeSteps) {
    $i++; $status = 'Failed'; $message = 'Detection script did not return a result.'; $remediated = $false; $remError = ''
    try { $r = & $step.DetectionScript; $status = $r.Status; $message = $r.Message }
    catch { $status = 'Failed'; $message = "Detection exception: $($_.Exception.Message)" }
    $should = ($status -eq 'Failed') -or ($status -eq 'Warning' -and $step.ResolveOnWarning)
    if ($should -and $step.ResolutionScript) { try { & $step.ResolutionScript | Out-Null; $remediated = $true } catch { $remError = $_.Exception.Message } }
    $note = if ($remediated) { '  -> Remediation ran' } elseif ($remError) { "  -> Remediation ERROR: $remError" } else { '' }
    Write-Output "`r`n  [$($status.PadRight(7))] $($step.Name): $message$note"
    Write-Log "[$status] $($step.Name): $message$note"
    $results.Add([PSCustomObject]@{ Order = $i; Name = $step.Name; Status = $status; Remediated = $remediated; RemError = $remError })
}

$passed = @($results | Where-Object { $_.Status -eq 'Passed' }).Count
$warnings = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed = @($results | Where-Object { $_.Status -eq 'Failed' }).Count
$remCount = @($results | Where-Object { $_.Remediated }).Count
$remErrors = @($results | Where-Object { $_.RemError }).Count
$unfixed = @($results | Where-Object { $_.Status -eq 'Failed' -and (-not $_.Remediated -or $_.RemError) }).Count

Write-Output "`r`n----------------------------------------------------------------"
Write-Output "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations run: $remCount  |  Remediation errors: $remErrors"
Write-Output "----------------------------------------------------------------`r`n"

try {
    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop -WhatIf:$false | Out-Null }
    $ver = if ($SCRIPT_VARIANT) { "$SCRIPT_VERSION+$SCRIPT_VARIANT" } else { $SCRIPT_VERSION }
    $stepsStr = (@($results | ForEach-Object { "$($_.Order):$($_.Status)$(if ($_.Remediated) { '+Rem' })$(if ($_.RemError) { '+Err' })" }) -join ';')
    $vals = [ordered]@{ ScriptVersion = $ver; Status = $(if ($failed -gt 0) { 'Failed' } elseif ($warnings -gt 0) { 'Warning' } else { 'Passed' })
                        Passed = [string]$passed; Warnings = [string]$warnings; Failed = [string]$failed; RemediationsRun = [string]$remCount
                        RemediationErrors = [string]$remErrors; Steps = $stepsStr; ClientUser = $userName }
    foreach ($k in $vals.Keys) { Set-ItemProperty -Path $RegPath -Name $k -Value $vals[$k] -Type String -ErrorAction Stop -WhatIf:$false }
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
Invoke-AutoRemediateHorizonClient
