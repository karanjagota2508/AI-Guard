param(
    [string]$OutputDir = (Join-Path (Split-Path $PSScriptRoot -Parent) "dist\pii-runtime"),
    [string]$PortablePythonDir = (Join-Path (Split-Path $PSScriptRoot -Parent) "dist\python-runtime"),
    [string]$WheelhouseDir = (Join-Path (Split-Path $PSScriptRoot -Parent) "dist\pii-wheelhouse")
)

$ErrorActionPreference = "Stop"

$installerRoot = Split-Path $PSScriptRoot -Parent
$repoRoot = Split-Path $installerRoot -Parent
$workspaceRoot = Split-Path $repoRoot -Parent
$backendSource = Join-Path $workspaceRoot "PII_agent\backend"
$portablePython = Join-Path $PortablePythonDir "python.exe"
$venvPython = Join-Path $OutputDir "venv\Scripts\python.exe"
$backendOutput = Join-Path $OutputDir "backend"
$requirementsPath = Join-Path $backendOutput "requirements.txt"

function Copy-DirectoryFiltered {
    param(
        [string]$Source,
        [string]$Destination,
        [string[]]$ExcludedDirectoryNames = @(),
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
                -ExcludedFilePatterns $ExcludedFilePatterns
            continue
        }

        $skip = $false
        foreach ($pattern in $ExcludedFilePatterns) {
            if ($item.Name -like $pattern) {
                $skip = $true
                break
            }
        }

        if (-not $skip) {
            Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $Destination $item.Name) -Force
        }
    }
}

if (-not (Test-Path $portablePython)) {
    & (Join-Path $installerRoot "scripts\build-python-runtime.ps1") -OutputDir $PortablePythonDir
}

if (-not (Test-Path $portablePython)) {
    throw "Portable Python executable not found at $portablePython"
}

if (Test-Path $OutputDir) {
    Remove-Item -Path $OutputDir -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Copy-DirectoryFiltered `
    -Source $backendSource `
    -Destination $backendOutput `
    -ExcludedDirectoryNames @(".venv", "venv", "__pycache__") `
    -ExcludedFilePatterns @("*.log")

& $portablePython -m venv (Join-Path $OutputDir "venv")
if ($LASTEXITCODE -ne 0) {
    throw "Failed to create the sealed PII runtime virtual environment."
}

$hasWheelhouse = (Test-Path $WheelhouseDir) -and (Get-ChildItem -Path $WheelhouseDir -File -ErrorAction SilentlyContinue | Select-Object -First 1)
if ($hasWheelhouse) {
    & $venvPython -m pip install --no-index --find-links $WheelhouseDir -r $requirementsPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install PII runtime dependencies from the bundled wheelhouse."
    }
} else {
    & $venvPython -m pip install --upgrade pip setuptools wheel
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to upgrade pip tooling while building the sealed PII runtime."
    }

    & $venvPython -m pip install -r $requirementsPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install PII runtime dependencies."
    }
}

foreach ($path in @(
    (Join-Path $OutputDir "venv\Lib\site-packages\pip"),
    (Join-Path $OutputDir "venv\Lib\site-packages\setuptools"),
    (Join-Path $OutputDir "venv\Lib\site-packages\wheel")
)) {
    if (Test-Path $path) {
        Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Get-ChildItem -Path $OutputDir -Recurse -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $OutputDir -Recurse -File -Include *.pyc,*.pyo -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host "Built sealed Ulti Guard PII runtime at $OutputDir"
