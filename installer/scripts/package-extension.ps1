param(
    [string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) "dist\ai-guard-extension.crx")
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$sourceDir = Join-Path $repoRoot "extension"
$privateKeyPath = Join-Path $repoRoot "installer\assets\extension-private-key.pem"
$distDir = Split-Path $OutputPath -Parent
$tempRoot = Join-Path $env:TEMP ("ai-guard-extension-" + [Guid]::NewGuid().ToString("N"))
$tempSource = Join-Path $tempRoot "extension"
$tempProfile = Join-Path $tempRoot "profile"

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
New-Item -ItemType Directory -Force -Path $tempSource, $tempProfile | Out-Null
Copy-Item -Path (Join-Path $sourceDir "*") -Destination $tempSource -Recurse -Force

$generatedCrx = "$tempSource.crx"
$browserAttempts = @()

foreach ($browserExe in Get-BrowserPackers) {
    if (Test-Path $generatedCrx) {
        Remove-Item -Path $generatedCrx -Force
    }

    $arguments = @(
        "--user-data-dir=$tempProfile",
        "--no-first-run",
        "--pack-extension=$tempSource",
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
Remove-Item -Path $tempRoot -Recurse -Force
Write-Host "Packaged extension to $OutputPath"
