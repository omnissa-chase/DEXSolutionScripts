# DISKCLN script for clearing space
# Get current free space on C: drive in GB (rounded down to integer)
$CurrentFreeSpace = (Get-Volume -DriveLetter "C" | Select @{Name="SizeGb"; Expression={[int]($_.SizeRemaining / 1GB)}}).SizeGB

# Integer used to identify the disk cleanup profile (can be any number from 10 to 99)
$DskCleanProfileID = 55

# List of cleanup options to enable for this run
# Comment/uncomment lines to include/exclude specific cleanup tasks
$ConfiguredOptions = @(
   #"Active Setup Temp Folders"
   #"BranchCache"
   #"Content Indexer Cleaner"
   #"D3D Shader Cache"
   #"Delivery Optimization Files"
   #"Device Driver Packages"
   #"Diagnostic Data Viewer database files"
   #"Downloaded Program Files"
   #"DownloadsFolder"
   #"Feedback Hub Archive log files"
   #"Internet Cache Files"
   #"Language Pack"
   #"Offline Pages Files"
   #"Old ChkDsk Files"
   "Previous Installations"
   #"Recycle Bin"
   #"RetailDemo Offline Content"
   #"Setup Log Files"
   "System error memory dump files"
   "System error minidump files"
   #"Temporary Files"
   #"Temporary Setup Files"
   #"Temporary Sync Files"
   #"Thumbnail Cache"
   "Update Cleanup"
   #"Upgrade Discarded Files"
   #"User file versions"
   #"Windows Defender"
   "Windows Error Reporting Files"
   #"Windows ESD installation files"
   "Windows Reset Log Files"
   "Windows Upgrade Log Files"
)

# Registry path where disk cleanup options are configured
$DskCleanPresetLocation = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\"

# Get all available cleanup options from the registry
$WindowsDiskCleanOptions = Get-ChildItem $DskCleanPresetLocation | Select-Object @{N='Options';E={Split-Path $_.Name -Leaf}}

# Loop through each available cleanup option
ForEach ($CleanOption in $WindowsDiskCleanOptions) {
   # Check if the registry path for the option exists
   If (Test-Path "$DskCleanPresetLocation\$CleanOption") {
       $CnfgValue = 0 # Default to disabled

       # Enable the option if it's in the configured list
       If ($CleanOption -in $ConfiguredOptions) {
           $CnfgValue = 2 # Value 2 enables the cleanup option
       }

       # Write the configuration value to the registry for the specified profile ID
       $Results = New-ItemProperty -Path "$DskCleanPresetLocation\$CleanOption" -Name "StateFlags00$DskCleanProfileId" -Value $CnfgValue -Force
   }
}

# Run Disk Cleanup with the configured profile ID
& cleanmgr "/sagerun:$DskCleanProfileId"

# Get new free space after cleanup
$NewFreeSpace = (Get-Volume -DriveLetter "C" | Select @{Name="SizeGb"; Expression={[int]($_.SizeRemaining / 1GB)}}).SizeGB

# Output the amount of space cleaned
echo "SpaceCleaned: $($CurrentFreeSpace - $NewFreeSpace) GB"