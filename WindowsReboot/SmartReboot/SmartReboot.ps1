# 

$AppRegPath="HKLM:\SOFTWARE\AirWatch\Extensions\SmartReboot" 

If(!(Test-Path $AppRegPath)){ 

    New-Item $AppRegPath -Force | Out-Null 

    New-ItemProperty $AppRegPath -Name "InstallComplete" -Value 0 -Force 

    Exit 1641 

}Else{ 

    Exit 0 

} 