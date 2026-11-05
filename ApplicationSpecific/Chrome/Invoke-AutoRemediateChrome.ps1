<#
.SYNOPSIS
    Invoke-AutoRemediateChrome -- Automated Google Chrome diagnostic and remediation.

.DESCRIPTION
    Runs a sequenced set of Chrome-specific health checks and automatically
    remediates where safe to do so. Targets the most common causes of Chrome
    performance and reliability issues within the app's own footprint.

    Steps covered by generic scripts are intentionally excluded here:
      - Network connectivity       --> Invoke-AutoRemediateNetworkStack.ps1
      - Driver issues              --> Invoke-AutoRemediateDriverIssues.ps1
      - Disk space                 --> DiskCleanup scripts
      - Windows Update             --> Invoke-AutoRemediateWindowsUpdates.ps1

    +------+--------------------------------------+-------------------------------+
    | Step | Name                                 | Remediates On                 |
    +------+--------------------------------------+-------------------------------+
    |  1   | Chrome Cache Bloat                   | Warning (auto -- safe clear)  |
    |  2   | Extension Count / Conflicts          | -- (informational only)       |
    |  3   | Google Update Service Health         | -- (informational only)       |
    |  4   | Enterprise Policy Check              | -- (informational only)       |
    |  5   | GPU / Renderer Crash Loop            | -- (informational only)       |
    |  6   | Stale NativeMessaging Hosts          | Warning (auto -- safe prune)  |
    +------+--------------------------------------+-------------------------------+

    Step 3 note: the Google updater service state is reported but not restarted.
    Current Chrome ships GoogleUpdaterService<version> / GoogleUpdaterInternalService<version>
    (Automatic, normally Stopped between runs); older installs have gupdate / gupdatem.
    Either family counts as present; only a Disabled service or no service at all is flagged. In MDM-managed fleets Chrome versioning is controlled
    through deployment packages -- restarting the update service outside that
    pipeline may conflict with approved version targeting or update ring controls.

    SYSTEM-context note: Chrome stores all user profile and cache data under
    %localappdata%\Google\Chrome\User Data, which is per-user. This script
    resolves the logged-on user's profile via Win32_ComputerSystem.UserName
    rather than using $env:LOCALAPPDATA, which resolves to the SYSTEM profile
    when the script runs as SYSTEM and must not be used for per-user data paths.

.PARAMETER CacheSizeWarningMB
    Combined size of Chrome's Cache and Code Cache directories above which a
    warning is raised and the cache is cleared.
    Default: 500 MB. Override via $env:CacheSizeWarningMB.

.PARAMETER ExtensionCountWarning
    Number of installed Chrome extensions above which a warning is raised
    (informational -- extensions are listed but not disabled).
    Default: 20. Override via $env:ExtensionCountWarning.

.PARAMETER AllowDestructiveActions
    Reserved for future use. Not currently required by any step in this script.
    Default: $false.

.NOTES
    Script Name  : Invoke-AutoRemediateChrome.ps1
    Version      : 1.0.3
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05 (1.0.3: the per-user candidate in the install fallback was a
                   bare if inside parentheses, which PowerShell ran as a command named "if";
                   the error aborted the fallback foreach, so a Chrome without an HKLM App
                   Paths entry was reported as not installed. Same defect as Zoom 1.0.1.
                   1.0.2: step 3 recognises the current GoogleUpdaterService* pair and
                   no longer warns on every machine; step 4 reads UpdateDefault from Policies\Google\Update
                   and the Chrome app GUID override, where the policy actually lives; step 6 reads the
                   logged-on user's hive through HKEY_USERS\<SID> so per-user orphaned hosts are found
                   under SYSTEM; step 1 reports a deferred clear when Chrome is running and counts files
                   it could not delete instead of throwing)
    Timeout      : 60 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
function Invoke-AutoRemediateChrome {
param(
    [int] $CacheSizeWarningMB      = $(if ($env:CacheSizeWarningMB)      { [int]$env:CacheSizeWarningMB }                               else { 500 }),
    [int] $ExtensionCountWarning   = $(if ($env:ExtensionCountWarning)   { [int]$env:ExtensionCountWarning }                           else { 20 }),
    [bool]$AllowDestructiveActions = $(if ($env:AllowDestructiveActions)  { [System.Convert]::ToBoolean($env:AllowDestructiveActions) } else { $false })
)

# -- Pre-flight: resolve logged-on user context -------------------------------
# SYSTEM context: $env:LOCALAPPDATA resolves to the SYSTEM profile.
# Chrome user data (cache, profile, extensions) is always per-user under
# %localappdata%\Google\Chrome\User Data -- must be resolved from the logged-on
# user's actual profile path.
$_loggedOnUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$_shortName    = if ($_loggedOnUser) { $_loggedOnUser.Split('\')[-1] } else { $null }
$_userProfile  = if ($_shortName -and (Test-Path "C:\Users\$_shortName")) { "C:\Users\$_shortName" } else { $null }

# -- Pre-flight: detect Chrome install ----------------------------------------
# Chrome can be installed system-wide (Program Files) or per-user (AppData).
# The App Paths registry key is the most reliable detection point for both.
$_chromeExe = $null

$_appPathKey = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction SilentlyContinue
if ($_appPathKey -and $_appPathKey.'(default)' -and (Test-Path $_appPathKey.'(default)')) {
    $_chromeExe = $_appPathKey.'(default)'
}
if (-not $_chromeExe) {
    # Built as a list first: a bare if inside @( ) is parsed as a command named "if",
    # and the error aborted the whole foreach, so 1.0.2 never reached these paths.
    $_candidates = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe")
    if ($_userProfile) { $_candidates += "$_userProfile\AppData\Local\Google\Chrome\Application\chrome.exe" }
    foreach ($candidate in $_candidates) {
        if ($candidate -and (Test-Path $candidate)) { $_chromeExe = $candidate; break }
    }
}

if (-not $_chromeExe) {
    Write-Output "`r`n-- Invoke-AutoRemediateChrome -----------------------------------"
    Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Output '   [Skipped] Google Chrome does not appear to be installed on this device.'
    Write-Output "----------------------------------------------------------------`r`n"
    exit 0
}

# Per-user Chrome data paths (only resolvable when a user is logged on)
$_chromeUserDataPath = if ($_userProfile) { Join-Path $_userProfile 'AppData\Local\Google\Chrome\User Data' } else { $null }
$_chromeDefaultPath  = if ($_chromeUserDataPath) { Join-Path $_chromeUserDataPath 'Default' } else { $null }

# The logged-on user's hive. Under SYSTEM, HKCU: is SYSTEM's own hive, so per-user
# NativeMessaging hosts were never seen; HKEY_USERS\<SID> is the user's hive from any context.
$_userHive = $null
if ($_loggedOnUser) {
    try {
        $_sid = ([System.Security.Principal.NTAccount]$_loggedOnUser).Translate([System.Security.Principal.SecurityIdentifier]).Value
        if (Test-Path "Registry::HKEY_USERS\$_sid") { $_userHive = "Registry::HKEY_USERS\$_sid" }
    } catch { $_userHive = $null }
}
# Step 6 search paths: the user's hive (or HKCU when it is the same user, or no user resolved), then the machine hives.
$_nmhSearchPaths = {
    $paths = @()
    if ($_userHive) { $paths += "$_userHive\Software\Google\Chrome\NativeMessagingHosts" }
    $paths += 'HKCU:\Software\Google\Chrome\NativeMessagingHosts'
    $paths += 'HKLM:\SOFTWARE\Google\Chrome\NativeMessagingHosts'
    $paths += 'HKLM:\SOFTWARE\WOW6432Node\Google\Chrome\NativeMessagingHosts'
    # HKCU and the resolved hive are the same key for an interactive run; keep one of each target.
    $seen = @{}
    foreach ($p in $paths) {
        $key = $p
        try { $item = Get-Item -Path $p -ErrorAction SilentlyContinue; if ($item) { $key = $item.Name } } catch { }
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $p }
    }
}

# -- Step Definitions ---------------------------------------------------------
$Steps = @(

    @{
        Name             = 'Chrome Cache Bloat'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $true   # Cache clear is the standard IT recommendation; no destructive flag needed
        DetectionScript  = {
            if (-not $_chromeDefaultPath -or -not (Test-Path $_chromeDefaultPath)) {
                return @{ Status = 'Passed'; Message = 'Chrome Default profile path not found -- cache check requires a logged-on user.' }
            }
            $totalMB = 0
            foreach ($folder in @('Cache', 'Code Cache')) {
                $fullPath = Join-Path $_chromeDefaultPath $folder
                if (Test-Path $fullPath) {
                    $totalMB += [math]::Round((Get-ChildItem $fullPath -Recurse -File -ErrorAction SilentlyContinue |
                        Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum / 1MB, 0)
                }
            }
            if ($totalMB -ge $CacheSizeWarningMB) {
                return @{ Status = 'Warning'; Message = "Chrome cache is ${totalMB}MB (threshold: ${CacheSizeWarningMB}MB). Will clear Cache and Code Cache if Chrome is not running." }
            }
            return @{ Status = 'Passed'; Message = "Chrome cache is ${totalMB}MB (threshold: ${CacheSizeWarningMB}MB)." }
        }
        ResolutionScript = {
            if (Get-Process -Name chrome -ErrorAction SilentlyContinue) {
                # Not an error: the cache is locked while Chrome runs. Say so and leave the
                # Warning standing, so the next run (with Chrome closed) does the clear.
                Write-Output '  [Info] Cache clear deferred: Chrome is running and holds its cache folders. It will be cleared on a run when Chrome is closed.'
                return
            }
            $cleared = 0; $failed = 0
            foreach ($folder in @('Cache', 'Code Cache')) {
                $fullPath = Join-Path $_chromeDefaultPath $folder
                if (Test-Path $fullPath) {
                    foreach ($file in @(Get-ChildItem $fullPath -Recurse -File -ErrorAction SilentlyContinue)) {
                        try { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop } catch { $failed++ }
                    }
                    $cleared++
                }
            }
            Write-Output "  [Info] Cleared $cleared Chrome cache folder(s)$(if ($failed) { ", $failed file(s) could not be deleted (still in use)" }). Chrome will rebuild cache on next launch."
        }
    },

    @{
        Name             = 'Extension Count / Conflicts'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if (-not $_chromeDefaultPath -or -not (Test-Path $_chromeDefaultPath)) {
                return @{ Status = 'Passed'; Message = 'Chrome Default profile path not found -- extension check requires a logged-on user.' }
            }
            $extRoot = Join-Path $_chromeDefaultPath 'Extensions'
            if (-not (Test-Path $extRoot)) {
                return @{ Status = 'Passed'; Message = 'No Extensions directory found in Chrome Default profile.' }
            }
            # Each extension is a subdirectory named by its Chrome ID (32-char base-26)
            $extDirs = Get-ChildItem $extRoot -Directory -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -match '^[a-p]{32}$' }
            $count   = if ($extDirs) { $extDirs.Count } else { 0 }

            if ($count -ge $ExtensionCountWarning) {
                # Attempt to read extension names from manifest files for the report
                $names = $extDirs | ForEach-Object {
                    $manifest = Get-ChildItem $_.FullName -Recurse -Filter 'manifest.json' -ErrorAction SilentlyContinue |
                                Select-Object -First 1
                    if ($manifest) {
                        try {
                            $json = Get-Content $manifest.FullName -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
                            if ($json.name -and $json.name -notmatch '^__MSG_') { $json.name } else { $_.Name }
                        } catch { $_.Name }
                    } else { $_.Name }
                }
                $nameList = ($names | Select-Object -First 10) -join ', '
                $more     = if ($count -gt 10) { " (and $($count - 10) more)" } else { '' }
                return @{ Status = 'Warning'; Message = "$count Chrome extensions installed (threshold: $ExtensionCountWarning). Review for unrecognized/conflicting extensions: $nameList$more." }
            }
            return @{ Status = 'Passed'; Message = "$count Chrome extension(s) installed (threshold: $ExtensionCountWarning)." }
        }
        ResolutionScript = $null   # Extension management requires an allow/deny list policy -- do not silently disable user extensions
    },

    @{
        Name             = 'Google Update Service Health'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            # Two generations: legacy Google Update (gupdate, gupdatem) and the current Google
            # Updater (GoogleUpdaterService<ver>, GoogleUpdaterInternalService<ver>). Both run on
            # a schedule and sit Stopped in between, so Stopped is not a fault; Disabled is.
            # Name lookups only: a full Get-Service enumeration aborts on protected services
            # under PowerShell 7.
            $updaters = @()
            foreach ($n in 'gupdate', 'gupdatem') { $s = Get-Service -Name $n -ErrorAction SilentlyContinue; if ($s) { $updaters += $s } }
            $names = @(Get-CimInstance -ClassName Win32_Service -Filter "Name LIKE 'GoogleUpdater%'" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
            foreach ($n in $names) { $s = Get-Service -Name $n -ErrorAction SilentlyContinue; if ($s) { $updaters += $s } }

            if ($updaters.Count -eq 0) {
                return @{ Status = 'Warning'; Message = 'No Google updater service found (neither GoogleUpdaterService* nor gupdate). Chrome component and security updates may not arrive unless the fleet updates Chrome through MDM packages.' }
            }
            $disabled = @($updaters | Where-Object { $_.StartType -eq 'Disabled' } | ForEach-Object { $_.Name })
            if ($disabled.Count -gt 0) {
                return @{ Status = 'Warning'; Message = "Google updater service(s) Disabled: $($disabled -join ', '). Chrome component and security updates may be affected. Review via MDM update policy before changing." }
            }
            $summary = ($updaters | ForEach-Object { "$($_.Name) $($_.Status)/$($_.StartType)" }) -join '; '
            return @{ Status = 'Passed'; Message = "Google updater service(s) present: $summary." }
        }
        ResolutionScript = $null   # Updates managed via MDM deployment -- restarting gupdate outside that pipeline may conflict with version targeting
    },

    @{
        Name             = 'Enterprise Policy Check'
        Order            = 4
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $policyPath     = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
            $policyPathWow  = 'HKLM:\SOFTWARE\WOW6432Node\Policies\Google\Chrome'
            $activePath     = if (Test-Path $policyPath) { $policyPath } elseif (Test-Path $policyPathWow) { $policyPathWow } else { $null }

            if (-not $activePath) {
                return @{ Status = 'Passed'; Message = 'No Chrome enterprise policy keys found in HKLM (Chrome running with default/user settings).' }
            }
            $props       = Get-ItemProperty $activePath -ErrorAction SilentlyContinue
            $policyNames = $props.PSObject.Properties |
                           Where-Object { $_.Name -notmatch '^PS' } |
                           Select-Object -ExpandProperty Name
            $policyCount = $policyNames.Count

            # Flag specific high-impact policies that commonly cause user issues.
            # The update policy does not live under Policies\Google\Chrome: UpdateDefault sits under
            # Policies\Google\Update, and the per-app override for Chrome is the value
            # Update{8A69D345-D564-463C-AFF1-A69D9E530F96} on the same key (0 AutoUpdate, 1 Manual,
            # 2 Disabled, 3 AutoUpdate-manual-allowed). The override wins when present.
            $cbcmToken    = $props.CloudManagementEnrollmentToken
            $updatePolicy = $null
            foreach ($updPath in 'HKLM:\SOFTWARE\Policies\Google\Update', 'HKLM:\SOFTWARE\WOW6432Node\Policies\Google\Update') {
                if (-not (Test-Path $updPath)) { continue }
                $upd = Get-ItemProperty $updPath -ErrorAction SilentlyContinue
                if ($null -ne $upd.'Update{8A69D345-D564-463C-AFF1-A69D9E530F96}') { $updatePolicy = $upd.'Update{8A69D345-D564-463C-AFF1-A69D9E530F96}'; $updateSource = 'Chrome app override' }
                elseif ($null -ne $upd.UpdateDefault)                                 { $updatePolicy = $upd.UpdateDefault; $updateSource = 'UpdateDefault' }
                if ($null -ne $updatePolicy) { break }
            }
            $issues = @()
            if ($updatePolicy -eq 2) {
                $issues += "$updateSource=2 (auto-updates disabled via Google Update policy)"
            }
            elseif ($updatePolicy -eq 1) {
                $issues += "$updateSource=1 (manual updates only via Google Update policy)"
            }
            if ($issues) {
                return @{ Status = 'Warning'; Message = "$policyCount Chrome policy value(s) applied. Potential issues: $($issues -join '; ')." }
            }
            $cbcmNote = if ($cbcmToken) { ' CBCM enrollment token present.' } else { ' No CBCM token (may be GPO-managed or unmanaged).' }
            return @{ Status = 'Passed'; Message = "$policyCount Chrome policy value(s) applied.$cbcmNote" }
        }
        ResolutionScript = $null   # Policy changes are an IT/admin action -- do not modify HKLM policy keys from a remediation script
    },

    @{
        Name             = 'GPU / Renderer Crash Loop'
        Order            = 5
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if (-not $_chromeUserDataPath -or -not (Test-Path $_chromeUserDataPath)) {
                return @{ Status = 'Passed'; Message = 'Chrome User Data path not found -- crash check requires a logged-on user.' }
            }
            $crashpadPath = Join-Path $_chromeUserDataPath 'Crashpad\reports'
            if (-not (Test-Path $crashpadPath)) {
                return @{ Status = 'Passed'; Message = 'Chrome crash report directory not found (no crashes recorded or Crashpad not initialized).' }
            }
            # Each crash event creates one file in this directory (minidump or metadata)
            $recentCrashFiles = Get-ChildItem $crashpadPath -File -ErrorAction SilentlyContinue |
                                Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-24) }
            $crashCount = if ($recentCrashFiles) { $recentCrashFiles.Count } else { 0 }

            if ($crashCount -ge 5) {
                return @{ Status = 'Warning'; Message = "$crashCount Chrome crash report file(s) in the last 24 hours. If crashes are GPU- or renderer-related, consider enabling the '--disable-gpu' flag via Chrome policy (RendererCodeIntegrityEnabled or a managed shortcut). Review crash dumps before forcing a fleet-wide flag." }
            }
            return @{ Status = 'Passed'; Message = "$crashCount Chrome crash report file(s) in the last 24 hours." }
        }
        ResolutionScript = $null   # GPU disable flag is a user/admin decision -- applying fleet-wide without crash triage may cause visual regressions
    },

    @{
        Name             = 'Stale NativeMessaging Hosts'
        Order            = 6
        Enabled          = $true
        ResolveOnWarning = $true   # Pruning orphaned registry keys is safe -- Chrome handles missing hosts gracefully
        DetectionScript  = {
            # NativeMessaging hosts are registered by third-party apps (e.g., password
            # managers, screen readers). When those apps are uninstalled, their registry
            # entries are often left behind. Chrome logs errors for missing manifest paths
            # and, in some cases, slows its startup loading process cycling through them.
            $orphaned = @()
            $searchPaths = @(& $_nmhSearchPaths)
            foreach ($regPath in $searchPaths) {
                if (-not (Test-Path $regPath)) { continue }
                Get-ChildItem $regPath -ErrorAction SilentlyContinue | ForEach-Object {
                    $manifestPath = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).'(default)'
                    if ($manifestPath -and -not (Test-Path $manifestPath)) {
                        $orphaned += [PSCustomObject]@{
                            HostName     = $_.PSChildName
                            RegPath      = $_.PSPath
                            ManifestPath = $manifestPath
                        }
                    }
                }
            }
            if ($orphaned.Count -gt 0) {
                $names = ($orphaned | Select-Object -ExpandProperty HostName) -join ', '
                return @{ Status = 'Warning'; Message = "$($orphaned.Count) orphaned NativeMessaging host registry entry/entries found (manifest no longer on disk): $names." }
            }
            return @{ Status = 'Passed'; Message = 'No orphaned NativeMessaging host registry entries found.' }
        }
        ResolutionScript = {
            # Re-enumerate orphaned hosts and remove their registry keys.
            # Chrome handles missing NativeMessaging hosts gracefully (it logs a warning
            # and continues). Removing stale entries cleans up Chrome's startup log noise.
            $searchPaths = @(& $_nmhSearchPaths)
            $removedCount = 0
            foreach ($regPath in $searchPaths) {
                if (-not (Test-Path $regPath)) { continue }
                Get-ChildItem $regPath -ErrorAction SilentlyContinue | ForEach-Object {
                    $manifestPath = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).'(default)'
                    if ($manifestPath -and -not (Test-Path $manifestPath)) {
                        Remove-Item $_.PSPath -Force -ErrorAction SilentlyContinue
                        Write-Output "  [Info] Removed orphaned NativeMessaging host: $($_.PSChildName) (manifest: $manifestPath)"
                        $removedCount++
                    }
                }
            }
            Write-Output "  [Info] Removed $removedCount orphaned NativeMessaging host registry key(s)."
        }
    }
)

# -- Execution Engine ---------------------------------------------------------
$activeSteps = $Steps | Where-Object { $_.Enabled } | Sort-Object { [int]$_.Order }
$results     = [System.Collections.Generic.List[PSCustomObject]]::new()

$chromeVersion = try {
    (Get-Item $_chromeExe -ErrorAction SilentlyContinue).VersionInfo.ProductVersion
} catch { 'unknown' }

Write-Output "`r`n-- Invoke-AutoRemediateChrome -----------------------------------"
Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)   Version: $chromeVersion   User: $(if ($_loggedOnUser) { $_loggedOnUser } else { 'unknown' })"
Write-Output '----------------------------------------------------------------'

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
    Write-Output "`r`n  [$($status.PadRight(7))] $($step.Name): $message$remNote"

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
# @() guards: in Windows PowerShell 5.1 a single PSCustomObject has no .Count, so a
# lone Failed step would otherwise yield $null here and the script would exit 0.
$passed   = @($results | Where-Object { $_.Status -eq 'Passed'  }).Count
$warnings = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed   = @($results | Where-Object { $_.Status -eq 'Failed'  }).Count
$remCount = @($results | Where-Object { $_.Remediated }).Count

Write-Output "`r`n----------------------------------------------------------------"
Write-Output "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations run: $remCount"
Write-Output "----------------------------------------------------------------`r`n"

# -- Registry Reporting -------------------------------------------------------
$regPath = 'HKLM:\Software\AirWatch\Extension\DEXRecords\ChromeErrors'
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
    Set-ItemProperty -Path $regPath -Name 'ChromeVersion'   -Value $chromeVersion  -Type String
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
    Write-Output "  [Registry] Results written to $regPath"
} catch {
    Write-Output "  [Registry] Write failed: $($_.Exception.Message)"
}

# -- Exit ---------------------------------------------------------------------
if ($failed -gt 0) { exit 1 }
exit 0
}

# -- entry point ---------------------------------------------------------------
# The param block sits inside the function deliberately. The Workspace ONE script
# engine does not recognise a param block at script scope, and $PSCmdlet is $null
# there, which makes every ShouldProcess call throw. Inputs arrive as environment
# variables and are bound to the function's parameters below.

Invoke-AutoRemediateChrome
Exit 0
