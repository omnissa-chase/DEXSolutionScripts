<#
.SYNOPSIS
    Test-HorizonNoAgentPath -- non-destructive contract test for the Horizon set on a
    device with no Horizon Agent and no Horizon Client installed.

.DESCRIPTION
    Runs every Horizon script and sensor in a child powershell.exe -File the way UEM
    does, and asserts the not-installed contract from VDI/Horizon/SPEC.md section 11.1:

      Collectors      write Installed 0, HealthScore -1, HealthReason NotInstalled,
                      Status NotApplicable, LastRun; exit 0
      Remediations    print the guard line, write no Remediation sub-key, exit 0
      Tier 2 restart  writes Status SkippedNotInstalled, registers no task, exit 0
      Scalar sensors  emit exactly one line of the right type with the documented fallback
      One-time sensors emit one line of valid JSON with Installed false, HealthReason
                      NotInstalled and every contracted key present, no nulls

    Then seeds a synthetic agent and client cache and asserts every shipped scalar sensor
    returns the seeded value, including the ;ImageFault suffix rule and the decimal
    parse. Removes the
    VDI\Horizon keys it wrote at the end (the next scheduled collector run recreates them).

    Needs elevation (HKLM writes). Refuses to run when a Horizon Agent or Client is
    installed, because the seeded cache would overwrite real data; use
    Test-HorizonScoreParity.ps1 on such a host instead.

    Writes a JSON result to C:\Temp\FixReport\Test-HorizonNoAgentPath\<timestamp>.json.
    Exit 0 when every assertion passes, 1 otherwise.

.NOTES
    Script Name  : Test-HorizonNoAgentPath.ps1
    Version      : 1.0.0
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
param([string]$ReportRoot = 'C:\Temp\FixReport\Test-HorizonNoAgentPath')

$ErrorActionPreference = 'Stop'
$Root      = Resolve-Path (Join-Path $PSScriptRoot '..')
$AgentKey  = 'HKLM:\Software\AirWatch\Extensions\VDI\Horizon\Agent'
$ClientKey = 'HKLM:\Software\AirWatch\Extensions\VDI\Horizon\Client'
$results   = New-Object System.Collections.Generic.List[object]

function Assert { param([string]$Name, [bool]$Ok, [string]$Detail = '')
    $results.Add([pscustomobject]@{ Test = $Name; Pass = $Ok; Detail = $Detail })
    Write-Host ("  [{0}] {1}{2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $(if ($Detail) { " -- $Detail" } else { '' })) -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' })
}
function Invoke-Child { param([string]$Path, [hashtable]$Env = @{})
    foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $Env[$k], 'Process') }
    try { $out = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Path 2>&1 | ForEach-Object { [string]$_ }); return @{ Output = $out; Exit = $LASTEXITCODE } }
    finally { foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $null, 'Process') } }
}
function Get-Val { param([string]$Key, [string]$Name) try { return (Get-ItemProperty -Path $Key -Name $Name -ErrorAction Stop).$Name } catch { return $null } }
function ConvertTo-Int { param([string]$Raw) $v = 0.0; if ([double]::TryParse($Raw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { return [int][math]::Round($v) }; return $null }

Write-Host "`nTest-HorizonNoAgentPath on $env:COMPUTERNAME  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"

# -- Precondition: nothing Horizon on this host --
$svc = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'wsnm' -or $_.DisplayName -match '(?i)Horizon' })
$uninst = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '(?i)^(Omnissa|VMware) Horizon' })
$roots = @('HKLM:\SOFTWARE\Omnissa\Horizon\Agent', 'HKLM:\SOFTWARE\VMware, Inc.\VMware VDM\Agent') | Where-Object { Test-Path $_ }
if ($svc.Count -gt 0 -or $uninst.Count -gt 0 -or $roots.Count -gt 0) {
    throw "A Horizon component is installed on this host (services: $($svc.Count), uninstall entries: $($uninst.Count), agent roots: $($roots.Count)). This test is for hosts without Horizon; run Test-HorizonScoreParity.ps1 instead."
}
Remove-Item -Path 'HKLM:\Software\AirWatch\Extensions\VDI\Horizon' -Recurse -Force -ErrorAction SilentlyContinue

# -- Collectors --
foreach ($c in @(@{ Name = 'Invoke-HorizonAgentStateCollection'; Key = $AgentKey }, @{ Name = 'Invoke-HorizonClientStateCollection'; Key = $ClientKey })) {
    $r = Invoke-Child (Join-Path $Root "$($c.Name).ps1")
    Assert "$($c.Name): exit 0" ($r.Exit -eq 0) "exit $($r.Exit)"
    Assert "$($c.Name): Installed 0" ((Get-Val $c.Key 'Installed') -eq 0)
    Assert "$($c.Name): HealthScore -1" ((ConvertTo-Int ([string](Get-Val $c.Key 'HealthScore'))) -eq -1)
    Assert "$($c.Name): HealthReason NotInstalled" ((Get-Val $c.Key 'HealthReason') -eq 'NotInstalled')
    Assert "$($c.Name): Status NotApplicable" ((Get-Val $c.Key 'Status') -eq 'NotApplicable')
    Assert "$($c.Name): LastRun written" (-not [string]::IsNullOrEmpty((Get-Val $c.Key 'LastRun')))
}

# -- Remediations --
foreach ($c in @(@{ Name = 'Invoke-AutoRemediateHorizonAgent'; Key = "$AgentKey\Remediation"; Line = 'No Horizon Agent present on this device. Nothing to process.' },
                 @{ Name = 'Invoke-AutoRemediateHorizonClient'; Key = "$ClientKey\Remediation"; Line = 'No Horizon Client present on this device. Nothing to process.' })) {
    $r = Invoke-Child (Join-Path $Root "$($c.Name).ps1")
    Assert "$($c.Name): exit 0" ($r.Exit -eq 0) "exit $($r.Exit)"
    Assert "$($c.Name): guard line" (($r.Output -join "`n") -like "*$($c.Line)*")
    Assert "$($c.Name): no Remediation key" (-not (Test-Path $c.Key))
}

# -- Tier 2 --
$r = Invoke-Child (Join-Path $Root 'Invoke-AutoRemediateHorizonAgentRestart.ps1')
Assert 'Invoke-AutoRemediateHorizonAgentRestart: exit 0' ($r.Exit -eq 0) "exit $($r.Exit)"
Assert 'Invoke-AutoRemediateHorizonAgentRestart: Status SkippedNotInstalled' ((Get-Val "$AgentKey\Restart" 'Status') -eq 'SkippedNotInstalled')
Assert 'Invoke-AutoRemediateHorizonAgentRestart: no scheduled task' ($null -eq (Get-ScheduledTask -TaskName 'WS1_HorizonAgentRestart' -ErrorAction SilentlyContinue))
Assert 'Invoke-AutoRemediateHorizonAgentRestart: no payload persisted' (-not (Test-Path 'C:\ProgramData\AirWatch\Extensions\VDI\Horizon\Invoke-AutoRemediateHorizonAgentRestart.ps1'))

# -- Scalar sensors, not-installed cache --
$sensorExpect = @{
    'hzn_agent_health_score' = '-1'; 'hzn_agent_health_reason' = 'NotInstalled'; 'hzn_agent_clone_type' = 'Unknown'
    'hzn_client_health_score' = '-1'; 'hzn_client_health_reason' = 'NotInstalled'; 'hzn_client_connect_failure_count_24h' = '-1'
}
foreach ($s in $sensorExpect.Keys) {
    $r = Invoke-Child (Join-Path $Root "Sensors\$s.ps1")
    $exp = $sensorExpect[$s]
    Assert "sensor ${s}: one line = '$exp'" ($r.Output.Count -eq 1 -and $r.Output[0] -eq $exp) "got [$($r.Output -join '|')]"
}

# -- One-time sensors --
# Schema 2 compact keys (SPEC 7.1 / 7.2 rev 2).
$agentKeys = 'Schema,Comp,At,Ms,TO,Inst,Ver,Root,Score,Reason,Next,Detail,Svc,SvcRun,SvcMode,Blast,BlastRun,Feat,FeatStop,Fw,FwOff,Udp,Up,Clone,Pers,SyncH,Sess,Disc,DiscMin,BSess,Rtt,Loss,Bw,Fps,Tcp,CSet,PSess,PRtt,PLoss,Brk,BrkList,BrkSrc,BrkDns,BrkTcp,BrkRes,BrkMs,Err,Errs,S,Rel,Ded'.Split(',')
$clientKeys = 'Schema,Comp,At,Ms,TO,Inst,Ver,Root,Score,Reason,Next,Detail,Dir,User,Usb,UsbRun,Srv,SrvList,SrvSrc,SrvDns,Srv443,BlastPort,BlastProbed,Res,PMs,Cert,Log,LogRes,Fail24,Ok24,LastAt,LastSrv,LastProto,Rel,Ded'.Split(',')
foreach ($o in @(@{ Name = 'hzn_agent_health'; Keys = $agentKeys }, @{ Name = 'hzn_client_health'; Keys = $clientKeys })) {
    $r = Invoke-Child (Join-Path $Root "OneTimeSensor\$($o.Name).ps1")
    Assert "$($o.Name): one line" ($r.Output.Count -eq 1) "lines $($r.Output.Count)"
    $j = $null; try { $j = $r.Output[0] | ConvertFrom-Json } catch { }
    Assert "$($o.Name): valid JSON" ($null -ne $j)
    if ($j) {
        $present = @($j.PSObject.Properties.Name)
        $missing = @($o.Keys | Where-Object { $present -notcontains $_ })
        Assert "$($o.Name): every contracted key present" ($missing.Count -eq 0) "missing [$($missing -join ',')]"
        $nulls = @($j.PSObject.Properties | Where-Object { $null -eq $_.Value } | ForEach-Object Name)
        Assert "$($o.Name): no null values" ($nulls.Count -eq 0) "nulls [$($nulls -join ',')]"
        Assert "$($o.Name): Inst false, NotInstalled, Score -1" ($j.Inst -eq $false -and $j.Reason -eq 'NotInstalled' -and $j.Score -eq -1)
        Assert "$($o.Name): under 1,000 bytes" ($r.Output[0].Length -le 1000) "$($r.Output[0].Length) bytes"
        Assert "$($o.Name): under 25 s" ($j.Ms -lt 25000) "$($j.Ms) ms"
    }
}

# -- Seeded cache: every scalar sensor returns what the collector wrote --
$agentSeed = @{ Version = '2406.1.0'; HealthScore = '55.0'; HealthReason = 'BrokerUnreachable'; SessionCount = '3'; DisconnectedSessionCount = '1'
                BlastRttMsMax = '48.6'; BlastPacketLossPpmMax = '1200'; BlastTcpFallbackSessions = '-1'; CloneType = 'InstantClone'; LastClientName = 'L-JDOE-01' }
$clientSeed = @{ Version = '2406.0.5'; HealthScore = '65'; HealthReason = 'RepeatedConnectFailures'; ConnectFailureCount24h = '7'; LastConnectTime = '2026-11-03T08:15:00' }
foreach ($k in $agentSeed.Keys) { Set-ItemProperty -Path $AgentKey -Name $k -Value $agentSeed[$k] -Type String }
Set-ItemProperty -Path $AgentKey -Name 'FaultPresentAtBoot' -Value 1 -Type DWord
foreach ($k in $clientSeed.Keys) { Set-ItemProperty -Path $ClientKey -Name $k -Value $clientSeed[$k] -Type String }
$seedExpect = @{
    'hzn_agent_health_score' = '55'; 'hzn_agent_health_reason' = 'BrokerUnreachable;ImageFault'; 'hzn_agent_clone_type' = 'InstantClone'
    'hzn_client_health_score' = '65'; 'hzn_client_health_reason' = 'RepeatedConnectFailures'; 'hzn_client_connect_failure_count_24h' = '7'
}
foreach ($s in $seedExpect.Keys) {
    $r = Invoke-Child (Join-Path $Root "Sensors\$s.ps1")
    Assert "seeded sensor ${s} = '$($seedExpect[$s])'" ($r.Output.Count -eq 1 -and $r.Output[0] -eq $seedExpect[$s]) "got [$($r.Output -join '|')]"
}
Set-ItemProperty -Path $AgentKey -Name 'FaultPresentAtBoot' -Value 0 -Type DWord
$r = Invoke-Child (Join-Path $Root 'Sensors\hzn_agent_health_reason.ps1')
Assert 'hzn_agent_health_reason without boot fault: no suffix' ($r.Output.Count -eq 1 -and $r.Output[0] -eq 'BrokerUnreachable') "got [$($r.Output -join '|')]"

# -- Cleanup and report --
Remove-Item -Path 'HKLM:\Software\AirWatch\Extensions\VDI\Horizon' -Recurse -Force -ErrorAction SilentlyContinue
$pass = @($results | Where-Object Pass).Count; $fail = @($results | Where-Object { -not $_.Pass }).Count
Write-Host "`n  Passed: $pass   Failed: $fail`n"
if (-not (Test-Path $ReportRoot)) { New-Item -ItemType Directory -Path $ReportRoot -Force | Out-Null }
$file = Join-Path $ReportRoot "$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
[ordered]@{ Machine = $env:COMPUTERNAME; RanAt = (Get-Date).ToString('o'); Passed = $pass; Failed = $fail; Results = $results } | ConvertTo-Json -Depth 4 | Set-Content -Path $file -Encoding UTF8
Write-Host "  [Result] $file`n"
if ($fail -gt 0) { exit 1 }
exit 0
