Download the Zip if you don't need to customize.  It is already prepped and ready for use.


Name  

Give it a simple name to track for your admins, but also looks good to end users (Required Reboot is the name I typically use but feel free to customize). 

Required Reboot 

Context 

Make sure this executes under the System Context with admin privileges 

 
Uninstall Command 

PowerShell.exe -ExecutionPolicy Bypass -Command { Remove-Item –Path "HKLM:\SOFTWARE\AirWatch\Extensions\SmartReboot" -Force -Recurse | Out-Null }  
 

Install Command 

PowerShell.exe -ExecutionPolicy Bypass -File ".\SmartReboot.ps1" 

Detection Method 

Type: Registry exists
Key: HKEY_LOCAL_MACHINE\SOFTWARE\AirWatch\Extensions\SmartReboot 
Name: InstallComplete 
Value: 0 