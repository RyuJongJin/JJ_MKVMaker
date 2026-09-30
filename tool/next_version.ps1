# 다음 버전 번호를 정해 pubspec.yaml 에 적는다.
#
# 버전: 년.월.일_순번 (예: 2026.09.30_001)
#   - 같은 날 다시 내면 순번 +1
#   - 날이 바뀌면 001 부터 다시
# pubspec.yaml 에는 Flutter 형식인 "2026.9.30+1" 로 적힌다 (앞의 0 은 쓸 수 없음).
# 프로그램 제목 · 업데이트 창 · 태그 · zip 이름에는 "2026.09.30_001" 로 보인다.
#
# 사용: powershell -File tool\next_version.ps1          → 번호를 올리고 새 번호 출력
#       powershell -File tool\next_version.ps1 -Show    → 지금 번호만 출력
param([switch]$Show)

$pubspec = Join-Path $PSScriptRoot '..\pubspec.yaml'
$text = [IO.File]::ReadAllText($pubspec)
if ($text -notmatch '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$') { throw 'pubspec.yaml 에서 version 을 찾을 수 없습니다.' }
$y = [int]$Matches[1]; $m = [int]$Matches[2]; $d = [int]$Matches[3]; $n = [int]$Matches[4]

function Format-Version($y, $m, $d, $n) { '{0}.{1:00}.{2:00}_{3:000}' -f $y, $m, $d, $n }

if ($Show) { Format-Version $y $m $d $n; return }

$today = Get-Date
if ($y -eq $today.Year -and $m -eq $today.Month -and $d -eq $today.Day) { $n++ } else { $n = 1 }
$y = $today.Year; $m = $today.Month; $d = $today.Day
$text = [regex]::Replace($text, '(?m)^version:.*$', "version: $y.$m.$d+$n")
[IO.File]::WriteAllText($pubspec, $text, (New-Object Text.UTF8Encoding $false))
Format-Version $y $m $d $n
