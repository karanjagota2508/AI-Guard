param(
    [int]$PiiPort = 8000,
    [string]$InstallRoot = "$env:ProgramFiles\Ulti Guard Agent",
    [switch]$SkipBuild,
    [string]$ExtensionUpdateUrl = "http://127.0.0.1:48555/update.xml",
    [string]$MinimumExtensionVersion = "",
    [switch]$BlockOtherExtensions,
    [string[]]$AllowedExtensionIds = @(),
    [switch]$RequirePrivateBrowsingGuard,
    [switch]$EnforceBrowserHostBlocklist,
    [switch]$DisablePrivateBrowsing,
    [switch]$DisallowExtensionDeveloperMode,
    [switch]$DisableBrowserDeveloperTools
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
    $dsreg = Get-Command dsregcmd.exe -ErrorAction SilentlyContinue
    if (-not $dsreg) {
        return $false
    }

    try {
        $output = & $dsreg.Source /status 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $output) {
            return $false
        }

        return [bool]($output | Select-String -Pattern 'AzureAdJoined\s*:\s*YES' -Quiet)
    } catch {
        return $false
    }
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
    $InstallRoot = Join-Path $env:LOCALAPPDATA "Ulti Guard Agent"
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
$token = New-RandomToken
$serviceName = "AIGuardAgent"
$extensionManifest = Get-Content -Path $extensionManifestPath -Raw | ConvertFrom-Json
$extensionId = "kgfkgellcbbmadimiahbfndmfbhfobko"
$extensionVersion = [string]$extensionManifest.version
$claudeWebHosts = @("claude.ai", "claude.com")
$origin = "chrome-extension://$extensionId/"
$bundledPythonExecutable = Join-Path $distDir "python-runtime\python.exe"
$wheelhouseDir = Join-Path $distDir "pii-wheelhouse"
$pythonExecutable = if (Test-Path $bundledPythonExecutable) { $bundledPythonExecutable } else { Find-PythonExecutable }
$restartedBrowsers = @()
$chromeExecutablePath = Find-ChromeExecutable
$chromeMajorVersion = Get-ChromeMajorVersion -ChromeExecutablePath $chromeExecutablePath
$chromeManagedSelfHostedSupported = if ($isAdmin) { Test-ChromeSelfHostedManagedSupported } else { $false }
$chromeCommandLineExtensionSupport = $chromeExecutablePath -and ($null -eq $chromeMajorVersion -or $chromeMajorVersion -lt 137)
$chromeShortcutFallbackMode = $isAdmin -and -not $chromeManagedSelfHostedSupported -and $chromeCommandLineExtensionSupport
$chromeModernUnmanagedUnsupported = $isAdmin -and -not $chromeManagedSelfHostedSupported -and $chromeExecutablePath -and -not $chromeCommandLineExtensionSupport

Stop-LocalProcessByPort -Port 48555 -ExpectedProcessName "ai-guard-daemon"

if (-not $SkipBuild) {
    cargo build --release --manifest-path (Join-Path $daemonProject "Cargo.toml")
    New-Item -ItemType Directory -Force -Path $distDir | Out-Null
    Copy-Item -Path $daemonBinarySource -Destination $distDaemonBinary -Force
    & (Join-Path $InstallerScriptRoot "scripts\package-extension.ps1") -OutputPath $distCrx
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

$installConfigDir = Join-Path $InstallRoot "config"
$installDistDir = Join-Path $InstallRoot "dist"
$installLogsDir = Join-Path $InstallRoot "logs"
$installManifestDir = Join-Path $InstallRoot "manifests"
$installPiiDir = Join-Path $InstallRoot "pii-agent"
$installScriptsDir = Join-Path $InstallRoot "scripts"
$installDesktopDir = Join-Path $InstallRoot "desktop"
$installBrandingDir = Join-Path $InstallRoot "branding"
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
$adminConsoleScript = Join-Path $installScriptsDir "admin-console.ps1"
$browserPoliciesScript = Join-Path $installScriptsDir "browser-policies.ps1"
$prepareBrowserTestModeScript = Join-Path $installScriptsDir "prepare-browser-test-mode.ps1"
$installedClaudeHook = Join-Path $installDesktopDir "claude-desktop-hook.cjs"
$installedClaudeUiaGuard = Join-Path $installDesktopDir "claude-desktop-uia-guard.ps1"
$installedBrandIcon = Join-Path $installBrandingDir "logo.ico"
$claudeLauncherScript = Join-Path $InstallRoot "launch-claude-desktop.ps1"
$adminConsoleLauncher = Join-Path $InstallRoot "launch-admin-console.ps1"
$browserTestModeLauncher = Join-Path $InstallRoot "launch-browser-test-mode.ps1"
$startMenuPrograms = if ($isAdmin) {
    Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs"
} else {
    [Environment]::GetFolderPath("Programs")
}
$adminConsoleShortcut = Join-Path $startMenuPrograms "Ulti Guard Agent Admin Console.lnk"
$browserTestModeShortcut = Join-Path $startMenuPrograms "Ulti Guard Browser Test Mode.lnk"
$legacyAdminConsoleShortcuts = @(
    (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\AI Guard Agent Admin Console.lnk"),
    (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Ulti Guard Agent Admin Console.lnk"),
    (Join-Path ([Environment]::GetFolderPath("Programs")) "AI Guard Agent Admin Console.lnk"),
    (Join-Path ([Environment]::GetFolderPath("Programs")) "Ulti Guard Agent Admin Console.lnk")
)

New-Item -ItemType Directory -Force -Path $InstallRoot, $installConfigDir, $installDistDir, $installLogsDir, $installManifestDir, $installPiiDir, $installScriptsDir, $installDesktopDir, $installBrandingDir | Out-Null
Copy-Item -Path $daemonBinaryToInstall -Destination $installedBinary -Force
Copy-Item -Path $distCrx -Destination $installedCrx -Force
Copy-Item -Path (Join-Path $InstallerScriptRoot "scripts\patch-claude-desktop.ps1") -Destination $patchClaudeDesktopScript -Force
Copy-Item -Path (Join-Path $InstallerScriptRoot "scripts\sync-claude-store-runtime.ps1") -Destination $syncClaudeStoreRuntimeScript -Force
Copy-Item -Path (Join-Path $InstallerScriptRoot "scripts\admin-console.ps1") -Destination $adminConsoleScript -Force
Copy-Item -Path (Join-Path $InstallerScriptRoot "scripts\browser-policies.ps1") -Destination $browserPoliciesScript -Force
Copy-Item -Path (Join-Path $InstallerScriptRoot "scripts\prepare-browser-test-mode.ps1") -Destination $prepareBrowserTestModeScript -Force
Copy-Item -Path (Join-Path $repoRoot "desktop\claude-desktop-hook.cjs") -Destination $installedClaudeHook -Force
Copy-Item -Path (Join-Path $repoRoot "desktop\claude-desktop-uia-guard.ps1") -Destination $installedClaudeUiaGuard -Force
if (Test-Path $brandingSource) {
    Copy-Item -Path (Join-Path $brandingSource "*") -Destination $installBrandingDir -Recurse -Force
}
$installedExtensionDir = Join-Path $InstallRoot "extension"
if (Test-Path $installedExtensionDir) {
    Remove-Item -Path $installedExtensionDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $installedExtensionDir | Out-Null
Copy-Item -Path (Join-Path $repoRoot "extension\\*") -Destination $installedExtensionDir -Recurse -Force

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
    -ExtensionId $extensionId `
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

$adminConsoleLauncherContent = @"
`$ErrorActionPreference = 'Stop'
& '$adminConsoleScript' -ConfigPath '$installedConfig' -ServiceName '$serviceName' -LauncherScriptPath '$launcherScript' -DaemonBinaryPath '$installedBinary'
"@
[System.IO.File]::WriteAllText($adminConsoleLauncher, $adminConsoleLauncherContent, (New-Object System.Text.UTF8Encoding($false)))

$browserTestModeLauncherContent = @"
`$ErrorActionPreference = 'Stop'
& '$prepareBrowserTestModeScript' -InstallRoot '$InstallRoot' -OpenFolder -OpenReadme -OpenEdge
"@
[System.IO.File]::WriteAllText($browserTestModeLauncher, $browserTestModeLauncherContent, (New-Object System.Text.UTF8Encoding($false)))

$nativeManifestObject = @{
    name = "com.wininfosoft.ai_guard"
    description = "Ulti Guard Agent native bootstrap host"
    path = $installedBinary
    type = "stdio"
    allowed_origins = @($origin)
}

$nativeManifestJson = $nativeManifestObject | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($chromeNativeManifest, $nativeManifestJson, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($edgeNativeManifest, $nativeManifestJson, (New-Object System.Text.UTF8Encoding($false)))

Set-RegistryDefaultValue -Hive $registryHive -KeyPath "SOFTWARE\Google\Chrome\NativeMessagingHosts\com.wininfosoft.ai_guard" -Value $chromeNativeManifest
Set-RegistryDefaultValue -Hive $registryHive -KeyPath "SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.wininfosoft.ai_guard" -Value $edgeNativeManifest
Set-RegistryStringValue -Hive $registryHive -KeyPath "SOFTWARE\Google\Chrome\Extensions\$extensionId" -Name "update_url" -Value $ExtensionUpdateUrl
Set-RegistryStringValue -Hive $registryHive -KeyPath "SOFTWARE\Microsoft\Edge\Extensions\$extensionId" -Name "update_url" -Value $ExtensionUpdateUrl

if ($isAdmin) {
    if ($chromeManagedSelfHostedSupported) {
        Set-ManagedExtensionPolicy `
            -Hive $registryHive `
            -Browser "Chrome" `
            -ExtensionId $extensionId `
            -UpdateUrl $ExtensionUpdateUrl `
            -MinimumVersionRequired $MinimumExtensionVersion `
            -BlockOtherExtensions:$BlockOtherExtensions `
            -AllowedExtensionIds $AllowedExtensionIds `
            -RequirePrivateBrowsingGuard:$RequirePrivateBrowsingGuard `
            -DisallowExtensionDeveloperMode:$DisallowExtensionDeveloperMode `
            -DisableDeveloperTools:$DisableBrowserDeveloperTools
    } else {
        Clear-ChromeUnsupportedManagedPolicyResidue `
            -Hive $registryHive `
            -ExtensionId $extensionId
    }

    if ($EnforceBrowserHostBlocklist) {
        Set-AIGuardBrowserHostBlocklistPolicy `
            -Hive $registryHive `
            -Browser "Chrome" `
            -Hosts @($effectiveConfig.blocking.browser_hosts)
    }

    if ($DisablePrivateBrowsing) {
        Set-AIGuardPrivateBrowsingPolicy `
            -Hive $registryHive `
            -Browser "Chrome" `
            -Disable
    } else {
        Set-AIGuardPrivateBrowsingPolicy `
            -Hive $registryHive `
            -Browser "Chrome"
    }

    Set-ManagedExtensionPolicy `
        -Hive $registryHive `
        -Browser "Edge" `
        -ExtensionId $extensionId `
        -UpdateUrl $ExtensionUpdateUrl `
        -MinimumVersionRequired $MinimumExtensionVersion `
        -BlockOtherExtensions:$BlockOtherExtensions `
        -AllowedExtensionIds $AllowedExtensionIds `
        -RequirePrivateBrowsingGuard:$RequirePrivateBrowsingGuard `
        -DisallowExtensionDeveloperMode:$DisallowExtensionDeveloperMode `
        -DisableDeveloperTools:$DisableBrowserDeveloperTools

    if ($EnforceBrowserHostBlocklist) {
        Set-AIGuardBrowserHostBlocklistPolicy `
            -Hive $registryHive `
            -Browser "Edge" `
            -Hosts @($effectiveConfig.blocking.browser_hosts)
    }

    if ($DisablePrivateBrowsing) {
        Set-AIGuardPrivateBrowsingPolicy `
            -Hive $registryHive `
            -Browser "Edge" `
            -Disable
    } else {
        Set-AIGuardPrivateBrowsingPolicy `
            -Hive $registryHive `
            -Browser "Edge"
    }
}

Stop-LocalProcessByPort -Port 48555 -ExpectedProcessName "ai-guard-daemon"
Stop-PiiServiceIfPresent -Port $PiiPort -InstallRoot $InstallRoot

if ($isAdmin) {
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        Stop-Service -Name $serviceName -ErrorAction SilentlyContinue
        sc.exe delete $serviceName | Out-Null
        Start-Sleep -Seconds 2
    }

    $binaryPath = "`"$installedBinary`" --config `"$installedConfig`" service"
    New-Service `
        -Name $serviceName `
        -BinaryPathName $binaryPath `
        -DisplayName "Ulti Guard Agent" `
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

foreach ($legacyShortcut in $legacyAdminConsoleShortcuts | Select-Object -Unique) {
    if ($legacyShortcut -and (Test-Path $legacyShortcut)) {
        Remove-Item -Path $legacyShortcut -Force -ErrorAction SilentlyContinue
    }
}

New-ShortcutFile `
    -ShortcutPath $adminConsoleShortcut `
    -TargetPath "powershell.exe" `
    -Arguments "-NoProfile -ExecutionPolicy RemoteSigned -File `"$adminConsoleLauncher`"" `
    -WorkingDirectory $InstallRoot `
    -Description "Open the Ulti Guard Agent admin console." `
    -IconLocation $installedBrandIcon

New-ShortcutFile `
    -ShortcutPath $browserTestModeShortcut `
    -TargetPath "powershell.exe" `
    -Arguments "-NoProfile -ExecutionPolicy RemoteSigned -File `"$browserTestModeLauncher`"" `
    -WorkingDirectory $InstallRoot `
    -Description "Prepare the Ulti Guard browser test package and open the unpacked extension folder." `
    -IconLocation $installedBrandIcon

Start-Sleep -Seconds 3

$daemonHealth = Wait-ForHttpOk -Url "http://127.0.0.1:48555/healthz" -TimeoutSeconds 60
$piiHealth = Wait-ForHttpOk -Url "http://127.0.0.1:$PiiPort/health" -TimeoutSeconds 240

if ($isAdmin) {
    $chromeWasRunning = Restart-BrowserIfRunning -ProcessName "chrome" -SkipRelaunch:$chromeShortcutFallbackMode
    if ($chromeWasRunning) {
        $restartedBrowsers += "chrome"
    }

    if (Restart-BrowserIfRunning -ProcessName "msedge") {
        $restartedBrowsers += "msedge"
    }

    if ($chromeShortcutFallbackMode) {
        $patchedChromeShortcuts = Set-ChromeShortcutFallback `
            -ChromeExecutablePath $chromeExecutablePath `
            -ExtensionDirectory $installedExtensionDir `
            -StartMenuProgramsPath $startMenuPrograms

        if ($patchedChromeShortcuts.Count -gt 0 -and $chromeWasRunning) {
            Start-Process -FilePath $chromeExecutablePath -ArgumentList "--load-extension=""$installedExtensionDir""" | Out-Null
        }
    }
}

Write-Host ""
Write-Host "Ulti Guard Agent installed."
Write-Host "Scope        : $(if ($isAdmin) { 'machine' } else { 'current-user' })"
Write-Host "Install root : $InstallRoot"
Write-Host "PII engine   : http://127.0.0.1:$PiiPort/api/pii/detect"
Write-Host "Extension ID : $extensionId"
Write-Host "Update URL   : $ExtensionUpdateUrl"
Write-Host "Python       : $venvPython"
Write-Host "Claude Desk  : desktop hook installed for detected app-* versions"
Write-Host "Claude Start : $claudeLauncherScript"
Write-Host "Admin UI     : $adminConsoleLauncher"
Write-Host "Daemon       : $($daemonHealth.Content)"
Write-Host "PII Health   : $($piiHealth.Content)"
Write-Host ""
if ($isAdmin) {
    if ($restartedBrowsers.Count -gt 0) {
        Write-Host "Browsers restarted: $($restartedBrowsers -join ', ')"
    } else {
        if ($chromeModernUnmanagedUnsupported) {
            Write-Host "Chrome was left installed, but the Ulti Guard web extension cannot be activated there on this machine."
        } elseif ($chromeShortcutFallbackMode) {
            Write-Host "Restart Chrome and Edge, then verify the Ulti Guard extension is present and active."
        } else {
            Write-Host "Restart Chrome and Edge, then verify the extension is present and managed."
        }
    }
    if ($chromeModernUnmanagedUnsupported) {
        Write-Host "Chrome $chromeMajorVersion on unmanaged Windows no longer supports loading this self-hosted extension."
        Write-Host "Ulti Guard web protection on Chrome requires one of the following:"
        Write-Host "  1. Chrome managed through domain/Azure AD/Chrome Enterprise with a valid enrollment token"
        Write-Host "  2. The extension published through the Chrome Web Store and deployed from there"
        Write-Host "Use Microsoft Edge or Claude Desktop on this machine if you need immediate PII protection without additional Chrome enterprise setup."
    }
    if ($chromeShortcutFallbackMode) {
        Write-Host "Chrome self-hosted force-install is not supported on this unmanaged Windows instance."
        Write-Host "Ulti Guard patched local Chrome shortcuts to launch Chrome with the bundled extension loaded from:"
        Write-Host "  $installedExtensionDir"
    }
    if ($EnforceBrowserHostBlocklist) {
        Write-Host "Blocked provider hosts are also enforced through Chrome/Edge URLBlocklist policy."
    }
    if ($DisablePrivateBrowsing) {
        Write-Host "Chrome Incognito and Edge InPrivate were disabled to prevent users bypassing managed protections."
    } elseif ($RequirePrivateBrowsingGuard) {
        Write-Host "Incognito/InPrivate stay enabled, but private navigation now requires Ulti Guard to remain allowed."
    }
} else {
    Write-Host "Current-user install does not force-enable the extension. Load the installed extension folder unpacked in Chrome/Edge:"
    Write-Host "  $installedExtensionDir"
}
