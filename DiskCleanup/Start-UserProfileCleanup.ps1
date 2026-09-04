<#
.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# Configuration
$ENROLLMENTUSER="Administrator"     # Name of the Windows User Used for enrollment.  Deleting the Windows user that enrolled can have adverse effects
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

# Function to calculate folder size in MB using native .NET enumeration (no Get-ChildItem pipeline overhead)
Function Get-FolderSizeMB($Path) {
   If (-not (Test-Path -LiteralPath $Path)) { return 0 }

   [Int64]$SizeBytes = 0
   $Stack = [System.Collections.Generic.Stack[string]]::new()
   $Stack.Push($Path)

   While ($Stack.Count -gt 0) {
       $Current = $Stack.Pop()
       Try {
           $DirInfo = [System.IO.DirectoryInfo]::new($Current)
           ForEach ($File in $DirInfo.EnumerateFiles()) {
               Try { $SizeBytes += $File.Length } Catch { }
           }
           ForEach ($SubDir in $DirInfo.EnumerateDirectories()) {
               # Skip reparse points (e.g. legacy "Local Settings"/"Application Data" junctions) to avoid double-counting/loops
               If (($SubDir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                   $Stack.Push($SubDir.FullName)
               }
           }
       } Catch {
           # Access denied or IO error on this directory -- skip it, keep walking siblings
           Continue
       }
   }

   return [math]::Round($SizeBytes / 1MB, 2)
}

# Initialize log
echo "`r`n[$(Get-Date)] Starting profile cleanup..."

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
