# ---------------------------------------------------------------------------
# Resolve the currently logged-on interactive user's SID.
# Win32_ComputerSystem.UserName returns DOMAIN\username (or COMPUTER\username
# for local accounts) even when this script runs under SYSTEM context.
# ---------------------------------------------------------------------------

$BaseInstallReg="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
$loggedOnUser = (Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName

if (-not $loggedOnUser) {
    Write-Warning 'No interactive user session detected. Cannot resolve user SID.'
    exit 1
}

$ntAccount = New-Object System.Security.Principal.NTAccount($loggedOnUser)
$userSid   = $ntAccount.Translate([System.Security.Principal.SecurityIdentifier]).Value

# ---------------------------------------------------------------------------
# Resolve the user's profile path from the ProfileList registry key.
# This gives us the filesystem root for the user's startup folder without
# relying on environment variables that reflect the SYSTEM account.
# ---------------------------------------------------------------------------
$profilePath       = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$userSid" -ErrorAction SilentlyContinue).ProfileImagePath
$userStartupFolder = if ($profilePath) { Join-Path $profilePath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup' } else { $null }
$allUsersStartup   = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"

# ---------------------------------------------------------------------------
# StartupApproved keys store the enabled/disabled state for every startup
# source. Task Manager reads three sub-keys per hive:
#   Run           -- entries from the 64-bit Run registry key
#   Run32         -- entries from the 32-bit (WOW6432Node) Run key
#   StartupFolder -- entries from the startup folder (.lnk files)
# HKU paths use the Registry:: provider prefix to access the user hive by
# SID without a mapped PSDrive. HKLM paths cover machine-wide entries.
# ---------------------------------------------------------------------------
$startupApprovedPaths = @(
    "Registry::HKEY_USERS\$userSid\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
    "Registry::HKEY_USERS\$userSid\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32"
    "Registry::HKEY_USERS\$userSid\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder"
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32"
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder"
)

# Run keys: 64-bit and 32-bit (WOW6432Node) for both user and machine hives.
# The WOW6432Node key is used by 32-bit applications installing themselves
# as startup entries on 64-bit Windows.
$runPaths = @(
    @{ Path = "Registry::HKEY_USERS\$userSid\SOFTWARE\Microsoft\Windows\CurrentVersion\Run";              Scope = $loggedOnUser }
    @{ Path = "Registry::HKEY_USERS\$userSid\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"; Scope = "$loggedOnUser (32-bit)" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run";                                      Scope = 'All Users' }
    @{ Path = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run";                          Scope = 'All Users (32-bit)' }
)

# ---------------------------------------------------------------------------
# Read enabled/disabled state from all StartupApproved keys.
# Windows stores a binary value per entry: byte[0] == 2 means Enabled,
# byte[0] == 3 means Disabled (toggled off in Task Manager > Startup tab).
# ---------------------------------------------------------------------------
$states = foreach ($path in $startupApprovedPaths) {
    $key = Get-Item -Path $path -ErrorAction SilentlyContinue
    if ($key) {
        foreach ($valueName in $key.GetValueNames()) {
            $raw     = $key.GetValue($valueName)
            $enabled = ($raw[0] -eq 2)   # 2 = Enabled, 3 = Disabled
            [PSCustomObject]@{
                ID = "StartupApp:$ValueName $(If(($raw[0] -eq 2)){ "Enabled" } Else {"Disabled"} )"
                Name    = $valueName
                Enabled = $enabled
            }
        }
    }
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

# ---------------------------------------------------------------------------
# Source 1: Registry Run keys (64-bit and 32-bit, user and machine).
# Each value name is the startup entry label; the value data is the command.
# Entries absent from StartupApproved default to Enabled (legacy behavior
# predating the Task Manager Startup tab in Windows 8).
# ---------------------------------------------------------------------------
foreach ($entry in $runPaths) {
    $key = Get-Item -Path $entry.Path -ErrorAction SilentlyContinue
    if (-not $key) { continue }
    foreach ($valueName in $key.GetValueNames()) {
        $state = $states | Where-Object { $_.Name -eq $valueName } | Select-Object -First 1
        $results.Add([PSCustomObject]@{
            Id = "StartupApp:$valueName ($(if ($null -ne $state) { "Disabled" } else { "Enabled" }))"
            Name    = $valueName
            Enabled = if ($null -ne $state) { $state.Enabled } else { $true }
            Command = $key.GetValue($valueName)
            Source  = 'Registry'
            User    = $entry.Scope
        })
    }
}

# ---------------------------------------------------------------------------
# Source 2: Startup folders (user and all-users).
# Task Manager enumerates .lnk shortcuts here and resolves their targets.
# The WScript.Shell COM object reads the shortcut's TargetPath; entries
# without a matching StartupApproved value are treated as Enabled.
# ---------------------------------------------------------------------------
$wsh = New-Object -ComObject WScript.Shell -ErrorAction SilentlyContinue

foreach ($folder in @($userStartupFolder, $allUsersStartup) | Where-Object { $_ -and (Test-Path $_) }) {
    $scope = if ($folder -eq $userStartupFolder) { $loggedOnUser } else { 'All Users' }
    Get-ChildItem -Path $folder -Filter '*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
        $target = $null
        if ($wsh) {
            try { $target = $wsh.CreateShortcut($_.FullName).TargetPath } catch {}
        }
        $state = $states | Where-Object { $_.Name -eq $_.BaseName } | Select-Object -First 1
        $results.Add([PSCustomObject]@{
            Id = "StartupApp:$($_.BaseName) ($(if ($null -ne $state) { "Disabled" } else { "Enabled" }))"
            Name    = $_.BaseName
            Enabled = if ($null -ne $state) { $state.Enabled } else { $true }
            Command = $target
            Source  = 'StartupFolder'
            User    = $scope
        })
    }
}

# ---------------------------------------------------------------------------
# Source 3: Task Scheduler logon-trigger tasks.
# Modern apps (Teams, Phone Link, Terminal, etc.) and many vendor tools
# register scheduled tasks with a LogonTrigger instead of using Run keys.
# We include tasks from the root folder (\) and the ApplicationModel path
# where UWP startup tasks live, excluding deep Windows-internal system tasks.
# Task enabled/disabled state comes from the task's own State property.
# ---------------------------------------------------------------------------
$logonTasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
    # Only tasks with at least one LogonTrigger
    ($_.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' }) -and
    # Root-level tasks (\TaskName) or UWP ApplicationModel tasks; skip deep OS internals
    ($_.TaskPath -eq '\' -or $_.TaskPath -like '\Microsoft\Windows\ApplicationModel\*')
}

foreach ($task in $logonTasks) {
    $action  = $task.Actions | Select-Object -First 1
    $command = if ($action.Execute) { "$($action.Execute) $($action.Arguments)".Trim() } else { $task.TaskName }
    $ID = "StartupTask:$(If($task.TaskName.Contains("OneDrive")){ "OneDrive Startup Task" }Else{ $Task.TaskName })"
    If(![string]::IsNullOrEmpty("$($Task.Triggers.UserId)".Trim())){
        $ID += "-$(($task.Triggers.UserId)) ($($task.State))"
    }
    $results.Add([PSCustomObject]@{
        Id = "$ID"
        Name    = $task.TaskName
        Enabled = ($task.State -ne 'Disabled')
        Command = $command
        Source  = 'TaskScheduler'
        User    = if ($task.Principal.UserId) { $ntAccount } else { 'All Users' }
    })
}

$results | Sort-Object Id | Format-Table -AutoSize

$ExistingStartupApplist = Get-ChildItem $BaseInstallReg -ErrorAction SilentlyContinue | Where Name -Like "Startup*"
 # Creates a unique path for each DetectionId; Uses THRT suffix to group them

ForEach($result in $results){
$ThreatRegPath="$BaseInstallReg\$DetectionIdShort"
# Get Threat active status for String
If(Test-Path $ThreatRegPath){

}

echo "$HEAD`Archiving record for $CurrentDisplayName"
#Remove-Item -Path $ThreatRegPath -Force | Out-Null
New-Item -Path $DetectionRecordReg -Force | Out-Null
New-ItemProperty -Path $DetectionRecordReg  -Name ReportedDate -Value (Get-Date).ToString("o") | Out-Null
continue

    $CurrentDisplayName=Get-ItemProperty "$ThreatRegPath" | Select-Object "DisplayName" -ExpandProperty "DisplayName" -ErrorAction SilentlyContinue
    $CurrentDisplayVersion=Get-ItemProperty "$ThreatRegPath" | Select-Object "DisplayVersion" -ExpandProperty "DisplayVersion" -ErrorAction SilentlyContinue
    $CurrentPublisher=Get-ItemProperty "$ThreatRegPath" | Select-Object "Publisher" -ExpandProperty "Publisher" -ErrorAction SilentlyContinue

    If($CurrentDisplayName -ne $DesiredDisplayName){
        New-ItemProperty -Path $ThreatRegPath -Name 'DisplayName' -Value $DesiredDisplayName -Force | Out-Null
    }
    If($CurrentDisplayVersion -ne $DesiredDisplayVersion){
        New-ItemProperty -Path $ThreatRegPath -Name 'DisplayVersion' -Value $DesiredDisplayVersion -Force | Out-Null
    }
    If($CurrentPublisher -ne 'DEFENDER'){
        New-ItemProperty -Path $ThreatRegPath -Name 'Publisher' -Value "DEFENDER" -Force | Out-Null
    }
    If(!$ReportedThreat.ThreatIDObject.IsActive -and [string]::IsNullOrEmpty($CurrentInstallDate)){
        New-ItemProperty -Path $ThreatRegPath -Name InstallDate -Value (Get-Date).ToString("o") -Force | Out-Null
    }
}