import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/secret_gate.dart';
import '../core/vfs.dart';
import '../core/webdav.dart';
import '../l10n/tr.dart';
import 'android_file_browser.dart';
import 'file_error.dart';

/// 폴더 고르기. Android 는 앱 안 화면 (내장 저장소 · SD 카드 · USB 를 실제 경로로 고를 수 있음), PC 는 Windows 폴더 선택 창
Future<String?> pickFolder(BuildContext context, String title, [String? initial]) => Platform.isAndroid
    ? showAndroidFolderBrowser(context, title: title, initialDirectory: initial)
    : FilePicker.getDirectoryPath(dialogTitle: title, initialDirectory: initial);

/// 124: 이 기기 폴더 또는 WebDAV 서버의 폴더 고르기 (서버가 없으면 바로 이 기기 폴더).
/// 환경 설정에서 추가한 서버가 실시간 동기화 · 모니터링의 고르는 곳에도 바로 보이게.
Future<String?> pickFolderOrDav(BuildContext context, String title, [String? initial]) async {
  final servers = DavRegistry.servers;
  if (servers.isEmpty) return pickFolder(context, title, initial);
  final where = await showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text(title),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, ''),
          child: ListTile(leading: const Icon(Icons.folder_outlined), title: Text(tr('이 기기의 폴더'))),
        ),
        for (final s in servers)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, s.id),
            child: ListTile(leading: const Icon(Icons.cloud_outlined), title: Text(s.label), subtitle: Text(s.url)),
          ),
      ],
    ),
  );
  if (where == null || !context.mounted) return null;
  if (where.isEmpty) return pickFolder(context, title, initial != null && !isDav(initial) ? initial : null);
  final start = initial != null && isDav(initial) && DavPath.parse(initial).server == where ? initial : '$davScheme$where/';
  return showDialog<String>(context: context, builder: (_) => _DavFolderDialog(title: title, start: start));
}

/// WebDAV 서버 안의 폴더를 들어가며 고른다
class _DavFolderDialog extends StatefulWidget {
  const _DavFolderDialog({required this.title, required this.start});
  final String title;
  final String start;

  @override
  State<_DavFolderDialog> createState() => _DavFolderDialogState();
}

class _DavFolderDialogState extends State<_DavFolderDialog> {
  late String _dir = widget.start;
  List<String>? _folders;
  String? _error;

  @override
  void initState() {
    super.initState();
    _open(_dir);
  }

  Future<void> _open(String dir) async {
    setState(() {
      _dir = dir;
      _folders = null;
      _error = null;
    });
    try {
      final list = await vList(dir, strict: true);
      final names = [for (final e in list) if (e.isDir) e.path]..sort((a, b) => vBasename(a).toLowerCase().compareTo(vBasename(b).toLowerCase()));
      if (mounted && _dir == dir) setState(() => _folders = names);
    } catch (e) {
      if (mounted && _dir == dir) setState(() => _error = '$e');
    }
  }

  /// 134: 원문 예외 대신 알아볼 수 있는 말 + 할 일. 133: 마스터 때문에 막혔으면 [마스터 비밀번호 넣기]
  Widget _errorView(String error) {
    final (title, body) = explainFileError(error, dav: true);
    final locked = isLockedError(error);
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(locked ? Icons.lock_outline : Icons.cloud_off_outlined, color: Colors.redAccent),
        const SizedBox(height: 8),
        Text(title, textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w600)),
        if (body.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(body, textAlign: TextAlign.center)),
        const SizedBox(height: 10),
        FilledButton.tonal(
          onPressed: () async {
            if (locked && !await SecretGate.pass(force: true)) return;
            await _open(_dir);
          },
          child: Text(locked ? tr('마스터 비밀번호 넣기') : tr('다시 시도')),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final atRoot = DavPath.parse(_dir).rel.replaceAll('/', '').isEmpty;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 460,
        height: 380,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(vDisplay(_dir) + DavPath.parse(_dir).rel, maxLines: 2, overflow: TextOverflow.ellipsis),
          const Divider(),
          Expanded(
            child: _error != null
                ? _errorView(_error!)
                : _folders == null
                    ? const Center(child: CircularProgressIndicator())
                    : ListView(children: [
                        if (!atRoot)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.arrow_upward),
                            title: const Text('..'),
                            onTap: () => _open(vDirname(_dir)),
                          ),
                        for (final f in _folders!)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(vBasename(f)),
                            onTap: () => _open(f),
                          ),
                      ]),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('취소'))),
        FilledButton(onPressed: _error != null ? null : () => Navigator.pop(context, _dir), child: Text(tr('이 폴더 고르기'))),
      ],
    );
  }
}
