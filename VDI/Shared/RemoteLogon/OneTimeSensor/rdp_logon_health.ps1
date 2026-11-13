#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : rdp_logon_health
    Data Type    : String
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-12
    Timeout      : < 25 seconds, self-enforced (registry first, event logs last)
    Requires     : nothing. One-time / run-once sensor. MUST NOT be scheduled recurring.

    "Why can nobody sign in to this machine over Remote Desktop?" in one on-demand pull.
    Works on any Windows device reached over RDP: AVD and Windows 365 session hosts,
    Horizon and Citrix hosts, RDS, and VMs reached through Bastion. Returns one compressed
    JSON line under 1,000 bytes: whether RDP is enabled and listening, the two remote
    logon rights (read from the LSA policy store, no process launched), PKU2U and join
    state, refused and successful remote logons by status code, the AVD agent's own health
    check report when the agent is present, a 0-100 score, the leading reason, and which
    script to run next.

    Keys: Schema, Comp, At, Ms, TO, Score, Reason, Next, Detail,
      Rdp (1 enabled / 0 disabled), DenyPol (policy value), Lsn (listener enabled), Nla, SL,
      Entra, Dom, Pku (AllowOnlineID; -1 absent = default on), Fw (profiles that ignore inbound rules),
      DenyR (population-wide entries in the deny right), AllowMiss (default entries missing from the allow right),
      UR (1 rights read / 0 not readable), RDU (Remote Desktop Users member count),
      Ref (refused remote logons, lookback), Ref15B (refused for rights), RefS ([status, count] rows),
      RefU (users refused for rights with no successful remote logon since), Ok (successful remote logons), OkAt, Auth (RCM 1149 count), AuthAt,
      Avd (agent present), AvdReg, AvdChk (health checks not passing), AvdChkAt,
      CertD (days until the RDP certificate expires), Up (minutes), Ded ([reason, points] rows).
    Sentinels: -1 unknown, -2 not applicable, -4 timed out. No nulls.
    Reasons and points: RdpDisabled 40, LogonDeniedByRight 40, ListenerDisabled 30,
      AllowRightMissingDefaults 30, PkuDisabled 30, RefusedForRights 25, AgentCheckFailing 20,
      FirewallIgnoresRules 15, BadCredentials 10, RdpCertExpired 10.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
try {
    $ErrorActionPreference = 'SilentlyContinue'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $BudgetMs = 22000; $LookbackHours = 48; $MaxEvents = 400; $BadCredWarn = 5
    $Blocking = @{ 'S-1-5-113' = 'LocalAccount'; 'S-1-5-114' = 'LocalAdmin'; 'S-1-1-0' = 'Everyone'; 'S-1-5-11' = 'AuthUsers'
                   'S-1-5-32-545' = 'Users'; 'S-1-5-32-544' = 'Admins'; 'S-1-5-32-555' = 'RDUsers' }
    function Cut([string]$s, [int]$n) { if ($null -eq $s) { return '' }; $s = ($s -replace '\s+', ' ').Trim(); if ($s.Length -gt $n) { return $s.Substring(0, $n) }; return $s }
    function V($p, $n) { $x = (Get-ItemProperty -Path $p -Name $n).$n; if ($null -eq $x) { return -1 }; return [int]$x }
    function Ev([string]$Log, [string]$Q, [int]$Max) {
        $out = New-Object System.Collections.Generic.List[object]
        try {
            $eq = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery($Log, [System.Diagnostics.Eventing.Reader.PathType]::LogName, $Q)
            $eq.ReverseDirection = $true
            $r = New-Object System.Diagnostics.Eventing.Reader.EventLogReader($eq)
            while ($out.Count -lt $Max -and $sw.ElapsedMilliseconds -lt $BudgetMs -and ($null -ne ($e = $r.ReadEvent()))) { $out.Add([pscustomobject]@{ At = $e.TimeCreated; PV = @($e.Properties | ForEach-Object { $_.Value }) }) }
            $r.Dispose()
        } catch { return $null }
        return , $out.ToArray()
    }

    $o = [ordered]@{ Schema = 2; Comp = 'RemoteLogon'; At = (Get-Date -Format 's'); Ms = 0; TO = $false; Score = -1; Reason = ''; Next = 'NONE'; Detail = '' }

    # -- Phase 1: registry --
    $ts = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    $denyLive = V $ts 'fDenyTSConnections'
    $o.DenyPol = V 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' 'fDenyTSConnections'
    $o.Rdp = if ($denyLive -eq 1 -or $o.DenyPol -eq 1) { 0 } elseif ($denyLive -eq 0) { 1 } else { -1 }
    $avd = Test-Path 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent'
    $lsn = -1
    if ($avd) { $lsn = 0; foreach ($w in @(Get-ChildItem "$ts\WinStations" | Where-Object { $_.PSChildName -match '^rdp-sxs' })) { if ((V $w.PSPath 'fEnableWinStation') -eq 1) { $lsn = 1 } } }
    else { $e1 = V "$ts\WinStations\RDP-Tcp" 'fEnableWinStation'; if ($e1 -ge 0) { $lsn = $e1 } }
    $o.Lsn = $lsn
    $o.Nla = V "$ts\WinStations\RDP-Tcp" 'UserAuthentication'
    $o.SL = V "$ts\WinStations\RDP-Tcp" 'SecurityLayer'
    $o.Entra = [int](@(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo').Count -gt 0)
    $o.Dom = [int]([string](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters').Domain -ne '')
    $o.Pku = V 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\pku2u' 'AllowOnlineID'
    $fw = 0
    foreach ($root in 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy', 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall') {
        foreach ($prof in 'DomainProfile', 'StandardProfile', 'PublicProfile') { if ((V "$root\$prof" 'DoNotAllowExceptions') -eq 1 -and (V "$root\$prof" 'EnableFirewall') -ne 0) { $fw++ } }
    }
    $o.Fw = $fw

    # -- Phase 2: remote logon rights from the LSA policy store (SYSTEM can read it; no secedit) --
    # Each account key's ActSysAc default value is a bitmask: 0x400 allow remote interactive, 0x800 deny remote interactive.
    $denyR = @(); $allowSids = @(); $ur = 0
    $acc = 'HKLM:\SECURITY\Policy\Accounts'
    foreach ($a in @(Get-ChildItem $acc)) {
        $ur = 1
        $b = $null; try { $b = (Get-Item "$($a.PSPath)\ActSysAc").GetValue('') } catch { }
        if ($b -and $b.Length -ge 4) {
            $m = [BitConverter]::ToUInt32($b, 0); $sid = $a.PSChildName
            if ($m -band 0x800) { if ($Blocking.ContainsKey($sid)) { $denyR += $Blocking[$sid] } elseif ($sid -match '^S-1-5-21-.*-513$') { $denyR += 'DomainUsers' } }
            if ($m -band 0x400) { $allowSids += $sid }
        }
    }
    $o.UR = $ur
    $o.DenyR = @($denyR)
    $o.AllowMiss = @(if ($ur) { @(@{ 'S-1-5-32-544' = 'Admins'; 'S-1-5-32-555' = 'RDUsers' }.GetEnumerator() | Where-Object { $allowSids -notcontains $_.Key } | ForEach-Object { $_.Value } | Sort-Object) })
    $rdu = -1; try { $rdu = @(([ADSI]'WinNT://./Remote Desktop Users,group').psbase.Invoke('Members')).Count } catch { }
    $o.RDU = $rdu

    # -- Phase 3: AVD agent's own health report --
    $o.Avd = [int]$avd; $o.AvdReg = -2; $o.AvdChk = @(); $o.AvdChkAt = ''
    if ($avd) {
        $o.AvdReg = V 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent' 'IsRegistered'
        $hp = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent\HealthCheckReport'
        $rep = $null; try { $rep = [string]$hp.AgentHealthCheckReport | ConvertFrom-Json } catch { }
        if ($rep) {
            # HealthCheckResult: 1 = passed, 8 = not applicable (seen on a healthy host); anything else is reported.
            $o.AvdChk = @($rep.PSObject.Properties | Where-Object { @(1, 8) -notcontains [int]$_.Value.HealthCheckResult } | ForEach-Object { ($_.Name -replace 'HealthCheck$|Check$', '') + ':' + [int]$_.Value.HealthCheckResult } | Select-Object -First 5)
            # The agent writes this stamp in UTC as "M/d/yyyy h:mm:ss tt"; normalise it to ISO 8601.
            $ts = [string]$hp.AgentHealthCheckTimestamp; $dt = [datetime]::MinValue
            if ([datetime]::TryParse($ts, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dt)) { $o.AvdChkAt = $dt.ToString('yyyy-MM-ddTHH:mm:ss') + 'Z' } else { $o.AvdChkAt = Cut $ts 22 }
        }
    }
    $cd = -1
    $c = @(Get-ChildItem 'Cert:\LocalMachine\Remote Desktop' | Sort-Object NotAfter -Descending | Select-Object -First 1)
    if ($c.Count) { $cd = [int]($c[0].NotAfter - (Get-Date)).TotalDays }
    $o.CertD = $cd
    $o.Up = [int]([Diagnostics.Stopwatch]::GetTimestamp() / [Diagnostics.Stopwatch]::Frequency / 60)

    # -- Phase 4: event logs (most expensive, last) --
    $since = (Get-Date).AddHours(-$LookbackHours).ToUniversalTime().ToString('o'); $t = "TimeCreated[@SystemTime>='$since']"
    $o.Ref = -4; $o.Ref15B = -4; $o.RefS = @(); $o.RefU = @(); $o.Ok = -4; $o.OkAt = ''; $o.Auth = -4; $o.AuthAt = ''
    $bad = 0; $refUsers = @{}
    if ($sw.ElapsedMilliseconds -lt $BudgetMs) {
        $f = Ev 'Security' "*[System[EventID=4625 and $t] and EventData[Data[@Name='LogonType']='10']]" $MaxEvents
        if ($null -eq $f) { $o.Ref = -1; $o.Ref15B = -1 } else {
            $st = @{}; $us = @{}
            foreach ($e in $f) {
                $k = '0x{0:X8}' -f [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$e.PV[7]), 0); $st[$k] = 1 + [int]$st[$k]
                if ($k -eq '0xC000015B' -and $e.PV[5] -and -not $us.ContainsKey([string]$e.PV[5])) { $us[[string]$e.PV[5]] = $e.At }
            }
            $o.Ref = $f.Count; $o.Ref15B = [int]$st['0xC000015B']
            $bad = [int]$st['0xC000006D'] + [int]$st['0xC000006A'] + [int]$st['0xC0000064']
            $rs = New-Object System.Collections.Generic.List[object]; foreach ($x in @($st.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 4)) { $rs.Add(@([string]$x.Key, [int]$x.Value)) }; $o.RefS = $rs.ToArray()
            $refUsers = $us
        }
    }
    if ($sw.ElapsedMilliseconds -lt $BudgetMs) {
        $k = Ev 'Security' "*[System[EventID=4624 and $t] and EventData[Data[@Name='LogonType']='10']]" 50
        if ($null -eq $k) { $o.Ok = -1 } else {
            $o.Ok = $k.Count; if ($k.Count) { $o.OkAt = $k[0].At.ToString('s') }
            # A user whose refusal was followed by a successful remote logon is no longer locked out.
            foreach ($e in $k) { $u = [string]$e.PV[5]; if ($u -and $refUsers.ContainsKey($u) -and $e.At -gt $refUsers[$u]) { $refUsers.Remove($u) } }
        }
    }
    if ($sw.ElapsedMilliseconds -lt $BudgetMs) {
        $a = Ev 'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational' "*[System[EventID=1149 and $t]]" 100
        if ($null -eq $a) { $o.Auth = -1 } else { $o.Auth = $a.Count; if ($a.Count) { $o.AuthAt = $a[0].At.ToString('s') } }
    }
    $o.RefU = @($refUsers.Keys | Select-Object -First 3 | ForEach-Object { Cut $_ 24 })
    if ($sw.ElapsedMilliseconds -ge $BudgetMs) { $o.TO = $true }

    # -- Phase 5: score --
    $ded = New-Object System.Collections.Generic.List[object]
    if ($o.Rdp -eq 0) { $ded.Add(@('RdpDisabled', 40)) }
    if ($o.DenyR.Count -gt 0) { $ded.Add(@('LogonDeniedByRight', 40)) }
    if ($o.Lsn -eq 0) { $ded.Add(@('ListenerDisabled', 30)) }
    if ($o.AllowMiss.Count -gt 0) { $ded.Add(@('AllowRightMissingDefaults', 30)) }
    if ($o.Entra -eq 1 -and $o.Pku -eq 0) { $ded.Add(@('PkuDisabled', 30)) }
    if ($o.RefU.Count -gt 0 -and $o.DenyR.Count -eq 0 -and $o.AllowMiss.Count -eq 0) { $ded.Add(@('RefusedForRights', 25)) }
    if ($o.AvdChk.Count -gt 0) { $ded.Add(@('AgentCheckFailing', 20)) }
    if ($o.Fw -gt 0 -and -not $avd) { $ded.Add(@('FirewallIgnoresRules', 15)) }
    if ($bad -ge $BadCredWarn) { $ded.Add(@('BadCredentials', 10)) }
    if ($o.CertD -ne -1 -and $o.CertD -lt 0) { $ded.Add(@('RdpCertExpired', 10)) }
    $score = 100; foreach ($d in $ded) { $score -= $d[1] }; if ($score -lt 0) { $score = 0 }
    $o.Score = $score
    $o.Reason = if ($ded.Count) { [string]$ded[0][0] } else { 'Healthy' }
    $o.Ded = $ded.ToArray()
    $next = @{
        RdpDisabled               = @('ADMIN', 'Remote Desktop is switched off (fDenyTSConnections); if DenyPol is 1 a policy sets it')
        LogonDeniedByRight        = @('AUTO', 'Invoke-AutoRemediateRdpLogonRights.ps1 step 1 with ConfirmHighImpact; fix the baseline or GPO first if one is still assigned')
        ListenerDisabled          = @('ADMIN', 'RDP listener WinStation is disabled; AVD: session host remediation, stack listener step')
        AllowRightMissingDefaults = @('AUTO', 'Invoke-AutoRemediateRdpLogonRights.ps1 step 2')
        PkuDisabled               = @('ADMIN', 'PKU2U online identities are disabled (AllowOnlineID 0); Entra sign-in over RDP cannot work')
        RefusedForRights          = @('ADMIN', 'refused user is in no allowed group; add to Remote Desktop Users or grant Virtual Machine User Login')
        AgentCheckFailing         = @('ADMIN', 'AVD agent health check(s) failing: see AvdChk; session host remediation')
        FirewallIgnoresRules      = @('ADMIN', 'a firewall profile blocks all inbound connections including allowed rules')
        BadCredentials            = @('USER', 'repeated bad user name or password; check the account and the sign-in name format')
        RdpCertExpired            = @('ADMIN', 'the Remote Desktop certificate has expired; restart TermService to regenerate it')
    }
    if ($next.ContainsKey($o.Reason)) { $o.Next = $next[$o.Reason][0]; $o.Detail = $next[$o.Reason][1] }
    $o.Ms = [int]$sw.ElapsedMilliseconds

    $json = $o | ConvertTo-Json -Compress -Depth 4
    foreach ($trim in 'RefU', 'AvdChk', 'RefS', 'Ded', 'Detail', 'AvdChkAt') {
        if ([Text.Encoding]::UTF8.GetByteCount($json) -lt 1000) { break }
        if ($o[$trim] -is [string]) { $o[$trim] = '' } else { $o[$trim] = @() }
        $json = $o | ConvertTo-Json -Compress -Depth 4
    }
    Write-Output $json
    return
} catch {
    Write-Output '{"Schema":2,"Comp":"RemoteLogon","Score":-1,"Reason":"CollectionError","Next":"NONE","Detail":""}'
    return
}
