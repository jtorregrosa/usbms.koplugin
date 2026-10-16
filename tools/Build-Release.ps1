#Requires -Version 7
[CmdletBinding()]
param(
    [string]$OutputDir = (Join-Path $PSScriptRoot '..\dist')
)

$ErrorActionPreference = 'Stop'
$npx = if ($IsWindows) { 'npx.cmd' } else { 'npx' }
$repo = Split-Path $PSScriptRoot -Parent
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('usbms-release-' + [guid]::NewGuid().ToString('N'))
$stage = Join-Path $tmp 'usbms.koplugin'
$locales = 'ar bg_BG ca cs de el eo es eu fa fi fr ga gl he hi hr hu id it_IT ja ka ko_KR lt_LT lv nb_NO nl_NL pl pt_BR pt_PT ro ru sk sl sr sv tr uk vi zh_CN zh_TW'.Split(' ')
try {
    New-Item -ItemType Directory -Path $tmp | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'usbms.koplugin') -Destination $stage -Recurse
    Copy-Item -LiteralPath (Join-Path $repo 'LICENSE') -Destination (Join-Path $stage 'LICENSE')
    $luaNames = @('main.lua', '_meta.lua', 'usbms_l10n.lua') + @($locales | ForEach-Object { "l10n/$_.lua" })
    $luaPaths = @($luaNames | ForEach-Object { Join-Path $stage $_ })
    $asts = & $npx --yes --package=luaparse@0.3.1 luaparse --file @luaPaths
    if ($LASTEXITCODE -ne 0) { throw 'Lua syntax validation failed' }
    $manifestJson = $asts | & node (Join-Path $PSScriptRoot 'Check-PluginData.cjs') $stage
    if ($LASTEXITCODE -ne 0) { throw 'Plugin data validation failed' }
    $manifest = $manifestJson | ConvertFrom-Json
    $filename = "usbms.koplugin-v$($manifest.version).zip"
    $archivePath = Join-Path $tmp $filename
    Compress-Archive -LiteralPath $stage -DestinationPath $archivePath
    $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $entries = @($archive.Entries | Where-Object { -not $_.FullName.EndsWith('/') })
        $expected = @($manifest.files | ForEach-Object { "usbms.koplugin/$($_.path)" })
        if ($entries.Count -ne $expected.Count -or @(Compare-Object $expected @($entries.FullName)).Count -ne 0) {
            throw 'Unexpected ZIP structure'
        }
        foreach ($file in $manifest.files) {
            $entry = $archive.GetEntry("usbms.koplugin/$($file.path)")
            $stream = $entry.Open()
            try {
                $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()
                if ($hash -cne $file.sha256) { throw "ZIP checksum mismatch: $($file.path)" }
            } finally { $stream.Dispose() }
        }
    } finally { $archive.Dispose() }
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $target = Join-Path $OutputDir $filename
    if (Test-Path -LiteralPath $target) { throw "Release already exists: $target" }
    Copy-Item -LiteralPath $archivePath -Destination $target
    $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$target.sha256", "$hash  $filename`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText("$target.manifest.json", ($manifest | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Write-Output "Validated $($manifest.files.Count) files, $($manifest.locales) locales: $target"
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}