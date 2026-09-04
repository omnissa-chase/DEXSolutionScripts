<#
.SYNOPSIS
    Runs Windows Disk Cleanup targeting specific system cleanup categories.

.DESCRIPTION
    Automates the Windows built-in Disk Cleanup utility (cleanmgr.exe) by
    programmatically configuring cleanup options via the registry and executing
    a cleanup profile. Targets system-level categories such as previous Windows
    installations, update artifacts, error dumps, and upgrade log files.
    Upon completion, outputs the amount of disk space reclaimed and the
    resulting free space, both in GB.

    cleanmgr returns as soon as it has handed the work off, so by default those
    figures are measured while cleanup is still running. Pass -Wait to block
    until cleanmgr and the Windows Modules Installer service have finished.

.PARAMETER Wait
    Wait for Disk Cleanup to finish before measuring free space. Without it the
    reclaimed figure is measured too early and is usually zero.

.PARAMETER WaitTimeoutSeconds
    Upper bound on that wait, in seconds. Defaults to 900.

.NOTES
    Script Name  : DEX_Start-DiskCleanup.ps1
    Version      : 1.2.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-09-03
    Timeout      : 30 seconds without -Wait. With -Wait, allow WaitTimeoutSeconds
                   plus a margin; the default 900s needs a 20 minute timeout.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
function Start-DiskCleanup {
param(
   # Block until cleanup has actually finished before measuring free space.
   [switch]$Wait,

   # Upper bound on that wait. Component store cleanup routinely runs for
   # several minutes on a machine with a long update history.
   [int]$WaitTimeoutSeconds = 900
)

# UEM supplies inputs as environment variables, so honour those when the
# parameter was not passed on the command line. Absent, empty, or unparseable
# resolves to a no-wait run, which is the previous behaviour.
If (-not $PSBoundParameters.ContainsKey("Wait") -and $env:WaitForCleanup) {
   Try   { $Wait = [System.Convert]::ToBoolean($env:WaitForCleanup) }
   Catch { $Wait = $false }
}
If (-not $PSBoundParameters.ContainsKey("WaitTimeoutSeconds") -and $env:WaitTimeoutSeconds) {
   $ParsedTimeout = 0
   If ([int]::TryParse($env:WaitTimeoutSeconds, [ref]$ParsedTimeout) -and $ParsedTimeout -gt 0) {
       $WaitTimeoutSeconds = $ParsedTimeout
   }
}

# Free space on C: in GB to two decimal places. The previous [int] cast rounded
# to the nearest whole GB, so a 400 MB cleanup reported 0 and a 600 MB one
# reported 1. Neither is a number worth showing an admin.
Function Get-FreeSpaceGB {
   return [math]::Round((Get-Volume -DriveLetter "C").SizeRemaining / 1GB, 2)
}

# Waits for cleanup to settle. Returns $true if it settled, $false on timeout.
Function Wait-DiskCleanupCompletion {
   Param([int]$TimeoutSeconds)

   $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)

   # cleanmgr /sagerun forks a worker and the launcher returns straight away, so
   # the launcher exiting says nothing about whether the work is done.
   While ((Get-Process -Name "cleanmgr" -ErrorAction SilentlyContinue) -and ((Get-Date) -lt $Deadline)) {
       Start-Sleep -Seconds 2
   }

   # "Update Cleanup" hands the component store work to the Windows Modules
   # Installer service, which keeps running well after cleanmgr has gone. That
   # is the service worth waiting on, and where most of the space comes back.
   While ((Get-Date) -lt $Deadline) {
       $TiWorker  = Get-Process -Name "TiWorker" -ErrorAction SilentlyContinue
       $Installer = Get-Service -Name "TrustedInstaller" -ErrorAction SilentlyContinue
       If (-not $TiWorker -and (-not $Installer -or $Installer.Status -ne "Running")) { Break }
       Start-Sleep -Seconds 5
   }

   # Deletions keep flushing briefly after the workers exit. Treat the volume as
   # settled once three consecutive readings agree.
   $StableSamples = 0
   $LastReading   = Get-FreeSpaceGB
   While (($StableSamples -lt 3) -and ((Get-Date) -lt $Deadline)) {
       Start-Sleep -Seconds 5
       $Reading = Get-FreeSpaceGB
       If ($Reading -eq $LastReading) { $StableSamples++ }
       Else { $StableSamples = 0; $LastReading = $Reading }
   }

   return ((Get-Date) -lt $Deadline)
}

# DISKCLN script for clearing space
# Free space before cleanup, the baseline for the reclaimed figure
$CurrentFreeSpace = Get-FreeSpaceGB

# Integer used to identify the disk cleanup profile (can be any number from 10 to 99)
$DskCleanProfileID = 55

# List of cleanup options to enable for this run
# Comment/uncomment lines to include/exclude specific cleanup tasks
$ConfiguredOptions = @(
   #"Active Setup Temp Folders"
   #"BranchCache"
   #"Content Indexer Cleaner"
   #"D3D Shader Cache"
   #"Delivery Optimization Files"
   #"Device Driver Packages"
   #"Diagnostic Data Viewer database files"
   #"Downloaded Program Files"
   #"DownloadsFolder"
   #"Feedback Hub Archive log files"
   #"Internet Cache Files"
   #"Language Pack"
   #"Offline Pages Files"
   #"Old ChkDsk Files"
   "Previous Installations"
   #"Recycle Bin"
   #"RetailDemo Offline Content"
   #"Setup Log Files"
   "System error memory dump files"
   "System error minidump files"
   #"Temporary Files"
   #"Temporary Setup Files"
   #"Temporary Sync Files"
   #"Thumbnail Cache"
   "Update Cleanup"
   #"Upgrade Discarded Files"
   #"User file versions"
   #"Windows Defender"
   "Windows Error Reporting Files"
   #"Windows ESD installation files"
   "Windows Reset Log Files"
   "Windows Upgrade Log Files"
)

# Registry path where disk cleanup options are configured
$DskCleanPresetLocation = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\"

# Get all available cleanup options from the registry
$WindowsDiskCleanOptions = Get-ChildItem $DskCleanPresetLocation | Select-Object @{N='Options';E={Split-Path $_.Name -Leaf}}

# Loop through each available cleanup option
ForEach ($CleanOption in $WindowsDiskCleanOptions) {
   # Check if the registry path for the option exists
   # Property is 'Options' (set by Select-Object above); '.Option' returned $null,
   # which collapsed this to the parent VolumeCaches key -- Test-Path still passed,
   # so every handler write landed on the parent instead of the handler itself.
   $OptionPath = Join-Path $DskCleanPresetLocation $CleanOption.Options
   If (Test-Path $OptionPath) {
       $CnfgValue = 0 # Default to disabled

       # Enable the option if it's in the configured list.
       # Compare the Options STRING, not the object: a PSCustomObject is never -in
       # an array of strings, so this was always false and nothing was ever enabled.
       If ($CleanOption.Options -in $ConfiguredOptions) {
           $CnfgValue = 2 # Value 2 enables the cleanup option
       }

       # Write the configuration value to the registry for the specified profile ID
       $Results = New-ItemProperty -Path $OptionPath -Name "StateFlags00$DskCleanProfileId" -Value $CnfgValue -Force
   }
}

# Run Disk Cleanup with the configured profile ID
& cleanmgr "/sagerun:$DskCleanProfileId"

$WaitTimedOut = $false
If ($Wait) {
   echo "Waiting up to $WaitTimeoutSeconds second(s) for Disk Cleanup to finish..."
   If (-not (Wait-DiskCleanupCompletion -TimeoutSeconds $WaitTimeoutSeconds)) {
       $WaitTimedOut = $true
       echo "Warning: Disk Cleanup had not finished after $WaitTimeoutSeconds second(s). The figures below understate the space reclaimed."
   }
}

# Get new free space after cleanup
$NewFreeSpace = Get-FreeSpaceGB

# Free space grows as data is removed, so the reclaimed amount is the new
# reading minus the baseline. The original subtraction ran the other way and
# could only ever report zero or a negative number.
echo "SpaceCleaned: $([math]::Round($NewFreeSpace - $CurrentFreeSpace, 2)) GB"
echo "FreeSpace: $NewFreeSpace GB"

# The cleanup itself ran, but a timeout means the reported size is known to be
# unreliable, so surface that as a failure rather than a confident wrong number.
If ($WaitTimedOut) { Exit 1 }
Exit 0
}

# -- entry point ---------------------------------------------------------------
# The param block sits inside the function deliberately. The Workspace ONE script
# engine does not recognise a param block at script scope, and $PSCmdlet is $null
# there, which makes every ShouldProcess call throw. Inputs arrive as environment
# variables and are bound to the function's parameters below.

Start-DiskCleanup
Exit 0
