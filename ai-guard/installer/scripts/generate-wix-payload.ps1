param(
    [Parameter(Mandatory = $true)]
    [string]$PayloadRoot,
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $PayloadRoot)) {
    throw "Payload root not found at $PayloadRoot"
}

$installerRoot = Split-Path $PSScriptRoot -Parent
$resolvedOutput = if ($OutputPath) {
    $OutputPath
} else {
    Join-Path $installerRoot "wix\package\Payload.generated.wxs"
}

function New-SafeId {
    param(
        [string]$Prefix,
        [string]$Value
    )

    $safe = ($Value -replace '[^A-Za-z0-9_]', '_')
    if ($safe.Length -gt 40) {
        $safe = $safe.Substring($safe.Length - 40)
    }
    $hashBytes = [System.Security.Cryptography.MD5]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))
    $hash = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').Substring(0, 8)
    return "${Prefix}_${safe}_$hash"
}

function Write-DirectoryTree {
    param(
        [System.Text.StringBuilder]$Builder,
        [string]$DirectoryPath,
        [string]$RelativePath,
        [int]$Indent
    )

    $directories = Get-ChildItem -LiteralPath $DirectoryPath -Directory | Where-Object {
        $_.Name -ne '__pycache__'
    } | Sort-Object Name
    foreach ($directory in $directories) {
        $childRelative = if ($RelativePath) {
            Join-Path $RelativePath $directory.Name
        } else {
            $directory.Name
        }
        $directoryId = New-SafeId -Prefix "DIR" -Value $childRelative
        [void]$Builder.Append(' ' * $Indent).AppendLine("<Directory Id=""$directoryId"" Name=""$($directory.Name)"">")
        Write-DirectoryTree -Builder $Builder -DirectoryPath $directory.FullName -RelativePath $childRelative -Indent ($Indent + 2)
        [void]$Builder.Append(' ' * $Indent).AppendLine("</Directory>")
    }
}

function Get-DirectoryId {
    param(
        [string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        return "INSTALLFOLDER"
    }

    switch ($RelativePath.Replace('/', '\')) {
        "admin-console" { return "ADMINCONSOLEDIR" }
        "desktop" { return "DESKTOPHOOKDIR" }
        "desktop-session" { return "DESKTOPSESSIONDIR" }
        "setup-actions" { return "SETUPACTIONSDIR" }
        "shared" { return "SHAREDDIR" }
    }

    return New-SafeId -Prefix "DIR" -Value $RelativePath
}

function Get-FileId {
    param(
        [string]$RelativePath
    )

    switch ($RelativePath.Replace('/', '\')) {
        "admin-console\AI-Guard-Admin-Console.exe" { return "AdminConsoleExeFile" }
        "ai-guard-daemon.exe" { return "DaemonExeFile" }
        "desktop\claude-desktop-hook.cjs" { return "ClaudeDesktopHookFile" }
        "desktop-session\AIGuard.DesktopSessionHelper.exe" { return "DesktopSessionHelperExeFile" }
        "setup-actions\AIGuard.Setup.Actions.exe" { return "SetupActionsExeFile" }
    }

    return New-SafeId -Prefix "FIL" -Value $RelativePath
}

function Get-RelativePath {
    param(
        [string]$BasePath,
        [string]$Path
    )

    $base = [System.IO.Path]::GetFullPath($BasePath)
    if (-not $base.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $base += [System.IO.Path]::DirectorySeparatorChar
    }

    $baseUri = New-Object System.Uri($base)
    $pathUri = New-Object System.Uri([System.IO.Path]::GetFullPath($Path))
    $relativeUri = $baseUri.MakeRelativeUri($pathUri)
    return [System.Uri]::UnescapeDataString($relativeUri.ToString()).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
}

$builder = New-Object System.Text.StringBuilder
[void]$builder.AppendLine('<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">')
[void]$builder.AppendLine('  <Fragment>')
[void]$builder.AppendLine('    <DirectoryRef Id="INSTALLFOLDER">')
Write-DirectoryTree -Builder $builder -DirectoryPath $PayloadRoot -RelativePath "" -Indent 6
[void]$builder.AppendLine('    </DirectoryRef>')
[void]$builder.AppendLine('  </Fragment>')
[void]$builder.AppendLine('  <Fragment>')
[void]$builder.AppendLine('    <ComponentGroup Id="PayloadComponents">')

$files = Get-ChildItem -LiteralPath $PayloadRoot -Recurse -File | Where-Object {
    $_.FullName -notmatch '\\__pycache__(\\|$)' -and
    $_.Extension -notin @('.pyc', '.pyo')
} | Sort-Object FullName
foreach ($file in $files) {
    $relative = Get-RelativePath -BasePath $PayloadRoot -Path $file.FullName
    $relativeDirectory = [System.IO.Path]::GetDirectoryName($relative)
    $componentId = New-SafeId -Prefix "CMP" -Value $relative
    $directoryId = Get-DirectoryId -RelativePath $relativeDirectory
    $fileId = Get-FileId -RelativePath $relative
    $fileSource = $file.FullName.Replace('&', '&amp;')
    [void]$builder.AppendLine("      <Component Id=""$componentId"" Directory=""$directoryId"" Guid=""*"" Bitness=""always64"">")
    [void]$builder.AppendLine("        <File Id=""$fileId"" Source=""$fileSource"" KeyPath=""yes"" />")
    [void]$builder.AppendLine('      </Component>')
}

[void]$builder.AppendLine('    </ComponentGroup>')
[void]$builder.AppendLine('  </Fragment>')
[void]$builder.AppendLine('</Wix>')

$outputDirectory = Split-Path $resolvedOutput -Parent
if ($outputDirectory) {
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}

[System.IO.File]::WriteAllText($resolvedOutput, $builder.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Generated WiX payload authoring at $resolvedOutput"
