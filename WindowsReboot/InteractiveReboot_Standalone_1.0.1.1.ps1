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
    
    $lastBootOld=$false
    $lastBoot = $(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $firstRunAt = (Get-ItemProperty -Path $MachineKey -ErrorAction SilentlyContinue | Select-Object "FirstRunAt" -ExpandProperty "FirstRunAt" -ErrorAction SilentlyContinue)
    If($firstRunAt){
        $dtFirstRunAt = [datetime]::Parse($firstRunAt) 
        $dtDiff=$dtFirstRunAt.Subtract($lastBoot)
        $lastBootOld=$dtDiff.TotalHours -gt $MaxHours
    }

    $taskOld=$false
    $ScheduledTask = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    $ScheduledTaskInstallDate = $null
    If($ScheduledTask.Description){ $ScheduledTaskInstallDate = $ScheduledTask.Description -as [datetime] }
    If($ScheduledTaskInstallDate){
        $taskOld=$(Get-Date).Subtract($ScheduledTaskInstallDate).TotalHours -gt $MaxHours
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
        Write-Verbose "Reboot has occured, removing scheduled task."            
        # Remove Scheduled Task 
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false | Out-Null
    }

    if (-not (Test-Path $MachineKey)){
        New-Item -Path $MachineKey -Force | Out-Null
    }

    if (-not (Get-ItemProperty -Path $MachineKey -Name FirstRunAt -ErrorAction SilentlyContinue)) {
        New-ItemProperty -Path $MachineKey -Name FirstRunAt -Value (Get-Date).ToString('o') -Force | Out-Null 
        New-ItemProperty -Path $MachineKey -Name Deadline -Value (Get-Date).AddHours($MaxHours) }

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
        $def = New-ScheduledTask -Action $action -Principal $principal -Settings $settings -Trigger @($tRepeat) -Description (Get-Date).ToString("yyyy:MM:dd hh:mm:ss")
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
        Write-Host "What if: Performing the operation `"New Property`" on target `"Item: $base Property: (Default)`"."
        Write-Host "What if: Performing the operation `"New Property`" on target `"Item: $base Property: URL Protocol`"."
        Write-Host "What if: Performing the operation `"New Item`" on target `"$cmdKey`"."
        Write-Host "What if: Performing the operation `"New Property`" on target `"Item: $cmdKey Property: (Default)`"."
    }
}

# Start countdown + show confirm toast (hidden)
$rebootCmd = "$shutdown=`"$env:WINDIR\System32\shutdown.exe`" /r /t 10 /f"
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
    # Explicit path to shutdown.exe ensures corret version is used
    $shutdown="$env:WINDIR\System32\shutdown.exe"

    # Starts the reboot countdown (force-close all apps) with given delay
    if(-not $WhatIfPreference){ 
        Start-Process -FilePath $shutdown -ArgumentList "/r /t $RebootCountdownSeconds /f" -WindowStyle Hidden
    }else{
        Write-Host "What if: Performing the operation `"Start Process`" on target `"$shutdown /r /t $RebootCountdownSeconds /f`"."
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
<toast launch="reboot-consent">
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
        
    $lastBoot = $(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $firstRunAt = (Get-ItemProperty -Path $MachineKey -ErrorAction SilentlyContinue | Select-Object "FirstRunAt" -ExpandProperty "FirstRunAt" -ErrorAction SilentlyContinue)
    $deadline = (Get-ItemProperty -Path $MachineKey -ErrorAction SilentlyContinue | Select-Object "Deadline" -ExpandProperty "Deadline" -ErrorAction SilentlyContinue)
    
    if($firstRunAt){ $dtFirstRunAt = $firstRunAt -as [DateTime] }
    if($deadline){ $dtDeadline = $deadline -as [DateTime] }

    if (-not (Test-Path $MachineKey)){
        New-Item -Path $MachineKey -Force | Out-Null
    }

    if (-not (Get-ItemProperty -Path $MachineKey -Name FirstRunAt -ErrorAction SilentlyContinue)) {
        New-ItemProperty -Path $MachineKey -Name FirstRunAt -Value (Get-Date).ToString('o') -Force | Out-Null 
        New-ItemProperty -Path $MachineKey -Name Deadline -Value (Get-Date).AddHours($MaxHours) | Out-Null }

    
    # This section ensures that if the machine has rebooted after the request date/time that the 
    # main thread gets removed   
    if($dtFirstRunAt){
        $dtDiff=$dtFirstRunAt.Subtract($lastBoot)
            if(($dtDiff.TotalMilliseconds -le 0)){
            Write-Verbose "Reboot has occured, removing scheduled task."            
            # Remove Scheduled Task 
            Unregister-ScheduledTask -TaskName $MainTaskName -Confirm:$false | Out-Null
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
        Write-Verbose "Time until deadline: $(($dtDeadline).Subtract((Get-Date)).TotalSeconds) seconds"
        $mandatoryReboot = ($dtDeadline - (Get-Date)).TotalSeconds -le 0
    }

    $SystemReboot=$false
    $quser = quser 2>$null
    if (-not $quser) { 
        Write-Verbose "quser returned no output."
        if($mandatoryReboot=$true){ $SystemReboot = $true } else { return; }
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
            Write-Verbose "Displayed toast for $user"
        } catch {
            Write-Verbose "Failed to show toast for $user`: $($_.Exception.Message)"
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