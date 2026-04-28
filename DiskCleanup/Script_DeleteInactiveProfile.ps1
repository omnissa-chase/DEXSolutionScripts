# Configuration
$ENROLLMENTUSER="chase"     # Name of the Windows User Used for enrollment.  Deleting the Windows user that enrolled can have adverse effects
$DAYS_INACTIVE = 30         # Number of days since last use
$SIZE_THRESHOLD_MB = 500    # Profile size threshold in MB.  0 will delete all inactive profiles reguardless the space they use.
$LOG_PATH = "C:\Temp\Logs\ProfileCleanup.log"

# Ensure log directory exists
If (!(Test-Path (Split-Path $LOG_PATH))) {
   New-Item -Path (Split-Path $LOG_PATH) -ItemType Directory -Force | Out-Null
}

# Get domain info
$Domain = (Get-WmiObject -Class Win32_ComputerSystem).Domain
If ($Domain -eq "WORKGROUP") {
   $Domain = (Get-WmiObject -Class Win32_ComputerSystem).Name
}

# Get domain user SIDs
$DomainUsersSID = (Get-WmiObject -Class Win32_UserAccount | Where-Object { $_.Domain -eq $Domain -and $_.Name -ne $ENROLLMENTUSER }).SID

# Get all non-special user profiles
$Profiles = Get-WmiObject -Class Win32_UserProfile | Where-Object {
   !$_.Special -and ($_.SID -in $DomainUsersSID)
}

# Function to calculate folder size in MB
Function Get-FolderSizeMB($Path) {
   If (Test-Path $Path) {
       $SizeBytes = 0
       (Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
            If (!($_.PSIsContainer)) {
                $SizeBytes += $_.Length
            }
       })
        

       return [math]::Round($SizeBytes / 1MB, 2)
   }
   return 0
}

# Initialize log
echo "`n[$(Get-Date)] Starting profile cleanup..."

# Loop through profiles and evaluate conditions
foreach ($Profile in $Profiles) {
   $LastUsed = $Profile.ConvertToDateTime($Profile.LastUseTime)
   $ProfilePath = $Profile.LocalPath
   $ProfileSizeMB = Get-FolderSizeMB $ProfilePath
   echo "[$(Get-Date)] Examining profile: $($Profile.LocalPath | Split-Path -Leaf)"

   $Inactive = ($LastUsed -lt (Get-Date).AddDays(-$DAYS_INACTIVE))
   $TooLarge = ($ProfileSizeMB -gt $SIZE_THRESHOLD_MB)

   echo "[$(Get-Date)] Profile, $($Profile.LocalPath | Split-Path -Leaf), has size $ProfileSizeMB MB, and has been inactive, $([math]::Round(((Get-Date).Subtract($LastUsed)).TotalDays,2)) day(s)"

   If ($Inactive -and $TooLarge) {
       Try {
           echo "[$(Get-Date)] Deleted profile: $ProfilePath"
           Remove-WmiObject -InputObject $Profile
       } Catch {
           echo "[$(Get-Date)] Error deleting profile: $ProfilePath | $_"
       }
   }
}

echo "[$(Get-Date)] Profile cleanup complete."

Exit 0
