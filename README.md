<p align="center"><img src="assets/icon/app_icon_256.png" width="112" alt="JJ_MKVMaker"></p>

# JJ_MKVMaker

동영상에 자막을 넣어 **MKV** 로 만들고, 자막을 **편집 · AI 로 생성 · 번역**하고,
동영상을 **재생**하는 무료 Windows 프로그램입니다. (Android 이식 예정)

- 모든 AI 처리(음성인식 · 번역)는 **내 PC 안에서** 이루어집니다. 영상이나 자막을 외부로 보내지 않습니다.
- 설치 없이 폴더째 실행합니다. 필요한 프로그램이 없으면 처음 실행할 때 물어보고 받아 줍니다.
- 무료 · 오픈 소스 (MIT) · 광고 없음

## 주요 기능

| 기능 | 내용 |
|---|---|
| **MKV 만들기** | 동영상 + 자막(여러 언어) → `jj_mkv\동일파일명.mkv`. 같은 폴더의 자막 자동 추가, 내장 자막 삭제·수정, 언어 태그 |
| **인코딩** | 원본 유지(재인코딩 없음) 또는 H.264 · H.265 · VP9 · AV1 · MPEG-4, 720p ~ 8K, 화질 3단계 |
| **자막 편집** | SRT · SMI · ASS · VTT · 내장 자막 편집, 문자셋 변환(UTF-8 · CP949 · Shift-JIS · GBK · UTF-16) |
| **싱크 맞추기** | 영상을 보면서 편집, 타임라인에서 끌어서 이동·길이 조절, "선택 줄부터 여기로 맞추기" |
| **AI 자막** | Whisper 음성인식 → `파일명_AI.srt`, NLLB 번역 → `파일명_ko.srt` · `_en` · `_ja` … (200개 언어) |
| **자막 번역** | 이미 있는 자막(예: 영어)을 원하는 언어로 번역해 MKV 에 추가. 인터넷에서 받은 자막도 한국어로 함께 번역 |
| **인터넷 자막 찾기** | OpenSubtitles.com 검색 (영상 해시로 "이 파일용" 자막 우선) |
| **동영상 플레이어** | 재생 목록, 전체 화면, 팝업(항상 위), 원본의 0.5·1·2·4배, 자막·음성 트랙 선택, 속도 |
| **탐색기 연결** | 오른쪽 클릭 "JJ_MKVMaker 로 재생" / "JJ_MKVMaker 로 자막 만들기", 끌어다 놓기. 더블클릭(연결 프로그램)으로 열면 바로 재생 또는 목록에 추가, 켜져 있는 창 / 새 창 (환경 설정) |
| **창 · 종료** | 창 위치 · 동영상 목록 기억, 여러 창의 목록 자동 맞춤. 종료(✕)를 누르면 백그라운드로 계속 / 모두 종료 / 매번 고르기 (환경 설정). 완전 종료는 트레이 아이콘 > 종료 |
| **다운로드** | Ctrl+C 로 복사한 YouTube 주소 → yt-dlp, 마그넷 · .torrent → aria2 (백그라운드, 트레이). 다 받은 영상은 편집 목록에 자동 추가 |
| **웹 브라우저** | 앱 안 브라우저(Edge WebView2)로 보다가 [다운로드], 즐겨찾기(Chrome · Edge · Whale 에서 가져오기), 로그인 쿠키를 yt-dlp 와 공유 |
| **작업 대기열 · 화면 분할** | AI 자막 · 번역 · MKV 만들기를 차례로 백그라운드 실행, 브라우저 옆 [작업 현황] 에서 진행 확인 |

## 실행

1. [Releases](../../releases) 에서 `JJ_MKVMaker_v*_win64.zip` 을 받아 원하는 폴더에 풉니다.
2. `jj_mkvmaker.exe` 를 실행합니다. (Windows 10/11 64비트)
3. 폴더 전체가 프로그램입니다. exe 파일 하나만 옮기면 동작하지 않습니다.

처음 쓸 때 내려받는 것 (한 번만):

| 항목 | 크기 | 언제 |
|---|---|---|
| Whisper base / small 음성인식 모델 | 148MB / 488MB | 처음 "AI 자막 만들기" 할 때 |
| NLLB-200 번역 모델 | 약 910MB | 처음 번역할 때 |

모델은 프로그램 폴더의 `models\` 에 저장됩니다. (환경 변수 `JJ_MKVMAKER_MODELS` 로 위치 변경 가능)

## 인터넷 자막 찾기 (선택)

OpenSubtitles 의 무료 API 키가 필요합니다.

1. [opensubtitles.com](https://www.opensubtitles.com) 가입
2. 프로필 → **API consumers** → **New consumer** 에서 키 만들기
3. 프로그램의 **환경 설정 → 인터넷 자막** 에 키 입력 (아이디·비밀번호는 선택, 넣으면 하루 받기 횟수가 늘어남)

## 단축키

| 화면 | 단축키 |
|---|---|
| 플레이어 | Space 재생/정지 · ←/→ 10초 · Shift+←/→ 1분 · ↑/↓ 음량 · F 전체 화면 · Esc 나가기 · N/P 다음/이전 · M 음소거 · S 자막 · L 재생 목록 |
| 자막 편집 | Ctrl+Space 재생/정지 · Alt+←/→ 1초 · Alt+Shift+←/→ 0.1초 · F7 새 줄 · F8 선택 줄 재생 · F9 시작=현재 · F10 끝=현재 |
| 브라우저 | Ctrl+L 주소창 · F5 새로고침 · Alt+←/→ 뒤로/앞으로 · Ctrl+D 즐겨찾기 · Ctrl+Shift+B 즐겨찾기 관리 · Ctrl+Shift+J 작업 현황 |
| 어디서나 | Ctrl+Shift+X 창 보이기 / 트레이로 숨기기 (환경 설정에서 변경) |

## 소스에서 빌드

필요: Flutter 3.47+, Visual Studio 2022 Build Tools (C++ 데스크톱), Windows 개발자 모드, PATH 에 `nuget.exe` (앱 안 브라우저 WebView2 빌드용)

```powershell
git clone <이 저장소>
cd app
powershell -File tool\fetch_ffmpeg.ps1   # third_party\ffmpeg\windows 에 FFmpeg 준비
powershell -File tool\fetch_tools.ps1    # third_party\tools\windows 에 yt-dlp · aria2 · Deno 준비
flutter pub get
flutter build windows --release          # build\windows\x64\runner\Release
```

테스트: `flutter test` (AI 모델 · 인터넷이 필요한 테스트는 자동으로 건너뜀)

### 구조

```
lib/
 ├─ core/       자막 · 문자셋 · FFmpeg 명령 · 재생 목록 규칙 등 순수 로직 (플랫폼 무관)
 ├─ app/        화면 상태 · 설정 · 다운로드 관리
 ├─ ui/         화면 (어두운 테마)
 ├─ services/   플랫폼 경계 (인터페이스)
 └─ platform/
     ├─ common/   Windows · Android 공용 구현 (mpv 플레이어, Whisper, NLLB, OpenSubtitles)
     └─ windows/  Windows 전용 (FFmpeg 프로세스, 트레이, 단축키, 탐색기 메뉴, yt-dlp, aria2)
packages/whisper_ggml/   Windows 힙 손상 버그를 고친 whisper_ggml 사본 (JJ_PATCH.md)
```

Android 이식 시 `platform/android/` 구현과 `services/platform_services.dart` 분기만 추가하면 됩니다.

## 라이선스

- JJ_MKVMaker 소스 코드: [MIT](LICENSE)
- 포함 · 사용하는 구성 요소: [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt)
  - FFmpeg (GPLv3) · aria2 (GPLv2) 는 수정하지 않은 별도 실행 파일로 함께 제공
  - libmpv (LGPL), whisper.cpp · ONNX Runtime (MIT), yt-dlp (Unlicense), Deno (MIT)
  - **NLLB-200 번역 모델은 CC-BY-NC 4.0 (비상업적 이용만)** — 이 프로그램은 무료 배포이며, 모델은 사용자가 직접 내려받습니다

## 주의

- YouTube 등에서 받은 영상, 토렌트로 받은 파일, 인터넷에서 받은 자막의 **저작권 책임은 이용자에게 있습니다.**
  권리가 있는 콘텐츠만 받으세요. YouTube 이용 약관도 확인하세요.
- 토렌트는 받는 동안 다른 사용자에게 조각을 올려 줍니다. 받기가 끝나면 올려 주기(시딩)는 바로 멈춥니다.
- "CapCut", "MakeMKV", "VLC" 는 각 소유자의 상표이며 이 프로그램과 관계가 없습니다.
