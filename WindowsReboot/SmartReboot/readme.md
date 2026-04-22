<h1>Smart Reboot 1.0.0.0</h1>

This option provides the most flexibility with the least amount of effort, and works with all but Hub Registered mode.  This option provides a simple .zip application package to be pushed through Workspace ONE's applicaiton management capabilities.   Using this option provides administrators with native capabilities to prompt the user and configure deferral rules.

<h3>**Instructions**</h3>

Download the Zip if you don't need to customize.  It is already prepped and ready for use.

<h3>**Name**</h3>

_Give it a simple name to track for your admins, but also looks good to end users (Required Reboot is the name I typically use but feel free to customize)._

Required Reboot

<h3>**Context**</h3>

Make sure this executes under the System Context with admin privileges 

<h3>**Uninstall Command**</h3>

PowerShell.exe -ExecutionPolicy Bypass -Command { Remove-Item –Path "HKLM:\SOFTWARE\AirWatch\Extensions\SmartReboot" -Force -Recurse | Out-Null }  
 
<h3>**Install Command**</h3>

PowerShell.exe -ExecutionPolicy Bypass -File ".\SmartReboot.ps1" 

<h3>**Detection Method**</h3>

Type: Registry exists
Key: HKEY_LOCAL_MACHINE\SOFTWARE\AirWatch\Extensions\SmartReboot 
Name: InstallComplete 
Value: 0 
