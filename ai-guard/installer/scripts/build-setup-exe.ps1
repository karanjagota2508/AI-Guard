param(
    [string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) "dist\Ulti-Guard-Setup.exe"),
    [string]$Runtime = "win-x64",
    [switch]$IncludeWheelhouse,
    [switch]$SkipSigning,
    [string]$SigningThumbprint = "",
    [string]$SigningPfxPath = "",
    [string]$SigningPfxPassword = "",
    [string]$SigningTimestampUrl = "",
    [switch]$AutoSelectSigningCertificate
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
$stagePowerShellScripts = @()
$defaultRootPfx = Join-Path $workspaceRoot "techheights-certificate.pfx"

if (-not $SigningPfxPath -and (Test-Path $defaultRootPfx)) {
    $SigningPfxPath = $defaultRootPfx
}

if (-not $SigningPfxPassword -and $env:ULTI_GUARD_PFX_PASSWORD) {
    $SigningPfxPassword = $env:ULTI_GUARD_PFX_PASSWORD
}

if (-not $AutoSelectSigningCertificate.IsPresent -and -not $SigningThumbprint -and -not $SigningPfxPath) {
    $AutoSelectSigningCertificate = $true
}

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

& (Join-Path $repoRoot "branding\generate-brand-assets.ps1")
& (Join-Path $installerRoot "scripts\package-extension.ps1") -OutputPath (Join-Path $installerRoot "dist\ai-guard-extension.crx")
& (Join-Path $PSScriptRoot "build-python-runtime.ps1")
if ($IncludeWheelhouse) {
    & (Join-Path $PSScriptRoot "build-pii-wheelhouse.ps1")
}

if (-not $SkipSigning) {
    & (Join-Path $PSScriptRoot "sign-release-artifacts.ps1") `
        -PortableExecutablePaths @((Join-Path $installerRoot "dist\ai-guard-daemon.exe")) `
        -Thumbprint $SigningThumbprint `
        -PfxPath $SigningPfxPath `
        -PfxPassword $SigningPfxPassword `
        -TimestampUrl $SigningTimestampUrl `
        -AutoSelectCertificate:$AutoSelectSigningCertificate `
        -SkipIfNoCertificate
}

try {
    if (Test-Path $payloadZip) {
        Remove-Item -Path $payloadZip -Force
    }
    if (Test-Path $stageRoot) {
        Remove-Item -Path $stageRoot -Recurse -Force
    }

    New-Item -ItemType Directory -Force -Path $stageAiGuardRoot, $stageInstallerRoot, $stagePiiRoot | Out-Null

    Copy-DirectoryFiltered -Source (Join-Path $repoRoot "branding") -Destination (Join-Path $stageAiGuardRoot "branding")
    Copy-DirectoryFiltered -Source (Join-Path $repoRoot "config") -Destination (Join-Path $stageAiGuardRoot "config")
    Copy-DirectoryFiltered -Source (Join-Path $repoRoot "desktop") -Destination (Join-Path $stageAiGuardRoot "desktop")
    Copy-DirectoryFiltered -Source (Join-Path $repoRoot "extension") -Destination (Join-Path $stageAiGuardRoot "extension")
    Copy-DirectoryFiltered -Source (Join-Path $installerRoot "scripts") -Destination (Join-Path $stageInstallerRoot "scripts")
    Copy-DirectoryFiltered `
        -Source (Join-Path $installerRoot "dist") `
        -Destination (Join-Path $stageInstallerRoot "dist") `
        -ExcludedDirectoryNames $(if ($IncludeWheelhouse) { @() } else { @("pii-wheelhouse") })

    Copy-DirectoryFiltered `
        -Source (Join-Path $workspaceRoot "PII_agent\backend") `
        -Destination (Join-Path $stagePiiRoot "backend") `
        -ExcludedDirectoryNames @(".venv", "venv", "__pycache__") `
        -ExcludedFilePatterns @("*.log")

    $stagePowerShellScripts = @(
        Get-ChildItem -Path $stageAiGuardRoot -Recurse -Filter *.ps1 -File | Select-Object -ExpandProperty FullName
    )

    if (-not $SkipSigning) {
        & (Join-Path $PSScriptRoot "sign-release-artifacts.ps1") `
            -PowerShellScriptPaths $stagePowerShellScripts `
            -Thumbprint $SigningThumbprint `
            -TimestampUrl $SigningTimestampUrl `
            -AutoSelectCertificate:$AutoSelectSigningCertificate `
            -SkipIfNoCertificate
    }

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
    Copy-Item -LiteralPath (Join-Path $publishDir "Ulti-Guard-Setup.exe") -Destination $OutputPath -Force

    if (-not $SkipSigning) {
        & (Join-Path $PSScriptRoot "sign-release-artifacts.ps1") `
            -PortableExecutablePaths @($OutputPath) `
            -Thumbprint $SigningThumbprint `
            -PfxPath $SigningPfxPath `
            -PfxPassword $SigningPfxPassword `
            -TimestampUrl $SigningTimestampUrl `
            -AutoSelectCertificate:$AutoSelectSigningCertificate `
            -SkipIfNoCertificate
    }

    Write-Host "Built Ulti Guard setup executable at $OutputPath"
}
finally {
    if (Test-Path $stageRoot) {
        Remove-Item -Path $stageRoot -Recurse -Force
    }
    if (Test-Path $payloadZip) {
        Remove-Item -Path $payloadZip -Force
    }
}
