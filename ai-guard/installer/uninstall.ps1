param(
    [string]$InstallRoot = "$env:ProgramFiles\AI Guard Agent",
    [switch]$KeepFiles
)

$ErrorActionPreference = "Stop"

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
    $baseKey.DeleteSubKeyTree($KeyPath, $false)
    $baseKey.Dispose()
}

function Remove-RegistryValueIfPresent {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [string]$KeyPath,
        [string]$Name
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
    $key = $baseKey.OpenSubKey($KeyPath, $true)
    if ($key) {
        $key.DeleteValue($Name, $false)
        $key.Dispose()
    }
    $baseKey.Dispose()
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

. (Join-Path $PSScriptRoot "scripts\browser-policies.ps1")

$isAdmin = Test-IsAdministrator
if (-not $isAdmin -and $InstallRoot.StartsWith($env:ProgramFiles, [System.StringComparison]::OrdinalIgnoreCase)) {
    $InstallRoot = Join-Path $env:LOCALAPPDATA "AI Guard Agent"
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
$machineAdminConsoleShortcut = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\AI Guard Agent Admin Console.lnk"
$userAdminConsoleShortcut = Join-Path ([Environment]::GetFolderPath("Programs")) "AI Guard Agent Admin Console.lnk"
$claudePatchScript = Join-Path $PSScriptRoot "scripts\patch-claude-desktop.ps1"
if ($isAdmin) {
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        Stop-Service -Name $serviceName -ErrorAction SilentlyContinue
        sc.exe delete $serviceName | Out-Null
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
    Remove-RegistryKeyIfPresent -Hive $registryHive -KeyPath "SOFTWARE\Google\Chrome\NativeMessagingHosts\com.wininfosoft.ai_guard"
    Remove-RegistryKeyIfPresent -Hive $registryHive -KeyPath "SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.wininfosoft.ai_guard"
    Remove-ManagedExtensionPolicy -Hive $registryHive -Browser "Chrome" -ExtensionId "kgfkgellcbbmadimiahbfndmfbhfobko"
    Remove-ManagedExtensionPolicy -Hive $registryHive -Browser "Edge" -ExtensionId "kgfkgellcbbmadimiahbfndmfbhfobko"
    Remove-RegistryKeyIfPresent -Hive $registryHive -KeyPath "SOFTWARE\Google\Chrome\Extensions\kgfkgellcbbmadimiahbfndmfbhfobko"
    Remove-RegistryKeyIfPresent -Hive $registryHive -KeyPath "SOFTWARE\Microsoft\Edge\Extensions\kgfkgellcbbmadimiahbfndmfbhfobko"
    Remove-RegistryValueIfPresent -Hive $registryHive -KeyPath "SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "AIGuardAgent"
}

foreach ($shortcut in @($machineAdminConsoleShortcut, $userAdminConsoleShortcut)) {
    if ($shortcut -and (Test-Path $shortcut)) {
        Remove-Item -Path $shortcut -Force -ErrorAction SilentlyContinue
    }
}

if (-not $KeepFiles -and (Test-Path $InstallRoot)) {
    Remove-Item -Path $InstallRoot -Recurse -Force
}

Write-Host "AI Guard Agent removed. Restart Chrome and Edge to clear extension policy state."
