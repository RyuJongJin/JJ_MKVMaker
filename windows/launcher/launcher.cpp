// JJ_MKVMaker 시작 프로그램 (배포 폴더 맨 위의 jj_mkvmaker.exe)
//
// 배포 폴더를 깔끔하게 두려고 실제 프로그램과 부속 파일은 모두 Lib\ 아래에 있다.
//   JJ_MKVMaker\jj_mkvmaker.exe      ← 이 파일 (Lib\jj_mkvmaker.exe 를 같은 인수로 실행하고 끝남)
//   JJ_MKVMaker\LICENSE.txt, README.md
//   JJ_MKVMaker\Lib\...              ← 프로그램 · DLL · ffmpeg · 도구
//   JJ_MKVMaker\Logs\...             ← 작업 기록
//
// 빌드: tool\build_launcher.ps1 (Visual Studio Build Tools 의 cl · rc, C 런타임 정적 연결 → 다른 DLL 없이 실행)
#include <windows.h>
#include <shellapi.h>

#include <string>

static std::wstring ExeDir() {
  wchar_t buf[MAX_PATH * 4];
  const DWORD n = GetModuleFileNameW(nullptr, buf, static_cast<DWORD>(sizeof(buf) / sizeof(buf[0])));
  std::wstring path(buf, n);
  const size_t slash = path.find_last_of(L"\\/");
  return slash == std::wstring::npos ? L"." : path.substr(0, slash);
}

// 이 프로그램을 실행할 때 받은 인수 (프로그램 이름 뒤 전부, 따옴표 포함 그대로)
static std::wstring ArgsAfterProgramName() {
  const wchar_t* cmd = GetCommandLineW();
  bool quoted = false;
  while (*cmd && (quoted || (*cmd != L' ' && *cmd != L'\t'))) {
    if (*cmd == L'"') quoted = !quoted;
    ++cmd;
  }
  while (*cmd == L' ' || *cmd == L'\t') ++cmd;
  return cmd;
}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int show) {
  const std::wstring lib = ExeDir() + L"\\Lib";
  const std::wstring app = lib + L"\\jj_mkvmaker.exe";
  if (GetFileAttributesW(app.c_str()) == INVALID_FILE_ATTRIBUTES) {
    const std::wstring msg = L"프로그램 파일을 찾을 수 없습니다:\n" + app +
                             L"\n\n배포 zip 을 다시 풀어 Lib 폴더가 jj_mkvmaker.exe 옆에 있는지 확인하세요.";
    MessageBoxW(nullptr, msg.c_str(), L"JJ_MKVMaker", MB_ICONERROR | MB_OK);
    return 1;
  }

  std::wstring cmdline = L"\"" + app + L"\"";
  const std::wstring args = ArgsAfterProgramName();
  if (!args.empty()) cmdline += L" " + args;

  // 새로 뜨는 창이 앞으로 올 수 있게
  AllowSetForegroundWindow(ASFW_ANY);

  STARTUPINFOW si{};
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESHOWWINDOW;
  si.wShowWindow = static_cast<WORD>(show);
  PROCESS_INFORMATION pi{};
  if (!CreateProcessW(app.c_str(), cmdline.data(), nullptr, nullptr, FALSE, 0, nullptr, lib.c_str(), &si, &pi)) {
    const std::wstring msg = L"프로그램을 시작할 수 없습니다 (오류 " + std::to_wstring(GetLastError()) + L"):\n" + app;
    MessageBoxW(nullptr, msg.c_str(), L"JJ_MKVMaker", MB_ICONERROR | MB_OK);
    return 1;
  }
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  return 0;
}
