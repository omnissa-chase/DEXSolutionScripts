
# Define the registry path where metrics will be stored
$REGSTORE = "HKLM:\SOFTWARE\AirWatch\Extensions\UserProfilesManagement"

# Ensure the registry path exists; create it if it doesn't
If (!(Test-Path $REGSTORE)) {
    New-Item -Path $REGSTORE -Force | Out-Null
}

# Set the threshold for inactivity in days
$DAYS_INACTIVE = 14

# Retrieve the current computer's domain
$Domain = (Get-WmiObject -Namespace root\cimv2 -Class Win32_ComputerSystem | Select Domain).Domain

# If the machine is not domain-joined (i.e., in WORKGROUP), use the computer name instead
If ($Domain -eq "WORKGROUP") {
    $Domain = (Get-WmiObject -Namespace root\cimv2 -Class Win32_ComputerSystem | Select Name).Name
}

# Get all user accounts that belong to the current domain
$DomainUsers = Get-WmiObject -Class Win32_UserAccount | Where Domain -eq $Domain

# Extract the SIDs of those domain users
$DomainUsersSID = ($DomainUsers | Select-Object SID).SID

# Get all user profiles that are not special and belong to domain users
$TotalProfiles = Get-WMIObject -class Win32_UserProfile | Where {
    (!$_.Special) -and ($_.SID -in $DomainUsersSID)
}

# Define a placeholder for a known enrollment user (not used in logic here)
$ENROLLMENTUSER = "EnrollmentUser"

# Configuration: log file location and registry path for script results
$LOG_LOCATION = "C:\Temp\Logs\DeleteInactiveProfiles.log"
$REGISTRY_RESULTS_PATH = "HKLM:\SOFTWARE\AirWatch\Extensions\Scripts"

# Get the current date/time for logging
$CurrentDate = (Get-Date).ToString("dd/MM/yyyy HH:mm:ss")

# Default status message
$LastStatus = "No inactive profiles detected."

# Filter profiles that haven't been used in the last $DAYS_INACTIVE days
$InactiveProfiles = $TotalProfiles | Where {
    ($_.ConvertToDateTime($_.LastUseTime)) -lt (Get-Date).AddDays(-$DAYS_INACTIVE)
}

# If inactive profiles are found, attempt to delete them
If (($InactiveProfiles | Measure).Count) {
    Try {
        # Count the number of inactive profiles
        $ProfileCount = ($InactiveProfiles | Measure).Count

        # Remove the inactive profiles
        $Results = $InactiveProfiles | Remove-WmiObject

        # Update status message
        $LastStatus = "$ProfileCount inactive profiles deleted."
    }
    Catch {
        # Capture and log any errors
        $e = $_.Exception.Message
        $LastStatus = "Inactive Profile Script error: $e"
    }
}

# Ensure the registry path for script results exists
If (!(Test-Path -Path $REGISTRY_RESULTS_PATH)) {
    $RegResult = New-Item -Path $REGISTRY_RESULTS_PATH -Force
}

# Output the final status message
echo $LastStatus

Exit 0
