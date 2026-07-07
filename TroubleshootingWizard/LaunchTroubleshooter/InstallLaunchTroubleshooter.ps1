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


$Scheme = 'omniwiz'
$AppPath = "$env:ALLUSERSPROFILE\AirWatch\Extensions\TroubleshootWizard\"

$BaseKey = "HKCU:\Software\Classes\$Scheme"
$CommandKey = "$BaseKey\shell\open\command"

New-Item -Path $BaseKey -Force | Out-Null
Set-ItemProperty -Path $BaseKey -Name '(default)' -Value "URL:$Scheme"
New-ItemProperty -Path $BaseKey -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null

New-Item -Path $CommandKey -Force | Out-Null
Set-ItemProperty -Path $CommandKey -Name '(default)' -Value "conhost.exe --headless powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File $AppPath\LaunchScheduledTask.ps1 -StepsDiag %1"

$LaunchScheduledTask | Out-File -FilePath "$env:ALLUSERSPROFILE\AirWatch\Extensions\TroubleshootWizard\LaunchScheduledTask.ps1" -Encoding utf8 -Force

