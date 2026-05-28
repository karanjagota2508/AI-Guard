param(
    [string]$Runtime = "win-x64",
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

$installerRoot = Split-Path $PSScriptRoot -Parent
$projectPath = Join-Path $installerRoot "desktop-session\AIGuard.DesktopSessionHelper.csproj"
$outputDirectory = if ($OutputPath) {
    $OutputPath
} else {
    Join-Path $installerRoot "dist\desktop-session"
}

if (-not (Test-Path $projectPath)) {
    throw "Desktop session helper project not found at $projectPath"
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
    throw "Failed to publish the Ulti Guard desktop session helper."
}

Write-Host "Published Ulti Guard desktop session helper to $outputDirectory"
