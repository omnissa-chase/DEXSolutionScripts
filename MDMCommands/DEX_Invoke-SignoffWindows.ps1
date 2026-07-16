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
    Version      : 2.5.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-09
    Timeout      : 15 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# ── Main script block ─────────────────────────────────────────────────────────
# Defined as a script block so it can be invoked via Invoke-Command, which
# surfaces terminating errors cleanly back to the Try/Catch handler below.
$SignoffDevice = {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([switch]$CurrentUser)
    
    if(-not ($CurrentUser.IsPresent)){
        Write-Host "Signing off all active user sessions.`r`n"
        # query session lists all sessions; filter for Active/Disc states and
        # extract the numeric session ID from column 3, then logoff each one.
        $allSessions = query session 2>&1 |
            Select-String '^\s*(Active|Disc|\S+\s+\S+\s+\d+\s+(Active|Disc))' |
            ForEach-Object {
                # Normalise variable-width columns → split on 2+ spaces
                ($_.ToString().Trim() -replace '\s{2,}', "`t").Split("`t")
            } |
            Where-Object { $_ -match '^\d+$' }   # keep only the ID tokens

        # Fallback: parse every non-header line and grab the numeric ID field
        if (-not $allSessions) {
            $allSessions = (query session 2>&1) |
                Where-Object { $_ -notmatch '^\s*SESSIONNAME' } |
                ForEach-Object {
                    $cols = $_.ToString().Trim() -split '\s{2,}'
                    # ID is the column that is purely numeric
                    $cols | Where-Object { $_ -match '^\d+$' }
                }
        }

        if (-not $allSessions) {
            Write-Host "No active user sessions found."
        } else {
            # Identify the console user's session ID so it can be logged off last
            $consoleUser = (Get-CimInstance Win32_ComputerSystem).UserName.Split('\')[-1]
            $consoleSessionId = $null
            if ($consoleUser) {
                $consoleMatch = (query session 2>&1) | Select-String $consoleUser
                if ($consoleMatch) {
                    $consoleCols = $consoleMatch.ToString().Trim() -split '\s{2,}'
                    $consoleSessionId = $consoleCols | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1
                }
            }

            # Sort: non-console sessions first, console user session last
            $sorted = @($allSessions | Where-Object { $_ -ne $consoleSessionId })
            if ($consoleSessionId) { $sorted += $consoleSessionId }

            foreach ($id in $sorted) {
                if (-not $WhatIfPreference) {
                    $label = if ($id -eq $consoleSessionId) { " (console user — last)" } else { "" }
                    Write-Host "Logging off session ID: $id$label"
                    logoff $id
                } else {
                    Write-Host "WhatIf: logoff $id"
                }
            }
        }
        return   # handled above — skip the single-session logoff at the bottom
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

    # Single-session logoff for the -CurrentUser path
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