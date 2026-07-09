<#
.SYNOPSIS
    Signs off user sessions on a managed device. Defaults to all sessions;
    use -CurrentUser to target only the active console user.

.PARAMETER CurrentUser
    When specified, targets only the active console user session rather than
    signing off all sessions. The console user is resolved via
    Win32_ComputerSystem.UserName and matched against active session IDs via
    'query session'.

.EXAMPLE
    # Sign off ALL active user sessions (default — no switch required)
    Invoke-Command $SignoffDevice

.EXAMPLE
    # Sign off only the currently logged-on console user
    Invoke-Command $SignoffDevice -ArgumentList ([switch]::Present)

.NOTES
    Script Name  : DEX_Invoke-SignoffWindows.ps1
    Version      : 2.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley
    Last Modified: 2026-07-09
    Timeout      : 5 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE in the repository root for full license terms (MIT).
#>

# ── Main script block ─────────────────────────────────────────────────────────
# Defined as a script block so it can be invoked via Invoke-Command, which
# surfaces terminating errors cleanly back to the Try/Catch handler below.
$SignoffDevice = {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([switch]$CurrentUser)
    
    if(-not ($CurrentUser.IsPresent)){
        Write-Host "Current user not specified. Flagging all users.`r`n"
        $SessionPref="/all"
    }
    elseif($CurrentUser.IsPresent){
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

        if(-not $Session.ID){
            Throw ([Exception]::new("Session not found for current user."))
        }
        $SessionPref="$($session.ID)"
    }


    if (-not $WhatIfPreference) {
        # Terminate the session — equivalent to "Sign out" in the Start menu
        Write-Host "Executing command, 'logoff $SessionPref'"
        logoff $SessionPref
    }
    Else {
        Write-Host "WhatIf: executing command, 'logoff $SessionPref'"
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