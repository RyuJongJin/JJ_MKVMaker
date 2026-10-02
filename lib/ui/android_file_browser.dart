import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../platform/android/android_storage.dart';
import 'theme.dart';

/// 마지막으로 본 폴더 (다음에 열 때 여기서)
String? _lastDir;

/// Android 앱 안 파일 고르기: 폴더를 오가며 [extensions] 파일을 여러 개 고른다. 고른 파일의 실제 경로를 돌려준다.
Future<List<String>?> showAndroidFileBrowser(
  BuildContext context, {
  required String title,
  required List<String> extensions,
  String? initialDirectory,
}) =>
    Navigator.of(context).push<List<String>>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _FileBrowser(title: title, extensions: extensions, initialDirectory: initialDirectory),
    ));

class _FileBrowser extends StatefulWidget {
  final String title;
  final List<String> extensions;
  final String? initialDirectory;
  const _FileBrowser({required this.title, required this.extensions, this.initialDirectory});

  @override
  State<_FileBrowser> createState() => _FileBrowserState();
}

class _FileBrowserState extends State<_FileBrowser> {
  String _root = '/storage/emulated/0';
  String? _dir;
  bool? _allowed;
  List<Directory> _dirs = [];
  List<File> _files = [];
  final _picked = <String>{};

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    _root = await AndroidAccess.storageRoot();
    final allowed = await AndroidAccess.hasAllFiles();
    final first = [widget.initialDirectory, _lastDir, _root].firstWhere(
        (d) => d != null && Directory(d).existsSync(),
        orElse: () => _root)!;
    setState(() => _allowed = allowed);
    if (allowed) _open(first);
  }

  bool _match(String path) => widget.extensions.contains(p.extension(path).replaceFirst('.', '').toLowerCase());

  void _open(String dir) {
    final dirs = <Directory>[];
    final files = <File>[];
    try {
      for (final e in Directory(dir).listSync(followLinks: false)) {
        final name = p.basename(e.path);
        if (name.startsWith('.')) continue;
        if (e is Directory) dirs.add(e);
        if (e is File && _match(e.path)) files.add(e);
      }
    } catch (_) {}
    int byName(FileSystemEntity a, FileSystemEntity b) =>
        p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase());
    dirs.sort(byName);
    files.sort(byName);
    setState(() {
      _dir = _lastDir = dir;
      _dirs = dirs;
      _files = files;
    });
  }

  static String _size(int b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)}GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)}MB';
    return '${(b / 1024).ceil()}KB';
  }

  @override
  Widget build(BuildContext context) {
    final dir = _dir;
    final atRoot = dir == null || p.equals(dir, _root) || !p.isWithin(_root, dir);
    return PopScope(
      canPop: atRoot,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && dir != null) _open(p.dirname(dir));
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          actions: [
            if (_files.isNotEmpty)
              TextButton(
                onPressed: () => setState(() {
                  final all = _files.every((f) => _picked.contains(f.path));
                  for (final f in _files) {
                    all ? _picked.remove(f.path) : _picked.add(f.path);
                  }
                }),
                child: const Text('이 폴더 전체'),
              ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(
                onPressed: _picked.isEmpty ? null : () => Navigator.pop(context, _picked.toList()),
                child: Text('추가 (${_picked.length})'),
              ),
            ),
          ],
        ),
        body: switch (_allowed) {
          null => const Center(child: CircularProgressIndicator()),
          false => _permission(),
          true => Column(children: [
              // 바로 가기 · 지금 폴더
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
                child: Row(children: [
                  for (final (label, sub) in [
                    ('내장 저장소', ''),
                    ('Download', 'Download'),
                    ('Movies', 'Movies'),
                    ('DCIM', 'DCIM'),
                    ('jj_mkv', 'Movies/jj_mkv'),
                  ])
                    if (Directory(p.join(_root, sub)).existsSync())
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ActionChip(label: Text(label), onPressed: () => _open(p.join(_root, sub))),
                      ),
                ]),
              ),
              ListTile(
                dense: true,
                leading: IconButton(
                  tooltip: '위 폴더',
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: atRoot ? null : () => _open(p.dirname(dir)),
                ),
                title: Text(
                  dir == null ? '' : (p.equals(dir, _root) ? '내장 저장소' : p.relative(dir, from: _root)),
                  style: const TextStyle(color: JjColors.textDim),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _dirs.isEmpty && _files.isEmpty
                    ? const Center(child: Text('이 폴더에는 고를 파일이 없습니다', style: TextStyle(color: JjColors.textDim)))
                    : ListView(children: [
                        for (final d in _dirs)
                          ListTile(
                            leading: const Icon(Icons.folder, color: Colors.amber),
                            title: Text(p.basename(d.path)),
                            onTap: () => _open(d.path),
                          ),
                        for (final f in _files)
                          CheckboxListTile(
                            value: _picked.contains(f.path),
                            onChanged: (v) => setState(() => v! ? _picked.add(f.path) : _picked.remove(f.path)),
                            secondary: const Icon(Icons.movie_outlined),
                            title: Text(p.basename(f.path)),
                            subtitle: Text(_sizeOf(f)),
                          ),
                      ]),
              ),
            ]),
        },
      ),
    );
  }

  String _sizeOf(File f) {
    try {
      return _size(f.lengthSync());
    } catch (_) {
      return '';
    }
  }

  Widget _permission() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.folder_off_outlined, size: 48),
            const SizedBox(height: 12),
            const Text(
              '동영상을 고르고, 동영상 옆 jj_mkv 폴더에 MKV 를 만들려면\n"모든 파일에 대한 접근" 권한이 필요합니다.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: AndroidAccess.request, child: const Text('권한 허용 화면 열기')),
            const SizedBox(height: 8),
            TextButton(onPressed: _start, child: const Text('허용했으면 다시 확인')),
          ]),
        ),
      );
}
