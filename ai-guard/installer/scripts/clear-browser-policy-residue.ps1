param(
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

$registryHives = @(
    [Microsoft.Win32.RegistryHive]::LocalMachine,
    [Microsoft.Win32.RegistryHive]::CurrentUser
)

foreach ($registryHive in $registryHives) {
    Remove-ManagedExtensionPolicy -Hive $registryHive -Browser "Chrome" -ExtensionId "kgfkgellcbbmadimiahbfndmfbhfobko"
    Remove-ManagedExtensionPolicy -Hive $registryHive -Browser "Edge" -ExtensionId "kgfkgellcbbmadimiahbfndmfbhfobko"
}

if ($RemoveCurrentUserUrlBlocklistKeys) {
    Remove-RegistryKeyIfPresent -Hive ([Microsoft.Win32.RegistryHive]::CurrentUser) -KeyPath "SOFTWARE\Policies\Google\Chrome\URLBlocklist"
    Remove-RegistryKeyIfPresent -Hive ([Microsoft.Win32.RegistryHive]::CurrentUser) -KeyPath "SOFTWARE\Policies\Microsoft\Edge\URLBlocklist"
}

Write-Host "AI Guard browser policy residue cleanup completed. Fully restart Chrome and Edge, then reload chrome://policy and edge://policy."
