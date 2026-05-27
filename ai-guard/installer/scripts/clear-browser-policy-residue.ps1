param(
    [string]$ConfigPath = "",
    [switch]$RemoveCurrentUserUrlBlocklistKeys
)

$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Remove-RegistryKeyIfPresent {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [string]$KeyPath
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $baseKey.DeleteSubKeyTree($KeyPath, $false)
    } finally {
        $baseKey.Dispose()
    }
}

if (-not (Test-IsAdministrator)) {
    throw "Run clear-browser-policy-residue.ps1 from an Administrator PowerShell window."
}

. (Join-Path $PSScriptRoot "browser-policies.ps1")

function Get-UltiGuardExtensionIds {
    param(
        [string]$ConfigPathValue
    )

    $defaults = @("kgfkgellcbbmadimiahbfndmfbhfobko")
    if (-not $ConfigPathValue -or -not (Test-Path $ConfigPathValue)) {
        return $defaults
    }

    try {
        $config = Get-Content -Path $ConfigPathValue -Raw | ConvertFrom-Json
        $ids = @(
            "$($config.package.chrome_extension_id)",
            "$($config.package.edge_extension_id)",
            "$($config.package.extension_id)",
            @($config.extension_ids)
        ) | Where-Object { $_ } | Select-Object -Unique

        if ($ids.Count -gt 0) {
            return $ids
        }
    } catch {
    }

    return $defaults
}

$registryHives = @(
    [Microsoft.Win32.RegistryHive]::LocalMachine,
    [Microsoft.Win32.RegistryHive]::CurrentUser
)

$extensionIds = Get-UltiGuardExtensionIds -ConfigPathValue $ConfigPath

foreach ($registryHive in $registryHives) {
    foreach ($extensionId in $extensionIds) {
        Remove-ManagedExtensionPolicy -Hive $registryHive -Browser "Chrome" -ExtensionId $extensionId
        Remove-ManagedExtensionPolicy -Hive $registryHive -Browser "Edge" -ExtensionId $extensionId
        Remove-RegistryKeyIfPresent -Hive $registryHive -KeyPath "SOFTWARE\Google\Chrome\Extensions\$extensionId"
        Remove-RegistryKeyIfPresent -Hive $registryHive -KeyPath "SOFTWARE\Microsoft\Edge\Extensions\$extensionId"
    }

    Remove-RegistryKeyIfPresent -Hive $registryHive -KeyPath "SOFTWARE\WinInfoSoft\AI Guard Agent\PolicyState\Chrome"
    Remove-RegistryKeyIfPresent -Hive $registryHive -KeyPath "SOFTWARE\WinInfoSoft\AI Guard Agent\PolicyState\Edge"
}

if ($RemoveCurrentUserUrlBlocklistKeys) {
    Remove-RegistryKeyIfPresent -Hive ([Microsoft.Win32.RegistryHive]::CurrentUser) -KeyPath "SOFTWARE\Policies\Google\Chrome\URLBlocklist"
    Remove-RegistryKeyIfPresent -Hive ([Microsoft.Win32.RegistryHive]::CurrentUser) -KeyPath "SOFTWARE\Policies\Microsoft\Edge\URLBlocklist"
}

Write-Host "Ulti Guard browser policy residue cleanup completed. Fully restart Chrome and Edge, then reload chrome://policy and edge://policy."
