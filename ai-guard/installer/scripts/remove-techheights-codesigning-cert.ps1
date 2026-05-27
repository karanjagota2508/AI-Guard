param(
    [string]$Thumbprint = "A6D4D5886C39370FCF6967483D74787BE8C7031D",
    [switch]$CurrentUserOnly
)

$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Remove-FromStoreIfPresent {
    param(
        [string]$StoreLocation,
        [string]$NormalizedThumbprint
    )

    $matches = @(Get-ChildItem -Path $StoreLocation -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $NormalizedThumbprint })

    if ($matches.Count -eq 0) {
        Write-Host "$StoreLocation : not present"
        return
    }

    foreach ($match in $matches) {
        Remove-Item -Path $match.PSPath -Force
    }

    Write-Host "$StoreLocation : removed ($NormalizedThumbprint)"
}

$targetScope = if ($CurrentUserOnly) { "CurrentUser" } else { "LocalMachine" }
if ($targetScope -eq "LocalMachine" -and -not (Test-IsAdministrator)) {
    throw "Run this script as Administrator, or use -CurrentUserOnly for a per-user trust removal."
}

$normalizedThumbprint = ($Thumbprint -replace '\s+', '').ToUpperInvariant()
Remove-FromStoreIfPresent -StoreLocation "Cert:\$targetScope\Root" -NormalizedThumbprint $normalizedThumbprint
Remove-FromStoreIfPresent -StoreLocation "Cert:\$targetScope\TrustedPublisher" -NormalizedThumbprint $normalizedThumbprint

Write-Host ""
Write-Host "TechHeights code-signing certificate trust removed for $targetScope."
