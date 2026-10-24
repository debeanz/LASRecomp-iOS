# Your game files inside the IPA (Windows, on your own PC): a copy of the IPA with exefs and romfs in
# "LAS Recomp.app/extracted", so the app needs nothing copied in after installing (runtime/main.c finds them there).
# The result holds the whole game (~6 GB): keep it to yourself. Signing seals no longer match the added files:
# LiveContainer and SideStore sign the app again when they install it.
#
#   powershell -ExecutionPolicy Bypass -File tools\ios\add_game_files.ps1 -Ipa build\ios\LASRecomp-beta_5-ios.ipa -GameFiles "D:\LA extracted"
#
# -Ipa        the IPA from tools\ios\build_ipa.ps1
# -GameFiles  the folder with your extracted exefs and romfs (the same game version the IPA was built from)
# -Out        the new IPA (default: next to -Ipa, "-with-game" added to its name)
param(
    [Parameter(Mandatory = $true)][string]$Ipa,
    [Parameter(Mandatory = $true)][string]$GameFiles,
    [string]$Out
)
$ErrorActionPreference = "Stop"
function Fail($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$Ipa = (Resolve-Path -LiteralPath $Ipa).Path
if (-not $Out) { $Out = [IO.Path]::Combine([IO.Path]::GetDirectoryName($Ipa), [IO.Path]::GetFileNameWithoutExtension($Ipa) + "-with-game.ipa") }
$exefs = Join-Path $GameFiles "exefs"
$romfs = Join-Path $GameFiles "romfs"
if (-not (Test-Path -LiteralPath (Join-Path $exefs "main"))) { Fail "no exefs\main in ${GameFiles}" }
if (-not (Test-Path -LiteralPath (Join-Path $romfs "region_common"))) { Fail "no romfs\region_common in ${GameFiles}" }
$romfsFiles = @(Get-ChildItem -LiteralPath $romfs -Recurse -File)
if ($romfsFiles.Count -lt 3836) { Fail "romfs has $($romfsFiles.Count) of 3836 files: the copy is incomplete" }

# the app's own entries; it must be one built from this game version (the main program's build ID: runtime/gamelib.h)
$src = [IO.Compression.ZipFile]::OpenRead($Ipa)
$app = $null
foreach ($e in $src.Entries) { if ($e.FullName -match '^(Payload/[^/]+\.app/)lasrecomp$') { $app = $Matches[1] } }
if (-not $app) { $src.Dispose(); Fail "${Ipa} isn't a LAS Recomp IPA (no Payload/*.app/lasrecomp)" }
foreach ($e in $src.Entries) {
    if ($e.FullName.StartsWith($app + "extracted/")) { $src.Dispose(); Fail "${Ipa} already holds game files" }
}
$bid = -join ([IO.File]::ReadAllBytes((Join-Path $exefs "main"))[0x40..0x47] | ForEach-Object { $_.ToString("X2") })
$exe = $src.GetEntry($app + "lasrecomp")
$ms = New-Object IO.MemoryStream
$s = $exe.Open(); $s.CopyTo($ms); $s.Dispose()
$exeText = [Text.Encoding]::ASCII.GetString($ms.ToArray())
$ms.Dispose()
if ($exeText -notmatch ("-" + $bid)) {
    $src.Dispose()
    Fail "this IPA was built from another version of the game than ${GameFiles} (build ID $bid): build it from these files"
}

if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out }
$fs = [IO.File]::Open($Out, [IO.FileMode]::CreateNew)
$dst = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
$buf = New-Object byte[] (4MB)
function Add-Stream($name, $in, $level, $attr) {
    $entry = $dst.CreateEntry($name, $level)
    if ($attr) { $entry.ExternalAttributes = $attr }
    $o = $entry.Open()
    while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) { $o.Write($buf, 0, $n) }
    $o.Dispose()
}
try {
    foreach ($e in $src.Entries) {  # (as they were, with their Unix permissions: the executable stays executable)
        if ($e.FullName.EndsWith("/")) { $d = $dst.CreateEntry($e.FullName); $d.ExternalAttributes = $e.ExternalAttributes; continue }
        $in = $e.Open()
        Add-Stream $e.FullName $in ([IO.Compression.CompressionLevel]::Optimal) $e.ExternalAttributes
        $in.Dispose()
    }
    # the game's files, stored (its data is compressed already): rw-r--r-- regular files
    $fileAttr = [int](0x81A4 -shl 16)
    $all = @(Get-ChildItem -LiteralPath $exefs -Recurse -File | ForEach-Object { @{ f = $_; base = $GameFiles } }) +
           @($romfsFiles | ForEach-Object { @{ f = $_; base = $GameFiles } })
    $total = ($all | ForEach-Object { $_.f.Length } | Measure-Object -Sum).Sum
    $done = 0; $i = 0
    $root = (Resolve-Path -LiteralPath $GameFiles).Path.TrimEnd('\')
    foreach ($x in $all) {
        $rel = $x.f.FullName.Substring($root.Length + 1).Replace('\', '/')
        $in = [IO.File]::OpenRead($x.f.FullName)
        Add-Stream ($app + "extracted/" + $rel) $in ([IO.Compression.CompressionLevel]::NoCompression) $fileAttr
        $in.Dispose()
        $done += $x.f.Length; $i++
        if ($i % 50 -eq 0) { Write-Progress -Activity "Adding the game files" -Status "$([math]::Round($done / 1GB, 2)) of $([math]::Round($total / 1GB, 2)) GB" -PercentComplete ([int](100 * $done / $total)) }
    }
    Write-Progress -Activity "Adding the game files" -Completed
} catch {
    $dst.Dispose(); $fs.Dispose(); $src.Dispose()
    Remove-Item -LiteralPath $Out -ErrorAction SilentlyContinue
    Fail "writing ${Out}: $($_.Exception.Message)"
}
$dst.Dispose(); $fs.Dispose(); $src.Dispose()
Write-Host "Done: $Out ($([math]::Round((Get-Item -LiteralPath $Out).Length / 1GB, 2)) GB) - it holds your whole game: keep it to yourself." -ForegroundColor Green
