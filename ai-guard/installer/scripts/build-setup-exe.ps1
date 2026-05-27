param(
    [string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) "dist\Ulti Guard Setup.exe"),
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
$daemonProject = Join-Path $repoRoot "daemon"
$daemonReleaseBinary = Join-Path $daemonProject "target\release\ai-guard-daemon.exe"
$distDaemonBinary = Join-Path $installerRoot "dist\ai-guard-daemon.exe"
$payloadZip = Join-Path $bootstrapperDir "payload.zip"
$publishDir = Join-Path $bootstrapperDir "bin\Release\net8.0-windows\$Runtime\publish"
$stageRoot = Join-Path $env:TEMP ("ai-guard-setup-payload-" + [Guid]::NewGuid().ToString("N"))
$payloadRoot = Join-Path $stageRoot "payload"
$stageAiGuardRoot = Join-Path $payloadRoot "ai-guard"
$stageInstallerRoot = Join-Path $stageAiGuardRoot "installer"
$stagePiiRoot = Join-Path $payloadRoot "PII_agent"
$stagePowerShellScripts = @()
$defaultRootPfx = Join-Path $workspaceRoot "techheights-certificate.pfx"
$preferredSigningSubject = "CN=techheights.com"
$canonicalOutputPath = Join-Path $installerRoot "dist\Ulti Guard Setup.exe"
$canonicalOutputDirectory = Split-Path $canonicalOutputPath -Parent
$legacySetupArtifactPatterns = @(
    "AI-Guard-Setup*.exe",
    "Ulti Guard Setup*.exe"
)

function Get-PreferredStoreCertificateThumbprint {
    param(
        [string]$Subject
    )

    $stores = @("Cert:\CurrentUser\My", "Cert:\LocalMachine\My")
    $candidates = foreach ($store in $stores) {
        Get-ChildItem -Path $store -CodeSigningCert -ErrorAction SilentlyContinue |
            Where-Object { $_.Subject -eq $Subject }
    }

    return $candidates |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1 -ExpandProperty Thumbprint
}

if (-not $SigningPfxPassword -and $env:ULTI_GUARD_PFX_PASSWORD) {
    $SigningPfxPassword = $env:ULTI_GUARD_PFX_PASSWORD
}

if (-not $SigningThumbprint) {
    $preferredThumbprint = Get-PreferredStoreCertificateThumbprint -Subject $preferredSigningSubject
    if ($preferredThumbprint) {
        $SigningThumbprint = $preferredThumbprint
        $AutoSelectSigningCertificate = $false
    }
}

if (-not $SigningPfxPath -and (Test-Path $defaultRootPfx) -and $SigningPfxPassword) {
    $SigningPfxPath = $defaultRootPfx
}

if (-not $AutoSelectSigningCertificate.IsPresent -and -not $SigningThumbprint -and -not $SigningPfxPath) {
    $AutoSelectSigningCertificate = $true
}

if (-not $SigningTimestampUrl) {
    $SigningTimestampUrl = "http://timestamp.digicert.com"
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

function Copy-FileWithRetry {
    param(
        [string]$Source,
        [string]$Destination,
        [int]$MaxAttempts = 5
    )

    $parent = Split-Path $Destination -Parent
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt += 1) {
        try {
            Copy-Item -LiteralPath $Source -Destination $Destination -Force
            return
        } catch {
            if ($attempt -ge $MaxAttempts) {
                throw
            }

            Start-Sleep -Seconds ([Math]::Min($attempt * 2, 8))
        }
    }
}

function Remove-StaleSetupArtifacts {
    param(
        [string]$DirectoryPath,
        [string]$CanonicalFilePath
    )

    if (-not (Test-Path $DirectoryPath)) {
        return
    }

    $canonicalResolvedPath = $null
    if (Test-Path $CanonicalFilePath) {
        $canonicalResolvedPath = (Resolve-Path -LiteralPath $CanonicalFilePath).Path
    }

    foreach ($pattern in $legacySetupArtifactPatterns) {
        foreach ($artifact in Get-ChildItem -Path $DirectoryPath -Filter $pattern -File -ErrorAction SilentlyContinue) {
            $artifactPath = $artifact.FullName
            if ($canonicalResolvedPath -and [string]::Equals($artifactPath, $canonicalResolvedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            Remove-Item -LiteralPath $artifactPath -Force -ErrorAction Stop
        }
    }
}

if ((Split-Path $OutputPath -Parent) -eq $canonicalOutputDirectory -and
    -not [string]::Equals($OutputPath, $canonicalOutputPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Custom setup output names inside installer\\dist are no longer supported. Use the canonical artifact path $canonicalOutputPath."
}

New-Item -ItemType Directory -Force -Path $canonicalOutputDirectory | Out-Null
Remove-StaleSetupArtifacts -DirectoryPath $canonicalOutputDirectory -CanonicalFilePath $canonicalOutputPath

cargo build --release --manifest-path (Join-Path $daemonProject "Cargo.toml")
if (-not (Test-Path $daemonReleaseBinary)) {
    throw "Failed to build the Ulti Guard daemon release binary at $daemonReleaseBinary."
}
New-Item -ItemType Directory -Force -Path (Split-Path $distDaemonBinary -Parent) | Out-Null
Copy-Item -LiteralPath $daemonReleaseBinary -Destination $distDaemonBinary -Force

& (Join-Path $repoRoot "branding\generate-brand-assets.ps1")
& (Join-Path $installerRoot "scripts\package-extension.ps1") `
    -OutputPath (Join-Path $installerRoot "dist\ai-guard-extension.crx") `
    -ChromeStoreZipPath (Join-Path $installerRoot "dist\ai-guard-extension-chrome-store.zip") `
    -EdgeStoreZipPath (Join-Path $installerRoot "dist\ai-guard-extension-edge-store.zip")
& (Join-Path $installerRoot "scripts\publish-admin-console.ps1") -OutputPath (Join-Path $installerRoot "dist\admin-console")
& (Join-Path $PSScriptRoot "build-python-runtime.ps1")
if ($IncludeWheelhouse) {
    & (Join-Path $PSScriptRoot "build-pii-wheelhouse.ps1")
}

if (-not $SkipSigning) {
    & (Join-Path $PSScriptRoot "sign-release-artifacts.ps1") `
        -PortableExecutablePaths @(
            (Join-Path $installerRoot "dist\ai-guard-daemon.exe"),
            (Join-Path $installerRoot "dist\admin-console\AI-Guard-Admin-Console.exe")
        ) `
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
    Copy-DirectoryFiltered -Source (Join-Path $repoRoot "shared") -Destination (Join-Path $stageAiGuardRoot "shared")
    Copy-DirectoryFiltered -Source (Join-Path $installerRoot "scripts") -Destination (Join-Path $stageInstallerRoot "scripts")
    Copy-DirectoryFiltered `
        -Source (Join-Path $installerRoot "dist") `
        -Destination (Join-Path $stageInstallerRoot "dist") `
        -ExcludedDirectoryNames $(if ($IncludeWheelhouse) { @() } else { @("pii-wheelhouse") }) `
        -ExcludedFileNames @([System.IO.Path]::GetFileName($canonicalOutputPath)) `
        -ExcludedFilePatterns $legacySetupArtifactPatterns
    Copy-FileEnsureParent -Source (Join-Path $installerRoot "install.ps1") -Destination (Join-Path $stageInstallerRoot "install.ps1")
    Copy-FileEnsureParent -Source (Join-Path $installerRoot "install-enterprise.ps1") -Destination (Join-Path $stageInstallerRoot "install-enterprise.ps1")
    Copy-FileEnsureParent -Source (Join-Path $installerRoot "uninstall.ps1") -Destination (Join-Path $stageInstallerRoot "uninstall.ps1")

    Copy-DirectoryFiltered `
        -Source (Join-Path $workspaceRoot "PII_agent\backend") `
        -Destination (Join-Path $stagePiiRoot "backend") `
        -ExcludedDirectoryNames @(".venv", "venv", "__pycache__") `
        -ExcludedFilePatterns @("*.log")

    foreach ($removedScript in @(
        (Join-Path $stageInstallerRoot "scripts\admin-console.ps1"),
        (Join-Path $stageInstallerRoot "scripts\prepare-browser-test-mode.ps1"),
        (Join-Path $stageInstallerRoot "scripts\run-local-browser-smoke-test.ps1"),
        (Join-Path $stageInstallerRoot "scripts\fix-claude-desktop-notification.ps1")
    )) {
        if (Test-Path $removedScript) {
            Remove-Item -Path $removedScript -Force
        }
    }

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

    Copy-FileWithRetry `
        -Source (Join-Path $publishDir "Ulti Guard Setup.exe") `
        -Destination $canonicalOutputPath

    if (-not $SkipSigning) {
        & (Join-Path $PSScriptRoot "sign-release-artifacts.ps1") `
            -PortableExecutablePaths @($canonicalOutputPath) `
            -Thumbprint $SigningThumbprint `
            -PfxPath $SigningPfxPath `
            -PfxPassword $SigningPfxPassword `
            -TimestampUrl $SigningTimestampUrl `
            -AutoSelectCertificate:$AutoSelectSigningCertificate `
            -SkipIfNoCertificate
    }

    if (-not [string]::Equals($OutputPath, $canonicalOutputPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        Copy-FileWithRetry `
            -Source $canonicalOutputPath `
            -Destination $OutputPath
    }

    Remove-StaleSetupArtifacts -DirectoryPath $canonicalOutputDirectory -CanonicalFilePath $canonicalOutputPath
    Write-Host "Built Ulti Guard setup executable at $canonicalOutputPath"
}
finally {
    if (Test-Path $stageRoot) {
        Remove-Item -Path $stageRoot -Recurse -Force
    }
    if (Test-Path $payloadZip) {
        Remove-Item -Path $payloadZip -Force
    }
}
