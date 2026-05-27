param(
    [string]$CertificatePath = "",
    [switch]$CurrentUserOnly
)

$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-DefaultCertificatePath {
    $scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $PSCommandPath -Parent }
    $repoRoot = Split-Path (Split-Path $scriptRoot -Parent) -Parent
    $workspaceRoot = Split-Path $repoRoot -Parent
    return Join-Path $workspaceRoot "techheights-codesigning.cer"
}

function Import-IntoStore {
    param(
        [string]$FilePath,
        [string]$StoreLocation
    )

    $existingThumbprints = @(Get-ChildItem -Path $StoreLocation -ErrorAction SilentlyContinue | ForEach-Object { $_.Thumbprint })
    $imported = Import-Certificate -FilePath $FilePath -CertStoreLocation $StoreLocation
    $thumbprint = ($imported | Select-Object -First 1 -ExpandProperty Thumbprint)
    $status = if ($existingThumbprints -contains $thumbprint) { "already present" } else { "imported" }
    Write-Host "$StoreLocation : $status ($thumbprint)"
}

if (-not $CertificatePath) {
    $CertificatePath = Resolve-DefaultCertificatePath
}

if (-not (Test-Path $CertificatePath)) {
    throw "TechHeights code-signing certificate was not found at $CertificatePath"
}

$targetScope = if ($CurrentUserOnly) { "CurrentUser" } else { "LocalMachine" }
if ($targetScope -eq "LocalMachine" -and -not (Test-IsAdministrator)) {
    throw "Run this script as Administrator, or use -CurrentUserOnly for a per-user trust install."
}

$rootStore = "Cert:\$targetScope\Root"
$trustedPublisherStore = "Cert:\$targetScope\TrustedPublisher"

Import-IntoStore -FilePath $CertificatePath -StoreLocation $rootStore
Import-IntoStore -FilePath $CertificatePath -StoreLocation $trustedPublisherStore

Write-Host ""
Write-Host "TechHeights code-signing certificate trust installed for $targetScope."
Write-Host "SmartScreen may still warn on unmanaged/public PCs because this is a self-signed certificate,"
Write-Host "but managed PCs that trust this cert will stop showing 'Unknown publisher'."
