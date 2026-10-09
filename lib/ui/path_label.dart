import 'dart:io';

import '../core/vfs.dart';
import '../core/webdav.dart' show DavRegistry;
import '../l10n/tr.dart';

/// 화면에 보일 경로 (67): Android 는 "내장 저장소 › Download › 폴더", WebDAV 는 "☁ 서버 › 폴더", Windows 는 "D: › 폴더"
String friendlyPath(String path) {
  if (isDav(path)) {
    final d = DavPath.parse(path);
    final label = DavRegistry.server(d.server)?.label ?? 'WebDAV';
    return ['☁ $label', ...d.rel.split('/').where((s) => s.isNotEmpty)].join(' › ');
  }
  if (Platform.isAndroid || path.startsWith('/storage/')) {
    final m = RegExp(r'^/storage/(emulated/\d+|[^/]+)(/.*)?$').firstMatch(path);
    if (m != null) {
      final root = m[1]!.startsWith('emulated/') ? tr('내장 저장소') : tr('SD 카드');
      return [root, ...(m[2] ?? '').split('/').where((s) => s.isNotEmpty)].join(' › ');
    }
  }
  final parts = path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.join(' › ');
}

/// 짧게: 끝의 [keep] 단계만 (앞은 "…"). 쌍이 여러 개여도 무엇이 무엇인지 보이게 (67)
String shortPath(String path, {int keep = 3}) {
  final parts = friendlyPath(path).split(' › ');
  return parts.length <= keep ? parts.join(' › ') : ['…', ...parts.sublist(parts.length - keep)].join(' › ');
}
