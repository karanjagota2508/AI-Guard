param(
    [int]$PiiPort = 8000,
    [string]$InstallRoot = "$env:ProgramFiles\AI Guard Agent",
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
        [string]$Description = ""
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
    $shortcut.Save()
}

. (Join-Path $PSScriptRoot "scripts\browser-policies.ps1")

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
        [string]$ProcessName
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

    if ($launchPath) {
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

$repoRoot = Split-Path $PSScriptRoot -Parent
$daemonProject = Join-Path $repoRoot "daemon"
$extensionManifestPath = Join-Path $repoRoot "extension\manifest.json"
$daemonBinarySource = Join-Path $daemonProject "target\release\ai-guard-daemon.exe"
$piiBackendSource = Join-Path (Split-Path $repoRoot -Parent) "PII_agent\backend"
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

Stop-LocalProcessByPort -Port 48555 -ExpectedProcessName "ai-guard-daemon"

if (-not $SkipBuild) {
    cargo build --release --manifest-path (Join-Path $daemonProject "Cargo.toml")
    New-Item -ItemType Directory -Force -Path $distDir | Out-Null
    Copy-Item -Path $daemonBinarySource -Destination $distDaemonBinary -Force
    & (Join-Path $PSScriptRoot "scripts\package-extension.ps1") -OutputPath $distCrx
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
$installedClaudeHook = Join-Path $installDesktopDir "claude-desktop-hook.cjs"
$installedClaudeUiaGuard = Join-Path $installDesktopDir "claude-desktop-uia-guard.ps1"
$claudeLauncherScript = Join-Path $InstallRoot "launch-claude-desktop.ps1"
$adminConsoleLauncher = Join-Path $InstallRoot "launch-admin-console.ps1"
$startMenuPrograms = if ($isAdmin) {
    Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs"
} else {
    [Environment]::GetFolderPath("Programs")
}
$adminConsoleShortcut = Join-Path $startMenuPrograms "AI Guard Agent Admin Console.lnk"

New-Item -ItemType Directory -Force -Path $InstallRoot, $installConfigDir, $installDistDir, $installLogsDir, $installManifestDir, $installPiiDir, $installScriptsDir, $installDesktopDir | Out-Null
Copy-Item -Path $daemonBinaryToInstall -Destination $installedBinary -Force
Copy-Item -Path $distCrx -Destination $installedCrx -Force
Copy-Item -Path (Join-Path $PSScriptRoot "scripts\patch-claude-desktop.ps1") -Destination $patchClaudeDesktopScript -Force
Copy-Item -Path (Join-Path $PSScriptRoot "scripts\sync-claude-store-runtime.ps1") -Destination $syncClaudeStoreRuntimeScript -Force
Copy-Item -Path (Join-Path $PSScriptRoot "scripts\admin-console.ps1") -Destination $adminConsoleScript -Force
Copy-Item -Path (Join-Path $PSScriptRoot "scripts\browser-policies.ps1") -Destination $browserPoliciesScript -Force
Copy-Item -Path (Join-Path $repoRoot "desktop\claude-desktop-hook.cjs") -Destination $installedClaudeHook -Force
Copy-Item -Path (Join-Path $repoRoot "desktop\claude-desktop-uia-guard.ps1") -Destination $installedClaudeUiaGuard -Force
$installedExtensionDir = Join-Path $InstallRoot "extension"
if (Test-Path $installedExtensionDir) {
    Remove-Item -Path $installedExtensionDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $installedExtensionDir | Out-Null
Copy-Item -Path (Join-Path $repoRoot "extension\\*") -Destination $installedExtensionDir -Recurse -Force

$venvPython = @(& (Join-Path $PSScriptRoot "scripts\provision-pii-agent.ps1") `
    -SourceBackendDir $piiBackendSource `
    -InstallDir $installPiiDir `
    -PythonExecutable $pythonExecutable `
    -WheelhousePath $wheelhouseDir)
$venvPython = ($venvPython | Select-Object -Last 1).Trim()

& (Join-Path $PSScriptRoot "scripts\write-config.ps1") `
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

$nativeManifestObject = @{
    name = "com.wininfosoft.ai_guard"
    description = "AI Guard Agent native bootstrap host"
    path = $installedBinary
    type = "stdio"
    allowed_origins = @($origin)
}

$nativeManifestJson = $nativeManifestObject | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($chromeNativeManifest, $nativeManifestJson, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($edgeNativeManifest, $nativeManifestJson, (New-Object System.Text.UTF8Encoding($false)))

Set-RegistryDefaultValue -Hive $registryHive -KeyPath "SOFTWARE\Google\Chrome\NativeMessagingHosts\com.wininfosoft.ai_guard" -Value $chromeNativeManifest
Set-RegistryDefaultValue -Hive $registryHive -KeyPath "SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.wininfosoft.ai_guard" -Value $edgeNativeManifest
Remove-RegistryKeyIfPresent -Hive $registryHive -KeyPath "SOFTWARE\Google\Chrome\Extensions\$extensionId"
Remove-RegistryKeyIfPresent -Hive $registryHive -KeyPath "SOFTWARE\Microsoft\Edge\Extensions\$extensionId"

if ($isAdmin) {
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
        -DisplayName "AI Guard Agent" `
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
    Set-RegistryStringValue -Hive $registryHive -KeyPath "SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "AIGuardAgent" -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherScript`""
    Start-Process -FilePath $installedBinary -ArgumentList "--config `"$installedConfig`" run" -WindowStyle Hidden | Out-Null
}

New-ShortcutFile `
    -ShortcutPath $adminConsoleShortcut `
    -TargetPath "powershell.exe" `
    -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$adminConsoleLauncher`"" `
    -WorkingDirectory $InstallRoot `
    -Description "Open the AI Guard Agent admin console."

Start-Sleep -Seconds 3

$daemonHealth = Wait-ForHttpOk -Url "http://127.0.0.1:48555/healthz" -TimeoutSeconds 60
$piiHealth = Wait-ForHttpOk -Url "http://127.0.0.1:$PiiPort/health" -TimeoutSeconds 240

if ($isAdmin) {
    foreach ($browserProcessName in @("chrome", "msedge")) {
        if (Restart-BrowserIfRunning -ProcessName $browserProcessName) {
            $restartedBrowsers += $browserProcessName
        }
    }
}

Write-Host ""
Write-Host "AI Guard Agent installed."
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
        Write-Host "Restart Chrome and Edge, then verify the extension is present and managed."
    }
    if ($EnforceBrowserHostBlocklist) {
        Write-Host "Blocked provider hosts are also enforced through Chrome/Edge URLBlocklist policy."
    }
    if ($DisablePrivateBrowsing) {
        Write-Host "Chrome Incognito and Edge InPrivate were disabled to prevent users bypassing managed protections."
    } elseif ($RequirePrivateBrowsingGuard) {
        Write-Host "Incognito/InPrivate stay enabled, but private navigation now requires AI Guard to remain allowed."
    }
} else {
    Write-Host "Current-user install does not force-enable the extension. Load the installed extension folder unpacked in Chrome/Edge:"
    Write-Host "  $installedExtensionDir"
}
