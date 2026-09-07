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
Add-Type -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing') -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class UsageTaskbarNative
{
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern IntPtr FindWindow(string className, string windowName);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr childAfter, string className, string windowName);
    [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetParent(IntPtr child, IntPtr newParent);
    [DllImport("user32.dll", SetLastError = true)] public static extern int GetWindowLong(IntPtr window, int index);
    [DllImport("user32.dll", SetLastError = true)] public static extern int SetWindowLong(IntPtr window, int index, int style);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool GetWindowRect(IntPtr window, out RECT rectangle);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool MoveWindow(IntPtr window, int x, int y, int width, int height, bool repaint);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr", SetLastError = true)] static extern IntPtr SetWindowLongPtr64(IntPtr window, int index, IntPtr value);
    [DllImport("user32.dll", EntryPoint = "SetWindowLong", SetLastError = true)] static extern IntPtr SetWindowLongPtr32(IntPtr window, int index, IntPtr value);
    public static IntPtr SetWindowOwner(IntPtr window, IntPtr owner) { return IntPtr.Size == 8 ? SetWindowLongPtr64(window, -8, owner) : SetWindowLongPtr32(window, -8, owner); }
}

public sealed class UsageTaskbarLayer : Form
{
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct SIZE { public int Width, Height; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)] struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr window);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr window, IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr value);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr value);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("user32.dll", SetLastError = true)] static extern bool UpdateLayeredWindow(IntPtr window, IntPtr destinationDc, ref POINT destination, ref SIZE size, IntPtr sourceDc, ref POINT source, int colorKey, ref BLENDFUNCTION blend, int flags);
    protected override CreateParams CreateParams { get { var p = base.CreateParams; p.ExStyle |= 0x00080000 | 0x00000080; return p; } }
    public void SetBitmap(Bitmap bitmap, int x, int y) {
        IntPtr screen = GetDC(IntPtr.Zero), memory = CreateCompatibleDC(screen), handle = bitmap.GetHbitmap(Color.FromArgb(0)), old = SelectObject(memory, handle);
        try { var dest = new POINT { X=x, Y=y }; var source = new POINT(); var size = new SIZE { Width=bitmap.Width, Height=bitmap.Height }; var blend = new BLENDFUNCTION { BlendOp=0, SourceConstantAlpha=255, AlphaFormat=1 }; if (!UpdateLayeredWindow(Handle, screen, ref dest, ref size, memory, ref source, 0, ref blend, 2)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()); }
        finally { SelectObject(memory, old); DeleteObject(handle); DeleteDC(memory); ReleaseDC(IntPtr.Zero, screen); }
    }
}
'@

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

function Test-AppLightTheme {
    return ($script:settings -and $script:settings.displayTheme -eq 'light')
}

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

function Get-ClaudeOAuth($userRoot) {
    $credentialPath = Join-Path $userRoot '.claude\.credentials.json'
    $credential = Get-JsonFile $credentialPath
    $oauth = $credential.claudeAiOauth
    if (-not $oauth.accessToken) { return @{ error = Get-ProviderSetupMessage 'Claude' } }

    # Claude Code OAuth access tokens are short-lived. Refresh before use when expired or nearly expired.
    $expiresAt = if ($oauth.expiresAt) { [int64]$oauth.expiresAt } else { 0 }
    if ($expiresAt -gt 0 -and $expiresAt -le ([DateTimeOffset]::Now.ToUnixTimeMilliseconds() + 120000)) {
        if (-not $oauth.refreshToken) { return @{ error = 'Claude session expired. Run claude auth login.' } }
        $body = @{ grant_type = 'refresh_token'; refresh_token = $oauth.refreshToken; client_id = '9d1c250a-e61b-44d9-88ed-5944d1962f5e' } | ConvertTo-Json -Compress
        $refreshError = $null; $refreshed = $null
        foreach ($endpoint in @('https://platform.claude.com/v1/oauth/token', 'https://console.anthropic.com/v1/oauth/token')) {
            try {
                $refreshed = Invoke-RestMethod -Method Post -Uri $endpoint -ContentType 'application/json' -Headers @{ Accept = 'application/json'; 'User-Agent' = 'ai-usage-dashboard-local' } -Body $body -TimeoutSec 15
                if ($refreshed.access_token) { break }
            } catch { $refreshError = $_.Exception.Message }
        }
        if (-not $refreshed.access_token) { return @{ error = "Claude session refresh failed: $refreshError" } }
        $oauth.accessToken = $refreshed.access_token
        if ($refreshed.refresh_token) { $oauth.refreshToken = $refreshed.refresh_token }
        if ($refreshed.expires_in) { $oauth.expiresAt = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() + ([int64]$refreshed.expires_in * 1000) }
        elseif ($refreshed.expires_at) { $oauth.expiresAt = [int64]$refreshed.expires_at }
        $credential.claudeAiOauth = $oauth
        $credential | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $credentialPath -Encoding UTF8
    }
    return $oauth
}

function Save-ProviderSettings($codexEnabled, $claudeEnabled) {
    New-Item -ItemType Directory -Force -Path $script:settingsDir | Out-Null
    [pscustomobject]@{ showCodex = [bool]$codexEnabled; showClaude = [bool]$claudeEnabled; showTaskbarWidget = if ($script:settings.showTaskbarWidget -ne $null) { [bool]$script:settings.showTaskbarWidget } else { $true }; displayTheme = if (Test-AppLightTheme) { 'light' } else { 'dark' } } | ConvertTo-Json | Set-Content -LiteralPath $script:settingsFile -Encoding UTF8
    $script:settings = Get-JsonFile $script:settingsFile
}

function Show-ProviderSetup {
    $form = [System.Windows.Forms.Form]::new()
    $background = [System.Drawing.Color]::FromArgb(15, 23, 42)
    $surface = [System.Drawing.Color]::FromArgb(24, 35, 56)
    $text = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $muted = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $form.Text = 'AI 사용량 대시보드 - 설정'; $form.Size = [System.Drawing.Size]::new(390, 270); $form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'None'; $form.MaximizeBox = $false; $form.MinimizeBox = $false; $form.BackColor = $background; $form.Padding = [System.Windows.Forms.Padding]::new(18)
    $form.Add_Shown({ Set-RoundedControlRegion $form 22 })
    $form.Add_SizeChanged({ Set-RoundedControlRegion $form 22 })
    $header = [System.Windows.Forms.Label]::new(); $header.Text = 'AI 사용량 대시보드'; $header.Font = [System.Drawing.Font]::new('Segoe UI', 13, [System.Drawing.FontStyle]::Bold); $header.ForeColor = $text; $header.BackColor = $background; $header.Location = [System.Drawing.Point]::new(24, 23); $header.Size = [System.Drawing.Size]::new(250, 28)
    $intro = [System.Windows.Forms.Label]::new(); $intro.Text = '작업표시줄에 표시할 서비스를 선택하세요.'; $intro.ForeColor = $muted; $intro.BackColor = $background; $intro.Location = [System.Drawing.Point]::new(24, 54); $intro.Size = [System.Drawing.Size]::new(320, 24)
    $content = [System.Windows.Forms.Panel]::new(); $content.BackColor = $surface; $content.Location = [System.Drawing.Point]::new(18, 87); $content.Size = [System.Drawing.Size]::new(354, 105)
    Set-RoundedControlRegion $content 16
    $codexBox = [System.Windows.Forms.CheckBox]::new(); $codexBox.Text = 'Codex'; $codexBox.Location = [System.Drawing.Point]::new(16, 15); $codexBox.AutoSize = $true; $codexBox.ForeColor = $text; $codexBox.BackColor = $surface; $codexBox.Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $claudeBox = [System.Windows.Forms.CheckBox]::new(); $claudeBox.Text = 'Claude'; $claudeBox.Location = [System.Drawing.Point]::new(16, 57); $claudeBox.AutoSize = $true; $claudeBox.ForeColor = $text; $claudeBox.BackColor = $surface; $claudeBox.Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $codexBox.Checked = if ($script:settings) { [bool]$script:settings.showCodex } else { Test-ProviderLogin 'Codex' }
    $claudeBox.Checked = if ($script:settings) { [bool]$script:settings.showClaude } else { Test-ProviderLogin 'Claude' }
    $codexStatus = [System.Windows.Forms.Label]::new(); $codexStatus.Text = if (Test-ProviderLogin 'Codex') { '로그인됨' } else { '로그인 필요 - codex login 실행' }; $codexStatus.Location = [System.Drawing.Point]::new(112, 16); $codexStatus.Size = [System.Drawing.Size]::new(220, 20); $codexStatus.ForeColor = if (Test-ProviderLogin 'Codex') { [System.Drawing.Color]::FromArgb(74, 222, 128) } else { [System.Drawing.Color]::FromArgb(251, 191, 36) }; $codexStatus.BackColor = $surface
    $claudeStatus = [System.Windows.Forms.Label]::new(); $claudeStatus.Text = if (Test-ProviderLogin 'Claude') { '로그인됨' } else { '로그인 필요 - Claude Code에서 로그인' }; $claudeStatus.Location = [System.Drawing.Point]::new(112, 58); $claudeStatus.Size = [System.Drawing.Size]::new(220, 20); $claudeStatus.ForeColor = if (Test-ProviderLogin 'Claude') { [System.Drawing.Color]::FromArgb(74, 222, 128) } else { [System.Drawing.Color]::FromArgb(251, 191, 36) }; $claudeStatus.BackColor = $surface
    $hint = [System.Windows.Forms.Label]::new(); $hint.Text = '나중에 대시보드의 설정 버튼에서 다시 변경할 수 있습니다.'; $hint.Location = [System.Drawing.Point]::new(24, 201); $hint.Size = [System.Drawing.Size]::new(340, 20); $hint.ForeColor = $muted; $hint.BackColor = $background
    $save = [System.Windows.Forms.Button]::new(); $save.Text = '저장'; $save.Location = [System.Drawing.Point]::new(204, 229); $save.Size = [System.Drawing.Size]::new(78, 28); $save.FlatStyle = 'Flat'; $save.FlatAppearance.BorderSize = 0; $save.BackColor = [System.Drawing.Color]::FromArgb(45, 212, 191); $save.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
    $cancel = [System.Windows.Forms.Button]::new(); $cancel.Text = '취소'; $cancel.Location = [System.Drawing.Point]::new(290, 229); $cancel.Size = [System.Drawing.Size]::new(78, 28); $cancel.FlatStyle = 'Flat'; $cancel.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(71, 85, 105); $cancel.BackColor = $surface; $cancel.ForeColor = $text
    foreach ($control in @($codexBox, $claudeBox, $codexStatus, $claudeStatus)) { $content.Controls.Add($control) }
    foreach ($control in @($header, $intro, $content, $hint, $save, $cancel)) { $form.Controls.Add($control) }
    Set-RoundedControlRegion $save 10; Set-RoundedControlRegion $cancel 10
    $save.Add_Click({ Save-ProviderSettings $codexBox.Checked $claudeBox.Checked; $form.DialogResult = [System.Windows.Forms.DialogResult]::OK; $form.Close() })
    $cancel.Add_Click({ $form.Close() })
    $null = $form.ShowDialog()
    if (-not $script:settings) { Save-ProviderSettings $codexBox.Checked $claudeBox.Checked }
}

function Get-RetryDelaySeconds($errorRecord) {
    $statusCode = $null; $retryAfter = $null
    try {
        $response = $errorRecord.Exception.Response
        if ($response) {
            $statusCode = [int]$response.StatusCode
            try { $retryAfter = $response.Headers['Retry-After'] } catch { }
            if (-not $retryAfter) {
                try {
                    if ($response.Headers.RetryAfter.Delta) { $retryAfter = [Math]::Ceiling($response.Headers.RetryAfter.Delta.TotalSeconds) }
                    elseif ($response.Headers.RetryAfter.Date) { $retryAfter = [Math]::Ceiling(($response.Headers.RetryAfter.Date.LocalDateTime - (Get-Date)).TotalSeconds) }
                } catch { }
            }
        }
    } catch { }
    $seconds = 0
    if ($retryAfter) {
        if (-not [int]::TryParse([string]$retryAfter, [ref]$seconds)) {
            $retryAt = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse([string]$retryAfter, [ref]$retryAt)) { $seconds = [Math]::Ceiling(($retryAt.LocalDateTime - (Get-Date)).TotalSeconds) }
        }
    }
    # Never retry faster than the dashboard's five-minute poll interval.
    # A longer server-provided Retry-After value extends that delay.
    if ($seconds -gt 0) { return [Math]::Max($script:pollSeconds, [Math]::Min(86400, $seconds)) }
    return $script:pollSeconds
}

function Get-Usage($provider) {
    $now = Get-Date
    $cached = $script:usageCache[$provider]
    if ($cached) {
        if ($cached.nextRetryAt -and $now -lt $cached.nextRetryAt) {
            if ($cached.value) { return $cached.value }
            return @{ error = $cached.error }
        }
        if ($cached.value -and $cached.fetchedAt -and (($now - $cached.fetchedAt).TotalSeconds -lt $script:pollSeconds)) {
            return $cached.value
        }
    }
    if ($provider -eq 'Claude') {
        $auth = Get-ClaudeOAuth $UserDataRoot
        if ($auth.error) { return @{ error = $auth.error } }
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
        $script:usageCache[$provider] = @{ value = $result; fetchedAt = $now; nextRetryAt = $null; error = $null }
        return $result
    } catch {
        # Retain the last successful value, but also suppress further HTTP calls
        # until the server's Retry-After period (or a conservative fallback) ends.
        $message = "request failed: $($_.Exception.Message)"
        $retryAt = $now.AddSeconds((Get-RetryDelaySeconds $_))
        if ($cached) {
            $cached.nextRetryAt = $retryAt; $cached.error = $message
            $script:usageCache[$provider] = $cached
            if ($cached.value) { return $cached.value }
        } else {
            $script:usageCache[$provider] = @{ value = $null; fetchedAt = $null; nextRetryAt = $retryAt; error = $message }
        }
        return @{ error = $message }
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
        if ($data.reset_at) { return "초기화 " + [DateTimeOffset]::FromUnixTimeSeconds([int64]$data.reset_at).ToLocalTime().ToString($format) }
    } elseif ($data.resets_at) {
        return "초기화 " + ([datetime]$data.resets_at).ToLocalTime().ToString($format)
    }
    return '초기화 시간 정보 없음'
}

function Get-GaugeColor($percent) {
    if ($percent -ge 80) { return [System.Drawing.Color]::FromArgb(220, 38, 38) }
    if ($percent -ge 60) { return [System.Drawing.Color]::FromArgb(217, 119, 6) }
    return [System.Drawing.Color]::FromArgb(34, 197, 94)
}

function Test-TaskbarWidgetEnabled {
    return (-not $script:settings -or $script:settings.showTaskbarWidget -ne $false)
}

function Get-TaskbarWidgetWidth {
    $count = [int][bool]$script:settings.showCodex + [int][bool]$script:settings.showClaude
    if ($count -le 0) { return 0 }
    if ($count -eq 1) { return 166 }
    return 344
}

function Draw-ProviderIcon($graphics, $provider, $x, $y, $size) {
    if (-not $script:providerLogoCache) { $script:providerLogoCache = @{} }
    if (-not $script:providerLogoCache.ContainsKey($provider)) {
        $fileName = if ($provider -eq 'CLAUDE') { 'claude.png' } else { 'chatgpt.png' }
        $filePath = Join-Path $PSScriptRoot (Join-Path 'assets' $fileName)
        if (Test-Path $filePath) {
            # Clone the image so the source file is not locked while the app is running.
            $source = [System.Drawing.Image]::FromFile($filePath)
            try {
                $logo = [System.Drawing.Bitmap]::new($source)
                if ($provider -eq 'CODEX') {
                    # Turn the black ChatGPT knot into a light alpha-only mark:
                    # white source pixels become transparent, so no white tile is drawn.
                    $foreground = if ($script:taskbarLightTheme) { [System.Drawing.Color]::FromArgb(15, 23, 42) } else { [System.Drawing.Color]::FromArgb(226, 232, 240) }
                    for ($pixelY = 0; $pixelY -lt $logo.Height; $pixelY++) {
                        for ($pixelX = 0; $pixelX -lt $logo.Width; $pixelX++) {
                            $pixel = $logo.GetPixel($pixelX, $pixelY)
                            $alpha = 255 - [int](($pixel.R + $pixel.G + $pixel.B) / 3)
                            if ($alpha -eq 0) { $logo.SetPixel($pixelX, $pixelY, [System.Drawing.Color]::Transparent) }
                            else { $logo.SetPixel($pixelX, $pixelY, [System.Drawing.Color]::FromArgb($alpha, $foreground.R, $foreground.G, $foreground.B)) }
                        }
                    }
                } else {
                    # Claude's actual flat app-icon background is beige, not the
                    # nearly transparent corner pixel. Remove the beige field.
                    $logo.MakeTransparent($logo.GetPixel(10, 10))
                }
                $script:providerLogoCache[$provider] = $logo
            } finally { $source.Dispose() }
        }
    }

    $icon = $script:providerLogoCache[$provider]
    if ($icon) {
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        if ($provider -eq 'CODEX') {
            # Remove the source image's generous padding while retaining the knot shape.
            $graphics.DrawImage($icon, [System.Drawing.Rectangle]::new($x, $y, $size, $size), 40, 40, 176, 176, [System.Drawing.GraphicsUnit]::Pixel)
        } else {
            $graphics.DrawImage($icon, [System.Drawing.Rectangle]::new($x, $y, $size, $size), 40, 40, 258, 258, [System.Drawing.GraphicsUnit]::Pixel)
        }
    }
}

function Draw-TaskbarMetric($graphics, $period, $percent, $y, $x, $font, $textBrush, $trackColor) {
    $graphics.DrawString("$period / " + $(if ($null -eq $percent) { '--' } else { "$percent%" }), $font, $textBrush, $x, $y)
    $gaugeColor = if ($null -eq $percent) { [System.Drawing.Color]::FromArgb(100, 116, 139) } else { Get-GaugeColor $percent }
    $track = [System.Drawing.Rectangle]::new($x + 65, $y + 6, 66, 6)
    Draw-RoundedRectangle $graphics $trackColor $track 3
    if ($null -ne $percent -and $percent -gt 0) {
        $fillWidth = [Math]::Max(1, [Math]::Round($track.Width * $percent / 100))
        Draw-RoundedRectangle $graphics $gaugeColor ([System.Drawing.Rectangle]::new($track.X, $track.Y, $fillWidth, $track.Height)) 3
    }
}

function Draw-TaskbarProviderColumn($graphics, $provider, $result, $x, $y) {
    $textColor = if ($script:taskbarLightTheme) { [System.Drawing.Color]::FromArgb(31, 41, 55) } else { [System.Drawing.Color]::FromArgb(241, 245, 249) }
    $valueFont = [System.Drawing.Font]::new('Segoe UI Semibold', 8)
    $valueBrush = [System.Drawing.SolidBrush]::new($textColor)
    $five = $null; $seven = $null
    if ($result -and -not $result.error) { $five = Get-UsagePercent $result.five; $seven = Get-UsagePercent $result.seven }
    $trackColor = if ($script:taskbarLightTheme) { [System.Drawing.Color]::FromArgb(190, 190, 190) } else { [System.Drawing.Color]::FromArgb(71, 85, 105) }
    Draw-ProviderIcon $graphics $provider $x ($y + 10) 17
    Draw-TaskbarMetric $graphics '5h' $five $y ($x + 24) $valueFont $valueBrush $trackColor
    Draw-TaskbarMetric $graphics '7d' $seven ($y + 20) ($x + 24) $valueFont $valueBrush $trackColor
    $valueBrush.Dispose(); $valueFont.Dispose()
}

function Update-TaskbarWidgetBitmap($x, $y, $width, $height) {
    $bitmap = [System.Drawing.Bitmap]::new($width, $height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::FromArgb(1, 0, 0, 0))
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        if ($script:settings.showClaude) { Draw-TaskbarProviderColumn $graphics 'CLAUDE' $script:lastClaudeResult 10 2 }
        if ($script:settings.showCodex) {
            $codexX = if ($script:settings.showClaude) { 178 } else { 10 }
            Draw-TaskbarProviderColumn $graphics 'CODEX' $script:lastCodexResult $codexX 2
        }
        $taskbarWidget.SetBitmap($bitmap, $x, $y)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}

function Set-TaskbarWidgetPosition {
    if (-not $taskbarWidget -or $taskbarWidget.IsDisposed) { return }
    if (-not (Test-TaskbarWidgetEnabled)) { $taskbarWidget.Hide(); return }
    $width = Get-TaskbarWidgetWidth
    if ($width -le 0) { $taskbarWidget.Hide(); return }
    $taskbar = [UsageTaskbarNative]::FindWindow('Shell_TrayWnd', $null)
    if ($taskbar -eq [IntPtr]::Zero) { $taskbarWidget.Hide(); return }
    $taskbarRect = [UsageTaskbarNative+RECT]::new()
    if (-not [UsageTaskbarNative]::GetWindowRect($taskbar, [ref]$taskbarRect)) { return }
    $trayArea = [UsageTaskbarNative]::FindWindowEx($taskbar, [IntPtr]::Zero, 'TrayNotifyWnd', $null)
    $rightEdge = $taskbarRect.Right - $taskbarRect.Left - 168
    if ($trayArea -ne [IntPtr]::Zero) { $trayRect = [UsageTaskbarNative+RECT]::new(); if ([UsageTaskbarNative]::GetWindowRect($trayArea, [ref]$trayRect)) { $rightEdge = $trayRect.Left - $taskbarRect.Left } }
    $height = [Math]::Min(44, [Math]::Max(38, $taskbarRect.Bottom - $taskbarRect.Top - 2))
    $x = $taskbarRect.Left + [Math]::Max(4, $rightEdge - $width - 5)
    $y = $taskbarRect.Top + [Math]::Floor((($taskbarRect.Bottom - $taskbarRect.Top) - $height) / 2)
    if ($script:taskbarOwner -ne $taskbar) {
        $style = [UsageTaskbarNative]::GetWindowLong($taskbarWidget.Handle, -16)
        $style = ($style -band (-bnot 0x40000000) -band (-bnot 0x04000000)) -bor (-2147483648)
        $null = [UsageTaskbarNative]::SetWindowLong($taskbarWidget.Handle, -16, [int]$style)
        $exStyle = [UsageTaskbarNative]::GetWindowLong($taskbarWidget.Handle, -20)
        $exStyle = $exStyle -band (-bnot 0x00000020) -band (-bnot 0x08000000) -bor 0x00000080 -bor 0x00000008
        $null = [UsageTaskbarNative]::SetWindowLong($taskbarWidget.Handle, -20, [int]$exStyle)
        $null = [UsageTaskbarNative]::SetParent($taskbarWidget.Handle, [IntPtr]::Zero)
        $null = [UsageTaskbarNative]::SetWindowOwner($taskbarWidget.Handle, $taskbar)
        $null = [UsageTaskbarNative]::SetWindowPos($taskbarWidget.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x0037)
        $script:taskbarOwner = $taskbar
    }
    $taskbarWidget.ClientSize = [System.Drawing.Size]::new($width, $height)
    if (-not $taskbarWidget.Visible) { $taskbarWidget.Show() }
    Update-TaskbarWidgetBitmap $x $y $width $height
    $null = [UsageTaskbarNative]::SetWindowPos($taskbarWidget.Handle, [IntPtr](-1), $x, $y, $width, $height, 0x0010)
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
    $session = [System.Windows.Forms.Label]::new(); $session.Text = '5시간 세션'; $session.Font = [System.Drawing.Font]::new('Segoe UI', 8, [System.Drawing.FontStyle]::Bold); $session.Location = [System.Drawing.Point]::new(18, 42); $session.AutoSize = $true; $session.BackColor = $cardBackground; $session.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
    $week = [System.Windows.Forms.Label]::new(); $week.Text = '7일 주간'; $week.Font = [System.Drawing.Font]::new('Segoe UI', 8, [System.Drawing.FontStyle]::Bold); $week.Location = [System.Drawing.Point]::new(18, 94); $week.AutoSize = $true; $week.BackColor = $cardBackground; $week.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
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
        $card.SessionInfo.Text = '불러올 수 없음'; $card.SessionReset.Text = $result.error
        $card.WeekInfo.Text = '불러올 수 없음'; $card.WeekReset.Text = $result.error
        $card.Panel.Tag = [pscustomobject]@{ five = $null; seven = $null }; $card.Panel.Invalidate(); return
    }
    $fivePercent = Get-UsagePercent $result.five; $sevenPercent = Get-UsagePercent $result.seven
    $card.SessionInfo.Text = "$(100 - $fivePercent)% 남음"; $card.SessionReset.Text = Get-ResetText $result.five
    $card.WeekInfo.Text = "$(100 - $sevenPercent)% 남음"; $card.WeekReset.Text = Get-ResetText $result.seven -Weekly
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
      <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="8"/><ColumnDefinition/><ColumnDefinition Width="8"/><ColumnDefinition/></Grid.ColumnDefinitions><Border Background="#1E293B" CornerRadius="10"><Button x:Name="WidgetToggle" Content="Hide widget" Background="Transparent" Foreground="#E2E8F0" BorderThickness="0" Height="30" FontSize="10"/></Border><Border Grid.Column="2" Background="#1E293B" CornerRadius="10"><Button x:Name="Configure" Content="Configure" Background="Transparent" Foreground="#E2E8F0" BorderThickness="0" Height="30" FontSize="10"/></Border><Border Grid.Column="4" Background="#1E293B" CornerRadius="10"><Button x:Name="Exit" Content="Exit" Background="Transparent" Foreground="#E2E8F0" BorderThickness="0" Height="30" FontSize="10"/></Border></Grid>
    </StackPanel>
  </Border>
</Window>
'@
$xaml = $xaml.Replace('5h session', '5시간 세션').Replace('7d weekly', '7일 주간').Replace('Hide widget', '위젯 숨기기').Replace('Show widget', '위젯 보이기').Replace('Content="Configure"', 'Content="설정"').Replace('Content="Exit"', 'Content="종료"')
$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
$dashboard = [Windows.Markup.XamlReader]::Load($reader)
$configure = $dashboard.FindName('Configure'); $exit = $dashboard.FindName('Exit'); $widgetToggle = $dashboard.FindName('WidgetToggle')
$buttonGrid = [System.Windows.Controls.Grid]$widgetToggle.Parent.Parent
$buttonGrid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new())
$buttonGrid.ColumnDefinitions[5].Width = [System.Windows.GridLength]::new(8)
$buttonGrid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new())
$themeToggle = [System.Windows.Controls.Button]::new()
$themeToggle.Content = '라이트 모드'; $themeToggle.Background = [System.Windows.Media.Brushes]::Transparent; $themeToggle.BorderThickness = [System.Windows.Thickness]::new(0); $themeToggle.Height = 30; $themeToggle.FontSize = 10
$themeButtonSurface = [System.Windows.Controls.Border]::new()
$themeButtonSurface.Background = [System.Windows.Media.Brushes]::Transparent; $themeButtonSurface.CornerRadius = [System.Windows.CornerRadius]::new(10); $themeButtonSurface.Child = $themeToggle
[System.Windows.Controls.Grid]::SetColumn($themeButtonSurface, 6)
$null = $buttonGrid.Children.Add($themeButtonSurface)

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
$script:taskbarLightTheme = Test-AppLightTheme
$script:taskbarOwner = [IntPtr]::Zero
$taskbarWidget = [UsageTaskbarLayer]::new()
$taskbarWidget.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$taskbarWidget.ShowInTaskbar = $false
$taskbarWidget.TopMost = $true
$taskbarWidget.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual

function Set-WpfUsageCard($provider, $result) {
    $fiveInfo = $dashboard.FindName("${provider}5Info"); $fiveReset = $dashboard.FindName("${provider}5Reset"); $fiveFill = $dashboard.FindName("${provider}5Fill")
    $sevenInfo = $dashboard.FindName("${provider}7Info"); $sevenReset = $dashboard.FindName("${provider}7Reset"); $sevenFill = $dashboard.FindName("${provider}7Fill")
    if ($result.error) {
        $fiveInfo.Text = '불러올 수 없음'; $fiveReset.Text = $result.error; $sevenInfo.Text = '불러올 수 없음'; $sevenReset.Text = $result.error
        $fiveFill.Width = 0; $sevenFill.Width = 0; return
    }
    $fivePercent = Get-UsagePercent $result.five; $sevenPercent = Get-UsagePercent $result.seven
    $fiveInfo.Text = "$(100 - $fivePercent)% 남음"; $fiveReset.Text = Get-ResetText $result.five
    $sevenInfo.Text = "$(100 - $sevenPercent)% 남음"; $sevenReset.Text = Get-ResetText $result.seven -Weekly
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

function Set-TaskbarWidgetEnabled($enabled) {
    $script:settings | Add-Member -NotePropertyName showTaskbarWidget -NotePropertyValue ([bool]$enabled) -Force
    $script:settings | ConvertTo-Json | Set-Content -LiteralPath $script:settingsFile -Encoding UTF8
    $widgetToggle.Content = if ($enabled) { '위젯 숨기기' } else { '위젯 보이기' }
    if ($enabled) { Update-UsageMenu } else { $taskbarWidget.Hide() }
}

function Set-TrayUsageDisplay($percent, $tooltip, $codexFive, $codexSeven, $claudeFive, $claudeSeven) {
    $oldIcon = $script:trayIcon; $oldBitmap = $script:trayBitmap
    $tray.Icon = New-DashboardTrayIcon $percent
    $tray.Text = if ($tooltip.Length -le 63) { $tooltip } else { $tooltip.Substring(0, 63) }
    if ($oldIcon) { $oldIcon.Dispose() }
    if ($oldBitmap) { $oldBitmap.Dispose() }
    $widgetToggle.Content = if (Test-TaskbarWidgetEnabled) { '위젯 숨기기' } else { '위젯 보이기' }
    Set-TaskbarWidgetPosition
}

function Set-DashboardThemeChildren($root, $textBrush, $mutedBrush, $trackBrush) {
    $childCount = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($root)
    for ($index = 0; $index -lt $childCount; $index++) {
        $child = [System.Windows.Media.VisualTreeHelper]::GetChild($root, $index)
        if ($child -is [System.Windows.Controls.TextBlock]) {
            $child.Foreground = if ($child.Name -match '(Info|Reset)$') { $mutedBrush } else { $textBrush }
        } elseif ($child -is [System.Windows.Controls.Button]) {
            $child.Foreground = $textBrush
        } elseif ($child -is [System.Windows.Controls.Border] -and $child.Height -eq 8 -and $child.Name -notmatch 'Fill$') {
            $child.Background = $trackBrush
        }
        Set-DashboardThemeChildren $child $textBrush $mutedBrush $trackBrush
    }
}

function Apply-AppTheme {
    $isLight = Test-AppLightTheme
    $converter = [System.Windows.Media.BrushConverter]::new()
    $shellBrush = $converter.ConvertFromString($(if ($isLight) { '#F8FAFC' } else { '#0B1220' }))
    $cardBrush = $converter.ConvertFromString($(if ($isLight) { '#FFFFFF' } else { '#172134' }))
    $buttonBrush = $converter.ConvertFromString($(if ($isLight) { '#E2E8F0' } else { '#1E293B' }))
    $textBrush = $converter.ConvertFromString($(if ($isLight) { '#0F172A' } else { '#E2E8F0' }))
    $mutedBrush = $converter.ConvertFromString($(if ($isLight) { '#475569' } else { '#94A3B8' }))
    $trackBrush = $converter.ConvertFromString($(if ($isLight) { '#CBD5E1' } else { '#334155' }))
    $dashboard.FindName('Shell').Background = $shellBrush
    $dashboard.FindName('CodexCard').Background = $cardBrush
    $dashboard.FindName('ClaudeCard').Background = $cardBrush
    foreach ($button in @($widgetToggle, $configure, $exit, $themeToggle)) { $button.Parent.Background = $buttonBrush }
    Set-DashboardThemeChildren $dashboard $textBrush $mutedBrush $trackBrush
    $themeToggle.Content = if ($isLight) { '다크 모드' } else { '라이트 모드' }
}

function Set-AppTheme($themeMode) {
    $script:settings | Add-Member -NotePropertyName displayTheme -NotePropertyValue $themeMode -Force
    $script:settings | ConvertTo-Json | Set-Content -LiteralPath $script:settingsFile -Encoding UTF8
    $script:taskbarLightTheme = Test-AppLightTheme
    if ($script:providerLogoCache) { foreach ($logo in $script:providerLogoCache.Values) { $logo.Dispose() } }
    $script:providerLogoCache = @{}
    Apply-AppTheme
    Update-UsageMenu
}

function Update-UsageMenu {
    $percentages = @(); $tooltipParts = @(); $codexFive = $null; $codexSeven = $null; $claudeFive = $null; $claudeSeven = $null
    if ($script:settings.showCodex) {
        $result = Get-Usage 'Codex'; Set-WpfUsageCard 'Codex' $result
        $script:lastCodexResult = $result
        if (-not $result.error) { $five = Get-UsagePercent $result.five; $seven = Get-UsagePercent $result.seven; $percentages += $five, $seven; $tooltipParts += "Codex 5h:$five% 7d:$seven%"; $codexFive = $five; $codexSeven = $seven }
    }
    if ($script:settings.showClaude) {
        $result = Get-Usage 'Claude'; Set-WpfUsageCard 'Claude' $result
        $script:lastClaudeResult = $result
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
$widgetToggle.Add_Click({ Set-TaskbarWidgetEnabled (-not (Test-TaskbarWidgetEnabled)) })
$themeToggle.Add_Click({ Set-AppTheme $(if (Test-AppLightTheme) { 'dark' } else { 'light' }) })
$exit.Add_Click({
    $timer.Stop()
    $taskbarTimer.Stop()
    $taskbarWidget.Close()
    if ($script:providerLogoCache) { foreach ($logo in $script:providerLogoCache.Values) { $logo.Dispose() } }
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
$taskbarWidget.Add_MouseClick({ param($sender, $event) if ($event.Button -eq [System.Windows.Forms.MouseButtons]::Right) { Show-DashboardPopup } })
$tray.Add_MouseUp({ param($sender, $event) if ($event.Button -eq [System.Windows.Forms.MouseButtons]::Right) { Show-DashboardPopup } })
$timer = [System.Windows.Forms.Timer]::new()
$timer.Interval = $script:pollSeconds * 1000
$timer.Add_Tick({ Update-UsageMenu })
$timer.Start()
$taskbarTimer = [System.Windows.Forms.Timer]::new()
$taskbarTimer.Interval = 1000
$taskbarTimer.Add_Tick({ Set-TaskbarWidgetPosition })
$taskbarTimer.Start()
Apply-AppTheme
Apply-ProviderSelection
Update-UsageMenu
[System.Windows.Forms.Application]::Run()
