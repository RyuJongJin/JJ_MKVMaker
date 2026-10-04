# JJ_MKVMaker 수정 사항 (webview_cef 0.6.2 원본: https://github.com/hlwhl/webview_cef @ bb2dbcc)

"내장 Chrome" 은 환경 설정에서 고른 사람만 쓰므로, CEF 실행 파일 (약 250MB) 을 프로그램에 넣지 않고
고를 때 내려받는다. 그래서 CEF 가 없어도 프로그램이 켜지도록 두 가지를 바꿨다.

1. `windows/CMakeLists.txt`
   - 플러그인 DLL 이 `libcef.dll` 을 **지연 로딩** (`/DELAYLOAD:libcef.dll`, `delayimp`).
     CEF 함수를 처음 부를 때 (Dart 에서 `WebviewManager().initialize`) 에만 `libcef.dll` 을 찾는다.
   - `webview_cef_bundled_libraries` 를 비워 CEF 실행 파일을 프로그램 폴더에 복사하지 않는다.

2. 앱의 `windows/runner/main.cpp` (이 폴더 밖)
   - `<exe 폴더>\cef\libcef.dll` 이 있을 때만 `SetDllDirectoryW(<exe 폴더>\cef)` → `initCEFProcesses` → 메시지 루프에서 `handleWndProcForCEF`.

CEF 실행 파일은 앱이 공식 배포처 (https://cef-builds.spotifycdn.com) 의 *Minimal Distribution*
(`third/download.cmake` 의 `CEF_VERSION` 과 같은 버전) 을 받아 `Release\*` 와 `Resources\*` 를 `Lib\cef` 에 푼다.
버전을 올릴 때는 `third/download.cmake` 와 앱의 `lib/platform/windows/cef_runtime.dart` 의 버전을 함께 바꾼다.

3. `common/webview_handler.cc`: 주소 변경 (`OnAddressChange`) · 읽기 시작 / 끝 (`OnLoadStart` / `OnLoadEnd`) 을 **본문 (main frame) 일 때만** 알린다.
   원본은 페이지 안 틀 (iframe, 예: YouTube 의 about:blank) 도 알려서 주소창이 about:blank 로 바뀌었다.

4. `windows/webview_cef_plugin.cpp`: CEF 실행 파일이 없으면 화면 갱신 스레드 (vsync) 와 IME 가로채기를 켜지 않는다.
   CEF 가 있어도 IME 는 **Chrome 화면 안의 입력칸에 포커스가 있을 때만** 가로챈다.
   원본은 늘 IME 조합 창을 막아서, 앱의 다른 입력칸 (주소창 · 검색 등) 의 한글 입력에 영향을 줄 수 있었다.

5. `common/webview_plugin.cc` · `common/webview_handler.cc` · `lib/src/webview.dart`: JavaScript 끄기.
   `create` 가 주소 대신 `{url, javascript: false}` 를 받으면 그 브라우저의 `CefBrowserSettings.javascript` 를 `STATE_DISABLED` 로 만든다
   (Dart: `WebViewController.initialize(url, javaScript: false)`). 이미 만든 브라우저는 바꿀 수 없어 앱이 새로 만든다.
