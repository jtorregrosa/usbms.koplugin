#Requires -Version 7
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$convert = Join-Path $repo 'tools/Convert-UsbScreens.ps1'
$build = Join-Path $repo 'tools/Build-Release.ps1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('usbms-release-test-' + [guid]::NewGuid().ToString('N'))
$inputDir = Join-Path $tmp 'input'
$outputDir = Join-Path $tmp 'output'
$releaseDir = Join-Path $tmp 'release'
function Expect-Failure([scriptblock]$Action, [string]$Label) {
    $failed = $false
    try { & $Action } catch { $failed = $true }
    if (-not $failed) { throw "Expected rejection: $Label" }
    Write-Output "PASS rejected $Label"
}
function Assert-Unchanged {
    foreach ($entry in $baseline.GetEnumerator()) {
        if ((Get-FileHash -LiteralPath (Join-Path $outputDir $entry.Key)).Hash -cne $entry.Value) {
            throw "Output changed after failed conversion: $($entry.Key)"
        }
    }
}
try {
    New-Item -ItemType Directory -Path $tmp, $inputDir | Out-Null
    & $convert -OutputDir $outputDir
    $baseline = @{}
    foreach ($file in Get-ChildItem -LiteralPath $outputDir -Filter *.raw) {
        $hash = (Get-FileHash -LiteralPath $file.FullName).Hash
        if ($hash -cne (Get-FileHash -LiteralPath (Join-Path $repo "usbms.koplugin/screens/$($file.Name)")).Hash) {
            throw "Conversion differs from shipped resource: $($file.Name)"
        }
        $baseline[$file.Name] = $hash
    }
    if ($baseline.Count -ne 3) { throw 'Incomplete conversion' }
    Write-Output 'PASS conversion matches shipped resources'
    Expect-Failure { & $convert -InputDir (Join-Path $tmp 'missing') -OutputDir $outputDir } 'missing directory'
    Expect-Failure { & $convert -InputDir $inputDir -OutputDir $outputDir } 'empty directory'
    Copy-Item -Path (Join-Path $repo 'screens/*.jpg') -Destination $inputDir
    Copy-Item -LiteralPath (Join-Path $inputDir 'usb-active.jpg') -Destination (Join-Path $inputDir 'usb-active.png')
    Expect-Failure { & $convert -InputDir $inputDir -OutputDir $outputDir } 'duplicate image'
    Remove-Item -LiteralPath (Join-Path $inputDir 'usb-active.png')
    [IO.File]::WriteAllText((Join-Path $inputDir 'usb-returning.jpg'), 'not an image')
    Expect-Failure { & $convert -InputDir $inputDir -OutputDir $outputDir } 'corrupt third image'
    Assert-Unchanged
    Write-Output 'PASS invalid input leaves outputs unchanged'
    & $build -OutputDir $releaseDir
    $zip = @(Get-ChildItem -LiteralPath $releaseDir -Filter *.zip)
    if ($zip.Count -ne 1) { throw 'Expected exactly one release ZIP' }
    $checksum = [IO.File]::ReadAllText($zip[0].FullName + '.sha256').Split(' ')[0]
    if ($checksum -cne (Get-FileHash -LiteralPath $zip[0].FullName).Hash.ToLowerInvariant()) { throw 'Invalid ZIP checksum' }
    $manifest = Get-Content -LiteralPath ($zip[0].FullName + '.manifest.json') -Raw | ConvertFrom-Json
    # Fixed files: main.lua, _meta.lua, usbms_l10n.lua, two helpers, LICENSE and three screens.
    $localeCount = @(Get-ChildItem -LiteralPath (Join-Path $repo 'usbms.koplugin/l10n') -Filter *.lua -File).Count
    if ($manifest.files.Count -ne 9 + $localeCount -or $manifest.locales -ne $localeCount) { throw 'Unexpected release manifest' }
    Expect-Failure { & $build -OutputDir $releaseDir } 'existing release ZIP'
    Write-Output 'PASS release package and checksum'
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}