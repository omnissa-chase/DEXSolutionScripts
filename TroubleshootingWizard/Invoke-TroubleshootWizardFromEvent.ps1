<#
.SYNOPSIS
    Scheduled-task action: reads the newest TroubleshootWizard launch event and
    starts the wizard with the steps file it names.

.DESCRIPTION
    Registered by Install-TroubleshootWizard.ps1 as the action of the task
    \Omnissa\TroubleshootWizard\TroubleshootWizard-OnEvent, which is triggered by
    Application-log events from source 'TroubleshootingWizard' with ID 9001 and
    runs as the interactive user (BUILTIN\Users group principal).

    The task command line is fixed and takes no data from the event. This script
    reads the event itself, parses it with the shared validator, and only launches
    a steps file that already exists in <install>\DiagSteps. Any request that does
    not validate is logged and ignored.

.PARAMETER LookbackSeconds
    Only events newer than this are considered (default 90). Guards against the
    task firing late and replaying an old request.

.PARAMETER SkipUI
    Pass-through to the engine for silent/diagnostic runs.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

[CmdletBinding()]
param(
    [int]    $LookbackSeconds = 90,
    [switch] $SkipUI
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TroubleshootWizard-Common.ps1')

$logName = 'Invoke-TroubleshootWizardFromEvent'
Write-WizardLog "Task fired as $env:USERDOMAIN\$env:USERNAME (session $([System.Diagnostics.Process]::GetCurrentProcess().SessionId))." -LogName $logName

$text = Get-WizardLaunchEvent -LookbackSeconds $LookbackSeconds
if (-not $text) {
    Write-WizardLog "No launch event in the last $LookbackSeconds s. Nothing to do." -Level WARNING -LogName $logName
    exit 0
}
Write-WizardLog "Event text: $text" -LogName $logName

$request   = ConvertFrom-WizardLaunchRequest -Text $text
$stepsFile = $null
if ($request.DiagSteps) {
    $stepsFile = Resolve-WizardStepsFile -Name $request.DiagSteps -InstallRoot $PSScriptRoot
}
if (-not $stepsFile) {
    Write-WizardLog "Rejected: event did not name a steps file that exists in $PSScriptRoot\DiagSteps." -Level ERROR -LogName $logName
    exit 2
}

$theme = if ($request.Theme) { $request.Theme } else { Get-WizardDefaultTheme -InstallRoot $PSScriptRoot }
$xaml  = $script:WizardThemes[$theme]
$title = if ($request.Title) { $request.Title } else { ConvertTo-WizardTitle -StepsName ([IO.Path]::GetFileNameWithoutExtension($stepsFile)) }

Write-WizardLog "Launching: StepsJson='$stepsFile' Theme=$theme Title='$title'" -LogName $logName

$engine = Join-Path $PSScriptRoot 'TroubleshootWizard.ps1'
if (-not (Test-Path -LiteralPath $engine)) {
    Write-WizardLog "Engine not found: $engine" -Level ERROR -LogName $logName
    exit 1
}

$ErrorActionPreference = 'Continue'
& $engine -StepsJson $stepsFile -XamlFile $xaml -Title $title -QuietMode -SkipUI:$SkipUI
