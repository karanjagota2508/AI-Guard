param(
    [string]$InstallRoot = "$env:ProgramFiles\Ulti Guard Agent",
    [switch]$KeepFiles
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

$machineInstallRoot = "$env:ProgramFiles\Ulti Guard Agent"
$legacyMachineInstallRoot = "$env:ProgramFiles\AI Guard Agent"
$userInstallRoot = Join-Path $env:LOCALAPPDATA "Ulti Guard Agent"
$legacyUserInstallRoot = Join-Path $env:LOCALAPPDATA "AI Guard Agent"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Remove-RegistryKeyIfPresent {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [string]$KeyPath
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $baseKey.DeleteSubKeyTree($KeyPath, $false)
    } catch [System.UnauthorizedAccessException] {
    } finally {
        $baseKey.Dispose()
    }
}

function Remove-RegistryValueIfPresent {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [string]$KeyPath,
        [string]$Name
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $baseKey.OpenSubKey($KeyPath, $true)
        if ($key) {
            try {
                $key.DeleteValue($Name, $false)
            } catch [System.UnauthorizedAccessException] {
            } finally {
                $key.Dispose()
            }
        }
    } finally {
        $baseKey.Dispose()
    }
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

function Remove-ChromeShortcutLoadExtensionArgument {
    param(
        [string]$ShortcutPath,
        [string]$ExtensionDirectory
    )

    $shortcut = Get-ShortcutObject -ShortcutPath $ShortcutPath
    if (-not $shortcut) {
        return $false
    }

    $targetLeaf = [System.IO.Path]::GetFileName([string]$shortcut.TargetPath)
    if ($targetLeaf -notin @("chrome.exe", "chrome_proxy.exe")) {
        return $false
    }

    $existingArguments = [string]$shortcut.Arguments
    if (-not $existingArguments) {
        return $false
    }

    $escapedExtensionDirectory = [Regex]::Escape($ExtensionDirectory)
    $updatedArguments = $existingArguments -replace "--load-extension=""$escapedExtensionDirectory""", ""
    $updatedArguments = $updatedArguments -replace '--load-extension=(?:"[^"]*"|\S+)', {
        param($match)
        if ($match.Value -match [Regex]::Escape($ExtensionDirectory)) { "" } else { $match.Value }
    }
    $updatedArguments = ($updatedArguments -replace '\s{2,}', ' ').Trim()

    if ($updatedArguments -eq $existingArguments) {
        return $false
    }

    $shortcut.Arguments = $updatedArguments
    $shortcut.Save()
    return $true
}

. (Join-Path $InstallerScriptRoot "scripts\browser-policies.ps1")

$isAdmin = Test-IsAdministrator
if (-not $isAdmin -and $InstallRoot.StartsWith($env:ProgramFiles, [System.StringComparison]::OrdinalIgnoreCase)) {
    $InstallRoot = $userInstallRoot
}

if (-not (Test-Path $InstallRoot)) {
    if ($isAdmin -and (Test-Path $legacyMachineInstallRoot)) {
        $InstallRoot = $legacyMachineInstallRoot
    } elseif (-not $isAdmin -and (Test-Path $legacyUserInstallRoot)) {
        $InstallRoot = $legacyUserInstallRoot
    }
}

$registryHives = if ($isAdmin) {
    @(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryHive]::CurrentUser
    )
} else {
    @([Microsoft.Win32.RegistryHive]::CurrentUser)
}

$serviceName = "AIGuardAgent"
$machineAdminConsoleShortcut = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Ulti Guard Agent Admin Console.lnk"
$userAdminConsoleShortcut = Join-Path ([Environment]::GetFolderPath("Programs")) "Ulti Guard Agent Admin Console.lnk"
$machineBrowserTestModeShortcut = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Ulti Guard Browser Test Mode.lnk"
$userBrowserTestModeShortcut = Join-Path ([Environment]::GetFolderPath("Programs")) "Ulti Guard Browser Test Mode.lnk"
$legacyMachineAdminConsoleShortcut = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\AI Guard Agent Admin Console.lnk"
$legacyUserAdminConsoleShortcut = Join-Path ([Environment]::GetFolderPath("Programs")) "AI Guard Agent Admin Console.lnk"
$managedChromeShortcut = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Ulti Guard Google Chrome.lnk"
$claudePatchScript = Join-Path $InstallerScriptRoot "scripts\patch-claude-desktop.ps1"
if ($isAdmin) {
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        Stop-Service -Name $serviceName -ErrorAction SilentlyContinue
        $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
        if ($service) {
            $service | Invoke-CimMethod -MethodName Delete -ErrorAction SilentlyContinue | Out-Null
        }
        Start-Sleep -Seconds 2
    }
} else {
    $daemonListener = Get-NetTCPConnection -LocalPort 48555 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($daemonListener) {
        $daemonOwner = Get-Process -Id $daemonListener.OwningProcess -ErrorAction SilentlyContinue
        if ($daemonOwner -and $daemonOwner.ProcessName -eq "ai-guard-daemon") {
            Stop-Process -Id $daemonOwner.Id -Force
        }
    }
}

if (Test-Path $claudePatchScript) {
    & $claudePatchScript -Restore -SkipRestart
}

Stop-ProcessesByCommandLinePattern -Patterns @(
    "claude-desktop-uia-guard.ps1",
    "launch-claude-desktop.ps1"
)

$piiListener = Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($piiListener) {
    $piiOwner = Get-Process -Id $piiListener.OwningProcess -ErrorAction SilentlyContinue
    if ($piiOwner -and $piiOwner.ProcessName -eq "python") {
        Stop-Process -Id $piiOwner.Id -Force
    }
}

foreach ($registryHive in $registryHives) {
    try {
        Remove-RegistryKeyIfPresent -Hive $registryHive -KeyPath "SOFTWARE\Google\Chrome\NativeMessagingHosts\com.wininfosoft.ai_guard"
        Remove-RegistryKeyIfPresent -Hive $registryHive -KeyPath "SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.wininfosoft.ai_guard"
        Remove-ManagedExtensionPolicy -Hive $registryHive -Browser "Chrome" -ExtensionId "kgfkgellcbbmadimiahbfndmfbhfobko"
        Remove-ManagedExtensionPolicy -Hive $registryHive -Browser "Edge" -ExtensionId "kgfkgellcbbmadimiahbfndmfbhfobko"
        Remove-RegistryKeyIfPresent -Hive $registryHive -KeyPath "SOFTWARE\Google\Chrome\Extensions\kgfkgellcbbmadimiahbfndmfbhfobko"
        Remove-RegistryKeyIfPresent -Hive $registryHive -KeyPath "SOFTWARE\Microsoft\Edge\Extensions\kgfkgellcbbmadimiahbfndmfbhfobko"
        Remove-RegistryValueIfPresent -Hive $registryHive -KeyPath "SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "AIGuardAgent"
    } catch [System.UnauthorizedAccessException] {
        Write-Warning "Skipping some registry cleanup under $registryHive because access was denied."
    } catch {
        Write-Warning "Skipping some registry cleanup under $registryHive because: $($_.Exception.Message)"
    }
}

foreach ($shortcut in @(
    $machineAdminConsoleShortcut,
    $userAdminConsoleShortcut,
    $machineBrowserTestModeShortcut,
    $userBrowserTestModeShortcut,
    $legacyMachineAdminConsoleShortcut,
    $legacyUserAdminConsoleShortcut
)) {
    if ($shortcut -and (Test-Path $shortcut)) {
        Remove-Item -Path $shortcut -Force -ErrorAction SilentlyContinue
    }
}

$installedExtensionDirectory = Join-Path $InstallRoot "extension"
foreach ($shortcutPath in Get-ChromeShortcutCandidatePaths) {
    Remove-ChromeShortcutLoadExtensionArgument -ShortcutPath $shortcutPath -ExtensionDirectory $installedExtensionDirectory | Out-Null
}
if (Test-Path $managedChromeShortcut) {
    Remove-Item -Path $managedChromeShortcut -Force -ErrorAction SilentlyContinue
}

if (-not $KeepFiles) {
    $rootsToRemove = if ($isAdmin) {
        @($InstallRoot, $machineInstallRoot, $legacyMachineInstallRoot, $userInstallRoot, $legacyUserInstallRoot)
    } else {
        @($InstallRoot, $userInstallRoot, $legacyUserInstallRoot)
    }

    foreach ($root in @($rootsToRemove | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-Path $root) {
            try {
                Remove-Item -Path $root -Recurse -Force
            } catch {
                Write-Warning ("Could not fully remove {0}: {1}" -f $root, $_.Exception.Message)
            }
        }
    }
}

Write-Host "Ulti Guard Agent removed. Restart Chrome and Edge to clear extension policy state."
