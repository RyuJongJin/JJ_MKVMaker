// l10n-skip-file: README.txt 의 영어 · 한국어 글 (화면 언어와 상관없이 둘 다 쓴다)
import 'dart:io';

import 'package:path/path.dart' as p;

/// Download 아래에 만드는 한국어 이름 폴더 ("설정 보관" · "AI 모델 보관") 를 한국어를 모르는 사용자도 알아보게
/// 그 폴더 안에 README.txt (영어 · 한국어). 이미 있으면 그대로. 실패해도 보관에는 영향 없음.
/// 작은 파일이라 바로 쓴다 (보관 흐름에 기다릴 단계를 더하지 않게).
void writeFolderReadme(String dir, String text) {
  try {
    final f = File(p.join(dir, 'README.txt'));
    if (f.existsSync()) return;
    Directory(dir).createSync(recursive: true);
    f.writeAsStringSync('$text\r\n');
  } catch (_) {}
}

const settingsBackupReadme = 'JJ_MKVMaker settings backup / 설정 보관\r\n'
    'Settings kept for each app version (one folder per version), used when going back to that version.\r\n'
    '앱 버전마다 보관한 설정입니다 (버전마다 폴더 하나). 그 버전으로 되돌릴 때 씁니다.';

const modelBackupReadme = 'JJ_MKVMaker AI model backup / AI 모델 보관\r\n'
    'AI models copied aside before going back to an older version, so they do not have to be downloaded again.\r\n'
    '예전 버전으로 되돌리기 전에 옮겨 둔 AI 모델입니다. 다시 받지 않아도 되게 되살립니다.';
