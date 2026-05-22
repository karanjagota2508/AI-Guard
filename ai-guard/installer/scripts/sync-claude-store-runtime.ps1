param(
    [string]$ConfigPath = "",
    [string]$HookSourcePath = "",
    [string]$TargetRoot = "$env:LOCALAPPDATA\Ulti Guard Agent\claude-desktop",
    [string]$LauncherScriptPath = "",
    [string]$PatchScriptPath = "",
    [string]$UiaGuardScriptPath = "",
    [string]$StoreAppsRoot = "$env:ProgramFiles\WindowsApps",
    [switch]$Launch
)

$ErrorActionPreference = "Stop"

function Get-StoreClaudeAppPath {
    param(
        [string]$Root
    )

    $candidates = @()

    try {
        $packages = @(Get-AppxPackage *Claude* -ErrorAction Stop | Where-Object { $_.InstallLocation })
        foreach ($package in $packages) {
            $appPath = Join-Path $package.InstallLocation "app"
            if (Test-Path (Join-Path $appPath "claude.exe")) {
                $candidates += [pscustomobject]@{
                    FullName = $package.InstallLocation
                    SortVersion = try { [version]$package.Version.ToString() } catch { [version]"0.0.0.0" }
                }
            }
        }
    } catch { }

    if ($candidates.Count -eq 0 -and (Test-Path $Root)) {
        $candidates = @(
            Get-ChildItem -Path $Root -Directory -Filter "Claude_*" -ErrorAction SilentlyContinue |
                Where-Object { Test-Path (Join-Path $_.FullName "app\claude.exe") } |
                ForEach-Object {
                    [pscustomobject]@{
                        FullName = $_.FullName
                        SortVersion = try {
                            $versionText = Get-Content (Join-Path $_.FullName "app\version") -ErrorAction Stop
                            [version]$versionText.Trim()
                        } catch {
                            try {
                                [version](Get-Item (Join-Path $_.FullName "app\claude.exe")).VersionInfo.FileVersion
                            } catch {
                                [version]"0.0.0.0"
                            }
                        }
                    }
                }
        )
    }

    if (-not $candidates) {
        return $null
    }

    $selected = $candidates |
        Sort-Object -Property SortVersion -Descending |
        Select-Object -First 1

    return Join-Path $selected.FullName "app"
}

function Get-AppVersionName {
    param(
        [string]$AppPath
    )

    $versionFile = Join-Path $AppPath "version"
    if (Test-Path $versionFile) {
        $versionText = (Get-Content $versionFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
        if ($versionText) {
            return $versionText
        }
    }

    $exePath = Join-Path $AppPath "claude.exe"
    if (Test-Path $exePath) {
        $fileVersion = (Get-Item $exePath).VersionInfo.FileVersion
        if ($fileVersion) {
            return $fileVersion
        }
    }

    throw "Could not determine Claude Desktop version from $AppPath"
}

function Invoke-RoboCopyMirror {
    param(
        [string]$Source,
        [string]$Destination
    )

    $null = New-Item -ItemType Directory -Force -Path $Destination
    & robocopy $Source $Destination /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed with exit code $LASTEXITCODE while syncing $Source to $Destination"
    }
}

function Write-Utf8NoBomFile {
    param(
        [string]$Path,
        [string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

if (-not (Test-Path $ConfigPath)) {
    throw "Ulti Guard config not found at $ConfigPath"
}

if (-not (Test-Path $HookSourcePath)) {
    throw "Claude Desktop hook source not found at $HookSourcePath"
}

if (-not (Test-Path $PatchScriptPath)) {
    throw "Claude patch script not found at $PatchScriptPath"
}

$sourceAppPath = Get-StoreClaudeAppPath -Root $StoreAppsRoot
if (-not $sourceAppPath) {
    Write-Host "Ulti Guard Agent: no WindowsApps Claude Desktop package found under $StoreAppsRoot"
    return
}

$versionName = Get-AppVersionName -AppPath $sourceAppPath
$targetAppRoot = Join-Path $TargetRoot "app-$versionName"
$targetExePath = Join-Path $targetAppRoot "claude.exe"
$storeExePath = Join-Path $sourceAppPath "claude.exe"

Invoke-RoboCopyMirror -Source $sourceAppPath -Destination $targetAppRoot

& $PatchScriptPath `
    -ConfigPath $ConfigPath `
    -HookSourcePath $HookSourcePath `
    -ClaudeRoot $TargetRoot `
    -SkipRestart

if ($LauncherScriptPath) {
    $launcherContent = @"
`$ErrorActionPreference = 'Stop'
Get-Process claude -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
if ('$UiaGuardScriptPath' -and (Test-Path '$UiaGuardScriptPath')) {
  `$existing = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
      `$_.Name -eq 'powershell.exe' -and
      `$_.CommandLine -like '*claude-desktop-uia-guard.ps1*'
    } |
    Select-Object -First 1
  if (-not `$existing) {
    `$helperArgs = "-NoProfile -ExecutionPolicy RemoteSigned -STA -File ``"$UiaGuardScriptPath``" -ConfigPath ``"$ConfigPath``" -PollMs 300"
    Start-Process -FilePath 'powershell.exe' -ArgumentList `$helperArgs -WindowStyle Hidden
    Start-Sleep -Milliseconds 750
  }
}
Start-Process -FilePath '$storeExePath' -ArgumentList '--force-renderer-accessibility' -WorkingDirectory '$(Split-Path $storeExePath -Parent)'
"@
    Write-Utf8NoBomFile -Path $LauncherScriptPath -Content $launcherContent
}

Write-Host "Ulti Guard Agent: synced WindowsApps Claude Desktop -> $targetAppRoot"

if ($Launch -and (Test-Path $storeExePath)) {
    Start-Process -FilePath $storeExePath -ArgumentList "--force-renderer-accessibility" -WorkingDirectory (Split-Path $storeExePath -Parent)
}
