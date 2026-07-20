$SCRIPT_VERSION = "1.0.2.1"

$RunEventId = ([Random]::new()).Next(1000,9999)
Write-Host "[$RunEventId] Executing script, $SCRIPT_VERSION.  Started @ '$((Get-Date).ToString("yyyy-MM-dd hh:mm:ss"))'"
$HEAD="`r`n[$RunEventId]"

if ($PSVersionTable.PSVersion.Major -ge 7) {
    Import-Module -Name ConfigDefender -SkipEditionCheck -ErrorAction Stop
}


# 0 - Default
# 1 - High (recommended for most enterprises)
# 2 - HighPlus (very aggressive)

$CloudBlockLevel = 1

# Start quick Defender scan
If((Get-MpPreference -ErrorAction SilentlyContinue).CloudBlockLevel -eq $CloudBlockLevel){
    Write-Host "$HEAD Cloud block level is already set to: $CloudBlockLevel."
}Else{
    Set-MpPreference -CloudBlockLevel $CloudBlockLevel
    Write-Host "$HEAD Cloud block level updated to: $CloudblockLevel."
}

If((Get-MpPreference -ErrorAction SilentlyContinue).MAPSReporting -ge 2){
    Write-Host "$HEAD MAPS reporting already enabled."
}Else{
    Set-MpPreference -MAPSReporting Advanced
    Write-Host "$HEAD Updating MAPS Reporting to: Advanced."
}

If((Get-MpPreference -ErrorAction SilentlyContinue).SubmitSamplesConsent -ge 1){   
    Write-Host "$HEAD Submit Samples Consent is already enabled."
}Else{
    Set-MpPreference -SubmitSamplesConsent 1
    Write-Host "$HEAD Updating SubmitSamplesConsent to: '1'."
}

Exit 0