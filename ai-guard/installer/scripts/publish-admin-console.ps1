param(
    [string]$Runtime = "win-x64",
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

$installerRoot = Split-Path $PSScriptRoot -Parent
$projectPath = Join-Path $installerRoot "admin-console\AIGuard.AdminConsole.csproj"
$outputDirectory = if ($OutputPath) {
    $OutputPath
} else {
    Join-Path $installerRoot "dist\admin-console"
}

if (-not (Test-Path $projectPath)) {
    throw "Admin console project not found at $projectPath"
}

if (Test-Path $outputDirectory) {
    Remove-Item -Path $outputDirectory -Recurse -Force
}

dotnet publish `
    $projectPath `
    -c Release `
    -r $Runtime `
    --self-contained true `
    -o $outputDirectory `
    -p:PublishSingleFile=true `
    -p:EnableCompressionInSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true

if ($LASTEXITCODE -ne 0) {
    throw "Failed to publish the Ulti Guard admin console."
}

Write-Host "Published Ulti Guard admin console to $outputDirectory"
