
<#
.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

    
    $Source = "TroubleshootingWizard"
    $EventID = 9001
    $Message = "Trigger event for scheduled task"

    Write-EventLog `
        -LogName Application `
        -Source $Source `
        -EventId $EventID `
        -EntryType Information `
        -Message $Message

