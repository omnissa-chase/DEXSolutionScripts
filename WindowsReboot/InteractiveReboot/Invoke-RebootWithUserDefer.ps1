<#
.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# Script version for tracking. Bump here, not in the filename.
$SCRIPT_VERSION = "1.2.0.9"
# 1.2.0.9 (2026-11-04): the toast uses scenario="reminder" so it stays on screen until the user
# picks a button, instead of sliding away after the default few seconds (seen on the lab VM).
# 1.2.0.8 (2026-11-04): a stored campaign is reset after a reboot or a passed deadline, a stale
# orchestrator task (unreadable install stamp or no next run) is re-registered, and the
# orchestrator logs its decisions to RebootPrompt.log. Before this a second deployment inherited
# the first campaign's expired deadline and the July task was never replaced, so no toast showed.

# Admin modified values

# How long until machine automatically reboots
$MaxHours = 4   # Max 168 hours
# How often to notify the user
$ShowEveryMinutes = 30   # Min 30, Max 1440 minutes
# How long if a user is logged in, and a reboot is in motion, the user has to save work
$RebootCountdownSeconds = 300 # default 5 minutes
# How often the script checks conditions
$PollMinutes = 5 # how often to check reboot in seconds

# Base Paths *Not recommended to change
# Important for security allowance purposes

$BasePath = "$env:ProgramData\AirWatch\Extensions\AdvancedReboot"
$MachineKey = 'HKLM:\Software\AirWatch\Extensions\AdvancedReboot'

# ===================== INSTALL FUNCTION =====================   
Function Invoke-RebootPrompt{
[CmdletBinding(SupportsShouldProcess=$true)]
param([int]$MaxHours = 72,[int]$ShowEveryMinutes = 240,[int]$RebootCountdownSeconds = 300,[int]$PollMinutes = 15,
    [string]$BasePath = "$env:ProgramData\AirWatch\Extensions\AdvancedReboot",
    [string]$MachineKey = 'HKLM:\Software\AirWatch\Extensions\AdvancedReboot'
)
    
    $TaskPath = '\WorkspaceOneEx\'
    $TaskName = 'RebootPrompt-Orchestrator'
    # -------- Policy Limits ----------
    $MaxHours        = [math]::Max(0, [math]::Min($MaxHours, 168))
    $ShowEveryMinutes = [math]::Max(30, [math]::Min($ShowEveryMinutes, 1440))
    $RebootCountdownSeconds = [math]::Max(30, $RebootCountdownSeconds)

    # ===================== INSTALL SECTION =====================
    if (-not (Test-Path $MachineKey)) { New-Item -Path $MachineKey -Force | Out-Null }
    
    # A stored campaign is stale when the machine has rebooted since it began (the reboot it
    # asked for happened) or its deadline has passed. 1.2.0.7 compared FirstRunAt - LastBoot
    # against MaxHours, which is never true after a reboot, so a second deployment inherited
    # the first one's expired deadline and went straight to mandatory mode (seen 2026-11-04).
    $lastBootOld=$false
    $lastBoot = $(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $stored = Get-ItemProperty -Path $MachineKey -ErrorAction SilentlyContinue
    $dtFirstRunAt = $null; $dtDeadline = $null
    If($stored.FirstRunAt){ $dtFirstRunAt = $stored.FirstRunAt -as [datetime] }
    If($stored.Deadline){ $dtDeadline = $stored.Deadline -as [datetime] }
    If($stored.FirstRunAt -and -not $dtFirstRunAt){ $lastBootOld = $true }          # unreadable stamp: start over
    If($dtFirstRunAt -and $lastBoot -gt $dtFirstRunAt){ $lastBootOld = $true }
    If($dtDeadline -and $dtDeadline -lt (Get-Date)){ $lastBootOld = $true }

    # The orchestrator task is stale when its install stamp is older than MaxHours, cannot be
    # read (an earlier release wrote "yyyy:MM:dd HH:mm:ss", which never parses, so the task was
    # kept forever), or it has no next run: its repetition window has lapsed and it will never
    # fire again. Any of those means re-register.
    $taskOld=$false
    $ScheduledTask = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    If($ScheduledTask){
        $ScheduledTaskInstallDate = $null
        If($ScheduledTask.Description){ $ScheduledTaskInstallDate = $ScheduledTask.Description -as [datetime] }
        If($ScheduledTaskInstallDate){
            $taskOld=$(Get-Date).Subtract($ScheduledTaskInstallDate).TotalHours -gt $MaxHours
        } else { $taskOld = $true }
        $TaskInfo = Get-ScheduledTaskInfo -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
        If($TaskInfo -and -not $TaskInfo.NextRunTime){ $taskOld = $true }
    }

    if($MaxHours -eq 0){
        $lastBootOld = $true
        $taskOld = $true
    }
    
    if($lastBootOld){
        Write-Verbose "Removing registry key at $MachineKey."            
        # Remove Scheduled Task
        If(Test-Path $MachineKey){
            Remove-Item -Path $MachineKey -Recurse -Force | Out-Null
        }
        Write-Verbose "Removing helper scripts."           
    }
   
    if(($ScheduledTask | Measure).Count -and $taskOld){
        Write-Verbose "Orchestrator task is stale, removing it so it is re-registered."
        # Remove Scheduled Task
        Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false | Out-Null
        $ScheduledTask = $null
    }

    if (-not (Test-Path $MachineKey)){
        New-Item -Path $MachineKey -Force | Out-Null
    }

    if (-not (Get-ItemProperty -Path $MachineKey -Name FirstRunAt -ErrorAction SilentlyContinue)) {
        New-ItemProperty -Path $MachineKey -Name FirstRunAt -Value (Get-Date).ToString('o') -Force | Out-Null
        New-ItemProperty -Path $MachineKey -Name Deadline -Value (Get-Date).AddHours($MaxHours).ToString('o') -Force | Out-Null }

    If(-not (Test-Path $BasePath)){  New-Item -ItemType Directory -Path $BasePath -Force | Out-Null }
    # Write helper files from the code blocks

    Write-Verbose "Wrote helpers: $userToastPath; $countdownToastPath; $incrementDeferralPath"

    $ScheduledTask = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    If(($ScheduledTask | measure).Count -eq 0){
        # Ensure machine state exists
        $mainThreadPath = Join-Path $BasePath 'RebootMainThread.ps1'
        # Register SYSTEM Orchestrator (AtStartup + AtLogOn + Once w/ Repetition)
        $exe  = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        $args = @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$mainThreadPath`"",
            '-MaxHours', $MaxHours,
            '-ShowEveryMinutes', $ShowEveryMinutes,
            '-RebootCountdownSeconds', $RebootCountdownSeconds,
            '-PollMinutes', $PollMinutes
        ) -join ' '

        $action = New-ScheduledTaskAction -Execute $exe -Argument $args
        $tLogon = New-ScheduledTaskTrigger -AtLogOn

        $tRepeat = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddSeconds(15)) -RepetitionInterval (New-TimeSpan -Minutes $PollMinutes) -RepetitionDuration (New-TimeSpan -Hours ($MaxHours+1))
        $settings = New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable `
                        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -Priority 5 -RestartCount 3 
        $settings.CimInstanceProperties['MultipleInstances'].Value = 3  # IgnoreNew

        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount
        # $tStart,$tLogon
        $def = New-ScheduledTask -Action $action -Principal $principal -Settings $settings -Trigger @($tRepeat) -Description (Get-Date).ToString('o')
        Register-ScheduledTask -InputObject $def -TaskPath $TaskPath -TaskName $TaskName -Force | Out-Null

        #Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName | Out-Null

        Write-Verbose "Registered SYSTEM orchestrator: $TaskPath$TaskName"
        Write-Verbose "Installed. Orchestrator will run at startup, at logon, and every $PollMinutes minute(s)."
    }
    return
}


# ===================== UserToast ===================== 
$UserToastSource = {


# UserToast.ps1
[CmdletBinding(SupportsShouldProcess=$true)]
param([string]$UserId,
  [int]$MaxHours                = 72,
  [int]$ShowEveryMinutes         = 240,
  [int]$RebootCountdownSeconds = 300,
  [switch]$Force)

$ForceOverride=$false
$WhatIfOverride=$false

function Invoke-UserMessage{
[CmdletBinding(SupportsShouldProcess=$true)]
param($UserId,$MaxHours,$ShowEveryMinutes,$RebootCountdownSeconds,[switch]$Force)

$BasePath = "$env:ProgramData\AirWatch\Extensions\AdvancedReboot"

Write-Verbose "Current user is: $UserId"

# Per-user state
$Key = "HKLM:\Software\AirWatch\Extensions\AdvancedReboot\$UserId"
if (-not (Test-Path $Key)) { New-Item -Path $Key -Force | Out-Null }

function Get-State {
    $p = Get-ItemProperty -Path $Key -ErrorAction SilentlyContinue
    [ordered]@{
        StartAt        = $p.StartAt
        DeadlineAt     = $p.DeadlineAt
        LastShownAt    = $p.LastShownAt
        MaxHours        = $p.MaxHours
        ShowEveryMinutes = $p.ShowEveryMinutes
    }
}
function Set-State([hashtable]$h) {
    foreach ($k in $h.Keys) {
        if ($null -ne $h[$k]) {
            Set-ItemProperty -Path $Key -Name $k -Value $h[$k] -Force
        }
    }
}

$now = Get-Date
$s = Get-State
if (-not $s.StartAt) {
    $deadline = $now.AddHours([math]::Max(0,[math]::Min($MaxHours,168)))
    Set-State @{
        StartAt        = $now.ToString('o')
        DeadlineAt     = $deadline.ToString('o')
        LastShownAt    = (Get-Date '2000-01-01').ToString('o')
        MaxHours        = $MaxHours
        ShowEveryMinutes = $ShowEveryMinutes
    }
    $s = Get-State
} else {
    # Keep policy in sync across runs
    Set-State @{ MaxHours=$MaxHours; ShowEveryMinutes=$ShowEveryMinutes }
}

# Respect ShowEveryMinutes cadence
$last = if ($s.LastShownAt) { [datetime]::Parse($s.LastShownAt) } else { Get-Date '2000-01-01' }
$diffDeadline = $now.AddHours([math]::Max(0,[math]::Min($MaxHours,168)))
If(!$Force.IsPresent){
    $nextNotification=$last.AddMinutes([math]::Max(1,[math]::Min($ShowEveryMinutes,1440)))
    if ($nextNotification -gt $now) { Write-Verbose "Notification not available.  Next notification not until: $($nextNotification.ToString())" ; return }
}

# Mandatory if beyond deadline or deferrals >= max
$deadline  = [datetime]::Parse($s.DeadlineAt)
if($diffDeadline){
    if($diffDeadline.Subtract($deadline).TotalSeconds -lt 0){
        $deadline = $diffDeadline
        Set-State @{ Deadline = $diffDeadline.ToString("o") }
    }
}

$deferrals = If($s.Deferrals){ $s.Deferrals } Else{ 0 }
$mandatory = ($now -ge $deadline) 

$timeleft=$deadline.Subtract((Get-Date))
# Stamp that we showed now
Set-State @{ LastShownAt = $now.ToString('o') }

# --- Per-user URL protocol helpers ---
function Ensure-UrlProtocol {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(Mandatory)][string]$Scheme,[Parameter(Mandatory)][string]$Command)
    $base = "HKCU:\Software\Classes\$Scheme"
    if (-not (Test-Path $base)) { New-Item -Path $base -Force | Out-Null }
    If(!$WhatIfPreference){
        New-ItemProperty -Path $base -Name '(Default)' -Value "URL:$Scheme Protocol" -Force | Out-Null
        New-ItemProperty -Path $base -Name 'URL Protocol' -Value '' -Force | Out-Null
        $cmdKey = Join-Path $base 'shell\open\command'
        if (-not (Test-Path $cmdKey)) { New-Item -Path $cmdKey -Force | Out-Null }
        New-ItemProperty -Path $cmdKey -Name '(Default)' -Value $Command -Force | Out-Null
    }Else{
        Write-Output "What if: Performing the operation `"New Property`" on target `"Item: $base Property: (Default)`"."
        Write-Output "What if: Performing the operation `"New Property`" on target `"Item: $base Property: URL Protocol`"."
        Write-Output "What if: Performing the operation `"New Item`" on target `"$cmdKey`"."
        Write-Output "What if: Performing the operation `"New Property`" on target `"Item: $cmdKey Property: (Default)`"."
    }
}

# Explicit path to shutdown.exe ensures correct version is used
$shutdown="$env:WINDIR\System32\shutdown.exe"

# Start countdown + show confirm toast (hidden)
$rebootCmd = "`"$shutdown`" /r /t 10 /f"
Ensure-UrlProtocol -Scheme 'rebootcountdown' -Command $rebootCmd

# Cancel pending shutdown (hidden)
$abortCmd = "`"$shutdown`" /a"
Ensure-UrlProtocol -Scheme 'rebootabort' -Command $abortCmd

# Increment deferrals (hidden; no inline -Command parsing issues)
$deferCmd = 'mshta.exe "javascript:close()"'
Ensure-UrlProtocol -Scheme 'rebootlater' -Command $deferCmd 

$ToastMessage=@"
<text>Reboot available</text>
<text>A reboot is needed. You have $($timeleft.Days) days, and $($timeleft.Hours) hours until the machine will automatically reboot.</text>
"@

If($mandatory){
    # Starts the reboot countdown (force-close all apps) with given delay
    if(-not $WhatIfPreference){ 
        Start-Process -FilePath $shutdown -ArgumentList "/r /t $RebootCountdownSeconds /f" -WindowStyle Hidden
    }else{
        Write-Output "What if: Performing the operation `"Start Process`" on target `"$shutdown /r /t $RebootCountdownSeconds /f`"."
    }
$mins = [Math]::Round($RebootCountdownSeconds/60)

$ToastMessage=@"
<text>Reboot scheduled</text>
<text>Your device will reboot in $mins minute(s). Save your work.</text>
"@
}

# --- Build & show toast via WinRT (no external modules) ---
$null = [Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime]
$null = [Windows.Data.Xml.Dom.XmlDocument,Windows.Data.Xml.Dom.XmlDocument,ContentType=WindowsRuntime]
$mins=[math]::Max(1,[math]::Min($ShowEveryMinutes,1440))



$xml = @"
<toast launch="reboot-consent" scenario="reminder">
  <visual><binding template="ToastGeneric">
    $ToastMessage
  </binding></visual>
  <actions>
    <action content="Reboot now" activationType="protocol" arguments="rebootcountdown://start" hint-buttonStyle="Success"/>
    $(If(!$mandatory){'<action content="Not now"    activationType="protocol" arguments="rebootlater://defer"    hint-buttonStyle="Critical"/>'}Else{''})
  </actions>
</toast>
"@

$doc = [Windows.Data.Xml.Dom.XmlDocument]::new(); $doc.LoadXml($xml)
$appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
$WorkspaceOne=Get-StartApps | Where Name -Like "Workspace ONE Intelligent Hub" | Select Name,AppId
If(($WorkspaceOne | Measure).Count -gt 0){
    $appId = $WorkspaceOne.AppId
}

[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($doc)
}


If([string]::IsNullOrEmpty($UserId)){
    $UserId = whoami
    if($UserId -like "*System*"){
        return
    }
}

Invoke-UserMessage -UserId $UserId -MaxHours $MaxHours -ShowEveryMinutes $ShowEveryMinutes -RebootCountdownSeconds $RebootCountdownSeconds -WhatIf:$WhatIfOverride -Verbose:$VerbosePreference

}

# ===================== MainThread =====================
$MainThreadSource = {


[CmdletBinding(SupportsShouldProcess=$true)]
param([int]$MaxHours = 72, [int]$ShowEveryMinutes = 240, [int]$RebootCountdownSeconds = 300, [int]$PollMinutes = 60)

Function Invoke-MainThread{
    [CmdletBinding(SupportsShouldProcess=$true)]
    param($MaxHours = 72,$ShowEveryMinutes = 240,
        $RebootCountdownSeconds = 300, 
        $PollMinutes = 60)

    $BasePath = 'C:\ProgramData\AirWatch\Extensions\AdvancedReboot'
    $MachineKey = 'HKLM:\Software\AirWatch\Extensions\AdvancedReboot'
    $MainTaskPath = '\WorkspaceOneEx\'
    $MainTaskName = 'RebootPrompt-Orchestrator'

    function Write-Log([string]$Message) {
        $line = "$((Get-Date).ToString('o')) $Message"
        Write-Verbose $line
        try { Add-Content -Path (Join-Path $BasePath 'RebootPrompt.log') -Value $line -ErrorAction Stop } catch { }
    }

    $lastBoot = $(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $firstRunAt = (Get-ItemProperty -Path $MachineKey -ErrorAction SilentlyContinue | Select-Object "FirstRunAt" -ExpandProperty "FirstRunAt" -ErrorAction SilentlyContinue)
    $deadline = (Get-ItemProperty -Path $MachineKey -ErrorAction SilentlyContinue | Select-Object "Deadline" -ExpandProperty "Deadline" -ErrorAction SilentlyContinue)
    
    # Both values are written as ISO 8601 round-trip ('o') strings; -as [DateTime] parses that form (invariant culture) and yields $null on failure
    if($firstRunAt){ $dtFirstRunAt = $firstRunAt -as [DateTime] }
    if($deadline){ $dtDeadline = $deadline -as [DateTime] }

    if (-not (Test-Path $MachineKey)){
        New-Item -Path $MachineKey -Force | Out-Null
    }

    if (-not (Get-ItemProperty -Path $MachineKey -Name FirstRunAt -ErrorAction SilentlyContinue)) {
        New-ItemProperty -Path $MachineKey -Name FirstRunAt -Value (Get-Date).ToString('o') -Force | Out-Null 
        New-ItemProperty -Path $MachineKey -Name Deadline -Value (Get-Date).AddHours($MaxHours).ToString('o') -Force | Out-Null }

    
    # This section ensures that if the machine has rebooted after the request date/time that the 
    # main thread gets removed   
    Write-Log "Orchestrator poll: lastBoot=$($lastBoot.ToString('o')) firstRunAt=$firstRunAt deadline=$deadline"
    if($dtFirstRunAt){
        $dtDiff=$dtFirstRunAt.Subtract($lastBoot)
            if(($dtDiff.TotalMilliseconds -le 0)){
            Write-Log "Reboot has occurred since FirstRunAt; removing the orchestrator task, the campaign key and the helpers."
            # Remove Scheduled Task
            Unregister-ScheduledTask -TaskPath $MainTaskPath -TaskName $MainTaskName -Confirm:$false | Out-Null
            Write-Verbose "Removing registry key at $MachineKey."
            # Remove Scheduled Task
            Remove-Item -Path $MachineKey -Recurse -Force | Out-Null
            Write-Verbose "Removing helper scripts."           
            # Remove scripts
            $Scripts=Get-ChildItem -Path $BasePath -Filter "*.ps1"
            ForEach($Script in $Scripts){
                Remove-Item $Script.FullName -Force | Out-Null
            }
            If(-not $ForceCleanup.IsPresent){
                return         
            }
        }
    }

    $mandatoryReboot=$false
    if($dtDeadline){
        Write-Log "Time until deadline: $([int]($dtDeadline).Subtract((Get-Date)).TotalSeconds) seconds"
        $mandatoryReboot = ($dtDeadline - (Get-Date)).TotalSeconds -le 0
    }

    $SystemReboot=$false
    $quser = quser 2>$null
    if (-not $quser) {
        Write-Log "quser returned no output (no sessions)."
        if($mandatoryReboot){ $SystemReboot = $true } else { return; }
    }

    $rows = $quser | Select-Object -Skip 1 |
        ForEach-Object {
        $t = $_.Trim()
        if (-not $t) { return }
        $parts = $t -replace '^\s+','' -split '\s{2,}'
        # Expected: USERNAME | SESSIONNAME | ID | STATE | IDLE TIME | LOGON TIME
        if ($parts.Count -ge 4) {
            [pscustomobject]@{
                USERNAME    = $parts[0]
                SESSIONNAME = $parts[1]
                ID          = $parts[2]
                STATE       = $parts[3]
                RAW         = $_
            }
        }
        }

    $activeUsers = $rows | Where-Object { $_.STATE -eq 'Active' -and $_.USERNAME }

    if (-not $activeUsers) { Write-Log "No active user sessions."; 
        if($mandatoryReboot){ $SystemReboot = $true } else { return }
    }

    if($SystemReboot){
        Write-Log "Deadline passed with no active session; restarting through shutdown.exe /r /t 10 /f."
        Start-Process -FilePath "C:\Windows\System32\shutdown.exe" -ArgumentList "/r /t 10 /f" -WindowStyle Hidden
        return
    }


    foreach ($UserRecord in @($activeUsers)) {
        # Some hosts mark current user with a leading '>' — remove if present
        $user = $UserRecord.USERNAME -replace '^>',''
        try {
            $exe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
            $userToastPath = Join-Path $BasePath 'UserToast.ps1'
        
            $args = @(
                '-WindowStyle', 'Hidden',
                '-NoProfile','-ExecutionPolicy','Bypass',
                '-File', ('"{0}"' -f $userToastPath),
                '-MaxHours', $MaxHours,
                '-ShowEveryMinutes', $ShowEveryMinutes,
                '-RebootCountdownSeconds', $RebootCountdownSeconds
            ) -join ' '

            $A = New-ScheduledTaskAction -Execute $exe -Argument $args
            $S = New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable -Priority 5 -AllowStartIfOnBatteries
            $S.CimInstanceProperties['MultipleInstances'].Value = 3  # IgnoreNew
            $P = New-ScheduledTaskPrincipal -UserId $user -RunLevel Highest -LogonType Interactive 
            $T = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) 

            $oneShot = "RebootPrompt-Toast-$([guid]::NewGuid().ToString('N'))"
            $D = New-ScheduledTask -Action $A -Trigger $T -Principal $P -Settings $S
            Register-ScheduledTask -InputObject $D -TaskPath $MainTaskPath -TaskName $oneShot -Force | Out-Null
            Start-ScheduledTask -TaskPath $MainTaskPath -TaskName $oneShot
            Start-Sleep -Seconds 10
            Unregister-ScheduledTask -TaskPath $MainTaskPath -TaskName $oneShot -Confirm:$false
            Write-Log "Toast task launched for $user (mandatory=$mandatoryReboot)."
        } catch {
            Write-Log "Failed to show toast for $user`: $($_.Exception.Message)"
        }
    }
    return
}

Invoke-MainThread -MaxHours $MaxHours -ShowEveryMinutes $ShowEveryMinutes -RebootCountdownSeconds $RebootCountdownSeconds -PollMinutes $PollMinutes -Verbose -WhatIf:$WhatIfPreference        
}

# -------- Paths to write helpers ----------
$userToastPath = Join-Path $BasePath 'UserToast.ps1'
$mainThreadPath = Join-Path $BasePath 'RebootMainThread.ps1'
Set-Content -Path $userToastPath -Value $UserToastSource -Encoding UTF8 -Force
Set-Content -Path $mainThreadPath -Value $MainThreadSource -Encoding UTF8 -Force

Invoke-RebootPrompt -MaxHours $MaxHours -ShowEveryMinutes $ShowEveryMinutes -RebootCountdownSeconds $RebootCountdownSeconds -PollMinutes $PollMinutes