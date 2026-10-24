# One command on Windows: your exefs -> your PRIVATE GitHub repository -> the cloud build (.github/workflows/ios.yml,
# in the public code repository) -> the IPA, downloaded here. Needs the GitHub CLI (gh), signed in.
#
#   powershell -ExecutionPolicy Bypass -File tools\ios\build_ipa.ps1 -GameFiles "D:\LA extracted"
#
# -GameFiles  the folder with your extracted exefs (and romfs) - version 1.0.0, 1.0.1 or 1.1.0. Only exefs is
#             uploaded (the game's code, ~40 MB); romfs stays here and goes onto the iPhone with the Files app.
# -CodeRepo   the public repository with this code and the workflow (default: <you>/LASRecomp-iOS)
# -DataRepo   your private repository for the game files and the IPA (default: <you>/LASRecomp-iOS-private; created
#             private if missing, refused if it isn't private)
# -Token      what the workflow reads / writes the private repository with (default: this gh sign-in's token; a
#             fine-grained token limited to the private repository is safer)
# -Out        where the IPA goes (default: build\ios)
param(
    [Parameter(Mandatory = $true)][string]$GameFiles,
    [string]$CodeRepo,
    [string]$DataRepo,
    [string]$Token,
    [string]$Out = "build\ios",
    [switch]$SkipUpload
)
$ErrorActionPreference = "Stop"
function Fail($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Fail "GitHub CLI (gh) not found: https://cli.github.com" }
$me = (gh api user --jq .login)
if (-not $me) { Fail "gh is not signed in: gh auth login" }
if (-not $CodeRepo) { $CodeRepo = "$me/LASRecomp-iOS" }
if (-not $DataRepo) { $DataRepo = "$me/LASRecomp-iOS-private" }

# the exefs folder: <GameFiles>\exefs, or GameFiles itself when it holds main / main.npdm
$exefs = Join-Path $GameFiles "exefs"
if (-not (Test-Path -LiteralPath (Join-Path $exefs "main"))) {
    if (Test-Path -LiteralPath (Join-Path $GameFiles "main")) { $exefs = $GameFiles }
    elseif (Get-ChildItem -LiteralPath $GameFiles -Filter *.nsp -ErrorAction SilentlyContinue) {
        Fail "${GameFiles} holds .nsp packages - LAS Recomp needs the game's extracted exefs and romfs folders."
    } else { Fail "no exefs\main in ${GameFiles}" }
}
foreach ($f in "main", "main.npdm", "sdk") {
    if (-not (Test-Path -LiteralPath (Join-Path $exefs $f))) { Fail "${exefs} has no ${f} - not a complete exefs" }
}

# the private repository: created private, never used when it is public
$vis = gh api "repos/$DataRepo" --jq .visibility 2>$null
if (-not $vis) {
    Write-Host "Creating the private repository $DataRepo"
    gh repo create $DataRepo --private --description "LAS Recomp iOS: my own game files and builds (private)" | Out-Null
    $vis = "private"
}
if ($vis -ne "private") { Fail "${DataRepo} is ${vis} - it must be private (it will hold your game files)" }

if (-not $SkipUpload) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("las-exefs-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Force (Join-Path $tmp "exefs") | Out-Null
    Copy-Item -LiteralPath (Get-ChildItem -LiteralPath $exefs).FullName -Destination (Join-Path $tmp "exefs") -Recurse
    $zip = Join-Path ([IO.Path]::GetTempPath()) "exefs.zip"
    if (Test-Path $zip) { Remove-Item $zip }
    Compress-Archive -Path (Join-Path $tmp "exefs") -DestinationPath $zip
    Remove-Item -Recurse -Force $tmp
    gh release view game-files -R $DataRepo *> $null
    if ($LASTEXITCODE -ne 0) {
        gh release create game-files -R $DataRepo --title "Game files" --notes "My own exefs, for my own builds. Private." | Out-Null
    }
    Write-Host "Uploading exefs ($([math]::Round((Get-Item $zip).Length / 1MB)) MB) to $DataRepo"
    gh release upload game-files $zip -R $DataRepo --clobber
    if ($LASTEXITCODE -ne 0) { Fail "upload failed" }
    Remove-Item $zip
}

# what the workflow needs to reach it
if (-not $Token) { $Token = (gh auth token) }
gh variable set LAS_PRIVATE_REPO -R $CodeRepo --body $DataRepo | Out-Null
$Token | gh secret set LAS_PRIVATE_TOKEN -R $CodeRepo | Out-Null

Write-Host "Starting the iOS build on $CodeRepo"
$before = (Get-Date).ToUniversalTime().AddSeconds(-5)
gh workflow run ios.yml -R $CodeRepo --ref ios-port -f build_ipa=true
if ($LASTEXITCODE -ne 0) { Fail "could not start the workflow" }
$run = $null
for ($i = 0; $i -lt 30 -and -not $run; $i++) {
    Start-Sleep -Seconds 4
    $run = gh run list -R $CodeRepo --workflow ios.yml --event workflow_dispatch --limit 5 --json databaseId,createdAt |
        ConvertFrom-Json | Where-Object { ([datetime]$_.createdAt).ToUniversalTime() -ge $before } | Select-Object -First 1
}
if (-not $run) { Fail "the run didn't show up: see https://github.com/$CodeRepo/actions" }
Write-Host "https://github.com/$CodeRepo/actions/runs/$($run.databaseId) (about 30-60 minutes the first time)"
gh run watch $run.databaseId -R $CodeRepo --exit-status
if ($LASTEXITCODE -ne 0) { Fail "the build failed: https://github.com/$CodeRepo/actions/runs/$($run.databaseId)" }

New-Item -ItemType Directory -Force $Out | Out-Null
gh release download ipa -R $DataRepo -p "*.ipa" -D $Out --clobber
$ipa = Get-ChildItem $Out -Filter *.ipa | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Host "Done: $($ipa.FullName)" -ForegroundColor Green
Write-Host "Install it with SideStore / AltStore, then copy exefs and romfs into Files > On My iPhone > LAS Recomp > extracted."
