param(
    [string]$Thumbprint = "A6D4D5886C39370FCF6967483D74787BE8C7031D"
)

$ErrorActionPreference = "Stop"

$normalizedThumbprint = ($Thumbprint -replace '\s+', '').ToUpperInvariant()
$stores = @(
    "Cert:\CurrentUser\Root",
    "Cert:\CurrentUser\TrustedPublisher",
    "Cert:\LocalMachine\Root",
    "Cert:\LocalMachine\TrustedPublisher"
)

foreach ($store in $stores) {
    $matches = @(Get-ChildItem -Path $store -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $normalizedThumbprint })

    if ($matches.Count -gt 0) {
        Write-Host "$store : present"
    } else {
        Write-Host "$store : missing"
    }
}
