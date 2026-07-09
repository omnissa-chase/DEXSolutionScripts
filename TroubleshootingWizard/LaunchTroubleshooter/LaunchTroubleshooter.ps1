<#
.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE in the repository root for full license terms (MIT).
#>

param([string]$StepDiag)

$Source = "TroubleshootingWizard"
if (-not [System.Diagnostics.EventLog]::SourceExists($Source)) {
    New-EventLog -LogName Application -Source $Source
}

$LaunchScheduledTask = {

param([string]$DiagSteps="NetworkDiagSteps.json")
$Source = "TroubleshootingWizard"
$EventID = 9001
$Message = "Trigger event for scheduled task"

If($DiagSteps -match "omniwiz\:\/\/.*diagsteps\=([^&]*)"){
    echo ($Matches | Out-String) >> "$PSScriptRoot\DiagStep.log"
    $DiagSteps = $Matches[1]
    if(-not ($DiagSteps.EndsWith(".json"))) {
       $DiagSteps=$DiagSteps+".json"
    }    
}

Write-EventLog `
    -LogName Application `
    -Source $Source `
    -EventId $EventID `
    -EntryType Information `
    -Message "$env:ALLUSERSPROFILE\AirWatch\Extensions\TroubleshootWizard\DiagSteps\$DiagSteps"


}

$LaunchScheduledTask | Out-File -FilePath "$env:ALLUSERSPROFILE\AirWatch\Extensions\TroubleshootWizard\LaunchScheduledTask.ps1" -Encoding utf8 -Force

