<#
.SYNOPSIS
    Signs off the active console user session on a managed device.

.DESCRIPTION
    Identifies the currently logged-in console user via WMI and terminates
    their active session using the native logoff utility. Intended for use
    as a remote MDM command deployed through Omnissa Workspace ONE.

.NOTES
    Script Name  : SignoffDevice.ps1
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
    
    # Retrieve the username of the user currently at the physical console
    # (Win32_ComputerSystem.UserName is in DOMAIN\Username format)
    $console = (Get-CimInstance Win32_ComputerSystem).UserName.Split('\')[-1]
    Write-Host "Current User: $console`r`n"
        
    # Parse the active session ID for the console user from quser output
    $session = (query session | Select-String "$console").ToString().Trim() 
    if (-not $session) { 
        Throw ([Exception]::new("Session not found"))
    }
    $parts = $session -replace '^\s+','' -split '\s{2,}'
    # Expected: USERNAME | SESSIONNAME | ID | STATE | IDLE TIME | LOGON TIME
    if ($parts.Count -ge 4) {
        $session=[pscustomobject]@{
            SESSIONNAME = $parts[0]
            USERNAME    = $parts[1]          
            ID          = $parts[2]
            STATE       = $parts[3]
            RAW         = $_
        }
    }
            
    Write-Host "Session info: $($session | Out-String)`r`n"

    if (-not $WhatIfPreference) {
        # Terminate the session — equivalent to "Sign out" in the Start menu
        logoff "$($session.ID)"
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