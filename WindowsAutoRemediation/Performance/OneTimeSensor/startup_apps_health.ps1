#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : startup_apps_health
    Data Type    : String (one compressed JSON object, under Hub's 1 KB sensor value cap)
    Architecture : Any (x86/x64/ARM64)
    Context      : System (reports on the console user; under a user context, on that user)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-06 (1.0.0)
    Timeout      : One-time / run-once sensor only. Self-enforced budget 25 s. MUST NOT be
                   scheduled as a recurring sensor (it mines the Shell-Core log).

    The on-demand companion of Disable-NonEssentialStartupApps.ps1 2.0.0: the same
    evidence (Shell-Core 9707/9708 launch times over 14 days, target present, signer,
    StartupApproved state) and the same decision rules, as a JSON summary and without
    changing anything. "Verdict" per entry is what the script would do: disable, report,
    off (already disabled by the user), ok.

    Keys: Schema, User, Collected, ElapsedMs, TimedOut, LogonsSampled (most logons any
    entry was timed over), Entries, Enabled, UserDisabled, Missing (target gone),
    SlowThirdParty (would be disabled), SlowMicrosoft (reported), MachineFlagged (HKLM
    entries missing or slow, admin review), RecentStartupMs (sum of each enabled entry's
    most recent launch time, user and machine: how long Explorer spent launching startup
    apps at the last logon, since it runs them one after another), Slowest, SlowestMs,
    Score (100 - 15 per missing - 20 per slow third-party - 10 per slow Microsoft - 5 per
    flagged machine entry, floor 0), Reason (largest deduction: Healthy, MissingTarget,
    SlowThirdParty, SlowMicrosoft, SlowMachineEntry), NextStep (AUTO = run the script,
    USER = Task Manager > Startup apps, ADMIN = machine entry, NONE), Detail, and Top
    (up to 5 entries, slowest first: N name, S signer, Ms median launch, X target exists,
    V verdict). Top rows are dropped from the end until the JSON fits in 1,000 bytes.
    Sentinels: -1 unknown. ThresholdMs defaults to 10000 (script variable SlowThresholdMs).

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

$ErrorActionPreference = 'SilentlyContinue'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$LookbackDays = 14
$ThresholdMs  = 10000
if ("$env:SlowThresholdMs" -match '^\d{3,6}$') { $ThresholdMs = [int]$env:SlowThresholdMs }
$NeverDisable = '(?i)airwatch|omnissa|workspace ?one|vmware|horizon|citrix|defender|securityhealth|crowdstrike|sentinel|carbon ?black|cylance|sophos|mcafee|trellix|symantec|tanium|intune|zscaler|globalprotect|cisco|okta|duo'

try {
    # -- User --
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $sid = $identity.User.Value; $user = $identity.Name
    if ($identity.IsSystem) {
        $user = (Get-CimInstance Win32_ComputerSystem).UserName
        if (-not $user) { Write-Output '{"Schema":1,"User":"","Score":-1,"Reason":"NoConsoleUser","NextStep":"NONE","Entries":-1}'; return }
        $sid = (New-Object System.Security.Principal.NTAccount($user)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    }
    $profilePath = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid").ProfileImagePath
    $hive = "Registry::HKEY_USERS\$sid"
    $approvedRoot = "$hive\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved"
    $userVars = @{ USERPROFILE = $profilePath; APPDATA = "$profilePath\AppData\Roaming"; LOCALAPPDATA = "$profilePath\AppData\Local"; TEMP = "$profilePath\AppData\Local\Temp"; TMP = "$profilePath\AppData\Local\Temp" }

    function Resolve-Cmd {
        param([string]$Data)
        $d = $Data.Trim()
        if ($d -match '^"([^"]+)"(.*)$') { $exe = $matches[1]; $rest = '"' + $matches[2] }
        elseif ($d -match '^(\S+\.(exe|com|bat|cmd))(.*)$') { $exe = $matches[1]; $rest = $matches[3] }
        elseif ($d -match '^(\S+)(.*)$') { $exe = $matches[1]; $rest = $matches[2] } else { $exe = $d; $rest = '' }
        $leaf = $exe.Substring($exe.LastIndexOf('\') + 1)
        $full = $exe
        foreach ($k in $userVars.Keys) { if ($profilePath) { $full = [regex]::Replace($full, "%$k%", [regex]::Escape($userVars[$k]).Replace('\\', '\'), 'IgnoreCase') } }
        $full = [Environment]::ExpandEnvironmentVariables($full)
        if ($full -match '%[^%\s]+%') { $full = $null }
        elseif ($full -notmatch '^[A-Za-z]:\\|^\\\\') { $full = @("$env:windir\System32\$full", "$env:windir\$full") | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1 }
        $exists = $false; $ready = $false
        if ($full) { $root = [System.IO.Path]::GetPathRoot($full); $ready = [bool]$root -and (Test-Path -LiteralPath $root); $exists = Test-Path -LiteralPath $full -PathType Leaf }
        @{ Exe = $full; Exists = $exists; Ready = $ready; Cmd = ($leaf + $rest).Trim() }
    }
    function Get-Signer {
        param([string]$Path, [bool]$Exists)
        if (-not $Exists) { return 'missing' }
        if ($Path -match '\\WindowsApps\\([^\\]+?)_([a-z0-9]{13})\\') { if ($matches[2] -eq '8wekyb3d8bbwe') { return 'Microsoft pkg' } else { return "pkg $($matches[1])" } }
        try { $s = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop } catch { return 'unreadable' }
        if ($s.Status -ne 'Valid') { return 'unsigned' }
        $cn = ($s.SignerCertificate.Subject -replace '^CN=([^,]+).*', '$1').Trim('"')
        if ($cn -match '^Microsoft (Corporation|Windows)') { return 'Microsoft' }
        if ($cn.Length -gt 18) { $cn = $cn.Substring(0, 18) }
        return $cn
    }
    function Get-Median { param([int[]]$V) $s = @($V | Sort-Object); $n = $s.Count; if (-not $n) { return -1 }; if ($n % 2) { return $s[[int](($n - 1) / 2)] }; return [int](($s[$n / 2 - 1] + $s[$n / 2]) / 2) }

    # -- Launch samples (Shell-Core 9707 -> 9708, oldest first) --
    $samples = @{}
    $reader = $null
    try {
        $q = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery('Microsoft-Windows-Shell-Core/Operational', [System.Diagnostics.Eventing.Reader.PathType]::LogName, "*[System[(EventID=9707 or EventID=9708) and TimeCreated[timediff(@SystemTime) <= $($LookbackDays * 86400000)]]]")
        $reader = New-Object System.Diagnostics.Eventing.Reader.EventLogReader($q)
        $open = @{}
        while ($null -ne ($e = $reader.ReadEvent())) {
            $cmd = $null
            foreach ($p in $e.Properties) { if ("$($p.Value)" -notmatch '^\d+$') { $cmd = "$($p.Value)".Trim() } }
            if (-not $cmd) { continue }
            if ($e.Id -eq 9707) { $open[$cmd] = $e.TimeCreated }
            elseif ($open.ContainsKey($cmd)) {
                if (-not $samples.ContainsKey($cmd)) { $samples[$cmd] = New-Object System.Collections.Generic.List[int] }
                $samples[$cmd].Add([int]($e.TimeCreated - $open[$cmd]).TotalMilliseconds); $open.Remove($cmd)
            }
            if ($sw.Elapsed.TotalSeconds -gt 20) { break }
        }
    } catch { } finally { if ($reader) { $reader.Dispose() } }

    # -- Entries --
    $entries = @()
    $sources = @(
        @{ Key = "$hive\Software\Microsoft\Windows\CurrentVersion\Run";             Scope = 'User';    Appr = 'Run' },
        @{ Key = "$hive\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"; Scope = 'User';    Appr = 'Run32' },
        @{ Key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run';             Scope = 'Machine'; Appr = '' },
        @{ Key = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Scope = 'Machine'; Appr = '' })
    foreach ($src in $sources) {
        $k = Get-Item -LiteralPath $src.Key
        if (-not $k) { continue }
        foreach ($name in $k.GetValueNames()) {
            if ($name -eq '') { continue }
            $r = Resolve-Cmd -Data "$($k.GetValue($name, '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames))"
            $ms = @(); if ($samples.ContainsKey($r.Cmd)) { $ms = @($samples[$r.Cmd]) }
            $state = 'Enabled'
            if ($src.Appr) { $a = Get-Item -LiteralPath "$approvedRoot\$($src.Appr)"; $v = if ($a) { $a.GetValue($name) } else { $null }; if ($v -and $v.Length -ge 1 -and (($v[0] -band 0x0F) -eq 3)) { $state = 'Disabled' } }
            $signer = Get-Signer -Path $r.Exe -Exists $r.Exists
            $entries += [pscustomobject]@{ Name = $name; Scope = $src.Scope; Exe = $r.Exe; Exists = $r.Exists; Ready = $r.Ready; Signer = $signer; N = $ms.Count; Median = (Get-Median -V $ms); Last = $(if ($ms.Count) { $ms[-1] } else { -1 }); State = $state; Protected = ("$name $($r.Exe) $signer" -match $NeverDisable); V = 'ok' }
        }
    }
    $startup = Join-Path $profilePath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
    if ($profilePath -and (Test-Path -LiteralPath $startup)) {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($f in @(Get-ChildItem -LiteralPath $startup -File | Where-Object { $_.Name -ne 'desktop.ini' })) {
            $t = $f.FullName; $a = ''
            if ($f.Extension -eq '.lnk') { $sc = $shell.CreateShortcut($f.FullName); $t = $sc.TargetPath; $a = $sc.Arguments }
            $r = if ($t) { Resolve-Cmd -Data ('"' + $t + '" ' + $a) } else { @{ Exe = $null; Exists = $false; Ready = $false } }
            $state = 'Enabled'
            $ap = Get-Item -LiteralPath "$approvedRoot\StartupFolder"; $v = if ($ap) { $ap.GetValue($f.Name) } else { $null }; if ($v -and $v.Length -ge 1 -and (($v[0] -band 0x0F) -eq 3)) { $state = 'Disabled' }
            $signer = Get-Signer -Path $r.Exe -Exists $r.Exists
            $entries += [pscustomobject]@{ Name = $f.Name; Scope = 'User'; Exe = $r.Exe; Exists = $r.Exists; Ready = $r.Ready; Signer = $signer; N = 0; Median = -1; Last = -1; State = $state; Protected = ("$($f.Name) $($r.Exe) $signer" -match $NeverDisable); V = 'ok' }
        }
    }

    # -- Decisions (same rules as Disable-NonEssentialStartupApps.ps1 2.0.0) --
    $userE = @($entries | Where-Object { $_.Scope -eq 'User' })
    foreach ($e in $userE) {
        if ($e.State -eq 'Disabled') { $e.V = 'off'; continue }
        $slow = ($e.Exists -and $e.N -ge 2 -and $e.Median -ge $ThresholdMs)
        if ($e.Exe -and -not $e.Exists -and $e.Ready) { $e.V = 'disable' }
        elseif ($slow -and $e.Signer -notlike 'Microsoft*' -and -not $e.Protected) { $e.V = 'disable' }
        elseif ($slow) { $e.V = 'report' }
    }
    $missing  = @($userE | Where-Object { $_.V -eq 'disable' -and -not $_.Exists }).Count
    $slow3p   = @($userE | Where-Object { $_.V -eq 'disable' -and $_.Exists }).Count
    $slowMs   = @($userE | Where-Object { $_.V -eq 'report' }).Count
    $machineF = @($entries | Where-Object { $_.Scope -eq 'Machine' -and (($_.Exe -and -not $_.Exists -and $_.Ready) -or ($_.N -ge 2 -and $_.Median -ge $ThresholdMs)) })
    foreach ($e in $machineF) { $e.V = 'report' }
    $ded = [ordered]@{ MissingTarget = 15 * $missing; SlowThirdParty = 20 * $slow3p; SlowMicrosoft = 10 * $slowMs; SlowMachineEntry = 5 * $machineF.Count }
    $score = [math]::Max(0, 100 - ($ded.Values | Measure-Object -Sum).Sum)
    $reason = 'Healthy'; $top = 0
    foreach ($k in $ded.Keys) { if ($ded[$k] -gt $top) { $top = $ded[$k]; $reason = $k } }
    $next = 'NONE'; $detail = ''
    if ($missing -or $slow3p) { $next = 'AUTO'; $detail = 'Disable-NonEssentialStartupApps.ps1 steps 1-2' }
    elseif ($slowMs) { $next = 'USER'; $detail = 'Task Manager, Startup apps: disable or accept the Microsoft entries listed' }
    elseif ($machineF.Count) { $next = 'ADMIN'; $detail = 'HKLM Run entry: fix or remove in the image or app package' }
    $timed = @($entries | Where-Object { $_.N -gt 0 })
    $slowest = $timed | Sort-Object Median -Descending | Select-Object -First 1
    $recent = ($entries | Where-Object { $_.State -ne 'Disabled' -and $_.Last -ge 0 } | Measure-Object Last -Sum).Sum
    $logons = ($entries | Measure-Object N -Maximum).Maximum

    $payload = [ordered]@{
        Schema = 1; User = "$user".Split('\')[-1]; Collected = (Get-Date -Format 's'); ElapsedMs = [int]$sw.ElapsedMilliseconds; TimedOut = ($sw.Elapsed.TotalSeconds -gt 20)
        ThresholdMs = $ThresholdMs; LogonsSampled = [int]$(if ($null -ne $logons) { $logons } else { 0 })
        Entries = $userE.Count; Enabled = @($userE | Where-Object { $_.State -ne 'Disabled' }).Count; UserDisabled = @($userE | Where-Object { $_.State -eq 'Disabled' }).Count
        Missing = $missing; SlowThirdParty = $slow3p; SlowMicrosoft = $slowMs; MachineFlagged = $machineF.Count
        RecentStartupMs = [int]$(if ($null -ne $recent) { $recent } else { -1 })
        Slowest = $(if ($slowest) { $slowest.Name } else { '' }); SlowestMs = $(if ($slowest) { $slowest.Median } else { -1 })
        Score = $score; Reason = $reason; NextStep = $next; Detail = $detail
        Top = @()
    }
    $rows = @($entries | Sort-Object @{ Expression = { $_.V -eq 'disable' }; Descending = $true }, @{ Expression = 'Median'; Descending = $true } | Select-Object -First 5 | ForEach-Object {
        $n = $_.Name; if ($n.Length -gt 24) { $n = $n.Substring(0, 24) }
        [ordered]@{ N = $n; S = $_.Signer; Ms = $_.Median; X = [bool]$_.Exists; V = $_.V }
    })
    do {
        $payload.Top = @($rows)
        $json = ConvertTo-Json -InputObject $payload -Compress -Depth 3
        if ($json.Length -le 1000 -or $rows.Count -eq 0) { break }
        $rows = @($rows | Select-Object -First ($rows.Count - 1))
    } while ($true)
    Write-Output $json
}
catch {
    Write-Output ('{{"Schema":1,"Score":-1,"Reason":"Error","NextStep":"NONE","Error":"{0}"}}' -f ($_.Exception.Message -replace '["\\]', "'"))
}
