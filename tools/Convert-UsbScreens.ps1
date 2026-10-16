#Requires -Version 7
<#
.SYNOPSIS
Turns the three USB status images into raw framebuffer dumps for usbms.koplugin.
.DESCRIPTION
The helper writes each screen straight to /dev/fb0 (eips -g misplaces PNGs on the PW2, and
KOReader's fbink has no image support). The PW2 framebuffer is 8-bit grayscale, 758 pixels per
row stored in 768 bytes, 1024 rows: 786432 bytes per screen. 0 is black, 255 is white.
#>
[CmdletBinding()]
param(
    [string]$InputDir = (Join-Path $PSScriptRoot '..\screens'),
    [string]$OutputDir = (Join-Path $PSScriptRoot '..\usbms.koplugin\screens')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$width = 758
$stride = 768
$height = 1024

$names = @('usb-waiting', 'usb-active', 'usb-returning')
if (-not (Test-Path -LiteralPath $InputDir -PathType Container)) { throw "Missing input directory: $InputDir" }
$sources = @{}
foreach ($name in $names) {
    $matches = @(Get-ChildItem -LiteralPath $InputDir -File | Where-Object {
        $_.BaseName -ceq $name -and $_.Extension.ToLowerInvariant() -in '.jpg', '.jpeg', '.png'
    })
    if ($matches.Count -ne 1) { throw "Expected exactly one JPG or PNG for $name; found $($matches.Count)" }
    $sources[$name] = $matches[0].FullName
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('usbms-screens-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    foreach ($name in $names) {
        $image = $null
        $bitmap = $null
        $graphics = $null
        $attributes = $null
        $data = $null
        try {
            $image = [System.Drawing.Image]::FromFile($sources[$name])
            if ($image.Width -gt $image.Height) { $image.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipNone) }
            $scale = [math]::Max($width / $image.Width, $height / $image.Height)
            $drawWidth = [int][math]::Round($image.Width * $scale)
            $drawHeight = [int][math]::Round($image.Height * $scale)
            $left = [int](($width - $drawWidth) / 2)
            $top = [int](($height - $drawHeight) / 2)
            $bitmap = [System.Drawing.Bitmap]::new($width, $height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            $graphics.Clear([System.Drawing.Color]::White)
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $attributes = [System.Drawing.Imaging.ImageAttributes]::new()
            $attributes.SetColorMatrix([System.Drawing.Imaging.ColorMatrix]::new([float[][]]@(
                [float[]]@(0.299, 0.299, 0.299, 0, 0),
                [float[]]@(0.587, 0.587, 0.587, 0, 0),
                [float[]]@(0.114, 0.114, 0.114, 0, 0),
                [float[]]@(0, 0, 0, 1, 0),
                [float[]]@(0, 0, 0, 0, 1)
            )))
            $graphics.DrawImage($image, [System.Drawing.Rectangle]::new($left, $top, $drawWidth, $drawHeight),
                0, 0, $image.Width, $image.Height, [System.Drawing.GraphicsUnit]::Pixel, $attributes)
            $graphics.Dispose()
            $graphics = $null
            $rect = [System.Drawing.Rectangle]::new(0, 0, $width, $height)
            $data = $bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
            $row = [byte[]]::new($width * 3)
            $raw = [byte[]]::new($stride * $height)
            [Array]::Fill($raw, [byte]255)
            for ($rowIndex = 0; $rowIndex -lt $height; $rowIndex++) {
                [Runtime.InteropServices.Marshal]::Copy([IntPtr]::Add($data.Scan0, $rowIndex * $data.Stride), $row, 0, $row.Length)
                for ($column = 0; $column -lt $width; $column++) {
                    $raw[$rowIndex * $stride + $column] = $row[$column * 3 + 1]
                }
            }
            [IO.File]::WriteAllBytes((Join-Path $tmp "$name.raw"), $raw)
        } finally {
            if ($data) { $bitmap.UnlockBits($data) }
            if ($graphics) { $graphics.Dispose() }
            if ($attributes) { $attributes.Dispose() }
            if ($bitmap) { $bitmap.Dispose() }
            if ($image) { $image.Dispose() }
        }
    }
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    foreach ($name in $names) {
        Copy-Item -LiteralPath (Join-Path $tmp "$name.raw") -Destination (Join-Path $OutputDir "$name.raw") -Force
        Write-Host "wrote $name.raw ($($stride * $height) bytes)"
    }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
