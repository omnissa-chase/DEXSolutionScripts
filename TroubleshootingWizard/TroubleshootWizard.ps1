<#
.SYNOPSIS
    TroubleshootWizard - Generic JSON-Driven Diagnostic Engine (PowerShell 5.1 Compatible)
.DESCRIPTION
    Loads diagnostic steps from a JSON definition file, executes each step's
    DetectionScript, optionally runs a ResolutionScript on failure, then saves
    results to the registry.

    If TroubleshootWizard-UI.ps1 is present alongside this script, it is
    dot-sourced automatically and the WPF results window is shown after execution.
    If the UI file is absent (or -SkipUI is passed), the script runs fully silent
    with no WPF dependency.
.PARAMETER StepsJson
    Path to the JSON file that defines the diagnostic steps.
    If omitted, the script attempts to read it from the TroubleshootingWizard event log.
.PARAMETER Title
    Title shown in the WPF window header (default: 'Diagnostics Results').
.PARAMETER RegistryKey
    Registry sub-key under HKCU:\Software\Diagnostics where results are persisted.
    Defaults to the base name of the JSON file (e.g. 'NetworkDiagSteps').
.PARAMETER XamlFile
    XAML layout file name (relative to script directory) passed to the UI library.
    Default: 'UI-Modern-Light.xaml'
.PARAMETER SkipUI
    Run diagnostics only; suppress the WPF results popup even if the UI library is present.
.PARAMETER QuietMode
    Suppress console progress output.
.PARAMETER TimeoutSeconds
    Auto-close the popup after N seconds (default: 60).
.PARAMETER AutoRemediate
    If set, each step's ResolutionScript is run automatically when a step fails.
.EXAMPLE
    .\TroubleshootWizard.ps1 -StepsJson ".\NetworkDiagSteps.json"
.EXAMPLE
    .\TroubleshootWizard.ps1 -StepsJson "C:\Diag\AppSteps.json" -Title "App Health Check" -AutoRemediate
.EXAMPLE
    .\TroubleshootWizard.ps1 -StepsJson ".\NetworkDiagSteps.json" -SkipUI
    # Runs silently; no WPF even if TroubleshootWizard-UI.ps1 is present

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE in the repository root for full license terms (MIT).
#>

[CmdletBinding()]
param(
    [string] $StepsJson,
    [string] $Title          = 'Diagnostics Results',
    [string] $RegistryKey    = '',
    [string] $XamlFile       = 'UI-Modern-Light.xaml',
    [switch] $SkipUI,
    [switch] $QuietMode,
    [int]    $TimeoutSeconds = 60,
    [switch] $AutoRemediate
)

$ErrorActionPreference = 'Continue'

#region --- Logging ---
function Write-Log {
    param([string] $Message,
        [ValidateSet('INFO','WARNING','ERROR','DEBUG')]
        [string] $Level = 'INFO'
    )
    if ($QuietMode -and $Level -eq 'INFO') { return }
    $ts     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $colors = @{ ERROR = 'Red'; WARNING = 'Yellow'; DEBUG = 'Gray'; INFO = 'White' }
    Write-Host "[$ts] [$Level] $Message" -ForegroundColor $colors[$Level]
    $FileName = (Split-Path $PSCommandPath -Leaf).Replace('.psm1','').Replace('.ps1','')
    $Message | Out-File -FilePath "$PSScriptRoot\$FileName.log" -Append
}
#endregion

#region --- Load & validate JSON ---
if ([string]::IsNullOrEmpty($StepsJson)) {
    $Event = Get-WinEvent -ProviderName 'TroubleshootingWizard' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($Event -and $Event.Message -match '[^.]*\.json' -and (Test-Path $Event.Message -ErrorAction SilentlyContinue)) {
        $StepsJson = $Event.Message
    }
    if ([string]::IsNullOrEmpty($StepsJson)) {
        Write-Log 'No StepsJson provided and none found in event log.' -Level ERROR
        exit 1
    }
}

Write-Log "Loading step definitions from: $StepsJson"

if (-not (Test-Path $StepsJson)) { Write-Log "Steps JSON file not found: $StepsJson" -Level ERROR; exit 1; }

try {
    $stepDefs = (Get-Content -Path $StepsJson -Raw -Encoding UTF8 | ConvertFrom-Json).Steps
} catch {
    Write-Log "Failed to parse JSON: $_" -Level ERROR
    exit 1
}

$activeSteps = $stepDefs | Where-Object { $_.Enabled -eq $true } | Sort-Object { [int]$_.Order }

if ($activeSteps.Count -eq 0) {
    Write-Log 'No enabled steps found in the JSON definition.' -Level WARNING
    exit 0
}

Write-Log "Loaded $($activeSteps.Count) enabled step(s)."
#endregion

#region --- Session state ---
if ([string]::IsNullOrWhiteSpace($RegistryKey)) {
    $RegistryKey = [System.IO.Path]::GetFileNameWithoutExtension($StepsJson)
}
$registryPath = "HKCU:\Software\Diagnostics\$RegistryKey"

$session = @{
    SessionName = "${RegistryKey}_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Results     = @{
        Timestamp = Get-Date -Format 'o'
        Passed    = 0
        Failed    = 0
        Warnings  = 0
        Steps     = @()
    }
}
#endregion

#region --- Helpers ---
function ConvertTo-SafeScriptBlock {
    param([string] $Code)
    if ([string]::IsNullOrWhiteSpace($Code)) { return $null }
    try   { return [scriptblock]::Create($Code) }
    catch { Write-Log "ScriptBlock parse error: $_" -Level WARNING; return $null }
}

function Get-StatusProperty {
    param([object] $Map, [string] $Status)
    if ($null -eq $Map) { return '' }
    $val = $Map | Select-Object -ExpandProperty $Status -ErrorAction SilentlyContinue
    if ($null -eq $val) { return '' }
    return [string]$val
}
#endregion

#region --- Load UI library ---
$uiLibrary = Join-Path $PSScriptRoot 'TroubleshootWizard-UI.ps1'
$uiLoaded  = $false
if (-not $SkipUI) {
    if (Test-Path $uiLibrary) {
        . $uiLibrary
        $uiLoaded = $true
    } else {
        Write-Log 'TroubleshootWizard-UI.ps1 not found — running silently.' -Level WARNING
    }
}
#endregion

#region --- Execute steps ---
Write-Log "$RegistryKey - Diagnostics Started"
Write-Log ('-' * 60)

# Detect theme and accent color early so the progress dialog matches the results window
$earlyIsDark = $true
$earlyXamlPath = if (-not [string]::IsNullOrEmpty($XamlFile)) { Join-Path $PSScriptRoot $XamlFile } else { '' }
if ($earlyXamlPath -and (Test-Path $earlyXamlPath)) {
    try {
        $earlyXml = [xml](Get-Content -Path $earlyXamlPath -Raw -Encoding Unicode)
        $bgAttr   = $earlyXml.DocumentElement.GetAttribute('Background')
        if ($bgAttr -match '^#([0-9A-Fa-f]{6,8})$') {
            $hex = $bgAttr -replace '^#', ''
            if ($hex.Length -eq 8) { $hex = $hex.Substring(2) }
            $r = [Convert]::ToInt32($hex.Substring(0,2), 16)
            $g = [Convert]::ToInt32($hex.Substring(2,2), 16)
            $b = [Convert]::ToInt32($hex.Substring(4,2), 16)
            $earlyIsDark = ($r + $g + $b) -lt 384
        }
    } catch {}
}

$earlyAccent = '#7C6AF7'
$earlyBrandingPath = Join-Path $PSScriptRoot 'Branding.json'
if (Test-Path $earlyBrandingPath) {
    try {
        $earlyBranding = Get-Content $earlyBrandingPath -Raw | ConvertFrom-Json
        if ($earlyBranding.AccentColor) { $earlyAccent = $earlyBranding.AccentColor }
    } catch {}
}

$progressHandle = $null
if (-not $SkipUI) {
    $progressHandle = Show-ProgressDialog -DialogTitle "Running $Title..." -StepCount $activeSteps.Count -IsDark $earlyIsDark -AccentColor $earlyAccent
}

$stepIndex = 0
foreach ($stepDef in $activeSteps) {

    $stepIndex++
    if ($stepDef.UserFeedback) { $feedbackText = $stepDef.UserFeedback } else { $feedbackText = $stepDef.Name }

    if ($uiLoaded) {
        Update-ProgressDialog -Handle $progressHandle `
            -StepText "($stepIndex / $($activeSteps.Count))  $feedbackText" `
            -Value ($stepIndex - 1)
    }

    if (-not $QuietMode -and $stepDef.UserFeedback) {
        Write-Host "  >>  $($stepDef.UserFeedback)" -ForegroundColor Cyan
    }

    Write-Log "Executing: $($stepDef.Name)"

    $detectionSb = ConvertTo-SafeScriptBlock -Code $stepDef.DetectionScript
    $startTime   = Get-Date
    $stepResult  = @{ Status = 'Failed'; Message = 'Detection script not defined or failed to parse.' }

    if ($detectionSb) {
        try {
            $stepResult = & $detectionSb
            Write-Log "  Result : $($stepResult.Status) - $($stepResult.Message)"
        } catch {
            $errMsg     = [string]($_.Exception.Message)
            $stepResult = @{ Status = 'Failed'; Message = "Exception: $errMsg" }
            Write-Host "  [ERROR] Exception in '$($stepDef.Name)': $errMsg" -ForegroundColor Red
        }
    }

    $duration = ((Get-Date) - $startTime).TotalMilliseconds

    $remediationRan    = $false
    $remediationStatus = ''

    if ($AutoRemediate -and $stepResult.Status -eq 'Failed') {
        $resolutionSb = ConvertTo-SafeScriptBlock -Code $stepDef.ResolutionScript
        if ($resolutionSb) {
            Write-Log "  Auto-remediating: $($stepDef.Name)" -Level WARNING
            try {
                & $resolutionSb | Out-Null
                $remediationRan    = $true
                $remediationStatus = 'Remediation script ran successfully.'
                Write-Log '  Remediation complete.' -Level WARNING
            } catch {
                $remediationStatus = "Remediation failed: $($_.Exception.Message)"
                Write-Log "  Remediation error: $($_.Exception.Message)" -Level ERROR
            }
        }
    }

    $resolutionText = Get-StatusProperty -Map $stepDef.ResolutionText -Status $stepResult.Status
    $testResultText = Get-StatusProperty -Map $stepDef.TestResultText -Status $stepResult.Status

    $entry = @{
        Name              = $stepDef.Name
        Description       = $stepDef.Description
        Status            = $stepResult.Status
        Message           = $stepResult.Message
        UserFeedback      = $stepDef.UserFeedback
        ResolutionText    = $resolutionText
        ResolutionScript  = if ($stepDef.ResolutionScript) { $stepDef.ResolutionScript } else { '' }
        TestResultText    = $testResultText
        Duration          = [math]::Round($duration, 0)
        RemediationRan    = $remediationRan
        RemediationStatus = $remediationStatus
    }

    $session.Results.Steps += $entry

    switch ($stepResult.Status) {
        'Passed'  { $session.Results.Passed++ }
        'Failed'  { $session.Results.Failed++ }
        'Warning' { $session.Results.Warnings++ }
    }
}

if ($uiLoaded) { Close-ProgressDialog -Handle $progressHandle }

Write-Log ('-' * 60)
Write-Log "$RegistryKey - Complete  |  Passed: $($session.Results.Passed)  Failed: $($session.Results.Failed)  Warnings: $($session.Results.Warnings)"
#endregion

#region --- Save to registry ---
try {
    if (-not (Test-Path $registryPath)) { New-Item -Path $registryPath -Force | Out-Null }
    Set-ItemProperty -Path $registryPath -Name 'LastResults' `
        -Value ($session.Results | ConvertTo-Json -Depth 4) -Force
    Write-Log 'Results saved to registry.'
} catch {
    Write-Log "Could not save to registry: $_" -Level WARNING
}
#endregion

#region --- UI (optional) ---
if (-not $uiLoaded) { exit 0 }

Show-ResultsUI `
    -Results         $session.Results `
    -Title           $Title `
    -XamlFile        (Join-Path $PSScriptRoot $XamlFile) `
    -TimeoutSeconds  $TimeoutSeconds `
    -ScriptRoot      $PSScriptRoot
#endregion
