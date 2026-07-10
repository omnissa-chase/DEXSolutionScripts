<#
.SYNOPSIS
    Notifies the logged-on user that a reboot is pending and initiates a
    5-minute countdown shutdown.

.NOTES
    Script Name  : Invoke-SimpleReboot.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-10
    Timeout      : 10 seconds (script exits immediately after scheduling reboot)

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# ── Configuration ─────────────────────────────────────────────────────────────

# Seconds of warning given to a logged-on user before the reboot fires
$CountdownSeconds = 300   # 5 minutes

# ── Detect logged-on console user ─────────────────────────────────────────────

$consoleUser = (Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName

if ($consoleUser) {
    Write-Host "Console user detected: $consoleUser"
    Write-Host "Scheduling reboot in $CountdownSeconds seconds..."

    # Pass the countdown directly to shutdown.exe so it runs asynchronously.
    # shutdown.exe returns immediately and manages the timer natively --
    # the script exits right away and does not block WS1 or the calling process.
    shutdown.exe /r /f /t $CountdownSeconds /c "Reboot initiated by IT management policy. Please save your work."

} else {
    Write-Host "No console user detected. Rebooting immediately."
    shutdown.exe /r /f /t 0 /c "Reboot initiated by IT manueagement policy."
}

Write-Host "Reboot scheduled. Script exiting."
Exit 0
