# FFmpeg 를 third_party\ffmpeg\windows 로 준비한다 (빌드 시 앱에 동봉됨).
# 사용법: powershell -File tool\fetch_ffmpeg.ps1 [-Source M:\jj_CapCut\tools\ffmpeg]
param(
    [string]$Source = "M:\jj_CapCut\tools\ffmpeg"
)
$ErrorActionPreference = 'Stop'
$dest = Join-Path $PSScriptRoot '..\third_party\ffmpeg\windows'
New-Item -ItemType Directory -Force $dest | Out-Null

if (-not (Test-Path "$Source\bin\ffmpeg.exe")) {
    Write-Host "FFmpeg 내려받는 중 (gyan.dev release essentials)..."
    $zip = Join-Path $env:TEMP 'jj_ffmpeg.zip'
    $tmp = Join-Path $env:TEMP 'jj_ffmpeg'
    curl.exe -L -s -o $zip https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip
    Expand-Archive $zip -DestinationPath $tmp -Force
    $Source = (Get-ChildItem $tmp | Select-Object -First 1).FullName
}

# ffprobe 는 없어도 ffmpeg 로 대체하므로 ffmpeg.exe 만 필수
Copy-Item "$Source\bin\ffmpeg.exe" $dest -Force
if (Test-Path "$Source\LICENSE") { Copy-Item "$Source\LICENSE" "$dest\FFMPEG_LICENSE.txt" -Force }
Write-Host "완료: $dest"
