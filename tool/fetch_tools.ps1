# 다운로드 도구를 third_party\tools\windows 로 준비한다 (빌드 시 앱의 tools\ 에 동봉됨).
#   yt-dlp  : https://github.com/yt-dlp/yt-dlp   (YouTube 등 동영상)
#   aria2c  : https://github.com/aria2/aria2     (토렌트 · 마그넷)
#   deno    : https://github.com/denoland/deno   (yt-dlp 의 YouTube 추출용 JavaScript 실행기)
# 사용법: powershell -File tool\fetch_tools.ps1
$ErrorActionPreference = 'Stop'
$dest = Join-Path $PSScriptRoot '..\third_party\tools\windows'
New-Item -ItemType Directory -Force $dest | Out-Null
$tmp = Join-Path $env:TEMP 'jj_tools'
New-Item -ItemType Directory -Force $tmp | Out-Null

function Latest($repo, $pattern) {
    $rel = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest"
    $a = $rel.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
    Write-Host "$repo $($rel.tag_name): $($a.name)"
    return $a.browser_download_url
}

curl.exe -L -s -o "$dest\yt-dlp.exe" (Latest 'yt-dlp/yt-dlp' '^yt-dlp\.exe$')

curl.exe -L -s -o "$tmp\aria2.zip" (Latest 'aria2/aria2' 'win-64bit.*\.zip$')
Expand-Archive "$tmp\aria2.zip" "$tmp\aria2" -Force
Copy-Item (Get-ChildItem "$tmp\aria2" -Recurse -Filter aria2c.exe | Select-Object -First 1).FullName $dest -Force

curl.exe -L -s -o "$tmp\deno.zip" (Latest 'denoland/deno' '^deno-x86_64-pc-windows-msvc\.zip$')
Expand-Archive "$tmp\deno.zip" $dest -Force

Get-ChildItem $dest | ForEach-Object { '{0,-12} {1,6:N1} MB' -f $_.Name, ($_.Length / 1MB) }
Write-Host "완료: $dest"
