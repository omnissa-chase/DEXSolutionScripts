# Name: 
# Context: System 
# Timeout: 15 seconds (runs updates as a seperate job)
# User impact: None 
# Trigger: On-demand (Should automatically update on its own. Remidiation script is designed to force an update.)
# Feel free to modify to use desired source if you want

$SCRIPT_VERSION = "1.0.0.0"

$RunEventId = ([Random]::new()).Next(1000,9999)
$MaxFullScanHours = 12
Write-Host "[$RunEventId] Executing script, $SCRIPT_VERSION.  Started @ '$((Get-Date).ToString("yyyy-MM-dd hh:mm:ss"))'"
$HEAD="`r`n[$RunEventId]"
if ($PSVersionTable.PSVersion.Major -ge 7) {
    Import-Module -Name ConfigDefender -SkipEditionCheck -ErrorAction Stop
}

$ComputerStatus=(Get-MpComputerStatus)

If(-not ($ComputerStatus.DefenderSignaturesOutOfDate)){
    Write-Host "$HEAD Defender signature is already up to date."
    Exit 0
}
# Line for updating source.
Write-Host "$HEAD Updating signature as job"
Update-MpSignature -AsJob
Exit 0