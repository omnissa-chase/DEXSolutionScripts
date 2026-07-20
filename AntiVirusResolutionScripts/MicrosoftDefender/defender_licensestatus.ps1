# Name: defender_licensestatus
# Type: PowerShell 
# Context: System 
# Data Type: Bool 

# Verifies the OnboardingState registry to determine if device is succesfully provisioned

$path = "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status\OnboardingState" 
$valName = "LicenseStatus" 

$status = Get-ItemProperty -Path $path -Name $valName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty $valName -ErrorAction SilentlyContinue 
If($status -ne $null){
    echo ($status -eq 1)
    return
}
echo $false
