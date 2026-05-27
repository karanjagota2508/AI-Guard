param(
    [string]$OutputRoot = "",
    [switch]$KeepRuntime
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$distDir = Join-Path $repoRoot "installer\dist"
$extensionDir = Join-Path $repoRoot "extension"
$testProjectDir = Join-Path $repoRoot "tests\browser"
$daemonSourceBinary = Join-Path $repoRoot "daemon\target\release\ai-guard-daemon.exe"
$daemonBinary = Join-Path $distDir "ai-guard-daemon.exe"
$manifestPath = Join-Path $extensionDir "manifest.json"
$packageExtensionScript = Join-Path $PSScriptRoot "package-extension.ps1"
$prepareBrowserTestModeScript = Join-Path $PSScriptRoot "prepare-browser-test-mode.ps1"
$writeConfigScript = Join-Path $PSScriptRoot "write-config.ps1"
$provisionPiiScript = Join-Path $PSScriptRoot "provision-pii-agent.ps1"
$smokeScript = Join-Path $testProjectDir "smoke-test.mjs"
$extensionId = "kgfkgellcbbmadimiahbfndmfbhfobko"

if (-not $OutputRoot) {
    $OutputRoot = Join-Path $repoRoot "..\artifacts\local-browser-smoke"
}

$runtimeRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$runtimeDaemonBinary = Join-Path $runtimeRoot "ai-guard-daemon.exe"
$browserTestModeRoot = Join-Path $runtimeRoot "browser-test-mode"
$testExtensionDir = Join-Path $browserTestModeRoot "extension"
$chromeTestingRoot = Join-Path $runtimeRoot "chrome-for-testing"
$logsDir = Join-Path $runtimeRoot "logs"
$nativeHostDir = Join-Path $runtimeRoot "native-host"
$configPath = Join-Path $runtimeRoot "ai-guard.local-browser-test.json"
$runtimeConfigDir = Join-Path $runtimeRoot "config"
$runtimeConfigPath = Join-Path $runtimeConfigDir "ai-guard.json"
$chromeProfileDir = Join-Path $runtimeRoot ("chrome-profile-" + [Guid]::NewGuid().ToString("N"))
$chromeNativeManifest = Join-Path $nativeHostDir "chrome-native-host.json"
$edgeNativeManifest = Join-Path $nativeHostDir "edge-native-host.json"
$venvPython = Join-Path $distDir "python-runtime\python.exe"
$wheelhouseDir = Join-Path $distDir "pii-wheelhouse"
$piiWorkingDirectory = Join-Path (Join-Path (Join-Path $repoRoot "..") "PII_agent") "backend"
$piiStdoutLog = Join-Path $logsDir "pii-agent.stdout.log"
$piiStderrLog = Join-Path $logsDir "pii-agent.stderr.log"
$daemonStdoutLog = Join-Path $logsDir "daemon.stdout.log"
$daemonStderrLog = Join-Path $logsDir "daemon.stderr.log"
$distCrx = Join-Path $distDir "ai-guard-extension.crx"
$serviceName = "AIGuardAgent"
$daemonPort = 49555
$piiPort = 18000

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

function Find-PythonExecutable {
    $candidates = @()

    if (Test-Path $venvPython) {
        return $venvPython
    }

    $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
    if ($pyLauncher) {
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

    $resolved = @($candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique)
    if (-not $resolved) {
        throw "Could not locate a usable Python interpreter for the local browser smoke test."
    }

    return $resolved[0]
}

function Wait-ForHttpOk {
    param(
        [string]$Url,
        [int]$TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            return Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
        } catch {
            Start-Sleep -Milliseconds 500
        }
    } while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for $Url"
}

function Save-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 10
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

function Set-LocalPiiMode {
    param(
        [string[]]$Paths,
        [string]$Action
    )

    foreach ($path in $Paths) {
        $config = Get-Content -Path $path -Raw | ConvertFrom-Json
        if (-not $config.pii) {
            $config | Add-Member -NotePropertyName pii -NotePropertyValue ([pscustomobject]@{})
        }

        $config.pii.enabled = $true
        $config.pii.confidence_score = 0.35
        $config.pii.action = $Action.ToLowerInvariant()
        Save-JsonFile -Path $path -Value $config
    }
}

function Set-LocalDaemonPort {
    param(
        [string[]]$Paths,
        [int]$Port
    )

    foreach ($path in $Paths) {
        $config = Get-Content -Path $path -Raw | ConvertFrom-Json
        $config.listen_address = "127.0.0.1:$Port"

        if ($config.package) {
            $config.package.chrome_update_url = "http://127.0.0.1:$Port/update.xml"
            $config.package.edge_update_url = "http://127.0.0.1:$Port/update.xml"
        }

        Save-JsonFile -Path $path -Value $config
    }
}

function Start-LocalDaemonProcess {
    param(
        [string]$BinaryPath,
        [string]$ConfigPath,
        [string]$StdoutLog,
        [string]$StderrLog
    )

    return Start-Process `
        -FilePath $BinaryPath `
        -ArgumentList "--config `"$ConfigPath`" run" `
        -RedirectStandardOutput $StdoutLog `
        -RedirectStandardError $StderrLog `
        -PassThru `
        -WindowStyle Hidden
}

function Restart-LocalDaemonProcess {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$BinaryPath,
        [string]$ConfigPath,
        [string]$StdoutLog,
        [string]$StderrLog,
        [int]$Port
    )

    if ($Process -and -not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        try {
            Wait-Process -Id $Process.Id -Timeout 10 -ErrorAction SilentlyContinue
        } catch {
        }
    }

    Stop-LocalDaemon -Port $Port
    Wait-ForPortReleased -Port $Port -TimeoutSeconds 30
    return Start-LocalDaemonProcess `
        -BinaryPath $BinaryPath `
        -ConfigPath $ConfigPath `
        -StdoutLog $StdoutLog `
        -StderrLog $StderrLog
}

function Stop-LocalDaemon {
    param(
        [int]$Port
    )

    $listeners = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    foreach ($listener in @($listeners)) {
        $process = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
        if ($process -and $process.ProcessName -eq "ai-guard-daemon") {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

function Wait-ForPortReleased {
    param(
        [int]$Port,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
        if (-not $listeners) {
            return
        }

        foreach ($listener in $listeners) {
            $process = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
            if ($process -and $process.ProcessName -eq "ai-guard-daemon") {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }
        }

        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for daemon port $Port to be released."
}

function Stop-InstalledUltiGuardService {
    param(
        [string]$Name
    )

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) {
        return $false
    }

    if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running) {
        return $false
    }

    try {
        Stop-Service -Name $Name -ErrorAction Stop
        Start-Sleep -Seconds 2
        return $true
    } catch {
        Write-Warning "Could not stop Windows service $Name before the local browser smoke test: $($_.Exception.Message)"
        return $false
    }
}

function Start-InstalledUltiGuardService {
    param(
        [string]$Name
    )

    try {
        Start-Service -Name $Name -ErrorAction Stop
    } catch {
        Write-Warning "Could not restart Windows service $Name after the local browser smoke test: $($_.Exception.Message)"
    }
}

function Stop-LocalRuntimeProcesses {
    param(
        [string]$RuntimeRoot
    )

    $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
    foreach ($process in @($processes)) {
        $processPath = [string]$process.ExecutablePath
        $commandLine = [string]$process.CommandLine
        if (
            ($processPath -and $processPath.StartsWith($RuntimeRoot, [System.StringComparison]::OrdinalIgnoreCase)) -or
            ($commandLine -and $commandLine.Contains($RuntimeRoot))
        ) {
            try {
                Invoke-CimMethod -InputObject $process -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null
            } catch {
            }
        }
    }
}

function Ensure-ChromeForTesting {
    param(
        [string]$DestinationRoot
    )

    $metadataUrl = "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json"
    $metadata = Invoke-RestMethod -Uri $metadataUrl -TimeoutSec 30
    $download = $metadata.channels.Stable.downloads.chrome | Where-Object { $_.platform -eq "win64" } | Select-Object -First 1
    if (-not $download) {
        throw "Could not resolve a Chrome for Testing download for win64."
    }

    $version = [string]$metadata.channels.Stable.version
    $versionRoot = Join-Path $DestinationRoot $version
    $chromeExe = Join-Path $versionRoot "chrome-win64\chrome.exe"
    if (Test-Path $chromeExe) {
        return $chromeExe
    }

    New-Item -ItemType Directory -Force -Path $DestinationRoot | Out-Null
    $zipPath = Join-Path $DestinationRoot "chrome-for-testing-$version-win64.zip"
    Invoke-WebRequest -Uri $download.url -OutFile $zipPath -TimeoutSec 120
    if (Test-Path $versionRoot) {
        Remove-Item -Path $versionRoot -Recurse -Force
    }
    Expand-Archive -Path $zipPath -DestinationPath $versionRoot -Force
    return $chromeExe
}

function Ensure-NpmDependencies {
    param(
        [string]$ProjectDir
    )

    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        throw "npm is required to run the Ulti Guard local browser smoke test."
    }

    Push-Location $ProjectDir
    try {
        npm install | Out-Null
    } finally {
        Pop-Location
    }
}

function Register-NativeHost {
    param(
        [string]$ManifestPath,
        [string]$KeyPath
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry64)
    $key = $baseKey.CreateSubKey($KeyPath)
    try {
        $key.SetValue($null, $ManifestPath, [Microsoft.Win32.RegistryValueKind]::String)
    } finally {
        $key.Dispose()
        $baseKey.Dispose()
    }
}

function Get-RegistryDefaultValue {
    param(
        [string]$KeyPath
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $baseKey.OpenSubKey($KeyPath, $false)
        if (-not $key) {
            return $null
        }

        try {
            return $key.GetValue($null, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        } finally {
            $key.Dispose()
        }
    } finally {
        $baseKey.Dispose()
    }
}

function Restore-NativeHostRegistration {
    param(
        [string]$KeyPath,
        [AllowNull()][string]$PreviousManifestPath
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        if ([string]::IsNullOrWhiteSpace($PreviousManifestPath)) {
            $parentPath = Split-Path $KeyPath -Parent
            $childName = Split-Path $KeyPath -Leaf
            $parentKey = $baseKey.OpenSubKey($parentPath, $true)
            if ($parentKey) {
                try {
                    $parentKey.DeleteSubKeyTree($childName, $false)
                } finally {
                    $parentKey.Dispose()
                }
            }
            return
        }

        $key = $baseKey.CreateSubKey($KeyPath)
        try {
            $key.SetValue($null, $PreviousManifestPath, [Microsoft.Win32.RegistryValueKind]::String)
        } finally {
            $key.Dispose()
        }
    } finally {
        $baseKey.Dispose()
    }
}

New-Item -ItemType Directory -Force -Path $runtimeRoot, $logsDir, $nativeHostDir | Out-Null
New-Item -ItemType Directory -Force -Path $runtimeConfigDir | Out-Null

Stop-LocalRuntimeProcesses -RuntimeRoot $runtimeRoot
if (Test-Path $chromeProfileDir) {
    Remove-Item -Path $chromeProfileDir -Recurse -Force -ErrorAction SilentlyContinue
}

$chromeNativeHostKeyPath = "SOFTWARE\Google\Chrome\NativeMessagingHosts\com.wininfosoft.ai_guard"
$edgeNativeHostKeyPath = "SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.wininfosoft.ai_guard"
$previousChromeNativeHost = Get-RegistryDefaultValue -KeyPath $chromeNativeHostKeyPath
$previousEdgeNativeHost = Get-RegistryDefaultValue -KeyPath $edgeNativeHostKeyPath
$serviceWasRunning = Stop-InstalledUltiGuardService -Name $serviceName

cargo build --release --manifest-path (Join-Path $repoRoot "daemon\Cargo.toml")
New-Item -ItemType Directory -Force -Path $distDir | Out-Null
Copy-Item -Path $daemonSourceBinary -Destination $daemonBinary -Force

if (-not (Test-Path $distCrx)) {
    & $packageExtensionScript -OutputPath $distCrx
}

$pythonExecutable = Find-PythonExecutable
$token = New-RandomToken
$extensionManifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
$extensionVersion = [string]$extensionManifest.version
$piiRuntimeRoot = Join-Path $runtimeRoot "pii-agent-runtime"
$piiPython = @(& $provisionPiiScript `
    -SourceBackendDir $piiWorkingDirectory `
    -InstallDir $piiRuntimeRoot `
    -PythonExecutable $pythonExecutable `
    -WheelhousePath $wheelhouseDir)
$piiPython = ($piiPython | Select-Object -Last 1).Trim()
$piiRuntimeBackend = Join-Path $piiRuntimeRoot "backend"

& $prepareBrowserTestModeScript -SourceExtensionDir $extensionDir -OutputRoot $browserTestModeRoot | Out-Null

& $writeConfigScript `
    -OutputPath $configPath `
    -PiiPort $piiPort `
    -DaemonPort $daemonPort `
    -AuthToken $token `
    -ExtensionCrxPath $distCrx `
    -ChromeExtensionId $extensionId `
    -EdgeExtensionId $extensionId `
    -ExtensionVersion $extensionVersion `
    -LogDirectory $logsDir `
    -PiiExecutablePath $piiPython `
    -PiiWorkingDirectory $piiRuntimeBackend `
    -PiiStdoutLogPath $piiStdoutLog `
    -PiiStderrLogPath $piiStderrLog `
    -PiiStartupDelayMs 5000 `
    -ClaudeWebHosts @("claude.ai", "claude.com", "127.0.0.1", "localhost")

Copy-Item -Path $daemonBinary -Destination $runtimeDaemonBinary -Force
Copy-Item -Path $configPath -Destination $runtimeConfigPath -Force

$nativeManifestObject = @{
    name = "com.wininfosoft.ai_guard"
    description = "Ulti Guard Agent native bootstrap host"
    path = $runtimeDaemonBinary
    type = "stdio"
    allowed_origins = @("chrome-extension://$extensionId/")
}

$nativeManifestJson = $nativeManifestObject | ConvertTo-Json -Depth 4
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($chromeNativeManifest, $nativeManifestJson, $utf8NoBom)
[System.IO.File]::WriteAllText($edgeNativeManifest, $nativeManifestJson, $utf8NoBom)

Register-NativeHost -ManifestPath $chromeNativeManifest -KeyPath $chromeNativeHostKeyPath
Register-NativeHost -ManifestPath $edgeNativeManifest -KeyPath $edgeNativeHostKeyPath

Stop-LocalDaemon -Port $daemonPort

$daemonProcess = Start-LocalDaemonProcess `
    -BinaryPath $runtimeDaemonBinary `
    -ConfigPath $configPath `
    -StdoutLog $daemonStdoutLog `
    -StderrLog $daemonStderrLog

try {
    Wait-ForHttpOk -Url "http://127.0.0.1:$daemonPort/healthz" -TimeoutSeconds 90 | Out-Null

    $chromeForTestingPath = Ensure-ChromeForTesting -DestinationRoot $chromeTestingRoot
    Ensure-NpmDependencies -ProjectDir $testProjectDir

    Push-Location $testProjectDir
    try {
        node $smokeScript `
            --browser-path $chromeForTestingPath `
            --extension-dir $testExtensionDir `
            --extension-id $extensionId `
            --daemon-base-url "http://127.0.0.1:$daemonPort" `
            --scenario "warmup-recovery" `
            --profile-dir $chromeProfileDir
        if ($LASTEXITCODE -ne 0) {
            throw "Ulti Guard browser smoke test failed with exit code $LASTEXITCODE."
        }

        Wait-ForHttpOk -Url "http://127.0.0.1:$daemonPort/readyz" -TimeoutSeconds 180 | Out-Null

        node $smokeScript `
            --browser-path $chromeForTestingPath `
            --extension-dir $testExtensionDir `
            --extension-id $extensionId `
            --daemon-base-url "http://127.0.0.1:$daemonPort" `
            --scenario "redact" `
            --profile-dir $chromeProfileDir
        if ($LASTEXITCODE -ne 0) {
            throw "Ulti Guard browser smoke test failed with exit code $LASTEXITCODE."
        }

        $maskDaemonPort = $daemonPort + 1
        Set-LocalPiiMode -Paths @($configPath, $runtimeConfigPath) -Action "mask"
        Set-LocalDaemonPort -Paths @($configPath, $runtimeConfigPath) -Port $maskDaemonPort
        $daemonProcess = Start-LocalDaemonProcess `
            -BinaryPath $runtimeDaemonBinary `
            -ConfigPath $configPath `
            -StdoutLog $daemonStdoutLog `
            -StderrLog $daemonStderrLog

        Wait-ForHttpOk -Url "http://127.0.0.1:$maskDaemonPort/readyz" -TimeoutSeconds 180 | Out-Null

        node $smokeScript `
            --browser-path $chromeForTestingPath `
            --extension-dir $testExtensionDir `
            --extension-id $extensionId `
            --daemon-base-url "http://127.0.0.1:$maskDaemonPort" `
            --scenario "mask" `
            --profile-dir $chromeProfileDir
        if ($LASTEXITCODE -ne 0) {
            throw "Ulti Guard browser smoke test failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }

    Write-Host ""
    Write-Host "Ulti Guard local browser smoke test passed."
    Write-Host "Runtime root : $runtimeRoot"
    Write-Host "Browser test : $browserTestModeRoot"
    Write-Host "Daemon logs  : $logsDir"
} finally {
    if (-not $KeepRuntime -and $daemonProcess -and -not $daemonProcess.HasExited) {
        Stop-Process -Id $daemonProcess.Id -Force -ErrorAction SilentlyContinue
    }

    if (-not $KeepRuntime) {
        Stop-LocalRuntimeProcesses -RuntimeRoot $runtimeRoot
        Restore-NativeHostRegistration -KeyPath $chromeNativeHostKeyPath -PreviousManifestPath $previousChromeNativeHost
        Restore-NativeHostRegistration -KeyPath $edgeNativeHostKeyPath -PreviousManifestPath $previousEdgeNativeHost
    } else {
        Write-Warning "KeepRuntime was specified. Browser native host registration was left in place for $runtimeRoot."
    }

    if ($serviceWasRunning) {
        Start-InstalledUltiGuardService -Name $serviceName
    }
}
