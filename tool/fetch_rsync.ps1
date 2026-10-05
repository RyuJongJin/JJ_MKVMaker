# rsync 를 third_party\rsync\windows 로 준비한다 (빌드 시 앱의 rsync\ 에 동봉됨, 내려받기 없이 바로 사용).
#   MSYS2 공식 저장소의 rsync 와 필요한 DLL. 패키지 목록 · SHA256 은 lib\core\sync_tools.dart 의 것을 그대로 쓴다.
#   Android 용은 tool\build_rsync_android.sh (NDK 로 소스에서 빌드).
# 사용법: powershell -File tool\fetch_rsync.ps1
$ErrorActionPreference = 'Stop'
$src = Get-Content (Join-Path $PSScriptRoot '..\lib\core\sync_tools.dart') -Raw -Encoding UTF8
$repo = [regex]::Match($src, "const msys2Repo = '([^']+)'").Groups[1].Value
$block = [regex]::Match($src, 'msys2RsyncPackages = <\(String, String\)>\[(.*?)\];', 'Singleline').Groups[1].Value
$pkgs = [regex]::Matches($block, "\('([^']+)', '([0-9a-f]{64})'\)")
$filesBlock = [regex]::Match($src, 'msys2RsyncFiles = \{(.*?)\};', 'Singleline').Groups[1].Value
$files = [regex]::Matches($filesBlock, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
if (-not $repo -or $pkgs.Count -eq 0 -or $files.Count -eq 0) { throw 'sync_tools.dart 에서 패키지 목록을 읽지 못했습니다' }

$dest = Join-Path $PSScriptRoot '..\third_party\rsync\windows'
$tmp = Join-Path $env:TEMP 'jj_rsync_fetch'
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $tmp, $dest | Out-Null
foreach ($m in $pkgs) {
    $name = $m.Groups[1].Value; $sha = $m.Groups[2].Value
    $f = Join-Path $tmp $name
    curl.exe -L -s -f -o $f "$repo$name"
    if ($LASTEXITCODE -ne 0) { throw "$name 을(를) 받지 못했습니다" }
    $got = (Get-FileHash $f -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $sha) { throw "$name 의 SHA256 이 다릅니다 ($got)" }
    tar.exe -xf $f -C $tmp usr/bin
    if ($LASTEXITCODE -ne 0) { throw "$name 을(를) 풀지 못했습니다" }
    Write-Host "확인: $name"
}
Get-ChildItem $dest | Remove-Item -Force
foreach ($n in $files) { Copy-Item (Join-Path $tmp "usr\bin\$n") $dest -Force }
& (Join-Path $dest 'rsync.exe') --version | Select-Object -First 1
Remove-Item $tmp -Recurse -Force
Write-Host "완료: $dest"
