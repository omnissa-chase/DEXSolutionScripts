
    
    $Source = "TroubleshootingWizard"
    $EventID = 9001
    $Message = "Trigger event for scheduled task"

    Write-EventLog `
        -LogName Application `
        -Source $Source `
        -EventId $EventID `
        -EntryType Information `
        -Message $Message

