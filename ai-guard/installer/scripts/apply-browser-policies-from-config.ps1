param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "browser-policies.ps1")

if (-not (Test-Path $ConfigPath)) {
    throw "Ulti Guard config not found at $ConfigPath"
}

$config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
$registryHive = if ($ConfigPath.StartsWith($env:ProgramFiles, [System.StringComparison]::OrdinalIgnoreCase)) {
    [Microsoft.Win32.RegistryHive]::LocalMachine
} else {
    [Microsoft.Win32.RegistryHive]::CurrentUser
}

$chromeExtensionId = "$($config.package.chrome_extension_id)"
if (-not $chromeExtensionId) {
    $chromeExtensionId = "$($config.package.extension_id)"
}

$edgeExtensionId = "$($config.package.edge_extension_id)"
if (-not $edgeExtensionId) {
    $edgeExtensionId = "$($config.package.extension_id)"
}

$chromeUpdateUrl = "$($config.package.chrome_update_url)"
$edgeUpdateUrl = "$($config.package.edge_update_url)"
$allowedExtensionIds = @($config.extension_ids | Where-Object { $_ } | Select-Object -Unique)

foreach ($required in @(
    @{ Label = "Chrome extension ID"; Value = $chromeExtensionId },
    @{ Label = "Edge extension ID"; Value = $edgeExtensionId },
    @{ Label = "Chrome update URL"; Value = $chromeUpdateUrl },
    @{ Label = "Edge update URL"; Value = $edgeUpdateUrl }
)) {
    if ([string]::IsNullOrWhiteSpace([string]$required.Value)) {
        throw "Ulti Guard config is missing $($required.Label)."
    }
}

$hosts = @($config.blocking.browser_hosts)
Set-ManagedExtensionPolicy `
    -Hive $registryHive `
    -Browser "Chrome" `
    -ExtensionId $chromeExtensionId `
    -UpdateUrl $chromeUpdateUrl `
    -MinimumVersionRequired "$($config.package.extension_version)" `
    -AllowedExtensionIds $allowedExtensionIds `
    -RequirePrivateBrowsingGuard

Set-ManagedExtensionPolicy `
    -Hive $registryHive `
    -Browser "Edge" `
    -ExtensionId $edgeExtensionId `
    -UpdateUrl $edgeUpdateUrl `
    -MinimumVersionRequired "$($config.package.extension_version)" `
    -AllowedExtensionIds $allowedExtensionIds `
    -RequirePrivateBrowsingGuard

Set-AIGuardBrowserHostBlocklistPolicy -Hive $registryHive -Browser "Chrome" -Hosts $hosts
Set-AIGuardBrowserHostBlocklistPolicy -Hive $registryHive -Browser "Edge" -Hosts $hosts
Set-AIGuardPrivateBrowsingPolicy -Hive $registryHive -Browser "Chrome"
Set-AIGuardPrivateBrowsingPolicy -Hive $registryHive -Browser "Edge"

Set-RegistryStringValue -Hive $registryHive -KeyPath "SOFTWARE\Google\Chrome\Extensions\$chromeExtensionId" -Name "update_url" -Value $chromeUpdateUrl
Set-RegistryStringValue -Hive $registryHive -KeyPath "SOFTWARE\Microsoft\Edge\Extensions\$edgeExtensionId" -Name "update_url" -Value $edgeUpdateUrl

Write-Host "Ulti Guard browser policies refreshed from $ConfigPath"
