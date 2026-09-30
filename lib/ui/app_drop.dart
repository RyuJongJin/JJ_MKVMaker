import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../core/playlist.dart';
import 'theme.dart';

/// 끌어다 놓은 파일 · 폴더에서 동영상을 골라 MKV 만들기의 동영상 목록에 넣는다.
/// 직접 놓은 동영상 파일은 jj_mkv 폴더 안에 있어도 넣고, 폴더째 놓으면 그 안의 jj_ 출력 폴더는 건너뛴다.
/// 돌려주는 값: (새로 넣은 개수, 찾은 동영상 개수)
Future<(int, int)> addDroppedVideos(AppController c, List<String> paths) async {
  final direct = [
    for (final path in paths)
      if (isVideoFile(path) && !await FileSystemEntity.isDirectory(path)) path,
  ];
  final found = await collectVideos(paths,
      isDirectory: (x) => FileSystemEntity.isDirectory(x),
      listDir: (x) async => Directory(x).list().map((e) => e.path).toList());
  final all = {...direct, ...found}.toList();
  final before = c.videos.length;
  await c.addVideos(direct, allowOutputFolder: true);
  await c.addVideos(found);
  final added = c.videos.skip(before).toList();
  if (added.isNotEmpty) c.select(added.first);
  return (added.length, all.length);
}

/// 앱 전체를 감싸는 끌어다 놓기 영역: 어느 화면에서 놓아도 MKV 만들기의 동영상 목록에 추가한다.
/// 끌고 들어오면 화면에 안내를 띄우고, 놓으면 결과를 알려 준다.
class AppDropArea extends StatefulWidget {
  final AppController c;
  final Widget child;
  const AppDropArea({super.key, required this.c, required this.child});

  @override
  State<AppDropArea> createState() => _AppDropAreaState();
}

class _AppDropAreaState extends State<AppDropArea> {
  bool _over = false;

  Future<void> _dropped(List<String> paths) async {
    setState(() => _over = false);
    final m = ScaffoldMessenger.maybeOf(context);
    final (added, found) = await addDroppedVideos(widget.c, paths);
    m?.clearSnackBars();
    m?.showSnackBar(SnackBar(
        content: Text(found == 0
            ? '끌어다 놓은 항목에 동영상이 없습니다.'
            : added == 0
                ? '이미 동영상 목록에 있습니다 ($found개).'
                : 'MKV 만들기의 동영상 목록에 $added개를 추가했습니다.'
                    '${added < found ? ' (${found - added}개는 이미 있음)' : ''}')));
  }

  @override
  Widget build(BuildContext context) => DropTarget(
        onDragEntered: (_) => setState(() => _over = true),
        onDragExited: (_) => setState(() => _over = false),
        onDragDone: (d) => _dropped(d.files.map((f) => f.path).toList()),
        child: Stack(children: [
          widget.child,
          if (_over)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: JjColors.accent.withValues(alpha: 0.12),
                    border: Border.all(color: JjColors.accent, width: 3),
                  ),
                  alignment: Alignment.center,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                    decoration: BoxDecoration(color: JjColors.panel, borderRadius: BorderRadius.circular(10)),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.playlist_add, color: JjColors.accent),
                      SizedBox(width: 10),
                      Text('여기에 놓으면 MKV 만들기의 동영상 목록에 추가합니다',
                          style: TextStyle(fontSize: 15, color: JjColors.text, decoration: TextDecoration.none)),
                    ]),
                  ),
                ),
              ),
            ),
        ]),
      );
}
