import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

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
  final shell32 = DynamicLibrary.open('shell32.dll');
  final op = shell32.lookupFunction<Int32 Function(Pointer<_ShFileOp>), int Function(Pointer<_ShFileOp>)>('SHFileOperationW');
  final before = _binCount(path);
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
    // 휴지통 항목 수가 늘었는지로 실제로 들어갔는지 본다 (수가 늦게 바뀔 수 있어 몇 번 다시 본다)
    if (before == null) return RecycleResult.recycled;
    for (var k = 0; k < 5; k++) {
      final after = _binCount(path);
      if (after == null || after > before) return RecycleResult.recycled;
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
