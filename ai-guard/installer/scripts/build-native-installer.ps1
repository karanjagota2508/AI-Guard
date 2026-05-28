param(
    [string]$Runtime = "win-x64",
    [string]$Version = "1.0.1",
    [string]$OutputDir = "",
    [switch]$SkipSigning,
    [string]$SigningThumbprint = "",
    [string]$SigningPfxPath = "",
    [string]$SigningPfxPassword = "",
    [string]$SigningTimestampUrl = "",
    [switch]$AutoSelectSigningCertificate
)

$ErrorActionPreference = "Stop"

function Copy-DirectoryFiltered {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path $Source)) {
        throw "Missing source directory: $Source"
    }

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Copy-Item -Path (Join-Path $Source "*") -Destination $Destination -Recurse -Force
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

$installerRoot = Split-Path $PSScriptRoot -Parent
$repoRoot = Split-Path $installerRoot -Parent
$workspaceRoot = Split-Path $repoRoot -Parent
$distDir = Join-Path $installerRoot "dist"
$outputDirectory = if ($OutputDir) { $OutputDir } else { $distDir }
$packageProject = Join-Path $installerRoot "wix\package\AIGuard.Package.wixproj"
$bundleProject = Join-Path $installerRoot "wix\bundle\AIGuard.Bundle.wixproj"
$packageOutput = Join-Path $outputDirectory "Ulti Guard.msi"
$bundleOutput = Join-Path $outputDirectory "Ulti Guard Setup.exe"
$buildStage = Join-Path $env:TEMP ("ai-guard-native-build-" + [Guid]::NewGuid().ToString("N"))
$artifactStage = Join-Path $buildStage "artifacts"
$payloadRoot = Join-Path $buildStage "payload"
$stagedDaemonPath = Join-Path $artifactStage "ai-guard-daemon.exe"
$stagedCrxPath = Join-Path $artifactStage "ai-guard-extension.crx"
$stagedChromeStoreZipPath = Join-Path $artifactStage "ai-guard-extension-chrome-store.zip"
$stagedEdgeStoreZipPath = Join-Path $artifactStage "ai-guard-extension-edge-store.zip"
$stagedAdminConsoleDir = Join-Path $artifactStage "admin-console"
$stagedDesktopSessionDir = Join-Path $artifactStage "desktop-session"
$stagedSetupActionsDir = Join-Path $artifactStage "setup-actions"
$stagedPythonRuntimeDir = Join-Path $artifactStage "python-runtime"
$stagedPiiRuntimeDir = Join-Path $artifactStage "pii-runtime"
$defaultRootPfx = Join-Path $workspaceRoot "techheights-certificate.pfx"
$preferredSigningSubject = "CN=techheights.com"

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

New-Item -ItemType Directory -Force -Path $distDir, $outputDirectory | Out-Null
if (Test-Path $buildStage) {
    Remove-Item -Path $buildStage -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $artifactStage | Out-Null

cargo build --release --manifest-path (Join-Path $repoRoot "daemon\Cargo.toml")
Copy-FileEnsureParent `
    -Source (Join-Path $repoRoot "daemon\target\release\ai-guard-daemon.exe") `
    -Destination $stagedDaemonPath

& (Join-Path $repoRoot "branding\generate-brand-assets.ps1")
& (Join-Path $installerRoot "scripts\package-extension.ps1") `
    -OutputPath $stagedCrxPath `
    -ChromeStoreZipPath $stagedChromeStoreZipPath `
    -EdgeStoreZipPath $stagedEdgeStoreZipPath
& (Join-Path $installerRoot "scripts\publish-admin-console.ps1") -Runtime $Runtime -OutputPath $stagedAdminConsoleDir
& (Join-Path $installerRoot "scripts\publish-desktop-session.ps1") -Runtime $Runtime -OutputPath $stagedDesktopSessionDir
& (Join-Path $installerRoot "scripts\publish-setup-actions.ps1") -Runtime $Runtime -OutputPath $stagedSetupActionsDir
& (Join-Path $installerRoot "scripts\build-python-runtime.ps1") -OutputDir $stagedPythonRuntimeDir
& (Join-Path $installerRoot "scripts\build-pii-runtime.ps1") -OutputDir $stagedPiiRuntimeDir

if (-not $SkipSigning) {
    & (Join-Path $installerRoot "scripts\sign-release-artifacts.ps1") `
        -PortableExecutablePaths @(
            $stagedDaemonPath,
            (Join-Path $stagedAdminConsoleDir "AI-Guard-Admin-Console.exe"),
            (Join-Path $stagedDesktopSessionDir "AIGuard.DesktopSessionHelper.exe"),
            (Join-Path $stagedSetupActionsDir "AIGuard.Setup.Actions.exe")
        ) `
        -Thumbprint $SigningThumbprint `
        -PfxPath $SigningPfxPath `
        -PfxPassword $SigningPfxPassword `
        -TimestampUrl $SigningTimestampUrl `
        -AutoSelectCertificate:$AutoSelectSigningCertificate `
        -SkipIfNoCertificate
}

try {
    New-Item -ItemType Directory -Force -Path $payloadRoot | Out-Null

    Copy-FileEnsureParent -Source $stagedDaemonPath -Destination (Join-Path $payloadRoot "ai-guard-daemon.exe")
    Copy-DirectoryFiltered -Source $stagedAdminConsoleDir -Destination (Join-Path $payloadRoot "admin-console")
    Copy-DirectoryFiltered -Source $stagedDesktopSessionDir -Destination (Join-Path $payloadRoot "desktop-session")
    Copy-DirectoryFiltered -Source $stagedSetupActionsDir -Destination (Join-Path $payloadRoot "setup-actions")
    Copy-DirectoryFiltered -Source $stagedPythonRuntimeDir -Destination (Join-Path $payloadRoot "python-runtime")
    Copy-DirectoryFiltered -Source $stagedPiiRuntimeDir -Destination (Join-Path $payloadRoot "pii-runtime")
    Copy-DirectoryFiltered -Source (Join-Path $repoRoot "branding") -Destination (Join-Path $payloadRoot "branding")
    Copy-DirectoryFiltered -Source (Join-Path $repoRoot "config") -Destination (Join-Path $payloadRoot "config")
    Copy-DirectoryFiltered -Source (Join-Path $repoRoot "extension") -Destination (Join-Path $payloadRoot "extension")
    Copy-DirectoryFiltered -Source (Join-Path $repoRoot "shared") -Destination (Join-Path $payloadRoot "shared")
    Copy-FileEnsureParent -Source (Join-Path $repoRoot "desktop\claude-desktop-hook.cjs") -Destination (Join-Path $payloadRoot "desktop\claude-desktop-hook.cjs")
    Copy-FileEnsureParent -Source $stagedCrxPath -Destination (Join-Path $payloadRoot "dist\ai-guard-extension.crx")
    & (Join-Path $installerRoot "scripts\generate-wix-payload.ps1") `
        -PayloadRoot $payloadRoot `
        -OutputPath (Join-Path $installerRoot "wix\package\Payload.generated.wxs")

    dotnet build `
        $packageProject `
        -c Release `
        -p:PayloadRoot="$payloadRoot" `
        -p:ProductVersion="$Version"
    $packageExitCode = $LASTEXITCODE
    $packageProjectDir = Split-Path $packageProject -Parent
    $builtMsi = Join-Path $packageProjectDir "bin\Release\Ulti Guard.msi"
    if (-not (Test-Path $builtMsi)) {
        $builtMsi = Join-Path $packageProjectDir "obj\Release\Ulti Guard.msi"
    }
    if (-not (Test-Path $builtMsi)) {
        throw "Expected MSI output was not found at $builtMsi"
    }
    if ($packageExitCode -ne 0) {
        Write-Warning "WiX package build returned exit code $packageExitCode, but a usable MSI artifact was produced at $builtMsi. Continuing with that artifact."
    }

    Copy-FileEnsureParent -Source $builtMsi -Destination $packageOutput

    if (-not $SkipSigning) {
        & (Join-Path $installerRoot "scripts\sign-release-artifacts.ps1") `
            -PortableExecutablePaths @($packageOutput) `
            -Thumbprint $SigningThumbprint `
            -PfxPath $SigningPfxPath `
            -PfxPassword $SigningPfxPassword `
            -TimestampUrl $SigningTimestampUrl `
            -AutoSelectCertificate:$AutoSelectSigningCertificate `
            -SkipIfNoCertificate
    }

    dotnet build `
        $bundleProject `
        -c Release `
        -p:BundleVersion="$Version" `
        -p:MsiPath="$packageOutput"

    $builtBundle = Join-Path (Split-Path $bundleProject -Parent) "bin\Release\Ulti Guard Setup.exe"
    if (-not (Test-Path $builtBundle)) {
        throw "Expected bundle output was not found at $builtBundle"
    }

    Copy-FileEnsureParent -Source $builtBundle -Destination $bundleOutput
    Copy-FileEnsureParent -Source $stagedDaemonPath -Destination (Join-Path $outputDirectory "ai-guard-daemon.exe")
    Copy-FileEnsureParent -Source $stagedCrxPath -Destination (Join-Path $outputDirectory "ai-guard-extension.crx")
    Copy-FileEnsureParent -Source $stagedChromeStoreZipPath -Destination (Join-Path $outputDirectory "ai-guard-extension-chrome-store.zip")
    Copy-FileEnsureParent -Source $stagedEdgeStoreZipPath -Destination (Join-Path $outputDirectory "ai-guard-extension-edge-store.zip")

    if (-not $SkipSigning) {
        & (Join-Path $installerRoot "scripts\sign-release-artifacts.ps1") `
            -PortableExecutablePaths @($bundleOutput) `
            -Thumbprint $SigningThumbprint `
            -PfxPath $SigningPfxPath `
            -PfxPassword $SigningPfxPassword `
            -TimestampUrl $SigningTimestampUrl `
            -AutoSelectCertificate:$AutoSelectSigningCertificate `
            -SkipIfNoCertificate
    }

    Write-Host "Built Ulti Guard MSI at $packageOutput"
    Write-Host "Built Ulti Guard bundle at $bundleOutput"
}
finally {
    if (Test-Path $buildStage) {
        Remove-Item -Path $buildStage -Recurse -Force
    }
}
