import 'package:archive/archive.dart';
import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../core/file_ops.dart' show formatSize;
import '../core/reader_sources.dart';
import '../core/vfs.dart';
import '../l10n/tr.dart';
import 'reader_page.dart';
import 'theme.dart';

/// ZIP · CBZ 목록: 안의 파일을 보고, 골라서 (또는 모두) 다른 곳으로 풀고, 그림이 있으면 만화처럼 본다.
/// [otherDir] 파일 탐색기의 다른 창 폴더 (풀 곳으로 먼저 보여 줌). 풀었으면 그 폴더를 돌려준다.
Future<String?> openZip(BuildContext context, AppController c, String path, {String? otherDir}) =>
    Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => ZipPage(c: c, path: path, otherDir: otherDir)));

/// ZIP 안 그림을 만화처럼 보기 (그림이 없으면 false)
Future<bool> openZipComic(BuildContext context, AppController c, String path) async {
  final temp = await c.services.storage.tempDirectory();
  final src = await ZipImagesSource.open(path, tempDir: temp, imageExts: c.settings.imageExts);
  if (src.length == 0) {
    await src.dispose();
    return false;
  }
  if (!context.mounted) return true;
  await openReader(context, c, src);
  return true;
}

class ZipPage extends StatefulWidget {
  final AppController c;
  final String path;
  final String? otherDir;
  const ZipPage({super.key, required this.c, required this.path, this.otherDir});

  @override
  State<ZipPage> createState() => _ZipPageState();
}

class _ZipPageState extends State<ZipPage> {
  AppController get c => widget.c;
  List<ArchiveFile>? _entries;
  Object? _error;
  final _marked = <String>{};
  (int, int)? _progress;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final temp = await c.services.storage.tempDirectory();
      final list = await zipEntries(widget.path, tempDir: temp);
      if (mounted) setState(() => _entries = list.where((f) => f.isFile).toList());
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  bool get _hasImages => _entries?.any((f) => c.settings.imageExts.contains(extOf(f.name))) ?? false;

  Future<void> _extract({required bool all}) async {
    final zipDir = vDirname(widget.path);
    final base = vBasename(widget.path).replaceAll(RegExp(r'\.[^.]+$'), '');
    final dest = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(all ? tr('모두 풀기') : trf('{0}개 풀기', [_marked.length])),
        children: [
          if (widget.otherDir != null)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, widget.otherDir),
              child: ListTile(
                leading: const Icon(Icons.vertical_split_outlined),
                title: Text(tr('다른 창 폴더로')),
                subtitle: Text(vDisplay(widget.otherDir!)),
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, vJoin(zipDir, base)),
            child: ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: Text(trf('ZIP 옆 새 폴더 "{0}" 로', [base])),
              subtitle: Text(vDisplay(zipDir)),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, zipDir),
            child: ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(tr('ZIP 이 있는 폴더로')),
              subtitle: Text(vDisplay(zipDir)),
            ),
          ),
        ],
      ),
    );
    if (dest == null || !mounted) return;
    setState(() => _progress = (0, 0));
    try {
      final temp = await c.services.storage.tempDirectory();
      final n = await extractZip(widget.path, dest,
          tempDir: temp,
          names: all ? const [] : _marked.toList(),
          onProgress: (d, t) {
            if (mounted) setState(() => _progress = (d, t));
          });
      if (!mounted) return;
      setState(() => _progress = null);
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(trf('{0}개를 풀었습니다: {1}', [n, vDisplay(dest)]))));
      Navigator.pop(context, dest);
    } catch (e) {
      if (!mounted) return;
      setState(() => _progress = null);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(trf('풀지 못했습니다: {0}', [e]))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(
        title: Text(vBasename(widget.path), overflow: TextOverflow.ellipsis),
        actions: [
          if (_hasImages)
            IconButton(
              tooltip: tr('만화 보기'),
              icon: const Icon(Icons.auto_stories_outlined),
              onPressed: () => openZipComic(context, c, widget.path),
            ),
          IconButton(
            tooltip: tr('고른 것 풀기'),
            icon: const Icon(Icons.unarchive_outlined),
            onPressed: _marked.isEmpty || _progress != null ? null : () => _extract(all: false),
          ),
          IconButton(
            tooltip: tr('모두 풀기'),
            icon: const Icon(Icons.folder_zip_outlined),
            onPressed: entries == null || entries.isEmpty || _progress != null ? null : () => _extract(all: true),
          ),
        ],
      ),
      body: Column(children: [
        if (_progress != null)
          LinearProgressIndicator(value: _progress!.$2 == 0 ? null : _progress!.$1 / _progress!.$2),
        Expanded(
          child: _error != null
              ? Center(child: Text(trf('열 수 없습니다: {0}', [_error])))
              : entries == null
                  ? const Center(child: CircularProgressIndicator())
                  : entries.isEmpty
                      ? Center(child: Text(tr('비어 있는 압축 파일입니다.')))
                      : ListView.builder(
                          itemCount: entries.length,
                          itemBuilder: (_, i) {
                            final f = entries[i];
                            final on = _marked.contains(f.name);
                            return CheckboxListTile(
                              dense: true,
                              value: on,
                              onChanged: (v) => setState(() => v == true ? _marked.add(f.name) : _marked.remove(f.name)),
                              secondary: Icon(
                                c.settings.imageExts.contains(extOf(f.name))
                                    ? Icons.image_outlined
                                    : Icons.insert_drive_file_outlined,
                                color: JjColors.textDim,
                              ),
                              title: Text(f.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                              subtitle: Text(formatSize(f.size)),
                            );
                          },
                        ),
        ),
      ]),
    );
  }
}
