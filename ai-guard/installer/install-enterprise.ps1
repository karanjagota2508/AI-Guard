param(
    [int]$PiiPort = 8000,
    [switch]$SkipBuild,
    [string]$ChromeExtensionId = "kgfkgellcbbmadimiahbfndmfbhfobko",
    [string]$EdgeExtensionId = "kgfkgellcbbmadimiahbfndmfbhfobko",
    [string]$ChromeUpdateUrl = "http://127.0.0.1:48555/update.xml",
    [string]$EdgeUpdateUrl = "http://127.0.0.1:48555/update.xml",
    [string]$MinimumExtensionVersion = "",
    [string[]]$AllowedExtensionIds = @(),
    [string]$BootstrapResultPath = ""
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

function Write-UltiGuardBootstrapResult {
    param(
        [string]$Status,
        [string]$Message,
        [string[]]$Warnings = @(),
        [string[]]$Errors = @(),
        [string]$InstallRoot = ""
    )

    $result = [ordered]@{
        status       = $Status
        message      = $Message
        install_root = $InstallRoot
        scope        = "machine"
        warnings     = @($Warnings | Where-Object { $_ })
        errors       = @($Errors | Where-Object { $_ })
    }

    $json = $result | ConvertTo-Json -Depth 6 -Compress
    if ($BootstrapResultPath) {
        $parent = Split-Path $BootstrapResultPath -Parent
        if ($parent) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        [System.IO.File]::WriteAllText($BootstrapResultPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    }
    Write-Host "ULTI_GUARD_BOOTSTRAPPER_RESULT::$json"
}

function Stop-StaleUltiGuardSetupProcesses {
    $setupRootMarkers = @(
        "\Ulti-Guard-Setup\",
        "\ai-guard\installer\"
    )
    $scriptNames = @(
        "install-enterprise.ps1",
        "install.ps1",
        "uninstall.ps1"
    )

    $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -ieq "powershell.exe" -and
        $_.ProcessId -ne $PID -and
        $_.CommandLine
    }

    foreach ($process in $processes) {
        $commandLine = [string]$process.CommandLine
        $matchesSetupRoot = $false
        foreach ($marker in $setupRootMarkers) {
            if ($commandLine -like "*$marker*") {
                $matchesSetupRoot = $true
                break
            }
        }

        if (-not $matchesSetupRoot) {
            continue
        }

        $matchesScriptName = $false
        foreach ($scriptName in $scriptNames) {
            if ($commandLine -like "*$scriptName*") {
                $matchesScriptName = $true
                break
            }
        }

        if (-not $matchesScriptName) {
            continue
        }

        try {
            Invoke-CimMethod -InputObject $process -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null
        } catch {
        }
    }

    Start-Sleep -Milliseconds 500
}

function Invoke-UltiGuardInstallScript {
    param(
        [string]$ScriptPath,
        [hashtable]$Parameters,
        [int]$MaxAttempts = 5
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            & $ScriptPath @Parameters
            return
        } catch {
            $message = $_.Exception.Message
            $isRetryable = $message -match "cannot access the file" -or
                $message -match "being used by another process"

            if (-not $isRetryable -or $attempt -ge $MaxAttempts) {
                throw
            }

            Write-Host "Ulti Guard setup hit a temporary file lock while starting install.ps1. Retrying ($attempt/$MaxAttempts)..."
            Stop-StaleUltiGuardSetupProcesses
            Start-Sleep -Seconds ([Math]::Min($attempt * 2, 6))
        }
    }
}

trap {
    $message = $_.Exception.Message
    Write-UltiGuardBootstrapResult `
        -Status "failed" `
        -Message $message `
        -Errors @($message) `
        -InstallRoot "$env:ProgramFiles\AI Guard Agent"
    exit 1
}

if (-not (Test-IsAdministrator)) {
    throw "Run install-enterprise.ps1 from an Administrator PowerShell window."
}

foreach ($pair in @(
    @{ Label = "Chrome"; ExtensionId = $ChromeExtensionId; UpdateUrl = $ChromeUpdateUrl },
    @{ Label = "Edge"; ExtensionId = $EdgeExtensionId; UpdateUrl = $EdgeUpdateUrl }
)) {
    if (-not $pair.ExtensionId) {
        throw "$($pair.Label) extension ID is required for enterprise browser deployment."
    }

    if (-not $pair.UpdateUrl -or $pair.UpdateUrl -notmatch '^https?://') {
        throw "$($pair.Label) update URL must be an HTTP or HTTPS endpoint."
    }

    if ($pair.UpdateUrl -match '^http://' -and $pair.UpdateUrl -notmatch '^http://(127\.0\.0\.1|localhost)(:\d+)?/') {
        throw "$($pair.Label) HTTP update URL must point to the local Ulti Guard daemon on 127.0.0.1 or localhost."
    }
}

if ($AllowedExtensionIds -contains 'your-corporate-extension-id') {
    throw "Replace the placeholder AllowedExtensionIds value with real extension IDs, or omit -AllowedExtensionIds."
}

$installScript = Join-Path $InstallerScriptRoot "install.ps1"
if (-not (Test-Path $installScript)) {
    throw "Missing install script at $installScript"
}

Stop-StaleUltiGuardSetupProcesses

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

$params["ChromeExtensionId"] = $ChromeExtensionId
$params["EdgeExtensionId"] = $EdgeExtensionId
$params["ChromeUpdateUrl"] = $ChromeUpdateUrl
$params["EdgeUpdateUrl"] = $EdgeUpdateUrl

if ($MinimumExtensionVersion) {
    $params["MinimumExtensionVersion"] = $MinimumExtensionVersion
}

if ($AllowedExtensionIds -and $AllowedExtensionIds.Count -gt 0) {
    $params["AllowedExtensionIds"] = $AllowedExtensionIds
}

if ($BootstrapResultPath) {
    $params["BootstrapResultPath"] = $BootstrapResultPath
}

Invoke-UltiGuardInstallScript -ScriptPath $installScript -Parameters $params

if (-not $BootstrapResultPath) {
    return
}

if (-not (Test-Path $BootstrapResultPath)) {
    Write-UltiGuardBootstrapResult `
        -Status "failed" `
        -Message "Ulti Guard installation exited without returning a result contract." `
        -Errors @("The wrapped install script completed without producing the required result contract.") `
        -InstallRoot "$env:ProgramFiles\AI Guard Agent"
    exit 1
}
