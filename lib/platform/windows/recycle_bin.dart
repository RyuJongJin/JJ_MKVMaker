import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../../l10n/tr.dart';

/// 휴지통으로 보낸 결과 (94: "휴지통으로 보냈습니다" 라고 하고 실제로는 영구 삭제되는 일이 없게)
enum RecycleResult {
  /// 휴지통에 들어갔다 (되살릴 수 있음)
  recycled,

  /// 휴지통에 들어가지 않고 지워졌다 (휴지통보다 큰 파일 - Windows 가 물었고 사용자가 지우기를 골랐음)
  deletedPermanently,

  /// 사용자가 Windows 의 경고 창에서 취소했다 (그대로 남음)
  cancelled,
}

/// 이 경로가 있는 곳에 휴지통이 있는지 (94). Windows 의 휴지통은 고정 디스크에만 있다:
/// 네트워크 드라이브 (Z:) · \\NAS\공유 · USB 메모리 · CD 는 휴지통 없이 바로 지워진다.
bool hasRecycleBin(String path) {
  if (!Platform.isWindows) return false;
  if (path.startsWith(r'\\')) return false;
  final m = RegExp(r'^([a-zA-Z]):').firstMatch(path);
  if (m == null) return false;
  final root = '${m[1]}:\\'.toNativeUtf16();
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final getDriveType = kernel32.lookupFunction<Uint32 Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>('GetDriveTypeW');
    return getDriveType(root) == 3; // DRIVE_FIXED
  } catch (_) {
    return false;
  } finally {
    calloc.free(root);
  }
}

/// 휴지통에 든 항목 수 (그 드라이브). 모르면 null
int? _binCount(String path) {
  final m = RegExp(r'^([a-zA-Z]):').firstMatch(path);
  if (m == null) return null;
  final root = '${m[1]}:\\'.toNativeUtf16();
  final info = calloc<_RbInfo>();
  try {
    final shell32 = DynamicLibrary.open('shell32.dll');
    final query = shell32.lookupFunction<Int32 Function(Pointer<Utf16>, Pointer<_RbInfo>),
        int Function(Pointer<Utf16>, Pointer<_RbInfo>)>('SHQueryRecycleBinW');
    info.ref.cbSize = sizeOf<_RbInfo>();
    return query(root, info) == 0 ? info.ref.numItems : null;
  } catch (_) {
    return null;
  } finally {
    calloc.free(root);
    calloc.free(info);
  }
}

/// 휴지통 정보 파일 ($I…) 에 적힌 원래 경로. Windows 10 이상 (판 2: 길이 + 경로) · 예전 (판 1: 260자 고정). 모르면 null
String? recycledInfoPath(List<int> bytes) {
  if (bytes.length < 28) return null;
  final version = bytes[0] | bytes[1] << 8;
  int start, end;
  if (version == 2) {
    final n = bytes[24] | bytes[25] << 8 | bytes[26] << 16 | bytes[27] << 24;
    start = 28;
    end = start + n * 2;
  } else if (version == 1) {
    start = 24;
    end = 24 + 520;
  } else {
    return null;
  }
  if (end > bytes.length) end = bytes.length - bytes.length % 2;
  final units = <int>[];
  for (var i = start; i + 1 < end; i += 2) {
    final u = bytes[i] | bytes[i + 1] << 8;
    if (u == 0) break;
    units.add(u);
  }
  return String.fromCharCodes(units);
}

/// 그 드라이브 휴지통에 [original] 의 정보 파일이 [since] 뒤에 생겼는지. 휴지통 폴더를 읽을 수 없으면 null
bool? recycledInfoExists(String original, {required DateTime since}) {
  final m = RegExp(r'^([a-zA-Z]):').firstMatch(original);
  if (m == null) return null;
  final bin = Directory('${m[1]}:\\\$Recycle.Bin');
  var readable = false;
  try {
    for (final user in bin.listSync(followLinks: false).whereType<Directory>()) {
      List<FileSystemEntity> items;
      try {
        items = user.listSync(followLinks: false); // 다른 사용자의 휴지통은 읽을 수 없다
      } catch (_) {
        continue;
      }
      readable = true;
      for (final f in items.whereType<File>()) {
        final name = f.uri.pathSegments.last;
        if (!name.startsWith(r'$I')) continue;
        try {
          if (f.lastModifiedSync().isBefore(since)) continue;
          final p = recycledInfoPath(f.readAsBytesSync());
          if (p != null && p.toLowerCase() == original.toLowerCase()) return true;
        } catch (_) {}
      }
    }
  } catch (_) {
    return null;
  }
  return readable ? false : null;
}

/// 지금 사용자의 SID (예: S-1-5-21-…, 휴지통 폴더 이름). 모르면 null
String? currentUserSid() => _sid ??= () {
      try {
        // 전체 경로로 (PATH 에 Git 등의 다른 whoami 가 먼저 있을 수 있다)
        final exe = '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\whoami.exe';
        final r = Process.runSync(exe, ['/user', '/fo', 'csv', '/nh']);
        return RegExp(r'"(S-1-[0-9-]+)"').firstMatch('${r.stdout}')?.group(1);
      } catch (_) {
        return null;
      }
    }();
String? _sid;

/// 148: 방금 휴지통으로 보낸 [original] 을 원래 자리로 되돌린다 ([since] 뒤에 생긴 것 중 가장 새것).
/// 휴지통의 $R… (내용) 을 원래 경로로 옮기고 $I… (정보) 를 지운다. 원래 자리에 이미 무엇이 있으면 덮지 않고 실패.
/// 실패하면 [FileSystemException] (이유는 읽을 수 있는 말).
void restoreFromRecycleBin(String original, {required DateTime since}) {
  final m = RegExp(r'^([a-zA-Z]):').firstMatch(original);
  if (m == null) throw FileSystemException(tr('휴지통이 없는 곳입니다'), original);
  if (FileSystemEntity.typeSync(original, followLinks: false) != FileSystemEntityType.notFound) {
    throw FileSystemException(tr('원래 자리에 같은 이름이 이미 있습니다'), original);
  }
  // 원래 폴더가 그사이 지워졌으면 다시 만들지 않는다 (사용자가 지운 폴더를 몰래 되살리지 않게)
  if (!Directory(p.dirname(original)).existsSync()) {
    throw FileSystemException(tr('원래 폴더가 없어 되돌리지 못했습니다 (휴지통에서 직접 복원하세요)'), original);
  }
  // 이 사용자 (SID) 의 휴지통 폴더에서만 찾는다 (관리자 권한으로 다른 사용자의 휴지통을 읽을 수 있어도)
  final sid = currentUserSid();
  if (sid == null) throw FileSystemException(tr('휴지통에서 찾지 못했습니다 (이미 비웠거나 되돌림)'), original);
  File? info;
  DateTime? newest;
  final bin = Directory('${m[1]}:\\\$Recycle.Bin');
  try {
    for (final user in [Directory('${bin.path}\\$sid')]) {
      List<FileSystemEntity> items;
      try {
        items = user.listSync(followLinks: false);
      } catch (_) {
        continue;
      }
      for (final f in items.whereType<File>()) {
        if (!f.uri.pathSegments.last.startsWith(r'$I')) continue;
        try {
          final t = f.lastModifiedSync();
          if (t.isBefore(since) || (newest != null && t.isBefore(newest))) continue;
          final was = recycledInfoPath(f.readAsBytesSync());
          if (was != null && was.toLowerCase() == original.toLowerCase()) {
            info = f;
            newest = t;
          }
        } catch (_) {}
      }
    }
  } catch (_) {}
  final i = info;
  if (i == null) throw FileSystemException(tr('휴지통에서 찾지 못했습니다 (이미 비웠거나 되돌림)'), original);
  final dir = i.parent.path;
  final content = '$dir\\\$R${i.uri.pathSegments.last.substring(2)}';
  final type = FileSystemEntity.typeSync(content, followLinks: false);
  if (type == FileSystemEntityType.notFound) throw FileSystemException(tr('휴지통에서 찾지 못했습니다 (이미 비웠거나 되돌림)'), original);
  if (type == FileSystemEntityType.directory) {
    Directory(content).renameSync(original);
  } else {
    File(content).renameSync(original);
  }
  try {
    i.deleteSync();
  } catch (_) {}
}

/// 휴지통이 받을 수 있는 경로 길이 (MAX_PATH - 끝의 NUL)
const recycleMaxPath = 259;

/// [path] (폴더면 그 안까지) 에 휴지통이 받지 못하는 긴 경로가 있으면 그 경로, 없으면 null
String? longPathInside(String path) {
  final full = File(path).absolute.path;
  if (full.length > recycleMaxPath) return full;
  if (FileSystemEntity.typeSync(full, followLinks: false) != FileSystemEntityType.directory) return null;
  try {
    for (final e in Directory(full).listSync(recursive: true, followLinks: false)) {
      if (e.path.length > recycleMaxPath) return e.path;
    }
  } catch (_) {
    // 긴 경로 때문에 목록을 다 읽지 못함 - 그것도 긴 경로가 있다는 뜻
    return full;
  }
  return null;
}

/// SHFileOperation 의 오류 번호를 사람이 읽을 말로 (98)
String recycleErrorText(int code) => switch (code) {
      0x02 || 0x03 => tr('찾을 수 없습니다 (이미 지워졌거나 옮겨졌습니다)'),
      0x05 || 0x78 => tr('권한이 없습니다'),
      0x20 || 0x21 => tr('다른 프로그램이 쓰고 있습니다'),
      0x7C || 0x79 || 0x81 || 0xCE || 0x6F => tr('경로가 너무 깁니다 (Windows 의 휴지통은 260자 넘는 경로를 받지 않습니다) - 영구 삭제로 지울 수 있습니다'),
      0x74 => tr('드라이브의 맨 위 폴더는 지울 수 없습니다'),
      0x75 || 0x4C7 => tr('취소했습니다'),
      0x82 || 0x83 || 0x84 || 0x85 || 0x86 || 0x87 || 0x88 => tr('읽기 전용 매체입니다'),
      _ => trf('Windows 오류 0x{0}', [code.toRadixString(16)]),
    };

/// Windows 휴지통으로 보내기 (SHFileOperationW, FO_DELETE + FOF_ALLOWUNDO). 65: 탐색기의 기본 지우기.
/// 하나씩 보내 어느 것이 실패했는지 알 수 있게 한다. 실패하면 [FileSystemException] (이유는 읽을 수 있는 말).
/// 휴지통보다 커서 들어가지 않으면 Windows 가 묻게 하고 (FOF_WANTNUKEWARNING), 실제로 어떻게 됐는지 돌려준다 (94).
RecycleResult moveToRecycleBin(String path) {
  if (!Platform.isWindows) throw FileSystemException(tr('휴지통이 없습니다'), path);
  if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound) return RecycleResult.recycled;
  // 휴지통은 260자 넘는 경로를 받지 않고, 그때 Windows 는 묻지 않고 영구 삭제해 버린다 (시험에서 확인).
  // 그래서 보내기 전에 (폴더면 안의 것까지) 긴 경로가 있으면 지우지 않고 이유를 알린다 - 영구 삭제는 사용자가 따로 고른다.
  final long = longPathInside(path);
  if (long != null) throw FileSystemException(recycleErrorText(0x7C), long);
  final shell32 = DynamicLibrary.open('shell32.dll');
  final op = shell32.lookupFunction<Int32 Function(Pointer<_ShFileOp>), int Function(Pointer<_ShFileOp>)>('SHFileOperationW');
  final before = _binCount(path);
  final full = File(path).absolute.path;
  final started = DateTime.now().subtract(const Duration(seconds: 2));
  // pFrom: 끝에 NUL 두 개 (여러 경로 목록 형식)
  final units = [...File(path).absolute.path.codeUnits, 0, 0];
  final from = calloc<Uint16>(units.length);
  final s = calloc<_ShFileOp>();
  try {
    from.asTypedList(units.length).setAll(0, units);
    s.ref
      // 108: Windows 가 묻는 창 ("영구히 삭제할까요?") 이 앱 창 뒤에 숨지 않게 앱 창을 주인으로
      ..hwnd = _ownWindow()
      ..wFunc = 0x0003 // FO_DELETE
      ..pFrom = from
      ..pTo = nullptr
      // FOF_SILENT | FOF_NOCONFIRMATION | FOF_ALLOWUNDO | FOF_NOERRORUI | FOF_WANTNUKEWARNING
      // (휴지통에 못 넣는 것은 묻지 않고 지우지 않게: Windows 가 "영구히 삭제할까요?" 를 묻는다)
      ..fFlags = 0x0004 | 0x0010 | 0x0040 | 0x0400 | 0x4000
      ..fAnyOperationsAborted = 0
      ..hNameMappings = nullptr
      ..lpszProgressTitle = nullptr;
    final r = op(s);
    if (s.ref.fAnyOperationsAborted != 0 || r == 0x4C7) return RecycleResult.cancelled;
    if (r != 0) throw FileSystemException(recycleErrorText(r), path);
    if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound) {
      return RecycleResult.cancelled;
    }
    // 휴지통 안에 이 파일의 정보 ($I…, 원래 경로가 적힘) 가 새로 생겼는지로 본다 (늦게 생길 수 있어 몇 번 다시 본다).
    // 휴지통 폴더를 읽을 수 없으면 항목 수가 늘었는지로.
    for (var k = 0; k < 5; k++) {
      final found = recycledInfoExists(full, since: started);
      if (found == true) return RecycleResult.recycled;
      if (found == null) {
        if (before == null) return RecycleResult.recycled;
        final after = _binCount(path);
        if (after == null || after > before) return RecycleResult.recycled;
      }
      sleep(const Duration(milliseconds: 100));
    }
    return RecycleResult.deletedPermanently;
  } finally {
    calloc.free(from);
    calloc.free(s);
  }
}

/// 이 앱의 앞 창 (지금 앞에 있는 창이 이 프로세스의 것이면). 아니면 없음
Pointer<Void> _ownWindow() {
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    final fg = user32.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('GetForegroundWindow')();
    if (fg == nullptr) return nullptr;
    final pidOf = user32.lookupFunction<Uint32 Function(Pointer<Void>, Pointer<Uint32>), int Function(Pointer<Void>, Pointer<Uint32>)>(
        'GetWindowThreadProcessId');
    final owner = calloc<Uint32>();
    try {
      pidOf(fg, owner);
      return owner.value == pid ? fg : nullptr;
    } finally {
      calloc.free(owner);
    }
  } catch (_) {
    return nullptr;
  }
}

final class _ShFileOp extends Struct {
  external Pointer<Void> hwnd;
  @Uint32()
  external int wFunc;
  external Pointer<Uint16> pFrom;
  external Pointer<Uint16> pTo;
  @Uint16()
  external int fFlags;
  @Int32()
  external int fAnyOperationsAborted;
  external Pointer<Void> hNameMappings;
  external Pointer<Uint16> lpszProgressTitle;
}

/// SHQUERYRBINFO
final class _RbInfo extends Struct {
  @Uint32()
  external int cbSize;
  @Int64()
  external int size;
  @Int64()
  external int numItems;
}
