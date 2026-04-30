Set shell = CreateObject("WScript.Shell")
shell.Run "powershell.exe -ExecutionPolicy Bypass -File ""C:\ProgramData\AirWatch\Extensions\TroubleshootWizard\LaunchTroubleshooter.ps1""", 0, False
