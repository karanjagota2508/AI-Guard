param(
    [int]$PiiPort = 8000,
    [switch]$SkipBuild,
    [string]$ExtensionUpdateUrl = "",
    [string]$MinimumExtensionVersion = "",
    [string[]]$AllowedExtensionIds = @()
)

$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    throw "Run install-enterprise.ps1 from an Administrator PowerShell window."
}

$installScript = Join-Path $PSScriptRoot "install.ps1"
if (-not (Test-Path $installScript)) {
    throw "Missing install script at $installScript"
}

$params = @{
    PiiPort                        = $PiiPort
    BlockOtherExtensions          = $true
    RequirePrivateBrowsingGuard   = $true
    DisallowExtensionDeveloperMode = $true
    DisableBrowserDeveloperTools  = $true
}

if ($SkipBuild) {
    $params["SkipBuild"] = $true
}

if ($ExtensionUpdateUrl) {
    $params["ExtensionUpdateUrl"] = $ExtensionUpdateUrl
}

if ($MinimumExtensionVersion) {
    $params["MinimumExtensionVersion"] = $MinimumExtensionVersion
}

if ($AllowedExtensionIds -and $AllowedExtensionIds.Count -gt 0) {
    $params["AllowedExtensionIds"] = $AllowedExtensionIds
}

& $installScript @params
