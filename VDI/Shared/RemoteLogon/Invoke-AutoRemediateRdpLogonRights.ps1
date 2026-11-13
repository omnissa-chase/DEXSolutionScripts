<#
.SYNOPSIS
    Remote Desktop logon-rights remediation -- finds and clears the "host is healthy,
    password is accepted, logon is still refused" lockout.

.DESCRIPTION
    Self-targeting: acts only when the device shows the fault. The scenario is a session
    host or any Windows device reached over RDP (AVD, Windows 365, Horizon, RDS, Bastion)
    where a security baseline or GPO wrote the user-rights assignment so that remote
    logons are refused with status 0xC000015B ("the user has not been granted the
    requested logon type"). Baselines tattoo: removing the baseline does not remove the
    setting, so the lockout outlives the policy that caused it.

      1  Deny Remote Desktop Logon Right    AUTO, needs ConfirmHighImpact and refused-logon evidence
      2  Allow Remote Desktop Logon Right   AUTO   restores Administrators and Remote Desktop Users
      3  Refused Remote Logons              report by status code, with the users affected
      4  Remote Desktop Users Membership    report when rights are clean and logons are still refused
      5  Policy Reapply Check               report when a fix made by this script was undone

    Step 1 removes only the entries that lock out whole populations (Local account,
    Everyone, Authenticated Users, Users, Administrators, Remote Desktop Users, Domain
    Users). Guest and named accounts are left in place. It loosens a security setting,
    so it fails closed: without ConfirmHighImpact it reports and changes nothing. It is
    held after two fixes in 24 hours, because a setting that keeps coming back is being
    enforced by a baseline or GPO and has to be fixed there.

    Report-only steps return Warning, never Failed. Exit 1 only when a Failed step's
    fix did not run or threw. Results: HKLM:\Software\AirWatch\Extensions\VDI\Shared\RemoteLogon\Remediation.

.NOTES
    Script Name  : Invoke-AutoRemediateRdpLogonRights.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-12
    Timeout      : 30 seconds (deploy with a 60 second UEM timeout)

    Environment variables:
      WhatIf = true              Dry run. Absent/unparseable => live run.
      ConfirmHighImpact = true   Required for step 1. Absent/unparseable => step 1 reports only.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
function Invoke-AutoRemediateRdpLogonRights {
[CmdletBinding(SupportsShouldProcess = $true)]
param()

$SCRIPT_VERSION = '1.0.0'
$RegPath = 'HKLM:\Software\AirWatch\Extensions\VDI\Shared\RemoteLogon\Remediation'
$LogPath = "$env:SystemRoot\Temp\UEM_AutoRemediateRdpLogonRights.log"

# -- SETTINGS --
$EventLookbackHours          = 48
$MaxEventsScanned            = 500
$RequireRefusedLogonEvidence = $true   # step 1 acts only when 0xC000015B refusals were logged in the lookback
$MaxFixesPer24h              = 2       # then Held: something is re-applying the setting
# Entries that lock out whole populations when they sit in the deny right.
$BlockingSids = [ordered]@{
    'S-1-5-113'    = 'Local account'
    'S-1-5-114'    = 'Local account and member of Administrators group'
    'S-1-1-0'      = 'Everyone'
    'S-1-5-11'     = 'Authenticated Users'
    'S-1-5-32-545' = 'Users'
    'S-1-5-32-544' = 'Administrators'
    'S-1-5-32-555' = 'Remote Desktop Users'
}
$BlockingSidPattern = '^S-1-5-21-\d+-\d+-\d+-513$'   # Domain Users
$DefaultAllowSids   = @('S-1-5-32-544', 'S-1-5-32-555')
$StatusMeaning = @{
    '0xC000015B' = 'logon type not granted (user rights)'; '0xC000006D' = 'bad user name or password'
    '0xC000006A' = 'wrong password'; '0xC0000064' = 'no such user'; '0xC0000234' = 'account locked out'
    '0xC0000072' = 'account disabled'; '0xC000006F' = 'outside logon hours'; '0xC0000070' = 'workstation restriction'
    '0xC0000071' = 'password expired'; '0xC0000193' = 'account expired'; '0xC0000224' = 'password must change'
    '0xC0000413' = 'authentication firewall'
}

$WhatIfPreference = $false
if ($env:WhatIf) { try { $WhatIfPreference = [System.Convert]::ToBoolean($env:WhatIf) } catch { $WhatIfPreference = $false } }
$ConfirmHighImpact = $false
if ($env:ConfirmHighImpact) { try { $ConfirmHighImpact = [System.Convert]::ToBoolean($env:ConfirmHighImpact) } catch { $ConfirmHighImpact = $false } }

$RunEventId = ([Random]::new()).Next(1000, 9999)
Write-Output "[$RunEventId] Executing Invoke-AutoRemediateRdpLogonRights, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'  WhatIf=$WhatIfPreference  ConfirmHighImpact=$ConfirmHighImpact"
$HEAD = "`r`n[$RunEventId]"

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$RunEventId] [$Level] $Message" |
        Out-File -FilePath $LogPath -Append -Encoding UTF8 -WhatIf:$false -ErrorAction SilentlyContinue
}
function Res { param([string]$S, [string]$M) return @{ Status = $S; Message = $M } }

# Reads the two remote-logon rights. Returns @{ Deny = entries; Allow = entries } where each
# entry is @{ Raw = text as exported; Sid = SID string or '' }, or $null when the export failed.
function Get-RdpRights {
    $cfg = Join-Path $env:TEMP ("dexur_{0}.cfg" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        $null = & secedit.exe /export /areas USER_RIGHTS /cfg $cfg 2>&1
        if (-not (Test-Path -LiteralPath $cfg)) { return $null }
        $out = @{ Deny = @(); Allow = @() }
        foreach ($line in @(Get-Content -LiteralPath $cfg -ErrorAction Stop)) {
            if ($line -notmatch '^(SeDenyRemoteInteractiveLogonRight|SeRemoteInteractiveLogonRight)\s*=\s*(.*)$') { continue }
            $key = if ($matches[1] -eq 'SeRemoteInteractiveLogonRight') { 'Allow' } else { 'Deny' }
            $list = @()
            foreach ($raw in @($matches[2] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                $sid = ''
                if ($raw -match '^\*(S-[\d-]+)$') { $sid = $matches[1] }
                else { try { $sid = ([Security.Principal.NTAccount]$raw).Translate([Security.Principal.SecurityIdentifier]).Value } catch { $sid = '' } }
                $list += @{ Raw = $raw; Sid = $sid }
            }
            $out[$key] = $list
        }
        return $out
    }
    catch { return $null }
    finally { Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue -WhatIf:$false }
}
# Writes one user right through secedit and nothing else. $Entries are the raw strings to keep.
function Set-RdpRight {
    param([string]$Right, [string[]]$Entries)
    $id  = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inf = Join-Path $env:TEMP "dexur_$id.inf"; $db = Join-Path $env:TEMP "dexur_$id.sdb"; $lg = Join-Path $env:TEMP "dexur_$id.log"
    try {
        $text = "[Unicode]`r`nUnicode=yes`r`n[Version]`r`nsignature=`"`$CHICAGO`$`"`r`nRevision=1`r`n[Privilege Rights]`r`n$Right = $($Entries -join ',')`r`n"
        [IO.File]::WriteAllText($inf, $text, [Text.Encoding]::Unicode)
        $o = & secedit.exe /configure /db $db /cfg $inf /areas USER_RIGHTS /log $lg 2>&1
        if ($LASTEXITCODE -ne 0) { throw "secedit /configure exit $LASTEXITCODE`: $((@($o) | Select-Object -Last 1))" }
    }
    finally { Remove-Item -LiteralPath $inf, $db, $lg, "$db.jfm" -Force -ErrorAction SilentlyContinue -WhatIf:$false }
}
function Get-SidLabel { param([string]$Sid) if ($BlockingSids.Contains($Sid)) { return $BlockingSids[$Sid] }; if ($Sid -match $BlockingSidPattern) { return 'Domain Users' }; return $Sid }
function Test-Blocking { param([string]$Sid) return ($Sid -and ($BlockingSids.Contains($Sid) -or $Sid -match $BlockingSidPattern)) }

# -- Guard: nothing to do where Remote Desktop is switched off and no session-host agent is present --
$tsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$deny  = (Get-ItemProperty -Path $tsKey -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections
$isHost = (Test-Path 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent') -or (Test-Path 'HKLM:\SOFTWARE\Omnissa\Horizon\Agent') -or
          (Test-Path 'HKLM:\SOFTWARE\VMware, Inc.\VMware VDM\Agent') -or (Test-Path 'HKLM:\SOFTWARE\Citrix\VirtualDesktopAgent')
if ($deny -eq 1 -and -not $isHost) {
    Write-Output "$HEAD Remote Desktop is not enabled on this device and no session host agent is present. Nothing to process."
    Write-Log 'Remote Desktop disabled and no session host agent. Exiting.'
    exit 0
}

# -- Discovery: refused remote logons (Security 4625, logon type 10), read once for all steps --
$Script:Refused = @{}; $Script:RefusedUsers = @{}; $Script:RefusedRead = $false; $Script:Last15B = $null
try {
    $since = (Get-Date).AddHours(-$EventLookbackHours).ToUniversalTime().ToString('o')
    $q = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery('Security', [System.Diagnostics.Eventing.Reader.PathType]::LogName,
            "*[System[EventID=4625 and TimeCreated[@SystemTime>='$since']] and EventData[Data[@Name='LogonType']='10']]")
    $q.ReverseDirection = $true
    $reader = New-Object System.Diagnostics.Eventing.Reader.EventLogReader($q)
    $n = 0
    while ($n -lt $MaxEventsScanned -and ($null -ne ($e = $reader.ReadEvent()))) {
        $n++
        $p = @($e.Properties | ForEach-Object { $_.Value })
        $st = '0x{0:X8}' -f [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$p[7]), 0)
        $Script:Refused[$st] = 1 + [int]$Script:Refused[$st]
        if ($st -eq '0xC000015B') {
            $u = [string]$p[5]; if ($u) { $Script:RefusedUsers[$u] = 1 + [int]$Script:RefusedUsers[$u] }
            if (-not $Script:Last15B) { $Script:Last15B = $e.TimeCreated }
        }
    }
    $reader.Dispose(); $Script:RefusedRead = $true
} catch { Write-Log "Security log not readable: $($_.Exception.Message)" 'WARN' }
$Script:Count15B = [int]$Script:Refused['0xC000015B']

# -- Discovery: prior fixes by this script (for the cool-down and the reapply check) --
$prior = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
$Script:FixTimes = @()
if ($prior -and $prior.DenyFixTimes) { $Script:FixTimes = @([string]$prior.DenyFixTimes -split ';' | Where-Object { $_ } | ForEach-Object { try { [datetime]$_ } catch { } } | Where-Object { $_ -gt (Get-Date).AddHours(-24) }) }
$Script:Rights = Get-RdpRights
$Script:DenyFixed = $false

$Steps = @(

    @{
        Name = 'Deny Remote Desktop Logon Right'
        DetectionScript = {
            if (-not $Script:Rights) { return Res Warning 'User rights could not be exported (secedit) -- deny right not checked' }
            $Script:Blocking = @($Script:Rights.Deny | Where-Object { Test-Blocking $_.Sid })
            if ($Script:Blocking.Count -eq 0) {
                $kept = @($Script:Rights.Deny | ForEach-Object { $_.Raw }) -join ', '
                return Res Passed "Deny log on through Remote Desktop Services holds no population-wide entry$(if ($kept) { " (present: $kept)" })"
            }
            $names = (@($Script:Blocking | ForEach-Object { Get-SidLabel $_.Sid }) -join ', ')
            $base = "Deny log on through Remote Desktop Services contains: $names"
            if ($RequireRefusedLogonEvidence -and $Script:Count15B -eq 0) {
                $why = if ($Script:RefusedRead) { "no remote logon was refused for it in the last $EventLookbackHours h" } else { 'the Security log could not be read for evidence' }
                return Res Warning "$base -- left in place: $why"
            }
            if ($Script:FixTimes.Count -ge $MaxFixesPer24h) {
                return Res Warning "$base -- HELD: this script removed it $($Script:FixTimes.Count) time(s) in the last 24 h and it came back; a baseline or GPO is enforcing it, fix it there"
            }
            if (-not $ConfirmHighImpact) {
                return Res Warning "$base -- $($Script:Count15B) remote logon(s) refused because of it in the last $EventLookbackHours h; set ConfirmHighImpact = true to remove the entry (it loosens a security setting)"
            }
            return Res Failed "$base -- $($Script:Count15B) remote logon(s) refused because of it in the last $EventLookbackHours h; removing the population-wide entr$(if ($Script:Blocking.Count -eq 1) { 'y' } else { 'ies' })"
        }
        ResolutionScript = {
            $keep = @($Script:Rights.Deny | Where-Object { -not (Test-Blocking $_.Sid) } | ForEach-Object { $_.Raw })
            if ($PSCmdlet.ShouldProcess('SeDenyRemoteInteractiveLogonRight', "Remove $(@($Script:Blocking | ForEach-Object { Get-SidLabel $_.Sid }) -join ', ')")) {
                Set-RdpRight -Right 'SeDenyRemoteInteractiveLogonRight' -Entries $keep
                $after = Get-RdpRights
                if (-not $after -or @($after.Deny | Where-Object { Test-Blocking $_.Sid }).Count -gt 0) { throw 'the entry is still present after secedit /configure' }
                $Script:DenyFixed = $true
            }
        }
    },

    @{
        Name = 'Allow Remote Desktop Logon Right'
        DetectionScript = {
            if (-not $Script:Rights) { return Res Warning 'User rights could not be exported (secedit) -- allow right not checked' }
            $have = @($Script:Rights.Allow | ForEach-Object { $_.Sid })
            $Script:MissingAllow = @($DefaultAllowSids | Where-Object { $have -notcontains $_ })
            if ($Script:MissingAllow.Count -eq 0) { return Res Passed "Allow log on through Remote Desktop Services includes Administrators and Remote Desktop Users ($($have.Count) entr$(if ($have.Count -eq 1) { 'y' } else { 'ies' }))" }
            $names = (@($Script:MissingAllow | ForEach-Object { Get-SidLabel $_ }) -join ', ')
            return Res Failed "Allow log on through Remote Desktop Services is missing: $names -- members of that group cannot start a remote session; restoring the Windows default"
        }
        ResolutionScript = {
            $entries = @($Script:Rights.Allow | ForEach-Object { $_.Raw }) + @($Script:MissingAllow | ForEach-Object { "*$_" })
            if ($PSCmdlet.ShouldProcess('SeRemoteInteractiveLogonRight', "Add $(@($Script:MissingAllow) -join ', ')")) {
                Set-RdpRight -Right 'SeRemoteInteractiveLogonRight' -Entries $entries
                $after = Get-RdpRights
                $have = if ($after) { @($after.Allow | ForEach-Object { $_.Sid }) } else { @() }
                if (@($DefaultAllowSids | Where-Object { $have -notcontains $_ }).Count -gt 0) { throw 'the default entries are still missing after secedit /configure' }
            }
        }
    },

    @{
        Name = 'Refused Remote Logons'
        DetectionScript = {
            if (-not $Script:RefusedRead) { return Res Warning 'Security log not readable -- refused remote logons unknown' }
            $total = 0; foreach ($k in $Script:Refused.Keys) { $total += $Script:Refused[$k] }
            if ($total -eq 0) { return Res Passed "No refused remote logons in the last $EventLookbackHours h" }
            $parts = @($Script:Refused.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 4 | ForEach-Object {
                $m = if ($StatusMeaning.ContainsKey($_.Key)) { $StatusMeaning[$_.Key] } else { 'see NTSTATUS' }; "$($_.Value) x $($_.Key) ($m)" })
            $users = if ($Script:RefusedUsers.Count) { '; refused for rights: ' + (@($Script:RefusedUsers.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Key) ($($_.Value))" }) -join ', ') } else { '' }
            return Res Warning "$total refused remote logon(s) in the last $EventLookbackHours h: $($parts -join '; ')$users"
        }
    },

    @{
        Name = 'Remote Desktop Users Membership'
        DetectionScript = {
            $members = @()
            try { $g = [ADSI]'WinNT://./Remote Desktop Users,group'; $members = @($g.psbase.Invoke('Members') | ForEach-Object { $_.GetType().InvokeMember('Name', 'GetProperty', $null, $_, $null) }) } catch { }
            $list = if ($members.Count) { ($members | Select-Object -First 6) -join ', ' } else { '(empty)' }
            $rightsClean = ($Script:Rights -and @($Script:Rights.Deny | Where-Object { Test-Blocking $_.Sid }).Count -eq 0 -and $Script:MissingAllow.Count -eq 0)
            if ($Script:Count15B -gt 0 -and $rightsClean -and -not $Script:DenyFixed) {
                return Res Warning "Logon rights are in order but $($Script:Count15B) remote logon(s) were refused for rights -- the refused user is not in an allowed group. Remote Desktop Users: $list. On an Entra-joined host, grant the Virtual Machine User Login role instead"
            }
            return Res Passed "Remote Desktop Users: $list"
        }
    },

    @{
        Name = 'Policy Reapply Check'
        DetectionScript = {
            if (-not $prior -or -not $prior.DenyFixTimes) { return Res Passed 'No earlier fix by this script on record' }
            $last = @([string]$prior.DenyFixTimes -split ';' | Where-Object { $_ }) | Select-Object -Last 1
            if ($Script:Blocking -and $Script:Blocking.Count -gt 0 -and -not $Script:DenyFixed) {
                return Res Warning "The deny entry was removed by this script at $last and is present again -- a security baseline or GPO still assigns it; change it at the source (Workspace ONE baseline, Intune, Group Policy)"
            }
            if ($Script:DenyFixed -and $Script:FixTimes.Count -ge 1) { return Res Warning "The deny entry had been removed at $last, came back, and was removed again -- a baseline or GPO still assigns it; the next run will hold" }
            return Res Passed "Last fix by this script at $last has held"
        }
    }
)

$activeSteps = @($Steps | Where-Object { -not $_.ContainsKey('Enabled') -or $_.Enabled })
$results = [System.Collections.Generic.List[PSCustomObject]]::new()
Write-Output "`r`n-- RdpLogonRightsResolutionWizard ------------------------------"
Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)   Refused for rights ($EventLookbackHours h): $(if ($Script:RefusedRead) { $Script:Count15B } else { 'unknown' })"
Write-Output '----------------------------------------------------------------'
$i = 0
foreach ($step in $activeSteps) {
    $i++; $status = 'Failed'; $message = 'Detection script did not return a result.'; $remediated = $false; $remError = ''
    try { $r = & $step.DetectionScript; $status = $r.Status; $message = $r.Message }
    catch { $status = 'Failed'; $message = "Detection exception: $($_.Exception.Message)" }
    if ($status -eq 'Failed' -and $step.ResolutionScript) { try { & $step.ResolutionScript | Out-Null; $remediated = $true } catch { $remError = $_.Exception.Message } }
    $note = if ($remError) { "  -> Remediation ERROR: $remError" } elseif ($remediated) { '  -> Remediation ran' } else { '' }
    Write-Output "`r`n  [$($status.PadRight(7))] $($step.Name): $message$note"
    Write-Log "[$status] $($step.Name): $message$note"
    $results.Add([PSCustomObject]@{ Order = $i; Name = $step.Name; Status = $status; Remediated = ($remediated -and -not $remError); RemError = $remError })
}

$passed = @($results | Where-Object { $_.Status -eq 'Passed' }).Count
$warnings = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed = @($results | Where-Object { $_.Status -eq 'Failed' }).Count
$remCount = @($results | Where-Object { $_.Remediated }).Count
$remErrors = @($results | Where-Object { $_.RemError }).Count
$unfixed = @($results | Where-Object { $_.Status -eq 'Failed' -and -not $_.Remediated }).Count

Write-Output "`r`n----------------------------------------------------------------"
Write-Output "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations run: $remCount  |  Remediation errors: $remErrors"
Write-Output "----------------------------------------------------------------`r`n"
if ($Script:DenyFixed) { Write-Output "$HEAD The deny entry is cleared. It takes effect at the next remote logon; no restart is needed. If a baseline or GPO still assigns it, it will return at the next policy refresh." }

try {
    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop -WhatIf:$false | Out-Null }
    $times = @($Script:FixTimes | ForEach-Object { $_.ToString('s') })
    if ($Script:DenyFixed -and -not $WhatIfPreference) { $times += (Get-Date).ToString('s') }
    $stepsStr = (@($results | ForEach-Object { "$($_.Order):$($_.Status)$(if ($_.Remediated) { '+Rem' })$(if ($_.RemError) { '+Err' })" }) -join ';')
    $vals = [ordered]@{ ScriptVersion = $SCRIPT_VERSION; Status = $(if ($failed -gt 0) { 'Failed' } elseif ($warnings -gt 0) { 'Warning' } else { 'Passed' })
                        Passed = [string]$passed; Warnings = [string]$warnings; Failed = [string]$failed; RemediationsRun = [string]$remCount
                        RemediationErrors = [string]$remErrors; Steps = $stepsStr; RefusedForRights = [string]$(if ($Script:RefusedRead) { $Script:Count15B } else { -1 })
                        DenyFixTimes = ($times -join ';') }
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
Invoke-AutoRemediateRdpLogonRights
