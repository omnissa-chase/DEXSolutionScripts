<#
.SYNOPSIS
    Writes the TroubleshootWizard launch event (Application log, source
    TroubleshootingWizard, event ID 9001). The event-triggered scheduled task
    registered by the installer picks it up and shows the wizard in the
    interactive user's session.

.DESCRIPTION
    Two ways to call it:

      1. URL protocol handler (registered by the installer under HKLM\SOFTWARE\Classes\omniwiz):
             omniwiz://run?diagsteps=Network&theme=Light
             omniwiz://Network
         Windows invokes:  ... -File Send-TroubleshootWizardEvent.ps1 -Url "%1"

      2. Directly, e.g. from a Workspace ONE script or sensor running as SYSTEM
         that needs to pop the wizard for the logged-on user:
             .\Send-TroubleshootWizardEvent.ps1 -DiagSteps Network -Theme Dark

    Only a validated steps-file *name* is accepted. It must resolve to an existing
    file in <install>\DiagSteps (e.g. 'Network' -> NetworkDiagSteps.json). Nothing
    else from the URL is forwarded.

.PARAMETER Url
    The full omniwiz: URL as passed by the shell (%1).

.PARAMETER DiagSteps
    Steps-file name: 'Network' or 'NetworkDiagSteps' (with or without .json).

.PARAMETER Theme
    'Dark' or 'Light'. Omit to use the "Theme" value in Branding.json (default Light).

.PARAMETER Title
    Optional window title (letters, digits, spaces and . _ ( ) & / - only, max 60).

.OUTPUTS
    Exit 0 = event written, 2 = request rejected, 1 = event log error.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

[CmdletBinding(DefaultParameterSetName = 'Url')]
param(
    [Parameter(ParameterSetName = 'Url', Position = 0)]
    [string] $Url,

    [Parameter(ParameterSetName = 'Direct', Mandatory)]
    [string] $DiagSteps,

    [Parameter(ParameterSetName = 'Direct')]
    [ValidateSet('Dark', 'Light')]
    [string] $Theme,

    [Parameter(ParameterSetName = 'Direct')]
    [string] $Title
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TroubleshootWizard-Common.ps1')

$logName = 'Send-TroubleshootWizardEvent'

if ($PSCmdlet.ParameterSetName -eq 'Url') {
    if ([string]::IsNullOrWhiteSpace($Url)) {
        Write-WizardLog 'No URL or -DiagSteps supplied.' -Level ERROR -LogName $logName
        exit 2
    }
    Write-WizardLog "Request (url): $Url" -LogName $logName
    $request = ConvertFrom-WizardLaunchRequest -Text $Url
} else {
    Write-WizardLog "Request (direct): DiagSteps=$DiagSteps Theme=$Theme Title=$Title" -LogName $logName
    $request = Confirm-WizardLaunchRequest -Request @{ DiagSteps = $DiagSteps; Theme = $Theme; Title = $Title }
}

if (-not $request.DiagSteps) {
    Write-WizardLog 'Rejected: no valid DiagSteps name in request.' -Level ERROR -LogName $logName
    exit 2
}

$stepsFile = Resolve-WizardStepsFile -Name $request.DiagSteps -InstallRoot $PSScriptRoot
if (-not $stepsFile) {
    Write-WizardLog "Rejected: '$($request.DiagSteps)' does not match a file in $PSScriptRoot\DiagSteps." -Level ERROR -LogName $logName
    exit 2
}

# Canonicalise to the real file base name so the receiver gets exactly one form.
$request.DiagSteps = [IO.Path]::GetFileNameWithoutExtension($stepsFile)
$message = New-WizardEventMessage -Request $request

try {
    Send-WizardLaunchEvent -Message $message
    Write-WizardLog "Event $($script:WizardEventId) written: $message" -LogName $logName
    exit 0
} catch {
    Write-WizardLog "Failed to write event: $($_.Exception.Message)" -Level ERROR -LogName $logName
    exit 1
}
