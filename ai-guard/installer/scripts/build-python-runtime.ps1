param(
    [string]$OutputDir = (Join-Path (Split-Path $PSScriptRoot -Parent) "dist\python-runtime")
)

$ErrorActionPreference = "Stop"

function Find-PythonExecutable {
    $candidates = @()

    $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
    if ($pyLauncher) {
        try {
            $pyPath = & $pyLauncher.Source -3.14 -c "import sys; print(sys.executable)" 2>$null
            if ($LASTEXITCODE -eq 0 -and $pyPath) {
                $candidates += $pyPath.Trim()
            }
        } catch { }
        try {
            $pyPath = & $pyLauncher.Source -3 -c "import sys; print(sys.executable)" 2>$null
            if ($LASTEXITCODE -eq 0 -and $pyPath) {
                $candidates += $pyPath.Trim()
            }
        } catch { }
    }

    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCmd) {
        $candidates += $pythonCmd.Source
    }

    $candidates = @($candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique)
    if (-not $candidates) {
        throw "Could not locate a usable Python interpreter to build the portable runtime."
    }

    return $candidates[0]
}

function Copy-DirectoryFiltered {
    param(
        [string]$Source,
        [string]$Destination,
        [string[]]$ExcludedDirectoryNames = @()
    )

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    foreach ($item in Get-ChildItem -Force -LiteralPath $Source) {
        if ($item.PSIsContainer) {
            if ($ExcludedDirectoryNames -contains $item.Name) {
                continue
            }

            Copy-DirectoryFiltered `
                -Source $item.FullName `
                -Destination (Join-Path $Destination $item.Name) `
                -ExcludedDirectoryNames $ExcludedDirectoryNames
            continue
        }

        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $Destination $item.Name) -Force
    }
}

$pythonExecutable = Find-PythonExecutable
$pythonRoot = & $pythonExecutable -c "import sys; print(sys.base_prefix)"
if ($LASTEXITCODE -ne 0 -or -not $pythonRoot) {
    throw "Failed to resolve Python base installation path."
}
$pythonRoot = $pythonRoot.Trim()

if (-not (Test-Path $pythonRoot)) {
    throw "Resolved Python base installation path does not exist: $pythonRoot"
}

if (Test-Path $OutputDir) {
    Remove-Item -Path $OutputDir -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

foreach ($name in @("DLLs", "Lib", "libs", "python.exe", "pythonw.exe", "python3.dll", "python314.dll", "vcruntime140.dll", "vcruntime140_1.dll", "LICENSE.txt")) {
    $sourcePath = Join-Path $pythonRoot $name
    if (-not (Test-Path $sourcePath)) {
        continue
    }

    $destPath = Join-Path $OutputDir $name
    if ((Get-Item $sourcePath).PSIsContainer) {
        if ($name -eq "Lib") {
            Copy-DirectoryFiltered -Source $sourcePath -Destination $destPath -ExcludedDirectoryNames @("site-packages", "__pycache__", "test", "tkinter", "turtledemo", "idlelib")
        } else {
            Copy-Item -LiteralPath $sourcePath -Destination $destPath -Recurse -Force
        }
    } else {
        Copy-Item -LiteralPath $sourcePath -Destination $destPath -Force
    }
}

Write-Host "Built portable Python runtime at $OutputDir"
