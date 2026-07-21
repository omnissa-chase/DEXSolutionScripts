<#
.SYNOPSIS
    defender_computerstate_summary -- Detection sensor: reports a summary of Microsoft Defender computer protection state.

.NOTES
    Script Name  : defender_computerstate_summary.ps1
    Type         : Sensor (detection only -- no remediation)
    Data Type    : String
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-20
    Timeout      : 10-20 seconds
#>

# Check if running in PowerShell 7 or later
If ($PSVersionTable.PSVersion.Major -ge 7) {
    # Import the ConfigDefender module, bypassing edition check (needed for compatibility)
    Import-Module -Name ConfigDefender -SkipEditionCheck
}

# Define a hashtable mapping Defender status flags to their bitmask values
$ReversedComputerStateFlags = @{
    "AMServiceEnabled"          = 0x00000001
    "AntispywareEnabled"        = 0x00000004
    "IOAVProtectionEnabled"     = 0x00000008
    "RealTimeProtectionEnabled" = 0x00000010
    "BehaviorMonitorEnabled"    = 0x00000020
    "OnAccessProtectionEnabled" = 0x00000040
    "ScanOnRealtimeEnable"      = 0x00000080
    "FullScanRequired"          = 0x00000100
    "RebootRequired"            = 0x00000200
    "NISProtectionEnabled"      = 0x00000400
    "TamperProtectionEnabled"   = 0x00000800
}

# Get current Defender status using Get-MpComputerStatus
$ComputerStatus = (& Get-MpComputerStatus)

# Initialize a string to track current state
$CurrentState = ""

# Loop through each property in the Defender status object
ForEach ($Property in (($ComputerStatus | Get-Member -MemberType Property).Name)) {
    # Check if the property is one of the known status flags
    If ($Property -in $ReversedComputerStateFlags.Keys) {
        # If the property ends in "Enabled", check if it's disabled
        If ($Property -like "*Enabled") {
            If ($ComputerStatus."$Property" -eq $false) {
                # Append "Disabled" version of the property to the state string
                $CurrentState += "$($Property.Replace("Enabled", "Disabled"));"
            }
        }
        # If the property ends in "Required", check if it's true (i.e., action needed)
        ElseIf ($Property -like "*Required") {
            If ($ComputerStatus."$Property" -eq $true) {
                $CurrentState += "$Property;"
            }
        }
    }
}

# If no issues were found, set state to "Ok"
If ([string]::IsNullOrEmpty($CurrentState)) {
    $CurrentState = "Ok"
}

# Output the final state summary
echo $CurrentState