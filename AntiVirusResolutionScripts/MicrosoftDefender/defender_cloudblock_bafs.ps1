# Name: defender_cloudblock_bafs
# Type: PowerShell 
# Context: System 
# Data Type: String 

if ($PSVersionTable.PSVersion.Major -ge 7) {
    Import-Module -Name ConfigDefender -SkipEditionCheck -ErrorAction Stop
}

# Simple Block-at-First-Sight (BAFS) Check

$pref = Get-MpPreference
$stat = Get-MpComputerStatus

$status = ""
$cloudOK   = ($pref.MAPSReporting -ge 1)
If(-not $cloudOK) { $status = $status + "MAPS_Reporting_Disabled|" } 
$sampleOK  = ($pref.SubmitSamplesConsent -in 1,3)
If(-not $sampleOK) { $status = $status + "SubmitSamples_Disabled|" } 
$defsOK    = ((New-TimeSpan -Start $stat.AntivirusSignatureLastUpdated -End (Get-Date)).TotalHours -le 24)
If(-not $defsOK) { $status = $status + "AntivirusSignature_OutOfDate|" } 
$cloudBlockOK = ($pref.CloudBlockLevel -gt 0)
If(-not $cloudBlockOK) { $status = $status + "CloudBlock_Disabled|" } 

if ([string]::IsNullOrEmpty($status)) {
    echo "OK"
    return
}
echo $status.TrimEnd("|")
