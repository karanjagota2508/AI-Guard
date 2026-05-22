param(
    [string]$ConfigPath,
    [int]$PollMs = 300
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class AiGuardNativeMethods
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
}
"@

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, "Global\AIGuardClaudeDesktopUiaGuard", [ref]$createdNew)
if (-not $createdNew) {
    return
}

try {
    if (-not (Test-Path $ConfigPath)) {
        throw "Ulti Guard config not found at $ConfigPath"
    }

    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $baseUrl = "http://$($config.listen_address)"
    $authToken = "$($config.auth_token)"
    $extensionId = "$($config.package.extension_id)"
    if (-not $extensionId) {
        $extensionId = @($config.extension_ids)[0]
    }
    $origin = "chrome-extension://$extensionId"
    $headers = @{
        Authorization = "Bearer $authToken"
        Origin = $origin
    }

    $state = @{
        LastNormalizedText = ""
        Applying = $false
        LastWarningAtUtcMs = 0
        LastWarningKey = ""
    }

    function Normalize-Text {
        param(
            [string]$Value
        )

        if ([string]::IsNullOrEmpty($Value)) {
            return ""
        }

        return $Value.Replace("`r`n", "`n").Replace("`r", "`n").Trim()
    }

    function Get-ClaudeWindowHandle {
        $proc = Get-Process claude -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -eq "Claude" } |
            Sort-Object StartTime -Descending |
            Select-Object -First 1

        if (-not $proc) {
            return [IntPtr]::Zero
        }

        return [IntPtr]$proc.MainWindowHandle
    }

    function Get-ClaudeEditor {
        $windowHandle = Get-ClaudeWindowHandle
        if ($windowHandle -eq [IntPtr]::Zero) {
            return $null
        }

        $window = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
        if (-not $window) {
            return $null
        }

        $editCondition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Edit
        )

        $editors = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $editCondition)
        if (-not $editors -or $editors.Count -eq 0) {
            return $null
        }

        for ($i = 0; $i -lt $editors.Count; $i++) {
            $editor = $editors.Item($i)
            if (
                $editor.Current.IsEnabled -and
                (
                    $editor.Current.Name -like "*prompt*" -or
                    $editor.Current.Name -like "*Claude*" -or
                    $editor.Current.ClassName -like "*ProseMirror*"
                )
            ) {
                return $editor
            }
        }

        return $editors.Item(0)
    }

    function Get-EditorValue {
        param(
            [System.Windows.Automation.AutomationElement]$Editor
        )

        if (-not $Editor) {
            return ""
        }

        $valuePattern = $null
        if ($Editor.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$valuePattern)) {
            return [string]$valuePattern.Current.Value
        }

        $textPattern = $null
        if ($Editor.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$textPattern)) {
            return [string]$textPattern.DocumentRange.GetText(-1)
        }

        return ""
    }

    function Set-EditorValue {
        param(
            [System.Windows.Automation.AutomationElement]$Editor,
            [string]$Value
        )

        $valuePattern = $null
        if (-not $Editor.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$valuePattern)) {
            throw "Claude editor does not expose ValuePattern"
        }

        $valuePattern.SetValue($Value)
    }

    function Get-ToastPlacement {
        param(
            [System.Windows.Automation.AutomationElement]$Editor = $null,
            [int]$Width = 460,
            [int]$Height = 108
        )

        $editorRect = $null
        if ($Editor) {
            $bounds = $Editor.Current.BoundingRectangle
            if (
                -not [double]::IsInfinity($bounds.Left) -and
                -not [double]::IsInfinity($bounds.Top) -and
                -not [double]::IsInfinity($bounds.Right) -and
                -not [double]::IsInfinity($bounds.Bottom) -and
                $bounds.Right -gt $bounds.Left -and
                $bounds.Bottom -gt $bounds.Top
            ) {
                $editorRect = [System.Drawing.Rectangle]::FromLTRB(
                    [int][Math]::Round($bounds.Left),
                    [int][Math]::Round($bounds.Top),
                    [int][Math]::Round($bounds.Right),
                    [int][Math]::Round($bounds.Bottom)
                )
                $screen = [System.Windows.Forms.Screen]::FromRectangle($editorRect)
            }
        }

        if (-not $screen) {
            $windowHandle = Get-ClaudeWindowHandle
            if ($windowHandle -ne [IntPtr]::Zero) {
                $screen = [System.Windows.Forms.Screen]::FromHandle($windowHandle)
            }
        }

        if (-not $screen) {
            $screen = [System.Windows.Forms.Screen]::PrimaryScreen
        }

        $area = $screen.WorkingArea

        return @{
            MinX = $area.Left + 18
            MaxRight = $area.Right - 24
            MinY = $area.Top + 18
            MaxBottom = $area.Bottom - 18
        }
    }

    function Set-CaretToDocumentEnd {
        param(
            [System.Windows.Automation.AutomationElement]$Editor
        )

        if (-not $Editor) {
            return
        }

        try {
            $Editor.SetFocus()
            Start-Sleep -Milliseconds 35
            [System.Windows.Forms.SendKeys]::SendWait("^{END}")
            Start-Sleep -Milliseconds 20
        } catch {
        }
    }

    function Show-DesktopToast {
        param(
            [string]$Message,
            [string]$DedupKey = "",
            [System.Windows.Automation.AutomationElement]$Editor = $null,
            [hashtable]$Placement = $null
        )

        $text = if ([string]::IsNullOrWhiteSpace($Message)) {
            "Ulti Guard Agent blocked this Claude Desktop prompt."
        } else {
            "Ulti Guard Agent: $Message"
        }

        $key = if ([string]::IsNullOrWhiteSpace($DedupKey)) { $text } else { $DedupKey }
        $nowUtcMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        if ($state.LastWarningKey -eq $key -and ($nowUtcMs - $state.LastWarningAtUtcMs) -lt 2500) {
            return
        }

        $state.LastWarningKey = $key
        $state.LastWarningAtUtcMs = $nowUtcMs

        if (-not $Placement) {
            $Placement = Get-ToastPlacement -Editor $Editor
        }
        $safeText = $text.Replace("'", "''")
        $toastScript = @"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System.Runtime.InteropServices;
public static class AiGuardToastNativeMethods {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
'@
[AiGuardToastNativeMethods]::SetProcessDPIAware() | Out-Null
[System.Windows.Forms.Application]::EnableVisualStyles()
`$form = New-Object System.Windows.Forms.Form
`$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
`$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
`$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
`$form.ShowInTaskbar = `$false
`$form.TopMost = `$true
`$form.BackColor = [System.Drawing.Color]::FromArgb(161, 23, 23)
`$form.ForeColor = [System.Drawing.Color]::White
`$form.Size = New-Object System.Drawing.Size(460, 108)
`$form.Padding = New-Object System.Windows.Forms.Padding(0)
`$label = New-Object System.Windows.Forms.Label
`$label.Dock = [System.Windows.Forms.DockStyle]::Fill
`$label.Text = '$safeText'
`$label.Padding = New-Object System.Windows.Forms.Padding(16, 14, 16, 14)
`$label.BackColor = `$form.BackColor
`$label.ForeColor = `$form.ForeColor
`$label.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
`$label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
`$form.Controls.Add(`$label)
`$timer = New-Object System.Windows.Forms.Timer
`$timer.Interval = 3500
`$timer.Add_Tick({
    `$timer.Stop()
    `$form.Close()
})
`$form.Add_Shown({
    `$scaleX = 1.0
    `$scaleY = 1.0
    try {
        `$appliedDpi = [double](Get-ItemPropertyValue -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name AppliedDPI -ErrorAction Stop)
        if (`$appliedDpi -ge 96.0) {
            `$scaleX = `$appliedDpi / 96.0
            `$scaleY = `$scaleX
        }
    } catch {
    }
    if (`$scaleX -le 1.0 -or `$scaleY -le 1.0) {
        `$bitmap = New-Object System.Drawing.Bitmap 1, 1
        `$graphics = [System.Drawing.Graphics]::FromImage(`$bitmap)
        try {
            `$scaleX = [Math]::Max(1.0, `$graphics.DpiX / 96.0)
            `$scaleY = [Math]::Max(1.0, `$graphics.DpiY / 96.0)
        } finally {
            `$graphics.Dispose()
            `$bitmap.Dispose()
        }
    }
    `$logicalMinX = [int][Math]::Ceiling($($Placement.MinX) / `$scaleX)
    `$logicalMaxRight = [int][Math]::Floor($($Placement.MaxRight) / `$scaleX)
    `$logicalMinY = [int][Math]::Ceiling($($Placement.MinY) / `$scaleY)
    `$logicalMaxBottom = [int][Math]::Floor($($Placement.MaxBottom) / `$scaleY)
    `$x = [Math]::Max(`$logicalMinX, `$logicalMaxRight - `$form.Width)
    `$y = [Math]::Min(`$logicalMinY, [Math]::Max(`$logicalMinY, `$logicalMaxBottom - `$form.Height))
    `$form.Location = New-Object System.Drawing.Point(`$x, `$y)
    `$timer.Start()
})
[System.Windows.Forms.Application]::Run(`$form)
"@

        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($toastScript))
        Start-Process `
            -FilePath "powershell.exe" `
            -ArgumentList "-NoProfile -ExecutionPolicy RemoteSigned -STA -WindowStyle Hidden -EncodedCommand $encoded" `
            -WindowStyle Hidden | Out-Null
    }

    function Invoke-Scan {
        param(
            [string]$Text
        )

        $body = @{ text = $Text } | ConvertTo-Json
        return Invoke-RestMethod `
            -Method Post `
            -Uri "$baseUrl/scan" `
            -Headers $headers `
            -Body $body `
            -ContentType "application/json" `
            -TimeoutSec 5
    }

    while ($true) {
        try {
            if ($state.Applying) {
                Start-Sleep -Milliseconds $PollMs
                continue
            }

            $editor = Get-ClaudeEditor
            if (-not $editor) {
                $state.LastNormalizedText = ""
                Start-Sleep -Milliseconds $PollMs
                continue
            }

            $currentText = Get-EditorValue -Editor $editor
            $normalizedText = Normalize-Text -Value $currentText
            if (-not $normalizedText) {
                $state.LastNormalizedText = ""
                Start-Sleep -Milliseconds $PollMs
                continue
            }

            if ($normalizedText -eq $state.LastNormalizedText) {
                Start-Sleep -Milliseconds $PollMs
                continue
            }

            $state.LastNormalizedText = $normalizedText
            $response = Invoke-Scan -Text $currentText
            if (-not $response -or -not $response.action) {
                Start-Sleep -Milliseconds $PollMs
                continue
            }

            if ($response.action -eq "allow") {
                Start-Sleep -Milliseconds $PollMs
                continue
            }

            $state.Applying = $true
            try {
                $toastPlacement = Get-ToastPlacement -Editor $editor
                if ($response.action -eq "redact") {
                    $replacement = [string]$response.redacted_text
                    if (-not [string]::IsNullOrWhiteSpace($replacement) -and (Normalize-Text -Value $replacement) -ne $normalizedText) {
                        Set-EditorValue -Editor $editor -Value $replacement
                        $state.LastNormalizedText = Normalize-Text -Value $replacement
                        Set-CaretToDocumentEnd -Editor $editor
                    }
                    Show-DesktopToast -Message ([string]$response.reason) -DedupKey "redact:$($response.reason)" -Placement $toastPlacement
                } elseif ($response.action -eq "block") {
                    Set-EditorValue -Editor $editor -Value ""
                    $state.LastNormalizedText = ""
                    Set-CaretToDocumentEnd -Editor $editor
                    Show-DesktopToast -Message ([string]$response.reason) -DedupKey "block:$($response.reason)" -Placement $toastPlacement
                }
            } finally {
                $state.Applying = $false
            }
        } catch {
            Start-Sleep -Milliseconds ([Math]::Max($PollMs, 250))
        }

        Start-Sleep -Milliseconds $PollMs
    }
} finally {
    if ($mutex) {
        $mutex.ReleaseMutex() | Out-Null
        $mutex.Dispose()
    }
}
