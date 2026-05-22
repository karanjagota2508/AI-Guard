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
        "AI Guard Agent Admin Console is missing a required helper file:`r`n$browserPoliciesScript`r`n`r`nRun the latest AI Guard setup and choose Install / Repair.",
        "AI Guard Agent",
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
        "-ExecutionPolicy", "Bypass",
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
            "Administrator approval is required to open AI Guard Agent Admin Console.",
            "AI Guard Agent",
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

function Read-Config {
    if (-not (Test-Path $ConfigPath)) {
        throw "AI Guard config not found at $ConfigPath"
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
                "AI Guard Agent",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            continue
        }

        if ($password -ne $confirm) {
            [System.Windows.Forms.MessageBox]::Show(
                "Passwords do not match. Try again.",
                "AI Guard Agent",
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
            -PromptMessage "Create a password for AI Guard Agent Admin Console. This password will be required every time the console opens."
        if (-not $created) {
            return $false
        }

        [System.Windows.Forms.MessageBox]::Show(
            "Admin console password has been set.",
            "AI Guard Agent",
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
            -Message "Enter the AI Guard Agent Admin Console password."
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
            "AI Guard Agent",
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
        Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$LauncherScriptPath`"" -WindowStyle Hidden | Out-Null
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

    return "Config saved. Restart AI Guard manually."
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
    $candidate = Join-Path ${env:ProgramFiles} "AI Guard Agent\config\ai-guard.json"
    if (Test-Path $candidate) {
        $ConfigPath = $candidate
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

$form = New-Object System.Windows.Forms.Form
$form.Text = "AI Guard Agent Admin Console"
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Size = New-Object System.Drawing.Size(980, 640)
$form.MinimumSize = New-Object System.Drawing.Size(980, 640)
$form.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 252)

$title = New-Object System.Windows.Forms.Label
$title.Text = "AI Guard Agent Admin Console"
$title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 18, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(20, 16)
$title.AutoSize = $true
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = "Only administrators with the admin-console password can change blocked providers. Standard users remain read-only when AI Guard is machine-installed."
$subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$subtitle.Location = New-Object System.Drawing.Point(22, 52)
$subtitle.Size = New-Object System.Drawing.Size(920, 40)
$form.Controls.Add($subtitle)

$presetGroup = New-Object System.Windows.Forms.GroupBox
$presetGroup.Text = "Provider Presets"
$presetGroup.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$presetGroup.Location = New-Object System.Drawing.Point(20, 98)
$presetGroup.Size = New-Object System.Drawing.Size(924, 86)
$form.Controls.Add($presetGroup)

$presetCombo = New-Object System.Windows.Forms.ComboBox
$presetCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$presetCombo.Location = New-Object System.Drawing.Point(16, 34)
$presetCombo.Size = New-Object System.Drawing.Size(340, 28)
$presetCombo.Items.AddRange(@($providerCatalog.Keys))
$presetCombo.SelectedIndex = 0
$presetGroup.Controls.Add($presetCombo)

$presetHint = New-Object System.Windows.Forms.Label
$presetHint.Text = "Preset adds known domains and desktop process names for the selected provider."
$presetHint.Location = New-Object System.Drawing.Point(370, 38)
$presetHint.Size = New-Object System.Drawing.Size(370, 24)
$presetGroup.Controls.Add($presetHint)

$addPresetButton = New-Object System.Windows.Forms.Button
$addPresetButton.Text = "Add Provider"
$addPresetButton.Location = New-Object System.Drawing.Point(778, 31)
$addPresetButton.Size = New-Object System.Drawing.Size(126, 32)
$presetGroup.Controls.Add($addPresetButton)

$webGroup = New-Object System.Windows.Forms.GroupBox
$webGroup.Text = "Blocked Websites / Hosts"
$webGroup.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$webGroup.Location = New-Object System.Drawing.Point(20, 198)
$webGroup.Size = New-Object System.Drawing.Size(446, 320)
$form.Controls.Add($webGroup)

$webList = New-Object System.Windows.Forms.ListBox
$webList.SelectionMode = [System.Windows.Forms.SelectionMode]::MultiExtended
$webList.Location = New-Object System.Drawing.Point(16, 32)
$webList.Size = New-Object System.Drawing.Size(412, 212)
$webGroup.Controls.Add($webList)

$webInput = New-Object System.Windows.Forms.TextBox
$webInput.Location = New-Object System.Drawing.Point(16, 258)
$webInput.Size = New-Object System.Drawing.Size(272, 28)
$webGroup.Controls.Add($webInput)

$webAddButton = New-Object System.Windows.Forms.Button
$webAddButton.Text = "Add Host"
$webAddButton.Location = New-Object System.Drawing.Point(300, 255)
$webAddButton.Size = New-Object System.Drawing.Size(128, 30)
$webGroup.Controls.Add($webAddButton)

$webRemoveButton = New-Object System.Windows.Forms.Button
$webRemoveButton.Text = "Remove Selected"
$webRemoveButton.Location = New-Object System.Drawing.Point(300, 289)
$webRemoveButton.Size = New-Object System.Drawing.Size(128, 30)
$webGroup.Controls.Add($webRemoveButton)

$webHelp = New-Object System.Windows.Forms.Label
$webHelp.Text = "Examples: grok.com, gemini.google.com, chat.deepseek.com"
$webHelp.Location = New-Object System.Drawing.Point(16, 292)
$webHelp.Size = New-Object System.Drawing.Size(272, 24)
$webGroup.Controls.Add($webHelp)

$processGroup = New-Object System.Windows.Forms.GroupBox
$processGroup.Text = "Blocked Desktop Processes"
$processGroup.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$processGroup.Location = New-Object System.Drawing.Point(498, 198)
$processGroup.Size = New-Object System.Drawing.Size(446, 320)
$form.Controls.Add($processGroup)

$processList = New-Object System.Windows.Forms.ListBox
$processList.SelectionMode = [System.Windows.Forms.SelectionMode]::MultiExtended
$processList.Location = New-Object System.Drawing.Point(16, 32)
$processList.Size = New-Object System.Drawing.Size(412, 212)
$processGroup.Controls.Add($processList)

$processInput = New-Object System.Windows.Forms.TextBox
$processInput.Location = New-Object System.Drawing.Point(16, 258)
$processInput.Size = New-Object System.Drawing.Size(272, 28)
$processGroup.Controls.Add($processInput)

$processAddButton = New-Object System.Windows.Forms.Button
$processAddButton.Text = "Add Process"
$processAddButton.Location = New-Object System.Drawing.Point(300, 255)
$processAddButton.Size = New-Object System.Drawing.Size(128, 30)
$processGroup.Controls.Add($processAddButton)

$processRemoveButton = New-Object System.Windows.Forms.Button
$processRemoveButton.Text = "Remove Selected"
$processRemoveButton.Location = New-Object System.Drawing.Point(300, 289)
$processRemoveButton.Size = New-Object System.Drawing.Size(128, 30)
$processGroup.Controls.Add($processRemoveButton)

$processHelp = New-Object System.Windows.Forms.Label
$processHelp.Text = "Examples: Cursor, Ollama, LM Studio, ChatGPT"
$processHelp.Location = New-Object System.Drawing.Point(16, 292)
$processHelp.Size = New-Object System.Drawing.Size(272, 24)
$processGroup.Controls.Add($processHelp)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Ready."
$statusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$statusLabel.Location = New-Object System.Drawing.Point(22, 532)
$statusLabel.Size = New-Object System.Drawing.Size(360, 24)
$form.Controls.Add($statusLabel)

$changePasswordButton = New-Object System.Windows.Forms.Button
$changePasswordButton.Text = "Change Console Password"
$changePasswordButton.Location = New-Object System.Drawing.Point(380, 548)
$changePasswordButton.Size = New-Object System.Drawing.Size(170, 34)
$form.Controls.Add($changePasswordButton)

$reloadButton = New-Object System.Windows.Forms.Button
$reloadButton.Text = "Reload"
$reloadButton.Location = New-Object System.Drawing.Point(564, 548)
$reloadButton.Size = New-Object System.Drawing.Size(110, 34)
$form.Controls.Add($reloadButton)

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = "Save and Apply"
$saveButton.Location = New-Object System.Drawing.Point(688, 548)
$saveButton.Size = New-Object System.Drawing.Size(144, 34)
$form.Controls.Add($saveButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = "Close"
$closeButton.Location = New-Object System.Drawing.Point(842, 548)
$closeButton.Size = New-Object System.Drawing.Size(102, 34)
$form.Controls.Add($closeButton)

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
        "AI Guard Agent",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

function Change-AdminConsolePassword {
    $changed = Set-AdminConsolePassword `
        -PromptTitle "Change Admin Console Password" `
        -PromptMessage "Enter a new password for AI Guard Agent Admin Console."
    if ($changed) {
        $statusLabel.Text = "Admin console password updated."
        [System.Windows.Forms.MessageBox]::Show(
            "Admin console password was updated successfully.",
            "AI Guard Agent",
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
