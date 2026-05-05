param([string]$StepDiag)

$Source = "TroubleshootingWizard"
if (-not [System.Diagnostics.EventLog]::SourceExists($Source)) {
    New-EventLog -LogName Application -Source $Source
}

$LaunchScheduledTask = {
param([string]$StepDiag="NetworkStepsDiag.json")
$Source = "TroubleshootingWizard"
$EventID = 9001
$Message = "Trigger event for scheduled task"

Write-EventLog `
    -LogName Application `
    -Source $Source `
    -EventId $EventID `
    -EntryType Information `
    -Message "$env:ALLUSERSPROFILE\AirWatch\Extensions\TroubleshootWizard\StepsDiag\$StepDiag"
}

$LaunchScheduledTask | Out-File -FilePath "$env:ALLUSERSPROFILE\AirWatch\Extensions\TroubleshootWizard\LaunchScheduledTask.ps1" -Encoding utf8 -Force

