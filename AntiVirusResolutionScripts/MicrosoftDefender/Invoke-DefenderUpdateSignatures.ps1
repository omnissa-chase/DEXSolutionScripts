<#
.SYNOPSIS
    Invoke-DefenderUpdateSignatures -- Forces a Microsoft Defender signature update if definitions are out of date.

.DESCRIPTION
    Checks DefenderSignaturesOutOfDate via Get-MpComputerStatus and exits immediately if
    signatures are current. If out of date, triggers Update-MpSignature as a background
    job so the script returns quickly without blocking the MDM agent timeout window.

.NOTES
    Script Name  : Invoke-DefenderUpdateSignatures.ps1
    Version      : 1.0.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-20
    Timeout      : 15 seconds (update runs as a background job)

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

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