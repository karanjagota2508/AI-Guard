param(
    [string]$SourceLogoPath = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "techeights logo.png")
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing

function New-SquareCanvasImage {
    param(
        [System.Drawing.Image]$SourceImage,
        [int]$Size
    )

    $bitmap = New-Object System.Drawing.Bitmap $Size, $Size
    $bitmap.SetResolution($SourceImage.HorizontalResolution, $SourceImage.VerticalResolution)

    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality

        $padding = [Math]::Round($Size * 0.12)
        $maxWidth = $Size - ($padding * 2)
        $maxHeight = $Size - ($padding * 2)
        $scale = [Math]::Min($maxWidth / $SourceImage.Width, $maxHeight / $SourceImage.Height)
        $targetWidth = [int][Math]::Round($SourceImage.Width * $scale)
        $targetHeight = [int][Math]::Round($SourceImage.Height * $scale)
        $targetX = [int][Math]::Round(($Size - $targetWidth) / 2)
        $targetY = [int][Math]::Round(($Size - $targetHeight) / 2)

        $graphics.DrawImage($SourceImage, $targetX, $targetY, $targetWidth, $targetHeight)
    } finally {
        $graphics.Dispose()
    }

    return $bitmap
}

function Save-Png {
    param(
        [System.Drawing.Image]$Image,
        [string]$Path
    )

    $parent = Split-Path $Path -Parent
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $Image.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
}

function Save-Icon {
    param(
        [System.Drawing.Bitmap]$Bitmap,
        [string]$Path
    )

    $parent = Split-Path $Path -Parent
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $icon = [System.Drawing.Icon]::FromHandle($Bitmap.GetHicon())
    try {
        $fileStream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
        try {
            $icon.Save($fileStream)
        } finally {
            $fileStream.Dispose()
        }
    } finally {
        $icon.Dispose()
    }
}

if (-not (Test-Path $SourceLogoPath)) {
    throw "Missing source logo at $SourceLogoPath"
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$installerRoot = Join-Path $repoRoot "installer"
$extensionRoot = Join-Path $repoRoot "extension"
$brandingRoot = $PSScriptRoot

$extensionAssetsRoot = Join-Path $extensionRoot "assets"
$bootstrapperLogoPath = Join-Path $installerRoot "bootstrapper\brand-logo.png"
$bootstrapperIconPath = Join-Path $installerRoot "bootstrapper\brand-icon.ico"
$brandingLogoPath = Join-Path $brandingRoot "logo.png"
$brandingIconPath = Join-Path $brandingRoot "logo.ico"
$extensionLogoPath = Join-Path $extensionAssetsRoot "logo.png"

New-Item -ItemType Directory -Force -Path $extensionAssetsRoot | Out-Null

$logoImage = [System.Drawing.Image]::FromFile($SourceLogoPath)
try {
    Copy-Item -LiteralPath $SourceLogoPath -Destination $brandingLogoPath -Force
    Copy-Item -LiteralPath $SourceLogoPath -Destination $bootstrapperLogoPath -Force
    Copy-Item -LiteralPath $SourceLogoPath -Destination $extensionLogoPath -Force

    foreach ($size in @(16, 32, 48, 128)) {
        $iconBitmap = New-SquareCanvasImage -SourceImage $logoImage -Size $size
        try {
            Save-Png -Image $iconBitmap -Path (Join-Path $extensionAssetsRoot ("icon{0}.png" -f $size))
        } finally {
            $iconBitmap.Dispose()
        }
    }

    $icon256 = New-SquareCanvasImage -SourceImage $logoImage -Size 256
    try {
        Save-Png -Image $icon256 -Path (Join-Path $brandingRoot "icon256.png")
        Save-Icon -Bitmap $icon256 -Path $bootstrapperIconPath
        Save-Icon -Bitmap $icon256 -Path $brandingIconPath
    } finally {
        $icon256.Dispose()
    }
} finally {
    $logoImage.Dispose()
}

Write-Host "Generated Ulti Guard brand assets from $SourceLogoPath"
