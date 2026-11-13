<#
.SYNOPSIS
    Restart-HungApps -- finds windowed apps in the user's session that have stopped
    responding and are idle, and ends them. Takes no input. Asynchronous: the script
    returns to Hub in a second or two and a one-shot watchdog does the work.

.DESCRIPTION
    The self-targeting counterpart to Restart-WinProcessGraceful.ps1 for use where no
    script variable can be passed. Nothing names the app; the watchdog finds it.

        Launcher (Hub, SYSTEM)  ->  Watchdog (Task Scheduler, the logged-on user, once)

    A window's responsiveness can only be measured from the session that owns it, so
    the launcher cannot look for itself: it stages the watchdog, starts it once in the
    user's session and exits. The watchdog:

      1. Checks every windowed process in its session. If all of them answer, it
         writes NoHungApps and ends (about a second). This is the normal case.
      2. Watches the ones that do not answer for $HungAfterSeconds. One that answers
         again was slow, not hung, and is left alone (Recovered).
      3. Sorts what is still not answering:
           Busy      it used CPU while not answering (a long recalculation, a large
                     file load): working, not hung. Left alone.
           Denied    on the deny list (remote-session clients, shell hosts, security
                     UI). Left alone.
           Held      this script already ended it $MaxRecoveriesPerCooldown times in
                     $CooldownHours h. It keeps hanging; ending it is not the fix.
           Deferred  over the $MaxAppsPerRun cap for one run.
           Ended     not answering and idle for the whole watch: the process is
                     ended, as the user would do from Task Manager. A hung Explorer
                     shell is ended and started again.
    Unsaved work in an app that is truly hung is already lost; the watch, the CPU
    test and the deny list exist so that a slow app is never taken for a hung one.

    The exit code reflects DISPATCH only. The outcome is in
    %ProgramData%\AirWatch\Extensions\HungApps\state\result.json (and watchdog.log);
    the next launcher run prints it and mirrors it into DEXRecords as LastResult*
    values. With nobody logged on there is nothing to measure and the script exits 0.

.NOTES
    Script Name  : Restart-HungApps.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : System (the watchdog runs as the logged-on user, Limited)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-12
    Timeout      : 60 seconds (the launcher takes 1-2 s; the watchdog is detached)
    Reporting    : HKLM:\Software\AirWatch\Extension\DEXRecords\HungApps
                   %ProgramData%\AirWatch\Extensions\HungApps\state\result.json

    No input. Settings are the constants in the SETTINGS block. Optional environment
    variables: WhatIf (true = report what would be ended, end nothing) and Mode
    (Inline = run the watchdog in this process, lab only).
    Requires an AV/EDR exclusion on %ProgramData%\AirWatch\Extensions\HungApps.

    Limits: only the console (or first Explorer-owning) user's session is checked;
    packaged (UWP) apps share ApplicationFrameHost and are not judged; a hung app
    running elevated cannot be ended by the Limited watchdog and is reported as Error.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# ==============================================================================
# SETTINGS -- edit here; there are no script variables
# ==============================================================================
$MaxAppsPerRun            = 2      # apps ended in one run; the rest are Deferred
$HungAfterSeconds         = 60     # continuous seconds without an answer before an app counts as hung
$PollSeconds              = 2      # pause between checks during the watch
$BusyCpuPercent           = 10     # average % of one core during the watch at or above which the app is Busy, not hung
$CooldownHours            = 24     # window for the per-app limit below
$MaxRecoveriesPerCooldown = 2      # after this many in the window the app is Held
$RelaunchApps             = $false # $true starts an ended app again from its own path
$RestartExplorer          = $true  # a hung Explorer shell is ended and started again; $false leaves it alone

# Process names (no .exe), wildcards allowed. Never ended, only reported.
$DenyList = @(
    # shell hosts and system UI (ending these takes other windows with them)
    'ApplicationFrameHost','ShellExperienceHost','StartMenuExperienceHost','SearchHost','SearchApp',
    'TextInputHost','SystemSettings','sihost','ctfmon','dwm','LockApp','LogonUI','Taskmgr',
    # credential and security UI
    'consent','CredentialUIBroker','SecurityHealth*','MsMpEng','SecHealthUI',
    # remote-session clients: a stalled network looks like a hang and ends the user's session
    'mstsc','msrdc','vmware-view','horizon-client','vmware-remotemks','wfica32','CDViewer','SelfService',
    # management agents and installers
    'AWACMClient','AirWatch*','IntelligentHub','VMwareHub*','msiexec','setup','TiWorker','TrustedInstaller'
)

# ==============================================================================
$SCRIPT_VERSION = '1.0.0'
$TaskName    = 'WS1_HungAppsWatchdog'
$BaseDir     = Join-Path $env:ProgramData 'AirWatch\Extensions\HungApps'
$StateDir    = Join-Path $BaseDir 'state'
$WatchdogPs1 = Join-Path $BaseDir 'Watch-HungApps.ps1'
$StateFile   = Join-Path $StateDir 'state.json'
$ResultFile  = Join-Path $StateDir 'result.json'
$RegPath     = 'HKLM:\Software\AirWatch\Extension\DEXRecords\HungApps'
$RunEventId  = ([Random]::new()).Next(1000,9999)
$HEAD        = "[$RunEventId]"
$whatIf      = "$env:WhatIf" -match '^(?i)(true|1|yes)$'
$Mode        = if ("$env:Mode" -match '^(?i)inline$') { 'Inline' } else { 'Detached' }

function Set-DexRecord {
    param([hashtable]$Values)
    try {
        if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop | Out-Null }
        foreach ($k in $Values.Keys) { Set-ItemProperty -Path $RegPath -Name $k -Value ([string]$Values[$k]) -Type String -ErrorAction Stop }
    } catch { Write-Output "$HEAD Registry write skipped: $($_.Exception.Message)" }
}

Write-Output "$HEAD Executing Restart-HungApps, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'$(if ($whatIf) { ' [WhatIf]' })"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Output "$HEAD Error: this script must run elevated (SYSTEM under Hub) to stage and start the watchdog."
    exit 1
}

# -- The previous run's outcome: print it and mirror it (the user-token watchdog cannot write HKLM) --
try {
    if (Test-Path $ResultFile) {
        $prev = Get-Content -Path $ResultFile -Raw -ErrorAction Stop | ConvertFrom-Json
        Write-Output "$HEAD Previous watchdog run ($($prev.CompletedAt)): $($prev.Status); ended $($prev.EndedCount), busy $($prev.BusyCount), recovered $($prev.RecoveredCount), held $($prev.HeldCount), denied $($prev.DeniedCount), errors $($prev.ErrorCount)."
        foreach ($a in @($prev.Apps)) { Write-Output "$HEAD   $($a.Name) (PID $($a.Id)): $($a.Outcome). $($a.Detail)" }
        $seen = (Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue).LastResultCompletedAt
        if ($prev.CompletedAt -and [string]$prev.CompletedAt -ne [string]$seen) {
            $m = @{}
            foreach ($k in 'Status','CompletedAt','CheckedCount','EndedCount','BusyCount','RecoveredCount','HeldCount','DeniedCount','DeferredCount','ErrorCount','Summary') { $m["LastResult$k"] = [string]$prev.$k }
            Set-DexRecord $m
        }
    }
} catch { }

# -- Whose session? Console user first, else the owner of an Explorer shell (RDP, VDI) --
$isSystem = [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem
$user = $null
try { $user = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName } catch { }
if (-not $user) {
    try {
        $ex = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($ex) {
            $o = Invoke-CimMethod -InputObject $ex -MethodName GetOwner -ErrorAction SilentlyContinue
            if ($o -and $o.User) { $user = "$($o.Domain)\$($o.User)" }
        }
    } catch { }
}
if ($Mode -eq 'Inline') {
    if ($isSystem) { Write-Output "$HEAD Inline mode cannot measure windows from SYSTEM; run it from the user's own elevated prompt."; exit 1 }
} elseif (-not $user) {
    Write-Output "$HEAD Nobody is logged on, so there are no app windows to check. Nothing to do."
    Set-DexRecord @{ LastRunTime = (Get-Date -Format 'o'); Status = 'NoUser' }
    exit 0
}

# -- A watchdog from an earlier dispatch still at work is left to finish --
if ($Mode -eq 'Detached') {
    $old = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($old -and "$($old.State)" -eq 'Running') {
        Write-Output "$HEAD The watchdog from an earlier run is still watching an app. Not dispatched again."
        exit 0
    }
}

# -- Watchdog source (single-quoted: everything resolves when the watchdog runs) --
$WatchdogSource = @'
<#  Watch-HungApps.ps1 -- GENERATED by Restart-HungApps.ps1 on every dispatch. DO NOT EDIT.
    Runs once in the user's session: finds windowed apps that do not answer, watches
    them, ends the ones that stay silent and idle. Writes state\result.json. #>
$StateDir    = Join-Path $PSScriptRoot 'state'
$StateFile   = Join-Path $StateDir 'state.json'
$ResultFile  = Join-Path $StateDir 'result.json'
$HistoryFile = Join-Path $StateDir 'history.json'
$LogFile     = Join-Path $StateDir 'watchdog.log'

function Write-Log {
    param([string]$Message)
    try { "$(Get-Date -Format 'o')  $Message" | Out-File -FilePath $LogFile -Append -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
}
function Test-Gone { param([int]$Id) try { return ($null -eq (Get-Process -Id $Id -ErrorAction SilentlyContinue)) } catch { return $true } }

$state = $null
try { $state = Get-Content -Path $StateFile -Raw -ErrorAction Stop | ConvertFrom-Json }
catch { Write-Log "FATAL: cannot read state file. $($_.Exception.Message)"; exit 1 }

$apps = @(); $status = 'Completed'; $checked = 0
$whatIf = [bool]$state.WhatIf
$mySession = [Diagnostics.Process]::GetCurrentProcess().SessionId

# Recovery history: { "<process name>": [ ISO timestamps ] }, entries inside the cool-down only.
$history = @{}
try {
    if (Test-Path $HistoryFile) {
        $cutoff = (Get-Date).AddHours(-[int]$state.CooldownHours)
        $raw = Get-Content -Path $HistoryFile -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($prop in $raw.PSObject.Properties) {
            $kept = @()
            foreach ($s in @($prop.Value)) {
                try { $t = [datetime]::Parse("$s", $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { continue }
                if ($t -ge $cutoff) { $kept += $t.ToString('o') }
            }
            if ($kept.Count -gt 0) { $history[$prop.Name] = $kept }
        }
    }
} catch { Write-Log "History unreadable, starting empty: $($_.Exception.Message)" }

function Test-Denied {
    param([string]$Name)
    foreach ($d in @($state.DenyList)) { if ($Name -like $d) { return $true } }
    return $false
}

# Windowed processes of this session that do not answer. Emits the processes one by one.
function Get-SilentApps {
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        try {
            if ($p.SessionId -ne $mySession -or $p.Id -eq $PID) { continue }
            if ($p.MainWindowHandle -eq [IntPtr]::Zero) { continue }
            $script:checked++
            if ($p.Responding) { continue }
            # Windows suspends idle packaged apps (Settings, Calculator); a suspended
            # process cannot answer and is not hung. Every thread suspended = suspended.
            $th = @($p.Threads)
            $susp = @($th | Where-Object { "$($_.ThreadState)" -eq 'Wait' -and "$($_.WaitReason)" -eq 'Suspended' })
            if ($th.Count -gt 0 -and $susp.Count -eq $th.Count) { continue }
            $p
        } catch { }
    }
}

try {
    Write-Log "Start. Session=$mySession HungAfter=$($state.HungAfterSeconds)s WhatIf=$whatIf"
    $silent = @(Get-SilentApps)
    if ($silent.Count -eq 0) {
        $status = 'NoHungApps'
        Write-Log "All $checked windowed app(s) answer. Nothing to do."
    } else {
        $t0 = Get-Date
        foreach ($p in $silent) {
            $cpu0 = $null; $path = ''; $title = ''
            try { $cpu0 = $p.TotalProcessorTime } catch { }
            try { $path = [string]$p.Path } catch { }
            try { $title = [string]$p.MainWindowTitle } catch { }
            $apps += [PSCustomObject]@{ Proc = $p; Id = $p.Id; Name = $p.Name; Title = $title; Path = $path; Cpu0 = $cpu0; Outcome = 'Watching'; Detail = '' }
            Write-Log "PID $($p.Id) [$($p.Name)] '$title' does not answer. Watching."
        }

        $deadline = $t0.AddSeconds([int]$state.HungAfterSeconds)
        while ((Get-Date) -lt $deadline -and @($apps | Where-Object { $_.Outcome -eq 'Watching' }).Count -gt 0) {
            Start-Sleep -Seconds ([int]$state.PollSeconds)
            foreach ($a in @($apps | Where-Object { $_.Outcome -eq 'Watching' })) {
                $secs = [int]((Get-Date) - $t0).TotalSeconds
                try {
                    $a.Proc.Refresh()
                    if ($a.Proc.HasExited) { $a.Outcome = 'Exited'; $a.Detail = "Closed by itself or by the user after $secs s."; Write-Log "PID $($a.Id) exited."; continue }
                    if ($a.Proc.Responding) { $a.Outcome = 'Recovered'; $a.Detail = "Answered again after $secs s: slow, not hung. Left alone."; Write-Log "PID $($a.Id) answers again." }
                } catch {
                    if (Test-Gone $a.Id) { $a.Outcome = 'Exited'; $a.Detail = "Closed after $secs s." }
                }
            }
        }

        $elapsed = [math]::Max(1, ((Get-Date) - $t0).TotalSeconds)
        $ended = 0
        foreach ($a in @($apps | Where-Object { $_.Outcome -eq 'Watching' } | Sort-Object Id)) {
            $label = "silent for $([int]$elapsed) s"
            $pct = $null
            try { if ($null -ne $a.Cpu0) { $a.Proc.Refresh(); $pct = [math]::Round((($a.Proc.TotalProcessorTime - $a.Cpu0).TotalSeconds / $elapsed) * 100, 1) } } catch { }
            $key = $a.Name.ToLowerInvariant()
            $past = @(); if ($history.ContainsKey($key)) { $past = @($history[$key]) }

            if (Test-Denied $a.Name) {
                $a.Outcome = 'Denied'; $a.Detail = "Not answering ($label) but on the deny list. Left alone."
            } elseif ($a.Name -eq 'explorer' -and -not [bool]$state.RestartExplorer) {
                $a.Outcome = 'Denied'; $a.Detail = "Explorer is not answering ($label); RestartExplorer is off. Left alone."
            } elseif ($null -ne $pct -and $pct -ge [double]$state.BusyCpuPercent) {
                $a.Outcome = 'Busy'; $a.Detail = "Not answering ($label) but working: $pct% of a core. Busy, not hung. Left alone."
            } elseif ($past.Count -ge [int]$state.MaxRecoveriesPerCooldown) {
                $a.Outcome = 'Held'; $a.Detail = "Not answering ($label), but already ended $($past.Count)x in the last $($state.CooldownHours) h. It keeps hanging; ending it is not the fix. Left alone."
            } elseif ($ended -ge [int]$state.MaxAppsPerRun) {
                $a.Outcome = 'Deferred'; $a.Detail = "Not answering ($label); over the $($state.MaxAppsPerRun)-per-run limit. Left for the next run."
            } elseif ($whatIf) {
                $a.Outcome = 'WouldEnd'; $a.Detail = "Not answering and idle ($label, CPU $pct%). WhatIf: not ended."
                $ended++
            } else {
                try {
                    Stop-Process -Id $a.Id -Force -ErrorAction Stop
                    try { $a.Proc.WaitForExit(5000) | Out-Null } catch { }
                    if (-not (Test-Gone $a.Id)) { throw 'the process is still running after the end request' }
                    $ended++
                    $a.Outcome = 'Ended'; $a.Detail = "Not answering and idle ($label, CPU $pct%). Process ended."
                    $history[$key] = @($past) + @((Get-Date).ToString('o'))
                    if ($a.Name -eq 'explorer') {
                        Start-Sleep -Seconds 4   # Windows normally restarts the shell itself
                        $shell = @(Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $mySession })
                        if ($shell.Count -eq 0) { Start-Process -FilePath (Join-Path $env:windir 'explorer.exe'); $a.Detail += ' Explorer started again.' }
                        else { $a.Detail += ' Windows restarted the shell.' }
                    } elseif ([bool]$state.RelaunchApps -and $a.Path) {
                        try { Start-Sleep -Seconds 2; Start-Process -FilePath $a.Path -ErrorAction Stop; $a.Detail += ' Started again.' }
                        catch { $a.Detail += " Relaunch failed: $($_.Exception.Message)" }
                    }
                } catch {
                    $a.Outcome = 'Error'; $a.Detail = "Not answering ($label) and could not be ended: $($_.Exception.Message) (an elevated app is out of this watchdog's reach)."
                }
            }
            Write-Log "PID $($a.Id) [$($a.Name)] $($a.Outcome): $($a.Detail)"
        }
    }
} catch {
    $status = 'Error'
    Write-Log "FATAL: $($_.Exception.Message)"
} finally {
    try {
        $h = [ordered]@{}; foreach ($k in $history.Keys) { $h[$k] = @($history[$k]) }
        if ($h.Count -gt 0) { [PSCustomObject]$h | ConvertTo-Json -Depth 3 | Set-Content -Path $HistoryFile -Encoding UTF8 -ErrorAction Stop }
        elseif (Test-Path $HistoryFile) { Remove-Item $HistoryFile -Force -ErrorAction SilentlyContinue }
    } catch { Write-Log "History write FAILED: $($_.Exception.Message)" }
    try {
        $count = { param($o) @($apps | Where-Object { $_.Outcome -eq $o }).Count }
        $summary = [PSCustomObject]@{
            Status         = $status
            CompletedAt    = (Get-Date -Format 'o')
            WhatIf         = $whatIf
            CheckedCount   = $checked
            EndedCount     = (& $count 'Ended')
            WouldEndCount  = (& $count 'WouldEnd')
            BusyCount      = (& $count 'Busy')
            RecoveredCount = (& $count 'Recovered') + (& $count 'Exited')
            HeldCount      = (& $count 'Held')
            DeniedCount    = (& $count 'Denied')
            DeferredCount  = (& $count 'Deferred')
            ErrorCount     = (& $count 'Error')
            Summary        = (@($apps | ForEach-Object { "$($_.Name)=$($_.Outcome)" }) -join '; ')
            Apps           = @($apps | ForEach-Object { [PSCustomObject]@{ Id = $_.Id; Name = $_.Name; Title = $_.Title; Outcome = $_.Outcome; Detail = $_.Detail } })
        }
        $summary | ConvertTo-Json -Depth 4 | Set-Content -Path $ResultFile -Encoding UTF8 -ErrorAction Stop
        Write-Log "Result written: $status checked=$checked ended=$($summary.EndedCount) busy=$($summary.BusyCount) recovered=$($summary.RecoveredCount) held=$($summary.HeldCount) errors=$($summary.ErrorCount)"
    } catch { Write-Log "Result write FAILED: $($_.Exception.Message)" }

    try { Remove-Item -Path $StateFile -Force -ErrorAction SilentlyContinue } catch { }
    try {
        if ($state.TaskName -and (Get-ScheduledTask -TaskName $state.TaskName -ErrorAction SilentlyContinue)) {
            Unregister-ScheduledTask -TaskName $state.TaskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    } catch { }
    Write-Log 'Watchdog end.'
}
exit 0
'@

# -- Stage the watchdog and its settings --
$budgetSec   = $HungAfterSeconds + 120
$taskExpires = (Get-Date).AddSeconds($budgetSec + 60)
try {
    foreach ($dir in @($BaseDir, $StateDir)) {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
    }
    # Only the state folder opens up to the user; the watchdog code stays under SYSTEM/Admins ACLs.
    if ($Mode -eq 'Detached') {
        try {
            $acl  = Get-Acl -Path $StateDir -ErrorAction Stop
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($user, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.SetAccessRule($rule)
            Set-Acl -Path $StateDir -AclObject $acl -ErrorAction Stop
        } catch { Write-Output "$HEAD Could not grant '$user' write access to the state folder: $($_.Exception.Message)" }
    }
    Set-Content -Path $WatchdogPs1 -Value $WatchdogSource -Encoding UTF8 -Force -ErrorAction Stop
    [PSCustomObject]@{
        HungAfterSeconds         = $HungAfterSeconds
        PollSeconds              = $PollSeconds
        BusyCpuPercent           = $BusyCpuPercent
        MaxAppsPerRun            = $MaxAppsPerRun
        CooldownHours            = $CooldownHours
        MaxRecoveriesPerCooldown = $MaxRecoveriesPerCooldown
        RelaunchApps             = $RelaunchApps
        RestartExplorer          = $RestartExplorer
        DenyList                 = @($DenyList)
        WhatIf                   = $whatIf
        TaskName                 = $(if ($Mode -eq 'Detached') { $TaskName } else { '' })
        DispatchedAt             = (Get-Date -Format 'o')
    } | ConvertTo-Json -Depth 3 | Set-Content -Path $StateFile -Encoding UTF8 -Force -ErrorAction Stop
} catch {
    Write-Output "$HEAD Error: could not stage the watchdog: $($_.Exception.Message)"
    Set-DexRecord @{ LastRunTime = (Get-Date -Format 'o'); Status = 'Error' }
    exit 1
}

if ($Mode -eq 'Inline') {
    Write-Output "$HEAD Running the watchdog inline (blocking; lab only)."
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $WatchdogPs1
    try {
        $r = Get-Content -Path $ResultFile -Raw -ErrorAction Stop | ConvertFrom-Json
        Write-Output "$HEAD Result: $($r.Status); checked $($r.CheckedCount), ended $($r.EndedCount). $($r.Summary)"
        foreach ($a in @($r.Apps)) { Write-Output "$HEAD   $($a.Name) (PID $($a.Id)): $($a.Outcome). $($a.Detail)" }
    } catch { Write-Output "$HEAD No result file after the inline run."; exit 1 }
    exit 0
}

# -- Hand off to Task Scheduler and return --
try {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$WatchdogPs1`""
    # Interactive: the task shares the user's desktop, so windows can be measured. Limited, not Highest.
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    # The end boundary lets Task Scheduler delete the task when the Limited watchdog cannot.
    $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5)
    $trigger.EndBoundary = $taskExpires.ToString('s')
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds $budgetSec) `
        -DeleteExpiredTaskAfter (New-TimeSpan -Minutes 1) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Trigger $trigger -Settings $settings -Force -ErrorAction Stop | Out-Null
    Write-Output "$HEAD Watchdog dispatched for $user (task '$TaskName', starts within 5 s). It ends at once when every app answers; otherwise it watches for $HungAfterSeconds s."
    Write-Output "$HEAD Outcome: $ResultFile (printed by the next run)."
} catch {
    Write-Output "$HEAD Error: could not dispatch the watchdog: $($_.Exception.Message)"
    Set-DexRecord @{ LastRunTime = (Get-Date -Format 'o'); Status = 'Error' }
    exit 1
}

Set-DexRecord @{ LastRunTime = (Get-Date -Format 'o'); Status = 'Dispatched'; WatchdogUser = $user; WhatIf = $whatIf }
exit 0
