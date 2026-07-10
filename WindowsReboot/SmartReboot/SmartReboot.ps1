<#
.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# 

$AppRegPath="HKLM:\SOFTWARE\AirWatch\Extensions\SmartReboot" 

If(!(Test-Path $AppRegPath)){ 

    New-Item $AppRegPath -Force | Out-Null 

    New-ItemProperty $AppRegPath -Name "InstallComplete" -Value 0 -Force 

    Exit 1641 

}Else{ 

    Exit 0 

} 