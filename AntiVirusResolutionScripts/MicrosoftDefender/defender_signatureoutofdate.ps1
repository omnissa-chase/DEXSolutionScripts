<#
.SYNOPSIS
    defender_signatureoutofdate -- Detection sensor: reports whether Microsoft Defender virus definition signatures are out of date.

.NOTES
    Script Name  : defender_signatureoutofdate.ps1
    Type         : Sensor (detection only -- no remediation)
    Data Type    : Boolean
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-20
#>

If($PSVersionTable.PSVersion.Major -ge 7){
    # Added Windows 7 support
    Import-Module -Name ConfigDefender -SkipEditionCheck
}

$ComputerStatus=(& Get-MpComputerStatus)

echo $ComputerStatus.DefenderSignaturesOutOfDate