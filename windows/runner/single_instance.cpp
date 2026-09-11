#include "single_instance.h"

#include <string.h>

#include <string>

namespace neko_chat {

namespace {

// Unique name for the single-instance mutex. The "Local\" prefix scopes it to
// the current user session so different users can each run their own copy.
constexpr const wchar_t kMutexName[] = L"Local\\NekoChat.SingleInstance";

// Window class used by the Flutter Windows runner and the title passed to
// Win32Window::Create() from main.cpp.
constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr const wchar_t kWindowTitle[] = L"neko_chat";

// Kept alive for the lifetime of the process so the mutex stays owned by the
// primary instance.
HANDLE g_instance_mutex = nullptr;

// Returns the full path of the executable backing |window|.
bool GetWindowExecutablePath(HWND window, std::wstring* path) {
  DWORD process_id = 0;
  ::GetWindowThreadProcessId(window, &process_id);
  if (process_id == 0) {
    return false;
  }

  HANDLE process =
      ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id);
  if (process == nullptr) {
    return false;
  }

  wchar_t buffer[MAX_PATH] = {};
  DWORD size = MAX_PATH;
  const bool ok = ::QueryFullProcessImageNameW(process, 0, buffer, &size) != 0;
  ::CloseHandle(process);
  if (!ok) {
    return false;
  }

  path->assign(buffer, size);
  return true;
}

// Returns the path of the currently running executable.
std::wstring GetCurrentExecutablePath() {
  wchar_t buffer[MAX_PATH] = {};
  const DWORD size = ::GetModuleFileNameW(nullptr, buffer, MAX_PATH);
  return std::wstring(buffer, size);
}

// A window only belongs to the primary instance when it uses the runner's
// window class, carries the expected title and is backed by another copy of
// this very executable. The executable check prevents other Flutter apps
// (which share the same window class) from being mistaken for our instance.
bool IsPrimaryWindow(HWND window) {
  wchar_t class_name[256] = {};
  if (::GetClassNameW(window, class_name, 256) == 0) {
    return false;
  }
  if (_wcsicmp(class_name, kWindowClassName) != 0) {
    return false;
  }

  wchar_t title[256] = {};
  if (::GetWindowTextW(window, title, 256) == 0) {
    return false;
  }
  if (_wcsicmp(title, kWindowTitle) != 0) {
    return false;
  }

  std::wstring window_path;
  if (!GetWindowExecutablePath(window, &window_path)) {
    return false;
  }
  const std::wstring current_path = GetCurrentExecutablePath();
  return _wcsicmp(window_path.c_str(), current_path.c_str()) == 0;
}

BOOL CALLBACK EnumWindowsCallback(HWND window, LPARAM param) {
  auto* result = reinterpret_cast<HWND*>(param);
  if (IsPrimaryWindow(window)) {
    *result = window;
    return FALSE;  // Stop enumerating once the window has been found.
  }
  return TRUE;
}

// The primary window may still be starting up, so poll for it briefly.
HWND FindPrimaryWindow() {
  for (int attempt = 0; attempt < 30; ++attempt) {
    HWND window = nullptr;
    ::EnumWindows(&EnumWindowsCallback, reinterpret_cast<LPARAM>(&window));
    if (window != nullptr) {
      return window;
    }
    ::Sleep(100);
  }
  return nullptr;
}

}  // namespace

UINT ActivateInstanceMessage() {
  static const UINT message =
      ::RegisterWindowMessageW(L"NekoChat.ActivateInstance");
  return message;
}

void BringWindowToForeground(HWND window) {
  if (window == nullptr) {
    return;
  }
  if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  } else {
    ::ShowWindow(window, SW_SHOW);
  }

  // SetForegroundWindow() is rejected for background processes, so temporarily
  // attach this thread's input to the current foreground thread to satisfy
  // that requirement.
  const HWND foreground = ::GetForegroundWindow();
  const DWORD foreground_thread =
      foreground == nullptr
          ? 0
          : ::GetWindowThreadProcessId(foreground, nullptr);
  const DWORD current_thread = ::GetCurrentThreadId();
  const bool attached =
      foreground_thread != 0 && foreground_thread != current_thread &&
      ::AttachThreadInput(current_thread, foreground_thread, TRUE) != 0;

  ::SetForegroundWindow(window);
  ::BringWindowToTop(window);

  if (attached) {
    ::AttachThreadInput(current_thread, foreground_thread, FALSE);
  }
}

bool FocusExistingInstanceOrStart() {
  g_instance_mutex = ::CreateMutexW(nullptr, TRUE, kMutexName);
  const bool already_running =
      g_instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS;
  if (!already_running) {
    return false;
  }

  HWND window = FindPrimaryWindow();
  if (window != nullptr) {
    // Ask the primary instance to bring itself forward; it does so from its own
    // message loop where the foreground change is more likely to be honored.
    ::PostMessageW(window, ActivateInstanceMessage(), 0, 0);
    // Foreground it from here as a best-effort fallback in case the primary is
    // busy and cannot process the message right away.
    BringWindowToForeground(window);
  }

  if (g_instance_mutex != nullptr) {
    ::CloseHandle(g_instance_mutex);
    g_instance_mutex = nullptr;
  }
  return true;
}

}  // namespace neko_chat
