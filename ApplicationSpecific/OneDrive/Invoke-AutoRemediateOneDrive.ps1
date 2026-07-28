<#
.SYNOPSIS
    Invoke-AutoRemediateOneDrive -- Automated OneDrive diagnostic and remediation.

.DESCRIPTION
    Runs a sequenced set of OneDrive-specific health checks and automatically
    remediates where safe to do so. Targets the most common causes of OneDrive
    sync failures, process health issues, and configuration drift in
    enterprise deployments.

    Steps covered by generic scripts are intentionally excluded here:
      - Network connectivity       --> Invoke-AutoRemediateNetworkStack.ps1
      - Disk space                 --> DiskCleanup scripts
      - Windows Update             --> Invoke-AutoRemediateWindowsUpdates.ps1

    +------+--------------------------------------+-------------------------------+
    | Step | Name                                 | Remediates On                 |
    +------+--------------------------------------+-------------------------------+
    |  1   | OneDrive Auto-start / Process Health | Failed (Run key + process)    |
    |  2   | Account Sign-in State                | -- (informational only)       |
    |  3   | Sync Error Detection                 | -- (informational only)       |
    |  4   | Files On-Demand Service              | Warning (restart if stopped)  |
    |  5   | Known Folder Move Status             | -- (informational only)       |
    +------+--------------------------------------+-------------------------------+

    Step 1 note: if OneDrive.exe is not running, this script creates a temporary
    scheduled task that runs as the logged-on user (Interactive session) to start
    OneDrive in their session. This is the correct method to launch a per-user
    process from SYSTEM context without user credentials.

    Step 5 note: Known Folder Move (KFM) policy can only be applied by an admin
    via Group Policy or the OneDrive admin center. This step reports drift but
    does not attempt to apply KFM silently -- that requires the tenant Enum ID
    which is site-specific and must be configured at deployment time.

    SYSTEM-context note: OneDrive stores all sync state, settings, and logs
    under %localappdata%\Microsoft\OneDrive, which is per-user. This script
    resolves the logged-on user's profile via Win32_ComputerSystem.UserName
    rather than using $env:LOCALAPPDATA, which resolves to the SYSTEM profile
    when the script runs as SYSTEM and must not be used for per-user data paths.

.PARAMETER AllowDestructiveActions
    Reserved for future use. Not currently required by any step in this script.
    Default: $false.

.NOTES
    Script Name  : Invoke-AutoRemediateOneDrive.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-28
    Timeout      : 60 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

param(
    [bool]$AllowDestructiveActions = $(if ($env:AllowDestructiveActions) { [System.Convert]::ToBoolean($env:AllowDestructiveActions) } else { $false })
)

# -- Pre-flight: resolve logged-on user context -------------------------------
# SYSTEM context: $env:LOCALAPPDATA resolves to the SYSTEM profile.
# OneDrive sync state, settings, and logs are all stored per-user under
# %localappdata%\Microsoft\OneDrive -- must be resolved from the actual
# logged-on user's profile path.
$_loggedOnUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$_shortName    = if ($_loggedOnUser) { $_loggedOnUser.Split('\')[-1] } else { $null }
$_userProfile  = if ($_shortName -and (Test-Path "C:\Users\$_shortName")) { "C:\Users\$_shortName" } else { $null }

$_userSid = $null
if ($_loggedOnUser) {
    try {
        $_userSid = ([Security.Principal.NTAccount]$_loggedOnUser).Translate([Security.Principal.SecurityIdentifier]).Value
    } catch { }
}

# -- Pre-flight: detect OneDrive install --------------------------------------
# OneDrive can be installed per-user (%localappdata%) or system-wide
# (%ProgramFiles%, the default on Windows 11). Both installations store
# per-user data in %localappdata%\Microsoft\OneDrive.
$_oneDriveExe = $null

# Per-user install (older/EXE-installed)
if ($_userProfile) {
    $perUserExe = Join-Path $_userProfile 'AppData\Local\Microsoft\OneDrive\OneDrive.exe'
    if (Test-Path $perUserExe) { $_oneDriveExe = $perUserExe }
}
# System-wide install (MSI / Windows 11 default)
if (-not $_oneDriveExe) {
    foreach ($candidate in @(
        "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe",
        "${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDrive.exe"
    )) {
        if (Test-Path $candidate) { $_oneDriveExe = $candidate; break }
    }
}

if (-not $_oneDriveExe) {
    Write-Host "`n-- Invoke-AutoRemediateOneDrive ---------------------------------" -ForegroundColor Cyan
    Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host '   [Skipped] OneDrive does not appear to be installed on this device.'
    Write-Host "----------------------------------------------------------------`n" -ForegroundColor Cyan
    exit 0
}

# -- Step Definitions ---------------------------------------------------------
$Steps = @(

    @{
        Name             = 'OneDrive Auto-start / Process Health'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if (-not $_userSid) {
                return @{ Status = 'Warning'; Message = 'Cannot resolve user SID -- Run key and process checks skipped.' }
            }
            $runKeyPath   = "Registry::HKEY_USERS\$_userSid\Software\Microsoft\Windows\CurrentVersion\Run"
            $runKeyValue  = (Get-ItemProperty $runKeyPath -Name 'OneDrive' -ErrorAction SilentlyContinue).OneDrive
            $isRunning    = [bool](Get-Process -Name OneDrive -ErrorAction SilentlyContinue)
            $runKeyExists = [bool]$runKeyValue

            if ($isRunning -and $runKeyExists) {
                return @{ Status = 'Passed'; Message = 'OneDrive is running and auto-start Run key is present.' }
            }
            if (-not $runKeyExists -and -not $isRunning) {
                return @{ Status = 'Failed'; Message = 'OneDrive is not running and the auto-start Run key is missing. Will restore Run key and start OneDrive.' }
            }
            if (-not $runKeyExists) {
                return @{ Status = 'Failed'; Message = "OneDrive is running but the auto-start Run key is missing (OneDrive will not restart after logoff). Will restore Run key." }
            }
            # Run key exists but process is not running
            return @{ Status = 'Failed'; Message = "OneDrive is not running (auto-start key is present). Will start OneDrive in user context." }
        }
        ResolutionScript = {
            # Step A: restore the Run key if missing
            $runKeyPath  = "Registry::HKEY_USERS\$_userSid\Software\Microsoft\Windows\CurrentVersion\Run"
            $runKeyValue = (Get-ItemProperty $runKeyPath -Name 'OneDrive' -ErrorAction SilentlyContinue).OneDrive
            if (-not $runKeyValue) {
                $runValue = "`"$_oneDriveExe`" /background"
                Set-ItemProperty -Path $runKeyPath -Name 'OneDrive' -Value $runValue -Type String -ErrorAction Stop
                Write-Host "  [Info] Restored OneDrive auto-start Run key: $runValue" -ForegroundColor DarkYellow
            }
            # Step B: start OneDrive in the user's interactive session if not running.
            # From SYSTEM context, Start-Process launches as SYSTEM, not the user.
            # A temporary scheduled task with Interactive logon is the correct method
            # to launch OneDrive in the user's desktop session without credentials.
            if (-not (Get-Process -Name OneDrive -ErrorAction SilentlyContinue)) {
                $taskName = 'DEX-TempStartOneDrive'
                try {
                    $action    = New-ScheduledTaskAction -Execute $_oneDriveExe -Argument '/background'
                    $principal = New-ScheduledTaskPrincipal -UserId $_loggedOnUser -LogonType Interactive -RunLevel Limited
                    $settings  = New-ScheduledTaskSettingsSet -DeleteExpiredTaskAfter '00:02:00' -ExecutionTimeLimit '00:01:00'
                    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
                    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
                    Start-Sleep -Seconds 5   # Allow process time to launch before the task is unregistered
                    Write-Host "  [Info] OneDrive started in user session via temporary scheduled task." -ForegroundColor DarkYellow
                } finally {
                    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
                }
            }
        }
    },

    @{
        Name             = 'Account Sign-in State'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if (-not $_userSid) {
                return @{ Status = 'Passed'; Message = 'Cannot resolve user SID -- account check skipped.' }
            }
            $accountsBase = "Registry::HKEY_USERS\$_userSid\Software\Microsoft\OneDrive\Accounts"
            if (-not (Test-Path $accountsBase)) {
                return @{ Status = 'Warning'; Message = 'OneDrive Accounts registry key not found -- OneDrive may not have completed first-run setup for this user.' }
            }
            $accounts     = Get-ChildItem $accountsBase -ErrorAction SilentlyContinue
            if (-not $accounts) {
                return @{ Status = 'Warning'; Message = 'No OneDrive accounts configured for this user (OneDrive Accounts key is empty).' }
            }
            $accountSummary = $accounts | ForEach-Object {
                $props     = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                $email     = $props.UserEmail
                $display   = $props.DisplayName
                $acctLabel = $_.PSChildName
                if ($email) {
                    "$acctLabel`: $email$(if ($display) { " ($display)" })"
                } else {
                    "$acctLabel`: not signed in"
                }
            }
            $notSignedIn = $accounts | Where-Object {
                -not (Get-ItemProperty $_.PSPath -Name 'UserEmail' -ErrorAction SilentlyContinue).UserEmail
            }
            if ($notSignedIn) {
                return @{ Status = 'Warning'; Message = "One or more OneDrive accounts are not signed in: $($accountSummary -join '; ')." }
            }
            return @{ Status = 'Passed'; Message = "OneDrive account(s) signed in: $($accountSummary -join '; ')." }
        }
        ResolutionScript = $null   # Sign-in requires user interaction -- cannot authenticate on behalf of a user from SYSTEM context
    },

    @{
        Name             = 'Sync Error Detection'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            # Check the Application event log for OneDrive error events in the last 24 hours.
            # This is the most accessible sync health signal available from SYSTEM context
            # without OneDrive's internal COM APIs.
            $cutoff    = (Get-Date).AddHours(-24)
            $odErrors  = @()
            try {
                $odErrors = Get-WinEvent -FilterHashtable @{
                    LogName   = 'Application'
                    StartTime = $cutoff
                    Level     = 2   # Error
                } -ErrorAction SilentlyContinue |
                Where-Object { $_.ProviderName -like '*OneDrive*' -or $_.Message -like '*OneDrive*' }
            } catch { }

            # Also check for the dedicated OneDrive operational log if available
            try {
                $odErrors += Get-WinEvent -FilterHashtable @{
                    LogName   = 'Microsoft-Windows-OneDrive-Operational'
                    StartTime = $cutoff
                    Level     = 2
                } -ErrorAction SilentlyContinue
            } catch { }   # Log may not exist on all configurations -- suppress

            $errorCount = $odErrors.Count
            if ($errorCount -gt 0) {
                $recent = $odErrors | Select-Object -First 3 |
                          ForEach-Object { $_.Message -replace '\r?\n',' ' | Select-Object -First 1 }
                $sample = ($recent | ForEach-Object { $_.Substring(0, [Math]::Min(80, $_.Length)) }) -join ' | '
                return @{ Status = 'Warning'; Message = "$errorCount OneDrive error event(s) in the Application log (last 24h). Sample: $sample" }
            }
            return @{ Status = 'Passed'; Message = 'No OneDrive error events found in the Application log in the last 24 hours.' }
        }
        ResolutionScript = $null   # Sync errors require root-cause triage (network, account, file conflict) -- no single safe automated fix
    },

    @{
        Name             = 'Files On-Demand Service'
        Order            = 4
        Enabled          = $true
        ResolveOnWarning = $true   # Restarting a stopped service is safe; disabled state is flagged but not forced
        DetectionScript  = {
            # FileSyncHelper is the Windows service that supports OneDrive Files On-Demand
            # (placeholder files, hydration on access). If this service is not running,
            # placeholder files will fail to open and users will see sync errors.
            $svc = Get-Service -Name 'FileSyncHelper' -ErrorAction SilentlyContinue
            if (-not $svc) {
                return @{ Status = 'Passed'; Message = 'FileSyncHelper service not found -- Files On-Demand may not be supported on this Windows version, or OneDrive is not configured for Files On-Demand.' }
            }
            if ($svc.StartType -eq 'Disabled') {
                return @{ Status = 'Warning'; Message = "FileSyncHelper service is Disabled. Files On-Demand placeholder files will not open. Review whether Files On-Demand is intentionally disabled via policy before re-enabling." }
            }
            if ($svc.Status -ne 'Running') {
                return @{ Status = 'Warning'; Message = "FileSyncHelper service is not running (Status: $($svc.Status), StartType: $($svc.StartType)). Will attempt to start." }
            }
            return @{ Status = 'Passed'; Message = "FileSyncHelper service is running (StartType: $($svc.StartType))." }
        }
        ResolutionScript = {
            $svc = Get-Service -Name 'FileSyncHelper' -ErrorAction SilentlyContinue
            if ($svc -and $svc.StartType -eq 'Disabled') {
                # Do not force-enable a disabled service without admin review
                Write-Host '  [Info] FileSyncHelper is Disabled -- skipping restart. Review policy before enabling.' -ForegroundColor DarkYellow
                return
            }
            if ($svc -and $svc.Status -ne 'Running') {
                Start-Service -Name 'FileSyncHelper' -ErrorAction Stop
                Write-Host "  [Info] FileSyncHelper service started." -ForegroundColor DarkYellow
            }
        }
    },

    @{
        Name             = 'Known Folder Move Status'
        Order            = 5
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if (-not $_userSid) {
                return @{ Status = 'Passed'; Message = 'Cannot resolve user SID -- KFM check skipped.' }
            }
            # KfmFoldersProtectedNow is a bitmask stored under the Business account key.
            # Bit 0 (1) = Desktop, Bit 1 (2) = Documents, Bit 2 (4) = Pictures
            # Value 7 = all three folders are being backed up.
            $accountsBase = "Registry::HKEY_USERS\$_userSid\Software\Microsoft\OneDrive\Accounts"
            if (-not (Test-Path $accountsBase)) {
                return @{ Status = 'Passed'; Message = 'OneDrive Accounts key not found -- KFM check skipped (OneDrive not set up).' }
            }
            # Check business accounts only (KFM is an enterprise feature; not applicable to Personal)
            $bizAccounts = Get-ChildItem $accountsBase -ErrorAction SilentlyContinue |
                           Where-Object { $_.PSChildName -like 'Business*' }
            if (-not $bizAccounts) {
                return @{ Status = 'Passed'; Message = 'No OneDrive business accounts found -- KFM is not applicable (KFM requires a work or school account).' }
            }

            # Check if KFM is expected via policy
            $kfmPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'
            $kfmOptIn      = (Get-ItemProperty $kfmPolicyPath -Name 'KFMSilentOptIn'        -ErrorAction SilentlyContinue).KFMSilentOptIn
            $kfmWizard     = (Get-ItemProperty $kfmPolicyPath -Name 'KFMOptInWithWizard'    -ErrorAction SilentlyContinue).KFMOptInWithWizard
            $kfmPolicySet  = [bool]($kfmOptIn -or $kfmWizard)

            $kfmResults = $bizAccounts | ForEach-Object {
                $kfmBitmask = (Get-ItemProperty $_.PSPath -Name 'KfmFoldersProtectedNow' -ErrorAction SilentlyContinue).KfmFoldersProtectedNow
                if ($null -eq $kfmBitmask) {
                    "$($_.PSChildName): KFM not configured (KfmFoldersProtectedNow key absent)"
                } else {
                    $folders = @()
                    if ($kfmBitmask -band 1) { $folders += 'Desktop' }
                    if ($kfmBitmask -band 2) { $folders += 'Documents' }
                    if ($kfmBitmask -band 4) { $folders += 'Pictures' }
                    $notProtected = @('Desktop','Documents','Pictures') | Where-Object { $folders -notcontains $_ }
                    $summary = if ($folders) { "Protecting: $($folders -join ', ')" } else { 'No folders protected' }
                    if ($notProtected) { $summary += ". Not protected: $($notProtected -join ', ')" }
                    "$($_.PSChildName): $summary"
                }
            }
            $allProtected = $bizAccounts | Where-Object {
                $bitmask = (Get-ItemProperty $_.PSPath -Name 'KfmFoldersProtectedNow' -ErrorAction SilentlyContinue).KfmFoldersProtectedNow
                $null -ne $bitmask -and ($bitmask -band 7) -eq 7
            }
            if ($kfmPolicySet -and $allProtected.Count -lt $bizAccounts.Count) {
                return @{ Status = 'Warning'; Message = "KFM policy is configured but not all folders are protected: $($kfmResults -join '; '). Check OneDrive admin center for enrollment status." }
            }
            if ($allProtected.Count -lt $bizAccounts.Count -and $kfmPolicySet) {
                return @{ Status = 'Warning'; Message = "KFM not fully applied: $($kfmResults -join '; ')." }
            }
            $policyNote = if (-not $kfmPolicySet) { ' Note: no KFM policy found in HKLM -- KFM may not be deployed for this tenant.' } else { '' }
            return @{ Status = 'Passed'; Message = "$($kfmResults -join '; ').$policyNote" }
        }
        ResolutionScript = $null   # KFM enrollment requires the tenant Enum ID configured via GPO or MDM policy -- cannot be applied locally from a script
    }
)

# -- Execution Engine ---------------------------------------------------------
$activeSteps = $Steps | Where-Object { $_.Enabled } | Sort-Object { [int]$_.Order }
$results     = [System.Collections.Generic.List[PSCustomObject]]::new()

$oneDriveVersion = try {
    (Get-Item $_oneDriveExe -ErrorAction SilentlyContinue).VersionInfo.ProductVersion
} catch { 'unknown' }

Write-Host "`n-- Invoke-AutoRemediateOneDrive ---------------------------------" -ForegroundColor Cyan
Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)   Version: $oneDriveVersion   User: $(if ($_loggedOnUser) { $_loggedOnUser } else { 'unknown' })"
Write-Host '----------------------------------------------------------------' -ForegroundColor Cyan

foreach ($step in $activeSteps) {
    $status     = 'Failed'
    $message    = 'Detection script did not return a result.'
    $remediated = $false
    $remError   = ''

    # Detection
    try {
        $result  = & $step.DetectionScript
        $status  = $result.Status
        $message = $result.Message
    } catch {
        $status  = 'Failed'
        $message = "Detection exception: $($_.Exception.Message)"
    }

    # Remediation
    $shouldRemediate = ($status -eq 'Failed') -or ($status -eq 'Warning' -and $step.ResolveOnWarning)
    if ($shouldRemediate -and $step.ResolutionScript) {
        try {
            & $step.ResolutionScript | Out-Null
            $remediated = $true
        } catch {
            $remError = $_.Exception.Message
        }
    }

    # Output
    $color   = switch ($status) { 'Passed' { 'Green' } 'Warning' { 'Yellow' } 'Failed' { 'Red' } default { 'White' } }
    $remNote = if ($remediated)   { '  -> Remediation ran' }
               elseif ($remError) { "  -> Remediation ERROR: $remError" }
               else               { '' }
    Write-Host "`n  [$($status.PadRight(7))] $($step.Name): $message$remNote" -ForegroundColor $color

    $results.Add([PSCustomObject]@{
        Order      = $step.Order
        Name       = $step.Name
        Status     = $status
        Message    = $message
        Remediated = $remediated
        RemError   = $remError
    })
}

# -- Summary ------------------------------------------------------------------
$passed   = ($results | Where-Object { $_.Status -eq 'Passed'  }).Count
$warnings = ($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed   = ($results | Where-Object { $_.Status -eq 'Failed'  }).Count
$remCount = ($results | Where-Object { $_.Remediated }).Count

Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations run: $remCount"
Write-Host "----------------------------------------------------------------`n" -ForegroundColor Cyan

# -- Registry Reporting -------------------------------------------------------
$regPath = 'HKLM:\Software\AirWatch\Extension\DEXRecords\OneDriveErrors'
try {
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null
    }
    $existing = Get-Item -Path $regPath -ErrorAction SilentlyContinue
    if ($existing) {
        $existing.GetValueNames() | ForEach-Object {
            Remove-ItemProperty -Path $regPath -Name $_ -ErrorAction SilentlyContinue
        }
    }
    Set-ItemProperty -Path $regPath -Name 'LastScanTime'      -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Type String
    Set-ItemProperty -Path $regPath -Name 'OneDriveVersion'   -Value $oneDriveVersion  -Type String
    Set-ItemProperty -Path $regPath -Name 'TotalSteps'        -Value $results.Count    -Type DWord
    Set-ItemProperty -Path $regPath -Name 'PassedCount'       -Value $passed           -Type DWord
    Set-ItemProperty -Path $regPath -Name 'WarningCount'      -Value $warnings         -Type DWord
    Set-ItemProperty -Path $regPath -Name 'FailedCount'       -Value $failed           -Type DWord
    Set-ItemProperty -Path $regPath -Name 'RemediatedCount'   -Value $remCount         -Type DWord

    $results | Where-Object { $_.Status -ne 'Passed' } | ForEach-Object {
        $valueName = 'Step{0:D2}_{1}' -f $_.Order, ($_.Name -replace '[^A-Za-z0-9]', '')
        $tag       = if ($_.Remediated) { '[Remediated]' } else { "[$($_.Status)]" }
        Set-ItemProperty -Path $regPath -Name $valueName -Value "$tag $($_.Message)" -Type String
    }
    Write-Host "  [Registry] Results written to $regPath" -ForegroundColor DarkCyan
} catch {
    Write-Host "  [Registry] Write failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

# -- Exit ---------------------------------------------------------------------
if ($failed -gt 0) { exit 1 }
exit 0
