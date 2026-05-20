param(
    [string]$SourceBackendDir,
    [string]$InstallDir,
    [string]$PythonExecutable
)

$ErrorActionPreference = "Stop"

$venvDir = Join-Path $InstallDir "venv"
$venvPython = Join-Path $venvDir "Scripts\python.exe"
$backendInstallDir = Join-Path $InstallDir "backend"

if (-not (Test-Path $SourceBackendDir)) {
    throw "PII backend source directory not found: $SourceBackendDir"
}

if (-not (Test-Path $PythonExecutable)) {
    throw "Python executable not found: $PythonExecutable"
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
if (Test-Path $backendInstallDir) {
    Remove-Item -Path $backendInstallDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $backendInstallDir | Out-Null
Get-ChildItem -Force -Path $SourceBackendDir | Where-Object {
    $_.Name -notin @(".venv", "__pycache__") -and -not $_.Name.EndsWith(".log")
} | Copy-Item -Destination $backendInstallDir -Recurse -Force

if (-not (Test-Path $venvPython)) {
    & $PythonExecutable -m venv $venvDir
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create PII agent virtual environment."
    }
}

$null = & $venvPython -m pip install --upgrade pip setuptools wheel
if ($LASTEXITCODE -ne 0) {
    throw "Failed to upgrade pip tooling for the PII agent."
}

$null = & $venvPython -m pip install -r (Join-Path $backendInstallDir "requirements.txt")
if ($LASTEXITCODE -ne 0) {
    throw "Failed to install PII agent dependencies."
}

Write-Output $venvPython
