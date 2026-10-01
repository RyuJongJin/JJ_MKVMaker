#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"
#include "webview_cef/webview_cef_plugin_c_api.h"

#include <string>

// 내장 Chrome (CEF) 은 환경 설정에서 고른 사람만 내려받는다: <exe 폴더>\cef\libcef.dll
// 있으면 그 폴더를 DLL 검색 경로에 넣고 true. 없으면 Chrome 관련 처리를 모두 건너뛴다.
static bool PrepareCef() {
  wchar_t buf[MAX_PATH * 4];
  const DWORD n = ::GetModuleFileNameW(nullptr, buf, static_cast<DWORD>(sizeof(buf) / sizeof(buf[0])));
  std::wstring dir(buf, n);
  dir = dir.substr(0, dir.find_last_of(L"\\/")) + L"\\cef";
  if (::GetFileAttributesW((dir + L"\\libcef.dll").c_str()) == INVALID_FILE_ATTRIBUTES) return false;
  ::SetDllDirectoryW(dir.c_str());
  return true;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // 내장 Chrome: CEF 의 하위 프로세스 (화면 그리기 · 네트워크 등) 로 실행된 경우 여기서 처리하고 끝낸다.
  // 반드시 맨 처음에 해야 한다.
  const bool cef = PrepareCef();
  if (cef) {
    const int exit_code = initCEFProcesses(instance);
    if (exit_code >= 0) return exit_code;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"JJ_MKVMaker", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
    // 내장 Chrome: 키 입력 · 플러그인 메시지를 CEF 로 (Chrome 엔진이 있을 때만)
    if (cef) handleWndProcForCEF(msg.hwnd, msg.message, msg.wParam, msg.lParam);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
