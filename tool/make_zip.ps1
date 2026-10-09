# 릴리스 zip 만들기 (166): stage 폴더 (make_layout -Clean) 를 zip 으로 묶고, 목록을 검사한다.
#   - zip 안 경로는 '/' 로 (Windows tar). 맨 위는 stage 폴더 이름 (JJ_MKVMaker/).
#   - 실행 흔적 (Logs\ · *.log · crash dump · 설정 · 세션 · 비밀 저장소 · 디버그 빌드 파일) 이 들어 있으면 실패한다.
# 사용: powershell -File tool\make_zip.ps1 -Stage '<루트>\release\stage\JJ_MKVMaker' -Zip '<루트>\release\JJ_MKVMaker_v<버전>_win64.zip'
param(
  [Parameter(Mandatory = $true)][string]$Stage,
  [Parameter(Mandatory = $true)][string]$Zip
)
$ErrorActionPreference = 'Stop'
$Stage = (Resolve-Path $Stage).Path
$parent = Split-Path $Stage -Parent
$name = Split-Path $Stage -Leaf
if (Test-Path $Zip) { Remove-Item $Zip -Force }
& "$env:SystemRoot\System32\tar.exe" -a -c -f $Zip -C $parent $name
if ($LASTEXITCODE -ne 0) { throw "tar 실패 ($LASTEXITCODE)" }

# 목록 검사
$list = & "$env:SystemRoot\System32\tar.exe" -t -f $Zip
if ($LASTEXITCODE -ne 0) { throw "zip 목록을 읽지 못함 ($LASTEXITCODE)" }
$bad = $list | Where-Object {
  $_ -match '(^|/)Logs/' -or
  $_ -match '\.(log|dmp|mdmp)$' -or
  $_ -match '(^|/)(settings|session)\.json(\.bak|\.tmp)?$' -or
  $_ -match '(^|/)settings\.broken-' -or
  $_ -match '(^|/)secrets\.dat$' -or
  $_ -match '(^|/)kernel_blob\.bin$' -or
  $_ -match '\\'
}
if ($bad) {
  Remove-Item $Zip -Force
  throw ("zip 에 넣으면 안 되는 파일이 있어 지웠습니다:`n" + ($bad -join "`n"))
}
if (-not ($list -contains "$name/jj_mkvmaker.exe")) {
  Remove-Item $Zip -Force
  throw "zip 맨 위에 $name/jj_mkvmaker.exe 가 없습니다"
}
$item = Get-Item $Zip
$hash = (Get-FileHash $Zip -Algorithm SHA256).Hash.ToLower()
"{0}  {1} bytes  {2} files  sha256 {3}" -f $item.Name, $item.Length, $list.Count, $hash
