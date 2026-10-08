import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../platform/android/android_storage.dart';
import 'bookmark_ui.dart' show askText;
import 'theme.dart';
import '../l10n/tr.dart';

/// 마지막으로 본 폴더 (다음에 열 때 여기서)
String? _lastDir;

/// Android 앱 안 파일 고르기: 폴더를 오가며 [extensions] 파일을 여러 개 고른다. 고른 파일의 실제 경로를 돌려준다.
/// 내장 저장소와 SD 카드 · USB 메모리를 오갈 수 있다.
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

/// Android 앱 안 폴더 고르기 (저장 위치 등). 고른 폴더의 실제 경로, 취소하면 null.
Future<String?> showAndroidFolderBrowser(BuildContext context, {required String title, String? initialDirectory}) async {
  final r = await Navigator.of(context).push<List<String>>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => _FileBrowser(title: title, extensions: const [], initialDirectory: initialDirectory, folder: true),
  ));
  return r?.firstOrNull;
}

class _FileBrowser extends StatefulWidget {
  final String title;
  final List<String> extensions;
  final String? initialDirectory;

  /// 폴더 고르기 (파일은 보이지 않고 "이 폴더 선택")
  final bool folder;
  const _FileBrowser({required this.title, required this.extensions, this.initialDirectory, this.folder = false});

  @override
  State<_FileBrowser> createState() => _FileBrowserState();
}

class _FileBrowserState extends State<_FileBrowser> {
  /// (경로, 이름, 빼낼 수 있는지)
  List<(String, String, bool)> _volumes = [('/storage/emulated/0', tr('내장 저장소'), false)];
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

  /// 듀얼 앱 (복제한 앱): Android 가 "모든 파일 접근" 을 주지 않을 수 있어 안내를 따로
  bool _dual = false;

  Future<void> _start() async {
    _volumes = await AndroidAccess.volumes();
    final allowed = await AndroidAccess.hasAllFiles();
    try {
      final root = await AndroidAccess.storageRoot();
      _dual = root.contains('/emulated/') && !root.endsWith('/emulated/0');
    } catch (_) {}
    final first = [widget.initialDirectory, _lastDir, _volumes.first.$1].firstWhere(
        (d) => d != null && Directory(d).existsSync() && _volumeOf(d) != null,
        orElse: () => _volumes.first.$1)!;
    setState(() => _allowed = allowed);
    if (allowed) _open(first);
  }

  /// [dir] 이 들어 있는 저장소 (맨 위 폴더 · 이름)
  (String, String, bool)? _volumeOf(String dir) {
    for (final v in _volumes) {
      if (p.equals(v.$1, dir) || p.isWithin(v.$1, dir)) return v;
    }
    return null;
  }

  static String _volumeName((String, String, bool) v) => v.$3 ? (v.$2.isEmpty ? tr('SD 카드') : v.$2) : tr('내장 저장소');

  bool _match(String path) => widget.extensions.contains(p.extension(path).replaceFirst('.', '').toLowerCase());

  void _open(String dir) {
    final dirs = <Directory>[];
    final files = <File>[];
    try {
      for (final e in Directory(dir).listSync(followLinks: false)) {
        final name = p.basename(e.path);
        if (name.startsWith('.')) continue;
        if (e is Directory) dirs.add(e);
        if (!widget.folder && e is File && _match(e.path)) files.add(e);
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

  /// 폴더 만들기: 이름을 물어 [parent] 아래에 만들고 그 폴더로 들어간다
  Future<void> _makeFolder(String parent) async {
    final name = (await askText(context, tr('폴더 만들기'), tr('폴더 이름'), tr('새 폴더'),
            help: trf('{0} 아래에 만듭니다', [parent])))
        ?.trim();
    if (name == null || name.isEmpty || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (RegExp(r'[\\/:*?"<>|]').hasMatch(name) || name == '.' || name == '..') {
      messenger.showSnackBar(SnackBar(content: Text(tr('폴더 이름에 쓸 수 없는 글자가 있습니다 (\\ / : * ? " < > |)'))));
      return;
    }
    final path = p.join(parent, name);
    try {
      if (Directory(path).existsSync()) {
        messenger.showSnackBar(SnackBar(content: Text(trf('이미 있는 폴더입니다: {0}', [name]))));
      } else {
        Directory(path).createSync();
      }
      _open(path);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(trf('폴더를 만들 수 없습니다: {0}', [e]))));
    }
  }

  static String _size(int b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)}GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)}MB';
    return '${(b / 1024).ceil()}KB';
  }

  @override
  Widget build(BuildContext context) {
    final dir = _dir;
    final vol = dir == null ? null : _volumeOf(dir);
    final root = vol?.$1;
    final atRoot = dir == null || root == null || p.equals(dir, root);
    final internal = _volumes.first.$1;
    return PopScope(
      canPop: atRoot,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && dir != null) _open(p.dirname(dir));
      },
      child: Scaffold(
        appBar: AppBar(
          // 닫기: 어느 폴더에 있든 바로 닫는다 (뒤로 가기 키는 위 폴더로)
          leading: IconButton(
            tooltip: tr('닫기'),
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(widget.title),
          actions: [
            if (widget.folder) ...[
              // 지금 보고 있는 폴더 아래에 새 폴더 (만든 뒤 그 폴더로 들어간다)
              OutlinedButton.icon(
                onPressed: dir == null ? null : () => _makeFolder(dir),
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                label: Text(tr('폴더 만들기')),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilledButton.icon(
                  onPressed: dir == null ? null : () => Navigator.pop(context, [dir]),
                  icon: const Icon(Icons.check, size: 18),
                  label: Text(tr('이 폴더 선택')),
                ),
              ),
            ] else ...[
              if (_files.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() {
                    final all = _files.every((f) => _picked.contains(f.path));
                    for (final f in _files) {
                      all ? _picked.remove(f.path) : _picked.add(f.path);
                    }
                  }),
                  child: Text(tr('이 폴더 전체')),
                ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilledButton(
                  onPressed: _picked.isEmpty ? null : () => Navigator.pop(context, _picked.toList()),
                  child: Text(trf('추가 ({0})', [_picked.length])),
                ),
              ),
            ],
          ],
        ),
        body: switch (_allowed) {
          null => const Center(child: CircularProgressIndicator()),
          false => _permission(),
          true => Column(children: [
              // 바로 가기: 저장소 (내장 · SD 카드 · USB) → 내장 저장소의 자주 쓰는 폴더
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
                child: Row(children: [
                  for (final v in _volumes)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ActionChip(
                        avatar: Icon(v.$3 ? Icons.sd_card_outlined : Icons.phone_android, size: 18),
                        label: Text(_volumeName(v)),
                        onPressed: () => _open(v.$1),
                      ),
                    ),
                  for (final (label, sub) in [
                    ('Download', 'Download'),
                    ('Movies', 'Movies'),
                    ('DCIM', 'DCIM'),
                  ])
                    if (Directory(p.join(internal, sub)).existsSync())
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ActionChip(label: Text(label), onPressed: () => _open(p.join(internal, sub))),
                      ),
                ]),
              ),
              ListTile(
                dense: true,
                leading: IconButton(
                  tooltip: tr('위 폴더'),
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: atRoot ? null : () => _open(p.dirname(dir)),
                ),
                title: Text(
                  dir == null || vol == null
                      ? ''
                      : (atRoot ? _volumeName(vol) : '${_volumeName(vol)} / ${p.relative(dir, from: root)}'),
                  style: const TextStyle(color: JjColors.textDim),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _dirs.isEmpty && _files.isEmpty
                    ? Center(
                        child: Text(widget.folder ? tr('하위 폴더가 없습니다') : tr('이 폴더에는 고를 파일이 없습니다'),
                            style: const TextStyle(color: JjColors.textDim)))
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
            Text(
              tr('동영상을 고르고, 동영상 옆 jj_mkv 폴더에 MKV 를 만들려면\n"모든 파일에 대한 접근" 권한이 필요합니다.'),
              textAlign: TextAlign.center,
            ),
            if (_dual) ...[
              const SizedBox(height: 12),
              Text(
                tr('지금은 듀얼 앱 (복제한 앱) 입니다. Android 가 듀얼 앱에는 이 권한을 주지 않을 수 있습니다. '
                    '허용 화면에서 켤 수 없으면 배지 없는 원래 JJ_MKVMaker 아이콘으로 여세요.'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: JjColors.textDim),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(onPressed: AndroidAccess.request, child: Text(tr('권한 허용 화면 열기'))),
            const SizedBox(height: 8),
            TextButton(onPressed: _start, child: Text(tr('허용했으면 다시 확인'))),
          ]),
        ),
      );
}
