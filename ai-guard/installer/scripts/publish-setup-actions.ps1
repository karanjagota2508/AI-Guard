param(
    [string]$Runtime = "win-x64",
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

$installerRoot = Split-Path $PSScriptRoot -Parent
$projectPath = Join-Path $installerRoot "setup-actions\AIGuard.Setup.Actions.csproj"
$outputDirectory = if ($OutputPath) {
    $OutputPath
} else {
    Join-Path $installerRoot "dist\setup-actions"
}

if (-not (Test-Path $projectPath)) {
    throw "Setup actions project not found at $projectPath"
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
    throw "Failed to publish the Ulti Guard setup actions helper."
}

Write-Host "Published Ulti Guard setup actions helper to $outputDirectory"
