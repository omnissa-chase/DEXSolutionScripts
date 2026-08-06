#Requires -Version 5.1
<#
.SYNOPSIS
    Deprovisions non-essential inbox AppX/UWP packages to reduce AppX registration
    load at logon, with a curated, safety-netted default package list.

.DESCRIPTION
    The AppX/UWP load phase (AppReadiness event 209, measured by
    Measure-LogonDuration.ps1) scales with how many inbox packages Windows has to
    register or verify for the signed-in user. A stock Windows 11 image ships with
    a long list of consumer apps (games, weather, messaging, 3D tools) that most
    managed enterprise endpoints never use, and each one is still weight AppReadiness
    carries at every logon.

    This script only ever removes packages that match a deny-list pattern AND do
    not match the hard-coded safelist below. The safelist cannot be overridden --
    it exists specifically so that an over-broad DenyListExtra value can never
    remove something the shell, security tooling, or a core productivity app
    depends on.

    +------+-------------------------------------------------+---------------------------------------+
    | Step | Name                                              | Action                                 |
    +------+-------------------------------------------------+---------------------------------------+
    |  1   | Deprovision Non-Essential AppX (Future Users)    | Remove-AppxProvisionedPackage -Online  |
    |  2   | Remove Non-Essential AppX (Existing Users)       | Remove-AppxPackage -AllUsers (opt-in)  |
    +------+-------------------------------------------------+---------------------------------------+

    Step 1 only affects user profiles created AFTER it runs. It never touches an
    already-installed package for a user who has already logged on, and is safe
    to run broadly without user-visible impact.

    Step 2 additionally removes the matching packages for users who already have
    them installed (Start Menu tiles disappear). This is disabled by default --
    set RemoveForExistingUsers to enable it once step 1's package list has been
    reviewed and accepted for the environment.

    The default deny list targets commonly-removed consumer inbox apps (Xbox
    companion apps, Solitaire, Weather, News, People, Mixed Reality Portal,
    Messaging, Skype, Feedback Hub, 3D tools, Maps, Wallet, Family Safety,
    Clipchamp). It deliberately excludes anything with ambiguous enterprise use
    (Cortana, Phone Link, Widgets) -- add those via DenyListExtra only after
    confirming they are unused in this environment.

    Results are written to HKLM:\Software\AirWatch\Extensions\AppXBloat\Remediation.

.PARAMETER DenyListExtra
    Comma-separated list of additional DisplayName wildcard patterns to remove,
    beyond the built-in default list. Still subject to the safelist. Defaults to
    $env:DenyListExtra, then to an empty string (no additions).

.PARAMETER RemoveForExistingUsers
    When $true, also removes matching packages already installed for existing
    users (step 2), not just future ones. Defaults to $env:RemoveForExistingUsers,
    then to $false.

.EXAMPLE
    .\Invoke-AutoRemediateAppXBloat.ps1

    Deprovisions the default deny list for future users only. Recommended first
    deployment step.

.EXAMPLE
    $env:RemoveForExistingUsers = 'true'; .\Invoke-AutoRemediateAppXBloat.ps1 -DenyListExtra 'Microsoft.YourPhone*'

    Also removes the matching packages, including Phone Link, from already
    logged-on users.

.NOTES
    Script Name  : Invoke-AutoRemediateAppXBloat.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-05
    Timeout      : 90 seconds

    Environment variables:
      WhatIf                 = true   Dry run. Absent/unparseable => live run.
      DenyListExtra           (comma-separated DisplayName wildcard patterns)
      RemoveForExistingUsers = true   Absent/unparseable => false.

    Explicit parameters win over environment variables.

    Related, non-overlapping report:
      UnmanagedAppReport\Get-StartupApps.ps1  Run-key/Startup-folder apps, not AppX.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$DenyListExtra = $(
        if ([string]::IsNullOrWhiteSpace($env:DenyListExtra)) { '' } else { $env:DenyListExtra.Trim() }
    ),

    [bool]$RemoveForExistingUsers = $(
        $env:RemoveForExistingUsers -and $env:RemoveForExistingUsers.Trim() -in @('true', '1', 'yes', 'y')
    )
)

$SCRIPT_VERSION = "1.0.0"
$RegPath        = "HKLM:\Software\AirWatch\Extensions\AppXBloat\Remediation"
$LogPath        = "$env:SystemRoot\Temp\UEM_AutoRemediateAppXBloat.log"

# -- WhatIf bridge -------------------------------------------------------------
# UEM cannot set $WhatIfPreference directly. Bridge it from an environment
# variable. Absent, empty, or unparseable => $false (live run).
$WhatIfPreference = $false
if ($env:WhatIf) {
    try   { $WhatIfPreference = [System.Convert]::ToBoolean($env:WhatIf) }
    catch { $WhatIfPreference = $false }
}

# -- Run header ----------------------------------------------------------------
$RunEventId = ([Random]::new()).Next(1000, 9999)
Write-Host "[$RunEventId] Executing Invoke-AutoRemediateAppXBloat, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'  WhatIf=$WhatIfPreference  RemoveForExistingUsers=$RemoveForExistingUsers"
$HEAD = "`r`n[$RunEventId]"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    # -WhatIf:$false so a dry run is still recorded; the log is evidence, not state.
    "[$timestamp] [$RunEventId] [$Level] $Message" |
        Out-File -FilePath $LogPath -Append -Encoding UTF8 -WhatIf:$false -ErrorAction SilentlyContinue
}

# -- Pre-flight ------------------------------------------------------------------
if (-not (Get-Command -Name Get-AppxProvisionedPackage -ErrorAction SilentlyContinue)) {
    Write-Host "$HEAD AppX provisioning cmdlets are not available on this device (Server SKU, or Appx feature removed). Nothing to do." -ForegroundColor Yellow
    Write-Log 'Appx cmdlets unavailable. Exiting without changes.'
    exit 0
}

# -- Package lists ----------------------------------------------------------------
# DisplayName wildcard patterns. Reviewed for ambiguous enterprise use before
# inclusion -- Cortana, Phone Link, and Widgets are deliberately left out of the
# default and must be opted into via DenyListExtra.
$DefaultDenyPatterns = @(
    'Microsoft.BingWeather'
    'Microsoft.BingNews'
    'Microsoft.GamingApp*'
    'Microsoft.XboxApp'
    'Microsoft.Xbox.TCUI'
    'Microsoft.XboxGameOverlay'
    'Microsoft.XboxGamingOverlay'
    'Microsoft.XboxIdentityProvider'
    'Microsoft.XboxSpeechToTextOverlay'
    'Microsoft.MicrosoftSolitaireCollection'
    'Microsoft.People'
    'Microsoft.MixedReality.Portal'
    'Microsoft.Messaging'
    'Microsoft.OneConnect'
    'Microsoft.SkypeApp'
    'Microsoft.WindowsFeedbackHub'
    'Microsoft.GetHelp'
    'Microsoft.Getstarted'
    'Microsoft.Print3D'
    'Microsoft.3DBuilder'
    'Microsoft.WindowsMaps'
    'Microsoft.Wallet'
    '*MicrosoftFamily*'
    'Clipchamp.Clipchamp'
)

$ExtraDenyPatterns = @(
    if ($DenyListExtra) { $DenyListExtra -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
)

$DenyPatterns = @($DefaultDenyPatterns + $ExtraDenyPatterns | Select-Object -Unique)

# Hard-coded, not configurable. This is what stops an over-broad DenyListExtra
# from ever taking out a shell component, framework dependency, or core app.
$SafelistPatterns = @(
    'Microsoft.WindowsCalculator'
    'Microsoft.WindowsCamera'
    'Microsoft.WindowsNotepad'
    'Microsoft.Paint'
    'Microsoft.ScreenSketch'
    'Microsoft.WindowsStore'
    'Microsoft.Windows.Photos'
    'Microsoft.WindowsTerminal*'
    'Microsoft.Todos'
    'MicrosoftWindows.Client.WebExperience'
    'Microsoft.SecHealthUI'
    '*ShellExperienceHost*'
    '*StartMenuExperienceHost*'
    'Microsoft.NET.Native.*'
    'Microsoft.VCLibs.*'
    'Microsoft.UI.Xaml.*'
)

function Test-NameMatchesAny {
    param([string]$Name, [string[]]$Patterns)
    foreach ($pattern in $Patterns) {
        if ($Name -like $pattern) { return $true }
    }
    return $false
}

function Test-IsRemovalCandidate {
    param([string]$Name)
    (Test-NameMatchesAny -Name $Name -Patterns $DenyPatterns) -and
    -not (Test-NameMatchesAny -Name $Name -Patterns $SafelistPatterns)
}

Write-Log "Deny patterns ($($DenyPatterns.Count)): $($DenyPatterns -join ', ')"

$script:StepFailures = @()

# -- Step Definitions -----------------------------------------------------------
# Only supported fields: Name, Order, Enabled, ResolveOnWarning,
#                        DetectionScript, ResolutionScript
$Steps = @(

    @{
        Name             = 'Deprovision Non-Essential AppX (Future Users)'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $matchedPkgs = @(
                Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                    Where-Object { Test-IsRemovalCandidate -Name $_.DisplayName }
            )
            if ($matchedPkgs.Count -gt 0) {
                return @{ Status = 'Failed'; Message = "$($matchedPkgs.Count) provisioned package(s) match the deny list: $(($matchedPkgs.DisplayName) -join ', ')" }
            }
            return @{ Status = 'Passed'; Message = 'No matching packages are provisioned for new users' }
        }
        ResolutionScript = {
            $matchedPkgs = @(
                Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                    Where-Object { Test-IsRemovalCandidate -Name $_.DisplayName }
            )
            foreach ($pkg in $matchedPkgs) {
                try {
                    Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
                } catch {
                    $script:StepFailures += "$($pkg.DisplayName): $($_.Exception.Message)"
                }
            }
            if ($script:StepFailures.Count -gt 0) {
                throw "$($script:StepFailures.Count) of $($matchedPkgs.Count) package(s) failed to deprovision: $($script:StepFailures -join '; ')"
            }
        }
    },

    @{
        Name             = 'Remove Non-Essential AppX (Existing Users)'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if (-not $RemoveForExistingUsers) {
                return @{ Status = 'Passed'; Message = 'RemoveForExistingUsers is disabled; existing installs are left as-is' }
            }
            $matchedPkgs = @(
                Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
                    Where-Object { Test-IsRemovalCandidate -Name $_.Name }
            )
            if ($matchedPkgs.Count -gt 0) {
                return @{ Status = 'Failed'; Message = "$($matchedPkgs.Count) installed package instance(s) match the deny list: $(($matchedPkgs.Name | Select-Object -Unique) -join ', ')" }
            }
            return @{ Status = 'Passed'; Message = 'No matching packages are installed for existing users' }
        }
        ResolutionScript = {
            $matchedPkgs = @(
                Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
                    Where-Object { Test-IsRemovalCandidate -Name $_.Name }
            )
            foreach ($pkg in $matchedPkgs) {
                try {
                    Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop | Out-Null
                } catch {
                    $script:StepFailures += "$($pkg.Name): $($_.Exception.Message)"
                }
            }
            if ($script:StepFailures.Count -gt 0) {
                throw "$($script:StepFailures.Count) of $($matchedPkgs.Count) package instance(s) failed to remove: $($script:StepFailures -join '; ')"
            }
        }
    }
)

# -- Execution Engine ------------------------------------------------------------
$activeSteps = $Steps |
    Where-Object { $_.Enabled } |
    Sort-Object   { [int]$_.Order }

$results = New-Object 'System.Collections.Generic.List[PSCustomObject]'

Write-Host "`n-- Invoke-AutoRemediateAppXBloat --------------------------------" -ForegroundColor Cyan
Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)"
Write-Host '--------------------------------------------------------------------' -ForegroundColor Cyan

foreach ($step in $activeSteps) {

    $status     = 'Failed'
    $message    = 'Detection script did not return a result.'
    $remediated = $false
    $remError   = ''

    # -- Detection ------------------------------------------------------------
    $script:StepFailures = @()
    try {
        $result  = & $step.DetectionScript
        $status  = $result.Status
        $message = $result.Message
    } catch {
        $status  = 'Failed'
        $message = "Detection exception: $($_.Exception.Message)"
    }

    # -- Remediation ------------------------------------------------------------
    $shouldRemediate = ($status -eq 'Failed') -or
                       ($status -eq 'Warning' -and $step.ResolveOnWarning)

    if ($shouldRemediate -and $step.ResolutionScript) {
        if ($PSCmdlet.ShouldProcess($step.Name, 'Remove non-essential AppX package(s)')) {
            try {
                & $step.ResolutionScript | Out-Null
                $remediated = $true
            } catch {
                $remError = $_.Exception.Message
            }
        }
    }

    # -- Output -------------------------------------------------------------------
    $color = switch ($status) {
        'Passed'  { 'Green'  }
        'Warning' { 'Yellow' }
        'Failed'  { 'Red'    }
        default   { 'White'  }
    }
    $remNote = if ($remediated)   { '  -> Removal applied' }
               elseif ($remError) { "  -> Removal ERROR: $remError" }
               else               { '' }

    Write-Host "`n  [$($status.PadRight(7))] $($step.Name): $message$remNote" -ForegroundColor $color
    Write-Log "$($step.Name): $status - $message$remNote"

    $results.Add([PSCustomObject]@{
        Order      = $step.Order
        Name       = $step.Name
        Status     = $status
        Message    = $message
        Remediated = $remediated
        RemError   = $remError
    })
}

# -- Summary -----------------------------------------------------------------
$passed   = ($results | Where-Object { $_.Status -eq 'Passed'  }).Count
$warnings = ($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed   = ($results | Where-Object { $_.Status -eq 'Failed'  }).Count
$remCount = ($results | Where-Object { $_.Remediated }).Count
$remErrs  = ($results | Where-Object { $_.RemError }).Count

Write-Host "`n--------------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations applied: $remCount"
Write-Host "--------------------------------------------------------------------`n" -ForegroundColor Cyan
Write-Log "Summary: Passed=$passed Warnings=$warnings Failed=$failed RemediationsApplied=$remCount RemediationErrors=$remErrs"

# -- Registry Reporting --------------------------------------------------------
# Skipped entirely on a WhatIf run -- a dry run must not claim a remediation state
# that was never actually applied.
if (-not $WhatIfPreference) {
    try {
        if (-not (Test-Path $RegPath)) {
            New-Item -Path $RegPath -Force -ErrorAction Stop | Out-Null
        }
        Set-ItemProperty -Path $RegPath -Name 'LastRun'                -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Type String
        Set-ItemProperty -Path $RegPath -Name 'ScriptVersion'          -Value $SCRIPT_VERSION -Type String
        Set-ItemProperty -Path $RegPath -Name 'Passed'                 -Value $passed   -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'Warnings'               -Value $warnings -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'Failed'                 -Value $failed   -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'RemediationsRun'        -Value $remCount -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'RemediationErrors'      -Value $remErrs  -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'RemoveForExistingUsers' -Value ([int]$RemoveForExistingUsers) -Type DWord
        Write-Log "Results cached to $RegPath"
    } catch {
        Write-Log "Registry cache write failed: $($_.Exception.Message)" 'WARN'
    }
} else {
    Write-Log 'WhatIf run -- registry cache left untouched.'
}

exit $(if ($remErrs -gt 0) { 1 } else { 0 })
