param(
    [string]$OutputDir = "",
    [string]$RequirementsPath = ""
)

$ErrorActionPreference = "Stop"

$installerRoot = Split-Path $PSScriptRoot -Parent
$repoRoot = Split-Path $installerRoot -Parent
$workspaceRoot = Split-Path $repoRoot -Parent

if (-not $OutputDir) {
    $OutputDir = Join-Path $installerRoot "dist\pii-wheelhouse"
}

if (-not $RequirementsPath) {
    $RequirementsPath = Join-Path $workspaceRoot "PII_agent\backend\requirements.txt"
}

function Find-PythonExecutable {
    $candidate = Join-Path $workspaceRoot "PII_agent\backend\.venv\Scripts\python.exe"
    if (Test-Path $candidate) {
        return $candidate
    }

    $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
    if ($pyLauncher) {
        try {
            $pyPath = & $pyLauncher.Source -3.14 -c "import sys; print(sys.executable)" 2>$null
            if ($LASTEXITCODE -eq 0 -and $pyPath) {
                return $pyPath.Trim()
            }
        } catch { }
        try {
            $pyPath = & $pyLauncher.Source -3 -c "import sys; print(sys.executable)" 2>$null
            if ($LASTEXITCODE -eq 0 -and $pyPath) {
                return $pyPath.Trim()
            }
        } catch { }
    }

    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCmd) {
        return $pythonCmd.Source
    }

    throw "Could not locate a usable Python interpreter to build the PII wheelhouse."
}

if (-not (Test-Path $RequirementsPath)) {
    throw "Requirements file not found: $RequirementsPath"
}

$pythonExecutable = Find-PythonExecutable

if (Test-Path $OutputDir) {
    Remove-Item -Path $OutputDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$null = & $pythonExecutable -m pip download -r $RequirementsPath -d $OutputDir
if ($LASTEXITCODE -ne 0) {
    throw "Failed to download the PII wheelhouse."
}

Write-Host "Built PII wheelhouse at $OutputDir"
