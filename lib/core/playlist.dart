import 'package:path/path.dart' as p;

import 'output_paths.dart';
import 'subtitle_detector.dart';
import '../l10n/tr.dart';

/// 동영상 하나를 재생할 때 재생 목록 만드는 방법
enum PlaylistMode {
  single('그 파일 하나만'),
  series('같은 시리즈 (번호만 다른 파일)'),
  folder('같은 폴더의 모든 동영상');

  /// 한국어 원문 (번역 사전의 열쇠)
  final String koLabel;

  /// 화면에 보일 이름 (화면 언어로)
  String get label => tr(koLabel);
  const PlaylistMode(this.koLabel);
}

bool isVideoFile(String path) =>
    videoExtensions.contains(p.extension(path).replaceFirst('.', '').toLowerCase());

bool isAudioFile(String path) =>
    audioExtensions.contains(p.extension(path).replaceFirst('.', '').toLowerCase());

/// 시리즈 비교용 이름: 숫자를 모두 # 으로 바꾼다.
/// file_001 ≡ file_0002,  Show.S01E02 ≡ Show.S02E10,  드라마 3화 ≡ 드라마 12화
String seriesKey(String path) => p
    .basenameWithoutExtension(path)
    .toLowerCase()
    .replaceAll(RegExp(r'\d+'), '#')
    .replaceAll(RegExp(r'[\s._\-]+'), ' ')
    .trim();

/// 사람이 읽는 순서 (file2 < file10)
int naturalCompare(String a, String b) {
  final re = RegExp(r'(\d+)|(\D+)');
  final ma = re.allMatches(a.toLowerCase()).toList();
  final mb = re.allMatches(b.toLowerCase()).toList();
  for (var i = 0; i < ma.length && i < mb.length; i++) {
    final x = ma[i], y = mb[i];
    if (x[1] != null && y[1] != null) {
      final c = BigInt.parse(x[1]!).compareTo(BigInt.parse(y[1]!));
      if (c != 0) return c;
      final l = x[1]!.length.compareTo(y[1]!.length); // 0010 과 10
      if (l != 0) return l;
    } else {
      final c = x[0]!.compareTo(y[0]!);
      if (c != 0) return c;
    }
  }
  return ma.length.compareTo(mb.length);
}

/// 파일 하나 → 재생 목록 (선택한 파일이 들어 있고, 이름 순)
/// 돌려주는 값: (목록, 선택한 파일의 위치)
(List<String>, int) buildPlaylist(String file, Iterable<String> filesInFolder, PlaylistMode mode) {
  if (mode == PlaylistMode.single) return ([file], 0);
  final key = seriesKey(file);
  final list = filesInFolder
      .where(isVideoFile)
      .where((f) => mode == PlaylistMode.folder || seriesKey(f) == key)
      .toList();
  if (!list.any((f) => p.equals(f, file))) list.add(file);
  list.sort((a, b) => naturalCompare(p.basename(a), p.basename(b)));
  return (list, list.indexWhere((f) => p.equals(f, file)));
}

/// 끌어다 놓은 파일·폴더 목록에서 동영상만 (폴더는 안쪽까지, jj_ 출력 폴더 제외)
/// [listDir] 은 폴더 안 항목 (파일, 하위 폴더) 을 돌려준다.
Future<List<String>> collectVideos(
  Iterable<String> paths, {
  required Future<bool> Function(String) isDirectory,
  required Future<List<String>> Function(String) listDir,
}) async {
  final out = <String>[];
  Future<void> walk(String path, int depth) async {
    if (await isDirectory(path)) {
      final name = p.basename(path).toLowerCase();
      if (depth > 0 && (name.startsWith('jj_') || name == outputFolderName)) return;
      if (depth > 5) return;
      final children = await listDir(path)..sort((a, b) => naturalCompare(a, b));
      for (final c in children) {
        await walk(c, depth + 1);
      }
    } else if (isVideoFile(path)) {
      out.add(path);
    }
  }

  for (final x in paths) {
    await walk(x, 0);
  }
  return out;
}

/// 실행 인수 (탐색기 오른쪽 메뉴)
///   --play 파일...      → 플레이어로 재생
///   --subtitle 파일...  → 목록에 추가하고 AI 자막 만들기
///   파일...             → 목록에 추가
class LaunchRequest {
  final LaunchAction action;
  final List<String> files;
  const LaunchRequest(this.action, this.files);

  static LaunchRequest parse(List<String> args) {
    var action = LaunchAction.add;
    final files = <String>[];
    for (final a in args) {
      switch (a) {
        case '--play':
          action = LaunchAction.play;
        case '--subtitle':
          action = LaunchAction.subtitle;
        case '--lsync':
          action = LaunchAction.lsync;
        default:
          // 99: 알림을 누르면 jjmkvmaker://lsync 로 열린다 (실시간 동기화 화면으로)
          if (a.toLowerCase().startsWith('jjmkvmaker://')) {
            if (a.toLowerCase().startsWith('jjmkvmaker://lsync')) action = LaunchAction.lsync;
          } else if (!a.startsWith('--')) {
            files.add(a);
          }
      }
    }
    return LaunchRequest(action, files);
  }

  List<String> toArgs() => [
        if (action == LaunchAction.play) '--play',
        if (action == LaunchAction.subtitle) '--subtitle',
        if (action == LaunchAction.lsync) '--lsync',
        ...files,
      ];
}

/// [lsync]: 실시간 동기화 화면 (모니터링) 을 연다 (동기화가 멈췄다는 알림을 누름 - 99)
enum LaunchAction { add, play, subtitle, lsync }
