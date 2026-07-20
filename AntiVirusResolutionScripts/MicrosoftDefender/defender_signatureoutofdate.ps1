# Name: defender_signaturesoutofdate
# Type: PowerShell 
# Context: System 
# Data Type: Boolean (Text also works) 

If($PSVersionTable.PSVersion.Major -ge 7){
    # Added Windows 7 support
    Import-Module -Name ConfigDefender -SkipEditionCheck
}

$ComputerStatus=(& Get-MpComputerStatus)

echo $ComputerStatus.DefenderSignaturesOutOfDate