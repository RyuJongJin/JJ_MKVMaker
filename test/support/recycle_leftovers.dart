import 'dart:io';

/// 휴지통을 건드리는 시험이 끝날 때: 사용자 휴지통 전체에서, 원래 위치가 [underDir] 아래 (하위 폴더 포함) 인 항목 수.
/// 시험 흔적이 남지 않았는지 시험이 스스로 확인한다 (0 이어야 함). 알 수 없으면 -1.
Future<int> recycleLeftovers(String underDir) async {
  if (!Platform.isWindows) return 0;
  final dir = File(underDir).absolute.path.replaceAll("'", "''");
  final r = await Process.run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    '''
\$rb = (New-Object -ComObject Shell.Application).Namespace(10)
\$root = '$dir'.TrimEnd('\\')
\$n = 0
foreach (\$it in @(\$rb.Items())) {
  \$loc = \$rb.GetDetailsOf(\$it, 1)
  if (\$loc -ieq \$root -or \$loc.StartsWith(\$root + '\\', [System.StringComparison]::OrdinalIgnoreCase)) { \$n++ }
}
\$n
''',
  ]);
  return int.tryParse('${r.stdout}'.trim().split('\n').last.trim()) ?? -1;
}
