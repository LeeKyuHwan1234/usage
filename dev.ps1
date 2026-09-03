[CmdletBinding()]
param(
    # Leave empty to use the Windows account that starts this app.
    [string]$UserDataRoot = $env:USERPROFILE,
    [switch]$Setup
)

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"", '-UserDataRoot', ('"{0}"' -f $UserDataRoot))
    if ($Setup) { $arguments += '-Setup' }
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $arguments
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName PresentationFramework

# Keep one tray dashboard per Windows user. The setup window is allowed separately.
if (-not $Setup) {
    $createdNew = $false
    $mutexName = "Local\AIUsageDashboard_$([Environment]::UserName)"
    $script:instanceMutex = [Threading.Mutex]::new($true, $mutexName, [ref]$createdNew)
    if (-not $createdNew) {
        $script:instanceMutex.Dispose()
        [System.Windows.Forms.MessageBox]::Show('AI Usage Dashboard is already running in the notification area.', 'AI Usage Dashboard', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        exit
    }
}
$script:usageCache = @{}
$script:pollSeconds = 300

function Get-JsonFile($path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { Get-Content -Raw -LiteralPath $path -ErrorAction Stop | ConvertFrom-Json } catch { $null }
}

$script:settingsDir = Join-Path $env:LOCALAPPDATA 'AIUsageDashboard'
$script:settingsFile = Join-Path $script:settingsDir 'settings.json'
$script:settings = Get-JsonFile $script:settingsFile

function Test-ProviderLogin($provider) {
    if ($provider -eq 'Codex') {
        $auth = Get-JsonFile (Join-Path $UserDataRoot '.codex\auth.json')
        return [bool]$auth.tokens.access_token
    }
    $auth = Get-JsonFile (Join-Path $UserDataRoot '.claude\.credentials.json')
    return [bool]$auth.claudeAiOauth.accessToken
}

function Get-ProviderSetupMessage($provider) {
    if ($provider -eq 'Codex') {
        return 'Setup required: run codex login with your ChatGPT account.'
    }
    return 'Setup required: open Claude Code and sign in to Claude.ai.'
}

function Save-ProviderSettings($codexEnabled, $claudeEnabled) {
    New-Item -ItemType Directory -Force -Path $script:settingsDir | Out-Null
    [pscustomobject]@{ showCodex = [bool]$codexEnabled; showClaude = [bool]$claudeEnabled; showBadge = if ($script:settings.showBadge -ne $null) { [bool]$script:settings.showBadge } else { $true }; badgeLeft = if ($script:settings.badgeLeft -ne $null) { $script:settings.badgeLeft } else { $null }; badgeTop = if ($script:settings.badgeTop -ne $null) { $script:settings.badgeTop } else { $null } } | ConvertTo-Json | Set-Content -LiteralPath $script:settingsFile -Encoding UTF8
    $script:settings = Get-JsonFile $script:settingsFile
}

function Show-ProviderSetup {
    $form = [System.Windows.Forms.Form]::new()
    $background = [System.Drawing.Color]::FromArgb(15, 23, 42)
    $surface = [System.Drawing.Color]::FromArgb(24, 35, 56)
    $text = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $muted = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $form.Text = 'AI Usage Dashboard - Setup'; $form.Size = [System.Drawing.Size]::new(390, 270); $form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'None'; $form.MaximizeBox = $false; $form.MinimizeBox = $false; $form.BackColor = $background; $form.Padding = [System.Windows.Forms.Padding]::new(18)
    $form.Add_Shown({ Set-RoundedControlRegion $form 22 })
    $form.Add_SizeChanged({ Set-RoundedControlRegion $form 22 })
    $header = [System.Windows.Forms.Label]::new(); $header.Text = 'AI Usage Dashboard'; $header.Font = [System.Drawing.Font]::new('Segoe UI', 13, [System.Drawing.FontStyle]::Bold); $header.ForeColor = $text; $header.BackColor = $background; $header.Location = [System.Drawing.Point]::new(24, 23); $header.Size = [System.Drawing.Size]::new(250, 28)
    $intro = [System.Windows.Forms.Label]::new(); $intro.Text = 'Choose the providers to show in your tray.'; $intro.ForeColor = $muted; $intro.BackColor = $background; $intro.Location = [System.Drawing.Point]::new(24, 54); $intro.Size = [System.Drawing.Size]::new(320, 24)
    $content = [System.Windows.Forms.Panel]::new(); $content.BackColor = $surface; $content.Location = [System.Drawing.Point]::new(18, 87); $content.Size = [System.Drawing.Size]::new(354, 105)
    Set-RoundedControlRegion $content 16
    $codexBox = [System.Windows.Forms.CheckBox]::new(); $codexBox.Text = 'Codex'; $codexBox.Location = [System.Drawing.Point]::new(16, 15); $codexBox.AutoSize = $true; $codexBox.ForeColor = $text; $codexBox.BackColor = $surface; $codexBox.Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $claudeBox = [System.Windows.Forms.CheckBox]::new(); $claudeBox.Text = 'Claude'; $claudeBox.Location = [System.Drawing.Point]::new(16, 57); $claudeBox.AutoSize = $true; $claudeBox.ForeColor = $text; $claudeBox.BackColor = $surface; $claudeBox.Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $codexBox.Checked = if ($script:settings) { [bool]$script:settings.showCodex } else { Test-ProviderLogin 'Codex' }
    $claudeBox.Checked = if ($script:settings) { [bool]$script:settings.showClaude } else { Test-ProviderLogin 'Claude' }
    $codexStatus = [System.Windows.Forms.Label]::new(); $codexStatus.Text = if (Test-ProviderLogin 'Codex') { 'Ready' } else { 'Not signed in - run codex login' }; $codexStatus.Location = [System.Drawing.Point]::new(112, 16); $codexStatus.Size = [System.Drawing.Size]::new(220, 20); $codexStatus.ForeColor = if (Test-ProviderLogin 'Codex') { [System.Drawing.Color]::FromArgb(74, 222, 128) } else { [System.Drawing.Color]::FromArgb(251, 191, 36) }; $codexStatus.BackColor = $surface
    $claudeStatus = [System.Windows.Forms.Label]::new(); $claudeStatus.Text = if (Test-ProviderLogin 'Claude') { 'Ready' } else { 'Not signed in - sign in to Claude Code' }; $claudeStatus.Location = [System.Drawing.Point]::new(112, 58); $claudeStatus.Size = [System.Drawing.Size]::new(220, 20); $claudeStatus.ForeColor = if (Test-ProviderLogin 'Claude') { [System.Drawing.Color]::FromArgb(74, 222, 128) } else { [System.Drawing.Color]::FromArgb(251, 191, 36) }; $claudeStatus.BackColor = $surface
    $hint = [System.Windows.Forms.Label]::new(); $hint.Text = 'You can change this later from the tray menu.'; $hint.Location = [System.Drawing.Point]::new(24, 201); $hint.Size = [System.Drawing.Size]::new(300, 20); $hint.ForeColor = $muted; $hint.BackColor = $background
    $save = [System.Windows.Forms.Button]::new(); $save.Text = 'Save'; $save.Location = [System.Drawing.Point]::new(204, 229); $save.Size = [System.Drawing.Size]::new(78, 28); $save.FlatStyle = 'Flat'; $save.FlatAppearance.BorderSize = 0; $save.BackColor = [System.Drawing.Color]::FromArgb(45, 212, 191); $save.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
    $cancel = [System.Windows.Forms.Button]::new(); $cancel.Text = 'Cancel'; $cancel.Location = [System.Drawing.Point]::new(290, 229); $cancel.Size = [System.Drawing.Size]::new(78, 28); $cancel.FlatStyle = 'Flat'; $cancel.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(71, 85, 105); $cancel.BackColor = $surface; $cancel.ForeColor = $text
    foreach ($control in @($codexBox, $claudeBox, $codexStatus, $claudeStatus)) { $content.Controls.Add($control) }
    foreach ($control in @($header, $intro, $content, $hint, $save, $cancel)) { $form.Controls.Add($control) }
    Set-RoundedControlRegion $save 10; Set-RoundedControlRegion $cancel 10
    $save.Add_Click({ Save-ProviderSettings $codexBox.Checked $claudeBox.Checked; $form.DialogResult = [System.Windows.Forms.DialogResult]::OK; $form.Close() })
    $cancel.Add_Click({ $form.Close() })
    $null = $form.ShowDialog()
    if (-not $script:settings) { Save-ProviderSettings $codexBox.Checked $claudeBox.Checked }
}

function Get-Usage($provider) {
    $cached = $script:usageCache[$provider]
    if ($cached -and (((Get-Date) - $cached.fetchedAt).TotalSeconds -lt $script:pollSeconds)) {
        return $cached.value
    }
    if ($provider -eq 'Claude') {
        $auth = (Get-JsonFile (Join-Path $UserDataRoot '.claude\.credentials.json')).claudeAiOauth
        if (-not $auth.accessToken) { return @{ error = Get-ProviderSetupMessage 'Claude' } }
        $uri = 'https://api.anthropic.com/api/oauth/usage'
        $headers = @{ Authorization = "Bearer $($auth.accessToken)"; 'anthropic-version' = '2023-06-01'; 'User-Agent' = 'usage-dashboard-local' }
    } else {
        $auth = Get-JsonFile (Join-Path $UserDataRoot '.codex\auth.json')
        $token = $auth.tokens.access_token
        if (-not $token) { return @{ error = Get-ProviderSetupMessage 'Codex' } }
        $uri = 'https://chatgpt.com/backend-api/wham/usage'
        $headers = @{ Authorization = "Bearer $token"; 'User-Agent' = 'usage-dashboard-local' }
    }
    try {
        $raw = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 15
        if ($provider -eq 'Codex') { $result = @{ five = $raw.rate_limit.primary_window; seven = $raw.rate_limit.secondary_window } }
        else { $result = @{ five = $raw.five_hour; seven = $raw.seven_day } }
        $script:usageCache[$provider] = @{ value = $result; fetchedAt = Get-Date }
        return $result
    } catch {
        # Keep showing the last successful value instead of repeatedly retrying after a rate limit.
        if ($cached) { return $cached.value }
        return @{ error = "request failed: $($_.Exception.Message)" }
    }
}

function Format-Usage($data) {
    if (-not $data) { return '--' }
    $used = Get-UsagePercent $data
    if ($null -ne $data.used_percent) {
        $reset = if ($data.reset_at) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$data.reset_at).ToLocalTime().ToString('HH:mm') } else { '--:--' }
        return "$used% used, reset $reset"
    }
    $reset = if ($data.resets_at) { ([datetime]$data.resets_at).ToLocalTime().ToString('HH:mm') } else { '--:--' }
    return "$used% used, reset $reset"
}

function Get-UsagePercent($data) {
    if ($null -ne $data.used_percent) { return [Math]::Round([double]$data.used_percent) }
    $ratio = if ($null -ne $data.utilization) { [double]$data.utilization } else { 0 }
    if ($ratio -le 1) { return [Math]::Round($ratio * 100) }
    return [Math]::Round($ratio)
}

function Get-ResetText($data, [switch]$Weekly) {
    $format = if ($Weekly) { 'MM/dd HH:mm' } else { 'HH:mm' }
    if ($null -ne $data.used_percent) {
        if ($data.reset_at) { return "Resets " + [DateTimeOffset]::FromUnixTimeSeconds([int64]$data.reset_at).ToLocalTime().ToString($format) }
    } elseif ($data.resets_at) {
        return "Resets " + ([datetime]$data.resets_at).ToLocalTime().ToString($format)
    }
    return 'Reset time unavailable'
}

function Get-GaugeColor($percent) {
    if ($percent -ge 80) { return [System.Drawing.Color]::FromArgb(220, 38, 38) }
    if ($percent -ge 60) { return [System.Drawing.Color]::FromArgb(217, 119, 6) }
    return [System.Drawing.Color]::FromArgb(34, 197, 94)
}

function New-RoundedPath($rectangle, $radius) {
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $diameter = $radius * 2
    $path.AddArc($rectangle.X, $rectangle.Y, $diameter, $diameter, 180, 90)
    $path.AddArc($rectangle.Right - $diameter, $rectangle.Y, $diameter, $diameter, 270, 90)
    $path.AddArc($rectangle.Right - $diameter, $rectangle.Bottom - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($rectangle.X, $rectangle.Bottom - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    return $path
}

function Set-RoundedControlRegion($control, $radius) {
    if ($control.Width -le ($radius * 2) -or $control.Height -le ($radius * 2)) { return }
    $path = New-RoundedPath ([System.Drawing.Rectangle]::new(0, 0, $control.Width, $control.Height)) $radius
    $control.Region = [System.Drawing.Region]::new($path)
    $path.Dispose()
}

function Draw-RoundedRectangle($graphics, $color, $rectangle, $radius) {
    if ($rectangle.Width -le 0 -or $rectangle.Height -le 0) { return }
    $path = New-RoundedPath $rectangle $radius
    $brush = [System.Drawing.SolidBrush]::new($color)
    $graphics.FillPath($brush, $path)
    $brush.Dispose(); $path.Dispose()
}

function Enable-DoubleBuffer($control) {
    $property = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic,Instance')
    $property.SetValue($control, $true, $null)
}

function New-DashboardTrayIcon([int]$percent = 0) {
    $percent = [Math]::Min(100, [Math]::Max(0, $percent))
    $bitmap = [System.Drawing.Bitmap]::new(32, 32)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $baseBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(15, 23, 42))
    $graphics.FillEllipse($baseBrush, 1, 1, 30, 30); $baseBrush.Dispose()
    $trackPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(51, 65, 85), 4)
    $graphics.DrawArc($trackPen, 4, 4, 24, 24, -90, 360); $trackPen.Dispose()
    if ($percent -gt 0) {
        $ringPen = [System.Drawing.Pen]::new((Get-GaugeColor $percent), 4)
        $graphics.DrawArc($ringPen, 4, 4, 24, 24, -90, [Math]::Max(8, [Math]::Round(360 * $percent / 100)))
        $ringPen.Dispose()
    }
    $graphics.Dispose()
    $script:trayBitmap = $bitmap
    $script:trayIcon = [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
    return $script:trayIcon
}

function New-UsageCard($title) {
    $panel = [System.Windows.Forms.Panel]::new()
    $panel.Size = [System.Drawing.Size]::new(318, 148)
    $panel.BackColor = [System.Drawing.Color]::FromArgb(11, 18, 32)
    Enable-DoubleBuffer $panel
    $panel.Padding = [System.Windows.Forms.Padding]::new(14)
    $cardBackground = [System.Drawing.Color]::FromArgb(23, 33, 52)
    $titleLabel = [System.Windows.Forms.Label]::new()
    $titleLabel.Text = $title; $titleLabel.Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240); $titleLabel.Location = [System.Drawing.Point]::new(18, 14); $titleLabel.AutoSize = $true; $titleLabel.BackColor = $cardBackground
    $session = [System.Windows.Forms.Label]::new(); $session.Text = '5h session'; $session.Font = [System.Drawing.Font]::new('Segoe UI', 8, [System.Drawing.FontStyle]::Bold); $session.Location = [System.Drawing.Point]::new(18, 42); $session.AutoSize = $true; $session.BackColor = $cardBackground; $session.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
    $week = [System.Windows.Forms.Label]::new(); $week.Text = '7d weekly'; $week.Font = [System.Drawing.Font]::new('Segoe UI', 8, [System.Drawing.FontStyle]::Bold); $week.Location = [System.Drawing.Point]::new(18, 94); $week.AutoSize = $true; $week.BackColor = $cardBackground; $week.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
    $sessionInfo = [System.Windows.Forms.Label]::new(); $sessionInfo.Location = [System.Drawing.Point]::new(18, 66); $sessionInfo.Size = [System.Drawing.Size]::new(135, 16); $sessionInfo.Font = [System.Drawing.Font]::new('Segoe UI', 8); $sessionInfo.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184); $sessionInfo.BackColor = $cardBackground
    $sessionReset = [System.Windows.Forms.Label]::new(); $sessionReset.Location = [System.Drawing.Point]::new(158, 66); $sessionReset.Size = [System.Drawing.Size]::new(142, 16); $sessionReset.Font = [System.Drawing.Font]::new('Segoe UI', 8); $sessionReset.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184); $sessionReset.BackColor = $cardBackground; $sessionReset.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $weekInfo = [System.Windows.Forms.Label]::new(); $weekInfo.Location = [System.Drawing.Point]::new(18, 118); $weekInfo.Size = [System.Drawing.Size]::new(135, 16); $weekInfo.Font = [System.Drawing.Font]::new('Segoe UI', 8); $weekInfo.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184); $weekInfo.BackColor = $cardBackground
    $weekReset = [System.Windows.Forms.Label]::new(); $weekReset.Location = [System.Drawing.Point]::new(158, 118); $weekReset.Size = [System.Drawing.Size]::new(142, 16); $weekReset.Font = [System.Drawing.Font]::new('Segoe UI', 8); $weekReset.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184); $weekReset.BackColor = $cardBackground; $weekReset.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    foreach ($control in @($titleLabel, $session, $week, $sessionInfo, $sessionReset, $weekInfo, $weekReset)) { $panel.Controls.Add($control) }
    $panel.Add_Paint({
        param($sender, $e)
        $e.Graphics.Clear([System.Drawing.Color]::FromArgb(11, 18, 32))
        $card = [System.Drawing.Rectangle]::new(4, 4, $sender.Width - 8, $sender.Height - 8)
        Draw-RoundedRectangle $e.Graphics ([System.Drawing.Color]::FromArgb(23, 33, 52)) $card 16
        foreach ($gauge in @(@{ Y = 54; Data = $sender.Tag.five }, @{ Y = 106; Data = $sender.Tag.seven })) {
            $track = [System.Drawing.Rectangle]::new(18, $gauge.Y, $sender.Width - 36, 8)
            Draw-RoundedRectangle $e.Graphics ([System.Drawing.Color]::FromArgb(51, 65, 85)) $track 5
            if ($gauge.Data) {
                $width = [Math]::Round($track.Width * [Math]::Min(100, [Math]::Max(0, [double]$gauge.Data.Percent)) / 100)
                if ($width -gt 0) {
                    Draw-RoundedRectangle $e.Graphics $gauge.Data.Color ([System.Drawing.Rectangle]::new($track.X, $track.Y, $width, $track.Height)) 5
                }
            }
        }
    })
    return [pscustomobject]@{ Panel = $panel; SessionInfo = $sessionInfo; SessionReset = $sessionReset; WeekInfo = $weekInfo; WeekReset = $weekReset }
}

function Set-UsageCard($card, $result) {
    if ($result.error) {
        $card.SessionInfo.Text = 'Unavailable'; $card.SessionReset.Text = $result.error
        $card.WeekInfo.Text = 'Unavailable'; $card.WeekReset.Text = $result.error
        $card.Panel.Tag = [pscustomobject]@{ five = $null; seven = $null }; $card.Panel.Invalidate(); return
    }
    $fivePercent = Get-UsagePercent $result.five; $sevenPercent = Get-UsagePercent $result.seven
    $card.SessionInfo.Text = "$(100 - $fivePercent)% remaining"; $card.SessionReset.Text = Get-ResetText $result.five
    $card.WeekInfo.Text = "$(100 - $sevenPercent)% remaining"; $card.WeekReset.Text = Get-ResetText $result.seven -Weekly
    $card.Panel.Tag = [pscustomobject]@{
        five = [pscustomobject]@{ Percent = $fivePercent; Color = Get-GaugeColor $fivePercent }
        seven = [pscustomobject]@{ Percent = $sevenPercent; Color = Get-GaugeColor $sevenPercent }
    }
    $card.Panel.Invalidate()
}

[System.Windows.Forms.Application]::EnableVisualStyles()
if (-not $script:settings -or $Setup) { Show-ProviderSetup }
$codexCard = New-UsageCard 'CODEX'
$claudeCard = New-UsageCard 'CLAUDE'
$background = [System.Drawing.Color]::FromArgb(11, 18, 32)
$surface = [System.Drawing.Color]::FromArgb(30, 41, 59)
$text = [System.Drawing.Color]::FromArgb(226, 232, 240)
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="350" Height="420" WindowStyle="None" AllowsTransparency="True" Background="Transparent" ShowInTaskbar="False" Topmost="True" ResizeMode="NoResize">
  <Border x:Name="Shell" Background="#0B1220" CornerRadius="20" Padding="12">
    <StackPanel>
      <Border x:Name="CodexCard" Background="#172134" CornerRadius="16" Padding="16" Margin="0,0,0,10">
        <StackPanel><TextBlock Text="CODEX" Foreground="#E2E8F0" FontWeight="Bold" FontSize="12"/><TextBlock Text="5h session" Foreground="#CBD5E1" FontWeight="SemiBold" FontSize="11" Margin="0,14,0,5"/><Border Background="#334155" Height="8" CornerRadius="4"><Border x:Name="Codex5Fill" Background="#22C55E" Width="0" HorizontalAlignment="Left" CornerRadius="4"/></Border><Grid Margin="0,5,0,0"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions><TextBlock x:Name="Codex5Info" Foreground="#94A3B8" FontSize="11"/><TextBlock x:Name="Codex5Reset" Grid.Column="1" Foreground="#94A3B8" FontSize="11" HorizontalAlignment="Right"/></Grid><TextBlock Text="7d weekly" Foreground="#CBD5E1" FontWeight="SemiBold" FontSize="11" Margin="0,17,0,5"/><Border Background="#334155" Height="8" CornerRadius="4"><Border x:Name="Codex7Fill" Background="#22C55E" Width="0" HorizontalAlignment="Left" CornerRadius="4"/></Border><Grid Margin="0,5,0,0"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions><TextBlock x:Name="Codex7Info" Foreground="#94A3B8" FontSize="11"/><TextBlock x:Name="Codex7Reset" Grid.Column="1" Foreground="#94A3B8" FontSize="11" HorizontalAlignment="Right"/></Grid></StackPanel>
      </Border>
      <Border x:Name="ClaudeCard" Background="#172134" CornerRadius="16" Padding="16" Margin="0,0,0,10">
        <StackPanel><TextBlock Text="CLAUDE" Foreground="#E2E8F0" FontWeight="Bold" FontSize="12"/><TextBlock Text="5h session" Foreground="#CBD5E1" FontWeight="SemiBold" FontSize="11" Margin="0,14,0,5"/><Border Background="#334155" Height="8" CornerRadius="4"><Border x:Name="Claude5Fill" Background="#22C55E" Width="0" HorizontalAlignment="Left" CornerRadius="4"/></Border><Grid Margin="0,5,0,0"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions><TextBlock x:Name="Claude5Info" Foreground="#94A3B8" FontSize="11"/><TextBlock x:Name="Claude5Reset" Grid.Column="1" Foreground="#94A3B8" FontSize="11" HorizontalAlignment="Right"/></Grid><TextBlock Text="7d weekly" Foreground="#CBD5E1" FontWeight="SemiBold" FontSize="11" Margin="0,17,0,5"/><Border Background="#334155" Height="8" CornerRadius="4"><Border x:Name="Claude7Fill" Background="#22C55E" Width="0" HorizontalAlignment="Left" CornerRadius="4"/></Border><Grid Margin="0,5,0,0"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions><TextBlock x:Name="Claude7Info" Foreground="#94A3B8" FontSize="11"/><TextBlock x:Name="Claude7Reset" Grid.Column="1" Foreground="#94A3B8" FontSize="11" HorizontalAlignment="Right"/></Grid></StackPanel>
      </Border>
      <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="8"/><ColumnDefinition/><ColumnDefinition Width="8"/><ColumnDefinition/></Grid.ColumnDefinitions><Border Background="#1E293B" CornerRadius="10"><Button x:Name="BadgeToggle" Content="Hide badge" Background="Transparent" Foreground="#E2E8F0" BorderThickness="0" Height="30" FontSize="10"/></Border><Border Grid.Column="2" Background="#1E293B" CornerRadius="10"><Button x:Name="Configure" Content="Configure" Background="Transparent" Foreground="#E2E8F0" BorderThickness="0" Height="30" FontSize="10"/></Border><Border Grid.Column="4" Background="#1E293B" CornerRadius="10"><Button x:Name="Exit" Content="Exit" Background="Transparent" Foreground="#E2E8F0" BorderThickness="0" Height="30" FontSize="10"/></Border></Grid>
    </StackPanel>
  </Border>
</Window>
'@
$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
$dashboard = [Windows.Markup.XamlReader]::Load($reader)
$configure = $dashboard.FindName('Configure'); $exit = $dashboard.FindName('Exit'); $badgeToggle = $dashboard.FindName('BadgeToggle')

$badgeXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="230" Height="54" WindowStyle="None" AllowsTransparency="True" Background="Transparent" ShowInTaskbar="False" Topmost="True" ResizeMode="NoResize">
  <Border x:Name="BadgeSurface" Background="#172134" BorderBrush="#334155" BorderThickness="1" CornerRadius="14" Padding="11,7">
    <Grid><StackPanel VerticalAlignment="Center" Margin="0,0,18,0"><Grid x:Name="BadgeCodexRow"><Grid.ColumnDefinitions><ColumnDefinition Width="55"/><ColumnDefinition Width="45"/><ColumnDefinition Width="12"/><ColumnDefinition Width="14"/><ColumnDefinition Width="45"/><ColumnDefinition Width="12"/></Grid.ColumnDefinitions><TextBlock Text="CODEX" Foreground="#CBD5E1" FontFamily="Segoe UI" FontSize="10"/><TextBlock x:Name="BadgeCodex5" Grid.Column="1" Foreground="#CBD5E1" FontFamily="Segoe UI" FontSize="10"/><Ellipse x:Name="BadgeCodex5Dot" Grid.Column="2" Width="7" Height="7" Fill="#22C55E" VerticalAlignment="Center"/><TextBlock x:Name="BadgeCodex7" Grid.Column="4" Foreground="#CBD5E1" FontFamily="Segoe UI" FontSize="10"/><Ellipse x:Name="BadgeCodex7Dot" Grid.Column="5" Width="7" Height="7" Fill="#22C55E" VerticalAlignment="Center"/></Grid><Border Height="1" Background="#475569" Margin="0,4,0,4"/><Grid x:Name="BadgeClaudeRow"><Grid.ColumnDefinitions><ColumnDefinition Width="55"/><ColumnDefinition Width="45"/><ColumnDefinition Width="12"/><ColumnDefinition Width="14"/><ColumnDefinition Width="45"/><ColumnDefinition Width="12"/></Grid.ColumnDefinitions><TextBlock Text="CLAUDE" Foreground="#CBD5E1" FontFamily="Segoe UI" FontSize="10"/><TextBlock x:Name="BadgeClaude5" Grid.Column="1" Foreground="#CBD5E1" FontFamily="Segoe UI" FontSize="10"/><Ellipse x:Name="BadgeClaude5Dot" Grid.Column="2" Width="7" Height="7" Fill="#22C55E" VerticalAlignment="Center"/><TextBlock x:Name="BadgeClaude7" Grid.Column="4" Foreground="#CBD5E1" FontFamily="Segoe UI" FontSize="10"/><Ellipse x:Name="BadgeClaude7Dot" Grid.Column="5" Width="7" Height="7" Fill="#22C55E" VerticalAlignment="Center"/></Grid></StackPanel><Button x:Name="BadgeClose" Content="X" HorizontalAlignment="Right" VerticalAlignment="Top" Width="15" Height="15" Padding="0" Background="Transparent" Foreground="#94A3B8" BorderThickness="0" FontFamily="Segoe UI" FontWeight="Bold" FontSize="9"/></Grid>
  </Border>
</Window>
'@
$badgeReader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($badgeXaml))
$usageBadge = [Windows.Markup.XamlReader]::Load($badgeReader)
$badgeClose = $usageBadge.FindName('BadgeClose')

$tray = [System.Windows.Forms.NotifyIcon]::new()
$tray.Icon = New-DashboardTrayIcon
$tray.Text = 'AI Usage Dashboard'
$tray.Visible = $true

function Set-WpfUsageCard($provider, $result) {
    $fiveInfo = $dashboard.FindName("${provider}5Info"); $fiveReset = $dashboard.FindName("${provider}5Reset"); $fiveFill = $dashboard.FindName("${provider}5Fill")
    $sevenInfo = $dashboard.FindName("${provider}7Info"); $sevenReset = $dashboard.FindName("${provider}7Reset"); $sevenFill = $dashboard.FindName("${provider}7Fill")
    if ($result.error) {
        $fiveInfo.Text = 'Unavailable'; $fiveReset.Text = $result.error; $sevenInfo.Text = 'Unavailable'; $sevenReset.Text = $result.error
        $fiveFill.Width = 0; $sevenFill.Width = 0; return
    }
    $fivePercent = Get-UsagePercent $result.five; $sevenPercent = Get-UsagePercent $result.seven
    $fiveInfo.Text = "$(100 - $fivePercent)% remaining"; $fiveReset.Text = Get-ResetText $result.five
    $sevenInfo.Text = "$(100 - $sevenPercent)% remaining"; $sevenReset.Text = Get-ResetText $result.seven -Weekly
    $fiveFill.Width = [Math]::Round(286 * $fivePercent / 100); $sevenFill.Width = [Math]::Round(286 * $sevenPercent / 100)
    $converter = [System.Windows.Media.BrushConverter]::new()
    $fiveFill.Background = $converter.ConvertFromString(('#{0:X2}{1:X2}{2:X2}' -f (Get-GaugeColor $fivePercent).R, (Get-GaugeColor $fivePercent).G, (Get-GaugeColor $fivePercent).B))
    $sevenFill.Background = $converter.ConvertFromString(('#{0:X2}{1:X2}{2:X2}' -f (Get-GaugeColor $sevenPercent).R, (Get-GaugeColor $sevenPercent).G, (Get-GaugeColor $sevenPercent).B))
}

function Set-BadgeMetric($label, $dot, $text, $percent) {
    $label.Text = $text
    $color = Get-GaugeColor $percent
    $dot.Fill = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb($color.R, $color.G, $color.B))
}

function Save-BadgePosition {
    if (-not $script:settings) { return }
    $script:settings | Add-Member -NotePropertyName badgeLeft -NotePropertyValue ([Math]::Round($usageBadge.Left)) -Force
    $script:settings | Add-Member -NotePropertyName badgeTop -NotePropertyValue ([Math]::Round($usageBadge.Top)) -Force
    $script:settings | ConvertTo-Json | Set-Content -LiteralPath $script:settingsFile -Encoding UTF8
}

function Set-BadgeEnabled($enabled) {
    $script:settings | Add-Member -NotePropertyName showBadge -NotePropertyValue ([bool]$enabled) -Force
    $script:settings | ConvertTo-Json | Set-Content -LiteralPath $script:settingsFile -Encoding UTF8
    $badgeToggle.Content = if ($enabled) { 'Hide badge' } else { 'Show badge' }
    if ($enabled) { Update-UsageMenu } else { $usageBadge.Hide() }
}

function Set-TrayUsageDisplay($percent, $tooltip, $codexFive, $codexSeven, $claudeFive, $claudeSeven) {
    $oldIcon = $script:trayIcon; $oldBitmap = $script:trayBitmap
    $tray.Icon = New-DashboardTrayIcon $percent
    $tray.Text = if ($tooltip.Length -le 63) { $tooltip } else { $tooltip.Substring(0, 63) }
    if ($oldIcon) { $oldIcon.Dispose() }
    if ($oldBitmap) { $oldBitmap.Dispose() }
    $color = Get-GaugeColor $percent
    $codexRow = $usageBadge.FindName('BadgeCodexRow'); $claudeRow = $usageBadge.FindName('BadgeClaudeRow')
    $codexRow.Visibility = if ($null -ne $codexFive) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    $claudeRow.Visibility = if ($null -ne $claudeFive) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    if ($null -ne $codexFive) { Set-BadgeMetric ($usageBadge.FindName('BadgeCodex5')) ($usageBadge.FindName('BadgeCodex5Dot')) "5h $codexFive%" $codexFive; Set-BadgeMetric ($usageBadge.FindName('BadgeCodex7')) ($usageBadge.FindName('BadgeCodex7Dot')) "7d $codexSeven%" $codexSeven }
    if ($null -ne $claudeFive) { Set-BadgeMetric ($usageBadge.FindName('BadgeClaude5')) ($usageBadge.FindName('BadgeClaude5Dot')) "5h $claudeFive%" $claudeFive; Set-BadgeMetric ($usageBadge.FindName('BadgeClaude7')) ($usageBadge.FindName('BadgeClaude7Dot')) "7d $claudeSeven%" $claudeSeven }
    $workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $usageBadge.Left = if ($script:settings.badgeLeft -ne $null) { [double]$script:settings.badgeLeft } else { $workArea.Right - $usageBadge.Width - 10 }
    $usageBadge.Top = if ($script:settings.badgeTop -ne $null) { [double]$script:settings.badgeTop } else { $workArea.Bottom - $usageBadge.Height - 8 }
    $badgeToggle.Content = if ($script:settings.showBadge -eq $false) { 'Show badge' } else { 'Hide badge' }
    if ($script:settings.showBadge -ne $false -and -not $usageBadge.IsVisible) { $usageBadge.Show() }
}

function Update-UsageMenu {
    $percentages = @(); $tooltipParts = @(); $codexFive = $null; $codexSeven = $null; $claudeFive = $null; $claudeSeven = $null
    if ($script:settings.showCodex) {
        $result = Get-Usage 'Codex'; Set-WpfUsageCard 'Codex' $result
        if (-not $result.error) { $five = Get-UsagePercent $result.five; $seven = Get-UsagePercent $result.seven; $percentages += $five, $seven; $tooltipParts += "Codex 5h:$five% 7d:$seven%"; $codexFive = $five; $codexSeven = $seven }
    }
    if ($script:settings.showClaude) {
        $result = Get-Usage 'Claude'; Set-WpfUsageCard 'Claude' $result
        if (-not $result.error) { $five = Get-UsagePercent $result.five; $seven = Get-UsagePercent $result.seven; $percentages += $five, $seven; $tooltipParts += "Claude 5h:$five% 7d:$seven%"; $claudeFive = $five; $claudeSeven = $seven }
    }
    $highest = if ($percentages.Count) { ($percentages | Measure-Object -Maximum).Maximum } else { 0 }
    $tooltip = if ($tooltipParts.Count) { 'AI Usage - ' + ($tooltipParts -join ' | ') } else { 'AI Usage Dashboard - no usage data' }
    Set-TrayUsageDisplay $highest $tooltip $codexFive $codexSeven $claudeFive $claudeSeven
}

function Apply-ProviderSelection {
    $dashboard.FindName('CodexCard').Visibility = if ($script:settings.showCodex) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    $dashboard.FindName('ClaudeCard').Visibility = if ($script:settings.showClaude) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
}

$configure.Add_Click({ $dashboard.Hide(); Show-ProviderSetup; Apply-ProviderSelection; Update-UsageMenu })
$badgeToggle.Add_Click({ Set-BadgeEnabled ($script:settings.showBadge -eq $false) })
$badgeClose.Add_Click({ Set-BadgeEnabled $false })
$exit.Add_Click({
    $timer.Stop()
    $usageBadge.Close()
    $dashboard.Close()
    $tray.Visible = $false
    $tray.Dispose()
    $script:trayIcon.Dispose()
    $script:trayBitmap.Dispose()
    [System.Windows.Forms.Application]::ExitThread()
})
function Show-DashboardPopup {
    if ($dashboard.IsVisible) { $dashboard.Hide(); return }
    Update-UsageMenu
    Apply-ProviderSelection
    $position = [System.Windows.Forms.Cursor]::Position
    $workArea = [System.Windows.Forms.Screen]::FromPoint($position).WorkingArea
    $x = [Math]::Min($position.X - $dashboard.Width + 10, $workArea.Right - $dashboard.Width - 4)
    $y = [Math]::Min($position.Y - $dashboard.Height - 8, $workArea.Bottom - $dashboard.Height - 4)
    $dashboard.Left = [Math]::Max($workArea.Left + 4, $x); $dashboard.Top = [Math]::Max($workArea.Top + 4, $y)
    $dashboard.Show(); $dashboard.Activate()
}
$dashboard.Add_KeyDown({ param($sender, $event) if ($event.Key -eq [System.Windows.Input.Key]::Escape) { $sender.Hide() } })
$dashboard.Add_Deactivated({ $dashboard.Hide() })
$usageBadge.Add_MouseLeftButtonDown({ $usageBadge.DragMove(); Save-BadgePosition })
$usageBadge.Add_MouseRightButtonUp({ Show-DashboardPopup })
$tray.Add_MouseUp({ param($sender, $event) if ($event.Button -eq [System.Windows.Forms.MouseButtons]::Right) { Show-DashboardPopup } })
$timer = [System.Windows.Forms.Timer]::new()
$timer.Interval = $script:pollSeconds * 1000
$timer.Add_Tick({ Update-UsageMenu })
$timer.Start()
Apply-ProviderSelection
Update-UsageMenu
[System.Windows.Forms.Application]::Run()
