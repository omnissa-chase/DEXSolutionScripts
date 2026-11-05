<#
.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# Script version for tracking. Bump here, not in the filename.
$SCRIPT_VERSION = "1.1.0"
# 1.1.0 (2026-11-05): a profile with no LastUseTime (kiosk and system-created accounts) no longer
# ends the run, it falls back to the NTUSER.DAT write time or is skipped; every line also goes to
# the log file, which 1.0 created but never wrote; candidates are every non-special, unloaded
# profile except the enrollment user's, resolved by SID, instead of only accounts whose
# Win32_UserAccount Domain matched (which enumerated the whole directory on a domain member
# and never considered local accounts there); exit 1 when a deletion failed.

# Configuration
$ENROLLMENTUSER="Administrator"     # Name of the Windows User Used for enrollment.  Deleting the Windows user that enrolled can have adverse effects
$DAYS_INACTIVE = 30         # Number of days since last use
$SIZE_THRESHOLD_MB = 500    # Profile size threshold in MB.  0 will delete all inactive profiles reguardless the space they use.
$LOG_PATH = "C:\Temp\Logs\ProfileCleanup.log"

# Ensure log directory exists
If (!(Test-Path (Split-Path $LOG_PATH))) {
   New-Item -Path (Split-Path $LOG_PATH) -ItemType Directory -Force | Out-Null
}

# Every line goes to the console (Hub captures it) and to the log file.
Function Write-Line($Text) {
   Write-Output $Text
   Try { Add-Content -LiteralPath $LOG_PATH -Value $Text -ErrorAction Stop } Catch { }
}

# The enrollment user's SID (local account first, then the machine's domain). A name that does
# not resolve excludes nothing, and says so.
$EnrollmentSID = $null
$ComputerName = (Get-WmiObject -Class Win32_ComputerSystem).Name
foreach ($Candidate in @("$ComputerName\$ENROLLMENTUSER", $ENROLLMENTUSER)) {
   Try {
       $EnrollmentSID = ([System.Security.Principal.NTAccount]$Candidate).Translate([System.Security.Principal.SecurityIdentifier]).Value
       break
   } Catch { }
}

# Candidates: every non-special profile that is not loaded (in use) and not the enrollment user's.
$Profiles = @(Get-WmiObject -Class Win32_UserProfile | Where-Object {
   -not $_.Special -and -not $_.Loaded -and $_.SID -ne $EnrollmentSID
})

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
Write-Line "`r`n[$(Get-Date)] Starting profile cleanup (v$SCRIPT_VERSION): $($Profiles.Count) candidate profile(s), inactive > $DAYS_INACTIVE day(s), size > $SIZE_THRESHOLD_MB MB"
If (-not $EnrollmentSID) { Write-Line "[$(Get-Date)] Warning: enrollment user '$ENROLLMENTUSER' did not resolve to a SID; no profile is excluded on that basis." }

$DeleteErrors = 0
$Deleted = 0

# Loop through profiles and evaluate conditions
foreach ($Profile in $Profiles) {
   $ProfilePath = $Profile.LocalPath
   $Leaf = Split-Path -Path $ProfilePath -Leaf
   Write-Line "[$(Get-Date)] Examining profile: $Leaf"

   # LastUseTime is null for profiles Windows created without an interactive logon (kiosk
   # accounts, some service accounts); ConvertToDateTime on null throws. Fall back to the
   # registry hive's write time, and skip the profile when neither is available.
   $LastUsed = $null
   Try { If ($Profile.LastUseTime) { $LastUsed = $Profile.ConvertToDateTime($Profile.LastUseTime) } } Catch { $LastUsed = $null }
   If (-not $LastUsed) {
       $Hive = Join-Path $ProfilePath 'NTUSER.DAT'
       If (Test-Path -LiteralPath $Hive) { Try { $LastUsed = (Get-Item -LiteralPath $Hive -Force -ErrorAction Stop).LastWriteTime } Catch { } }
   }
   If (-not $LastUsed) {
       Write-Line "[$(Get-Date)] Profile, $Leaf, has no last-use time and no readable NTUSER.DAT; left alone."
       Continue
   }

   $ProfileSizeMB = Get-FolderSizeMB $ProfilePath
   $Inactive = ($LastUsed -lt (Get-Date).AddDays(-$DAYS_INACTIVE))
   $TooLarge = ($ProfileSizeMB -gt $SIZE_THRESHOLD_MB)

   Write-Line "[$(Get-Date)] Profile, $Leaf, has size $ProfileSizeMB MB, and has been inactive, $([math]::Round(((Get-Date).Subtract($LastUsed)).TotalDays,2)) day(s)"

   If ($Inactive -and $TooLarge) {
       Try {
           Remove-WmiObject -InputObject $Profile -ErrorAction Stop
           $Deleted++
           Write-Line "[$(Get-Date)] Deleted profile: $ProfilePath"
       } Catch {
           $DeleteErrors++
           Write-Line "[$(Get-Date)] Error deleting profile: $ProfilePath | $($_.Exception.Message)"
       }
   }
}

Write-Line "[$(Get-Date)] Profile cleanup complete: $Deleted deleted, $DeleteErrors error(s)."

If ($DeleteErrors -gt 0) { Exit 1 }
Exit 0
