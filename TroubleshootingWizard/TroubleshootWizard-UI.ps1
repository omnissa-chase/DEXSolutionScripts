<#
.SYNOPSIS
    TroubleshootWizard-UI - WPF UI Library
.DESCRIPTION
    Dot-sourced by TroubleshootWizard.ps1 when a UI is required.
    Exposes the following public functions:
      Show-ProgressDialog  - Lightweight in-progress spinner (background STA runspace)
      Update-ProgressDialog - Update spinner text/value while steps run
      Close-ProgressDialog  - Tear down the spinner runspace
      Show-ResultsUI        - Full WPF results window shown after all steps complete

    Do NOT run this file directly — dot-source it or let TroubleshootWizard.ps1
    load it automatically.

.NOTES
    PowerShell 5.1 compatible.
    Requires PresentationFramework / WPF assemblies (loaded on first call).
#>

#region --- WPF assembly ---
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
#endregion

#region --- WPF helpers ---
function New-Brush     { param([string]$Color) New-Object Windows.Media.SolidColorBrush($Color) }
function New-Pad       { param([double]$L=0,[double]$T=0,[double]$R=0,[double]$B=0) New-Object Windows.Thickness($L,$T,$R,$B) }
function New-TextBlock {
    param([hashtable]$Props)
    $tb = New-Object Windows.Controls.TextBlock
    foreach ($kv in $Props.GetEnumerator()) { $tb.($kv.Key) = $kv.Value }
    $tb
}
#endregion

#region --- Progress dialog (background STA runspace) ---
function Show-ProgressDialog {
    param(
        [string] $DialogTitle = 'Running Diagnostics...',
        [int]    $StepCount   = 1,
        [bool]   $IsDark      = $true,
        [string] $AccentColor = '#7C6AF7'
    )

    $progBg     = if ($IsDark) { '#1E1E2E' } else { '#FFFFFF' }
    $progBorder = if ($IsDark) { '#3A3A5C' } else { '#D0D5E8' }
    $progTitle  = if ($IsDark) { 'White'   } else { '#1A1F3C' }
    $progSub    = if ($IsDark) { '#9999BB' } else { '#7788AA' }
    $progTrack  = if ($IsDark) { '#2A2A40' } else { '#E8EAF0' }
    $progFill   = $AccentColor

    $sync = [hashtable]::Synchronized(@{
        Window    = $null
        Close     = $false
        StepText  = 'Initializing...'
        Value     = 0
        StepCount = $StepCount
    })

    $xamlProg = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Diagnostics" Width="440" Height="170"
  WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True" Background="Transparent" Topmost="True" ResizeMode="NoResize">
    <Border Background="$progBg" CornerRadius="10" BorderBrush="$progBorder" BorderThickness="1">
        <StackPanel Margin="28,22,28,22" VerticalAlignment="Center">
            <TextBlock Text="$DialogTitle" Foreground="$progTitle" FontSize="14" FontWeight="Bold" Margin="0,0,0,10"/>
            <TextBlock Name="StepLabel" Text="Starting..." Foreground="$progSub" FontSize="11" Margin="0,0,0,12" TextTrimming="CharacterEllipsis"/>
            <ProgressBar Name="PB" Height="5" Minimum="0" Maximum="$StepCount" Value="0" Background="$progTrack" Foreground="$progFill"/>
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

    $waited = 0
    while (-not $sync.Window -and $waited -lt 30) { Start-Sleep -Milliseconds 100; $waited++ }
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
    while (-not $Handle.Async.IsCompleted -and $waited -lt 30) { Start-Sleep -Milliseconds 100; $waited++ }
    try { $Handle.PS.EndInvoke($Handle.Async) } catch {}
    $Handle.PS.Dispose()
    $Handle.RS.Close()
    $Handle.RS.Dispose()
}
#endregion

#region --- Show-ResultsUI ---
function Show-ResultsUI {
    <#
    .SYNOPSIS
        Displays the WPF diagnostic results window.
    .PARAMETER Results
        Hashtable produced by TroubleshootWizard.ps1 — contains Passed, Failed,
        Warnings, Timestamp, and a Steps array.
    .PARAMETER Title
        Window title and header text.
    .PARAMETER XamlFile
        Full path to the XAML layout file.
    .PARAMETER TimeoutSeconds
        Seconds before the window auto-closes (default: 60).
    .PARAMETER ScriptRoot
        Directory of the calling script; used to locate Branding.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Results,
        [string] $Title          = 'Diagnostics Results',
        [string] $XamlFile       = '',
        [int]    $TimeoutSeconds = 60,
        [string] $ScriptRoot     = $PSScriptRoot
    )

    if ([string]::IsNullOrEmpty($XamlFile) -or -not (Test-Path $XamlFile)) {
        Write-Warning "Show-ResultsUI: XamlFile not found: $XamlFile"
        return
    }

    $xaml = Get-Content -Path $XamlFile -Raw -Encoding Unicode

    try {
        # Load XAML
        $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
        $window = [Windows.Markup.XamlReader]::Load($reader)

        # Detect light vs dark theme from the window background color
        $winBg  = $window.Background
        $isDark = $true
        if ($winBg -is [Windows.Media.SolidColorBrush]) {
            $isDark = ($winBg.Color.R + $winBg.Color.G + $winBg.Color.B) -lt 384
        }

        # Theme color palette — resolved once; every reference below uses $theme.*
        $theme = if ($isDark) {
            @{
                CardBgNormal     = '#1A1A2E'; CardBgHover      = '#1E1E3A'
                StepName         = '#E8E8F0'; StepDesc         = '#6666AA'
                DiagMsg          = '#AAAACC'; TrtText          = '#8888BB'
                ResBg            = '#1F1808'; ResBorder        = '#FBBF24'
                ResHeader        = '#FBBF24'; ResBody          = '#E8D9A0'
                FixStatus        = '#9999BB'; ItNote           = '#7777AA'
                HubBg            = '#252550'; HubFg            = '#9090FF'
                CloseBtnBg       = '#5C6890'
                PassBannerBg     = '#0D2218'; PassBannerBorder = '#1A5C35'; PassText = '#4ADE80'
                WarnBannerBg     = '#1F1808'; WarnBannerBorder = '#5C4A1A'; WarnText = '#FBBF24'
                FailBannerBg     = '#1F0D0D'; FailBannerBorder = '#5C1A1A'; FailText = '#F87171'
            }
        } else {
            @{
                CardBgNormal     = '#FFFFFF'; CardBgHover      = '#F5F6FC'
                StepName         = '#1A1F3C'; StepDesc         = '#7788AA'
                DiagMsg          = '#445577'; TrtText          = '#6677AA'
                ResBg            = '#FFFBF0'; ResBorder        = '#E0A020'
                ResHeader        = '#A06010'; ResBody          = '#5C3A00'
                FixStatus        = '#556688'; ItNote           = '#5566AA'
                HubBg            = '#EEF0FB'; HubFg            = '#3A4CC0'
                CloseBtnBg       = '#D0D5E8'
                PassBannerBg     = '#EDF7F1'; PassBannerBorder = '#A8D8B8'; PassText = '#1E6E42'
                WarnBannerBg     = '#FFFBF0'; WarnBannerBorder = '#F0D888'; WarnText = '#8A5C00'
                FailBannerBg     = '#FFF0F0'; FailBannerBorder = '#F0A8A8'; FailText = '#B02020'
            }
        }

        # Dynamic title
        $window.Title = $Title
        $window.FindName('HeaderTitle').Text = $Title

        # Window icon (embedded Base64 PNG)
        try {
            $iconB64 = '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'
            $iconBytes = [Convert]::FromBase64String($iconB64)
            $ms = New-Object System.IO.MemoryStream(,$iconBytes)
            $bmp = New-Object Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit(); $bmp.StreamSource = $ms
            $bmp.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bmp.EndInit(); $ms.Close()
            $window.Icon = $bmp
        } catch { <# icon is cosmetic - silently skip #> }

        #region Branding
        $branding = @{
            CompanyName      = 'Omnissa'
            LogoFile         = ''
            AccentColor      = '#7C6AF7'
            HeaderBackground = if ($isDark) { '#16162A' } else { '#FFFFFF' }
            HubUrl           = 'ws1winhub:'
            SupportText      = 'Contact IT Support'
            SupportUrl       = ''
        }
        $brandingPath = Join-Path $ScriptRoot 'Branding.json'
        if (Test-Path $brandingPath) {
            try {
                $b = Get-Content $brandingPath -Raw | ConvertFrom-Json
                foreach ($key in @('CompanyName','LogoFile','AccentColor','HeaderBackground','HubUrl','SupportText','SupportUrl')) {
                    if ($b.$key) { $branding[$key] = $b.$key }
                }
            } catch {}
        }

        $window.FindName('HeaderBar').Background       = New-Brush $branding.HeaderBackground
        $window.FindName('FixAllButton').Background    = New-Brush $branding.AccentColor
        $window.FindName('CloseButton').Background     = New-Brush $theme.CloseBtnBg
        $window.FindName('TimeoutProgress').Foreground = New-Brush $branding.AccentColor

        $logoCtrl = $window.FindName('LogoImage')
        if ($branding.LogoFile) {
            $resolvedLogo = if ([System.IO.Path]::IsPathRooted($branding.LogoFile)) {
                $branding.LogoFile
            } else {
                Join-Path $ScriptRoot $branding.LogoFile
            }
            if (Test-Path $resolvedLogo) {
                try {
                    $logoUri             = New-Object System.Uri((Resolve-Path $resolvedLogo).Path)
                    $logoCtrl.Source     = New-Object Windows.Media.Imaging.BitmapImage($logoUri)
                    $logoCtrl.Visibility = 'Visible'
                } catch { $logoCtrl.Visibility = 'Collapsed' }
            }
        }
        #endregion

        #region Header counts
        $window.FindName('PassedCount').Text  = $Results.Passed
        $window.FindName('FailedCount').Text  = $Results.Failed
        $window.FindName('WarningCount').Text = $Results.Warnings
        $humanTime = (Get-Date $Results.Timestamp).ToString('dddd, MMMM d yyyy') + ' . ' + (Get-Date $Results.Timestamp).ToString('h:mm tt')
        $window.FindName('TimestampText').Text = "Completed at: $humanTime"
        #endregion

        #region Conclusion banner
        $conclusionBanner = $window.FindName('ConclusionBanner')
        $conclusionIcon   = $window.FindName('ConclusionIcon')
        $conclusionText   = $window.FindName('ConclusionText')
        if ($Results.Failed -eq 0 -and $Results.Warnings -eq 0) {
            $conclusionBanner.Background  = New-Brush $theme.PassBannerBg
            $conclusionBanner.BorderBrush = New-Brush $theme.PassBannerBorder
            $conclusionIcon.Text          = [char]0x2705
            $conclusionText.Text          = 'All checks passed. No action required.'
            $conclusionText.Foreground    = New-Brush $theme.PassText
        } elseif ($Results.Failed -eq 0) {
            $conclusionBanner.Background  = New-Brush $theme.WarnBannerBg
            $conclusionBanner.BorderBrush = New-Brush $theme.WarnBannerBorder
            $conclusionIcon.Text          = [char]0x26A0 + [char]0xFE0F
            $w = $Results.Warnings
            $conclusionText.Text          = "$w warning$(if($w -ne 1){'s'}) found. Review the descriptions below - no action may be needed."
            $conclusionText.Foreground    = New-Brush $theme.WarnText
        } else {
            $conclusionBanner.Background  = New-Brush $theme.FailBannerBg
            $conclusionBanner.BorderBrush = New-Brush $theme.FailBannerBorder
            $conclusionIcon.Text          = [char]0x274C
            $f = $Results.Failed; $w = $Results.Warnings
            $msg = "$f error$(if($f -ne 1){'s'}) found"
            if ($w -gt 0) { $msg += " and $w warning$(if($w -ne 1){'s'})" }
            $conclusionText.Text       = "$msg. Use Fix It on affected steps or contact IT."
            $conclusionText.Foreground = New-Brush $theme.FailText
        }
        #endregion

        #region Result cards
        $panel         = $window.FindName('ResultsPanel')
        $fixItButtons  = @{}
        $fixItStatuses = @{}
        $statusColors  = @{ Passed = '#4CAF50'; Failed = '#F44336'; Warning = '#FF9800' }
        $statusSymbols = @{ Passed = 'OK';      Failed = 'X';       Warning = '!' }

        # Sort: Failed first, then Passed, then Warning
        $sortOrder  = @{ Failed = 0; Passed = 1; Warning = 2 }
        $sortedSteps = $Results.Steps | Sort-Object { $sortOrder[$_.Status] }

        $warningCards = [System.Collections.Generic.List[object]]::new()

        foreach ($step in $sortedSteps) {

            $statusColor  = if ($statusColors.ContainsKey($step.Status))  { $statusColors[$step.Status]  } else { '#9E9E9E' }
            $statusSymbol = if ($statusSymbols.ContainsKey($step.Status)) { $statusSymbols[$step.Status] } else { '?' }

            # Card
            $card                 = New-Object Windows.Controls.Border
            $card.Background      = New-Brush $theme.CardBgNormal
            $card.BorderBrush     = New-Brush $statusColor
            $card.BorderThickness = New-Pad 3 1 1 1
            $card.CornerRadius    = New-Object Windows.CornerRadius(6)
            $card.Padding         = New-Pad 15 12 15 12
            $card.Margin          = New-Pad 0 0 0 8
            $cardBgNormal = $theme.CardBgNormal
            $cardBgHover  = $theme.CardBgHover

            # Inner grid: 3 cols x 4 rows
            $grid = New-Object Windows.Controls.Grid
            foreach ($gw in @([Windows.GridLength]::new(44), [Windows.GridLength]::new(1,'Star'), [Windows.GridLength]::new(80))) {
                $c = New-Object Windows.Controls.ColumnDefinition; $c.Width = $gw
                $grid.ColumnDefinitions.Add($c) | Out-Null
            }
            1..4 | ForEach-Object {
                $r = New-Object Windows.Controls.RowDefinition; $r.Height = [Windows.GridLength]::Auto
                $grid.RowDefinitions.Add($r) | Out-Null
            }

            # Status indicator
            $indicator                   = New-Object Windows.Controls.Grid
            $indicator.Width             = 26
            $indicator.Height            = 26
            $indicator.VerticalAlignment = 'Top'
            $indicator.Margin            = New-Pad 0 2 10 0
            [Windows.Controls.Grid]::SetColumn($indicator, 0)
            [Windows.Controls.Grid]::SetRowSpan($indicator, 4)

            $ellipse      = New-Object Windows.Shapes.Ellipse
            $ellipse.Fill = New-Brush $statusColor

            $sym = New-TextBlock @{
                Text = $statusSymbol; Foreground = (New-Brush 'White')
                HorizontalAlignment = 'Center'; VerticalAlignment = 'Center'
                FontWeight = 'Bold'; FontSize = 12
            }
            $indicator.Children.Add($ellipse) | Out-Null
            $indicator.Children.Add($sym)     | Out-Null

            # Row 0: name + badge
            $nameText = New-TextBlock @{ Text = $step.Name; FontSize = 13; FontWeight = 'Bold'; Foreground = (New-Brush $theme.StepName) }
            [Windows.Controls.Grid]::SetColumn($nameText, 1); [Windows.Controls.Grid]::SetRow($nameText, 0)

            $badge = New-TextBlock @{
                Text = $step.Status; FontSize = 11; FontWeight = 'Bold'
                Foreground = (New-Brush $statusColor); HorizontalAlignment = 'Right'; VerticalAlignment = 'Top'
            }
            [Windows.Controls.Grid]::SetColumn($badge, 2); [Windows.Controls.Grid]::SetRow($badge, 0)

            # Row 1: description
            $descText = New-TextBlock @{
                Text = $step.Description; FontSize = 10; FontStyle = 'Italic'; TextWrapping = 'Wrap'
                Foreground = (New-Brush $theme.StepDesc); Margin = (New-Pad 0 1 0 0)
            }
            [Windows.Controls.Grid]::SetColumn($descText, 1); [Windows.Controls.Grid]::SetColumnSpan($descText, 2); [Windows.Controls.Grid]::SetRow($descText, 1)

            # Row 2: diagnostic message + TestResultText
            $msgStack        = New-Object Windows.Controls.StackPanel
            $msgStack.Margin = New-Pad 0 4 0 0
            [Windows.Controls.Grid]::SetColumn($msgStack, 1); [Windows.Controls.Grid]::SetColumnSpan($msgStack, 2); [Windows.Controls.Grid]::SetRow($msgStack, 2)

            $msgStack.Children.Add((New-TextBlock @{ Text = $step.Message; FontSize = 11; TextWrapping = 'Wrap'; Foreground = (New-Brush $theme.DiagMsg) })) | Out-Null

            if ($step.TestResultText) {
                $msgStack.Children.Add((New-TextBlock @{
                    Text = $step.TestResultText; FontSize = 11; FontStyle = 'Italic'; TextWrapping = 'Wrap'
                    Foreground = (New-Brush $theme.TrtText); Margin = (New-Pad 0 2 0 0)
                })) | Out-Null
            }

            # Row 3: resolution box (non-Passed steps only)
            if ($step.Status -ne 'Passed' -and $step.ResolutionText) {
                $resBorder                 = New-Object Windows.Controls.Border
                $resBorder.Background      = New-Brush $theme.ResBg
                $resBorder.BorderBrush     = New-Brush $theme.ResBorder
                $resBorder.BorderThickness = New-Pad 3 0 0 0
                $resBorder.CornerRadius    = New-Object Windows.CornerRadius(0, 4, 4, 0)
                $resBorder.Padding         = New-Pad 8 6 8 6
                $resBorder.Margin          = New-Pad 0 8 0 0
                [Windows.Controls.Grid]::SetColumn($resBorder, 1); [Windows.Controls.Grid]::SetColumnSpan($resBorder, 2); [Windows.Controls.Grid]::SetRow($resBorder, 3)

                $resStack = New-Object Windows.Controls.StackPanel
                $resStack.Children.Add((New-TextBlock @{ Text = 'Resolution Steps'; FontSize = 10; FontWeight = 'Bold'; Foreground = (New-Brush $theme.ResHeader); Margin = (New-Pad 0 0 0 4) })) | Out-Null
                $resStack.Children.Add((New-TextBlock @{ Text = $step.ResolutionText; FontSize = 11; TextWrapping = 'Wrap'; Foreground = (New-Brush $theme.ResBody) })) | Out-Null

                # Fix It row (Failed steps with a ResolutionScript)
                if ($step.Status -eq 'Failed' -and $step.ResolutionScript) {
                    $fixRow        = New-Object Windows.Controls.DockPanel
                    $fixRow.Margin = New-Pad 0 8 0 0

                    $fixBtn                 = New-Object Windows.Controls.Button
                    $fixBtn.Content         = 'Fix It'
                    $fixBtn.Width           = 72
                    $fixBtn.Height          = 26
                    $fixBtn.FontSize        = 11
                    $fixBtn.FontWeight      = 'Bold'
                    $fixBtn.Background      = New-Brush '#E65100'
                    $fixBtn.Foreground      = New-Brush 'White'
                    $fixBtn.BorderThickness = New-Pad 0 0 0 0
                    $fixBtn.Cursor          = 'Hand'
                    [Windows.Controls.DockPanel]::SetDock($fixBtn, 'Left')

                    $fixStatus = New-TextBlock @{
                        FontSize = 10; VerticalAlignment = 'Center'; TextWrapping = 'Wrap'
                        Margin = (New-Pad 10 0 0 0); Foreground = (New-Brush $theme.FixStatus)
                        Text = 'Click to run the resolution script automatically.'
                    }

                    $capturedScript = $step.ResolutionScript
                    $capturedBtn    = $fixBtn
                    $capturedStatus = $fixStatus

                    $fixBtn.Add_Click({
                        $capturedBtn.IsEnabled     = $false
                        $capturedBtn.Content       = 'Running...'
                        $capturedStatus.Text       = 'Running resolution script...'
                        $capturedStatus.Foreground = New-Brush '#1565C0'
                        try {
                            & ([scriptblock]::Create($capturedScript)) | Out-Null
                            $capturedBtn.Content       = 'Done'
                            $capturedBtn.Background    = New-Brush '#2E7D32'
                            $capturedStatus.Text       = 'Resolution script completed successfully.'
                            $capturedStatus.Foreground = New-Brush '#1B5E20'
                        } catch {
                            $capturedBtn.Content       = 'Failed'
                            $capturedBtn.Background    = New-Brush '#B71C1C'
                            $capturedStatus.Text       = "Error: $($_.Exception.Message)"
                            $capturedStatus.Foreground = New-Brush '#B71C1C'
                        }
                    })

                    $fixRow.Children.Add($fixBtn)    | Out-Null
                    $fixRow.Children.Add($fixStatus) | Out-Null
                    $resStack.Children.Add($fixRow)  | Out-Null

                    $fixItButtons[$step.Name]  = $fixBtn
                    $fixItStatuses[$step.Name] = $fixStatus
                }

                # Warning callout (Hub + IT contact)
                if ($step.Status -eq 'Warning') {
                    $warnRow        = New-Object Windows.Controls.DockPanel
                    $warnRow.Margin = New-Pad 0 10 0 0

                    $hubBtn                 = New-Object Windows.Controls.Button
                    $hubBtn.Content         = 'Open Intelligent Hub'
                    $hubBtn.Height          = 26
                    $hubBtn.FontSize        = 11
                    $hubBtn.FontWeight      = 'SemiBold'
                    $hubBtn.Background      = New-Brush $theme.HubBg
                    $hubBtn.Foreground      = New-Brush $theme.HubFg
                    $hubBtn.BorderThickness = New-Pad 0 0 0 0
                    $hubBtn.Padding         = New-Pad 12 0 12 0
                    $hubBtn.Cursor          = 'Hand'
                    $capturedHubUrl = $branding.HubUrl
                    $hubBtn.Add_Click({ Start-Process $capturedHubUrl })
                    [Windows.Controls.DockPanel]::SetDock($hubBtn, 'Left')

                    $resStack.Children.Add($warnRow) | Out-Null
                    $warnRow.Children.Add($hubBtn)   | Out-Null
                    $warnRow.Children.Add((New-TextBlock @{
                        Text = 'Contact IT - Check Intelligent Hub for potential solutions'
                        FontSize = 10; VerticalAlignment = 'Center'; TextWrapping = 'Wrap'
                        Foreground = (New-Brush $theme.ItNote); Margin = (New-Pad 12 0 0 0)
                    })) | Out-Null
                }

                # Auto-remediation banner
                if ($step.RemediationRan) {
                    $resStack.Children.Add((New-TextBlock @{
                        Text = '[Auto-Fixed]  ' + $step.RemediationStatus
                        FontSize = 10; Foreground = (New-Brush '#1B5E20'); Margin = (New-Pad 0 4 0 0)
                    })) | Out-Null
                }

                $resBorder.Child = $resStack
                $grid.Children.Add($resBorder) | Out-Null
            }

            $grid.Children.Add($indicator) | Out-Null
            $grid.Children.Add($nameText)  | Out-Null
            $grid.Children.Add($badge)     | Out-Null
            $grid.Children.Add($descText)  | Out-Null
            $grid.Children.Add($msgStack)  | Out-Null

            $card.Add_MouseEnter({ param($s,$e); $s.Background = New-Brush $cardBgHover  })
            $card.Add_MouseLeave({ param($s,$e); $s.Background = New-Brush $cardBgNormal })
            $card.Child = $grid

            if ($step.Status -eq 'Warning') {
                $card.Visibility = 'Collapsed'
                $warningCards.Add($card) | Out-Null
            } else {
                $panel.Children.Add($card) | Out-Null
            }
        }

        # Warning toggle button + collapsed warning cards
        if ($warningCards.Count -gt 0) {
            $warnToggle                 = New-Object Windows.Controls.Button
            $warnToggle.Content         = "Show Warnings ($($warningCards.Count))  ▼"
            $warnToggle.HorizontalAlignment = 'Stretch'
            $warnToggle.Height          = 32
            $warnToggle.FontSize        = 11
            $warnToggle.FontWeight      = 'SemiBold'
            $warnToggle.Background      = New-Brush $theme.WarnBannerBg
            $warnToggle.Foreground      = New-Brush $theme.WarnText
            $warnToggle.BorderBrush     = New-Brush $theme.WarnBannerBorder
            $warnToggle.BorderThickness = New-Pad 1 1 1 1
            $warnToggle.Cursor          = 'Hand'
            $warnToggle.Margin          = New-Pad 0 4 0 8
            $panel.Children.Add($warnToggle) | Out-Null

            foreach ($wc in $warningCards) { $panel.Children.Add($wc) | Out-Null }

            $capturedCards  = $warningCards
            $capturedBtn    = $warnToggle
            $capturedCount  = $warningCards.Count
            $warningsVisible = $false

            $warnToggle.Add_Click({
                $script:warningsVisible = -not $script:warningsVisible
                foreach ($wc in $capturedCards) {
                    $wc.Visibility = if ($script:warningsVisible) { 'Visible' } else { 'Collapsed' }
                }
                $capturedBtn.Content = if ($script:warningsVisible) {
                    "Hide Warnings ($capturedCount)  ▲"
                } else {
                    "Show Warnings ($capturedCount)  ▼"
                }
            })
        }
        #endregion

        #region Window chrome
        $window.FindName('CloseButton').Add_Click({       $window.Close() })
        $window.FindName('ChromeCloseButton').Add_Click({ $window.Close() })
        $window.FindName('MinimizeButton').Add_Click({    $window.WindowState = 'Minimized' })
        $window.FindName('HeaderBar').Add_MouseLeftButtonDown({ $window.DragMove() })
        #endregion

        #region Fix All
        $fixAllBtn    = $window.FindName('FixAllButton')
        $fixAllStatus = $window.FindName('FixAllStatus')
        if ($Results.Failed -eq 0) { $fixAllBtn.Visibility = 'Collapsed' }

        $capturedResults   = $Results
        $capturedFixBtns   = $fixItButtons
        $capturedFixStats  = $fixItStatuses
        $capturedFixAllBtn = $fixAllBtn
        $capturedFixAllSt  = $fixAllStatus

        $fixAllBtn.Add_Click({
            $capturedFixAllBtn.IsEnabled = $false
            $capturedFixAllBtn.Content   = 'Running...'
            $capturedFixAllSt.Text       = 'Running resolution scripts - please wait...'
            $capturedFixAllSt.Foreground = New-Brush '#1565C0'
            $ran = 0; $failed = 0

            foreach ($s in $capturedResults.Steps) {
                if ($s.Status -ne 'Failed' -or -not $s.ResolutionScript) { continue }
                if ($capturedFixBtns.ContainsKey($s.Name)) {
                    $capturedFixBtns[$s.Name].IsEnabled  = $false
                    $capturedFixBtns[$s.Name].Content    = 'Running...'
                    $capturedFixStats[$s.Name].Text      = 'Running...'
                    $capturedFixStats[$s.Name].Foreground = New-Brush '#1565C0'
                }
                try {
                    & ([scriptblock]::Create($s.ResolutionScript)) | Out-Null
                    $ran++
                    if ($capturedFixBtns.ContainsKey($s.Name)) {
                        $capturedFixBtns[$s.Name].Content     = 'Done'
                        $capturedFixBtns[$s.Name].Background  = New-Brush '#2E7D32'
                        $capturedFixStats[$s.Name].Text       = 'Completed successfully.'
                        $capturedFixStats[$s.Name].Foreground = New-Brush '#1B5E20'
                    }
                } catch {
                    $failed++
                    if ($capturedFixBtns.ContainsKey($s.Name)) {
                        $capturedFixBtns[$s.Name].Content     = 'Failed'
                        $capturedFixBtns[$s.Name].Background  = New-Brush '#B71C1C'
                        $capturedFixStats[$s.Name].Text       = "Error: $($_.Exception.Message)"
                        $capturedFixStats[$s.Name].Foreground = New-Brush '#B71C1C'
                    }
                }
            }

            if ($failed -eq 0) {
                $capturedFixAllBtn.Content    = 'All Done'
                $capturedFixAllBtn.Background = New-Brush '#2E7D32'
                $capturedFixAllSt.Text        = "$ran script(s) ran successfully."
                $capturedFixAllSt.Foreground  = New-Brush '#1B5E20'
            } else {
                $capturedFixAllBtn.Content    = 'Partial'
                $capturedFixAllBtn.Background = New-Brush '#F57F17'
                $capturedFixAllSt.Text        = "$ran succeeded, $failed failed. Review individual cards above."
                $capturedFixAllSt.Foreground  = New-Brush '#E65100'
            }
        })
        #endregion

        #region Countdown timer
        $timeoutProgress         = $window.FindName('TimeoutProgress')
        $timeoutText             = $window.FindName('TimeoutText')
        $timeoutProgress.Maximum = $TimeoutSeconds
        $timeoutProgress.Value   = 0

        $timer          = New-Object System.Windows.Forms.Timer
        $timer.Interval = 1000
        $script:elapsed = 0

        $capturedTimeout = $TimeoutSeconds
        $timer.Add_Tick({
            $script:elapsed++
            $remaining             = $capturedTimeout - $script:elapsed
            $timeoutProgress.Value = $script:elapsed
            $timeoutText.Text      = "Auto-closing in $remaining seconds..."
            if ($script:elapsed -ge $capturedTimeout) { $timer.Stop(); $window.Close() }
        })
        $window.Add_Closing({ $timer.Stop() })
        $timer.Start()
        #endregion

        $window.ShowDialog() | Out-Null

    } catch {
        Write-Warning "Show-ResultsUI error: $_"
    }
}
#endregion
