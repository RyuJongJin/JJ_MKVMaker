# Build the distribution layout from a Flutter release build:
#
#   <Target>\jj_mkvmaker.exe   launcher (tool\build_launcher.ps1) -> runs Lib\jj_mkvmaker.exe
#   <Target>\LICENSE.txt, README.md
#   <Target>\Lib\...           everything from build\windows\x64\runner\Release
#   <Target>\Logs\             created by the app at run time
#
# -Clean : make <Target> exactly this layout (for the release zip stage folder)
# default: update in place (deploy folder) - keeps downloads, models, Logs and other user files,
#          and removes program files left at the top by the old single-folder layout.
param(
  [Parameter(Mandatory = $true)][string]$Target,
  [string]$Release = '',
  [switch]$Clean
)
$ErrorActionPreference = 'Stop'
$app = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $Release) { $Release = Join-Path $app 'build\windows\x64\runner\Release' }  # PS 5.1: $PSScriptRoot is empty in param defaults
$Release = (Resolve-Path $Release).Path
$launcher = Join-Path $app 'build\launcher\jj_mkvmaker.exe'
if (-not (Test-Path $launcher)) { $launcher = & (Join-Path $PSScriptRoot 'build_launcher.ps1') | Select-Object -Last 1 }
New-Item -ItemType Directory -Force $Target | Out-Null
$lib = Join-Path $Target 'Lib'

if ($Clean) {
  robocopy $Release $lib /E /PURGE /XD jj_yt-dlp jj_aria2 models /NFL /NDL /NJH /NJS /NP | Out-Null
  # nothing else at the top
  Get-ChildItem $Target | Where-Object { $_.Name -notin 'Lib' } | Remove-Item -Recurse -Force
} else {
  robocopy $Release $lib /E /XD jj_yt-dlp jj_aria2 models /NFL /NDL /NJH /NJS /NP | Out-Null
  # old single-folder layout: program files at the top that now live in Lib
  Get-ChildItem $Target -File | Where-Object {
    ($_.Extension -eq '.dll' -or $_.Name -in 'THIRD_PARTY_NOTICES.txt', 'native_assets.json') -and (Test-Path (Join-Path $lib $_.Name))
  } | Remove-Item -Force
  foreach ($pair in @(@('data', 'app.so'), @('ffmpeg', 'ffmpeg.exe'), @('tools', 'yt-dlp.exe'))) {
    $d = Join-Path $Target $pair[0]
    if ((Test-Path (Join-Path $d $pair[1])) -and (Test-Path (Join-Path $lib $pair[0]))) { Remove-Item $d -Recurse -Force }
  }
}
# debug build leftover (integration tests) must never ship
Remove-Item (Join-Path $lib 'data\flutter_assets\kernel_blob.bin') -Force -ErrorAction SilentlyContinue

Copy-Item $launcher (Join-Path $Target 'jj_mkvmaker.exe') -Force
Copy-Item (Join-Path $lib 'LICENSE.txt') (Join-Path $Target 'LICENSE.txt') -Force
Copy-Item (Join-Path $app 'README.md') (Join-Path $Target 'README.md') -Force
Get-ChildItem $Target | Select-Object -ExpandProperty Name
