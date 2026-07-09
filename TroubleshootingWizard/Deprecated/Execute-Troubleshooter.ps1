<#
.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE in the repository root for full license terms (MIT).
#>

param([string]$DiagSteps="NetworkDiagSteps")

$InstallPath="$env:ALLUSERSPROFILE\AirWatch\Extensions\TroubleshootWizard"

$process = New-Object -TypeName System.Diagnostics.Process
$process.StartInfo.FileName = "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe"
#.\Troubleshooter-Modular.ps1 -StepsJson .\NetworkDiagSteps.json -XamlFile .\UI-Modern.xaml
$process.StartInfo.Arguments = "-ExecutionPolicy Bypass -File `"$InstallPath\Troubleshooter-Modular.ps1`" -StepsJson `"$InstallPath\$DiagSteps.json`" -Title `"Windows Updates Troubleshooting Wizard`" -XamlFile `"$InstallPath\UI-Modern.xaml`""
    
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.RedirectStandardOutput = $true
$process.StartInfo.RedirectStandardError = $true
$process.EnableRaisingEvents = $true
$outSub  = Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action {
    $line = $Event.SourceEventArgs.Data
    if ($line) {
        # safe to do PowerShell work here in ISE
        # (leave empty if you just want to confirm stability)
            Write-Host "[PID $($Event.Sender.Id)] OUT: $line"
    }
}

$errSub  = Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -Action {
    $line = $Event.SourceEventArgs.Data
    if ($line) {
            Write-Host "[PID $($Event.Sender.Id)] ERR: $line"
    }
}

$exitSub = Register-ObjectEvent -InputObject $process -EventName Exited -Action {
    Write-Host "[PID $($Event.Sender.Id)] exited with $($Event.Sender.ExitCode)"
}
Try{ 
    $process.Start() | Out-Null

    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()
}Catch{
    Write-Host "[PID $($Process.Id)] failed with $($_.Exception.Message)"
}
Exit 0