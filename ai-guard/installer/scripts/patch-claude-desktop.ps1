param(
    [string]$ConfigPath = "",
    [string]$HookSourcePath = "",
    [string]$ClaudeRoot = "$env:LOCALAPPDATA\AnthropicClaude",
    [switch]$Restore,
    [switch]$SkipRestart
)

$ErrorActionPreference = "Stop"

$patchSentinel = "AI_GUARD_CLAUDE_HOOK_V1"
$backupSuffix = ".ai-guard.bak"
$hookFileName = "ai-guard-claude-hook.cjs"
$bridgeFileName = "ai-guard-desktop-bridge.json"

function Get-CommandPath {
    param(
        [string]$Name
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "Required command '$Name' is not available in PATH."
    }

    return $command.Source
}

function Get-ClaudeResourceDirectories {
    param(
        [string]$Root
    )

    if (-not (Test-Path $Root)) {
        return @()
    }

    $directories = Get-ChildItem -Path $Root -Directory -Filter "app-*"
    return @(
        $directories |
            Sort-Object -Property @{
                Expression = {
                    try {
                        [version]($_.Name -replace '^app-', '')
                    } catch {
                        [version]"0.0.0.0"
                    }
                }
            } -Descending |
            ForEach-Object {
                $resourceDir = Join-Path $_.FullName "resources"
                $asarPath = Join-Path $resourceDir "app.asar"
                if (Test-Path $asarPath) {
                    [pscustomobject]@{
                        VersionName = $_.Name
                        Root = $_.FullName
                        ResourceDirectory = $resourceDir
                        AsarPath = $asarPath
                    }
                }
            }
    )
}

function Stop-ClaudeProcesses {
    $processes = @(Get-Process claude -ErrorAction SilentlyContinue | Where-Object { $_.Path })
    $restartPath = $null

    if ($processes.Count -gt 0) {
        $restartPath = @($processes | Select-Object -ExpandProperty Path -Unique)[0]
        $processes | Stop-Process -Force
        Start-Sleep -Seconds 2
    }

    return $restartPath
}

function Write-Utf8NoBomFile {
    param(
        [string]$Path,
        [string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-BridgeConfiguration {
    param(
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "AI Guard config not found at $Path"
    }

    $config = Get-Content $Path -Raw | ConvertFrom-Json
    $listenAddress = "$($config.listen_address)"
    if (-not $listenAddress) {
        throw "listen_address missing in $Path"
    }

    $extensionId = "$($config.package.extension_id)"
    if (-not $extensionId) {
        $extensionId = @($config.extension_ids)[0]
    }
    if (-not $extensionId) {
        throw "extension_id missing in $Path"
    }

    $authToken = "$($config.auth_token)"
    if (-not $authToken) {
        throw "auth_token missing in $Path"
    }

    return @{
        base_url = "http://$listenAddress"
        token = $authToken
        origin = "chrome-extension://$extensionId"
    }
}

function Invoke-Asar {
    param(
        [string[]]$Arguments
    )

    & npx --yes asar @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "asar command failed: npx --yes asar $($Arguments -join ' ')"
    }
}

function Patch-ClaudeDesktopVersion {
    param(
        [pscustomobject]$VersionInfo,
        [hashtable]$BridgeConfiguration,
        [string]$HookPath
    )

    $resourceDir = $VersionInfo.ResourceDirectory
    $asarPath = $VersionInfo.AsarPath
    $backupPath = "$asarPath$backupSuffix"
    $hookTargetPath = Join-Path $resourceDir $hookFileName
    $bridgeTargetPath = Join-Path $resourceDir $bridgeFileName

    $bridgeJson = $BridgeConfiguration | ConvertTo-Json -Depth 4
    Write-Utf8NoBomFile -Path $bridgeTargetPath -Content $bridgeJson
    Copy-Item -Path $HookPath -Destination $hookTargetPath -Force

    if (-not (Test-Path $backupPath)) {
        Copy-Item -Path $asarPath -Destination $backupPath -Force
    }

    $tempRoot = Join-Path $env:TEMP ("ai-guard-claude-" + [guid]::NewGuid().ToString("N"))
    $extractDir = Join-Path $tempRoot "extract"
    $packedAsar = Join-Path $tempRoot "app.asar"
    $mainWindowPath = Join-Path $extractDir ".vite\build\mainWindow.js"

    try {
        New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
        Invoke-Asar -Arguments @("extract", $asarPath, $extractDir)

        if (-not (Test-Path $mainWindowPath)) {
            throw "Claude Desktop preload bundle not found at $mainWindowPath"
        }

        $content = Get-Content $mainWindowPath -Raw
        if ($content -notmatch [regex]::Escape($patchSentinel)) {
            $injection = @"
;try{
  const __aiGuardPath=require("path");
  require(__aiGuardPath.join(process.resourcesPath,"$hookFileName"));
}catch(error){
  console.error("$patchSentinel",error);
}
"@
            Write-Utf8NoBomFile -Path $mainWindowPath -Content ($content + "`r`n" + $injection)
            Invoke-Asar -Arguments @("pack", $extractDir, $packedAsar)
            Copy-Item -Path $packedAsar -Destination $asarPath -Force
            return [pscustomobject]@{
                VersionName = $VersionInfo.VersionName
                Status = "patched"
                Path = $asarPath
            }
        }

        return [pscustomobject]@{
            VersionName = $VersionInfo.VersionName
            Status = "already_patched"
            Path = $asarPath
        }
    } finally {
        if (Test-Path $tempRoot) {
            Remove-Item -Path $tempRoot -Recurse -Force
        }
    }
}

function Restore-ClaudeDesktopVersion {
    param(
        [pscustomobject]$VersionInfo
    )

    $resourceDir = $VersionInfo.ResourceDirectory
    $asarPath = $VersionInfo.AsarPath
    $backupPath = "$asarPath$backupSuffix"
    $hookTargetPath = Join-Path $resourceDir $hookFileName
    $bridgeTargetPath = Join-Path $resourceDir $bridgeFileName
    $hadBackup = Test-Path $backupPath

    if ($hadBackup) {
        Copy-Item -Path $backupPath -Destination $asarPath -Force
        Remove-Item -Path $backupPath -Force
    }

    if (Test-Path $hookTargetPath) {
        Remove-Item -Path $hookTargetPath -Force
    }

    if (Test-Path $bridgeTargetPath) {
        Remove-Item -Path $bridgeTargetPath -Force
    }

    return [pscustomobject]@{
        VersionName = $VersionInfo.VersionName
        Status = if ($hadBackup) { "restored" } else { "cleaned" }
        Path = $asarPath
    }
}

$claudeVersions = @(Get-ClaudeResourceDirectories -Root $ClaudeRoot)
if ($claudeVersions.Count -eq 0) {
    Write-Host "AI Guard Agent: Claude Desktop not found under $ClaudeRoot"
    return
}

if (-not $Restore) {
    Get-CommandPath -Name "npx" | Out-Null
    if (-not (Test-Path $HookSourcePath)) {
        throw "Claude Desktop hook source not found at $HookSourcePath"
    }
}

$restartPath = Stop-ClaudeProcesses

try {
    if ($Restore) {
        $results = @($claudeVersions | ForEach-Object { Restore-ClaudeDesktopVersion -VersionInfo $_ })
    } else {
        $bridgeConfiguration = Get-BridgeConfiguration -Path $ConfigPath
        $results = @(
            $claudeVersions | ForEach-Object {
                Patch-ClaudeDesktopVersion `
                    -VersionInfo $_ `
                    -BridgeConfiguration $bridgeConfiguration `
                    -HookPath $HookSourcePath
            }
        )
    }
} finally {
    if (-not $SkipRestart -and $restartPath -and (Test-Path $restartPath)) {
        Start-Process -FilePath $restartPath
    }
}

$results | ForEach-Object {
    Write-Host "AI Guard Agent: Claude Desktop $($_.VersionName) -> $($_.Status)"
}
