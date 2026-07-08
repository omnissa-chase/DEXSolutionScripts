<#
.SYNOPSIS
    Signs off the active console user session on a managed device.

.DESCRIPTION
    Identifies the currently logged-in console user via WMI and terminates
    their active session using the native logoff utility. Intended for use
    as a remote MDM command deployed through Omnissa Workspace ONE.

.NOTES
    Script Name  : DEX_Invoke-SignoffDevice.ps1
    Version      : 1.5.1
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley

    Workspace ONE Script Configuration:
      - Execution Context : System
      - Architecture      : Any
      - Timeout (seconds) : 5
#>

# ── Main script block ─────────────────────────────────────────────────────────
# Defined as a script block so it can be invoked via Invoke-Command, which
# surfaces terminating errors cleanly back to the Try/Catch handler below.
$SignoffDevice = {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param()
   
    if (-not $WhatIfPreference) {
        # Terminate the session — equivalent to "Sign out" in the Start menu
        logoff /all
    }
    Else {
        Write-Host "WhatIf: Would sign off the active console user session for user $($session.USERNAME)"
    }
    
}

# ── Execution & exit-code handling ────────────────────────────────────────────
Try {
    # Invoke the script block and capture any output as a string for logging
    $rslt = Invoke-Command $SignoffDevice | Out-String
    Write-Host $rslt
    Exit 0  # Success — Workspace ONE marks the command as completed
}
Catch {
    # Surface the exception message for Workspace ONE script output logging
    $rslt = "An error has occured $($_.Exception.Message)"
    Write-Host $rslt
}
Exit 1  # Failure — Workspace ONE marks the command as failed