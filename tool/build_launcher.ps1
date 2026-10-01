# 배포 폴더 맨 위의 시작 프로그램 (jj_mkvmaker.exe → Lib\jj_mkvmaker.exe) 을 빌드한다.
# 결과: build\launcher\jj_mkvmaker.exe   (C 런타임 정적 연결 - 다른 DLL 없이 실행)
#
# 사용: powershell -File tool\build_launcher.ps1 [-VsDir <Visual Studio Build Tools 폴더>]
param([string]$VsDir = '')

$ErrorActionPreference = 'Stop'
$app = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $VsDir) { $VsDir = Join-Path $app '..\tools\VSBuildTools' }  # PS 5.1: $PSScriptRoot is empty in param defaults
$src = Join-Path $app 'windows\launcher'
$out = Join-Path $app 'build\launcher'
New-Item -ItemType Directory -Force $out | Out-Null

$vcvars = Get-ChildItem $VsDir -Recurse -Filter vcvars64.bat -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $vcvars) { throw "vcvars64.bat not found: $VsDir" }

$cmd = @"
call "$($vcvars.FullName)" >nul
cd /d "$out"
rc /nologo /fo launcher.res "$src\launcher.rc" || exit /b 1
cl /nologo /O2 /MT /EHsc /std:c++17 /utf-8 /DUNICODE /D_UNICODE "$src\launcher.cpp" launcher.res /Fe:jj_mkvmaker.exe /link /SUBSYSTEM:WINDOWS user32.lib shell32.lib || exit /b 1
"@
$bat = Join-Path $out 'build.cmd'
[IO.File]::WriteAllText($bat, $cmd, [Text.Encoding]::Default)
cmd /c $bat
if ($LASTEXITCODE -ne 0) { throw "launcher build failed" }
Join-Path $out 'jj_mkvmaker.exe'
