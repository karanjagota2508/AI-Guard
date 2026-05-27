param(
    [string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) "dist\ai-guard-extension.crx"),
    [string]$ChromeStoreZipPath = "",
    [string]$EdgeStoreZipPath = ""
)

$ErrorActionPreference = "Stop"

$localUpdateUrl = "http://127.0.0.1:48555/update.xml"
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$sourceDir = Join-Path $repoRoot "extension"
$privateKeyPath = Join-Path $repoRoot "installer\assets\extension-private-key.pem"
$distDir = Split-Path $OutputPath -Parent
$tempRoot = Join-Path $env:TEMP ("ai-guard-extension-" + [Guid]::NewGuid().ToString("N"))
$tempLocalSource = Join-Path $tempRoot "extension-local"
$tempStoreSource = Join-Path $tempRoot "extension-store"
$tempProfile = Join-Path $tempRoot "profile"

Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not $ChromeStoreZipPath) {
    $ChromeStoreZipPath = Join-Path $distDir "ai-guard-extension-chrome-store.zip"
}

if (-not $EdgeStoreZipPath) {
    $EdgeStoreZipPath = Join-Path $distDir "ai-guard-extension-edge-store.zip"
}

function Write-JsonNoBom {
    param(
        [string]$Path,
        $Object
    )

    $json = $Object | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-BrowserPackers {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe"),
        (Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Microsoft\Edge\Application\msedge.exe"),
        (Join-Path $env:ProgramFiles "Microsoft\Edge\Application\msedge.exe")
    )

    $available = @()
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            $available += $candidate
        }
    }

    if ($available.Count -eq 0) {
        throw "Could not find Microsoft Edge or Google Chrome for extension packaging."
    }

    return $available
}

New-Item -ItemType Directory -Force -Path $distDir | Out-Null
New-Item -ItemType Directory -Force -Path $tempLocalSource, $tempStoreSource, $tempProfile | Out-Null
Copy-Item -Path (Join-Path $sourceDir "*") -Destination $tempLocalSource -Recurse -Force
Copy-Item -Path (Join-Path $sourceDir "*") -Destination $tempStoreSource -Recurse -Force
foreach ($artifactPath in @($OutputPath, $ChromeStoreZipPath, $EdgeStoreZipPath)) {
    if ($artifactPath -and (Test-Path $artifactPath)) {
        Remove-Item -Path $artifactPath -Force
    }
}

$localManifestPath = Join-Path $tempLocalSource "manifest.json"
$localManifest = Get-Content -Path $localManifestPath -Raw | ConvertFrom-Json
$localManifest | Add-Member -NotePropertyName "update_url" -NotePropertyValue $localUpdateUrl -Force
Write-JsonNoBom -Path $localManifestPath -Object $localManifest

$generatedCrx = "$tempLocalSource.crx"
$browserAttempts = @()

foreach ($browserExe in Get-BrowserPackers) {
    if (Test-Path $generatedCrx) {
        Remove-Item -Path $generatedCrx -Force
    }

    $arguments = @(
        "--user-data-dir=$tempProfile",
        "--no-first-run",
        "--pack-extension=$tempLocalSource",
        "--pack-extension-key=$privateKeyPath"
    )

    & $browserExe @arguments 2>$null | Out-Null
    $exitCode = $LASTEXITCODE
    $browserAttempts += "$browserExe => $exitCode"

    if (Test-Path $generatedCrx) {
        if ($exitCode -ne 0) {
            Write-Warning "Browser returned exit code $exitCode, but the CRX package was created successfully."
        }
        break
    }
}

if (-not (Test-Path $generatedCrx)) {
    throw "Extension packaging failed. Attempts: $($browserAttempts -join '; ')"
}

Copy-Item -Path $generatedCrx -Destination $OutputPath -Force
[System.IO.Compression.ZipFile]::CreateFromDirectory($tempStoreSource, $ChromeStoreZipPath)
[System.IO.Compression.ZipFile]::CreateFromDirectory($tempStoreSource, $EdgeStoreZipPath)
Remove-Item -Path $tempRoot -Recurse -Force
Write-Host "Packaged local test extension to $OutputPath"
Write-Host "Packaged Chrome store submission to $ChromeStoreZipPath"
Write-Host "Packaged Edge store submission to $EdgeStoreZipPath"
