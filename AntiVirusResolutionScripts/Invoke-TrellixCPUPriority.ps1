$trellixProcesses = @(
    "mcshield",
    "mfemms",
    "mfevtps",
    "macmnsvc",
    "masvc",
    "mfeesp",
    "mfeann",
    "mfehcs",
    "mfetp"
)

foreach ($name in $trellixProcesses) {
    Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $_.PriorityClass = "BelowNormal"

            [pscustomobject]@{
                ProcessName = $_.ProcessName
                PID         = $_.Id
                Priority    = $_.PriorityClass
                Result      = "Priority changed to BelowNormal"
            }
        }
        catch {
            [pscustomobject]@{
                ProcessName = $_.ProcessName
                PID         = $_.Id
                Priority    = $null
                Result      = "Failed: $($_.Exception.Message)"
            }
        }
    }
}
