param(
    [int]$PiiPort = 8000,
    [switch]$SkipBuild,
    [string]$ExtensionUpdateUrl = "",
    [string]$MinimumExtensionVersion = "",
    [string[]]$AllowedExtensionIds = @()
)

$ErrorActionPreference = "Stop"

$InstallerScriptRoot = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($env:ULTI_GUARD_INSTALLER_ROOT) {
    $env:ULTI_GUARD_INSTALLER_ROOT
} elseif ($PSCommandPath) {
    Split-Path $PSCommandPath -Parent
} else {
    (Get-Location).Path
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    throw "Run install-enterprise.ps1 from an Administrator PowerShell window."
}

if ($ExtensionUpdateUrl -and $ExtensionUpdateUrl -match 'your-company-host') {
    throw "Replace the placeholder ExtensionUpdateUrl with a real HTTPS URL, or omit -ExtensionUpdateUrl to use the local daemon update endpoint."
}

if ($AllowedExtensionIds -contains 'your-corporate-extension-id') {
    throw "Replace the placeholder AllowedExtensionIds value with real extension IDs, or omit -AllowedExtensionIds."
}

$installScript = Join-Path $InstallerScriptRoot "install.ps1"
if (-not (Test-Path $installScript)) {
    throw "Missing install script at $installScript"
}

$params = @{
    PiiPort                        = $PiiPort
    BlockOtherExtensions          = $true
    EnforceBrowserHostBlocklist   = $true
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
