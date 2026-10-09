import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/l10n/tr.dart';
import 'package:jj_mkvmaker/platform/windows/recycle_bin.dart';
import 'package:path/path.dart' as p;

/// 실제 사용자 휴지통을 쓰는 시험은 이 값이 1 일 때만 (휴지통 쪽 코드를 고칠 때 · 릴리스 전에 따로 돌리고 흔적 0 확인).
/// 기본 전체 시험은 [FakeRecycleBin] 으로 흐름만 본다 - 시험이 도중에 끊기면 사용자 휴지통에 흔적이 남기 때문.
bool get realRecycleBin => Platform.environment['JJ_TEST_REAL_RECYCLE'] == '1';

/// 실제 휴지통 시험을 건너뛸 때의 이유 (skip 에 그대로)
Object get realRecycleSkip => !Platform.isWindows
    ? 'Windows 만'
    : realRecycleBin
        ? false
        : '실제 휴지통 시험은 JJ_TEST_REAL_RECYCLE=1 일 때만';

/// 시험 하나 동안 휴지통을 가짜로 (JJ_TEST_REAL_RECYCLE=1 이면 실제 휴지통 그대로). 가짜 휴지통을 돌려준다 (실제면 null).
FakeRecycleBin? useTestRecycleBin() {
  if (realRecycleBin) return null;
  final fake = FakeRecycleBin();
  recycleBinForTest = fake;
  addTearDown(() {
    recycleBinForTest = null;
    fake.dispose();
  });
  return fake;
}

/// 시험용 휴지통: 시험 임시 폴더 안의 자기 폴더로 옮기고, 실제 휴지통과 같은 규칙으로 되돌린다
/// (긴 경로는 받지 않음 · 원래 자리에 같은 이름이 있으면 덮지 않음 · 원래 폴더가 없으면 다시 만들지 않음).
class FakeRecycleBin implements RecycleBinBackend {
  final Directory bin = Directory.systemTemp.createTempSync('jj_fake_recycle_');

  /// 원래 경로 → 휴지통 안의 경로 (보낸 차례대로)
  final items = <String, String>{};
  var _n = 0;

  @override
  RecycleResult move(String path) {
    if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound) return RecycleResult.recycled;
    final long = longPathInside(path);
    if (long != null) throw LongPathException(recycleErrorText(0x7C), long);
    final full = File(path).absolute.path;
    final to = p.join(bin.path, '\$R${_n++}${p.extension(full)}');
    _move(full, to);
    items[full] = to;
    return RecycleResult.recycled;
  }

  @override
  void restore(String original, {required DateTime since}) {
    final from = items[File(original).absolute.path];
    if (from == null) throw FileSystemException(tr('휴지통에서 찾지 못했습니다 (이미 비웠거나 되돌림)'), original);
    if (FileSystemEntity.typeSync(original, followLinks: false) != FileSystemEntityType.notFound) {
      throw FileSystemException(tr('원래 자리에 같은 이름이 이미 있습니다'), original);
    }
    if (!Directory(p.dirname(original)).existsSync()) {
      throw FileSystemException(tr('원래 폴더가 없어 되돌리지 못했습니다 (휴지통에서 직접 복원하세요)'), original);
    }
    _move(from, original);
    items.remove(File(original).absolute.path);
  }

  /// 옮기기 (다른 드라이브면 복사한 뒤 지운다 - 시험 폴더가 M: 이고 가짜 휴지통이 C: 의 임시 폴더일 때)
  static void _move(String from, String to) {
    final dir = FileSystemEntity.isDirectorySync(from);
    try {
      dir ? Directory(from).renameSync(to) : File(from).renameSync(to);
      return;
    } on FileSystemException {
      // 아래에서 복사
    }
    if (!dir) {
      File(from).copySync(to);
      File(from).deleteSync();
      return;
    }
    Directory(to).createSync(recursive: true);
    for (final e in Directory(from).listSync(recursive: true, followLinks: false)) {
      final dst = p.join(to, p.relative(e.path, from: from));
      if (e is Directory) {
        Directory(dst).createSync(recursive: true);
      } else if (e is File) {
        File(dst).parent.createSync(recursive: true);
        e.copySync(dst);
      }
    }
    Directory(from).deleteSync(recursive: true);
  }

  void dispose() {
    try {
      bin.deleteSync(recursive: true);
    } catch (_) {}
  }
}
