param(
    [string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) "dist\AI-Guard-Setup.exe"),
    [string]$Runtime = "win-x64"
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression.FileSystem

$installerRoot = Split-Path $PSScriptRoot -Parent
$repoRoot = Split-Path $installerRoot -Parent
$workspaceRoot = Split-Path $repoRoot -Parent
$bootstrapperDir = Join-Path $installerRoot "bootstrapper"
$payloadZip = Join-Path $bootstrapperDir "payload.zip"
$publishDir = Join-Path $bootstrapperDir "bin\Release\net8.0-windows\$Runtime\publish"
$stageRoot = Join-Path $env:TEMP ("ai-guard-setup-payload-" + [Guid]::NewGuid().ToString("N"))
$payloadRoot = Join-Path $stageRoot "payload"
$stageAiGuardRoot = Join-Path $payloadRoot "ai-guard"
$stageInstallerRoot = Join-Path $stageAiGuardRoot "installer"
$stagePiiRoot = Join-Path $payloadRoot "PII_agent"

function Copy-DirectoryFiltered {
    param(
        [string]$Source,
        [string]$Destination,
        [string[]]$ExcludedDirectoryNames = @(),
        [string[]]$ExcludedFileNames = @(),
        [string[]]$ExcludedFilePatterns = @()
    )

    if (-not (Test-Path $Source)) {
        throw "Missing source directory: $Source"
    }

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    foreach ($item in Get-ChildItem -Force -LiteralPath $Source) {
        if ($item.PSIsContainer) {
            if ($ExcludedDirectoryNames -contains $item.Name) {
                continue
            }

            Copy-DirectoryFiltered `
                -Source $item.FullName `
                -Destination (Join-Path $Destination $item.Name) `
                -ExcludedDirectoryNames $ExcludedDirectoryNames `
                -ExcludedFileNames $ExcludedFileNames `
                -ExcludedFilePatterns $ExcludedFilePatterns
            continue
        }

        if ($ExcludedFileNames -contains $item.Name) {
            continue
        }

        $skip = $false
        foreach ($pattern in $ExcludedFilePatterns) {
            if ($item.Name -like $pattern) {
                $skip = $true
                break
            }
        }

        if ($skip) {
            continue
        }

        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $Destination $item.Name) -Force
    }
}

function Copy-FileEnsureParent {
    param(
        [string]$Source,
        [string]$Destination
    )

    $parent = Split-Path $Destination -Parent
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

if (-not (Test-Path (Join-Path $installerRoot "dist\ai-guard-daemon.exe"))) {
    throw "Missing prebuilt daemon binary at installer\dist\ai-guard-daemon.exe. Build or copy it first."
}

if (-not (Test-Path (Join-Path $installerRoot "dist\ai-guard-extension.crx"))) {
    throw "Missing packaged extension at installer\dist\ai-guard-extension.crx. Build or copy it first."
}

& (Join-Path $PSScriptRoot "build-python-runtime.ps1")
& (Join-Path $PSScriptRoot "build-pii-wheelhouse.ps1")

try {
    if (Test-Path $payloadZip) {
        Remove-Item -Path $payloadZip -Force
    }
    if (Test-Path $stageRoot) {
        Remove-Item -Path $stageRoot -Recurse -Force
    }

    New-Item -ItemType Directory -Force -Path $stageAiGuardRoot, $stageInstallerRoot, $stagePiiRoot | Out-Null

    Copy-DirectoryFiltered -Source (Join-Path $repoRoot "config") -Destination (Join-Path $stageAiGuardRoot "config")
    Copy-DirectoryFiltered -Source (Join-Path $repoRoot "desktop") -Destination (Join-Path $stageAiGuardRoot "desktop")
    Copy-DirectoryFiltered -Source (Join-Path $repoRoot "extension") -Destination (Join-Path $stageAiGuardRoot "extension")
    Copy-DirectoryFiltered -Source (Join-Path $installerRoot "scripts") -Destination (Join-Path $stageInstallerRoot "scripts")
    Copy-DirectoryFiltered -Source (Join-Path $installerRoot "dist") -Destination (Join-Path $stageInstallerRoot "dist")

    Copy-FileEnsureParent -Source (Join-Path $installerRoot "install.ps1") -Destination (Join-Path $stageInstallerRoot "install.ps1")
    Copy-FileEnsureParent -Source (Join-Path $installerRoot "install-enterprise.ps1") -Destination (Join-Path $stageInstallerRoot "install-enterprise.ps1")
    Copy-FileEnsureParent -Source (Join-Path $installerRoot "uninstall.ps1") -Destination (Join-Path $stageInstallerRoot "uninstall.ps1")

    Copy-DirectoryFiltered `
        -Source (Join-Path $workspaceRoot "PII_agent\backend") `
        -Destination (Join-Path $stagePiiRoot "backend") `
        -ExcludedDirectoryNames @(".venv", "venv", "__pycache__") `
        -ExcludedFilePatterns @("*.log")

    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $payloadRoot,
        $payloadZip,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    dotnet publish `
        (Join-Path $bootstrapperDir "AIGuard.Setup.csproj") `
        -c Release `
        -r $Runtime `
        --self-contained true `
        -p:PublishSingleFile=true `
        -p:EnableCompressionInSingleFile=true `
        -p:IncludeNativeLibrariesForSelfExtract=true

    New-Item -ItemType Directory -Force -Path (Split-Path $OutputPath -Parent) | Out-Null
    Copy-Item -LiteralPath (Join-Path $publishDir "AI-Guard-Setup.exe") -Destination $OutputPath -Force
    Write-Host "Built AI Guard setup executable at $OutputPath"
}
finally {
    if (Test-Path $stageRoot) {
        Remove-Item -Path $stageRoot -Recurse -Force
    }
    if (Test-Path $payloadZip) {
        Remove-Item -Path $payloadZip -Force
    }
}
