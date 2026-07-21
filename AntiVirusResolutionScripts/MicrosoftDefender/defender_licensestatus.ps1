<#
.SYNOPSIS
    defender_licensestatus -- Detection sensor: reports Microsoft Defender for Endpoint license and onboarding state.

.NOTES
    Script Name  : defender_licensestatus.ps1
    Type         : Sensor (detection only -- no remediation)
    Data Type    : Boolean
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-20
#>

# Verifies the OnboardingState registry to determine if device is succesfully provisioned

$path = "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status\OnboardingState" 
$valName = "LicenseStatus" 

$status = Get-ItemProperty -Path $path -Name $valName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty $valName -ErrorAction SilentlyContinue 
If($status -ne $null){
    echo ($status -eq 1)
    return
}
echo $false
