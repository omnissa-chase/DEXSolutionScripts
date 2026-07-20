# Name: Defender_ThreatReport_1.4.8.4
# Context: System
# Timeout: 30 seconds 
# User impact: None 
# Optimal triggers: Triggers Run Periodically Every 4 Hours
# Run Once Immediately
# Login, Log Out, Startup, Network Change
# The goal is to run this as often as possible so that the data is accurate


# Defines script version for easy tracking
$SCRIPT_VERSION="1.4.8.4"
$RunEventId = ([Random]::new()).Next(1000,9999)
echo "[$RunEventId] Executing script, $SCRIPT_VERSION"
$HEAD="`r`n[$RunEventId]"

# This will map Threats to the Uninstall Registry for reporting in Intelligence
$MAP_THREATS_TO_APPS=$true
# Keeps any mapped threats for X # of hours (based on last run time of this script)
# 36 is the ideal value based on app reporting.  May be reduced depeding on how well app list is reporting in real time.
# Potential to use Workflow to force the query.
$MAP_THREATS_RETENTION=36

If($PSVersionTable.PSVersion.Major -ge 7){
    # Added Powershell 7 support
    Import-Module -Name ConfigDefender -SkipEditionCheck
}

# Define a hashtable of mappings for various Defender-related IDs to readable labels
$MpDefinitions=@{   
"SeverityId"=@{"0"="Critical";"1"="High";"2"="Moderate";"3"="Low";"4"="VeryLow";"5"="VeryLow"}
 # Maps threat category IDs to names (e.g., Adware, Trojan, etc.)
"ThreatCategoryId"=@{"0"="Invalid";"1"="Adware";"2"="Spyware";"3"="PasswordStealer";"4"="TrojanDownloader";"5"="Worm";"6"="Backdoor";"7"="RemoteAccessTrojan";"8"="Trojan";"9"="EmailFlooder";"10"="Keylogger";"11"="Dialer";"12"="MonitoringSoftware";"13"="BrowserModifier";"14"="Cookie";"15"="BrowserPlugin";"16"="AOLExploit";"17"="NetscapeExploit";"18"="ActiveXExploit";"19"="JavaExploit";"20"="LinuxExploit";"21"="MacExploit";"22"="MiscExploit";"23"="Virus";"24"="SecurityDisabler";"25"="JokeProgram";"26"="HostileActiveXControl";"27"="SoftwareBundler";"28"="StealthNotifier";"29"="SettingsModifier";"30"="Toolbar";"31"="RemoteControlSoftware";"32"="TrojanFTP";"33"="PotentiallyUnwantedSoftware";"34"="ICQExploit";"35"="IRCExploit";"36"="MSNExploit";"37"="Misc";"38"="Unknown";"39"="ScriptingExploit";"40"="TrojanTelnet";"41"="Exploit";"42"="FileSharingProgram";"43"="MalwareCreationTool";"44"="RemoteDesktopControl";"45"="HackTool";"46"="DataCompressionTool";"47"="NonThreat";"48"="BootSectorVirus";"49"="TemporaryThreat";"50"="Ransomware"}
 # Maps cleaning actions taken by Defender
"CleaningActionId"=@{"0"="NoAction";"1"="Cleaned";"2"="Quarantined";"3"="Removed";"4"="Allowed";"5"="Blocked";"6"="UserDefined";"7"="NoActionRequired"}
# Maps detection status codes
"DetectionStatusId"=@{"0"="Unknown";"1"="Detected";"2"="Blocked";"3"="Quarantined";"4"="Removed";"5"="Allowed"}
# Maps threat resolution status
"ThreatStatusId"=@{"0"="Active";"1"="Resolved";"2"="Quarantined";"3"="Removed";"4"="Allowed";"5"="NoActionRequired"}
# Maps execution status of detected threats
"ExecutionStatusId"=@{"0"="Unknown";"1"="Executing";"2"="Blocked";"3"="Stopped"}
# Maps source of detection (e.g., real-time, scheduled scan)
"DetectionSourceTypeId"=@{"0"="Unknown";"1"="Real-timeProtection";"2"="IOAV";"3"="BehaviorMonitoring";"4"="On-demandScan";"5"="ScheduledScan";"6"="NetworkInspectionSystem";"7"="ManualRemediation"}
}

# Function to map raw threat data to readable labels using the definitions above
Function Get-MpDataMap {
    param($MpData, $MpDatabase)

    $ThreatListNew = @()  # Initialize an empty array to hold mapped threat objects

    ForEach ($MpThreat in $MpData) {
        $PropertyList = @{}  # Create a new hashtable for each threat's properties
        if($MpThreat.DetectionId){
            $DetectionIdShort="THRT:" + ($MpThreat.DetectionId).Replace("{","").Replace("}","").Replace("-","")
            $PropertyList.Add("DetectionIdShort",$DetectionIdShort)
        }
        # Loop through each property of the threat object
        ForEach ($Property in (($MpThreat | Get-Member -MemberType Property).Name)) {
            # If the property is in the definitions, map its value to a readable label
            If ($Property -in $MpDefinitions.Keys) {
                $PropertyList.Add($Property, $MpDefinitions["$Property"]["$($MpThreat."$Property")"])
            } Else {
                # Otherwise, just copy the raw value
                $PropertyList.Add($Property, $MpThreat."$Property")
            }

            # If a database is provided, enrich the data with additional object info
            If ($MpDatabase) {
                If ($Property -in $MpDatabase.Keys) {
                    $CurrentID = "$($MpThreat."$Property")"
                    If ($CurrentID -in $MpDatabase["$Property"].Keys) {
                        $PropertyName = "$Property`Object"
                        $PropertyList.Add($PropertyName, $MpDatabase["$Property"][$CurrentID])
                    }
                }
            }
        }

        # Convert the hashtable to a custom object and add it to the result list
        $ThreatListNew += @(New-Object -TypeName PSCustomObject -Property $PropertyList)
    }

    return $ThreatListNew
}


# Initialize an empty database to store enriched threat objects
$MpDatabase = @{}

# Get current threat detection and threat data from Defender
$MpThreatList = (& Get-MpThreatDetection)
$MpThreatData = (& Get-MpThreat)

# Map threat data using definitions
$MpThreatData_Mapped = Get-MpDataMap -MpData $MpThreatData

# Build a lookup table for ThreatId to full threat object
$MpDatabase.Add("ThreatId", @{})
ForEach ($MpThreatObject in $MpThreatData_Mapped) {
    If (!($MpDatabase["ThreatId"].ContainsKey("$($MpThreatObject.ThreatId)"))) {
        $MpDatabase["ThreatId"].Add("$($MpThreatObject.ThreatId)", $MpThreatObject)
    } Else {
        $MpDatabase["ThreatId"]["$($MpThreatObject.ThreatId)"] = $MpThreatObject
    }
}

# Map the threat detection list using the enriched database
$ThreatListNew = Get-MpDataMap $MpThreatList -MpDatabase $MpDatabase

# HealthDetection Reg
$HealthDetectionPath="HKLM:\SOFTWARE\AIRWATCH\Extensions\HealthDetection"
If(-not (Test-Path $HealthDetectionPath)) { New-Item -Path $HealthDetectionPath -Force | Out-Null }

$LastRun = Get-ItemProperty "$HealthDetectionPath" | Select-Object "LastRun" -ExpandProperty "LastRun" -ErrorAction SilentlyContinue
$dtLastRun = $LastRun -as [DateTime]

# Write active threat count to registry
$ActiveThreats = (($ThreatListNew | Where {$_.ThreatIDObject.IsActive}) | Measure).Count
echo "$HEAD`Writing active threats to registry: $ActiveThreats"
New-ItemProperty -Path $HealthDetectionPath -Name 'ActiveThreats' -Value $ActiveThreats -Force | Out-Null

# Maps threats to app sample list if enabled for reporting
If($MAP_THREATS_TO_APPS){
    $BaseInstallReg="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    $DetectionRecordList = Get-ChildItem $HealthDetectionPath -ErrorAction SilentlyContinue

    ForEach($ReportedThreat in $ThreatListNew){
        # Converts DetectionId from GUID to a shorter more digestable Id
        #$DetectionIdShort=($ReportedThreat.DetectionID).Replace("{","").Replace("}","").Replace("-","")
        $DetectionIdShort=$ReportedThreat.DetectionIdShort

        $DetectionRecordReg="$HealthDetectionPath\$DetectionIdShort"
        $DetectionRecord=""
        If(Test-Path "$DetectionRecordReg"){
            $DetectionRecord = Get-ItemProperty "$DetectionRecordReg" | Select-Object "ReportedDate" -ExpandProperty "ReportedDate" -ErrorAction SilentlyContinue
        }


        # Creates a unique path for each DetectionId; Uses THRT suffix to group them
        $ThreatRegPath="$BaseInstallReg\$DetectionIdShort"
        # Get Threat active status for String
        $IsActive="Inactive"
        If($ReportedThreat.ThreatIDObject.IsActive){
            $IsActive="Active"
        }
        If(![string]::IsNullOrEmpty($DetectionRecord) -and $IsActive -eq "Inactive"){
            continue
        }

        $DesiredDisplayName="THRT:$($ReportedThreat.ThreatIDObject.ThreatName)-$($ReportedThreat.ThreatIDObject.SeverityID) ($IsActive)"
        $DesiredDisplayVersion="$($ReportedThreat.CleaningActionID)"
  
        If(!(Test-Path $ThreatRegPath)){
            echo "$HEAD`Adding record for $DesiredDisplayName"
            New-Item $ThreatRegPath -Force | Out-Null
            New-ItemProperty -Path $ThreatRegPath -Name 'DisplayName' -Value $DesiredDisplayName -Force | Out-Null
            New-ItemProperty -Path $ThreatRegPath -Name 'DisplayVersion' -Value $DesiredDisplayVersion -Force | Out-Null
            New-ItemProperty -Path $ThreatRegPath -Name 'Publisher' -Value "DEFENDER" -Force | Out-Null
            New-ItemProperty -Path $ThreatRegPath -Name 'SystemComponent' -Type DWord -Value 1 -Force | Out-Null
            #Install Date only gets reported for inactive records
            if(-not $ReportedThreat.ThreatIDObject.IsActive){
                New-ItemProperty -Path $ThreatRegPath -Name 'InstallDate' -Value (Get-Date).ToString("o") | Out-Null
            }
            if($ReportedThreat.ThreatIDObject.IsActive){
                $RemoveRecord = @"
                powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module ConfigDefender -SkipEditionCheck; Remove-MpThreat -ThreatID $($ReportedThreat.ThreatId)"
"@
                New-ItemProperty -Path $ThreatRegPath -Name 'UninstallString' -Value "powershell.exe -ExecutionPolicy Bypass -Command {$RemoveRecord}" | Out-Null
            }else{
            $RemoveRecord = @"
                Remove-Item -Path $ThreatRegPath -Force | Out-Null;
                New-Item -Path $DetectionRecordReg -Force | Out-Null;
                New-ItemProperty -Path $DetectionRecordReg  -Name ReportedDate -Value (Get-Date).ToString("o");
"@
                
                New-ItemProperty -Path $ThreatRegPath -Name 'UninstallString' -Value "powershell.exe -ExecutionPolicy Bypass -Command {$RemoveRecord}" | Out-Null
            }
        }Else{
            echo "$HEAD`Updating record for $DesiredDisplayName"
            # Remove item from the list if item is inactive and 
            $CurrentInstallDate=Get-ItemProperty "$ThreatRegPath" | Select-Object "InstallDate" -ExpandProperty "InstallDate" -ErrorAction SilentlyContinue
            $CurrentDisplayName=Get-ItemProperty "$ThreatRegPath" | Select-Object "DisplayName" -ExpandProperty "DisplayName" -ErrorAction SilentlyContinue
            # Perform retention checks
            $dtCurrentInstallDate = ($CurrentInstallDate -as [DateTime])
            $isCurrentDateEmpty=(-not ($dtCurrentInstallDate))
            $isRecordInactive=($CurrentDisplayName -like "*(Inactive)*")            
            $statusInactive =($isRecordInactive -and !$ReportedThreat.ThreatIDObject.IsActive) 
            $hasReported = if($dtLastRun -and $dtCurrentInstallDate) { $dtLastRun.Subtract($dtCurrentInstallDate).TotalHours} else { -1 }
                     
            $retentionTrigger=if(-not $isCurrentDateEmpty){$hasReported -gt $MAP_THREATS_RETENTION} else {$false}

            if(($isCurrentDateEmpty -and $statusInactive) -or ($retentionTrigger) ){ 
                echo "$HEAD`Archiving record for $CurrentDisplayName"
                Remove-Item -Path $ThreatRegPath -Force | Out-Null
                New-Item -Path $DetectionRecordReg -Force | Out-Null
                New-ItemProperty -Path $DetectionRecordReg  -Name ReportedDate -Value (Get-Date).ToString("o") | Out-Null
                continue
            }

            $CurrentDisplayName=Get-ItemProperty "$ThreatRegPath" | Select-Object "DisplayName" -ExpandProperty "DisplayName" -ErrorAction SilentlyContinue
            $CurrentDisplayVersion=Get-ItemProperty "$ThreatRegPath" | Select-Object "DisplayVersion" -ExpandProperty "DisplayVersion" -ErrorAction SilentlyContinue
            $CurrentPublisher=Get-ItemProperty "$ThreatRegPath" | Select-Object "Publisher" -ExpandProperty "Publisher" -ErrorAction SilentlyContinue

            If($CurrentDisplayName -ne $DesiredDisplayName){
                New-ItemProperty -Path $ThreatRegPath -Name 'DisplayName' -Value $DesiredDisplayName -Force | Out-Null
            }
            If($CurrentDisplayVersion -ne $DesiredDisplayVersion){
                New-ItemProperty -Path $ThreatRegPath -Name 'DisplayVersion' -Value $DesiredDisplayVersion -Force | Out-Null
            }
            If($CurrentPublisher -ne 'DEFENDER'){
                New-ItemProperty -Path $ThreatRegPath -Name 'Publisher' -Value "DEFENDER" -Force | Out-Null
            }
            If(!$ReportedThreat.ThreatIDObject.IsActive -and [string]::IsNullOrEmpty($CurrentInstallDate)){
                New-ItemProperty -Path $ThreatRegPath -Name InstallDate -Value (Get-Date).ToString("o") -Force | Out-Null
            }
        }
    }
    $CurrentList= ($ThreatListNew | Select DetectionIdShort).DetectionIdShort

    # Clean up orphaned record
    $UninstallList = Get-ChildItem $BaseInstallReg -ErrorAction SilentlyContinue -Force | Where PSChildName -like "THRT:*" -ErrorAction SilentlyContinue
    $UninstallInactives = $UninstallList | Where PSChildName -notin $CurrentList
    foreach($InactiveRecord in $UninstallInactives){
        Remove-Item -Path $InactiveRecord.PSPath -Force | Out-Null 
    }
    

    $InativeDetectionRecords= $DetectionRecordList | Where PSChildName -notin $CurrentList
    foreach($InactiveDetectionRecord in $InativeDetectionRecords){
        Remove-Item -Path $InactiveDetectionRecord.PSPath -Force | Out-Null 
    }
    
}

echo "$HEAD`Updating LastRun to $((Get-Date).ToString("o"))"
New-ItemProperty -Path $HealthDetectionPath -Name 'LastRun' -Value (Get-Date).ToString("o") -Force | Out-Null

Exit 0