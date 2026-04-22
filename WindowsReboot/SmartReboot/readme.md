<h1>**Smart Reboot 1.0.0.0**</h1>

This option provides the most flexibility with the least amount of effort, and works with all but Hub Registered mode.  This option provides a simple .zip application package to be pushed through Workspace ONE's applicaiton management capabilities.   Using this option provides administrators with native capabilities to prompt the user and configure deferral rules.

**Instructions**

Download the Zip if you don't need to customize.  It is already prepped and ready for use.

**Name** 

_Give it a simple name to track for your admins, but also looks good to end users (Required Reboot is the name I typically use but feel free to customize)._

Required Reboot

**Context**

Make sure this executes under the System Context with admin privileges 

**Uninstall Command**

PowerShell.exe -ExecutionPolicy Bypass -Command { Remove-Item –Path "HKLM:\SOFTWARE\AirWatch\Extensions\SmartReboot" -Force -Recurse | Out-Null }  
 
**Install Command**

PowerShell.exe -ExecutionPolicy Bypass -File ".\SmartReboot.ps1" 

**Detection Method**

Type: Registry exists
Key: HKEY_LOCAL_MACHINE\SOFTWARE\AirWatch\Extensions\SmartReboot 
Name: InstallComplete 
Value: 0 
