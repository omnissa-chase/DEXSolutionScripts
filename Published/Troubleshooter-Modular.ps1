<#
.SYNOPSIS
    Troubleshooter-Modular - Generic JSON-Driven Diagnostic Engine
.DESCRIPTION
    Loads diagnostic steps from a JSON definition file, executes each step's
    DetectionScript, optionally runs a ResolutionScript on failure, then displays
    a WPF results popup driven entirely by the JSON metadata.

    The JSON schema supports per-step:
      - Name / Description
      - Enabled flag and Order for sequencing
      - DetectionScript   – PowerShell code that returns @{ Status; Message }
      - UserFeedback      – Progress text shown in console while the step runs
      - ResolutionScript  – Optional PowerShell run automatically on failure
      - ResolutionText    – Hashtable of status-keyed human-readable fix steps
      - TestResultText    – Hashtable of status-keyed summary sentences for the UI

.PARAMETER StepsJson
    Path to the JSON file that defines the diagnostic steps.
    Must be provided; there is no built-in default category.
.PARAMETER Title
    Title shown in the WPF window header (default: 'Diagnostics Results').
.PARAMETER RegistryKey
    Registry sub-key under HKCU:\Software where results are persisted.
    Defaults to the base name of the JSON file (e.g. 'NetworkDiagSteps').
.PARAMETER SkipUI
    Run diagnostics only; suppress the WPF results popup.
.PARAMETER QuietMode
    Suppress console progress output.
.PARAMETER TimeoutSeconds
    Auto-close the popup after N seconds (default: 60).
.PARAMETER AutoRemediate
    If set, each step's ResolutionScript is run automatically when a step fails.
.EXAMPLE
    .\Troubleshooter-Modular.ps1 -StepsJson ".\NetworkDiagSteps.json"
.EXAMPLE
    .\Troubleshooter-Modular.ps1 -StepsJson "C:\Diag\AppSteps.json" -Title "App Health Check" -AutoRemediate
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $StepsJson,
    [string] $Title          = 'Diagnostics Results',
    [string] $RegistryKey    = '',
    [string] $XamlFile       = '',
    [switch] $SkipUI,
    [switch] $QuietMode,
    [int]    $TimeoutSeconds = 60,
    [switch] $AutoRemediate
)

$ErrorActionPreference = 'Continue'

# 
#  LOGGING
# 
function Write-Log {
    param(
        [string] $Message,
        [ValidateSet('INFO','WARNING','ERROR','DEBUG')]
        [string] $Level = 'INFO'
    )
    if ($QuietMode -and $Level -eq 'INFO') { return }
    $ts     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $colors = @{ ERROR = 'Red'; WARNING = 'Yellow'; DEBUG = 'Gray'; INFO = 'White' }
    Write-Host "[$ts] [$Level] $Message" -ForegroundColor $colors[$Level]
}

# 
#  LOAD & VALIDATE JSON
# 
Write-Log "Loading step definitions from: $StepsJson"

if (-not (Test-Path $StepsJson)) {
    Write-Log "Steps JSON file not found: $StepsJson" -Level ERROR
    exit 1
}

try {
    $jsonContent  = Get-Content -Path $StepsJson -Raw -Encoding UTF8
    $stepDefs     = ($jsonContent | ConvertFrom-Json).Steps
} catch {
    Write-Log "Failed to parse JSON: $_" -Level ERROR
    exit 1
}

# Filter to enabled steps, sorted by Order
$activeSteps = $stepDefs |
    Where-Object { $_.Enabled -eq $true } |
    Sort-Object  { [int]$_.Order }

if ($activeSteps.Count -eq 0) {
    Write-Log 'No enabled steps found in the JSON definition.' -Level WARNING
    exit 0
}

Write-Log "Loaded $($activeSteps.Count) enabled step(s)."

# 
#  SESSION STATE
# 
if ([string]::IsNullOrWhiteSpace($RegistryKey)) {
    $RegistryKey = [System.IO.Path]::GetFileNameWithoutExtension($StepsJson)
}
$registryPath = "HKCU:\Software\Diagnostics\$RegistryKey"

$sessionLabel = $RegistryKey
$session = @{
    SessionName = "${sessionLabel}_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Results     = @{
        Timestamp = Get-Date -Format 'o'
        Passed    = 0
        Failed    = 0
        Warnings  = 0
        Steps     = @()
    }
}

# 
#  HELPER: Safely convert a JSON string to a ScriptBlock
# 
function ConvertTo-SafeScriptBlock {
    param([string] $Code)
    if ([string]::IsNullOrWhiteSpace($Code)) { return $null }
    try   { return [scriptblock]::Create($Code) }
    catch { Write-Log "ScriptBlock parse error: $_" -Level WARNING; return $null }
}

# 
#  HELPER: Look up a status-keyed property from a PSCustomObject
#  e.g. $step.ResolutionText.Failed  or  $step.TestResultText.Passed
# 
function Get-StatusProperty {
    param(
        [object] $Map,
        [string] $Status
    )
    if ($null -eq $Map) { return '' }
    $val = $Map | Select-Object -ExpandProperty $Status -ErrorAction SilentlyContinue
    if ($null -eq $val) { return '' }
    return [string]$val
}

# 
#  HELPER: In-progress WPF dialog (runs on a background STA runspace)
# 
function Show-ProgressDialog {
    param(
        [string] $DialogTitle = 'Running Diagnostics…',
        [int]    $StepCount   = 1
    )

    $sync = [hashtable]::Synchronized(@{
        Window    = $null
        Close     = $false
        StepText  = 'Initializing…'
        Value     = 0
        StepCount = $StepCount
    })

    $xamlProg = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Diagnostics" Width="440" Height="170"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ResizeMode="NoResize">
    <Border Background="#1E1E2E" CornerRadius="10"
            BorderBrush="#3A3A5C" BorderThickness="1">
        <StackPanel Margin="28,22,28,22" VerticalAlignment="Center">
            <TextBlock Text="$DialogTitle" Foreground="White"
                       FontSize="14" FontWeight="Bold" Margin="0,0,0,10"/>
            <TextBlock Name="StepLabel" Text="Starting…"
                       Foreground="#9999BB" FontSize="11" Margin="0,0,0,12"
                       TextTrimming="CharacterEllipsis"/>
            <ProgressBar Name="PB" Height="5" Minimum="0" Maximum="$StepCount" Value="0"
                         Background="#2A2A40" Foreground="#7C6AF7"/>
        </StackPanel>
    </Border>
</Window>
"@

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync',     $sync)
    $rs.SessionStateProxy.SetVariable('xamlProg', $xamlProg)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
        $reader = New-Object System.Xml.XmlNodeReader ([xml]$xamlProg)
        $w      = [Windows.Markup.XamlReader]::Load($reader)
        $sync.Window = $w

        $timer          = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(150)
        $timer.Add_Tick({
            $w.FindName('StepLabel').Text = $sync.StepText
            $w.FindName('PB').Value       = $sync.Value
            if ($sync.Close) { $timer.Stop(); $w.Close() }
        })
        $timer.Start()
        $w.ShowDialog() | Out-Null
    })

    $handle = @{ PS = $ps; RS = $rs; Sync = $sync; Async = $null }
    $handle.Async = $ps.BeginInvoke()

    # Wait up to 3 s for the window to appear before returning
    $waited = 0
    while (-not $sync.Window -and $waited -lt 30) {
        Start-Sleep -Milliseconds 100
        $waited++
    }
    return $handle
}

function Update-ProgressDialog {
    param($Handle, [string]$StepText, [int]$Value)
    if (-not $Handle) { return }
    $Handle.Sync.StepText = $StepText
    $Handle.Sync.Value    = $Value
}

function Close-ProgressDialog {
    param($Handle)
    if (-not $Handle) { return }
    $Handle.Sync.Close = $true
    $waited = 0
    while (-not $Handle.Async.IsCompleted -and $waited -lt 30) {
        Start-Sleep -Milliseconds 100
        $waited++
    }
    try { $Handle.PS.EndInvoke($Handle.Async) } catch {}
    $Handle.PS.Dispose()
    $Handle.RS.Close()
    $Handle.RS.Dispose()
}

# 
#  EXECUTE EACH STEP
# 
Write-Log "$RegistryKey - Diagnostics Started"
Write-Log ('-' * 60)

$progressHandle = $null
if (-not $SkipUI) {
    $progressHandle = Show-ProgressDialog -DialogTitle "Running $Title…" -StepCount $activeSteps.Count
}

$stepIndex = 0
foreach ($stepDef in $activeSteps) {

    $stepIndex++
    Update-ProgressDialog -Handle $progressHandle `
        -StepText "($stepIndex / $($activeSteps.Count))  $($stepDef.UserFeedback ? $stepDef.UserFeedback : $stepDef.Name)" `
        -Value ($stepIndex - 1)

    # --- User feedback progress line ---
    if (-not $QuietMode -and $stepDef.UserFeedback) {
        Write-Host "  >>  $($stepDef.UserFeedback)" -ForegroundColor Cyan
    }

    Write-Log "Executing: $($stepDef.Name)"

    $detectionSb = ConvertTo-SafeScriptBlock -Code $stepDef.DetectionScript
    $startTime   = Get-Date
    $stepResult  = @{ Status = 'Failed'; Message = 'Detection script not defined or failed to parse.' }

    if ($detectionSb) {
        try {
            $stepResult = & $detectionSb
            Write-Log "  Result : $($stepResult.Status) - $($stepResult.Message)"
        } catch {
            $errMsg = [string]($_.Exception.Message)
            $stepResult = @{ Status = 'Failed'; Message = "Exception: $errMsg" }
            Write-Host "  [ERROR] Exception in '$($stepDef.Name)': $errMsg" -ForegroundColor Red
        }
    }

    $duration = ((Get-Date) - $startTime).TotalMilliseconds

    # --- Optional auto-remediation ---
    $remediationRan    = $false
    $remediationStatus = ''

    if ($AutoRemediate -and $stepResult.Status -eq 'Failed') {
        $resolutionSb = ConvertTo-SafeScriptBlock -Code $stepDef.ResolutionScript
        if ($resolutionSb) {
            Write-Log "  Auto-remediating: $($stepDef.Name)" -Level WARNING
            try {
                & $resolutionSb | Out-Null
                $remediationRan    = $true
                $remediationStatus = 'Remediation script ran successfully.'
                Write-Log '  Remediation complete.' -Level WARNING
            } catch {
                $remediationStatus = "Remediation failed: $($_.Exception.Message)"
                Write-Log "  Remediation error: $($_.Exception.Message)" -Level ERROR
            }
        }
    }

    # --- Resolve display text from JSON maps ---
    $resolutionText  = Get-StatusProperty -Map $stepDef.ResolutionText  -Status $stepResult.Status
    $testResultText  = Get-StatusProperty -Map $stepDef.TestResultText  -Status $stepResult.Status

    # Build result entry
    $entry = @{
        Name               = $stepDef.Name
        Description        = $stepDef.Description
        Status             = $stepResult.Status
        Message            = $stepResult.Message
        UserFeedback       = $stepDef.UserFeedback
        ResolutionText     = $resolutionText
        ResolutionScript   = if ($stepDef.ResolutionScript) { $stepDef.ResolutionScript } else { '' }
        TestResultText     = $testResultText
        Duration           = [math]::Round($duration, 0)
        RemediationRan     = $remediationRan
        RemediationStatus  = $remediationStatus
    }

    $session.Results.Steps += $entry

    switch ($stepResult.Status) {
        'Passed'  { $session.Results.Passed++ }
        'Failed'  { $session.Results.Failed++ }
        'Warning' { $session.Results.Warnings++ }
    }
}

Close-ProgressDialog -Handle $progressHandle

Write-Log ('-' * 60)
Write-Log "$RegistryKey - Complete  |  Passed: $($session.Results.Passed)  Failed: $($session.Results.Failed)  Warnings: $($session.Results.Warnings)"

# 
#  SAVE TO REGISTRY
# 
try {
    if (-not (Test-Path $registryPath)) { New-Item -Path $registryPath -Force | Out-Null }
    Set-ItemProperty -Path $registryPath -Name 'LastResults' `
        -Value ($session.Results | ConvertTo-Json -Depth 4) -Force
    Write-Log 'Results saved to registry.'
} catch {
    Write-Log "Could not save to registry: $_" -Level WARNING
}

$results = $session.Results

# 
#  WPF UI
# 
if ($SkipUI) { exit 0 }

# Load XAML from an external file if provided, otherwise use the embedded default
if ($XamlFile) {
    if (-not (Test-Path $XamlFile)) {
        Write-Error "XamlFile not found: $XamlFile"
        exit 1
    }
    $xaml = Get-Content -Path $XamlFile -Raw
    Write-Log "Loaded XAML from: $XamlFile" 'INFO'
} else {

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Diagnostics Results"
        Width="720" Height="820"
        WindowStartupLocation="CenterScreen"
        Background="#F5F5F5"
        Topmost="True">
    <Window.Resources>
        <Style x:Key="HeaderStyle" TargetType="TextBlock">
            <Setter Property="Foreground" Value="#1976D2"/>
            <Setter Property="FontWeight" Value="Bold"/>
        </Style>
        <Style x:Key="ActionButton" TargetType="Button">
            <Setter Property="Height" Value="32"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="14,0"/>
        </Style>
    </Window.Resources>

    <DockPanel>
        <!-- ── Header ── -->
        <Border DockPanel.Dock="Top" Background="White"
                BorderBrush="#E0E0E0" BorderThickness="0,0,0,1" Padding="20,14,20,10">
            <DockPanel>
                <!-- Action buttons pinned to the right -->
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal"
                            VerticalAlignment="Top" Margin="0,2,0,0">
                    <Button Name="FixAllButton" Content="Attempt Fix All"
                            Style="{StaticResource ActionButton}"
                            Background="#E65100" Margin="0,0,8,0"/>
                    <Button Name="CloseButton" Content="Close"
                            Style="{StaticResource ActionButton}"
                            Background="#2196F3"/>
                </StackPanel>
                <!-- Title + timestamp on the left -->
                <StackPanel DockPanel.Dock="Left">
                    <TextBlock Name="HeaderTitle" Text="Diagnostics Results" FontSize="20"
                               Style="{StaticResource HeaderStyle}" Margin="0,0,0,3"/>
                    <TextBlock Name="TimestampText" Text="Completed at: …"
                               FontSize="11" Foreground="#666666"/>
                    <TextBlock Name="FixAllStatus" Text="" FontSize="10"
                               Foreground="#555555" Margin="0,3,0,0" TextWrapping="Wrap"/>
                </StackPanel>
            </DockPanel>
        </Border>

        <!-- ── Auto-close progress bar ── -->
        <ProgressBar Name="TimeoutProgress" DockPanel.Dock="Top" Height="3"
                     Foreground="#2196F3" Background="#E0E0E0"/>
        <TextBlock Name="TimeoutText" DockPanel.Dock="Top" FontSize="9"
                   Foreground="#AAAAAA" Margin="20,2,0,4" Text="Auto-closing…"/>

        <!-- ── Summary counts ── -->
        <Border DockPanel.Dock="Top" Background="White"
                BorderBrush="#E0E0E0" BorderThickness="0,0,0,1"
                Padding="20,12" Margin="0,0,0,8">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                    <TextBlock Text="Passed"   Foreground="#999999" FontSize="11"/>
                    <TextBlock Name="PassedCount"  Text="0" Foreground="#4CAF50" FontSize="24" FontWeight="Bold"/>
                </StackPanel>
                <StackPanel Grid.Column="1">
                    <TextBlock Text="Failed"   Foreground="#999999" FontSize="11"/>
                    <TextBlock Name="FailedCount"  Text="0" Foreground="#F44336" FontSize="24" FontWeight="Bold"/>
                </StackPanel>
                <StackPanel Grid.Column="2">
                    <TextBlock Text="Warnings" Foreground="#999999" FontSize="11"/>
                    <TextBlock Name="WarningCount" Text="0" Foreground="#FF9800" FontSize="24" FontWeight="Bold"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- ── Scrollable step cards ── -->
        <ScrollViewer DockPanel.Dock="Top" VerticalScrollBarVisibility="Auto"
                      Background="Transparent">
            <StackPanel Name="ResultsPanel" Margin="20,0,20,10" Background="Transparent"/>
        </ScrollViewer>
    </DockPanel>
</Window>
'@

} # end else (embedded XAML)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

try {
    # ── Load XAML ──
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)

    # Detect light vs dark theme from the window background color
    $winBg    = $window.Background
    $isDark   = $true
    if ($winBg -is [Windows.Media.SolidColorBrush]) {
        $isDark = ($winBg.Color.R + $winBg.Color.G + $winBg.Color.B) -lt 384
    }

    # ── Set dynamic title ──
    $window.Title = $Title
    $window.FindName('HeaderTitle').Text = $Title

    # ── Set window icon (embedded Base64 PNG from NativeEnrollment.ico) ──
    try {
        $iconB64 = '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'
        $iconBytes = [Convert]::FromBase64String($iconB64)
        $ms = New-Object System.IO.MemoryStream(,$iconBytes)
        $bmp = New-Object Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.StreamSource = $ms
        $bmp.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.EndInit()
        $ms.Close()
        $window.Icon = $bmp
    } catch { <# icon is cosmetic - silently skip #> }

    # ── Load Branding.json (optional sidecar next to script) ──
    $branding = @{
        CompanyName      = 'Omnissa'
        LogoFile         = ''
        AccentColor      = '#7C6AF7'
        HeaderBackground = '#16162A'
        HubUrl           = 'ws1winhub:'
        SupportText      = 'Contact IT Support'
        SupportUrl       = ''
    }
    $brandingPath = Join-Path $PSScriptRoot 'Branding.json'
    if (Test-Path $brandingPath) {
        try {
            $b = Get-Content $brandingPath -Raw | ConvertFrom-Json
            foreach ($key in @('CompanyName','LogoFile','AccentColor','HeaderBackground','HubUrl','SupportText','SupportUrl')) {
                if ($b.$key) { $branding[$key] = $b.$key }
            }
            Write-Log "Loaded branding from: $brandingPath" 'INFO'
        } catch { Write-Log "Could not parse Branding.json: $_" 'WARNING' }
    }

    # ── Apply branding colors ──
    $window.FindName('HeaderBar').Background         = New-Object Windows.Media.SolidColorBrush($branding.HeaderBackground)
    $window.FindName('FixAllButton').Background      = New-Object Windows.Media.SolidColorBrush($branding.AccentColor)
    $window.FindName('TimeoutProgress').Foreground   = New-Object Windows.Media.SolidColorBrush($branding.AccentColor)

    # ── Load logo ──
    $logoCtrl = $window.FindName('LogoImage')
    if ($branding.LogoFile) {
        $resolvedLogo = if ([System.IO.Path]::IsPathRooted($branding.LogoFile)) {
            $branding.LogoFile
        } else {
            Join-Path $PSScriptRoot $branding.LogoFile
        }
        if (Test-Path $resolvedLogo) {
            try {
                $logoUri       = New-Object System.Uri((Resolve-Path $resolvedLogo).Path)
                $logoBmp       = New-Object Windows.Media.Imaging.BitmapImage($logoUri)
                $logoCtrl.Source     = $logoBmp
                $logoCtrl.Visibility = 'Visible'
            } catch { $logoCtrl.Visibility = 'Collapsed' }
        }
    }

    # ── Populate header ──
    $window.FindName('PassedCount').Text  = $results.Passed
    $window.FindName('FailedCount').Text  = $results.Failed
    $window.FindName('WarningCount').Text = $results.Warnings
    $humanTime = (Get-Date $results.Timestamp).ToString('dddd, MMMM d yyyy') + ' · ' + (Get-Date $results.Timestamp).ToString('h:mm tt')
    $window.FindName('TimestampText').Text = "Completed at: $humanTime"

    # ── Conclusion banner ──
    $conclusionBanner = $window.FindName('ConclusionBanner')
    $conclusionIcon   = $window.FindName('ConclusionIcon')
    $conclusionText   = $window.FindName('ConclusionText')
    if ($results.Failed -eq 0 -and $results.Warnings -eq 0) {
        $conclusionBanner.Background    = New-Object Windows.Media.SolidColorBrush($(if($isDark){'#0D2218'}else{'#EDF7F1'}))
        $conclusionBanner.BorderBrush   = New-Object Windows.Media.SolidColorBrush($(if($isDark){'#1A5C35'}else{'#A8D8B8'}))
        $conclusionIcon.Text            = [char]0x2705
        $conclusionText.Text            = 'All checks passed. No action required.'
        $conclusionText.Foreground      = New-Object Windows.Media.SolidColorBrush($(if($isDark){'#4ADE80'}else{'#1E6E42'}))
    } elseif ($results.Failed -eq 0) {
        $conclusionBanner.Background    = New-Object Windows.Media.SolidColorBrush($(if($isDark){'#1F1808'}else{'#FFFBF0'}))
        $conclusionBanner.BorderBrush   = New-Object Windows.Media.SolidColorBrush($(if($isDark){'#5C4A1A'}else{'#F0D888'}))
        $conclusionIcon.Text            = [char]0x26A0 + [char]0xFE0F
        $w = $results.Warnings
        $conclusionText.Text            = "$w warning$(if($w -ne 1){'s'}) found. Review the descriptions below — no action may be needed."
        $conclusionText.Foreground      = New-Object Windows.Media.SolidColorBrush($(if($isDark){'#FBBF24'}else{'#8A5C00'}))
    } else {
        $conclusionBanner.Background    = New-Object Windows.Media.SolidColorBrush($(if($isDark){'#1F0D0D'}else{'#FFF0F0'}))
        $conclusionBanner.BorderBrush   = New-Object Windows.Media.SolidColorBrush($(if($isDark){'#5C1A1A'}else{'#F0A8A8'}))
        $conclusionIcon.Text            = [char]0x274C
        $f = $results.Failed; $w = $results.Warnings
        $msg = "$f error$(if($f -ne 1){'s'}) found"
        if ($w -gt 0) { $msg += " and $w warning$(if($w -ne 1){'s'})" }
        $conclusionText.Text            = "$msg. Use Fix It on affected steps or contact IT."
        $conclusionText.Foreground      = New-Object Windows.Media.SolidColorBrush($(if($isDark){'#F87171'}else{'#B02020'}))
    }

    $panel = $window.FindName('ResultsPanel')

    # Track Fix It buttons keyed by step name for Fix All to reference
    $fixItButtons  = @{}
    $fixItStatuses = @{}

    $statusColors  = @{ Passed = '#4CAF50'; Failed = '#F44336'; Warning = '#FF9800' }
    $statusSymbols = @{ Passed = 'OK'; Failed = 'X'; Warning = '!' }

    foreach ($step in $results.Steps) {

        $statusColor  = if ($statusColors.ContainsKey($step.Status))  { $statusColors[$step.Status]  } else { '#9E9E9E' }
        $statusSymbol = if ($statusSymbols.ContainsKey($step.Status)) { $statusSymbols[$step.Status] } else { '?' }

        # ── Card border ──
        $card                  = New-Object Windows.Controls.Border
        $card.Background       = New-Object Windows.Media.SolidColorBrush('#1A1A2E')
        $card.BorderBrush      = New-Object Windows.Media.SolidColorBrush($statusColor)
        $card.BorderThickness  = New-Object Windows.Thickness(3, 1, 1, 1)
        $card.CornerRadius     = New-Object Windows.CornerRadius(6)
        $card.Padding          = New-Object Windows.Thickness(15, 12, 15, 12)
        $card.Margin           = New-Object Windows.Thickness(0, 0, 0, 8)
        $cardBgNormal = if($isDark){'#1A1A2E'}else{'#FFFFFF'}
        $cardBgHover  = if($isDark){'#1E1E3A'}else{'#F5F6FC'}
        # ── Inner grid: 3 cols × 4 rows ──
        $grid = New-Object Windows.Controls.Grid

        foreach ($w in @([Windows.GridLength]::new(44), [Windows.GridLength]::new(1,'Star'), [Windows.GridLength]::new(80))) {
            $c = New-Object Windows.Controls.ColumnDefinition; $c.Width = $w
            $grid.ColumnDefinitions.Add($c) | Out-Null
        }
        1..4 | ForEach-Object {
            $r = New-Object Windows.Controls.RowDefinition; $r.Height = [Windows.GridLength]::Auto
            $grid.RowDefinitions.Add($r) | Out-Null
        }

        # ── Status indicator (ellipse + symbol) ──
        $indicator                  = New-Object Windows.Controls.Grid
        $indicator.Width            = 26
        $indicator.Height           = 26
        $indicator.VerticalAlignment = 'Top'
        $indicator.Margin           = New-Object Windows.Thickness(0, 2, 10, 0)
        [Windows.Controls.Grid]::SetColumn($indicator, 0)
        [Windows.Controls.Grid]::SetRowSpan($indicator, 4)

        $ellipse      = New-Object Windows.Shapes.Ellipse
        $ellipse.Fill = New-Object Windows.Media.SolidColorBrush($statusColor)

        $sym                     = New-Object Windows.Controls.TextBlock
        $sym.Text                = $statusSymbol
        $sym.Foreground          = New-Object Windows.Media.SolidColorBrush('White')
        $sym.HorizontalAlignment = 'Center'
        $sym.VerticalAlignment   = 'Center'
        $sym.FontWeight          = 'Bold'
        $sym.FontSize            = 12
        $indicator.Children.Add($ellipse) | Out-Null
        $indicator.Children.Add($sym)     | Out-Null

        # ── Row 0: Step name ──
        $nameText            = New-Object Windows.Controls.TextBlock
        $nameText.Text       = $step.Name
        $nameText.FontSize   = 13
        $nameText.FontWeight = 'Bold'
        $nameText.Foreground = New-Object Windows.Media.SolidColorBrush($(if($isDark){'#E8E8F0'}else{'#1A1F3C'}))
        [Windows.Controls.Grid]::SetColumn($nameText, 1)
        [Windows.Controls.Grid]::SetRow($nameText, 0)

        # ── Row 0 col 2: Status badge ──
        $badge                     = New-Object Windows.Controls.TextBlock
        $badge.Text                = $step.Status
        $badge.FontSize            = 11
        $badge.FontWeight          = 'Bold'
        $badge.Foreground          = New-Object Windows.Media.SolidColorBrush($statusColor)
        $badge.HorizontalAlignment = 'Right'
        $badge.VerticalAlignment   = 'Top'
        [Windows.Controls.Grid]::SetColumn($badge, 2)
        [Windows.Controls.Grid]::SetRow($badge, 0)

        # ── Row 1: Description ──
        $descText              = New-Object Windows.Controls.TextBlock
        $descText.Text         = $step.Description
        $descText.FontSize     = 10
        $descText.Foreground   = New-Object Windows.Media.SolidColorBrush($(if($isDark){'#6666AA'}else{'#7788AA'}))
        $descText.FontStyle    = 'Italic'
        $descText.TextWrapping = 'Wrap'
        $descText.Margin       = New-Object Windows.Thickness(0, 1, 0, 0)
        [Windows.Controls.Grid]::SetColumn($descText, 1)
        [Windows.Controls.Grid]::SetColumnSpan($descText, 2)
        [Windows.Controls.Grid]::SetRow($descText, 1)

        # ── Row 2: Diagnostic message + TestResultText ──
        $msgStack = New-Object Windows.Controls.StackPanel
        $msgStack.Margin = New-Object Windows.Thickness(0, 4, 0, 0)
        [Windows.Controls.Grid]::SetColumn($msgStack, 1)
        [Windows.Controls.Grid]::SetColumnSpan($msgStack, 2)
        [Windows.Controls.Grid]::SetRow($msgStack, 2)

        $diagMsg              = New-Object Windows.Controls.TextBlock
        $diagMsg.Text         = $step.Message
        $diagMsg.FontSize     = 11
        $diagMsg.Foreground   = New-Object Windows.Media.SolidColorBrush($(if($isDark){'#AAAACC'}else{'#445577'}))
        $diagMsg.TextWrapping = 'Wrap'
        $msgStack.Children.Add($diagMsg) | Out-Null

        if ($step.TestResultText) {
            $trtText              = New-Object Windows.Controls.TextBlock
            $trtText.Text         = $step.TestResultText
            $trtText.FontSize     = 11
            $trtText.Foreground   = New-Object Windows.Media.SolidColorBrush($(if($isDark){'#8888BB'}else{'#6677AA'}))
            $trtText.FontStyle    = 'Italic'
            $trtText.TextWrapping = 'Wrap'
            $trtText.Margin       = New-Object Windows.Thickness(0, 2, 0, 0)
            $msgStack.Children.Add($trtText) | Out-Null
        }

        # ── Row 3: Resolution steps (only for non-Passed with text) ──
        if ($step.Status -ne 'Passed' -and $step.ResolutionText) {
            $resBorder                 = New-Object Windows.Controls.Border
            $resBorder.Background      = New-Object Windows.Media.SolidColorBrush($(if($isDark){'#1F1808'}else{'#FFFBF0'}))
            $resBorder.BorderBrush     = New-Object Windows.Media.SolidColorBrush($(if($isDark){'#FBBF24'}else{'#E0A020'}))
            $resBorder.BorderThickness = New-Object Windows.Thickness(3, 0, 0, 0)
            $resBorder.CornerRadius    = New-Object Windows.CornerRadius(0, 4, 4, 0)
            $resBorder.Padding         = New-Object Windows.Thickness(8, 6, 8, 6)
            $resBorder.Margin          = New-Object Windows.Thickness(0, 8, 0, 0)
            [Windows.Controls.Grid]::SetColumn($resBorder, 1)
            [Windows.Controls.Grid]::SetColumnSpan($resBorder, 2)
            [Windows.Controls.Grid]::SetRow($resBorder, 3)

            $resStack = New-Object Windows.Controls.StackPanel

            $resHeader            = New-Object Windows.Controls.TextBlock
            $resHeader.Text       = 'Resolution Steps'
            $resHeader.FontSize   = 10
            $resHeader.FontWeight = 'Bold'
            $resHeader.Foreground = New-Object Windows.Media.SolidColorBrush($(if($isDark){'#FBBF24'}else{'#A06010'}))
            $resHeader.Margin     = New-Object Windows.Thickness(0, 0, 0, 4)

            $resBody              = New-Object Windows.Controls.TextBlock
            $resBody.Text         = $step.ResolutionText
            $resBody.FontSize     = 11
            $resBody.Foreground   = New-Object Windows.Media.SolidColorBrush($(if($isDark){'#E8D9A0'}else{'#5C3A00'}))
            $resBody.TextWrapping = 'Wrap'

            $resStack.Children.Add($resHeader) | Out-Null
            $resStack.Children.Add($resBody)   | Out-Null

            # ── Fix It button row (only for Failed steps with a ResolutionScript) ──
            if ($step.Status -eq 'Failed' -and $step.ResolutionScript) {
                $fixRow = New-Object Windows.Controls.DockPanel
                $fixRow.Margin = New-Object Windows.Thickness(0, 8, 0, 0)

                $fixBtn                     = New-Object Windows.Controls.Button
                $fixBtn.Content             = 'Fix It'
                $fixBtn.Width               = 72
                $fixBtn.Height              = 26
                $fixBtn.FontSize            = 11
                $fixBtn.FontWeight          = 'Bold'
                $fixBtn.Background          = New-Object Windows.Media.SolidColorBrush('#E65100')
                $fixBtn.Foreground          = New-Object Windows.Media.SolidColorBrush('White')
                $fixBtn.BorderThickness     = New-Object Windows.Thickness(0)
                $fixBtn.Cursor              = 'Hand'
                [Windows.Controls.DockPanel]::SetDock($fixBtn, 'Left')

                $fixStatus                  = New-Object Windows.Controls.TextBlock
                $fixStatus.FontSize         = 10
                $fixStatus.VerticalAlignment = 'Center'
                $fixStatus.Margin           = New-Object Windows.Thickness(10, 0, 0, 0)
                $fixStatus.TextWrapping     = 'Wrap'
                $fixStatus.Foreground       = New-Object Windows.Media.SolidColorBrush($(if($isDark){'#9999BB'}else{'#556688'}))
                $fixStatus.Text             = 'Click to run the resolution script automatically.'

                # Capture script text in a local variable for the closure
                $capturedScript = $step.ResolutionScript
                $capturedBtn    = $fixBtn
                $capturedStatus = $fixStatus

                $fixBtn.Add_Click({
                    $capturedBtn.IsEnabled  = $false
                    $capturedBtn.Content    = 'Running…'
                    $capturedStatus.Text    = 'Running resolution script…'
                    $capturedStatus.Foreground = New-Object Windows.Media.SolidColorBrush('#1565C0')
                    try {
                        $sb = [scriptblock]::Create($capturedScript)
                        & $sb | Out-Null
                        $capturedBtn.Content       = 'Done'
                        $capturedBtn.Background    = New-Object Windows.Media.SolidColorBrush('#2E7D32')
                        $capturedStatus.Text       = 'Resolution script completed successfully.'
                        $capturedStatus.Foreground = New-Object Windows.Media.SolidColorBrush('#1B5E20')
                    } catch {
                        $capturedBtn.Content       = 'Failed'
                        $capturedBtn.Background    = New-Object Windows.Media.SolidColorBrush('#B71C1C')
                        $capturedStatus.Text       = "Error: $($_.Exception.Message)"
                        $capturedStatus.Foreground = New-Object Windows.Media.SolidColorBrush('#B71C1C')
                    }
                })

                $fixRow.Children.Add($fixBtn)    | Out-Null
                $fixRow.Children.Add($fixStatus) | Out-Null
                $resStack.Children.Add($fixRow)  | Out-Null

                # Register for Fix All
                $fixItButtons[$step.Name]  = $fixBtn
                $fixItStatuses[$step.Name] = $fixStatus
            }

            # ── Warning: Hub + IT contact callout (no Fix It for warnings) ──
            if ($step.Status -eq 'Warning') {
                $warnRow        = New-Object Windows.Controls.DockPanel
                $warnRow.Margin = New-Object Windows.Thickness(0, 10, 0, 0)

                $hubBtn                 = New-Object Windows.Controls.Button
                $hubBtn.Content         = '🔗  Open Intelligent Hub'
                $hubBtn.Height          = 26
                $hubBtn.FontSize        = 11
                $hubBtn.FontWeight      = 'SemiBold'
                $hubBtn.Background      = New-Object Windows.Media.SolidColorBrush('#252550')
                $hubBtn.Foreground      = New-Object Windows.Media.SolidColorBrush('#9090FF')
                $hubBtn.BorderThickness = New-Object Windows.Thickness(0)
                $hubBtn.Padding         = New-Object Windows.Thickness(12, 0, 12, 0)
                $hubBtn.Cursor          = 'Hand'
                $capturedHubUrl = $branding.HubUrl
                $hubBtn.Add_Click({ Start-Process $capturedHubUrl })
                [Windows.Controls.DockPanel]::SetDock($hubBtn, 'Left')

                $itNote                   = New-Object Windows.Controls.TextBlock
                $itNote.Text              = 'Contact IT · Check Intelligent Hub for potential solutions'
                $itNote.FontSize          = 10
                $itNote.Foreground        = New-Object Windows.Media.SolidColorBrush($(if($isDark){'#7777AA'}else{'#5566AA'}))
                $itNote.VerticalAlignment = 'Center'
                $itNote.Margin            = New-Object Windows.Thickness(12, 0, 0, 0)
                $itNote.TextWrapping      = 'Wrap'

                $warnRow.Children.Add($hubBtn) | Out-Null
                $warnRow.Children.Add($itNote) | Out-Null
                $resStack.Children.Add($warnRow) | Out-Null
            }

            $resBorder.Child = $resStack

            # ── Auto-remediation banner (shown when -AutoRemediate already ran) ──
            if ($step.RemediationRan) {
                $remBanner            = New-Object Windows.Controls.TextBlock
                $remBanner.Text       = '[Auto-Fixed]  ' + $step.RemediationStatus
                $remBanner.FontSize   = 10
                $remBanner.Foreground = New-Object Windows.Media.SolidColorBrush('#1B5E20')
                $remBanner.Margin     = New-Object Windows.Thickness(0, 4, 0, 0)
                $resStack.Children.Add($remBanner) | Out-Null
            }

            $grid.Children.Add($resBorder) | Out-Null
        }

        $grid.Children.Add($indicator) | Out-Null
        $grid.Children.Add($nameText)  | Out-Null
        $grid.Children.Add($badge)     | Out-Null
        $grid.Children.Add($descText)  | Out-Null
        $grid.Children.Add($msgStack)  | Out-Null

        # ── Hover effect ──
        $card.Add_MouseEnter({ param($s,$e); $s.Background = New-Object Windows.Media.SolidColorBrush($cardBgHover)  })
        $card.Add_MouseLeave({ param($s,$e); $s.Background = New-Object Windows.Media.SolidColorBrush($cardBgNormal) })

        $card.Child = $grid
        $panel.Children.Add($card) | Out-Null
    }

    # ── Wire up window chrome ──
    $window.FindName('CloseButton').Add_Click({       $window.Close() })
    $window.FindName('ChromeCloseButton').Add_Click({ $window.Close() })
    $window.FindName('MinimizeButton').Add_Click({    $window.WindowState = 'Minimized' })
    $window.FindName('HeaderBar').Add_MouseLeftButtonDown({ $window.DragMove() })

    # ── Wire up Fix All button (hidden when there are no failures) ──
    $fixAllBtn    = $window.FindName('FixAllButton')
    $fixAllStatus = $window.FindName('FixAllStatus')
    if ($results.Failed -eq 0) { $fixAllBtn.Visibility = 'Collapsed' }

    # Capture collections for the closure
    $capturedResults   = $results
    $capturedFixBtns   = $fixItButtons
    $capturedFixStats  = $fixItStatuses
    $capturedFixAllBtn = $fixAllBtn
    $capturedFixAllSt  = $fixAllStatus

    $fixAllBtn.Add_Click({
        $capturedFixAllBtn.IsEnabled = $false
        $capturedFixAllBtn.Content   = 'Running…'
        $capturedFixAllSt.Text       = 'Running resolution scripts—please wait…'
        $capturedFixAllSt.Foreground = New-Object Windows.Media.SolidColorBrush('#1565C0')

        $ran = 0; $failed = 0

        foreach ($s in $capturedResults.Steps) {
            if ($s.Status -ne 'Failed' -or -not $s.ResolutionScript) { continue }

            # Mirror state onto the individual Fix It button if it exists
            if ($capturedFixBtns.ContainsKey($s.Name)) {
                $capturedFixBtns[$s.Name].IsEnabled = $false
                $capturedFixBtns[$s.Name].Content   = 'Running…'
                $capturedFixStats[$s.Name].Text      = 'Running…'
                $capturedFixStats[$s.Name].Foreground = New-Object Windows.Media.SolidColorBrush('#1565C0')
            }

            try {
                $sb = [scriptblock]::Create($s.ResolutionScript)
                & $sb | Out-Null
                $ran++
                if ($capturedFixBtns.ContainsKey($s.Name)) {
                    $capturedFixBtns[$s.Name].Content    = 'Done'
                    $capturedFixBtns[$s.Name].Background = New-Object Windows.Media.SolidColorBrush('#2E7D32')
                    $capturedFixStats[$s.Name].Text      = 'Completed successfully.'
                    $capturedFixStats[$s.Name].Foreground = New-Object Windows.Media.SolidColorBrush('#1B5E20')
                }
            } catch {
                $failed++
                if ($capturedFixBtns.ContainsKey($s.Name)) {
                    $capturedFixBtns[$s.Name].Content    = 'Failed'
                    $capturedFixBtns[$s.Name].Background = New-Object Windows.Media.SolidColorBrush('#B71C1C')
                    $capturedFixStats[$s.Name].Text      = "Error: $($_.Exception.Message)"
                    $capturedFixStats[$s.Name].Foreground = New-Object Windows.Media.SolidColorBrush('#B71C1C')
                }
            }
        }

        if ($failed -eq 0) {
            $capturedFixAllBtn.Content    = 'All Done'
            $capturedFixAllBtn.Background = New-Object Windows.Media.SolidColorBrush('#2E7D32')
            $capturedFixAllSt.Text        = "$ran script(s) ran successfully."
            $capturedFixAllSt.Foreground  = New-Object Windows.Media.SolidColorBrush('#1B5E20')
        } else {
            $capturedFixAllBtn.Content    = 'Partial'
            $capturedFixAllBtn.Background = New-Object Windows.Media.SolidColorBrush('#F57F17')
            $capturedFixAllSt.Text        = "$ran succeeded, $failed failed. Review individual cards above."
            $capturedFixAllSt.Foreground  = New-Object Windows.Media.SolidColorBrush('#E65100')
        }
    })

    # ── Countdown timer ──
    $timeoutProgress           = $window.FindName('TimeoutProgress')
    $timeoutText               = $window.FindName('TimeoutText')
    $timeoutProgress.Maximum   = $TimeoutSeconds
    $timeoutProgress.Value     = 0

    $timer          = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $script:elapsed = 0

    $timer.Add_Tick({
        $script:elapsed++
        $remaining               = $TimeoutSeconds - $script:elapsed
        $timeoutProgress.Value   = $script:elapsed
        $timeoutText.Text        = "Auto-closing in $remaining seconds…"
        if ($script:elapsed -ge $TimeoutSeconds) {
            $timer.Stop()
            $window.Close()
        }
    })

    # Stop the timer if the user closes the window early (prevents post-close tick exceptions)
    $window.Add_Closing({ $timer.Stop() })

    $timer.Start()
    $window.ShowDialog() | Out-Null

} catch {
    Write-Host "UI Error: $_" -ForegroundColor Red
}
