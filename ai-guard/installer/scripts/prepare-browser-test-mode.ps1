param(
    [string]$SourceExtensionDir = "",
    [string]$OutputRoot = "",
    [string]$InstallRoot = "",
    [switch]$OpenFolder,
    [switch]$OpenChrome,
    [switch]$OpenEdge,
    [switch]$OpenReadme
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

function Find-BrowserExecutable {
    param(
        [ValidateSet("Chrome", "Edge")]
        [string]$Browser
    )

    $candidates = if ($Browser -eq "Chrome") {
        @(
            (Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe"),
            (Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe")
        )
    } else {
        @(
            (Join-Path ${env:ProgramFiles(x86)} "Microsoft\Edge\Application\msedge.exe"),
            (Join-Path $env:ProgramFiles "Microsoft\Edge\Application\msedge.exe")
        )
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    return $null
}

if (-not $SourceExtensionDir) {
    if ($InstallRoot) {
        $SourceExtensionDir = Join-Path $InstallRoot "extension"
    } else {
        $candidateInstallRoots = @(
            (Join-Path $env:ProgramFiles "Ulti Guard Agent"),
            (Join-Path $env:LOCALAPPDATA "Ulti Guard Agent"),
            (Join-Path $env:ProgramFiles "AI Guard Agent"),
            (Join-Path $env:LOCALAPPDATA "AI Guard Agent")
        )

        foreach ($candidateInstallRoot in $candidateInstallRoots) {
            $candidateExtensionDir = Join-Path $candidateInstallRoot "extension"
            if (Test-Path $candidateExtensionDir) {
                $InstallRoot = $candidateInstallRoot
                $SourceExtensionDir = $candidateExtensionDir
                break
            }
        }
    }
}

if (-not $SourceExtensionDir -or -not (Test-Path $SourceExtensionDir)) {
    throw "Could not locate the Ulti Guard extension source directory."
}

if (-not $OutputRoot) {
    if ($InstallRoot) {
        $OutputRoot = Join-Path $InstallRoot "browser-test-mode"
    } else {
        $OutputRoot = Join-Path $env:LOCALAPPDATA "Ulti Guard Browser Test Mode"
    }
}

$testExtensionDir = Join-Path $OutputRoot "extension"
$readmePath = Join-Path $OutputRoot "README.txt"

if (Test-Path $OutputRoot) {
    Remove-Item -Path $OutputRoot -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $testExtensionDir | Out-Null
Copy-Item -Path (Join-Path $SourceExtensionDir "*") -Destination $testExtensionDir -Recurse -Force

$manifestPath = Join-Path $testExtensionDir "manifest.json"
$manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json

$manifest.PSObject.Properties.Remove("update_url")
$manifest.name = "Ulti Guard Agent Test Mode"
$manifest.description = "Testing package for Ulti Guard web prompt protection. Load unpacked for browser testing."

$manifestJson = $manifest | ConvertTo-Json -Depth 20
$encoding = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($manifestPath, $manifestJson, $encoding)

$readme = @"
Ulti Guard Browser Test Mode
============================

This package is for browser testing only.
It keeps the same fixed extension key so native messaging and daemon communication continue to work.

Extension folder:
$testExtensionDir

Chrome / Edge steps:
1. Open the browser extensions page.
2. Turn on Developer mode.
3. Click Load unpacked.
4. Select this folder:
   $testExtensionDir
5. Open http://127.0.0.1:48555/__ulti_guard_test__/mock-claude and test prompt redaction / blocking.
6. Open a blocked provider such as https://chatgpt.com while the mock Claude page remains open.

Notes:
- This test mode is not the locked production deployment.
- Users can remove or disable this unpacked extension.
- Production enterprise install remains unchanged.
- For a fully automated local smoke test on a developer machine, run:
  powershell -NoProfile -ExecutionPolicy RemoteSigned -File "$repoRoot\installer\scripts\run-local-browser-smoke-test.ps1"
"@
[System.IO.File]::WriteAllText($readmePath, $readme, $encoding)

if ($OpenFolder) {
    Start-Process explorer.exe $testExtensionDir | Out-Null
}

if ($OpenReadme) {
    Start-Process notepad.exe $readmePath | Out-Null
}

if ($OpenChrome) {
    $chromePath = Find-BrowserExecutable -Browser "Chrome"
    if ($chromePath) {
        Start-Process -FilePath $chromePath -ArgumentList "chrome://extensions/" | Out-Null
    }
}

if ($OpenEdge) {
    $edgePath = Find-BrowserExecutable -Browser "Edge"
    if ($edgePath) {
        Start-Process -FilePath $edgePath -ArgumentList "edge://extensions/" | Out-Null
    }
}

Write-Host "Ulti Guard browser test package prepared at: $OutputRoot"
Write-Host "Extension folder: $testExtensionDir"
Write-Host "Readme: $readmePath"
