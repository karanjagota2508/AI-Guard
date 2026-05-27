param(
    [string[]]$PortableExecutablePaths = @(),
    [string[]]$PowerShellScriptPaths = @(),
    [string]$Thumbprint = "",
    [string]$PfxPath = "",
    [string]$PfxPassword = "",
    [string]$TimestampUrl = "",
    [switch]$AutoSelectCertificate,
    [switch]$SkipIfNoCertificate
)

$ErrorActionPreference = "Stop"

function Get-SignToolPath {
    $roots = @(
        (Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"),
        (Join-Path $env:ProgramFiles "Windows Kits\10\bin")
    )

    $candidates = @()
    foreach ($root in $roots) {
        if (-not $root -or -not (Test-Path $root)) {
            continue
        }

        $candidates += Get-ChildItem -Path $root -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
            Sort-Object FullName -Descending
    }

    return ($candidates | Select-Object -First 1 -ExpandProperty FullName)
}

function Get-StoreCertificate {
    param(
        [string]$RequestedThumbprint,
        [switch]$AutoSelect
    )

    $stores = @("Cert:\CurrentUser\My", "Cert:\LocalMachine\My")

    if ($RequestedThumbprint) {
        $normalized = ($RequestedThumbprint -replace '\s+', '').ToUpperInvariant()
        foreach ($store in $stores) {
            $candidate = Get-ChildItem -Path $store -CodeSigningCert -ErrorAction SilentlyContinue |
                Where-Object { $_.Thumbprint.ToUpperInvariant() -eq $normalized } |
                Select-Object -First 1
            if ($candidate) {
                return $candidate
            }
        }

        throw "Could not find code-signing certificate with thumbprint $RequestedThumbprint"
    }

    if (-not $AutoSelect) {
        return $null
    }

    $all = foreach ($store in $stores) {
        Get-ChildItem -Path $store -CodeSigningCert -ErrorAction SilentlyContinue
    }

    $preferred = $all | Sort-Object NotAfter -Descending | Select-Object -First 1
    return $preferred
}

function Invoke-SignTool {
    param(
        [string]$SignToolPath,
        [string]$FilePath,
        [string]$TimestampUrl,
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [string]$PfxPath,
        [string]$PfxPassword
    )

    $arguments = @("sign", "/fd", "SHA256")

    if ($TimestampUrl) {
        $arguments += @("/tr", $TimestampUrl, "/td", "SHA256")
    }

    if ($PfxPath) {
        $arguments += @("/f", $PfxPath)
        if ($PfxPassword) {
            $arguments += @("/p", $PfxPassword)
        }
    } else {
        $arguments += @("/sha1", $Certificate.Thumbprint, "/s", "My")
        if ($Certificate.PSParentPath -like "*LocalMachine*") {
            $arguments += "/sm"
        }
    }

    $arguments += $FilePath

    $maxAttempts = 5
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt += 1) {
        $signOutput = & $SignToolPath @arguments 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            return
        }

        $outputText = ($signOutput | Out-String)
        if ($attempt -lt $maxAttempts -and $outputText -match 'being used by another process') {
            Start-Sleep -Seconds ([Math]::Min($attempt * 2, 8))
            continue
        }

        if ($outputText) {
            Write-Host $outputText.TrimEnd()
        }

        throw "signtool failed for $FilePath with exit code $exitCode"
    }
}

function Set-ScriptSignatureIfSupported {
    param(
        [string]$FilePath,
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [string]$TimestampUrl
    )

    if (-not $Certificate) {
        return
    }

    $params = @{
        FilePath      = $FilePath
        Certificate   = $Certificate
        HashAlgorithm = "SHA256"
    }

    if ($TimestampUrl) {
        $params["TimestampServer"] = $TimestampUrl
    }

    $signature = Set-AuthenticodeSignature @params
    if ($signature.Status -eq [System.Management.Automation.SignatureStatus]::NotSigned) {
        throw "Failed to sign script $FilePath"
    }
}

function Get-ValidPaths {
    param(
        [string[]]$Paths
    )

    return @($Paths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique)
}

$peFiles = Get-ValidPaths -Paths $PortableExecutablePaths
$psFiles = Get-ValidPaths -Paths $PowerShellScriptPaths

if ($peFiles.Count -eq 0 -and $psFiles.Count -eq 0) {
    Write-Host "No files supplied for signing."
    return
}

$storeCertificate = $null
if (-not $PfxPath) {
    $storeCertificate = Get-StoreCertificate -RequestedThumbprint $Thumbprint -AutoSelect:$AutoSelectCertificate
    if (-not $storeCertificate) {
        if ($SkipIfNoCertificate) {
            Write-Warning "No code-signing certificate available. Skipping signing."
            return
        }

        throw "No code-signing certificate was found. Provide -Thumbprint, -PfxPath, or use -AutoSelectCertificate."
    }
}

$signToolPath = Get-SignToolPath
if (-not $signToolPath) {
    throw "signtool.exe was not found. Install the Windows SDK signing tools."
}

foreach ($file in $peFiles) {
    Invoke-SignTool -SignToolPath $signToolPath -FilePath $file -TimestampUrl $TimestampUrl -Certificate $storeCertificate -PfxPath $PfxPath -PfxPassword $PfxPassword
    Write-Host "Signed binary: $file"
}

if ($storeCertificate) {
    foreach ($file in $psFiles) {
        Set-ScriptSignatureIfSupported -FilePath $file -Certificate $storeCertificate -TimestampUrl $TimestampUrl
        Write-Host "Signed script: $file"
    }
} elseif ($psFiles.Count -gt 0) {
    Write-Warning "PowerShell script signing was skipped because only PFX-based binary signing is available in this mode."
}
