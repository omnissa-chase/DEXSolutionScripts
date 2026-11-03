#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : scom_state_folder_mb_standalone
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-25
    Timeout      : < 3 seconds typical -- see the runtime note below
    Requires     : nothing -- measures the device directly, no cache, no sweep script

    Standalone twin of scom_state_folder_mb. Deploy one or the other, not both.

    Size in MB of the agent's Health Service State folder, measured live. This is the
    folder that grows when the agent cannot upload -- queued data, an inflated
    HealthServiceStore.edb, orphaned management pack caches. On a VDI golden image or
    a small-disk laptop it is real capacity, not a monitoring curiosity.

    -1 means not measured -- no agent, folder absent, or the size read failed. It is
    not zero and it is not small. Filter it out before averaging.

    RUNTIME -- the one sensor here with an unbounded worst case. Sizing is done with
    Scripting.FileSystemObject, whose Size property walks the subtree in native code:
    an order of magnitude faster than Get-ChildItem -Recurse, and it does not
    materialise a FileInfo per file. In practice this returns in well under a second,
    because state-folder bloat is almost always a handful of very large files (the
    .edb store, queue files) rather than a large file COUNT. A folder pathological in
    file count instead would be slower, and there is no way to time-box a blocking
    COM call from inside a sensor without a thread, which sensors may not create.
    If you are sizing a fleet known to have deep per-workflow cache sprawl, deploy
    the cached scom_state_folder_mb against the sweep instead -- a script has the
    budget for it and a sensor does not.

    A large value on its own is not a corruption finding. Confirm against
    scom_config_age_hours_standalone and the connector state before flushing
    anything; Invoke-AutoRemediateSCOMHealthServiceCache.ps1 requires a corroborating
    signal for exactly that reason.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

$fso = $null
try {
    $agentRoot = $null
    foreach ($candidate in @('HKLM:\SOFTWARE\Microsoft\Microsoft Operations Manager\3.0',
                             'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft Operations Manager\3.0')) {
        if (Test-Path $candidate -ErrorAction SilentlyContinue) { $agentRoot = $candidate; break }
    }
    if (-not $agentRoot) { Write-Output -1; return }

    $setup = Get-ItemProperty -Path (Join-Path $agentRoot 'Setup') -ErrorAction SilentlyContinue
    if (-not $setup -or -not $setup.InstallDirectory) { Write-Output -1; return }

    $stateDir = Join-Path ([string]$setup.InstallDirectory) 'Health Service State'
    if (-not (Test-Path -LiteralPath $stateDir -ErrorAction SilentlyContinue)) { Write-Output -1; return }

    $fso    = New-Object -ComObject Scripting.FileSystemObject
    $folder = $fso.GetFolder($stateDir)

    Write-Output ([int][math]::Round($folder.Size / 1MB))
    return
}
catch {
    Write-Output -1
    return
}
finally {
    if ($fso) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($fso) }
}
