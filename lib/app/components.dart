import 'package:flutter/material.dart';

/// 앱의 기능 묶음 (컴포넌트). 코드는 앱에 들어 있고, 환경 설정 > 컴포넌트에서 설치 (필요한 파일을 받아 켬) · 제거 (끔) 한다.
/// 화면이 있는 것 ([page]) 은 위쪽 이동 버튼 · 좌우로 밀기로 오간다 (순서는 [AppSettings.navOrder]).
class AppComponent {
  final String id;

  /// 화면 이름 (tr() 로 번역)
  final String name;
  final String description;
  final IconData icon;

  /// 위쪽 이동 버튼 · 좌우로 밀기로 오가는 화면
  final bool page;

  /// 설치할 때 받아야 하는 파일이 있음 (GitHub 릴리스의 components.json)
  final bool needsDownload;

  /// 처음 설치할 때부터 켜져 있음
  final bool builtIn;

  const AppComponent(this.id, this.name, this.description, this.icon,
      {this.page = true, this.needsDownload = false, this.builtIn = true});

  static const mkv = AppComponent('mkv', 'MKV 만들기', '동영상 + 자막을 MKV 로 합치기 · AI 자막 · 화면 보정', Icons.video_library_outlined);
  static const browser = AppComponent('browser', '웹 브라우저', '앱 안 웹 브라우저 · 즐겨찾기 · 동영상 다운로드', Icons.public);
  static const explorer = AppComponent('explorer', '파일 탐색기', '두 창 파일 탐색기 · 복사 · 이동 · WebDAV', Icons.folder_copy_outlined);
  static const rsync = AppComponent('rsync', 'Rsync', '좌우 두 폴더 맞추기 (rsync) · 모니터링 · 실시간 동기화 (lsync)', Icons.sync_alt);
  static const downloads = AppComponent('downloads', '다운로드', 'YouTube · 토렌트 다운로드 목록', Icons.download_for_offline_outlined);
  static const viewer = AppComponent('viewer', '이미지 · PDF · ZIP 보기', '그림 · 만화 보기, PDF 보기 · 페이지 편집, ZIP 목록 · 만화 보기',
      Icons.photo_library_outlined, page: false);
  static const docs = AppComponent('docs', '문서 미리보기', 'DOC · DOCX · HWP · XLS · XLSX 를 PDF 로 바꿔 보기 (변환기를 받음)',
      Icons.description_outlined, page: false, needsDownload: true, builtIn: false);

  static const all = [mkv, browser, explorer, rsync, downloads, viewer, docs];

  /// 문서 미리보기 대상 (PDF 로 바꿔 봄)
  static const docExtensions = ['doc', 'docx', 'hwp', 'hwpx', 'xls', 'xlsx', 'ppt', 'pptx', 'odt', 'ods', 'odp', 'rtf'];

  /// 화면 있는 것의 기본 순서 (좌우로 밀기 · 위쪽 버튼)
  static const defaultOrder = ['mkv', 'browser', 'explorer', 'rsync', 'downloads'];

  static AppComponent? byId(String id) => all.where((c) => c.id == id).firstOrNull;

  /// 처음 설치 때 켜진 것
  static List<String> get defaultInstalled => [for (final c in all) if (c.builtIn) c.id];

  /// 설치된 화면들을 [order] 순서로 (순서에 없는 것은 기본 순서대로 뒤에)
  static List<AppComponent> pages(List<String> installed, List<String> order) {
    final ids = [
      ...order.where(defaultOrder.contains),
      ...defaultOrder.where((x) => !order.contains(x)),
    ];
    return [for (final id in ids) if (installed.contains(id)) byId(id)!];
  }
}
