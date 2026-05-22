param(
    [string]$InstallRoot = "",
    [switch]$RelaunchClaude
)

$ErrorActionPreference = "Stop"

function Resolve-InstallRoot {
    param(
        [string]$Preferred
    )

    $candidates = @()
    if ($Preferred) {
        $candidates += $Preferred
    }
    $candidates += @(
        "$env:ProgramFiles\Ulti Guard Agent",
        "$env:ProgramFiles\AI Guard Agent",
        "$env:LOCALAPPDATA\Ulti Guard Agent",
        "$env:LOCALAPPDATA\AI Guard Agent"
    )

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if ($candidate -and (Test-Path (Join-Path $candidate "config\ai-guard.json"))) {
            return $candidate
        }
    }

    throw "Ulti Guard Agent install root not found. Pass -InstallRoot explicitly."
}

function Write-Utf8NoBomFile {
    param(
        [string]$Path,
        [string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Resolve-SourceFile {
    param(
        [string]$RepoRelativePath,
        [string]$InstalledPath
    )

    $repoCandidate = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) $RepoRelativePath
    if (Test-Path $repoCandidate) {
        return $repoCandidate
    }

    if (Test-Path $InstalledPath) {
        return $InstalledPath
    }

    throw "Could not resolve source file for $RepoRelativePath"
}

function Copy-IfDifferent {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )

    $resolvedSource = (Resolve-Path -LiteralPath $SourcePath).Path
    $resolvedDestination = $null

    if (Test-Path -LiteralPath $DestinationPath) {
        $resolvedDestination = (Resolve-Path -LiteralPath $DestinationPath).Path
    }

    if ($resolvedDestination -and $resolvedSource -eq $resolvedDestination) {
        return
    }

    Copy-Item -LiteralPath $resolvedSource -Destination $DestinationPath -Force
}

function Restart-DesktopHelper {
    param(
        [string]$HelperPath,
        [string]$ConfigPath
    )

    $existing = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -eq "powershell.exe" -and
            $_.CommandLine -like "*claude-desktop-uia-guard.ps1*"
        }

    foreach ($item in @($existing)) {
        Stop-Process -Id $item.ProcessId -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Milliseconds 600

    Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList "-NoProfile -ExecutionPolicy RemoteSigned -STA -File `"$HelperPath`" -ConfigPath `"$ConfigPath`" -PollMs 300" `
        -WindowStyle Hidden | Out-Null
}

$resolvedInstallRoot = Resolve-InstallRoot -Preferred $InstallRoot
$configPath = Join-Path $resolvedInstallRoot "config\ai-guard.json"
$installedHookPath = Join-Path $resolvedInstallRoot "desktop\claude-desktop-hook.cjs"
$installedHelperPath = Join-Path $resolvedInstallRoot "desktop\claude-desktop-uia-guard.ps1"
$launcherPath = Join-Path $resolvedInstallRoot "launch-claude-desktop.ps1"
$claudeDesktopRoot = Join-Path $resolvedInstallRoot "claude-desktop"

$hookSource = Resolve-SourceFile -RepoRelativePath "desktop\claude-desktop-hook.cjs" -InstalledPath $installedHookPath
$helperSource = Resolve-SourceFile -RepoRelativePath "desktop\claude-desktop-uia-guard.ps1" -InstalledPath $installedHelperPath

New-Item -ItemType Directory -Force -Path (Split-Path $installedHookPath -Parent) | Out-Null
Copy-IfDifferent -SourcePath $hookSource -DestinationPath $installedHookPath
Copy-IfDifferent -SourcePath $helperSource -DestinationPath $installedHelperPath

if (Test-Path $claudeDesktopRoot) {
    Get-ChildItem -Path $claudeDesktopRoot -Directory -Filter "app-*" -ErrorAction SilentlyContinue | ForEach-Object {
        $resourceHookPath = Join-Path $_.FullName "resources\ai-guard-claude-hook.cjs"
        if (Test-Path (Split-Path $resourceHookPath -Parent)) {
            Copy-IfDifferent -SourcePath $hookSource -DestinationPath $resourceHookPath
        }
    }
}

Restart-DesktopHelper -HelperPath $installedHelperPath -ConfigPath $configPath

if ($RelaunchClaude -and (Test-Path $launcherPath)) {
    Get-Process claude -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 900
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy RemoteSigned -File `"$launcherPath`"" | Out-Null
}

Write-Host ""
Write-Host "Ulti Guard Agent Claude Desktop notification fix applied."
Write-Host "Install root : $resolvedInstallRoot"
Write-Host "Hook source  : $hookSource"
Write-Host "Helper source: $helperSource"
Write-Host "Config       : $configPath"
Write-Host ""
if ($RelaunchClaude) {
    Write-Host "Claude Desktop was relaunched through the Ulti Guard launcher."
} else {
    Write-Host "If Claude Desktop is open, close it and reopen through launch-claude-desktop.ps1 for a clean test."
}
