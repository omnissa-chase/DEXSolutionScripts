<#
.SYNOPSIS
    TroubleshootWizard-Common - shared helpers for the launch pipeline.

.DESCRIPTION
    Dot-sourced by:
      Send-TroubleshootWizardEvent.ps1        (omniwiz: URL protocol handler -> writes event)
      Invoke-TroubleshootWizardFromEvent.ps1  (scheduled task action -> reads event -> launches wizard)

    The security model lives here. A launch request (URL or event message) is
    treated as untrusted text. The only thing ever taken from it is a short
    *name* that must match ^[A-Za-z0-9_-]{1,64}$ and must resolve to a file that
    already exists in <InstallRoot>\DiagSteps. Paths, script text, and anything
    else in the request are discarded. The install folder is ACL-locked by the
    installer (SYSTEM/Administrators write, Users read), so the set of JSON files
    an event can trigger is entirely admin-controlled.

    Do NOT run this file directly.

.NOTES
    PowerShell 5.1 and 7+ compatible. Uses System.Diagnostics.EventLog directly
    because Write-EventLog does not exist in PowerShell 7.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

$script:WizardEventSource      = 'TroubleshootingWizard'
$script:WizardEventLog         = 'Application'
$script:WizardEventId          = 9001
$script:WizardUrlScheme        = 'omniwiz'
$script:WizardStepsNamePattern = '^[A-Za-z0-9_-]{1,64}\z'
$script:WizardTitlePattern     = '^[A-Za-z0-9 ._()&/-]{1,60}\z'
$script:WizardThemes           = @{ Dark = 'UI-Modern.xaml'; Light = 'UI-Modern-Light.xaml' }
$script:WizardLogDir           = Join-Path $env:LOCALAPPDATA 'TroubleshootWizard'

#region --- Logging (per-user, never inside the locked install folder) ---
function Write-WizardLog {
    param(
        [string] $Message,
        [ValidateSet('INFO','WARNING','ERROR','DEBUG')]
        [string] $Level   = 'INFO',
        [string] $LogName = 'Launcher'
    )
    try {
        if (-not (Test-Path -LiteralPath $script:WizardLogDir)) {
            New-Item -ItemType Directory -Path $script:WizardLogDir -Force | Out-Null
        }
        $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
        Add-Content -LiteralPath (Join-Path $script:WizardLogDir "$LogName.log") -Value $line -Encoding UTF8
    } catch { }
}
#endregion

#region --- Validation ---
function Test-WizardStepsName {
    <# True when $Name is a bare, safe steps-file name (no path, no extension, no odd characters). #>
    param([string] $Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    return [bool]($Name -match $script:WizardStepsNamePattern)
}

function Resolve-WizardStepsFile {
    <#
        Maps a validated name to an existing file in <InstallRoot>\DiagSteps.
        Accepts 'Network' or 'NetworkDiagSteps'. Returns the full path or $null.
    #>
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $InstallRoot
    )
    if (-not (Test-WizardStepsName $Name)) { return $null }

    $stepsDir = Join-Path $InstallRoot 'DiagSteps'
    if (-not (Test-Path -LiteralPath $stepsDir -PathType Container)) { return $null }
    $stepsDirFull = (Get-Item -LiteralPath $stepsDir).FullName.TrimEnd('\')

    foreach ($candidate in @("$Name.json", "${Name}DiagSteps.json")) {
        $path = Join-Path $stepsDir $candidate
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $item = Get-Item -LiteralPath $path
            # The resolved file must sit directly inside DiagSteps (no traversal, no reparse tricks).
            if ($item.DirectoryName.TrimEnd('\') -eq $stepsDirFull -and
                -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                return $item.FullName
            }
        }
    }
    return $null
}

function Confirm-WizardLaunchRequest {
    <#
        Normalises a raw request hashtable. Anything that fails validation is
        nulled out rather than passed through.
    #>
    param([hashtable] $Request)

    $out = @{ DiagSteps = $null; Theme = $null; Title = $null }

    if ($Request.DiagSteps) {
        $n = ([string]$Request.DiagSteps).Trim() -replace '(?i)\.json\z', ''
        if (Test-WizardStepsName $n) { $out.DiagSteps = $n }
    }
    if ($Request.Theme) {
        switch -Regex (([string]$Request.Theme).Trim()) {
            '^(?i)dark\z'  { $out.Theme = 'Dark' }
            '^(?i)light\z' { $out.Theme = 'Light' }
        }
    }
    if ($Request.Title) {
        $t = ([string]$Request.Title).Trim()
        if ($t -match $script:WizardTitlePattern) { $out.Title = $t }
    }
    return $out
}
#endregion

#region --- Parsing ---
function ConvertFrom-WizardLaunchRequest {
    <#
        Parses launch text into @{ DiagSteps; Theme; Title } (all validated).

        Accepted forms:
          omniwiz://run?diagsteps=Network&theme=Light&title=Network%20Check
          omniwiz://Network            omniwiz:Network
          DiagSteps=Network;Theme=Dark                       (event message, current format)
          C:\...\DiagSteps\NetworkDiagSteps.json             (event message, legacy - base name only)
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

    $raw = @{ DiagSteps = $null; Theme = $null; Title = $null }
    $t   = $Text.Trim()

    if ($t -match "^(?i)$($script:WizardUrlScheme):") {
        $rest = $t -replace "^(?i)$($script:WizardUrlScheme):/*", ''
        $pathPart, $queryPart = $rest -split '\?', 2
        if ($queryPart) {
            foreach ($pair in ($queryPart -split '&')) {
                $k, $v = $pair -split '=', 2
                if ([string]::IsNullOrEmpty($v)) { continue }
                try { $v = [Uri]::UnescapeDataString($v) } catch { continue }
                switch ($k.Trim().ToLowerInvariant()) {
                    'diagsteps' { $raw.DiagSteps = $v }
                    'steps'     { $raw.DiagSteps = $v }
                    'theme'     { $raw.Theme     = $v }
                    'title'     { $raw.Title     = $v }
                }
            }
        }
        if (-not $raw.DiagSteps -and $pathPart) {
            $seg = ($pathPart.Trim('/') -split '/')[0]
            if ($seg -and $seg -notmatch '^(?i)run\z') { $raw.DiagSteps = $seg }
        }
    }
    elseif ($t -match '(?i)\.json\z' -and $t -notmatch '=') {
        # Legacy event message: a full path. Only the file's base name is trusted.
        $raw.DiagSteps = [IO.Path]::GetFileNameWithoutExtension($t)
    }
    else {
        foreach ($pair in ($t -split '[;\r\n]+')) {
            $k, $v = $pair -split '=', 2
            if ([string]::IsNullOrWhiteSpace($k) -or $null -eq $v) { continue }
            switch ($k.Trim().ToLowerInvariant()) {
                'diagsteps' { $raw.DiagSteps = $v }
                'theme'     { $raw.Theme     = $v }
                'title'     { $raw.Title     = $v }
            }
        }
    }

    return (Confirm-WizardLaunchRequest -Request $raw)
}

function New-WizardEventMessage {
    <# Builds the canonical event message from a validated request. #>
    param([Parameter(Mandatory)] [hashtable] $Request)
    $parts = @("DiagSteps=$($Request.DiagSteps)")
    if ($Request.Theme) { $parts += "Theme=$($Request.Theme)" }
    if ($Request.Title) { $parts += "Title=$($Request.Title)" }
    return ($parts -join ';')
}

function Get-WizardDefaultTheme {
    <# Reads "Theme" from Branding.json; falls back to Light. #>
    param([Parameter(Mandatory)] [string] $InstallRoot)
    $brandingPath = Join-Path $InstallRoot 'Branding.json'
    try {
        if (Test-Path -LiteralPath $brandingPath) {
            $b = Get-Content -LiteralPath $brandingPath -Raw | ConvertFrom-Json
            if ($b.Theme -and $script:WizardThemes.ContainsKey([string]$b.Theme)) { return [string]$b.Theme }
        }
    } catch { }
    return 'Light'
}

function ConvertTo-WizardTitle {
    <# 'NetworkDiagSteps' -> 'Network Diagnostics' #>
    param([Parameter(Mandatory)] [string] $StepsName)
    $base = $StepsName -replace '(?i)DiagSteps\z', ''
    $base = [regex]::Replace($base, '(?<=[a-z0-9])(?=[A-Z])', ' ')
    $base = $base -replace '[_-]+', ' '
    return "$($base.Trim()) Diagnostics"
}
#endregion

#region --- Event log ---
function Test-WizardEventSource {
    try   { return [System.Diagnostics.EventLog]::SourceExists($script:WizardEventSource) }
    catch { return $false }   # non-admins get an exception when the source is absent (Security log not readable)
}

function Send-WizardLaunchEvent {
    <#
        Writes the launch event. Standard (interactive) users can write to the
        Application log once the source exists; the installer registers the source.
    #>
    param([Parameter(Mandatory)] [string] $Message)
    if (-not (Test-WizardEventSource)) {
        throw "Event source '$($script:WizardEventSource)' is not registered on this device. Run Install-TroubleshootWizard.ps1 as an administrator."
    }
    [System.Diagnostics.EventLog]::WriteEntry(
        $script:WizardEventSource,
        $Message,
        [System.Diagnostics.EventLogEntryType]::Information,
        $script:WizardEventId)
}

function Get-WizardLaunchEvent {
    <# Newest launch event within the look-back window, or $null. Returns the raw inserted string. #>
    param([int] $LookbackSeconds = 90)
    $filter = @{
        LogName      = $script:WizardEventLog
        ProviderName = $script:WizardEventSource
        Id           = $script:WizardEventId
        StartTime    = (Get-Date).AddSeconds(-$LookbackSeconds)
    }
    $evt = Get-WinEvent -FilterHashtable $filter -MaxEvents 1 -ErrorAction SilentlyContinue
    if (-not $evt) { return $null }
    # Properties[0] is the raw string we inserted; Message may be wrapped in a "description not found" template.
    if ($evt.Properties.Count -gt 0 -and $evt.Properties[0].Value) { return [string]$evt.Properties[0].Value }
    return [string]$evt.Message
}
#endregion
