$possiblePaths = @(
    "$env:ProgramFiles\Windows Defender\MpCmdRun.exe",
    "$env:ProgramData\Microsoft\Windows Defender\Platform\*\MpCmdRun.exe"
)

$mpCmdRun = Get-Item $possiblePaths -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending |
    Select-Object -First 1

if (-not $mpCmdRun) {
    throw "MpCmdRun.exe was not found."
}

& $mpCmdRun.FullName -Scan -Cancel