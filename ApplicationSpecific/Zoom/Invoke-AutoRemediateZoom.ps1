<#
.SYNOPSIS
    Invoke-AutoRemediateZoom -- Automated Zoom diagnostic and remediation.

.DESCRIPTION
    Runs a sequenced set of Zoom-specific health checks and automatically
    remediates where safe to do so. Targets the most common causes of Zoom
    performance, sign-in, and call-quality issues within the app's own footprint.

    Steps covered by generic scripts are intentionally excluded here:
      - Network connectivity       --> Invoke-AutoRemediateNetworkStack.ps1
      - Driver / audio issues      --> Invoke-AutoRemediateDriverIssues.ps1
      - Disk space                 --> DiskCleanup scripts
      - Windows Update             --> Invoke-AutoRemediateWindowsUpdates.ps1

    +------+--------------------------------------+-------------------------------+
    | Step | Name                                 | Remediates On                 |
    +------+--------------------------------------+-------------------------------+
    |  1   | Zoom Cache / Log Bloat               | Warning (auto -- safe clear)  |
    |  2   | Zoom Updater / Version Health        | -- (informational only)       |
    |  3   | Outlook Add-in Conflict              | -- (informational only)       |
    |  4   | Sign-in / SSO Token Cache            | Warning ($AllowDestructiveActs)|
    |  5   | Camera / Webcam Permission           | Warning ($AllowDestructiveActs)|
    +------+--------------------------------------+-------------------------------+

    Step 2 note: Zoom updater health is reported but not restarted. In
    MDM-managed fleets, Zoom versioning is controlled through deployment
    packages -- triggering Zoom's own update mechanism outside that pipeline
    may conflict with approved version targeting.

    Step 5 note: Camera access is checked via the Windows Privacy Consent Store
    (per-app webcam deny state). Resolution sets the Value to 'Allow' for
    Zoom's specific executable path, not for all apps globally.

    SYSTEM-context note: Zoom stores profile and log data under
    %appdata%\Zoom, which is per-user. This script resolves the logged-on
    user's profile via Win32_ComputerSystem.UserName rather than using
    $env:APPDATA, which resolves to the SYSTEM profile when the script runs
    as SYSTEM and must not be used for per-user Zoom data paths.

.PARAMETER CacheSizeWarningMB
    Combined size of the Zoom data and logs directories above which a warning
    is raised and safe cache/log files are cleared.
    Default: 500 MB. Override via $env:CacheSizeWarningMB.

.PARAMETER AllowDestructiveActions
    When $true, enables remediations that affect user session state:
      - Step 4: Clears Zoom auth/token cache files (forces Zoom re-login).
      - Step 5: Sets webcam consent to Allow for Zoom's executable path.
    Default: $false.

.NOTES
    Script Name  : Invoke-AutoRemediateZoom.ps1
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
    [int] $CacheSizeWarningMB      = $(if ($env:CacheSizeWarningMB)      { [int]$env:CacheSizeWarningMB }                               else { 500 }),
    [bool]$AllowDestructiveActions = $(if ($env:AllowDestructiveActions)  { [System.Convert]::ToBoolean($env:AllowDestructiveActions) } else { $false })
)

# -- Pre-flight: resolve logged-on user context -------------------------------
# SYSTEM context: $env:APPDATA resolves to the SYSTEM profile.
# Zoom profile and log data lives under %appdata%\Zoom, which is per-user.
# Derive the actual user profile from WMI to access per-user Zoom data paths.
$_loggedOnUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$_shortName    = if ($_loggedOnUser) { $_loggedOnUser.Split('\')[-1] } else { $null }
$_userProfile  = if ($_shortName -and (Test-Path "C:\Users\$_shortName")) { "C:\Users\$_shortName" } else { $null }

$_userSid = $null
if ($_loggedOnUser) {
    try {
        $_userSid = ([Security.Principal.NTAccount]$_loggedOnUser).Translate([Security.Principal.SecurityIdentifier]).Value
    } catch { }
}

# -- Pre-flight: detect Zoom install ------------------------------------------
# Zoom can be installed system-wide (Program Files, via MSI) or per-user
# (AppData\Roaming\Zoom\bin, via EXE installer). Check App Paths registry
# first (covers both), then fall back to common paths.
$_zoomExe = $null

$_appPathKey = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Zoom.exe' -ErrorAction SilentlyContinue
if ($_appPathKey -and $_appPathKey.'(default)' -and (Test-Path $_appPathKey.'(default)')) {
    $_zoomExe = $_appPathKey.'(default)'
}
if (-not $_zoomExe) {
    foreach ($candidate in @(
        "$env:ProgramFiles\Zoom\bin\Zoom.exe",
        "${env:ProgramFiles(x86)}\Zoom\bin\Zoom.exe",
        (if ($_userProfile) { "$_userProfile\AppData\Roaming\Zoom\bin\Zoom.exe" } else { $null })
    )) {
        if ($candidate -and (Test-Path $candidate)) { $_zoomExe = $candidate; break }
    }
}

if (-not $_zoomExe) {
    Write-Host "`n-- Invoke-AutoRemediateZoom ------------------------------------" -ForegroundColor Cyan
    Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host '   [Skipped] Zoom does not appear to be installed on this device.'
    Write-Host "----------------------------------------------------------------`n" -ForegroundColor Cyan
    exit 0
}

# Per-user Zoom data paths (only resolvable when a user is logged on)
$_zoomDataPath = if ($_userProfile) { Join-Path $_userProfile 'AppData\Roaming\Zoom\data' } else { $null }
$_zoomLogsPath = if ($_userProfile) { Join-Path $_userProfile 'AppData\Roaming\Zoom\logs' } else { $null }

# -- Step Definitions ---------------------------------------------------------
$Steps = @(

    @{
        Name             = 'Zoom Cache / Log Bloat'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $true   # Log and cache clear is the standard IT recommendation; no destructive flag needed
        DetectionScript  = {
            if (-not $_zoomDataPath -or -not $_zoomLogsPath) {
                return @{ Status = 'Passed'; Message = 'Zoom data paths cannot be resolved -- cache check requires a logged-on user.' }
            }
            $totalMB = 0
            foreach ($dir in @($_zoomDataPath, $_zoomLogsPath)) {
                if (Test-Path $dir) {
                    $totalMB += [math]::Round((Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue |
                        Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum / 1MB, 0)
                }
            }
            if ($totalMB -ge $CacheSizeWarningMB) {
                return @{ Status = 'Warning'; Message = "Zoom data/logs total ${totalMB}MB (threshold: ${CacheSizeWarningMB}MB). Will clear log files and cache subdirectory if Zoom is not running." }
            }
            return @{ Status = 'Passed'; Message = "Zoom data/logs total ${totalMB}MB (threshold: ${CacheSizeWarningMB}MB)." }
        }
        ResolutionScript = {
            if (Get-Process -Name Zoom -ErrorAction SilentlyContinue) {
                throw 'Zoom is running -- log and cache files may be locked. Stop Zoom before running this remediation.'
            }
            $cleared = 0
            # Clear all log files -- Zoom recreates these on next launch
            if (Test-Path $_zoomLogsPath) {
                Get-ChildItem $_zoomLogsPath -File -ErrorAction SilentlyContinue |
                    Remove-Item -Force -ErrorAction SilentlyContinue
                $cleared++
                Write-Host "  [Info] Cleared Zoom log files from: $_zoomLogsPath" -ForegroundColor DarkYellow
            }
            # Clear the Zoom data cache subdirectory only -- do not clear the full data dir
            # (it contains SQLite databases and user configuration that must be preserved)
            $cacheSubDir = Join-Path $_zoomDataPath 'cache'
            if (Test-Path $cacheSubDir) {
                Get-ChildItem $cacheSubDir -Recurse -File -ErrorAction SilentlyContinue |
                    Remove-Item -Force -ErrorAction SilentlyContinue
                $cleared++
                Write-Host "  [Info] Cleared Zoom data cache from: $cacheSubDir" -ForegroundColor DarkYellow
            }
            if ($cleared -eq 0) {
                Write-Host '  [Info] No Zoom log or cache directories found to clear.' -ForegroundColor DarkYellow
            }
        }
    },

    @{
        Name             = 'Zoom Updater / Version Health'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $issues = @()

            # Report installed version (from binary)
            $installedVersion = try {
                (Get-Item $_zoomExe -ErrorAction SilentlyContinue).VersionInfo.ProductVersion
            } catch { 'unknown' }

            # Check for the Zoom Automatic Updater scheduled task
            $updateTask = Get-ScheduledTask -TaskName 'Zoom Automatic Updater' -ErrorAction SilentlyContinue
            if ($updateTask) {
                if ($updateTask.State -eq 'Disabled') {
                    $issues += "Zoom Automatic Updater task is Disabled (updates will not run automatically)"
                }
            }

            # Check Zoom update policy registry (ZoomUpdate key)
            $zoomUpdateKey = Get-ItemProperty 'HKLM:\SOFTWARE\Zoom\ZoomUpdate' -ErrorAction SilentlyContinue
            if ($zoomUpdateKey) {
                if ($zoomUpdateKey.EnableAutoUpdate -eq 0) {
                    $issues += "ZoomUpdate\\EnableAutoUpdate=0 (auto-update disabled via registry policy)"
                }
            }

            $versionNote = "Installed version: $installedVersion."
            if ($issues) {
                return @{ Status = 'Warning'; Message = "$versionNote Updater issue(s): $($issues -join '; '). Review via MDM deployment policy." }
            }
            $taskNote = if ($updateTask) { " Update task state: $($updateTask.State)." } else { ' Zoom Automatic Updater task not found (may be MSI-managed deployment).' }
            return @{ Status = 'Passed'; Message = "$versionNote$taskNote" }
        }
        ResolutionScript = $null   # Updates managed via MDM deployment -- triggering Zoom's own updater may conflict with version targeting
    },

    @{
        Name             = 'Outlook Add-in Conflict'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            # Check for the Zoom Outlook COM add-in registration in both user (via HKU)
            # and machine scope. The add-in can be registered at either level depending
            # on whether Zoom was installed per-user or system-wide.
            if (-not $_userSid) {
                return @{ Status = 'Passed'; Message = 'Cannot resolve user SID -- Outlook add-in check skipped.' }
            }
            $addInSearchPaths = @(
                "Registry::HKEY_USERS\$_userSid\Software\Microsoft\Office\Outlook\Addins",
                'HKLM:\SOFTWARE\Microsoft\Office\Outlook\Addins'
            )
            $found = @()
            foreach ($searchPath in $addInSearchPaths) {
                if (-not (Test-Path $searchPath)) { continue }
                Get-ChildItem $searchPath -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -like '*Zoom*' } |
                ForEach-Object {
                    $lb     = (Get-ItemProperty $_.PSPath -Name 'LoadBehavior' -ErrorAction SilentlyContinue).LoadBehavior
                    $scope  = if ($searchPath -like '*HKEY_USERS*') { 'User' } else { 'Machine' }
                    $lbDesc = switch ($lb) {
                        0       { 'Disabled' }
                        2       { 'Disabled by crash protection' }
                        3       { 'Active' }
                        8       { 'Disabled by user' }
                        default { "LoadBehavior=$lb" }
                    }
                    $found += "$($_.PSChildName) ($scope): $lbDesc"
                }
            }
            if (-not $found) {
                return @{ Status = 'Passed'; Message = 'Zoom Outlook add-in not found -- no Outlook plugin installed or registered.' }
            }
            $summary = $found -join '; '
            # Flag specifically if crash protection disabled the add-in (LoadBehavior=2),
            # which indicates a recent add-in failure that Outlook's built-in protection caught
            if ($found | Where-Object { $_ -like '*Disabled by crash protection*' }) {
                return @{ Status = 'Warning'; Message = "Zoom Outlook add-in was auto-disabled by Office crash protection: $summary. If Outlook stability issues recur, consider disabling the add-in via MDM policy." }
            }
            return @{ Status = 'Passed'; Message = "Zoom Outlook add-in found: $summary." }
        }
        ResolutionScript = $null   # Add-in enable/disable is an admin/MDM policy action -- do not silently change LoadBehavior
    },

    @{
        Name             = 'Sign-in / SSO Token Cache'
        Order            = 4
        Enabled          = $true
        ResolveOnWarning = $AllowDestructiveActions   # Clears Zoom auth files, forcing re-login -- gated
        DetectionScript  = {
            if (-not $_zoomLogsPath -or -not (Test-Path $_zoomLogsPath)) {
                return @{ Status = 'Passed'; Message = 'Zoom logs path not found -- sign-in check skipped.' }
            }
            # Scan recent Zoom log entries for auth/SSO failure patterns.
            # Proxy approach: direct token introspection is not feasible from SYSTEM context
            # without Zoom's internal APIs.
            $latestLog = Get-ChildItem $_zoomLogsPath -Filter '*.log' -File -ErrorAction SilentlyContinue |
                         Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $latestLog) {
                return @{ Status = 'Passed'; Message = 'No Zoom log files found -- sign-in check skipped.' }
            }
            $logLines  = Get-Content $latestLog.FullName -Tail 500 -ErrorAction SilentlyContinue
            $authErrors = $logLines | Where-Object {
                $_ -match 'sign.?in.fail|SSO.error|token.expir|auth.fail|login.fail|401|SAML.error|sso_token'
            }
            $errorCount = if ($authErrors) { $authErrors.Count } else { 0 }
            if ($errorCount -gt 0) {
                return @{ Status = 'Warning'; Message = "$errorCount sign-in/auth failure pattern(s) found in Zoom log (last 500 lines of $($latestLog.Name))$(if (-not $AllowDestructiveActions) { '. Set $AllowDestructiveActions=$true to clear auth cache' } else { '' })." }
            }
            return @{ Status = 'Passed'; Message = "No sign-in/auth failure patterns found in Zoom log ($($latestLog.Name))." }
        }
        ResolutionScript = {
            # Clears Zoom auth-related files from the data directory to force re-authentication.
            # Targets files matching auth/token/login patterns -- does not delete the full
            # Zoom data directory or its SQLite databases (which would reset all user settings).
            if (Get-Process -Name Zoom -ErrorAction SilentlyContinue) {
                throw 'Zoom is running -- auth files may be locked. Stop Zoom before clearing auth cache.'
            }
            if (-not (Test-Path $_zoomDataPath)) {
                Write-Host '  [Info] Zoom data path not found -- no auth files to clear.' -ForegroundColor DarkYellow
                return
            }
            $authFiles = Get-ChildItem $_zoomDataPath -File -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -match 'auth|token|login|sso|credential' }
            if ($authFiles) {
                $authFiles | Remove-Item -Force -ErrorAction SilentlyContinue
                Write-Host "  [Info] Cleared $($authFiles.Count) Zoom auth/token file(s). Zoom will prompt for sign-in on next launch." -ForegroundColor DarkYellow
            } else {
                Write-Host '  [Info] No auth/token files matched the expected pattern in Zoom data directory.' -ForegroundColor DarkYellow
            }
        }
    },

    @{
        Name             = 'Camera / Webcam Permission'
        Order            = 5
        Enabled          = $true
        ResolveOnWarning = $AllowDestructiveActions   # Modifies Windows Privacy consent store for Zoom -- gated
        DetectionScript  = {
            if (-not $_userSid) {
                return @{ Status = 'Passed'; Message = 'Cannot resolve user SID -- webcam permission check skipped.' }
            }
            # Check the global webcam consent setting for the user
            $globalWebcamPath  = "Registry::HKEY_USERS\$_userSid\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam"
            $globalValue       = if (Test-Path $globalWebcamPath) {
                (Get-ItemProperty $globalWebcamPath -Name 'Value' -ErrorAction SilentlyContinue).Value
            } else { $null }

            if ($globalValue -eq 'Deny') {
                return @{ Status = 'Warning'; Message = "Webcam access is globally denied for this user (ConsentStore\webcam Value=Deny). All apps including Zoom will be blocked. User must enable Camera access in Windows Settings > Privacy > Camera." }
            }

            # Check for a Zoom-specific deny entry under NonPackaged
            # Win32 non-packaged app keys use the exe path with backslashes replaced by #
            $webcamNonPkgPath = "$globalWebcamPath\NonPackaged"
            if (-not (Test-Path $webcamNonPkgPath)) {
                return @{ Status = 'Passed'; Message = 'No per-app webcam consent entries found -- global setting applies (webcam allowed by default).' }
            }
            # Search for any key matching Zoom's exe name (handles varying install paths)
            $zoomWebcamKeys = Get-ChildItem $webcamNonPkgPath -ErrorAction SilentlyContinue |
                              Where-Object { $_.PSChildName -like '*Zoom*' }
            if (-not $zoomWebcamKeys) {
                return @{ Status = 'Passed'; Message = 'No Zoom-specific webcam consent entry found (global setting applies).' }
            }
            $denied = $zoomWebcamKeys | Where-Object {
                (Get-ItemProperty $_.PSPath -Name 'Value' -ErrorAction SilentlyContinue).Value -eq 'Deny'
            }
            if ($denied) {
                $denyPaths = ($denied | Select-Object -ExpandProperty PSChildName) -join ', '
                return @{ Status = 'Warning'; Message = "Webcam access is denied for Zoom: $denyPaths$(if (-not $AllowDestructiveActions) { '. Set $AllowDestructiveActions=$true to grant access' } else { '' })." }
            }
            $allowedNote = ($zoomWebcamKeys | ForEach-Object {
                $v = (Get-ItemProperty $_.PSPath -Name 'Value' -ErrorAction SilentlyContinue).Value
                "$($_.PSChildName): $v"
            }) -join '; '
            return @{ Status = 'Passed'; Message = "Zoom webcam consent: $allowedNote." }
        }
        ResolutionScript = {
            # Sets webcam consent to Allow for Zoom's specific ConsentStore entry.
            # Only modifies the Zoom-specific per-app key -- does not change the global
            # webcam consent setting (which would affect all apps on the device).
            $webcamNonPkgPath = "Registry::HKEY_USERS\$_userSid\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam\NonPackaged"
            $zoomWebcamKeys   = Get-ChildItem $webcamNonPkgPath -ErrorAction SilentlyContinue |
                                Where-Object { $_.PSChildName -like '*Zoom*' }
            if (-not $zoomWebcamKeys) {
                # Zoom's key doesn't exist yet -- create it from the detected exe path
                # Path format: replace \ with # (e.g., C:#Program Files#Zoom#bin#Zoom.exe)
                $encodedPath = $_zoomExe -replace '\\', '#'
                $newKeyPath  = "$webcamNonPkgPath\$encodedPath"
                if (-not (Test-Path $newKeyPath)) {
                    New-Item -Path $newKeyPath -Force -ErrorAction Stop | Out-Null
                }
                Set-ItemProperty -Path $newKeyPath -Name 'Value' -Value 'Allow' -Type String -ErrorAction Stop
                Write-Host "  [Info] Created Zoom webcam consent key and set Value=Allow: $newKeyPath" -ForegroundColor DarkYellow
            } else {
                $zoomWebcamKeys | ForEach-Object {
                    Set-ItemProperty -Path $_.PSPath -Name 'Value' -Value 'Allow' -Type String -ErrorAction SilentlyContinue
                    Write-Host "  [Info] Set webcam consent Value=Allow for: $($_.PSChildName)" -ForegroundColor DarkYellow
                }
            }
        }
    }
)

# -- Execution Engine ---------------------------------------------------------
$activeSteps = $Steps | Where-Object { $_.Enabled } | Sort-Object { [int]$_.Order }
$results     = [System.Collections.Generic.List[PSCustomObject]]::new()

$zoomVersion = try {
    (Get-Item $_zoomExe -ErrorAction SilentlyContinue).VersionInfo.ProductVersion
} catch { 'unknown' }

Write-Host "`n-- Invoke-AutoRemediateZoom ------------------------------------" -ForegroundColor Cyan
Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)   Version: $zoomVersion   User: $(if ($_loggedOnUser) { $_loggedOnUser } else { 'unknown' })"
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
$regPath = 'HKLM:\Software\AirWatch\Extension\DEXRecords\ZoomErrors'
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
    Set-ItemProperty -Path $regPath -Name 'LastScanTime'    -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Type String
    Set-ItemProperty -Path $regPath -Name 'ZoomVersion'     -Value $zoomVersion    -Type String
    Set-ItemProperty -Path $regPath -Name 'TotalSteps'      -Value $results.Count  -Type DWord
    Set-ItemProperty -Path $regPath -Name 'PassedCount'     -Value $passed         -Type DWord
    Set-ItemProperty -Path $regPath -Name 'WarningCount'    -Value $warnings       -Type DWord
    Set-ItemProperty -Path $regPath -Name 'FailedCount'     -Value $failed         -Type DWord
    Set-ItemProperty -Path $regPath -Name 'RemediatedCount' -Value $remCount       -Type DWord

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
