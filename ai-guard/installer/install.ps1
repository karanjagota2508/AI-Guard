param(
    [int]$PiiPort = 8000,
    [string]$InstallRoot = "$env:ProgramFiles\AI Guard Agent",
    [switch]$SkipBuild,
    [string]$ChromeExtensionId = "kgfkgellcbbmadimiahbfndmfbhfobko",
    [string]$EdgeExtensionId = "kgfkgellcbbmadimiahbfndmfbhfobko",
    [string]$ChromeUpdateUrl = "http://127.0.0.1:48555/update.xml",
    [string]$EdgeUpdateUrl = "http://127.0.0.1:48555/update.xml",
    [string]$MinimumExtensionVersion = "",
    [switch]$BlockOtherExtensions,
    [string[]]$AllowedExtensionIds = @(),
    [switch]$RequirePrivateBrowsingGuard,
    [switch]$EnforceBrowserHostBlocklist,
    [switch]$DisallowExtensionDeveloperMode,
    [switch]$DisableBrowserDeveloperTools,
    [string]$BootstrapResultPath = ""
)

$ErrorActionPreference = "Stop"

$InstallerScriptRoot = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($env:ULTI_GUARD_INSTALLER_ROOT) {
    $env:ULTI_GUARD_INSTALLER_ROOT
} elseif ($PSCommandPath) {
    Split-Path $PSCommandPath -Parent
} else {
    (Get-Location).Path
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$script:InstallWarnings = New-Object System.Collections.Generic.List[string]

function Add-InstallWarning {
    param(
        [string]$Message
    )

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        [void]$script:InstallWarnings.Add($Message.Trim())
    }
}

function Get-InstallScope {
    if (Test-IsAdministrator) {
        return "machine"
    }

    return "current-user"
}

function Write-UltiGuardBootstrapResult {
    param(
        [string]$Status,
        [string]$Message,
        [string[]]$Warnings = @(),
        [string[]]$Errors = @(),
        [string]$InstallRootValue = "",
        [string]$Scope = "",
        [bool]$ChromeReady = $false,
        [bool]$EdgeReady = $false,
        [string]$PrivateModeStrategy = ""
    )

    if (-not $Scope) {
        $Scope = Get-InstallScope
    }

    $result = [ordered]@{
        status       = $Status
        message      = $Message
        install_root = $InstallRootValue
        scope        = $Scope
        chrome_ready = $ChromeReady
        edge_ready   = $EdgeReady
        private_mode_strategy = $PrivateModeStrategy
        warnings     = @($Warnings | Where-Object { $_ })
        errors       = @($Errors | Where-Object { $_ })
    }

    $json = $result | ConvertTo-Json -Depth 8 -Compress
    if ($BootstrapResultPath) {
        $parent = Split-Path $BootstrapResultPath -Parent
        if ($parent) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        [System.IO.File]::WriteAllText($BootstrapResultPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    }
    Write-Host "ULTI_GUARD_BOOTSTRAPPER_RESULT::$json"
}

function Test-RegistryKeyExists {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [string]$KeyPath
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $baseKey.OpenSubKey($KeyPath, $false)
        if ($key) {
            $key.Dispose()
            return $true
        }

        return $false
    } finally {
        $baseKey.Dispose()
    }
}

trap {
    $message = $_.Exception.Message
    Write-UltiGuardBootstrapResult `
        -Status "failed" `
        -Message $message `
        -Warnings $script:InstallWarnings.ToArray() `
        -Errors @($message) `
        -InstallRootValue $InstallRoot `
        -Scope (Get-InstallScope)
    exit 1
}

function New-RandomToken {
    $bytes = New-Object byte[] 48
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    return [Convert]::ToBase64String($bytes)
}

function Set-RegistryDefaultValue {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [string]$KeyPath,
        [string]$Value
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
    $key = $baseKey.CreateSubKey($KeyPath)
    $key.SetValue($null, $Value, [Microsoft.Win32.RegistryValueKind]::String)
    $key.Dispose()
    $baseKey.Dispose()
}

function Set-RegistryStringValue {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [string]$KeyPath,
        [string]$Name,
        [string]$Value
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
    $key = $baseKey.CreateSubKey($KeyPath)
    $key.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]::String)
    $key.Dispose()
    $baseKey.Dispose()
}

function Remove-RegistryKeyIfPresent {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [string]$KeyPath
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $baseKey.DeleteSubKeyTree($KeyPath, $false)
    } finally {
        $baseKey.Dispose()
    }
}

function New-ShortcutFile {
    param(
        [string]$ShortcutPath,
        [string]$TargetPath,
        [string]$Arguments = "",
        [string]$WorkingDirectory = "",
        [string]$Description = "",
        [string]$IconLocation = ""
    )

    $shortcutDir = Split-Path $ShortcutPath -Parent
    if ($shortcutDir) {
        New-Item -ItemType Directory -Force -Path $shortcutDir | Out-Null
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $TargetPath
    $shortcut.Arguments = $Arguments
    if ($WorkingDirectory) {
        $shortcut.WorkingDirectory = $WorkingDirectory
    }
    if ($Description) {
        $shortcut.Description = $Description
    }
    if ($IconLocation) {
        $shortcut.IconLocation = $IconLocation
    }
    $shortcut.Save()
}

function Get-ShortcutObject {
    param(
        [string]$ShortcutPath
    )

    if (-not (Test-Path $ShortcutPath)) {
        return $null
    }

    $shell = New-Object -ComObject WScript.Shell
    return $shell.CreateShortcut($ShortcutPath)
}

function Get-ChromeShortcutCandidatePaths {
    $searchRoots = @(
        (Join-Path $env:PUBLIC "Desktop"),
        [Environment]::GetFolderPath("Desktop"),
        (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs"),
        [Environment]::GetFolderPath("Programs"),
        (Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar")
    )

    $paths = @()
    foreach ($root in $searchRoots | Select-Object -Unique) {
        if (-not $root -or -not (Test-Path $root)) {
            continue
        }

        try {
            $paths += @(Get-ChildItem -Path $root -Filter *.lnk -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        } catch { }
    }

    return @($paths | Select-Object -Unique)
}

function Find-ChromeExecutable {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe"),
        (Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe")
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    return $null
}

function Get-ChromeMajorVersion {
    param(
        [string]$ChromeExecutablePath
    )

    if (-not $ChromeExecutablePath -or -not (Test-Path $ChromeExecutablePath)) {
        return $null
    }

    try {
        $productVersion = (Get-Item $ChromeExecutablePath).VersionInfo.ProductVersion
        if (-not $productVersion) {
            return $null
        }

        $majorVersion = 0
        if ([int]::TryParse(($productVersion -split '\.')[0], [ref]$majorVersion)) {
            return $majorVersion
        }
    } catch { }

    return $null
}

function Test-AzureAdJoined {
    try {
        $cdjPath = "SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo"
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $key = $baseKey.OpenSubKey($cdjPath)
        if ($key) {
            $subKeys = $key.GetSubKeyNames()
            $key.Dispose()
            $baseKey.Dispose()
            return $subKeys.Count -gt 0
        }
        $baseKey.Dispose()
    } catch { }
    return $false
}

function Test-ChromeEnterpriseEnrollmentConfigured {
    $token = Get-RegistryStringValue `
        -Hive ([Microsoft.Win32.RegistryHive]::LocalMachine) `
        -KeyPath "SOFTWARE\Policies\Google\Chrome" `
        -Name "CloudManagementEnrollmentToken"

    return -not [string]::IsNullOrWhiteSpace([string]$token)
}

function Test-ChromeSelfHostedManagedSupported {
    $computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $domainJoined = [bool]($computerSystem -and $computerSystem.PartOfDomain)
    return $domainJoined -or (Test-AzureAdJoined) -or (Test-ChromeEnterpriseEnrollmentConfigured)
}

function Set-ChromeShortcutLoadExtensionArgument {
    param(
        [string]$ShortcutPath,
        [string]$ChromeExecutablePath,
        [string]$ExtensionDirectory
    )

    $shortcut = Get-ShortcutObject -ShortcutPath $ShortcutPath
    if (-not $shortcut) {
        return $false
    }

    $currentTarget = [string]$shortcut.TargetPath
    if (-not $currentTarget) {
        return $false
    }

    $targetLeaf = [System.IO.Path]::GetFileName($currentTarget)
    if ($targetLeaf -notin @("chrome.exe", "chrome_proxy.exe")) {
        return $false
    }

    $existingArguments = [string]$shortcut.Arguments
    if ($existingArguments -match '--app-id=' -or $existingArguments -match '--app=') {
        return $false
    }

    $desiredArgument = "--load-extension=""$ExtensionDirectory"""
    $cleanArguments = ($existingArguments -replace '--load-extension=(?:"[^"]*"|\S+)', '').Trim()
    $finalArguments = if ($cleanArguments) { "$cleanArguments $desiredArgument" } else { $desiredArgument }

    $shortcut.TargetPath = $ChromeExecutablePath
    $shortcut.Arguments = $finalArguments.Trim()
    if (-not $shortcut.WorkingDirectory -or -not (Test-Path $shortcut.WorkingDirectory)) {
        $shortcut.WorkingDirectory = Split-Path $ChromeExecutablePath -Parent
    }
    $shortcut.Save()
    return $true
}

function Set-ChromeShortcutFallback {
    param(
        [string]$ChromeExecutablePath,
        [string]$ExtensionDirectory,
        [string]$StartMenuProgramsPath
    )

    if (-not $ChromeExecutablePath -or -not (Test-Path $ChromeExecutablePath)) {
        return @()
    }

    $patched = @()
    foreach ($shortcutPath in Get-ChromeShortcutCandidatePaths) {
        if (Set-ChromeShortcutLoadExtensionArgument -ShortcutPath $shortcutPath -ChromeExecutablePath $ChromeExecutablePath -ExtensionDirectory $ExtensionDirectory) {
            $patched += $shortcutPath
        }
    }

    $managedShortcut = Join-Path $StartMenuProgramsPath "Ulti Guard Google Chrome.lnk"
    New-ShortcutFile `
        -ShortcutPath $managedShortcut `
        -TargetPath $ChromeExecutablePath `
        -Arguments "--load-extension=""$ExtensionDirectory""" `
        -WorkingDirectory (Split-Path $ChromeExecutablePath -Parent) `
        -Description "Launch Google Chrome with Ulti Guard protection."

    if ($patched -notcontains $managedShortcut) {
        $patched += $managedShortcut
    }

    return @($patched | Select-Object -Unique)
}

function Test-ChromeShortcutFallbackPresence {
    param(
        [string]$ExtensionDirectory,
        [string]$StartMenuProgramsPath
    )

    if (-not $ExtensionDirectory -or -not (Test-Path $ExtensionDirectory)) {
        return $false
    }

    $candidateShortcuts = @(
        (Join-Path $StartMenuProgramsPath "Ulti Guard Google Chrome.lnk")
    ) + (Get-ChromeShortcutCandidatePaths)

    foreach ($shortcutPath in @($candidateShortcuts | Select-Object -Unique)) {
        $shortcut = Get-ShortcutObject -ShortcutPath $shortcutPath
        if (-not $shortcut) {
            continue
        }

        $targetLeaf = [System.IO.Path]::GetFileName([string]$shortcut.TargetPath)
        if ($targetLeaf -notin @("chrome.exe", "chrome_proxy.exe")) {
            continue
        }

        $arguments = [string]$shortcut.Arguments
        if ($arguments -match [regex]::Escape($ExtensionDirectory)) {
            return $true
        }
    }

    return $false
}

function Clear-ChromeUnsupportedManagedPolicyResidue {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [string]$ExtensionId,
        [string]$BlockedInstallMessage = "Only company-approved browser extensions are allowed."
    )

    Remove-ManagedExtensionPolicy -Hive $Hive -Browser "Chrome" -ExtensionId $ExtensionId

    $settings = Get-ExtensionSettingsValue -Hive $Hive -Browser "Chrome"
    if ($settings.ContainsKey("*")) {
        $wildcardSetting = $settings["*"]
        $wildcardInstallMode = [string]$wildcardSetting["installation_mode"]
        $wildcardBlockedMessage = [string]$wildcardSetting["blocked_install_message"]

        if ($wildcardInstallMode -eq "blocked" -and $wildcardBlockedMessage -eq $BlockedInstallMessage) {
            $settings.Remove("*")
            Save-ExtensionSettingsValue -Hive $Hive -Browser "Chrome" -Settings $settings
        }
    }

    $policyRoot = Get-BrowserPolicyRoot -Browser "Chrome"
    if ((Get-RegistryDwordValue -Hive $Hive -KeyPath $policyRoot -Name "ExtensionDeveloperModeSettings") -eq 1) {
        Remove-RegistryValueIfPresent -Hive $Hive -KeyPath $policyRoot -Name "ExtensionDeveloperModeSettings"
    }
    if ((Get-RegistryDwordValue -Hive $Hive -KeyPath $policyRoot -Name "DeveloperToolsAvailability") -eq 2) {
        Remove-RegistryValueIfPresent -Hive $Hive -KeyPath $policyRoot -Name "DeveloperToolsAvailability"
    }

    foreach ($keyPath in @(
        (Join-Path $policyRoot "ExtensionInstallForcelist"),
        (Get-MandatoryPrivateBrowsingPolicyPath -Browser "Chrome")
    )) {
        if ((Get-RegistryStringListValues -Hive $Hive -KeyPath $keyPath).Count -eq 0) {
            Remove-RegistryKeyIfPresent -Hive $Hive -KeyPath $keyPath
        }
    }
}

. (Join-Path $InstallerScriptRoot "scripts\browser-policies.ps1")

function Test-LocalExtensionUpdateUrl {
    param(
        [string]$UpdateUrl
    )

    if ([string]::IsNullOrWhiteSpace($UpdateUrl)) {
        return $false
    }

    try {
        $uri = [Uri]$UpdateUrl
        return $uri.IsLoopback -and $uri.Scheme -in @("http", "https")
    } catch {
        return $false
    }
}

function Assert-ExtensionDeploymentMetadata {
    param(
        [string]$ChromeId,
        [string]$EdgeId,
        [string]$ChromeDeploymentUrl,
        [string]$EdgeDeploymentUrl
    )

    foreach ($item in @(
        @{ Label = "Chrome extension ID"; Value = $ChromeId },
        @{ Label = "Edge extension ID"; Value = $EdgeId },
        @{ Label = "Chrome update URL"; Value = $ChromeDeploymentUrl },
        @{ Label = "Edge update URL"; Value = $EdgeDeploymentUrl }
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$item.Value)) {
            throw "$($item.Label) is required."
        }
    }

    foreach ($url in @($ChromeDeploymentUrl, $EdgeDeploymentUrl)) {
        if ($url -notmatch '^https?://') {
            throw "Browser deployment requires an HTTP or HTTPS update URL."
        }

        if ($url -match '^http://' -and -not (Test-LocalExtensionUpdateUrl -UpdateUrl $url)) {
            throw "HTTP update URLs are only allowed for the local Ulti Guard daemon on 127.0.0.1 or localhost."
        }
    }
}

function Test-ForceInstalledPolicy {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [ValidateSet("Chrome", "Edge")]
        [string]$Browser,
        [string]$ExtensionId
    )

    $settings = Get-ExtensionSettingsValue -Hive $Hive -Browser $Browser
    if (-not $settings.ContainsKey($ExtensionId)) {
        return $false
    }

    return [string]$settings[$ExtensionId]["installation_mode"] -eq "force_installed"
}

function Test-AdminConsoleSelfTest {
    param(
        [string]$AdminConsolePath,
        [string]$ConfigPath
    )

    if (-not (Test-Path $AdminConsolePath) -or -not (Test-Path $ConfigPath)) {
        return $false
    }

    try {
        $process = Start-Process `
            -FilePath $AdminConsolePath `
            -ArgumentList @("--self-test", "--config", $ConfigPath) `
            -WindowStyle Hidden `
            -Wait `
            -PassThru
        return $process.ExitCode -eq 0
    } catch {
        return $false
    }
}

function Get-InstallReadinessState {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [string]$ChromeExtensionId,
        [string]$EdgeExtensionId,
        [string]$AdminConsolePath,
        [string]$ConfigPath,
        [string]$ExtensionDirectory,
        [string]$StartMenuProgramsPath
    )

    $edgeMandatoryEntries = Get-RegistryStringListValues `
        -Hive $Hive `
        -KeyPath (Get-MandatoryPrivateBrowsingPolicyPath -Browser "Edge")
    $chromePolicyReady = Test-ForceInstalledPolicy -Hive $Hive -Browser "Chrome" -ExtensionId $ChromeExtensionId
    $chromeShortcutFallbackReady = Test-ChromeShortcutFallbackPresence `
        -ExtensionDirectory $ExtensionDirectory `
        -StartMenuProgramsPath $StartMenuProgramsPath

    return [ordered]@{
        chrome_policy_ready = $chromePolicyReady
        chrome_shortcut_fallback_ready = $chromeShortcutFallbackReady
        chrome_ready = ($chromePolicyReady -or $chromeShortcutFallbackReady)
        edge_ready = (Test-ForceInstalledPolicy -Hive $Hive -Browser "Edge" -ExtensionId $EdgeExtensionId)
        admin_console_ready = (Test-AdminConsoleSelfTest -AdminConsolePath $AdminConsolePath -ConfigPath $ConfigPath)
        chrome_private_ready = ((Get-RegistryDwordValue -Hive $Hive -KeyPath (Get-BrowserPolicyRoot -Browser "Chrome") -Name "IncognitoModeAvailability") -ne 1)
        edge_private_ready = @($edgeMandatoryEntries) -contains $EdgeExtensionId
        private_mode_strategy = if ($chromeShortcutFallbackReady -and -not $chromePolicyReady) {
            "chrome_incognito_enabled_shortcut_fallback;edge_inprivate_required"
        } else {
            "chrome_incognito_enabled;edge_inprivate_required"
        }
    }
}

function Get-InstallVerificationFailures {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [string]$InstallRootValue,
        [string]$DaemonBinaryPath,
        [string]$ConfigPath,
        [string]$ExtensionCrxPath,
        [string]$AdminConsolePath,
        [string]$AdminShortcutPath,
        [string]$ChromeExtensionId,
        [string]$EdgeExtensionId,
        $DaemonHealthResponse,
        $ReadinessState
    )

    $failures = New-Object System.Collections.Generic.List[string]

    foreach ($requiredPath in @(
        @{ Label = "install root"; Path = $InstallRootValue },
        @{ Label = "daemon binary"; Path = $DaemonBinaryPath },
        @{ Label = "runtime config"; Path = $ConfigPath },
        @{ Label = "packaged extension"; Path = $ExtensionCrxPath },
        @{ Label = "admin console"; Path = $AdminConsolePath },
        @{ Label = "Start Menu shortcut"; Path = $AdminShortcutPath }
    )) {
        if (-not (Test-Path $requiredPath.Path)) {
            [void]$failures.Add("Missing $($requiredPath.Label) at $($requiredPath.Path).")
        }
    }

    if (-not $DaemonHealthResponse -or $DaemonHealthResponse.StatusCode -lt 200 -or $DaemonHealthResponse.StatusCode -ge 300) {
        [void]$failures.Add("The Ulti Guard daemon health endpoint did not report success.")
    }

    if (-not $ReadinessState.admin_console_ready) {
        [void]$failures.Add("The Ulti Guard admin console self-test failed.")
    }

    if (-not $ReadinessState.chrome_ready) {
        [void]$failures.Add("Chrome Ulti Guard registration is missing; neither force-installed policy nor shortcut fallback was detected.")
    }

    if (-not $ReadinessState.edge_ready) {
        [void]$failures.Add("Edge managed extension policy for Ulti Guard was not registered as force-installed.")
    }

    if (-not (Test-RegistryKeyExists -Hive $Hive -KeyPath "SOFTWARE\Google\Chrome\Extensions\$ChromeExtensionId")) {
        [void]$failures.Add("Chrome extension registry entry for Ulti Guard is missing.")
    }

    if (-not (Test-RegistryKeyExists -Hive $Hive -KeyPath "SOFTWARE\Microsoft\Edge\Extensions\$EdgeExtensionId")) {
        [void]$failures.Add("Edge extension registry entry for Ulti Guard is missing.")
    }

    if (-not $ReadinessState.chrome_private_ready) {
        [void]$failures.Add("Chrome Incognito is still disabled by policy.")
    }

    if (-not $ReadinessState.edge_private_ready) {
        [void]$failures.Add("Edge InPrivate mandatory extension policy is missing.")
    }

    foreach ($nativeHostKey in @(
        "SOFTWARE\Google\Chrome\NativeMessagingHosts\com.wininfosoft.ai_guard",
        "SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.wininfosoft.ai_guard"
    )) {
        if (-not (Test-RegistryKeyExists -Hive $Hive -KeyPath $nativeHostKey)) {
            [void]$failures.Add("Native host registration is missing at $nativeHostKey.")
        }
    }

    return $failures
}

function Find-PythonExecutable {
    $candidates = @()

    $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
    if ($pyLauncher) {
        try {
            $pyPath = & $pyLauncher.Source -3.14 -c "import sys; print(sys.executable)" 2>$null
            if ($LASTEXITCODE -eq 0 -and $pyPath) {
                $candidates += $pyPath.Trim()
            }
        } catch { }
        try {
            $pyPath = & $pyLauncher.Source -3 -c "import sys; print(sys.executable)" 2>$null
            if ($LASTEXITCODE -eq 0 -and $pyPath) {
                $candidates += $pyPath.Trim()
            }
        } catch { }
    }

    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCmd) {
        $candidates += $pythonCmd.Source
    }

    $candidates = @($candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique)
    if (-not $candidates) {
        throw "Could not locate a usable Python interpreter."
    }

    return $candidates[0]
}

function Stop-LocalProcessByPort {
    param(
        [int]$Port,
        [string]$ExpectedProcessName
    )

    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $listener) {
        return
    }

    $process = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
    if ($process -and $process.ProcessName -eq $ExpectedProcessName) {
        Stop-Process -Id $process.Id -Force
        Start-Sleep -Seconds 2
    }
}

function Stop-PiiServiceIfPresent {
    param(
        [int]$Port,
        [string]$InstallRoot
    )

    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/" -TimeoutSec 3
        if ($response.StatusCode -ne 200) {
            return
        }
    } catch {
        return
    }

    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $listener) {
        return
    }

    $owner = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
    if (-not $owner -or $owner.ProcessName -ne "python") {
        return
    }

    $ownerPath = $owner.Path
    if ($ownerPath -and $ownerPath.StartsWith($InstallRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return
    }

    Stop-Process -Id $owner.Id -Force
    Start-Sleep -Seconds 2
}

function Stop-ProcessesByCommandLinePattern {
    param(
        [string[]]$Patterns
    )

    if (-not $Patterns -or $Patterns.Count -eq 0) {
        return
    }

    $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -ieq "powershell.exe" -and $_.CommandLine
    }

    foreach ($process in $processes) {
        $commandLine = [string]$process.CommandLine
        if ($Patterns | Where-Object { $commandLine -like "*$_*" }) {
            Invoke-CimMethod -InputObject $process -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null
        }
    }

    Start-Sleep -Seconds 1
}

function Stop-ProcessesInstalledUnderRoots {
    param(
        [string[]]$Roots
    )

    $resolvedRoots = @(
        $Roots |
            Where-Object { $_ -and (Test-Path $_) } |
            ForEach-Object {
                try {
                    (Resolve-Path -LiteralPath $_ -ErrorAction Stop).Path.TrimEnd('\')
                } catch {
                    $null
                }
            } |
            Where-Object { $_ } |
            Select-Object -Unique
    )

    if ($resolvedRoots.Count -eq 0) {
        return
    }

    $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath
    }

    foreach ($process in $processes) {
        $executablePath = [string]$process.ExecutablePath
        if (-not $executablePath) {
            continue
        }

        foreach ($root in $resolvedRoots) {
            if ($executablePath.StartsWith($root + "\", [System.StringComparison]::OrdinalIgnoreCase) -or
                [string]::Equals($executablePath, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
                try {
                    Invoke-CimMethod -InputObject $process -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null
                } catch {
                }
                break
            }
        }
    }

    Start-Sleep -Seconds 2
}

function Restart-BrowserIfRunning {
    param(
        [string]$ProcessName,
        [switch]$SkipRelaunch
    )

    $processes = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID })
    if (-not $processes -or $processes.Count -eq 0) {
        return $false
    }

    $launchPath = $null
    foreach ($process in $processes) {
        if (-not $launchPath -and $process.Path -and (Test-Path $process.Path)) {
            $launchPath = $process.Path
        }

        try {
            if ($process.MainWindowHandle -ne 0) {
                $null = $process.CloseMainWindow()
            }
        } catch { }
    }

    Start-Sleep -Seconds 3

    foreach ($process in $processes) {
        try {
            if (-not $process.HasExited) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }

    Start-Sleep -Seconds 2

    if ($launchPath -and -not $SkipRelaunch) {
        Start-Process -FilePath $launchPath | Out-Null
    }

    return $true
}

function Wait-ForHttpOk {
    param(
        [string]$Url,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 5
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
                return $response
            }
        } catch { }
        Start-Sleep -Seconds 2
    }

    throw "Timed out waiting for $Url"
}

$isAdmin = Test-IsAdministrator

if (-not $isAdmin -and $InstallRoot.StartsWith($env:ProgramFiles, [System.StringComparison]::OrdinalIgnoreCase)) {
    $InstallRoot = Join-Path $env:LOCALAPPDATA "AI Guard Agent"
}

$registryHive = if ($isAdmin) { [Microsoft.Win32.RegistryHive]::LocalMachine } else { [Microsoft.Win32.RegistryHive]::CurrentUser }

$repoRoot = Split-Path $InstallerScriptRoot -Parent
$daemonProject = Join-Path $repoRoot "daemon"
$extensionManifestPath = Join-Path $repoRoot "extension\manifest.json"
$daemonBinarySource = Join-Path $daemonProject "target\release\ai-guard-daemon.exe"
$piiBackendSource = Join-Path (Split-Path $repoRoot -Parent) "PII_agent\backend"
$brandingSource = Join-Path $repoRoot "branding"
$distDir = Join-Path $repoRoot "installer\dist"
$distDaemonBinary = Join-Path $distDir "ai-guard-daemon.exe"
$distCrx = Join-Path $distDir "ai-guard-extension.crx"
$distChromeStoreZip = Join-Path $distDir "ai-guard-extension-chrome-store.zip"
$distEdgeStoreZip = Join-Path $distDir "ai-guard-extension-edge-store.zip"
$distAdminConsoleDir = Join-Path $distDir "admin-console"
$distAdminConsoleExe = Join-Path $distAdminConsoleDir "AI-Guard-Admin-Console.exe"
$token = New-RandomToken
$serviceName = "AIGuardAgent"
$extensionManifest = Get-Content -Path $extensionManifestPath -Raw | ConvertFrom-Json
$extensionVersion = [string]$extensionManifest.version
$claudeWebHosts = @("claude.ai", "claude.com")
$allowedExtensionIds = @($AllowedExtensionIds + @($ChromeExtensionId, $EdgeExtensionId) | Where-Object { $_ } | Select-Object -Unique)
$chromeOrigin = "chrome-extension://$ChromeExtensionId/"
$edgeOrigin = "chrome-extension://$EdgeExtensionId/"
$bundledPythonExecutable = Join-Path $distDir "python-runtime\python.exe"
$wheelhouseDir = Join-Path $distDir "pii-wheelhouse"
$pythonExecutable = if (Test-Path $bundledPythonExecutable) { $bundledPythonExecutable } else { Find-PythonExecutable }
$restartedBrowsers = @()
$chromeExecutablePath = Find-ChromeExecutable
$chromeManagedPolicySupported = if ($isAdmin) { Test-ChromeSelfHostedManagedSupported } else { $false }

Assert-ExtensionDeploymentMetadata `
    -ChromeId $ChromeExtensionId `
    -EdgeId $EdgeExtensionId `
    -ChromeDeploymentUrl $ChromeUpdateUrl `
    -EdgeDeploymentUrl $EdgeUpdateUrl

Stop-LocalProcessByPort -Port 48555 -ExpectedProcessName "ai-guard-daemon"

if (-not $SkipBuild) {
    cargo build --release --manifest-path (Join-Path $daemonProject "Cargo.toml")
    New-Item -ItemType Directory -Force -Path $distDir | Out-Null
    Copy-Item -Path $daemonBinarySource -Destination $distDaemonBinary -Force
    & (Join-Path $InstallerScriptRoot "scripts\package-extension.ps1") `
        -OutputPath $distCrx `
        -ChromeStoreZipPath $distChromeStoreZip `
        -EdgeStoreZipPath $distEdgeStoreZip
    & (Join-Path $InstallerScriptRoot "scripts\publish-admin-console.ps1") -OutputPath $distAdminConsoleDir
}

$daemonBinaryToInstall = $null
foreach ($candidate in @($daemonBinarySource, $distDaemonBinary)) {
    if ($candidate -and (Test-Path $candidate)) {
        $daemonBinaryToInstall = $candidate
        break
    }
}

if (-not $daemonBinaryToInstall) {
    throw "Missing daemon binary. Expected either $daemonBinarySource or $distDaemonBinary. Run without -SkipBuild on a build machine first, or copy a prebuilt daemon binary into installer\\dist\\ai-guard-daemon.exe."
}

if (-not (Test-Path $distCrx)) {
    throw "Missing packaged extension at $distCrx. Run without -SkipBuild or package it first."
}

foreach ($storePackage in @($distChromeStoreZip, $distEdgeStoreZip)) {
    if (-not (Test-Path $storePackage)) {
        throw "Missing store submission package at $storePackage. Run without -SkipBuild or package it first."
    }
}

if (-not (Test-Path $distAdminConsoleExe)) {
    throw "Missing published admin console at $distAdminConsoleExe. Run without -SkipBuild or publish it first."
}

$installConfigDir = Join-Path $InstallRoot "config"
$installDistDir = Join-Path $InstallRoot "dist"
$installLogsDir = Join-Path $InstallRoot "logs"
$installManifestDir = Join-Path $InstallRoot "manifests"
$installPiiDir = Join-Path $InstallRoot "pii-agent"
$installScriptsDir = Join-Path $InstallRoot "scripts"
$installDesktopDir = Join-Path $InstallRoot "desktop"
$installBrandingDir = Join-Path $InstallRoot "branding"
$installAdminConsoleDir = Join-Path $InstallRoot "admin-console"
$installedBinary = Join-Path $InstallRoot "ai-guard-daemon.exe"
$installedConfig = Join-Path $installConfigDir "ai-guard.json"
$installedCrx = Join-Path $installDistDir "ai-guard-extension.crx"
$chromeNativeManifest = Join-Path $installManifestDir "chrome-native-host.json"
$edgeNativeManifest = Join-Path $installManifestDir "edge-native-host.json"
$launcherScript = Join-Path $InstallRoot "launch-daemon.ps1"
$piiStdoutLog = Join-Path $installLogsDir "pii-agent.stdout.log"
$piiStderrLog = Join-Path $installLogsDir "pii-agent.stderr.log"
$patchClaudeDesktopScript = Join-Path $installScriptsDir "patch-claude-desktop.ps1"
$syncClaudeStoreRuntimeScript = Join-Path $installScriptsDir "sync-claude-store-runtime.ps1"
$browserPoliciesScript = Join-Path $installScriptsDir "browser-policies.ps1"
$applyBrowserPoliciesScript = Join-Path $installScriptsDir "apply-browser-policies-from-config.ps1"
$installedClaudeHook = Join-Path $installDesktopDir "claude-desktop-hook.cjs"
$installedClaudeUiaGuard = Join-Path $installDesktopDir "claude-desktop-uia-guard.ps1"
$installedBrandIcon = Join-Path $installBrandingDir "logo.ico"
$installedAdminConsoleExe = Join-Path $installAdminConsoleDir "AI-Guard-Admin-Console.exe"
$claudeLauncherScript = Join-Path $InstallRoot "launch-claude-desktop.ps1"
$claudeDesktopGuardRunValueName = "UltiGuardClaudeDesktopGuard"
$legacyAdminConsoleScript = Join-Path $installScriptsDir "admin-console.ps1"
$legacyBrowserTestModeScript = Join-Path $installScriptsDir "prepare-browser-test-mode.ps1"
$legacyAdminConsoleLauncher = Join-Path $InstallRoot "launch-admin-console.ps1"
$legacyBrowserTestModeLauncher = Join-Path $InstallRoot "launch-browser-test-mode.ps1"
$startMenuPrograms = if ($isAdmin) {
    Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs"
} else {
    [Environment]::GetFolderPath("Programs")
}
$adminConsoleShortcut = Join-Path $startMenuPrograms "Ulti Guard Admin Console.lnk"
$legacyAdminConsoleShortcuts = @(
    (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Ulti Guard Admin Console.lnk"),
    (Join-Path ([Environment]::GetFolderPath("Programs")) "Ulti Guard Admin Console.lnk"),
    (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\AI Guard Agent Admin Console.lnk"),
    (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Ulti Guard Agent Admin Console.lnk"),
    (Join-Path ([Environment]::GetFolderPath("Programs")) "AI Guard Agent Admin Console.lnk"),
    (Join-Path ([Environment]::GetFolderPath("Programs")) "Ulti Guard Agent Admin Console.lnk")
)
$legacyBrowserTestModeShortcuts = @(
    (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Ulti Guard Browser Test Mode.lnk"),
    (Join-Path ([Environment]::GetFolderPath("Programs")) "Ulti Guard Browser Test Mode.lnk")
)

$knownInstallRoots = @(
    $InstallRoot,
    "$env:ProgramFiles\AI Guard Agent",
    "$env:ProgramFiles\Ulti Guard Agent",
    (Join-Path $env:LOCALAPPDATA "AI Guard Agent"),
    (Join-Path $env:LOCALAPPDATA "Ulti Guard Agent")
) | Select-Object -Unique

Stop-LocalProcessByPort -Port 48555 -ExpectedProcessName "ai-guard-daemon"
Stop-PiiServiceIfPresent -Port $PiiPort -InstallRoot $InstallRoot
Stop-ProcessesByCommandLinePattern -Patterns @(
    "claude-desktop-uia-guard.ps1",
    "launch-daemon.ps1",
    "launch-claude-desktop.ps1"
)
Stop-ProcessesInstalledUnderRoots -Roots $knownInstallRoots

if ($isAdmin) {
    $existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($existingService) {
        try {
            Stop-Service -Name $serviceName -ErrorAction SilentlyContinue
        } catch {
        }
        Start-Sleep -Seconds 2
    }
}

New-Item -ItemType Directory -Force -Path $InstallRoot, $installConfigDir, $installDistDir, $installLogsDir, $installManifestDir, $installPiiDir, $installScriptsDir, $installDesktopDir, $installBrandingDir, $installAdminConsoleDir | Out-Null
Copy-Item -Path $daemonBinaryToInstall -Destination $installedBinary -Force
Copy-Item -Path $distCrx -Destination $installedCrx -Force
Copy-Item -Path (Join-Path $InstallerScriptRoot "scripts\patch-claude-desktop.ps1") -Destination $patchClaudeDesktopScript -Force
Copy-Item -Path (Join-Path $InstallerScriptRoot "scripts\sync-claude-store-runtime.ps1") -Destination $syncClaudeStoreRuntimeScript -Force
Copy-Item -Path (Join-Path $InstallerScriptRoot "scripts\browser-policies.ps1") -Destination $browserPoliciesScript -Force
Copy-Item -Path (Join-Path $InstallerScriptRoot "scripts\apply-browser-policies-from-config.ps1") -Destination $applyBrowserPoliciesScript -Force
Copy-Item -Path (Join-Path $repoRoot "desktop\claude-desktop-hook.cjs") -Destination $installedClaudeHook -Force
Copy-Item -Path (Join-Path $repoRoot "desktop\claude-desktop-uia-guard.ps1") -Destination $installedClaudeUiaGuard -Force
if (Test-Path $brandingSource) {
    Copy-Item -Path (Join-Path $brandingSource "*") -Destination $installBrandingDir -Recurse -Force
}
foreach ($legacyFile in @(
    $legacyAdminConsoleScript,
    $legacyBrowserTestModeScript,
    $legacyAdminConsoleLauncher,
    $legacyBrowserTestModeLauncher
)) {
    if ($legacyFile -and (Test-Path $legacyFile)) {
        Remove-Item -Path $legacyFile -Force -ErrorAction SilentlyContinue
    }
}
$installedExtensionDir = Join-Path $InstallRoot "extension"
if (Test-Path $installedExtensionDir) {
    Remove-Item -Path $installedExtensionDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $installedExtensionDir | Out-Null
Copy-Item -Path (Join-Path $repoRoot "extension\\*") -Destination $installedExtensionDir -Recurse -Force
if (Test-Path $installAdminConsoleDir) {
    Remove-Item -Path $installAdminConsoleDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $installAdminConsoleDir | Out-Null
Copy-Item -Path (Join-Path $distAdminConsoleDir "*") -Destination $installAdminConsoleDir -Recurse -Force

$venvPython = @(& (Join-Path $InstallerScriptRoot "scripts\provision-pii-agent.ps1") `
    -SourceBackendDir $piiBackendSource `
    -InstallDir $installPiiDir `
    -PythonExecutable $pythonExecutable `
    -WheelhousePath $wheelhouseDir)
$venvPython = ($venvPython | Select-Object -Last 1).Trim()

& (Join-Path $InstallerScriptRoot "scripts\write-config.ps1") `
    -OutputPath $installedConfig `
    -PiiPort $PiiPort `
    -AuthToken $token `
    -ExtensionCrxPath $installedCrx `
    -ChromeExtensionId $ChromeExtensionId `
    -EdgeExtensionId $EdgeExtensionId `
    -ChromeUpdateUrl $ChromeUpdateUrl `
    -EdgeUpdateUrl $EdgeUpdateUrl `
    -ExtensionVersion $extensionVersion `
    -LogDirectory $installLogsDir `
    -PiiExecutablePath $venvPython `
    -PiiWorkingDirectory (Join-Path $installPiiDir "backend") `
    -PiiStdoutLogPath $piiStdoutLog `
    -PiiStderrLogPath $piiStderrLog `
    -ClaudeWebHosts $claudeWebHosts

$effectiveConfig = Get-Content -Path $installedConfig -Raw | ConvertFrom-Json

& $patchClaudeDesktopScript `
    -ConfigPath $installedConfig `
    -HookSourcePath $installedClaudeHook

& $syncClaudeStoreRuntimeScript `
    -ConfigPath $installedConfig `
    -HookSourcePath $installedClaudeHook `
    -TargetRoot (Join-Path $InstallRoot "claude-desktop") `
    -LauncherScriptPath $claudeLauncherScript `
    -PatchScriptPath $patchClaudeDesktopScript `
    -UiaGuardScriptPath $installedClaudeUiaGuard

$chromeNativeManifestObject = @{
    name = "com.wininfosoft.ai_guard"
    description = "Ulti Guard native bootstrap host"
    path = $installedBinary
    type = "stdio"
    allowed_origins = @($chromeOrigin)
}

$edgeNativeManifestObject = @{
    name = "com.wininfosoft.ai_guard"
    description = "Ulti Guard native bootstrap host"
    path = $installedBinary
    type = "stdio"
    allowed_origins = @($edgeOrigin)
}

$chromeNativeManifestJson = $chromeNativeManifestObject | ConvertTo-Json -Depth 4
$edgeNativeManifestJson = $edgeNativeManifestObject | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($chromeNativeManifest, $chromeNativeManifestJson, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($edgeNativeManifest, $edgeNativeManifestJson, (New-Object System.Text.UTF8Encoding($false)))

Set-RegistryDefaultValue -Hive $registryHive -KeyPath "SOFTWARE\Google\Chrome\NativeMessagingHosts\com.wininfosoft.ai_guard" -Value $chromeNativeManifest
Set-RegistryDefaultValue -Hive $registryHive -KeyPath "SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.wininfosoft.ai_guard" -Value $edgeNativeManifest
Set-RegistryStringValue -Hive $registryHive -KeyPath "SOFTWARE\Google\Chrome\Extensions\$ChromeExtensionId" -Name "update_url" -Value $ChromeUpdateUrl
Set-RegistryStringValue -Hive $registryHive -KeyPath "SOFTWARE\Microsoft\Edge\Extensions\$EdgeExtensionId" -Name "update_url" -Value $EdgeUpdateUrl

if ($isAdmin) {
    Set-ManagedExtensionPolicy `
        -Hive $registryHive `
        -Browser "Chrome" `
        -ExtensionId $ChromeExtensionId `
        -UpdateUrl $ChromeUpdateUrl `
        -MinimumVersionRequired $MinimumExtensionVersion `
        -BlockOtherExtensions:$BlockOtherExtensions `
        -AllowedExtensionIds $allowedExtensionIds `
        -RequirePrivateBrowsingGuard:$RequirePrivateBrowsingGuard `
        -DisallowExtensionDeveloperMode:$DisallowExtensionDeveloperMode `
        -DisableDeveloperTools:$DisableBrowserDeveloperTools

    if ($EnforceBrowserHostBlocklist) {
        Set-AIGuardBrowserHostBlocklistPolicy `
            -Hive $registryHive `
            -Browser "Chrome" `
            -Hosts @($effectiveConfig.blocking.browser_hosts)
    }

    Set-AIGuardPrivateBrowsingPolicy `
        -Hive $registryHive `
        -Browser "Chrome"

    Set-ManagedExtensionPolicy `
        -Hive $registryHive `
        -Browser "Edge" `
        -ExtensionId $EdgeExtensionId `
        -UpdateUrl $EdgeUpdateUrl `
        -MinimumVersionRequired $MinimumExtensionVersion `
        -BlockOtherExtensions:$BlockOtherExtensions `
        -AllowedExtensionIds $allowedExtensionIds `
        -RequirePrivateBrowsingGuard:$true `
        -DisallowExtensionDeveloperMode:$DisallowExtensionDeveloperMode `
        -DisableDeveloperTools:$DisableBrowserDeveloperTools

    if ($EnforceBrowserHostBlocklist) {
        Set-AIGuardBrowserHostBlocklistPolicy `
            -Hive $registryHive `
            -Browser "Edge" `
            -Hosts @($effectiveConfig.blocking.browser_hosts)
    }

    Set-AIGuardPrivateBrowsingPolicy `
        -Hive $registryHive `
        -Browser "Edge"

    if (-not $chromeManagedPolicySupported) {
        $chromeShortcutFallbackPaths = @(Set-ChromeShortcutFallback `
            -ChromeExecutablePath $chromeExecutablePath `
            -ExtensionDirectory $installedExtensionDir `
            -StartMenuProgramsPath $startMenuPrograms)

        if ($chromeShortcutFallbackPaths.Count -gt 0) {
            Add-InstallWarning "Chrome is using the Ulti Guard managed shortcut fallback on this Windows device."
        } else {
            Add-InstallWarning "Chrome policy install is limited on this Windows device and no Ulti Guard Chrome shortcut fallback could be created."
        }
    }
}

Stop-LocalProcessByPort -Port 48555 -ExpectedProcessName "ai-guard-daemon"
Stop-PiiServiceIfPresent -Port $PiiPort -InstallRoot $InstallRoot

if ($isAdmin) {
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        Stop-Service -Name $serviceName -ErrorAction SilentlyContinue
        $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
        if ($service) {
            $service | Invoke-CimMethod -MethodName Delete -ErrorAction SilentlyContinue | Out-Null
        }
        Start-Sleep -Seconds 2
    }

    $binaryPath = "`"$installedBinary`" --config `"$installedConfig`" service"
    New-Service `
        -Name $serviceName `
        -BinaryPathName $binaryPath `
        -DisplayName "Ulti Guard" `
        -Description "Protects Claude sessions, scans prompts for PII, and blocks competing LLM tools." `
        -StartupType Automatic | Out-Null

    Start-Service -Name $serviceName

} else {
    $launcherScriptContent = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$config = Get-Content '$installedConfig' -Raw | ConvertFrom-Json
`$listenPort = ([string]`$config.listen_address).Split(':')[-1]
`$listener = Get-NetTCPConnection -LocalPort `$listenPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if (`$listener) { exit 0 }
Start-Process -FilePath '$installedBinary' -ArgumentList '--config `"$installedConfig`" run' -WindowStyle Hidden
"@
    [System.IO.File]::WriteAllText($launcherScript, $launcherScriptContent, (New-Object System.Text.UTF8Encoding($false)))
    Set-RegistryStringValue -Hive $registryHive -KeyPath "SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "AIGuardAgent" -Value "powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File `"$launcherScript`""
    Start-Process -FilePath $installedBinary -ArgumentList "--config `"$installedConfig`" run" -WindowStyle Hidden | Out-Null
}

$claudeDesktopGuardArguments = @(
    "-NoProfile",
    "-ExecutionPolicy", "RemoteSigned",
    "-STA",
    "-File", $installedClaudeUiaGuard,
    "-ConfigPath", $installedConfig,
    "-PollMs", "300"
)
$claudeDesktopGuardRunCommand = "powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -STA -WindowStyle Hidden -File `"$installedClaudeUiaGuard`" -ConfigPath `"$installedConfig`" -PollMs 300"
Set-RegistryStringValue `
    -Hive $registryHive `
    -KeyPath "SOFTWARE\Microsoft\Windows\CurrentVersion\Run" `
    -Name $claudeDesktopGuardRunValueName `
    -Value $claudeDesktopGuardRunCommand
Start-Process -FilePath "powershell.exe" -ArgumentList $claudeDesktopGuardArguments -WindowStyle Hidden | Out-Null

foreach ($legacyShortcut in $legacyAdminConsoleShortcuts | Select-Object -Unique) {
    if ($legacyShortcut -and (Test-Path $legacyShortcut)) {
        Remove-Item -Path $legacyShortcut -Force -ErrorAction SilentlyContinue
    }
}
foreach ($legacyShortcut in $legacyBrowserTestModeShortcuts | Select-Object -Unique) {
    if ($legacyShortcut -and (Test-Path $legacyShortcut)) {
        Remove-Item -Path $legacyShortcut -Force -ErrorAction SilentlyContinue
    }
}

New-ShortcutFile `
    -ShortcutPath $adminConsoleShortcut `
    -TargetPath $installedAdminConsoleExe `
    -Arguments "--config `"$installedConfig`"" `
    -WorkingDirectory $installAdminConsoleDir `
    -Description "Open the Ulti Guard Admin Console." `
    -IconLocation $installedBrandIcon

Start-Sleep -Seconds 3

$daemonHealth = Wait-ForHttpOk -Url "http://127.0.0.1:48555/healthz" -TimeoutSeconds 60
$piiHealth = Wait-ForHttpOk -Url "http://127.0.0.1:$PiiPort/health" -TimeoutSeconds 240

if ($isAdmin) {
    $chromeWasRunning = Restart-BrowserIfRunning -ProcessName "chrome"
    if ($chromeWasRunning) {
        $restartedBrowsers += "chrome"
    }

    if (Restart-BrowserIfRunning -ProcessName "msedge") {
        $restartedBrowsers += "msedge"
    }
}

$readinessState = Get-InstallReadinessState `
    -Hive $registryHive `
    -ChromeExtensionId $ChromeExtensionId `
    -EdgeExtensionId $EdgeExtensionId `
    -AdminConsolePath $installedAdminConsoleExe `
    -ConfigPath $installedConfig `
    -ExtensionDirectory $installedExtensionDir `
    -StartMenuProgramsPath $startMenuPrograms

$verificationFailures = Get-InstallVerificationFailures `
    -Hive $registryHive `
    -InstallRootValue $InstallRoot `
    -DaemonBinaryPath $installedBinary `
    -ConfigPath $installedConfig `
    -ExtensionCrxPath $installedCrx `
    -AdminConsolePath $installedAdminConsoleExe `
    -AdminShortcutPath $adminConsoleShortcut `
    -ChromeExtensionId $ChromeExtensionId `
    -EdgeExtensionId $EdgeExtensionId `
    -DaemonHealthResponse $daemonHealth `
    -ReadinessState $readinessState

if ($verificationFailures.Count -gt 0) {
    foreach ($failure in $verificationFailures) {
        Add-InstallWarning "Verification failure: $failure"
    }
}

Write-Host ""
Write-Host "Ulti Guard installed."
Write-Host "Scope        : $(if ($isAdmin) { 'machine' } else { 'current-user' })"
Write-Host "Install root : $InstallRoot"
Write-Host "PII engine   : http://127.0.0.1:$PiiPort/api/pii/detect"
Write-Host "Chrome Ext   : $ChromeExtensionId"
Write-Host "Chrome URL   : $ChromeUpdateUrl"
Write-Host "Edge Ext     : $EdgeExtensionId"
Write-Host "Edge URL     : $EdgeUpdateUrl"
Write-Host "Python       : $venvPython"
Write-Host "Claude Desk  : desktop hook installed for detected app-* versions"
Write-Host "Claude Start : $claudeLauncherScript"
Write-Host "Admin UI     : $installedAdminConsoleExe"
Write-Host "Daemon       : $($daemonHealth.Content)"
Write-Host "PII Health   : $($piiHealth.Content)"
Write-Host ""
if ($isAdmin) {
    if ($restartedBrowsers.Count -gt 0) {
        Write-Host "Browsers restarted: $($restartedBrowsers -join ', ')"
    } else {
        Write-Host "Restart Chrome and Edge, then verify the Ulti Guard extension is present and managed."
    }
    if ($EnforceBrowserHostBlocklist) {
        Write-Host "Blocked provider hosts are also enforced through Chrome/Edge URLBlocklist policy."
    }
    if ($readinessState.chrome_shortcut_fallback_ready -and -not $readinessState.chrome_policy_ready) {
        Write-Host "Chrome uses the Ulti Guard shortcut fallback on this Windows device."
    }
    Write-Host "Chrome Incognito remains enabled."
    Write-Host "Edge InPrivate remains enabled, but navigation requires Ulti Guard to be allowed there."
} else {
    Write-Host "Current-user install does not force-enable the extension. Load the installed extension folder unpacked in Chrome/Edge:"
    Write-Host "  $installedExtensionDir"
}

$finalStatus = if ($script:InstallWarnings.Count -gt 0) { "installed_with_warning" } else { "installed" }
Write-UltiGuardBootstrapResult `
    -Status $finalStatus `
    -Message "Ulti Guard installation completed." `
    -Warnings $script:InstallWarnings.ToArray() `
    -InstallRootValue $InstallRoot `
    -Scope (Get-InstallScope) `
    -ChromeReady ([bool]$readinessState.chrome_ready) `
    -EdgeReady ([bool]$readinessState.edge_ready) `
    -PrivateModeStrategy ([string]$readinessState.private_mode_strategy)
