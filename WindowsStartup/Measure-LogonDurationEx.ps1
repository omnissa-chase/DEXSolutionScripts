#Requires -Version 7.0
<#
.SYNOPSIS
    Records key logon duration metrics for the currently logged-on interactive user
    to the registry. Designed to run as SYSTEM via a WorkspaceONE logon script trigger.

.PARAMETER DeployMode
    RunNow             (default) Run the measurement immediately and write results to registry.
    DeployScheduledTask        Copy this script to C:\ProgramData\AirWatch\Extensions\DEXTools
                               and register a SYSTEM scheduled task that runs at every user
                               logon. Use this from a WSO one-time deployment script so the
                               measurement runs locally without consuming WSO agent time.
    ConfigureLogging           Check and enable the optional Windows event logs required for
                               full metric coverage (PrintService/Operational,
                               TaskScheduler/Operational). Run once as a prerequisite step
                               before deploying the scheduled task or running measurements.

.DESCRIPTION
    Mines Windows event logs for the most recent interactive logon of the active user
    and captures the following phases:
      - Logon timestamp           (TerminalServices-LocalSessionManager EID 21/25)
      - Shell / Desktop ready     (Microsoft-Windows-Winlogon EID 7001)
      - Total logon duration      (EID 21 -> Winlogon EID 7001)
      - Group Policy total        (GP EID 4001 -> EID 8001, by PrincipalSamName)
      - GP Logon Scripts          (GP EID 4018 -> EID 5018, ScriptType=1)
      - Folder Redirection        (Microsoft-Windows-Folder Redirection EID 501 -> 502)
      - User Profile load         (User Profile Service EID 1 -> 2, by user SID)
      - FSLogix container attach  (FSLogix Operational log, if present)
      - ActiveSetup               (Microsoft-Windows-Shell-Core EID 62170 -> 62171)
      - AppX / UWP packages       (Microsoft-Windows-AppReadiness EID 209)
      - Printer mapping           (PrintService/Operational EID 300 -> 306, if log enabled)
      - Scheduled tasks at logon  (TaskScheduler/Operational EID 100 -> 102, if log enabled)

    All values are written as string registry values under:
      HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration

    This script leverages PowerShell 7 features:
      - ForEach-Object -Parallel for concurrent event log queries
      - Null-coalescing operator (??)
      - Ternary operator (? :)
      - Null-conditional member access (?.)

.NOTES
    PowerShell 7+ required (uses parallel streams, ternary operators, null-conditional access).
    DeployMode RunNow            : intended for direct WSO logon script execution.
    DeployMode DeployScheduledTask : run once from WSO; thereafter the local scheduled task
                                     handles all subsequent logon captures independently.
                                     Requires pwsh.exe to be present on the target machine.
    DeployMode ConfigureLogging  : run once as a prerequisite; enables optional event logs
                                   so PrintersMappedCount/Duration and LogonTask metrics
                                   are populated. Safe to re-run — skips already-enabled logs.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE in the repository root for full license terms (MIT).
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('RunNow', 'DeployScheduledTask', 'ConfigureLogging')]
    [string]$DeployMode = 'RunNow'
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

#region --- Script-level constants ---
$script:ToolsDir   = 'C:\ProgramData\AirWatch\Extensions\DEXTools'
$script:ScriptName = 'Measure-LogonDurationEx.ps1'
$script:TaskName   = 'DEXTools_MeasureLogonDurationEx'
#endregion

#region --- Measurement function ---
function Invoke-LogonDurationCapture {
    $ErrorActionPreference = 'SilentlyContinue'
    $ProgressPreference    = 'SilentlyContinue'

#region --- Identify the currently logged-on interactive user ---
$loggedOnUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName

if ([string]::IsNullOrEmpty($loggedOnUser)) {
    Write-Warning 'No interactive user detected. Exiting.'
    exit 1
}

$username = $loggedOnUser.Split('\')[-1]

# Resolve user SID — used for accurate User Profile Service event correlation
$userSID = $null
try {
    $userSID = ([System.Security.Principal.NTAccount]$loggedOnUser).Translate(
        [System.Security.Principal.SecurityIdentifier]
    ).Value
} catch {}
#endregion

#region --- Logon timestamp and Session ID (TerminalServices-LocalSessionManager EID 21/25) ---
$tsEvent = Get-WinEvent -FilterHashtable @{
    ProviderName = 'Microsoft-Windows-TerminalServices-LocalSessionManager'
    Id           = @(21, 25)
} -MaxEvents 100 -ErrorAction SilentlyContinue |
    Where-Object { $_.Properties[0].Value -like "*\$username" } |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 1

$logonTime = $tsEvent?.TimeCreated
$sessionId = $tsEvent ? [int]$tsEvent.Properties[1].Value : $null
#endregion

#region --- Shell / Desktop Ready + Total Logon Duration ---
# Winlogon EID 7001 fires when the Shell subscriber (Explorer) begins executing
# the logon notification — the closest reliable proxy for "desktop appeared".
$shellReadyTime   = $null
$totalLogonDurSec = $null

if ($logonTime) {
    $shellEvent = Get-WinEvent -FilterHashtable @{
        ProviderName = 'Microsoft-Windows-Winlogon'
        Id           = 7001
        StartTime    = $logonTime
        EndTime      = $logonTime.AddMinutes(10)
    } -ErrorAction SilentlyContinue |
        Where-Object { $_.Properties[0].Value -eq 'Shell' } |
        Sort-Object TimeCreated |
        Select-Object -First 1

    if ($shellEvent) {
        $shellReadyTime   = $shellEvent.TimeCreated
        $totalLogonDurSec = [math]::Round(($shellReadyTime - $logonTime).TotalSeconds, 2)
    }
}
#endregion

#region --- Parallel event log queries ---
# Run GP, GP Scripts, Folder Redirection, User Profile, and FSLogix lookups concurrently.
# Each thread receives only the variables it needs via $using:.
$parallelResults = @('GP', 'GPScripts', 'FolderRedir', 'Profile', 'FSLogix', 'ActiveSetup', 'AppX', 'Printers', 'ScheduledTasks') | ForEach-Object -Parallel {
    $task        = $_
    $user        = $using:loggedOnUser
    $session     = $using:sessionId
    $logon       = $using:logonTime
    $sid         = $using:userSID
    $ErrorActionPreference = 'SilentlyContinue'

    switch ($task) {

        'GP' {
            # EID 4001 = GP start, EID 8001 = GP fully completed (not just last CSE 5016)
            $result   = @{ GPDurationSec = $null; GPStartTime = $null }
            $gpXPath  = "*[EventData[Data[@Name='PrincipalSamName'] and (Data='$user')]] and *[System[(EventID='4001')]]"
            $gpStart  = Get-WinEvent -ProviderName 'Microsoft-Windows-GroupPolicy' `
                -FilterXPath $gpXPath -MaxEvents 1 -ErrorAction SilentlyContinue

            if ($gpStart) {
                $result.GPStartTime = $gpStart.TimeCreated
                $gpEndXPath = "*[EventData[Data[@Name='PrincipalSamName'] and (Data='$user')]] and *[System[(EventID='8001')]]"
                $gpEnd = Get-WinEvent -ProviderName 'Microsoft-Windows-GroupPolicy' `
                    -FilterXPath $gpEndXPath -MaxEvents 1 -ErrorAction SilentlyContinue

                if ($gpEnd) {
                    $result.GPDurationSec = [math]::Round(
                        ($gpEnd.TimeCreated - $gpStart.TimeCreated).TotalSeconds, 2
                    )
                }
            }
            [PSCustomObject]@{ Task = 'GP'; Data = $result }
        }

        'GPScripts' {
            # EID 4018 = logon scripts start, EID 5018 = logon scripts finish, ScriptType=1
            $result         = @{ GPScriptsDurSec = $null }
            $scriptStartXPath = "*[EventData[Data[@Name='PrincipalSamName'] and (Data='$user')] " +
                "and [Data[@Name='ScriptType'] and (Data='1')]] and *[System[(EventID='4018')]]"
            $scriptEndXPath   = "*[EventData[Data[@Name='PrincipalSamName'] and (Data='$user')] " +
                "and [Data[@Name='ScriptType'] and (Data='1')]] and *[System[(EventID='5018')]]"

            $sStart = Get-WinEvent -ProviderName 'Microsoft-Windows-GroupPolicy' `
                -FilterXPath $scriptStartXPath -MaxEvents 1 -ErrorAction SilentlyContinue
            $sEnd   = Get-WinEvent -ProviderName 'Microsoft-Windows-GroupPolicy' `
                -FilterXPath $scriptEndXPath   -MaxEvents 1 -ErrorAction SilentlyContinue

            if ($sStart -and $sEnd) {
                $result.GPScriptsDurSec = [math]::Round(
                    ($sEnd.TimeCreated - $sStart.TimeCreated).TotalSeconds, 2
                )
            }
            [PSCustomObject]@{ Task = 'GPScripts'; Data = $result }
        }

        'FolderRedir' {
            # Spans first EID 501 to last EID 502 in Folder Redirection log after logon
            $result  = @{ FolderRedirDurSec = $null }
            if ($logon) {
                $frStart = Get-WinEvent -FilterHashtable @{
                    ProviderName = 'Microsoft-Windows-Folder Redirection'
                    Id           = 501
                    StartTime    = $logon
                    EndTime      = $logon.AddMinutes(10)
                } -ErrorAction SilentlyContinue | Sort-Object TimeCreated | Select-Object -First 1

                $frEnd   = Get-WinEvent -FilterHashtable @{
                    ProviderName = 'Microsoft-Windows-Folder Redirection'
                    Id           = 502
                    StartTime    = $logon
                    EndTime      = $logon.AddMinutes(10)
                } -ErrorAction SilentlyContinue | Sort-Object TimeCreated -Descending | Select-Object -First 1

                if ($frStart -and $frEnd) {
                    $result.FolderRedirDurSec = [math]::Round(
                        ($frEnd.TimeCreated - $frStart.TimeCreated).TotalSeconds, 2
                    )
                }
            }
            [PSCustomObject]@{ Task = 'FolderRedir'; Data = $result }
        }

        'Profile' {
            # Primary: SID-based XPath (Security[@UserID]) is most accurate.
            # Fallback: session ID filter if SID resolution was unavailable.
            $result = @{ ProfileDurationSec = $null }
            $profStartEvent = $null
            $profEndEvent   = $null

            if ($sid -and $logon) {
                $isoTime        = $logon.ToUniversalTime().ToString('o')
                $profStartXPath = "*[System[(EventID='1') and Security[@UserID='$sid'] and TimeCreated[@SystemTime>='$isoTime']]]"
                $profEndXPath   = "*[System[(EventID='2') and Security[@UserID='$sid'] and TimeCreated[@SystemTime>='$isoTime']]]"

                $profStartEvent = Get-WinEvent -ProviderName 'Microsoft-Windows-User Profile Service' `
                    -FilterXPath $profStartXPath -MaxEvents 1 -ErrorAction SilentlyContinue
                $profEndEvent   = Get-WinEvent -ProviderName 'Microsoft-Windows-User Profile Service' `
                    -FilterXPath $profEndXPath   -MaxEvents 1 -ErrorAction SilentlyContinue
            }

            if ((-not $profStartEvent -or -not $profEndEvent) -and $null -ne $session -and $logon) {
                $profStartEvent = Get-WinEvent -FilterHashtable @{
                    ProviderName = 'Microsoft-Windows-User Profile Service'; Id = 1; StartTime = $logon
                } -MaxEvents 100 -ErrorAction SilentlyContinue |
                    Where-Object { $_.Properties[0].Value -eq $session } |
                    Sort-Object TimeCreated | Select-Object -First 1

                $profEndEvent   = Get-WinEvent -FilterHashtable @{
                    ProviderName = 'Microsoft-Windows-User Profile Service'; Id = 2; StartTime = $logon
                } -MaxEvents 100 -ErrorAction SilentlyContinue |
                    Where-Object { $_.Properties[0].Value -eq $session } |
                    Sort-Object TimeCreated | Select-Object -First 1
            }

            if ($profStartEvent -and $profEndEvent) {
                $result.ProfileDurationSec = [math]::Round(
                    ($profEndEvent.TimeCreated - $profStartEvent.TimeCreated).TotalSeconds, 2
                )
            }
            [PSCustomObject]@{ Task = 'Profile'; Data = $result }
        }

        'FSLogix' {
            $result    = @{ FSLogixDurationSec = 'N/A' }
            $logExists = Get-WinEvent -ListLog 'Microsoft-FSLogix-Apps/Operational' -ErrorAction SilentlyContinue
            if ($logExists -and $logon) {
                $fsEvents = Get-WinEvent -FilterHashtable @{
                    LogName   = 'Microsoft-FSLogix-Apps/Operational'
                    StartTime = $logon.AddSeconds(-30)
                    EndTime   = $logon.AddMinutes(5)
                } -ErrorAction SilentlyContinue | Sort-Object TimeCreated

                $result.FSLogixDurationSec = $fsEvents?.Count -ge 2 ?
                    [string][math]::Round(($fsEvents[-1].TimeCreated - $fsEvents[0].TimeCreated).TotalSeconds, 2) :
                    ($fsEvents?.Count -eq 1 ? '0' : 'N/A')
            }
            [PSCustomObject]@{ Task = 'FSLogix'; Data = $result }
        }

        'ActiveSetup' {
            # Shell-Core EID 62170 = ActiveSetup start, 62171 = finish.
            # Filtered by Security/UserID (event.UserId) to isolate the current user.
            $result  = @{ ActiveSetupDurSec = 'N/A' }
            if ($logon -and $sid) {
                $asStart = Get-WinEvent -FilterHashtable @{
                    ProviderName = 'Microsoft-Windows-Shell-Core'
                    Id           = 62170
                    StartTime    = $logon
                    EndTime      = $logon.AddMinutes(10)
                } -ErrorAction SilentlyContinue |
                    Where-Object { $null -ne $_.UserId -and $_.UserId.Value -eq $sid } |
                    Sort-Object TimeCreated | Select-Object -First 1

                $asEnd = Get-WinEvent -FilterHashtable @{
                    ProviderName = 'Microsoft-Windows-Shell-Core'
                    Id           = 62171
                    StartTime    = $logon
                    EndTime      = $logon.AddMinutes(10)
                } -ErrorAction SilentlyContinue |
                    Where-Object { $null -ne $_.UserId -and $_.UserId.Value -eq $sid } |
                    Sort-Object TimeCreated -Descending | Select-Object -First 1

                if ($asStart -and $asEnd) {
                    $result.ActiveSetupDurSec = [math]::Round(($asEnd.TimeCreated - $asStart.TimeCreated).TotalSeconds, 2)
                }
            }
            [PSCustomObject]@{ Task = 'ActiveSetup'; Data = $result }
        }

        'AppX' {
            # AppReadiness EID 209 fires twice per logon for UWP state transitions.
            # Start: Properties[1]=2, Properties[2]=0  End: Properties[1]=1, Properties[2]=2
            # Properties[0] = User (SID or username).
            $result  = @{ AppXDurSec = 'N/A' }
            $uname   = $using:username
            if ($logon -and $sid) {
                $appxEvents = Get-WinEvent -FilterHashtable @{
                    ProviderName = 'Microsoft-Windows-AppReadiness'
                    Id           = 209
                    StartTime    = $logon
                    EndTime      = $logon.AddMinutes(10)
                } -ErrorAction SilentlyContinue |
                    Where-Object { $_.Properties[0].Value -eq $sid -or $_.Properties[0].Value -eq $uname } |
                    Sort-Object TimeCreated

                if ($appxEvents) {
                    $appxStart = $appxEvents | Where-Object { [int]$_.Properties[1].Value -eq 2 -and [int]$_.Properties[2].Value -eq 0 } | Select-Object -First 1
                    $appxEnd   = $appxEvents | Where-Object { [int]$_.Properties[1].Value -eq 1 -and [int]$_.Properties[2].Value -eq 2 } | Select-Object -First 1

                    if ($appxStart -and $appxEnd) {
                        $result.AppXDurSec = [math]::Round(($appxEnd.TimeCreated - $appxStart.TimeCreated).TotalSeconds, 2)
                    } elseif (@($appxEvents).Count -ge 2) {
                        $result.AppXDurSec = [math]::Round(($appxEvents[-1].TimeCreated - $appxEvents[0].TimeCreated).TotalSeconds, 2)
                    }
                }
            }
            [PSCustomObject]@{ Task = 'AppX'; Data = $result }
        }

        'Printers' {
            # PrintService/Operational EID 300 = connection start, 306 = connection end.
            # Log is disabled by default; reports 'LogDisabled' if unavailable.
            $result = @{ PrinterCount = 'N/A'; PrinterDurSec = 'N/A' }
            $printLogInfo = Get-WinEvent -ListLog 'Microsoft-Windows-PrintService/Operational' -ErrorAction SilentlyContinue
            if (-not $printLogInfo -or -not $printLogInfo.IsEnabled) {
                $result.PrinterCount  = 'LogDisabled'
                $result.PrinterDurSec = 'LogDisabled'
            } elseif ($logon) {
                $pStart = Get-WinEvent -FilterHashtable @{
                    LogName = 'Microsoft-Windows-PrintService/Operational'; Id = 300
                    StartTime = $logon; EndTime = $logon.AddMinutes(10)
                } -ErrorAction SilentlyContinue | Sort-Object TimeCreated

                $pEnd = Get-WinEvent -FilterHashtable @{
                    LogName = 'Microsoft-Windows-PrintService/Operational'; Id = 306
                    StartTime = $logon; EndTime = $logon.AddMinutes(10)
                } -ErrorAction SilentlyContinue | Sort-Object TimeCreated -Descending

                $result.PrinterCount = $pStart ? [string](@($pStart)).Count : '0'
                if ($pStart -and $pEnd) {
                    $result.PrinterDurSec = [math]::Round(
                        ((@($pEnd) | Select-Object -First 1).TimeCreated - (@($pStart) | Select-Object -First 1).TimeCreated).TotalSeconds, 2
                    )
                } elseif (-not $pStart) {
                    $result.PrinterDurSec = '0'
                }
            }
            [PSCustomObject]@{ Task = 'Printers'; Data = $result }
        }

        'ScheduledTasks' {
            # EID 100 = task launched, EID 102 = task completed.
            # Records count of tasks started and span from first launch to last completion
            # within 5 minutes of logon. TaskScheduler/Operational is usually enabled.
            $result = @{ TaskCount = 'N/A'; TaskTotalDurSec = 'N/A' }
            $taskLogInfo = Get-WinEvent -ListLog 'Microsoft-Windows-TaskScheduler/Operational' -ErrorAction SilentlyContinue
            if (-not $taskLogInfo -or -not $taskLogInfo.IsEnabled) {
                $result.TaskCount       = 'LogDisabled'
                $result.TaskTotalDurSec = 'LogDisabled'
            } elseif ($logon) {
                $tStart = Get-WinEvent -FilterHashtable @{
                    LogName = 'Microsoft-Windows-TaskScheduler/Operational'; Id = 100
                    StartTime = $logon; EndTime = $logon.AddMinutes(5)
                } -ErrorAction SilentlyContinue

                $tEnd = Get-WinEvent -FilterHashtable @{
                    LogName = 'Microsoft-Windows-TaskScheduler/Operational'; Id = 102
                    StartTime = $logon; EndTime = $logon.AddMinutes(5)
                } -ErrorAction SilentlyContinue

                if ($tStart) {
                    $result.TaskCount = [string](@($tStart)).Count
                    if ($tEnd) {
                        $firstStart = @($tStart) | Sort-Object TimeCreated | Select-Object -First 1
                        $lastEnd    = @($tEnd)   | Sort-Object TimeCreated -Descending | Select-Object -First 1
                        $result.TaskTotalDurSec = [string][math]::Round(($lastEnd.TimeCreated - $firstStart.TimeCreated).TotalSeconds, 2)
                    }
                } else {
                    $result.TaskCount       = '0'
                    $result.TaskTotalDurSec = '0'
                }
            }
            [PSCustomObject]@{ Task = 'ScheduledTasks'; Data = $result }
        }
    }
} -ThrottleLimit 9

# Unpack parallel results
$gpResult       = ($parallelResults | Where-Object Task -eq 'GP').Data
$gpScriptsResult= ($parallelResults | Where-Object Task -eq 'GPScripts').Data
$frResult       = ($parallelResults | Where-Object Task -eq 'FolderRedir').Data
$profResult     = ($parallelResults | Where-Object Task -eq 'Profile').Data
$fslogixResult    = ($parallelResults | Where-Object Task -eq 'FSLogix').Data
$asResult         = ($parallelResults | Where-Object Task -eq 'ActiveSetup').Data
$appxResult       = ($parallelResults | Where-Object Task -eq 'AppX').Data
$printerResult    = ($parallelResults | Where-Object Task -eq 'Printers').Data
$taskResult       = ($parallelResults | Where-Object Task -eq 'ScheduledTasks').Data
#endregion

#region --- Write results to registry ---
$regPath = 'HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration'
if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}

$regValues = [ordered]@{
    Username                  = $loggedOnUser
    LogonTime                 = $logonTime?.ToString('yyyy-MM-dd HH:mm:ss')        ?? 'Unknown'
    ShellReadyTime            = $shellReadyTime?.ToString('yyyy-MM-dd HH:mm:ss')   ?? 'Unknown'
    TotalLogonDurationSec     = $null -ne $totalLogonDurSec                        ? [string]$totalLogonDurSec                   : 'Unknown'
    GPStartTime               = $gpResult.GPStartTime?.ToString('yyyy-MM-dd HH:mm:ss') ?? 'Unknown'
    GPDurationSec             = $null -ne $gpResult.GPDurationSec                  ? [string]$gpResult.GPDurationSec             : 'Unknown'
    GPScriptsDurationSec      = $null -ne $gpScriptsResult.GPScriptsDurSec         ? [string]$gpScriptsResult.GPScriptsDurSec    : 'N/A'
    FolderRedirDurationSec    = $null -ne $frResult.FolderRedirDurSec              ? [string]$frResult.FolderRedirDurSec         : 'N/A'
    ProfileLoadDurationSec    = $null -ne $profResult.ProfileDurationSec           ? [string]$profResult.ProfileDurationSec      : 'Unknown'
    FSLogixAttachDurationSec  = [string]$fslogixResult.FSLogixDurationSec
    ActiveSetupDurationSec    = [string]$asResult.ActiveSetupDurSec
    AppXLoadDurationSec       = [string]$appxResult.AppXDurSec
    PrintersMappedCount       = [string]$printerResult.PrinterCount
    PrinterMappingDurationSec = [string]$printerResult.PrinterDurSec
    LogonTaskCount            = [string]$taskResult.TaskCount
    LogonTaskTotalDurationSec = [string]$taskResult.TaskTotalDurSec
    DataCollectedAt           = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
}

foreach ($key in $regValues.Keys) {
    Set-ItemProperty -Path $regPath -Name $key -Value $regValues[$key] -Type String -Force
}
#endregion

Write-Output "Logon duration metrics recorded for '$loggedOnUser' at '$regPath'"
} # end Invoke-LogonDurationCapture
#endregion

#region --- Scheduled Task deployment function ---
function Install-LogonDurationTask {
    [CmdletBinding()]
    param()

    if ([string]::IsNullOrEmpty($PSCommandPath)) {
        Write-Warning 'Cannot determine script path ($PSCommandPath is empty). Run from a saved .ps1 file.'
        return
    }

    # Verify pwsh.exe is available before committing
    $pwsh = (Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue)?.Source
    if (-not $pwsh) {
        # Fallback to well-known PS7 default install paths
        $pwsh = @(
            "$env:ProgramFiles\PowerShell\7\pwsh.exe",
            "$env:ProgramFiles\PowerShell\7-preview\pwsh.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if (-not $pwsh) {
        Write-Warning 'pwsh.exe not found. Install PowerShell 7 before deploying the Ex scheduled task.'
        return
    }

    # Ensure tools directory exists
    if (-not (Test-Path $script:ToolsDir)) {
        New-Item -Path $script:ToolsDir -ItemType Directory -Force | Out-Null
    }

    # Copy this script to the permanent tools location
    $destScript = Join-Path $script:ToolsDir $script:ScriptName
    Copy-Item -Path $PSCommandPath -Destination $destScript -Force

    # Task action — runs the saved worker copy with RunNow (default), hidden, using pwsh.exe
    $action    = New-ScheduledTaskAction `
        -Execute  $pwsh `
        -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$destScript`""

    # AtLogon trigger for any user; 30-second delay ensures event log entries are flushed
    $trigger         = New-ScheduledTaskTrigger -AtLogOn
    $trigger.Delay   = 'PT30S'

    $principal = New-ScheduledTaskPrincipal `
        -UserId    'SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel  Highest

    $settings  = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
        -MultipleInstances  IgnoreNew `
        -Hidden

    # Remove existing task of the same name before re-registering
    $existing = Get-ScheduledTask -TaskName $script:TaskName -TaskPath '\DEXTools\' -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $script:TaskName -TaskPath '\DEXTools\' -Confirm:$false
    }

    Register-ScheduledTask `
        -TaskName    $script:TaskName `
        -TaskPath    '\DEXTools\' `
        -Action      $action `
        -Trigger     $trigger `
        -Principal   $principal `
        -Settings    $settings `
        -Description 'Captures logon duration metrics to HKLM registry at each user logon (PS7). Deployed by WorkspaceONE.' | Out-Null

    Write-Output "Scheduled task '\DEXTools\$($script:TaskName)' registered."
    Write-Output "Worker script saved to: $destScript"
    Write-Output "Using PowerShell 7 executable: $pwsh"
}
#endregion

#region --- Logging configuration function ---
function Enable-DEXAuditLogs {
    <#
    .SYNOPSIS
        Enables the optional Windows event logs used by Measure-LogonDurationEx.
        Safe to run multiple times — already-enabled logs are reported and skipped.
    #>

    # Logs that are disabled by default but required for full metric coverage
    $targets = @(
        [PSCustomObject]@{
            LogName     = 'Microsoft-Windows-PrintService/Operational'
            Description = 'Printer mapping duration (EID 300 start, EID 306 finish)'
        }
        [PSCustomObject]@{
            LogName     = 'Microsoft-Windows-TaskScheduler/Operational'
            Description = 'Logon scheduled task duration (EID 100 start, EID 102 finish)'
        }
    )

    Write-Output ''
    Write-Output '=== DEX Audit Log Configuration ==='

    foreach ($target in $targets) {
        $log = Get-WinEvent -ListLog $target.LogName -ErrorAction SilentlyContinue

        if (-not $log) {
            Write-Output "  [NOT FOUND] $($target.LogName)"
            Write-Output "              This log does not exist on this system. Skipping."
            continue
        }

        if ($log.IsEnabled) {
            Write-Output "  [OK]        $($target.LogName)"
            Write-Output "              Already enabled — $($target.Description)"
        } else {
            try {
                wevtutil.exe sl $target.LogName /e:true 2>&1 | Out-Null
                $verify = Get-WinEvent -ListLog $target.LogName -ErrorAction SilentlyContinue
                if ($verify?.IsEnabled) {
                    Write-Output "  [ENABLED]   $($target.LogName)"
                    Write-Output "              Now enabled — $($target.Description)"
                } else {
                    Write-Output "  [FAILED]    $($target.LogName)"
                    Write-Output "              wevtutil returned success but log still reports disabled."
                }
            } catch {
                Write-Output "  [ERROR]     $($target.LogName)"
                Write-Output "              $_"
            }
        }
        Write-Output ''
    }

    Write-Output '=== Configuration complete ==='
    Write-Output 'Re-run with -DeployMode RunNow or DeployScheduledTask when ready.'
}
#endregion

#region --- Entry point ---
switch ($DeployMode) {
    'RunNow'              { Invoke-LogonDurationCapture }
    'DeployScheduledTask' { Install-LogonDurationTask }
    'ConfigureLogging'    { Enable-DEXAuditLogs }
}
#endregion