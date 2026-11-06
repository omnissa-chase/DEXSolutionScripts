<#
.SYNOPSIS
    Disable-NonEssentialStartupApps -- Disables the logged-on user's startup entries that
    Windows' own evidence shows are broken or slow, and reports every entry with the facts.

.DESCRIPTION
    No app-name lists. Each Run entry and Startup-folder shortcut of the console user is
    judged on what the device records about it:

      Launch time   Shell-Core/Operational events 9707 (Explorer starts a Run command) and
                    9708 (that command is ready, or Explorer gave up waiting at about 30 s),
                    last 14 days. Explorer launches the entries one after another, so a slow
                    entry delays every entry behind it and the desktop itself. The event
                    carries the executable name plus its arguments, which is what this
                    script matches on.
      Target        Whether the executable the entry points at still exists on a drive
                    that is present (uninstaller leftovers), after per-user variables
                    (%USERPROFILE%, %APPDATA%, %LOCALAPPDATA%) are expanded for that user.
      Signer        Authenticode signer of the target; packaged apps by package family
                    (8wekyb3d8bbwe = Microsoft).
      Approval      HKU\<SID>\...\Explorer\StartupApproved: byte 0 = 3 means the user (or
                    an admin) already disabled it; such entries are never touched.

    Actions:
      Disabled   target missing on a present drive; or median launch time at or above the
                 threshold over at least two logons, target not Microsoft-signed, not a
                 security or management agent.
      Reported   slow Microsoft-signed entries (OneDrive, Teams), slow protected agents,
                 machine-wide HKLM Run entries. Warning only; nothing is changed.
      Left       everything else, listed with its facts.

    Disabling writes the same StartupApproved record Task Manager writes (03 + FILETIME),
    so the entry stays visible and the user can turn it back on from Task Manager; nothing
    is deleted. The change takes effect at the next logon. Under SYSTEM the console user's
    hive is reached through HKEY_USERS by SID; with nobody logged on the script exits 0.

.NOTES
    Script Name  : Disable-NonEssentialStartupApps.ps1
    Version      : 2.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : System (works on the console user's hive) or User
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-06
    Timeout      : 60 seconds

    Script variables (UEM environment variables), all optional:
      SlowThresholdMs   Median launch time that counts as slow. Default 10000.
      WhatIf            true | false  Default false; report the decisions, change nothing.

    Exit codes: 0 = done (including when entries were disabled); 1 = a disable failed.

    Reports to HKLM\Software\AirWatch\Extension\DEXRecords\StartupApps: counts, this run's
    DisabledCount, SlowestEntry, one Entry_<name> value per entry with its facts, and a
    Step value for every step that warned, failed or remediated.

    2.0.0: evidence-based rewrite. 1.x matched value names against built-in gaming, media
    and utility lists by substring (itch matched Twitch, Steam matched SteamVR), deleted
    the Run values and shortcuts outright, had no WhatIf and exited 1 on the run that
    fixed things. 1.0.2 fixed the SYSTEM path reading SYSTEM's own hive.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

$ErrorActionPreference = 'Stop'
$SCRIPT_VERSION  = '2.0.0'
$LookbackDays    = 14
$SlowThresholdMs = 10000
if ("$env:SlowThresholdMs" -match '^\d{3,6}$') { $SlowThresholdMs = [int]$env:SlowThresholdMs }
$whatIf = "$env:WhatIf" -match '^(?i)(true|1|yes)$'
# Security and management agents are never disabled, however slow; matched on name, target and signer.
$NeverDisable = '(?i)airwatch|omnissa|workspace ?one|vmware|horizon|citrix|defender|securityhealth|crowdstrike|sentinel|carbon ?black|cylance|sophos|mcafee|trellix|symantec|tanium|intune|zscaler|globalprotect|cisco|okta|duo'
$regPath = 'HKLM:\Software\AirWatch\Extension\DEXRecords\StartupApps'

Write-Output "`r`n-- Disable-NonEssentialStartupApps $SCRIPT_VERSION ----------------------------"

# -- Resolve the user -----------------------------------------------------------
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$sid = $identity.User.Value; $targetUser = $identity.Name
if ($identity.IsSystem) {
    $consoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if ([string]::IsNullOrEmpty($consoleUser)) {
        Write-Output "  No interactive user is logged on; per-user startup entries cannot be evaluated. Nothing to do."
        exit 0
    }
    try { $sid = (New-Object System.Security.Principal.NTAccount($consoleUser)).Translate([System.Security.Principal.SecurityIdentifier]).Value }
    catch { Write-Output "  Could not resolve the SID for console user '$consoleUser': $($_.Exception.Message)"; exit 1 }
    $targetUser = $consoleUser
}
$profilePath = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction SilentlyContinue).ProfileImagePath
if (-not (Test-Path "Registry::HKEY_USERS\$sid") -or [string]::IsNullOrEmpty($profilePath)) {
    Write-Output "  Hive or profile path for '$targetUser' is not available (hive not loaded). Nothing to do."
    exit 0
}
$userHive      = "Registry::HKEY_USERS\$sid"
$approvedRoot  = "$userHive\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved"
$startupFolder = Join-Path $profilePath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
$userVars = @{ USERPROFILE = $profilePath; APPDATA = "$profilePath\AppData\Roaming"; LOCALAPPDATA = "$profilePath\AppData\Local"; TEMP = "$profilePath\AppData\Local\Temp"; TMP = "$profilePath\AppData\Local\Temp" }

# -- Helpers --------------------------------------------------------------------
function Expand-UserPath {
    # Per-user variables from the target user's profile, then the machine's; $null if any remain.
    param([string]$Text)
    foreach ($k in $userVars.Keys) { $Text = [regex]::Replace($Text, "%$k%", [regex]::Escape($userVars[$k]).Replace('\\', '\'), 'IgnoreCase') }
    $Text = [Environment]::ExpandEnvironmentVariables($Text)
    if ($Text -match '%[^%\s]+%') { return $null }
    return $Text
}

function Resolve-StartupCommand {
    # Splits a Run value into executable and arguments; returns Exe (full path or $null when it
    # cannot be resolved), Exists, DriveReady, and EventCommand (what Shell-Core 9707 logs:
    # the executable's file name followed by the rest of the command line).
    param([string]$Data)
    $d = $Data.Trim()
    if ($d -match '^"([^"]+)"(.*)$')           { $exe = $matches[1]; $rest = '"' + $matches[2] }
    elseif ($d -match '^(\S+\.(exe|com|bat|cmd))(.*)$') { $exe = $matches[1]; $rest = $matches[3] }
    elseif ($d -match '^(\S+)(.*)$')           { $exe = $matches[1]; $rest = $matches[2] }
    else { $exe = $d; $rest = '' }
    $leaf = $exe.Substring($exe.LastIndexOf('\') + 1)
    $full = Expand-UserPath $exe
    $exists = $false; $driveReady = $false
    if ($full) {
        if ($full -notmatch '^[A-Za-z]:\\|^\\\\') {
            # Bare name: System32 and Windows, as CreateProcess would find it.
            $hit = @("$env:windir\System32\$full", "$env:windir\$full") | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
            if ($hit) { $full = $hit } else { $full = $null }
        }
        if ($full) {
            $root = [System.IO.Path]::GetPathRoot($full)
            $driveReady = [bool]$root -and (Test-Path -LiteralPath $root)
            $exists = Test-Path -LiteralPath $full -PathType Leaf
        }
    }
    return @{ Exe = $full; Exists = $exists; DriveReady = $driveReady; EventCommand = ($leaf + $rest).Trim() }
}

function Get-SignerClass {
    # 'Microsoft', 'Microsoft (packaged)', 'Packaged <family>', '<signer CN>', 'Unsigned', 'Unreadable', 'Missing'.
    param([string]$Path, [bool]$Exists)
    if (-not $Exists) { return 'Missing' }
    if ($Path -match '\\WindowsApps\\([^\\]+?)_([a-z0-9]{13})\\') {
        if ($matches[2] -eq '8wekyb3d8bbwe') { return 'Microsoft (packaged)' }
        return "Packaged $($matches[1])"
    }
    try {
        $s = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        if ($s.Status -ne 'Valid') { return 'Unsigned' }
        $cn = $s.SignerCertificate.Subject -replace '^CN=([^,]+).*', '$1'
        if ($cn -match '^Microsoft (Corporation|Windows)') { return 'Microsoft' }
        return $cn.Trim('"')
    } catch { return 'Unreadable' }
}

function Get-LaunchSamples {
    # Command -> list of milliseconds from each 9707/9708 pair in the lookback window, oldest first.
    $samples = @{}
    $reader = $null
    try {
        $xpath = "*[System[(EventID=9707 or EventID=9708) and TimeCreated[timediff(@SystemTime) <= $($LookbackDays * 86400000)]]]"
        $q = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery('Microsoft-Windows-Shell-Core/Operational', [System.Diagnostics.Eventing.Reader.PathType]::LogName, $xpath)
        $reader = New-Object System.Diagnostics.Eventing.Reader.EventLogReader($q)
        $open = @{}
        while ($null -ne ($e = $reader.ReadEvent())) {
            $cmd = $null
            foreach ($p in $e.Properties) { if ("$($p.Value)" -notmatch '^\d+$') { $cmd = "$($p.Value)".Trim() } }
            if (-not $cmd) { continue }
            if ($e.Id -eq 9707) { $open[$cmd] = $e.TimeCreated }
            elseif ($open.ContainsKey($cmd)) {
                if (-not $samples.ContainsKey($cmd)) { $samples[$cmd] = New-Object System.Collections.Generic.List[int] }
                $samples[$cmd].Add([int]($e.TimeCreated - $open[$cmd]).TotalMilliseconds)
                $open.Remove($cmd)
            }
        }
    } catch { $script:eventNote = "Shell-Core log not readable: $($_.Exception.Message)" }
    finally { if ($reader) { $reader.Dispose() } }
    return $samples
}

function Get-Median { param([int[]]$Values) $s = @($Values | Sort-Object); $n = $s.Count; if ($n -eq 0) { return $null }; if ($n % 2) { return $s[[int](($n - 1) / 2)] }; return [int](($s[$n / 2 - 1] + $s[$n / 2]) / 2) }

function Get-ApprovedState {
    # 'Enabled', 'Disabled' or 'NoRecord' (Explorer treats no record as enabled).
    param([string]$SubKey, [string]$Name)
    $k = Get-Item -LiteralPath "$approvedRoot\$SubKey" -ErrorAction SilentlyContinue
    if (-not $k) { return 'NoRecord' }
    $v = $k.GetValue($Name)
    if ($null -eq $v -or $v.Length -lt 1) { return 'NoRecord' }
    if (($v[0] -band 0x0F) -eq 3) { return 'Disabled' }
    return 'Enabled'
}

function Disable-StartupEntry {
    # Task Manager's record: byte 0 = 3 (disabled), bytes 4..11 = FILETIME of the change.
    param([string]$SubKey, [string]$Name)
    $k = "$approvedRoot\$SubKey"
    if (-not (Test-Path -LiteralPath $k)) { New-Item -Path $k -Force | Out-Null }
    $bytes = [byte[]](@(3, 0, 0, 0) + [BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc()))
    Set-ItemProperty -LiteralPath $k -Name $Name -Value $bytes -Type Binary
}

function New-StartupEntry {
    param([string]$Source, [string]$ApprovedSubKey, [string]$Name, [string]$Data, [string]$Exe, [bool]$Exists, [bool]$DriveReady, [string]$EventCommand, [hashtable]$Samples)
    $signer = Get-SignerClass -Path $Exe -Exists $Exists
    $ms = @(); if ($EventCommand -and $Samples.ContainsKey($EventCommand)) { $ms = @($Samples[$EventCommand]) }
    $approved = if ($ApprovedSubKey) { Get-ApprovedState -SubKey $ApprovedSubKey -Name $Name } else { 'n/a' }
    [pscustomobject]@{
        Source = $Source; ApprovedSubKey = $ApprovedSubKey; Name = $Name; Data = $Data; Exe = $Exe
        Exists = $Exists; DriveReady = $DriveReady; Signer = $signer
        Samples = $ms.Count; Median = (Get-Median -Values $ms); Last = $(if ($ms.Count) { $ms[-1] } else { $null })
        Approved = $approved
        Protected = ("$Name $Exe $signer" -match $NeverDisable)
        Verdict = ''; Changed = $false
    }
}

function Get-RunEntries {
    param([string]$KeyPath, [string]$Source, [string]$ApprovedSubKey, [hashtable]$Samples)
    $k = Get-Item -LiteralPath $KeyPath -ErrorAction SilentlyContinue
    if (-not $k) { return @() }
    $out = @()
    foreach ($name in $k.GetValueNames()) {
        if ($name -eq '') { continue }
        $data = "$($k.GetValue($name, '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames))"
        $r = Resolve-StartupCommand -Data $data
        $out += New-StartupEntry -Source $Source -ApprovedSubKey $ApprovedSubKey -Name $name -Data $data -Exe $r.Exe -Exists $r.Exists -DriveReady $r.DriveReady -EventCommand $r.EventCommand -Samples $Samples
    }
    return $out
}

function Get-StartupFolderEntries {
    param([hashtable]$Samples)
    if (-not (Test-Path -LiteralPath $startupFolder)) { return @() }
    $out = @(); $shell = $null
    foreach ($f in @(Get-ChildItem -LiteralPath $startupFolder -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) {
        $target = $f.FullName; $lnkArgs = ''
        if ($f.Extension -eq '.lnk') {
            try { if (-not $shell) { $shell = New-Object -ComObject WScript.Shell }; $sc = $shell.CreateShortcut($f.FullName); $target = $sc.TargetPath; $lnkArgs = $sc.Arguments } catch { $target = $null }
        }
        if ($target) { $r = Resolve-StartupCommand -Data ('"' + $target + '" ' + $lnkArgs) } else { $r = @{ Exe = $null; Exists = $false; DriveReady = $false; EventCommand = '' } }
        $out += New-StartupEntry -Source 'StartupFolder' -ApprovedSubKey 'StartupFolder' -Name $f.Name -Data "$target $lnkArgs".Trim() -Exe $r.Exe -Exists $r.Exists -DriveReady $r.DriveReady -EventCommand $r.EventCommand -Samples $Samples
    }
    return $out
}

function Format-Entry {
    param($E)
    $t = if ($E.Samples) { "{0}/{1} ms over {2}" -f $E.Median, $E.Last, $E.Samples } else { 'no launch timing' }
    $where = if ($E.Exists) { "present; $($E.Signer)" } elseif ($E.Exe) { 'MISSING' } else { 'unresolved' }
    "{0}: {1}; target {2}; {3}" -f $E.Name, $E.Approved, $where, $t
}

function Invoke-Disable {
    # Disables each entry (or reports what would be disabled); returns the engine result hashtable.
    param($Entries, [string]$Why)
    $done = @(); $errs = @()
    foreach ($e in $Entries) {
        if ($whatIf) { $e.Verdict = 'would disable'; $done += $e.Name; continue }
        try { Disable-StartupEntry -SubKey $e.ApprovedSubKey -Name $e.Name; $e.Verdict = 'disabled'; $e.Changed = $true; $done += $e.Name }
        catch { $e.Verdict = "disable FAILED: $($_.Exception.Message)"; $errs += "$($e.Name) ($($_.Exception.Message))" }
    }
    if ($errs.Count) { return @{ Remediated = ($done.Count -gt 0); Status = 'Failed'; Message = "$Why; could not disable $($errs -join ', ')" } }
    $verb = if ($whatIf) { 'would disable (WhatIf)' } else { 'disabled until the user re-enables it in Task Manager' }
    return @{ Remediated = -not $whatIf; Status = 'Passed'; Message = "$Why; $verb`: $($done -join ', ')" }
}

# -- Gather ----------------------------------------------------------------------
$script:eventNote = ''
$samples = Get-LaunchSamples
$userEntries = @()
$userEntries += Get-RunEntries -KeyPath "$userHive\Software\Microsoft\Windows\CurrentVersion\Run"             -Source 'Run'   -ApprovedSubKey 'Run'   -Samples $samples
$userEntries += Get-RunEntries -KeyPath "$userHive\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run" -Source 'Run32' -ApprovedSubKey 'Run32' -Samples $samples
$userEntries += Get-StartupFolderEntries -Samples $samples
$machineEntries = @()
$machineEntries += Get-RunEntries -KeyPath 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'             -Source 'HKLM Run'   -ApprovedSubKey '' -Samples $samples
$machineEntries += Get-RunEntries -KeyPath 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' -Source 'HKLM Run32' -ApprovedSubKey '' -Samples $samples

Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   User: $targetUser   Slow threshold: $SlowThresholdMs ms (median, $LookbackDays days)$(if ($whatIf) { '   [WhatIf]' })"
if ($script:eventNote) { Write-Output "   $script:eventNote" }
Write-Output '----------------------------------------------------------------'
Write-Output "  User entries ($($userEntries.Count)):"
foreach ($e in $userEntries)    { Write-Output "    [$($e.Source)] $(Format-Entry $e)" }
Write-Output "  Machine entries ($($machineEntries.Count), report only):"
foreach ($e in $machineEntries) { Write-Output "    [$($e.Source)] $(Format-Entry $e)" }

$active = @($userEntries | Where-Object { $_.Approved -ne 'Disabled' })
$dangling = @($active | Where-Object { $_.Exe -and -not $_.Exists -and $_.DriveReady })
$slow     = @($active | Where-Object { $_.Exists -and $_.Samples -ge 2 -and $_.Median -ge $SlowThresholdMs })
$slowAct  = @($slow | Where-Object { $_.Signer -notlike 'Microsoft*' -and -not $_.Protected })
$slowKeep = @($slow | Where-Object { $_.Signer -like 'Microsoft*' -or $_.Protected })
foreach ($e in @($userEntries | Where-Object { $_.Approved -eq 'Disabled' })) { $e.Verdict = 'already disabled, left' }
foreach ($e in $slowKeep) { $e.Verdict = $(if ($e.Protected) { 'slow, protected agent, reported' } else { 'slow, Microsoft-signed, reported' }) }

# -- Steps -----------------------------------------------------------------------
$Steps = @(
    @{
        Name = 'User entries with a missing target'; Order = 1
        DetectionScript = {
            if ($dangling.Count) { return @{ Status = 'Failed'; Message = "target no longer exists: $(($dangling | ForEach-Object { "$($_.Name) -> $($_.Exe)" }) -join '; ')" } }
            return @{ Status = 'Passed'; Message = 'every enabled entry points at a file that exists' }
        }
        ResolutionScript = { Invoke-Disable -Entries $dangling -Why 'target missing' }
    },
    @{
        Name = 'Slow non-Microsoft user entries'; Order = 2
        DetectionScript = {
            if ($slowAct.Count) { return @{ Status = 'Failed'; Message = "median launch >= $SlowThresholdMs ms: $(($slowAct | ForEach-Object { "$($_.Name) $($_.Median) ms ($($_.Signer))" }) -join '; ')" } }
            return @{ Status = 'Passed'; Message = "no non-Microsoft entry at or above $SlowThresholdMs ms median" }
        }
        ResolutionScript = { Invoke-Disable -Entries $slowAct -Why 'slow at logon' }
    },
    @{
        Name = 'Slow Microsoft or protected user entries'; Order = 3
        DetectionScript = {
            if ($slowKeep.Count) { return @{ Status = 'Warning'; Message = "left in place (Microsoft-signed or protected agent): $(($slowKeep | ForEach-Object { "$($_.Name) $($_.Median) ms" }) -join '; ')" } }
            return @{ Status = 'Passed'; Message = 'none' }
        }
        ResolutionScript = $null
    },
    @{
        Name = 'Machine Run entries (report only)'; Order = 4
        DetectionScript = {
            $bad = @($machineEntries | Where-Object { ($_.Exe -and -not $_.Exists -and $_.DriveReady) -or ($_.Samples -ge 2 -and $_.Median -ge $SlowThresholdMs) })
            if ($bad.Count) { return @{ Status = 'Warning'; Message = "admin review: $(($bad | ForEach-Object { Format-Entry $_ }) -join '; ')" } }
            return @{ Status = 'Passed'; Message = "$($machineEntries.Count) machine entries, none missing or slow" }
        }
        ResolutionScript = $null
    }
)

# -- Engine ----------------------------------------------------------------------
$results = New-Object 'System.Collections.Generic.List[PSCustomObject]'
foreach ($step in ($Steps | Sort-Object { [int]$_.Order })) {
    $status = 'Failed'; $message = 'Detection script did not return a result.'; $remediated = $false; $remError = ''
    try { $r = & $step.DetectionScript; $status = $r.Status; $message = $r.Message }
    catch { $message = "Detection exception: $($_.Exception.Message)" }
    if ($status -eq 'Failed' -and $step.ResolutionScript) {
        try {
            $rr = & $step.ResolutionScript | Select-Object -Last 1
            if ($rr -is [hashtable]) { $remediated = [bool]$rr.Remediated; if ($rr.Status) { $status = $rr.Status }; if ($rr.Message) { $message = $rr.Message } }
        } catch { $remError = $_.Exception.Message }
    }
    $note = if ($remediated) { '  -> Remediation ran' } elseif ($remError) { "  -> Remediation ERROR: $remError" } else { '' }
    Write-Output "`r`n  [$($status.PadRight(7))] $($step.Name): $message$note"
    $results.Add([PSCustomObject]@{ Order = $step.Order; Name = $step.Name; Status = $status; Message = $message; Remediated = $remediated; RemError = $remError })
}

$passed   = @($results | Where-Object { $_.Status -eq 'Passed'  }).Count
$warnings = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed   = @($results | Where-Object { $_.Status -eq 'Failed'  }).Count
$remCount = @($results | Where-Object { $_.Remediated }).Count
$changed  = @($userEntries | Where-Object { $_.Changed }).Count
Write-Output "`r`n----------------------------------------------------------------"
Write-Output "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations run: $remCount  |  Entries disabled: $changed$(if ($changed) { ' (effective at next logon)' })"
Write-Output "----------------------------------------------------------------`r`n"

# -- Registry reporting ------------------------------------------------------------
try {
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null }
    (Get-Item -Path $regPath).GetValueNames() | ForEach-Object { Remove-ItemProperty -Path $regPath -Name $_ -ErrorAction SilentlyContinue }
    Set-ItemProperty -Path $regPath -Name 'LastScanTime'    -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Type String
    Set-ItemProperty -Path $regPath -Name 'ScriptVersion'   -Value $SCRIPT_VERSION -Type String
    Set-ItemProperty -Path $regPath -Name 'TargetUser'      -Value $targetUser     -Type String
    Set-ItemProperty -Path $regPath -Name 'TotalSteps'      -Value $results.Count  -Type DWord
    Set-ItemProperty -Path $regPath -Name 'PassedCount'     -Value $passed         -Type DWord
    Set-ItemProperty -Path $regPath -Name 'WarningCount'    -Value $warnings       -Type DWord
    Set-ItemProperty -Path $regPath -Name 'FailedCount'     -Value $failed         -Type DWord
    Set-ItemProperty -Path $regPath -Name 'RemediatedCount' -Value $remCount       -Type DWord
    Set-ItemProperty -Path $regPath -Name 'EntryCount'      -Value $userEntries.Count -Type DWord
    Set-ItemProperty -Path $regPath -Name 'DisabledCount'   -Value $changed        -Type DWord
    $slowest = $userEntries + $machineEntries | Where-Object { $_.Samples } | Sort-Object Median -Descending | Select-Object -First 1
    if ($slowest) { Set-ItemProperty -Path $regPath -Name 'SlowestEntry' -Value "$($slowest.Name) $($slowest.Median) ms ($($slowest.Source))" -Type String }
    $i = 0
    foreach ($e in $userEntries) {
        if (++$i -gt 40) { break }
        $safe = ($e.Name -replace '[^A-Za-z0-9._-]', '_'); if ($safe.Length -gt 60) { $safe = $safe.Substring(0, 60) }
        $v = "$($e.Source); $(Format-Entry $e)"; if ($e.Verdict) { $v += "; $($e.Verdict)" }
        Set-ItemProperty -Path $regPath -Name "Entry_$safe" -Value $v -Type String
    }
    $results | Where-Object { $_.Status -ne 'Passed' -or $_.Remediated } | ForEach-Object {
        $tag = if ($_.Remediated) { '[Remediated]' } else { "[$($_.Status)]" }
        Set-ItemProperty -Path $regPath -Name ('Step{0:D2}_{1}' -f $_.Order, ($_.Name -replace '[^A-Za-z0-9]', '')) -Value "$tag $($_.Message)" -Type String
    }
    Write-Output "  [Registry] Results written to $regPath"
} catch {
    Write-Output "  [Registry] Write failed: $($_.Exception.Message)"
}

if ($failed -gt 0) { exit 1 }
exit 0
