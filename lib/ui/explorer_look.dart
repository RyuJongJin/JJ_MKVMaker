import 'package:flutter/material.dart';

import '../core/file_ops.dart';
import '../core/playlist.dart' show isVideoFile;
import '../l10n/tr.dart';
import 'theme.dart';

/// 파일 탐색기 모양 (환경 설정 > 파일 탐색기 > 스타일)
///
/// - X-plore: 큰 아이콘 · 동영상 썸네일 · 두 줄 (이름 / 크기 · 날짜 · 해상도 · 길이)
/// - Windows 탐색기: 작은 컬러 아이콘 · 한 줄 · 열 (이름 · 수정한 날짜 · 유형 · 크기)
/// - Total Commander: 아주 작은 아이콘 · 촘촘한 한 줄 · 폴더는 [이름] · 열 (이름 · 확장자 · 크기 · 날짜), 크기 칸의 `<DIR>`
enum ExplorerStyle {
  xplore('X-plore'),
  windows('Windows 탐색기'),
  totalcmd('Total Commander');

  final String label;
  const ExplorerStyle(this.label);

  static ExplorerStyle of(String name) => values.firstWhere((s) => s.name == name, orElse: () => xplore);

  double get rowHeight => switch (this) { xplore => 52, windows => 34, totalcmd => 26 };
  double get iconSize => switch (this) { xplore => 30, windows => 20, totalcmd => 16 };
  double get indent => switch (this) { xplore => 16, windows => 14, totalcmd => 12 };
  double get fontSize => switch (this) { xplore => 14, windows => 13, totalcmd => 12.5 };

  /// 썸네일 · 두 줄 정보 (X-plore 만)
  bool get rich => this == xplore;

  /// 열 머리 (이름 · 날짜 · 유형 · 크기)
  bool get columns => this != xplore;
}

const _images = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'};
const _audio = {'mp3', 'm4a', 'flac', 'wav', 'ogg', 'aac', 'opus', 'wma'};
const _subs = {'srt', 'ass', 'ssa', 'smi', 'sami', 'vtt'};
const _archives = {'zip', '7z', 'rar', 'tar', 'gz', 'xz', 'bz2'};
const _texts = {'txt', 'log', 'md', 'json', 'xml', 'ini', 'csv', 'yaml', 'yml'};
const _docs = {'doc', 'docx', 'hwp', 'hwpx', 'odt', 'rtf'};
const _sheets = {'xls', 'xlsx', 'ods'};
const _slides = {'ppt', 'pptx', 'odp'};
const _programs = {'exe', 'msi', 'bat', 'cmd', 'ps1', 'apk'};

/// 파일 종류별 아이콘 · 색 (스타일마다 다르게)
(IconData, Color) fileIcon(ExplorerStyle style, FileEntry e, {bool open = false}) {
  final x = e.ext;
  switch (style) {
    case ExplorerStyle.xplore:
      if (e.isDir) return (open ? Icons.folder_open : Icons.folder, Colors.amber);
      return (
        switch (x) {
          _ when _subs.contains(x) => Icons.subtitles_outlined,
          _ when _audio.contains(x) => Icons.audiotrack_outlined,
          'pdf' => Icons.picture_as_pdf_outlined,
          _ when _archives.contains(x) => Icons.folder_zip_outlined,
          'apk' => Icons.android,
          _ when _texts.contains(x) => Icons.description_outlined,
          _ when _images.contains(x) => Icons.image_outlined,
          _ when isVideoFile(e.path) => Icons.movie_outlined,
          _ => Icons.insert_drive_file_outlined,
        },
        JjColors.textDim
      );
    case ExplorerStyle.windows:
      // Windows 11 탐색기 느낌: 노란 폴더, 종류마다 색
      if (e.isDir) return (open ? Icons.folder_open : Icons.folder, const Color(0xFFFFC83D));
      if (isVideoFile(e.path)) return (Icons.video_file, const Color(0xFF5B9BD5));
      if (_images.contains(x)) return (Icons.image, const Color(0xFF3FB3A8));
      if (_audio.contains(x)) return (Icons.audio_file, const Color(0xFFB57EDC));
      if (_subs.contains(x)) return (Icons.closed_caption, const Color(0xFF9FA8DA));
      if (x == 'pdf') return (Icons.picture_as_pdf, const Color(0xFFE5534B));
      if (_archives.contains(x)) return (Icons.folder_zip, const Color(0xFFD8A657));
      if (_docs.contains(x)) return (Icons.article, const Color(0xFF4F8EDC));
      if (_sheets.contains(x)) return (Icons.table_chart, const Color(0xFF4CAF7A));
      if (_slides.contains(x)) return (Icons.slideshow, const Color(0xFFE8804F));
      if (_programs.contains(x)) return (x == 'apk' ? Icons.android : Icons.terminal, const Color(0xFF8BC34A));
      if (_texts.contains(x)) return (Icons.description, const Color(0xFFB0BEC5));
      return (Icons.insert_drive_file, const Color(0xFFB0BEC5));
    case ExplorerStyle.totalcmd:
      // Total Commander 느낌: 단순한 작은 아이콘, 폴더는 노랑, 실행 파일은 초록
      if (e.isDir) return (Icons.folder, const Color(0xFFE8C547));
      if (_programs.contains(x)) return (Icons.settings_applications, const Color(0xFF7CB342));
      if (isVideoFile(e.path)) return (Icons.movie, const Color(0xFF64B5F6));
      if (_images.contains(x)) return (Icons.image, const Color(0xFF64B5F6));
      if (_archives.contains(x)) return (Icons.inventory_2, const Color(0xFFBCAAA4));
      return (Icons.description, const Color(0xFFCFD8DC));
  }
}

/// Windows 탐색기의 "유형" 칸: "파일 폴더" · "MP4 파일"
String typeLabel(FileEntry e) => e.isDir
    ? tr('파일 폴더')
    : e.ext.isEmpty
        ? tr('파일')
        : trf('{0} 파일', [e.ext.toUpperCase()]);

/// Total Commander 의 이름 칸: 폴더는 [이름], 파일은 확장자를 뺀 이름 (확장자는 따로)
String totalCmdName(FileEntry e) {
  if (e.isDir) return '[${e.name}]';
  final n = e.name;
  final dot = n.lastIndexOf('.');
  return dot > 0 ? n.substring(0, dot) : n;
}

/// 열 머리 (Windows 탐색기 · Total Commander)
class ExplorerColumnsHeader extends StatelessWidget {
  final ExplorerStyle style;
  const ExplorerColumnsHeader({super.key, required this.style});

  @override
  Widget build(BuildContext context) {
    const st = TextStyle(fontSize: 11.5, color: JjColors.textDim);
    Widget cell(String t, int flex, {TextAlign align = TextAlign.start}) =>
        Expanded(flex: flex, child: Text(t, style: st, textAlign: align, maxLines: 1, overflow: TextOverflow.clip));
    return Container(
      height: 24,
      padding: const EdgeInsets.only(left: 10, right: 40),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: JjColors.border))),
      child: Row(
        children: style == ExplorerStyle.windows
            ? [
                cell(tr('이름'), 6),
                cell(tr('수정한 날짜'), 3),
                cell(tr('유형'), 2),
                cell(tr('크기'), 2, align: TextAlign.end),
              ]
            : [
                cell(tr('이름'), 6),
                cell(tr('확장자'), 1),
                cell(tr('크기'), 2, align: TextAlign.end),
                const SizedBox(width: 8),
                cell(tr('날짜'), 3),
              ],
      ),
    );
  }
}
