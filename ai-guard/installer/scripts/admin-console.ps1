param(
    [string]$ConfigPath = "",
    [string]$ServiceName = "AIGuardAgent",
    [string]$LauncherScriptPath = "",
    [string]$DaemonBinaryPath = ""
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$browserPoliciesScript = Join-Path $PSScriptRoot "browser-policies.ps1"
if (-not (Test-Path $browserPoliciesScript)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Ulti Guard Agent Admin Console is missing a required helper file:`r`n$browserPoliciesScript`r`n`r`nRun the latest Ulti Guard setup and choose Install / Repair.",
        "Ulti Guard Agent",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    return
}

. $browserPoliciesScript

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SelfElevation {
    $parts = @(
        "-NoProfile",
        "-ExecutionPolicy", "RemoteSigned",
        "-File", "`"$PSCommandPath`""
    )

    if ($ConfigPath) {
        $parts += @("-ConfigPath", "`"$ConfigPath`"")
    }
    if ($ServiceName) {
        $parts += @("-ServiceName", "`"$ServiceName`"")
    }
    if ($LauncherScriptPath) {
        $parts += @("-LauncherScriptPath", "`"$LauncherScriptPath`"")
    }
    if ($DaemonBinaryPath) {
        $parts += @("-DaemonBinaryPath", "`"$DaemonBinaryPath`"")
    }

    try {
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList ($parts -join " ") | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Administrator approval is required to open Ulti Guard Agent Admin Console.",
            "Ulti Guard Agent",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
}

function Convert-ToHashtable {
    param(
        [Parameter(ValueFromPipeline = $true)]
        $InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $table = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $table[$key] = Convert-ToHashtable $InputObject[$key]
        }
        return $table
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += ,(Convert-ToHashtable $item)
        }
        return ,$items
    }

    if ($InputObject -is [pscustomobject]) {
        $table = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $table[$property.Name] = Convert-ToHashtable $property.Value
        }
        return $table
    }

    return $InputObject
}

function Get-BrandAssetPath {
    param(
        [string]$LeafName
    )

    $candidates = @(
        (Join-Path (Split-Path $PSScriptRoot -Parent) "branding\$LeafName"),
        (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "branding\$LeafName")
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    return $null
}

function Read-Config {
    if (-not (Test-Path $ConfigPath)) {
        throw "Ulti Guard config not found at $ConfigPath"
    }

    $raw = Get-Content -Path $ConfigPath -Raw
    return Convert-ToHashtable (ConvertFrom-Json -InputObject $raw)
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$ContentObject
    )

    $json = $ContentObject | ConvertTo-Json -Depth 20
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $encoding)
}

function Ensure-StringArray {
    param(
        $Value
    )

    if ($null -eq $Value) {
        return ,@()
    }

    if ($Value -is [string]) {
        return ,@($Value)
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value | ForEach-Object { [string]$_ } | Where-Object { $_ -ne "" })
        return ,$items
    }

    return ,@([string]$Value)
}

function Normalize-ConfigShape {
    param(
        [hashtable]$ConfigObject
    )

    if (-not $ConfigObject.Contains("managed_pii")) {
        $ConfigObject["managed_pii"] = [ordered]@{}
    }
    if (-not $ConfigObject.Contains("claude")) {
        $ConfigObject["claude"] = [ordered]@{}
    }
    if (-not $ConfigObject.Contains("blocking")) {
        $ConfigObject["blocking"] = [ordered]@{}
    }

    $ConfigObject["extension_ids"] = Ensure-StringArray $ConfigObject["extension_ids"]
    $ConfigObject["managed_pii"]["args"] = Ensure-StringArray $ConfigObject["managed_pii"]["args"]
    $ConfigObject["claude"]["desktop_processes"] = Ensure-StringArray $ConfigObject["claude"]["desktop_processes"]
    $ConfigObject["claude"]["web_hosts"] = Ensure-StringArray $ConfigObject["claude"]["web_hosts"]
    $ConfigObject["blocking"]["browser_hosts"] = Ensure-StringArray $ConfigObject["blocking"]["browser_hosts"]
    $ConfigObject["blocking"]["process_names"] = Ensure-StringArray $ConfigObject["blocking"]["process_names"]
    $ConfigObject["blocking"]["exempt_process_names"] = Ensure-StringArray $ConfigObject["blocking"]["exempt_process_names"]

    if (-not $ConfigObject.Contains("admin_console")) {
        $ConfigObject["admin_console"] = [ordered]@{}
    }

    if (-not $ConfigObject["admin_console"].Contains("password_hash")) {
        $ConfigObject["admin_console"]["password_hash"] = ""
    }
    if (-not $ConfigObject["admin_console"].Contains("password_salt")) {
        $ConfigObject["admin_console"]["password_salt"] = ""
    }
    if (-not $ConfigObject["admin_console"].Contains("password_iterations")) {
        $ConfigObject["admin_console"]["password_iterations"] = 150000
    }
}

function New-AdminConsoleSalt {
    $bytes = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    return [Convert]::ToBase64String($bytes)
}

function Get-AdminConsolePasswordHash {
    param(
        [string]$Password,
        [string]$SaltBase64,
        [int]$Iterations
    )

    $salt = [Convert]::FromBase64String($SaltBase64)
    try {
        $deriveBytes = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
            $Password,
            $salt,
            $Iterations,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256
        )
    } catch {
        $deriveBytes = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
            $Password,
            $salt,
            $Iterations
        )
    }

    try {
        $hashBytes = $deriveBytes.GetBytes(32)
        return [Convert]::ToBase64String($hashBytes)
    } finally {
        $deriveBytes.Dispose()
    }
}

function Show-PasswordPrompt {
    param(
        [string]$Title,
        [string]$Message,
        [switch]$Confirm
    )

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $dialog.Size = if ($Confirm) { New-Object System.Drawing.Size(430, 250) } else { New-Object System.Drawing.Size(430, 200) }
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.TopMost = $true

    $messageLabel = New-Object System.Windows.Forms.Label
    $messageLabel.Text = $Message
    $messageLabel.Location = New-Object System.Drawing.Point(18, 16)
    $messageLabel.Size = New-Object System.Drawing.Size(380, 40)
    $dialog.Controls.Add($messageLabel)

    $passwordLabel = New-Object System.Windows.Forms.Label
    $passwordLabel.Text = "Password"
    $passwordLabel.Location = New-Object System.Drawing.Point(20, 66)
    $passwordLabel.Size = New-Object System.Drawing.Size(120, 20)
    $dialog.Controls.Add($passwordLabel)

    $passwordBox = New-Object System.Windows.Forms.TextBox
    $passwordBox.Location = New-Object System.Drawing.Point(20, 88)
    $passwordBox.Size = New-Object System.Drawing.Size(380, 27)
    $passwordBox.UseSystemPasswordChar = $true
    $dialog.Controls.Add($passwordBox)

    $confirmBox = $null
    if ($Confirm) {
        $confirmLabel = New-Object System.Windows.Forms.Label
        $confirmLabel.Text = "Confirm Password"
        $confirmLabel.Location = New-Object System.Drawing.Point(20, 122)
        $confirmLabel.Size = New-Object System.Drawing.Size(140, 20)
        $dialog.Controls.Add($confirmLabel)

        $confirmBox = New-Object System.Windows.Forms.TextBox
        $confirmBox.Location = New-Object System.Drawing.Point(20, 144)
        $confirmBox.Size = New-Object System.Drawing.Size(380, 27)
        $confirmBox.UseSystemPasswordChar = $true
        $dialog.Controls.Add($confirmBox)
    }

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "OK"
    $okButton.Location = if ($Confirm) { New-Object System.Drawing.Point(226, 182) } else { New-Object System.Drawing.Point(226, 124) }
    $okButton.Size = New-Object System.Drawing.Size(82, 32)
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.Location = if ($Confirm) { New-Object System.Drawing.Point(318, 182) } else { New-Object System.Drawing.Point(318, 124) }
    $cancelButton.Size = New-Object System.Drawing.Size(82, 32)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancelButton)

    $dialog.AcceptButton = $okButton
    $dialog.CancelButton = $cancelButton

    $result = $dialog.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        $dialog.Dispose()
        return $null
    }

    $response = [ordered]@{
        password = $passwordBox.Text
        confirm = if ($confirmBox) { $confirmBox.Text } else { $null }
    }

    $dialog.Dispose()
    return $response
}

function Test-AdminConsolePasswordConfigured {
    $section = $script:config["admin_console"]
    return -not [string]::IsNullOrWhiteSpace([string]$section["password_hash"])
}

function Save-AdminConsoleConfigOnly {
    Normalize-ConfigShape -ConfigObject $script:config
    Write-JsonFile -Path $ConfigPath -ContentObject $script:config
}

function Set-AdminConsolePassword {
    param(
        [string]$PromptTitle,
        [string]$PromptMessage
    )

    while ($true) {
        $response = Show-PasswordPrompt -Title $PromptTitle -Message $PromptMessage -Confirm
        if ($null -eq $response) {
            return $false
        }

        $password = [string]$response["password"]
        $confirm = [string]$response["confirm"]

        if ($password.Length -lt 8) {
            [System.Windows.Forms.MessageBox]::Show(
                "Admin console password must be at least 8 characters long.",
                "Ulti Guard Agent",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            continue
        }

        if ($password -ne $confirm) {
            [System.Windows.Forms.MessageBox]::Show(
                "Passwords do not match. Try again.",
                "Ulti Guard Agent",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            continue
        }

        $salt = New-AdminConsoleSalt
        $iterations = [int]$script:config["admin_console"]["password_iterations"]
        $hash = Get-AdminConsolePasswordHash -Password $password -SaltBase64 $salt -Iterations $iterations
        $script:config["admin_console"]["password_salt"] = $salt
        $script:config["admin_console"]["password_hash"] = $hash
        Save-AdminConsoleConfigOnly
        return $true
    }
}

function Confirm-AdminConsoleAccess {
    if (-not (Test-AdminConsolePasswordConfigured)) {
        $created = Set-AdminConsolePassword `
            -PromptTitle "Set Admin Console Password" `
            -PromptMessage "Create a password for Ulti Guard Agent Admin Console. This password will be required every time the console opens."
        if (-not $created) {
            return $false
        }

        [System.Windows.Forms.MessageBox]::Show(
            "Admin console password has been set.",
            "Ulti Guard Agent",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return $true
    }

    $storedHash = [string]$script:config["admin_console"]["password_hash"]
    $storedSalt = [string]$script:config["admin_console"]["password_salt"]
    $iterations = [int]$script:config["admin_console"]["password_iterations"]

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $response = Show-PasswordPrompt `
            -Title "Admin Console Password" `
            -Message "Enter the Ulti Guard Agent Admin Console password."
        if ($null -eq $response) {
            return $false
        }

        $candidate = [string]$response["password"]
        $candidateHash = Get-AdminConsolePasswordHash -Password $candidate -SaltBase64 $storedSalt -Iterations $iterations
        if ($candidateHash -eq $storedHash) {
            return $true
        }

        [System.Windows.Forms.MessageBox]::Show(
            "Incorrect password.",
            "Ulti Guard Agent",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }

    return $false
}
function Normalize-Host {
    param(
        [string]$Value
    )

    $text = [string]$Value
    $text = $text.Trim().ToLowerInvariant()
    if (-not $text) {
        return ""
    }

    $text = $text.Trim("/")
    if ($text.StartsWith("http://") -or $text.StartsWith("https://")) {
        try {
            $uri = [Uri]$text
            if ($uri.Host) {
                $text = $uri.Host.ToLowerInvariant()
            }
        } catch {
        }
    }

    return $text.Trim().Trim(".")
}

function Normalize-ProcessName {
    param(
        [string]$Value
    )

    return ([string]$Value).Trim()
}

function Set-ListBoxValues {
    param(
        [System.Windows.Forms.ListBox]$ListBox,
        [string[]]$Values
    )

    $ListBox.Items.Clear()
    foreach ($item in @($Values | Where-Object { $_ } | Sort-Object -Unique)) {
        [void]$ListBox.Items.Add($item)
    }
}

function Get-ListBoxValues {
    param(
        [System.Windows.Forms.ListBox]$ListBox
    )

    return @($ListBox.Items | ForEach-Object { [string]$_ } | Where-Object { $_ } | Sort-Object -Unique)
}

function Add-UniqueListItem {
    param(
        [System.Windows.Forms.ListBox]$ListBox,
        [string]$Value
    )

    $current = Get-ListBoxValues -ListBox $ListBox
    if ($current -contains $Value) {
        return $false
    }

    [void]$ListBox.Items.Add($Value)
    Set-ListBoxValues -ListBox $ListBox -Values (Get-ListBoxValues -ListBox $ListBox)
    return $true
}

function Remove-SelectedListItems {
    param(
        [System.Windows.Forms.ListBox]$ListBox
    )

    $selected = @($ListBox.SelectedItems | ForEach-Object { [string]$_ })
    if (-not $selected) {
        return
    }

    foreach ($item in $selected) {
        $ListBox.Items.Remove($item)
    }

    Set-ListBoxValues -ListBox $ListBox -Values (Get-ListBoxValues -ListBox $ListBox)
}

function Wait-ForAIGuardHealth {
    param(
        [int]$TimeoutMs = 12000
    )

    $listenAddress = [string]$script:config["listen_address"]
    if (-not $listenAddress) {
        return $false
    }

    $healthUrl = "http://$listenAddress/healthz"
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $response = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 2
            if ($response.ok -eq $true) {
                return $true
            }
        } catch {
        }

        Start-Sleep -Milliseconds 500
    }

    return $false
}

function Restart-AIGuardRuntime {
    if ($ServiceName -and (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
        Restart-Service -Name $ServiceName -Force -ErrorAction Stop
        if (Wait-ForAIGuardHealth) {
            return "Windows service restarted."
        }

        return "Windows service restart requested, but daemon health check failed."
    }

    Get-Process ai-guard-daemon -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800

    if ($LauncherScriptPath -and (Test-Path $LauncherScriptPath)) {
        Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy RemoteSigned -File `"$LauncherScriptPath`"" -WindowStyle Hidden | Out-Null
        if (Wait-ForAIGuardHealth) {
            return "Daemon relaunched through launcher script."
        }

        return "Launcher script executed, but daemon health check failed."
    }

    if ($DaemonBinaryPath -and (Test-Path $DaemonBinaryPath)) {
        Start-Process -FilePath $DaemonBinaryPath -ArgumentList "--config `"$ConfigPath`" run" -WindowStyle Hidden | Out-Null
        if (Wait-ForAIGuardHealth) {
            return "Daemon relaunched directly."
        }

        return "Daemon launch attempted, but health check failed."
    }

    return "Config saved. Restart Ulti Guard manually."
}

function Get-PolicyRegistryHive {
    if ($ConfigPath -and $ConfigPath.StartsWith($env:ProgramFiles, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [Microsoft.Win32.RegistryHive]::LocalMachine
    }

    return [Microsoft.Win32.RegistryHive]::CurrentUser
}

function Apply-BrowserPoliciesFromConfig {
    $hive = Get-PolicyRegistryHive
    $hosts = @($script:config.blocking.browser_hosts)

    Set-AIGuardBrowserHostBlocklistPolicy -Hive $hive -Browser "Chrome" -Hosts $hosts
    Set-AIGuardBrowserHostBlocklistPolicy -Hive $hive -Browser "Edge" -Hosts $hosts
    Set-AIGuardPrivateBrowsingPolicy -Hive $hive -Browser "Chrome"
    Set-AIGuardPrivateBrowsingPolicy -Hive $hive -Browser "Edge"
}

if (-not $ConfigPath) {
    foreach ($candidate in @(
        (Join-Path ${env:ProgramFiles} "Ulti Guard Agent\config\ai-guard.json"),
        (Join-Path ${env:ProgramFiles} "AI Guard Agent\config\ai-guard.json"),
        (Join-Path $env:LOCALAPPDATA "Ulti Guard Agent\config\ai-guard.json"),
        (Join-Path $env:LOCALAPPDATA "AI Guard Agent\config\ai-guard.json")
    )) {
        if (Test-Path $candidate) {
            $ConfigPath = $candidate
            break
        }
    }
}

if (-not (Test-IsAdministrator)) {
    Invoke-SelfElevation
    return
}

$script:config = Read-Config
Normalize-ConfigShape -ConfigObject $script:config
if (-not (Confirm-AdminConsoleAccess)) {
    return
}

if (-not $script:config.Contains("blocking")) {
    $script:config["blocking"] = [ordered]@{
        browser_hosts = @()
        process_names = @()
        exempt_process_names = @()
    }
}

$providerCatalog = [ordered]@{
    "ChatGPT / OpenAI" = @{
        browser_hosts = @("chatgpt.com", "chat.openai.com")
        process_names = @("ChatGPT")
    }
    "Gemini" = @{
        browser_hosts = @("gemini.google.com")
        process_names = @("Gemini")
    }
    "Perplexity" = @{
        browser_hosts = @("perplexity.ai")
        process_names = @("Perplexity")
    }
    "Grok" = @{
        browser_hosts = @("grok.com", "x.ai")
        process_names = @("Grok")
    }
    "Cursor" = @{
        browser_hosts = @()
        process_names = @("Cursor")
    }
    "Ollama" = @{
        browser_hosts = @()
        process_names = @("Ollama")
    }
    "LM Studio" = @{
        browser_hosts = @()
        process_names = @("LM Studio")
    }
    "Open WebUI" = @{
        browser_hosts = @()
        process_names = @("OpenWebUI")
    }
    "AnythingLLM" = @{
        browser_hosts = @()
        process_names = @("AnythingLLM")
    }
    "Jan" = @{
        browser_hosts = @()
        process_names = @("Jan")
    }
}

[System.Windows.Forms.Application]::EnableVisualStyles()

function New-CardPanel {
    param(
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height
    )

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point($X, $Y)
    $panel.Size = New-Object System.Drawing.Size($Width, $Height)
    $panel.BackColor = [System.Drawing.Color]::White
    $panel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    return $panel
}

function Set-ButtonTheme {
    param(
        [System.Windows.Forms.Button]$Button,
        [ValidateSet("Primary", "Secondary", "Ghost", "Danger")]
        [string]$Variant = "Primary"
    )

    $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $Button.FlatAppearance.BorderSize = 0
    $Button.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand

    switch ($Variant) {
        "Primary" {
            $Button.BackColor = [System.Drawing.Color]::FromArgb(211, 101, 48)
            $Button.ForeColor = [System.Drawing.Color]::White
        }
        "Secondary" {
            $Button.BackColor = [System.Drawing.Color]::FromArgb(16, 35, 59)
            $Button.ForeColor = [System.Drawing.Color]::White
        }
        "Ghost" {
            $Button.BackColor = [System.Drawing.Color]::FromArgb(240, 243, 249)
            $Button.ForeColor = [System.Drawing.Color]::FromArgb(16, 35, 59)
        }
        "Danger" {
            $Button.BackColor = [System.Drawing.Color]::FromArgb(165, 32, 32)
            $Button.ForeColor = [System.Drawing.Color]::White
        }
    }
}

function Set-InputTheme {
    param(
        [System.Windows.Forms.Control]$Control
    )

    $Control.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $Control.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 253)
    $Control.ForeColor = [System.Drawing.Color]::FromArgb(27, 39, 53)
}

$brandLogoPath = Get-BrandAssetPath -LeafName "logo.png"
$brandIconPath = Get-BrandAssetPath -LeafName "logo.ico"

$form = New-Object System.Windows.Forms.Form
$form.Text = "Ulti Guard Agent Admin Console"
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Size = New-Object System.Drawing.Size(1080, 720)
$form.MinimumSize = New-Object System.Drawing.Size(1080, 720)
$form.BackColor = [System.Drawing.Color]::FromArgb(239, 242, 247)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)
if ($brandIconPath) {
    $form.Icon = New-Object System.Drawing.Icon($brandIconPath)
}

$heroPanel = New-Object System.Windows.Forms.Panel
$heroPanel.Location = New-Object System.Drawing.Point(18, 16)
$heroPanel.Size = New-Object System.Drawing.Size(1028, 132)
$heroPanel.BackColor = [System.Drawing.Color]::FromArgb(16, 35, 59)
$form.Controls.Add($heroPanel)

if ($brandLogoPath) {
    $heroLogo = New-Object System.Windows.Forms.PictureBox
    $heroLogo.Location = New-Object System.Drawing.Point(24, 28)
    $heroLogo.Size = New-Object System.Drawing.Size(160, 68)
    $heroLogo.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $heroLogo.BackColor = [System.Drawing.Color]::Transparent
    $heroLogo.Image = [System.Drawing.Image]::FromFile($brandLogoPath)
    $heroPanel.Controls.Add($heroLogo)
}

$heroEyebrow = New-Object System.Windows.Forms.Label
$heroEyebrow.Text = "WIN INFOSOFT · ENTERPRISE CONTROL"
$heroEyebrow.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9)
$heroEyebrow.ForeColor = [System.Drawing.Color]::FromArgb(242, 177, 140)
$heroEyebrow.Location = New-Object System.Drawing.Point(196, 18)
$heroEyebrow.AutoSize = $true
$heroPanel.Controls.Add($heroEyebrow)

$title = New-Object System.Windows.Forms.Label
$title.Text = "Ulti Guard Agent Admin Console"
$title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 22, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = [System.Drawing.Color]::White
$title.Location = New-Object System.Drawing.Point(194, 38)
$title.AutoSize = $true
$heroPanel.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = "Manage blocked providers, enforce browser policy, and keep Claude-only protection tight without exposing controls to standard users."
$subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(221, 229, 238)
$subtitle.Location = New-Object System.Drawing.Point(198, 82)
$subtitle.Size = New-Object System.Drawing.Size(528, 34)
$heroPanel.Controls.Add($subtitle)

$installModeBadge = New-Object System.Windows.Forms.Label
$installModeBadge.Text = if ($ConfigPath -and $ConfigPath.StartsWith($env:ProgramFiles, [System.StringComparison]::OrdinalIgnoreCase)) { "Machine Install" } else { "Current User Install" }
$installModeBadge.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$installModeBadge.ForeColor = [System.Drawing.Color]::White
$installModeBadge.BackColor = [System.Drawing.Color]::FromArgb(211, 101, 48)
$installModeBadge.Location = New-Object System.Drawing.Point(808, 24)
$installModeBadge.Size = New-Object System.Drawing.Size(180, 34)
$installModeBadge.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$heroPanel.Controls.Add($installModeBadge)

$configBadge = New-Object System.Windows.Forms.Label
$configBadge.Text = $ConfigPath
$configBadge.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$configBadge.ForeColor = [System.Drawing.Color]::FromArgb(221, 229, 238)
$configBadge.Location = New-Object System.Drawing.Point(598, 86)
$configBadge.Size = New-Object System.Drawing.Size(390, 30)
$configBadge.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$heroPanel.Controls.Add($configBadge)

$presetCard = New-CardPanel -X 18 -Y 164 -Width 1028 -Height 104
$form.Controls.Add($presetCard)

$presetTitle = New-Object System.Windows.Forms.Label
$presetTitle.Text = "Provider Presets"
$presetTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 12)
$presetTitle.ForeColor = [System.Drawing.Color]::FromArgb(16, 35, 59)
$presetTitle.Location = New-Object System.Drawing.Point(18, 14)
$presetTitle.AutoSize = $true
$presetCard.Controls.Add($presetTitle)

$presetHint = New-Object System.Windows.Forms.Label
$presetHint.Text = "Add a curated provider pack with known browser hosts and desktop process names."
$presetHint.Location = New-Object System.Drawing.Point(18, 40)
$presetHint.Size = New-Object System.Drawing.Size(480, 22)
$presetHint.ForeColor = [System.Drawing.Color]::FromArgb(94, 109, 128)
$presetCard.Controls.Add($presetHint)

$presetCombo = New-Object System.Windows.Forms.ComboBox
$presetCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$presetCombo.Location = New-Object System.Drawing.Point(22, 68)
$presetCombo.Size = New-Object System.Drawing.Size(320, 30)
$presetCombo.Items.AddRange(@($providerCatalog.Keys))
$presetCombo.SelectedIndex = 0
Set-InputTheme -Control $presetCombo
$presetCard.Controls.Add($presetCombo)

$presetNote = New-Object System.Windows.Forms.Label
$presetNote.Text = "Use this for common providers, then fine-tune hosts and processes below."
$presetNote.Location = New-Object System.Drawing.Point(360, 72)
$presetNote.Size = New-Object System.Drawing.Size(420, 22)
$presetNote.ForeColor = [System.Drawing.Color]::FromArgb(94, 109, 128)
$presetCard.Controls.Add($presetNote)

$addPresetButton = New-Object System.Windows.Forms.Button
$addPresetButton.Text = "Add Provider"
$addPresetButton.Location = New-Object System.Drawing.Point(864, 64)
$addPresetButton.Size = New-Object System.Drawing.Size(138, 34)
Set-ButtonTheme -Button $addPresetButton -Variant Secondary
$presetCard.Controls.Add($addPresetButton)

$webCard = New-CardPanel -X 18 -Y 286 -Width 502 -Height 336
$form.Controls.Add($webCard)

$webTitle = New-Object System.Windows.Forms.Label
$webTitle.Text = "Blocked Websites / Hosts"
$webTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 12)
$webTitle.ForeColor = [System.Drawing.Color]::FromArgb(16, 35, 59)
$webTitle.Location = New-Object System.Drawing.Point(18, 14)
$webTitle.AutoSize = $true
$webCard.Controls.Add($webTitle)

$webCaption = New-Object System.Windows.Forms.Label
$webCaption.Text = "These hosts are denied by extension logic and enterprise browser policy."
$webCaption.Location = New-Object System.Drawing.Point(18, 40)
$webCaption.Size = New-Object System.Drawing.Size(440, 22)
$webCaption.ForeColor = [System.Drawing.Color]::FromArgb(94, 109, 128)
$webCard.Controls.Add($webCaption)

$webList = New-Object System.Windows.Forms.ListBox
$webList.SelectionMode = [System.Windows.Forms.SelectionMode]::MultiExtended
$webList.Location = New-Object System.Drawing.Point(20, 72)
$webList.Size = New-Object System.Drawing.Size(460, 186)
Set-InputTheme -Control $webList
$webCard.Controls.Add($webList)

$webInput = New-Object System.Windows.Forms.TextBox
$webInput.Location = New-Object System.Drawing.Point(20, 274)
$webInput.Size = New-Object System.Drawing.Size(280, 30)
Set-InputTheme -Control $webInput
$webCard.Controls.Add($webInput)

$webAddButton = New-Object System.Windows.Forms.Button
$webAddButton.Text = "Add Host"
$webAddButton.Location = New-Object System.Drawing.Point(314, 272)
$webAddButton.Size = New-Object System.Drawing.Size(78, 32)
Set-ButtonTheme -Button $webAddButton -Variant Primary
$webCard.Controls.Add($webAddButton)

$webRemoveButton = New-Object System.Windows.Forms.Button
$webRemoveButton.Text = "Remove"
$webRemoveButton.Location = New-Object System.Drawing.Point(402, 272)
$webRemoveButton.Size = New-Object System.Drawing.Size(78, 32)
Set-ButtonTheme -Button $webRemoveButton -Variant Ghost
$webCard.Controls.Add($webRemoveButton)

$webHelp = New-Object System.Windows.Forms.Label
$webHelp.Text = "Examples: grok.com, gemini.google.com, chat.deepseek.com"
$webHelp.Location = New-Object System.Drawing.Point(20, 308)
$webHelp.Size = New-Object System.Drawing.Size(360, 20)
$webHelp.ForeColor = [System.Drawing.Color]::FromArgb(94, 109, 128)
$webCard.Controls.Add($webHelp)

$processCard = New-CardPanel -X 544 -Y 286 -Width 502 -Height 336
$form.Controls.Add($processCard)

$processTitle = New-Object System.Windows.Forms.Label
$processTitle.Text = "Blocked Desktop Processes"
$processTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 12)
$processTitle.ForeColor = [System.Drawing.Color]::FromArgb(16, 35, 59)
$processTitle.Location = New-Object System.Drawing.Point(18, 14)
$processTitle.AutoSize = $true
$processCard.Controls.Add($processTitle)

$processCaption = New-Object System.Windows.Forms.Label
$processCaption.Text = "These process names are killed while Claude guard mode is active."
$processCaption.Location = New-Object System.Drawing.Point(18, 40)
$processCaption.Size = New-Object System.Drawing.Size(440, 22)
$processCaption.ForeColor = [System.Drawing.Color]::FromArgb(94, 109, 128)
$processCard.Controls.Add($processCaption)

$processList = New-Object System.Windows.Forms.ListBox
$processList.SelectionMode = [System.Windows.Forms.SelectionMode]::MultiExtended
$processList.Location = New-Object System.Drawing.Point(20, 72)
$processList.Size = New-Object System.Drawing.Size(460, 186)
Set-InputTheme -Control $processList
$processCard.Controls.Add($processList)

$processInput = New-Object System.Windows.Forms.TextBox
$processInput.Location = New-Object System.Drawing.Point(20, 274)
$processInput.Size = New-Object System.Drawing.Size(280, 30)
Set-InputTheme -Control $processInput
$processCard.Controls.Add($processInput)

$processAddButton = New-Object System.Windows.Forms.Button
$processAddButton.Text = "Add Process"
$processAddButton.Location = New-Object System.Drawing.Point(314, 272)
$processAddButton.Size = New-Object System.Drawing.Size(86, 32)
Set-ButtonTheme -Button $processAddButton -Variant Primary
$processCard.Controls.Add($processAddButton)

$processRemoveButton = New-Object System.Windows.Forms.Button
$processRemoveButton.Text = "Remove"
$processRemoveButton.Location = New-Object System.Drawing.Point(406, 272)
$processRemoveButton.Size = New-Object System.Drawing.Size(74, 32)
Set-ButtonTheme -Button $processRemoveButton -Variant Ghost
$processCard.Controls.Add($processRemoveButton)

$processHelp = New-Object System.Windows.Forms.Label
$processHelp.Text = "Examples: Cursor, Ollama, LM Studio, ChatGPT"
$processHelp.Location = New-Object System.Drawing.Point(20, 308)
$processHelp.Size = New-Object System.Drawing.Size(320, 20)
$processHelp.ForeColor = [System.Drawing.Color]::FromArgb(94, 109, 128)
$processCard.Controls.Add($processHelp)

$footerPanel = New-Object System.Windows.Forms.Panel
$footerPanel.Location = New-Object System.Drawing.Point(18, 636)
$footerPanel.Size = New-Object System.Drawing.Size(1028, 54)
$footerPanel.BackColor = [System.Drawing.Color]::FromArgb(247, 249, 252)
$footerPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($footerPanel)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Ready."
$statusLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(16, 35, 59)
$statusLabel.Location = New-Object System.Drawing.Point(18, 16)
$statusLabel.Size = New-Object System.Drawing.Size(390, 22)
$footerPanel.Controls.Add($statusLabel)

$changePasswordButton = New-Object System.Windows.Forms.Button
$changePasswordButton.Text = "Change Password"
$changePasswordButton.Location = New-Object System.Drawing.Point(542, 10)
$changePasswordButton.Size = New-Object System.Drawing.Size(150, 32)
Set-ButtonTheme -Button $changePasswordButton -Variant Ghost
$footerPanel.Controls.Add($changePasswordButton)

$reloadButton = New-Object System.Windows.Forms.Button
$reloadButton.Text = "Reload"
$reloadButton.Location = New-Object System.Drawing.Point(706, 10)
$reloadButton.Size = New-Object System.Drawing.Size(86, 32)
Set-ButtonTheme -Button $reloadButton -Variant Ghost
$footerPanel.Controls.Add($reloadButton)

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = "Save and Apply"
$saveButton.Location = New-Object System.Drawing.Point(806, 10)
$saveButton.Size = New-Object System.Drawing.Size(132, 32)
Set-ButtonTheme -Button $saveButton -Variant Primary
$footerPanel.Controls.Add($saveButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = "Close"
$closeButton.Location = New-Object System.Drawing.Point(950, 10)
$closeButton.Size = New-Object System.Drawing.Size(60, 32)
Set-ButtonTheme -Button $closeButton -Variant Secondary
$footerPanel.Controls.Add($closeButton)

function Refresh-UiFromConfig {
    $script:config = Read-Config
    Normalize-ConfigShape -ConfigObject $script:config
    Set-ListBoxValues -ListBox $webList -Values @($script:config.blocking.browser_hosts)
    Set-ListBoxValues -ListBox $processList -Values @($script:config.blocking.process_names)
    $statusLabel.Text = "Loaded config from $ConfigPath"
}

function Add-HostFromInput {
    $value = Normalize-Host -Value $webInput.Text
    if (-not $value) {
        return
    }

    if (Add-UniqueListItem -ListBox $webList -Value $value) {
        $webInput.Clear()
        $statusLabel.Text = "Added blocked host: $value"
    } else {
        $statusLabel.Text = "Host already exists: $value"
    }
}

function Add-ProcessFromInput {
    $value = Normalize-ProcessName -Value $processInput.Text
    if (-not $value) {
        return
    }

    if (Add-UniqueListItem -ListBox $processList -Value $value) {
        $processInput.Clear()
        $statusLabel.Text = "Added blocked process: $value"
    } else {
        $statusLabel.Text = "Process already exists: $value"
    }
}

function Add-PresetProvider {
    $name = [string]$presetCombo.SelectedItem
    if (-not $name -or -not $providerCatalog.Contains($name)) {
        return
    }

    $preset = $providerCatalog[$name]
    foreach ($host in @($preset.browser_hosts | ForEach-Object { Normalize-Host -Value $_ } | Where-Object { $_ })) {
        Add-UniqueListItem -ListBox $webList -Value $host | Out-Null
    }

    foreach ($processName in @($preset.process_names | ForEach-Object { Normalize-ProcessName -Value $_ } | Where-Object { $_ })) {
        Add-UniqueListItem -ListBox $processList -Value $processName | Out-Null
    }

    $statusLabel.Text = "Added preset provider: $name"
}

function Save-And-Apply {
    $script:config.blocking.browser_hosts = Get-ListBoxValues -ListBox $webList
    $script:config.blocking.process_names = Get-ListBoxValues -ListBox $processList
    Normalize-ConfigShape -ConfigObject $script:config
    Write-JsonFile -Path $ConfigPath -ContentObject $script:config
    Apply-BrowserPoliciesFromConfig
    $result = Restart-AIGuardRuntime
    $statusLabel.Text = "Saved. $result"
    [System.Windows.Forms.MessageBox]::Show(
        "Provider settings were saved successfully.`r`n`r`nBrowser URL block policy was updated. Incognito/InPrivate remain enabled, but blocked providers stay denied by browser policy.`r`n`r`n$result",
        "Ulti Guard Agent",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

function Change-AdminConsolePassword {
    $changed = Set-AdminConsolePassword `
        -PromptTitle "Change Admin Console Password" `
        -PromptMessage "Enter a new password for Ulti Guard Agent Admin Console."
    if ($changed) {
        $statusLabel.Text = "Admin console password updated."
        [System.Windows.Forms.MessageBox]::Show(
            "Admin console password was updated successfully.",
            "Ulti Guard Agent",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
}

$webAddButton.Add_Click({ Add-HostFromInput })
$webInput.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        Add-HostFromInput
        $_.SuppressKeyPress = $true
    }
})
$webRemoveButton.Add_Click({
    Remove-SelectedListItems -ListBox $webList
    $statusLabel.Text = "Removed selected hosts."
})

$processAddButton.Add_Click({ Add-ProcessFromInput })
$processInput.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        Add-ProcessFromInput
        $_.SuppressKeyPress = $true
    }
})
$processRemoveButton.Add_Click({
    Remove-SelectedListItems -ListBox $processList
    $statusLabel.Text = "Removed selected processes."
})

$addPresetButton.Add_Click({ Add-PresetProvider })
$changePasswordButton.Add_Click({ Change-AdminConsolePassword })
$reloadButton.Add_Click({ Refresh-UiFromConfig })
$saveButton.Add_Click({ Save-And-Apply })
$closeButton.Add_Click({ $form.Close() })

Refresh-UiFromConfig
[void]$form.ShowDialog()
