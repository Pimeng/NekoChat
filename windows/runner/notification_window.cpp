#include "notification_window.h"

#include <windows.h>
#include <dwmapi.h>
#include <flutter_windows.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <multiview_desktop/multi_view_desktop_plugin.h>

#include <algorithm>
#include <cmath>
#include <cwchar>
#include <map>
#include <memory>
#include <string>

namespace neko_chat {
namespace {

constexpr char kChannelName[] = "neko_chat/notification_window";
constexpr DWORD kDwmwaUseImmersiveDarkMode = 20;
constexpr DWORD kDwmwaWindowCornerPreference = 33;
constexpr DWORD kDwmwcpRound = 2;
constexpr UINT_PTR kAnimTimerId = 0x4E54;

enum class AnimMode { kNone, kEnter, kExit };

struct NotificationWindowState {
  WNDPROC original_wndproc = nullptr;
  RECT target_rect = {};
  bool lock_bounds = false;
  bool hidden_by_alpha = false;
  std::string corner = "bottomRight";
  double scale = 1.0;
  AnimMode anim_mode = AnimMode::kNone;
  ULONGLONG anim_start_ms = 0;
  DWORD anim_duration_ms = 0;
  int anim_start_x = 0;
  int anim_end_x = 0;
  int anim_y = 0;
  BYTE anim_start_alpha = 0;
  BYTE anim_end_alpha = 255;
  int current_x = 0;
  BYTE current_alpha = 0;
};

HHOOK g_cbt_hook = nullptr;
RECT g_pending_target_rect = {};

std::map<HWND, NotificationWindowState>& WindowStates() {
  static auto* states = new std::map<HWND, NotificationWindowState>();
  return *states;
}

int64_t IntFromMap(const flutter::EncodableMap& map, const char* key,
                   int64_t fallback = -1) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return fallback;
  if (const auto* v32 = std::get_if<int32_t>(&it->second)) return *v32;
  if (const auto* v64 = std::get_if<int64_t>(&it->second)) return *v64;
  return fallback;
}

double DoubleFromMap(const flutter::EncodableMap& map, const char* key,
                     double fallback) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return fallback;
  if (const auto* vd = std::get_if<double>(&it->second)) return *vd;
  if (const auto* v32 = std::get_if<int32_t>(&it->second)) {
    return static_cast<double>(*v32);
  }
  if (const auto* v64 = std::get_if<int64_t>(&it->second)) {
    return static_cast<double>(*v64);
  }
  return fallback;
}

bool BoolFromMap(const flutter::EncodableMap& map, const char* key,
                 bool fallback) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return fallback;
  if (const auto* vb = std::get_if<bool>(&it->second)) return *vb;
  return fallback;
}

std::string StringFromMap(const flutter::EncodableMap& map, const char* key,
                          const char* fallback) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return fallback;
  if (const auto* vs = std::get_if<std::string>(&it->second)) return *vs;
  return fallback;
}

bool ReadPersonalizeDword(const wchar_t* value_name, DWORD* out_value) {
  HKEY key = nullptr;
  if (::RegOpenKeyExW(
          HKEY_CURRENT_USER,
          L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
          0, KEY_READ, &key) != ERROR_SUCCESS) {
    return false;
  }
  DWORD data = 1;
  DWORD size = sizeof(data);
  DWORD type = 0;
  const LONG status =
      ::RegQueryValueExW(key, value_name, nullptr, &type,
                         reinterpret_cast<LPBYTE>(&data), &size);
  ::RegCloseKey(key);
  if (status != ERROR_SUCCESS || type != REG_DWORD) {
    return false;
  }
  *out_value = data;
  return true;
}

bool IsSystemDarkMode() {
  DWORD light_theme = 1;
  if (ReadPersonalizeDword(L"SystemUsesLightTheme", &light_theme)) {
    return light_theme == 0;
  }
  if (ReadPersonalizeDword(L"AppsUseLightTheme", &light_theme)) {
    return light_theme == 0;
  }
  return false;
}

bool ComputeTargetRect(double logical_width, double logical_height,
                       double margin_x, double margin_y,
                       const std::string& corner, RECT* out_rect,
                       double* out_scale = nullptr) {
  if (out_rect == nullptr) return false;
  const POINT origin = {0, 0};
  const HMONITOR monitor =
      ::MonitorFromPoint(origin, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO monitor_info = {};
  monitor_info.cbSize = sizeof(monitor_info);
  if (!::GetMonitorInfoW(monitor, &monitor_info)) {
    return false;
  }
  const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  const double scale =
      dpi > 0 ? static_cast<double>(dpi) / USER_DEFAULT_SCREEN_DPI : 1.0;
  if (out_scale != nullptr) {
    *out_scale = scale;
  }

  const int phys_w =
      std::max(1, static_cast<int>(std::lround(logical_width * scale)));
  const int phys_h =
      std::max(1, static_cast<int>(std::lround(logical_height * scale)));
  const int phys_mx =
      std::max(0, static_cast<int>(std::lround(margin_x * scale)));
  const int phys_my =
      std::max(0, static_cast<int>(std::lround(margin_y * scale)));

  const RECT work = monitor_info.rcWork;
  int x = work.right - phys_w - phys_mx;
  int y = work.bottom - phys_h - phys_my;
  if (corner == "topRight") {
    x = work.right - phys_w - phys_mx;
    y = work.top + phys_my;
  } else if (corner == "bottomLeft") {
    x = work.left + phys_mx;
    y = work.bottom - phys_h - phys_my;
  } else if (corner == "topLeft") {
    x = work.left + phys_mx;
    y = work.top + phys_my;
  }

  out_rect->left = x;
  out_rect->top = y;
  out_rect->right = x + phys_w;
  out_rect->bottom = y + phys_h;
  return true;
}

int SlideOffsetPx(const NotificationWindowState& state, double logical_px) {
  const int px = static_cast<int>(std::lround(logical_px * state.scale));
  if (state.corner == "bottomLeft" || state.corner == "topLeft") {
    return -px;
  }
  return px;
}

void ApplyDwmStyling(HWND hwnd) {
  if (hwnd == nullptr) return;
  const BOOL dark_mode = IsSystemDarkMode() ? TRUE : FALSE;
  ::DwmSetWindowAttribute(hwnd, kDwmwaUseImmersiveDarkMode, &dark_mode,
                          sizeof(dark_mode));
  const DWORD corner_pref = kDwmwcpRound;
  ::DwmSetWindowAttribute(hwnd, kDwmwaWindowCornerPreference, &corner_pref,
                          sizeof(corner_pref));
}

void SetWindowAlpha(HWND hwnd, BYTE alpha) {
  if (hwnd == nullptr) return;
  const LONG_PTR ex_style = ::GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
  if ((ex_style & WS_EX_LAYERED) == 0) {
    ::SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex_style | WS_EX_LAYERED);
  }
  ::SetLayeredWindowAttributes(hwnd, 0, alpha, LWA_ALPHA);
}

void StopAnimation(HWND hwnd, NotificationWindowState* state) {
  if (hwnd != nullptr) {
    ::KillTimer(hwnd, kAnimTimerId);
  }
  if (state != nullptr) {
    state->anim_mode = AnimMode::kNone;
  }
}

void StartEnterAnimation(HWND hwnd, NotificationWindowState* state) {
  if (hwnd == nullptr || state == nullptr) return;
  const int off_x = state->target_rect.left + SlideOffsetPx(*state, 48.0);
  const bool interrupting_exit = (state->anim_mode == AnimMode::kExit);
  ::KillTimer(hwnd, kAnimTimerId);

  state->anim_mode = AnimMode::kEnter;
  state->anim_start_ms = ::GetTickCount64();
  state->anim_duration_ms = 240;
  state->anim_start_x = interrupting_exit ? state->current_x : off_x;
  state->anim_end_x = state->target_rect.left;
  state->anim_y = state->target_rect.top;
  state->anim_start_alpha = interrupting_exit ? state->current_alpha : 0;
  state->anim_end_alpha = 255;
  state->hidden_by_alpha = false;
  state->current_x = state->anim_start_x;
  state->current_alpha = state->anim_start_alpha;

  ::SetWindowPos(hwnd, HWND_TOPMOST, state->anim_start_x, state->anim_y, 0, 0,
                 SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  SetWindowAlpha(hwnd, state->anim_start_alpha);
  ::ShowWindow(hwnd, SW_SHOWNOACTIVATE);
  ::SetTimer(hwnd, kAnimTimerId, 10, nullptr);
}

void StartExitAnimation(HWND hwnd, NotificationWindowState* state) {
  if (hwnd == nullptr || state == nullptr) return;
  if (!::IsWindowVisible(hwnd)) {
    StopAnimation(hwnd, state);
    state->hidden_by_alpha = true;
    state->current_alpha = 0;
    return;
  }
  const int end_x = state->target_rect.left + SlideOffsetPx(*state, 40.0);
  const bool was_idle = (state->anim_mode == AnimMode::kNone);
  ::KillTimer(hwnd, kAnimTimerId);

  state->anim_start_x = was_idle ? state->target_rect.left : state->current_x;
  state->anim_start_alpha = was_idle ? 255 : state->current_alpha;
  state->anim_end_x = end_x;
  state->anim_y = state->target_rect.top;
  state->anim_end_alpha = 0;
  state->anim_mode = AnimMode::kExit;
  state->anim_start_ms = ::GetTickCount64();
  state->anim_duration_ms = 180;
  state->current_x = state->anim_start_x;
  state->current_alpha = state->anim_start_alpha;

  ::SetTimer(hwnd, kAnimTimerId, 10, nullptr);
}

void ForceFlutterViewResizeAndRedraw(HWND flutter_hwnd, int phys_w,
                                     int phys_h) {
  if (flutter_hwnd == nullptr) return;
  const int w = std::max(1, phys_w);
  const int h = std::max(1, phys_h);
  // 首次配置时触发真实的 WM_SIZE 尺寸变化，让新建后的 FlutterView 同步宿主窗口 DPI 与交换链视口。
  ::MoveWindow(flutter_hwnd, 0, 0, w + 1, h, FALSE);
  ::MoveWindow(flutter_hwnd, 0, 0, w, h, TRUE);
  ::RedrawWindow(flutter_hwnd, nullptr, nullptr,
                 RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);
}

LRESULT CALLBACK NotificationHostWndProc(HWND hwnd, UINT message,
                                         WPARAM wparam, LPARAM lparam) {
  auto& states = WindowStates();
  auto it = states.find(hwnd);
  if (it == states.end()) {
    return ::DefWindowProcW(hwnd, message, wparam, lparam);
  }
  WNDPROC orig_proc = it->second.original_wndproc;
  auto invoke_original = [&](HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    if (orig_proc == nullptr || orig_proc == NotificationHostWndProc) {
      return ::DefWindowProcW(h, msg, wp, lp);
    }
    return ::CallWindowProcW(orig_proc, h, msg, wp, lp);
  };

  switch (message) {
    case WM_GETMINMAXINFO: {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      if (info != nullptr) {
        info->ptMinTrackSize.x = 1;
        info->ptMinTrackSize.y = 1;
      }
      return 0;
    }
    case WM_NCCALCSIZE: {
      if (wparam != 0) {
        return 0;
      }
      break;
    }
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    case WM_TIMER: {
      if (wparam == kAnimTimerId && it->second.anim_mode != AnimMode::kNone) {
        NotificationWindowState& st = it->second;
        const ULONGLONG now = ::GetTickCount64();
        const double elapsed =
            now >= st.anim_start_ms
                ? static_cast<double>(now - st.anim_start_ms)
                : 0.0;
        const double duration =
            st.anim_duration_ms > 0 ? static_cast<double>(st.anim_duration_ms)
                                    : 1.0;
        const double raw = std::clamp(elapsed / duration, 0.0, 1.0);

        double pos_t = raw;
        double alpha_t = raw;
        if (st.anim_mode == AnimMode::kEnter) {
          pos_t = 1.0 - std::pow(1.0 - raw, 4.0);
          const double a_raw = std::min(1.0, raw / 0.7);
          alpha_t = 1.0 - std::pow(1.0 - a_raw, 3.0);
        } else {
          const double ease = 1.0 - std::pow(1.0 - raw, 2.5);
          pos_t = ease;
          alpha_t = ease;
        }

        const int cur_x = static_cast<int>(std::lround(
            st.anim_start_x + (st.anim_end_x - st.anim_start_x) * pos_t));
        const int alpha_val = static_cast<int>(std::lround(
            st.anim_start_alpha +
            (static_cast<int>(st.anim_end_alpha) -
             static_cast<int>(st.anim_start_alpha)) *
                alpha_t));
        const BYTE cur_alpha =
            static_cast<BYTE>(std::clamp(alpha_val, 0, 255));

        st.current_x = cur_x;
        st.current_alpha = cur_alpha;
        ::SetWindowPos(hwnd, HWND_TOPMOST, cur_x, st.anim_y, 0, 0,
                       SWP_NOSIZE | SWP_NOACTIVATE);
        SetWindowAlpha(hwnd, cur_alpha);

        if (raw >= 1.0) {
          const bool was_exit = (st.anim_mode == AnimMode::kExit);
          StopAnimation(hwnd, &st);
          if (was_exit) {
            ::ShowWindow(hwnd, SW_HIDE);
            st.hidden_by_alpha = true;
          }
        }
        return 0;
      }
      break;
    }
    case WM_CREATE: {
      const LRESULT res = invoke_original(hwnd, message, wparam, lparam);
      auto after_it = states.find(hwnd);
      if (after_it != states.end()) {
        if (after_it->second.hidden_by_alpha) {
          SetWindowAlpha(hwnd, 0);
        }
        ApplyDwmStyling(hwnd);
      }
      return res;
    }
    case WM_WINDOWPOSCHANGING: {
      if (it->second.lock_bounds && lparam != 0) {
        auto* wp = reinterpret_cast<WINDOWPOS*>(lparam);
        const RECT& target = it->second.target_rect;
        wp->x = target.left;
        wp->y = target.top;
        wp->cx = target.right - target.left;
        wp->cy = target.bottom - target.top;
        wp->hwndInsertAfter = HWND_TOPMOST;
        wp->flags = (wp->flags & ~(SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER)) |
                    SWP_NOACTIVATE;
        return 0;
      }
      break;
    }
    case WM_NCDESTROY: {
      ::KillTimer(hwnd, kAnimTimerId);
      ::SetWindowLongPtrW(hwnd, GWLP_WNDPROC,
                          reinterpret_cast<LONG_PTR>(orig_proc));
      states.erase(it);
      return invoke_original(hwnd, message, wparam, lparam);
    }
    default:
      break;
  }

  return invoke_original(hwnd, message, wparam, lparam);
}

LRESULT CALLBACK CbtCreateHookProc(int nCode, WPARAM wparam, LPARAM lparam) {
  const HHOOK hook = g_cbt_hook;
  if (nCode == HCBT_CREATEWND && lparam != 0) {
    const HWND hwnd = reinterpret_cast<HWND>(wparam);
    wchar_t class_name[64] = {};
    if (hwnd != nullptr && ::GetClassNameW(hwnd, class_name, 64) > 0 &&
        std::wcscmp(class_name, L"MULTIVIEW_DESKTOP_HOST_WINDOW") == 0) {
      auto* cbt = reinterpret_cast<CBT_CREATEWNDW*>(lparam);
      if (cbt != nullptr && cbt->lpcs != nullptr) {
        const RECT& target = g_pending_target_rect;
        cbt->lpcs->style &=
            ~(WS_OVERLAPPEDWINDOW | WS_CAPTION | WS_THICKFRAME |
              WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU | WS_BORDER |
              WS_VISIBLE);
        cbt->lpcs->style |= WS_POPUP;
        cbt->lpcs->dwExStyle &= ~WS_EX_APPWINDOW;
        cbt->lpcs->dwExStyle |= WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE |
                                WS_EX_TOPMOST | WS_EX_LAYERED;
        cbt->lpcs->x = target.left;
        cbt->lpcs->y = target.top;
        cbt->lpcs->cx = target.right - target.left;
        cbt->lpcs->cy = target.bottom - target.top;
      }

      const LONG_PTR prev_proc = ::SetWindowLongPtrW(
          hwnd, GWLP_WNDPROC,
          reinterpret_cast<LONG_PTR>(NotificationHostWndProc));
      NotificationWindowState state;
      state.original_wndproc = reinterpret_cast<WNDPROC>(prev_proc);
      state.target_rect = g_pending_target_rect;
      state.lock_bounds = true;
      state.hidden_by_alpha = true;
      WindowStates()[hwnd] = state;
      SetWindowAlpha(hwnd, 0);
      ApplyDwmStyling(hwnd);

      if (g_cbt_hook != nullptr) {
        ::UnhookWindowsHookEx(g_cbt_hook);
        g_cbt_hook = nullptr;
      }
    }
  }
  return ::CallNextHookEx(hook, nCode, wparam, lparam);
}

NotificationWindowState* EnsureSubclass(HWND hwnd, const RECT& target_rect) {
  auto& states = WindowStates();
  auto it = states.find(hwnd);
  if (it == states.end()) {
    const LONG_PTR prev_proc = ::SetWindowLongPtrW(
        hwnd, GWLP_WNDPROC,
        reinterpret_cast<LONG_PTR>(NotificationHostWndProc));
    NotificationWindowState state;
    state.original_wndproc = reinterpret_cast<WNDPROC>(prev_proc);
    state.target_rect = target_rect;
    it = states.emplace(hwnd, state).first;
  } else {
    it->second.target_rect = target_rect;
  }
  return &it->second;
}

struct WindowHandles {
  HWND flutter_hwnd = nullptr;
  HWND host_hwnd = nullptr;
};

class NotificationWindowManagerImpl {
 public:
  void Initialize(flutter::BinaryMessenger* messenger) {
    channel_ = std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
        messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler(
        [this](const auto& call, auto result) {
          HandleMethodCall(call, std::move(result));
        });
  }

 private:
  int64_t ToRealViewId(int64_t public_view_id) const {
    return public_view_id + MultiViewDesktopGetMainViewId() - 1;
  }

  WindowHandles ResolveHandles(int64_t public_view_id) const {
    const HWND flutter_hwnd =
        MultiViewDesktopGetFlutterHwnd(ToRealViewId(public_view_id));
    if (flutter_hwnd == nullptr) return {};
    const HWND host_hwnd = ::GetAncestor(flutter_hwnd, GA_ROOT);
    if (host_hwnd == nullptr) return {};
    return {flutter_hwnd, host_hwnd};
  }

  void ApplyBounds(const WindowHandles& handles, const RECT& target,
                   bool frame_changed, bool force_flutter_resize) const {
    const int phys_w = std::max(1L, target.right - target.left);
    const int phys_h = std::max(1L, target.bottom - target.top);

    UINT flags = SWP_NOACTIVATE | SWP_SHOWWINDOW;
    if (frame_changed) {
      flags |= SWP_FRAMECHANGED;
    }
    ::SetWindowPos(handles.host_hwnd, HWND_TOPMOST, target.left, target.top,
                   phys_w, phys_h, flags);
    if (force_flutter_resize) {
      ForceFlutterViewResizeAndRedraw(handles.flutter_hwnd, phys_w, phys_h);
    } else {
      ::MoveWindow(handles.flutter_hwnd, 0, 0, phys_w, phys_h, TRUE);
    }
    ::ShowWindow(handles.host_hwnd, SW_SHOWNOACTIVATE);
  }

  void CancelPrepare() {
    if (g_cbt_hook != nullptr) {
      ::UnhookWindowsHookEx(g_cbt_hook);
      g_cbt_hook = nullptr;
    }
  }

  bool PrepareForCreation(const flutter::EncodableMap& args) {
    previous_foreground_ = ::GetForegroundWindow();
    const double width = DoubleFromMap(args, "width", 364.0);
    const double height = DoubleFromMap(args, "height", 114.0);
    const double margin_x = DoubleFromMap(args, "marginX", 16.0);
    const double margin_y = DoubleFromMap(args, "marginY", 16.0);
    const std::string corner = StringFromMap(args, "corner", "bottomRight");

    RECT target = {};
    if (!ComputeTargetRect(width, height, margin_x, margin_y, corner,
                           &target)) {
      return false;
    }
    g_pending_target_rect = target;
    CancelPrepare();
    g_cbt_hook = ::SetWindowsHookExW(WH_CBT, CbtCreateHookProc, nullptr,
                                     ::GetCurrentThreadId());
    return g_cbt_hook != nullptr;
  }

  bool ConfigureWindow(const flutter::EncodableMap& args) {
    CancelPrepare();
    const int64_t view_id = IntFromMap(args, "viewId");
    if (view_id < 0) return false;
    const WindowHandles handles = ResolveHandles(view_id);
    if (handles.host_hwnd == nullptr) return false;

    const double width = DoubleFromMap(args, "width", 364.0);
    const double height = DoubleFromMap(args, "height", 114.0);
    const double margin_x = DoubleFromMap(args, "marginX", 16.0);
    const double margin_y = DoubleFromMap(args, "marginY", 16.0);
    const std::string corner = StringFromMap(args, "corner", "bottomRight");
    const bool reveal = BoolFromMap(args, "reveal", true);

    RECT target = {};
    double scale = 1.0;
    if (!ComputeTargetRect(width, height, margin_x, margin_y, corner,
                           &target, &scale)) {
      return false;
    }

    NotificationWindowState* state = EnsureSubclass(handles.host_hwnd, target);
    state->lock_bounds = false;
    state->corner = corner;
    state->scale = scale;

    LONG_PTR style = ::GetWindowLongPtrW(handles.host_hwnd, GWL_STYLE);
    style &= ~(WS_OVERLAPPEDWINDOW | WS_CAPTION | WS_THICKFRAME |
               WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU | WS_BORDER);
    style |= WS_POPUP;
    ::SetWindowLongPtrW(handles.host_hwnd, GWL_STYLE, style);

    LONG_PTR ex_style = ::GetWindowLongPtrW(handles.host_hwnd, GWL_EXSTYLE);
    ex_style &= ~WS_EX_APPWINDOW;
    ex_style |=
        WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST | WS_EX_LAYERED;
    ::SetWindowLongPtrW(handles.host_hwnd, GWL_EXSTYLE, ex_style);

    if (!reveal) {
      state->hidden_by_alpha = true;
      state->current_alpha = 0;
      SetWindowAlpha(handles.host_hwnd, 0);
    }

    ApplyDwmStyling(handles.host_hwnd);
    const MARGINS margins = {0, 0, 1, 0};
    ::DwmExtendFrameIntoClientArea(handles.host_hwnd, &margins);

    ApplyBounds(handles, target, true, true);

    if (previous_foreground_ != nullptr &&
        previous_foreground_ != handles.host_hwnd &&
        ::IsWindow(previous_foreground_)) {
      ::SetForegroundWindow(previous_foreground_);
    }
    if (reveal) {
      previous_foreground_ = nullptr;
      StartEnterAnimation(handles.host_hwnd, state);
    }
    return true;
  }

  bool RevealWindow(const flutter::EncodableMap& args) {
    const int64_t view_id = IntFromMap(args, "viewId");
    if (view_id < 0) return false;
    const WindowHandles handles = ResolveHandles(view_id);
    if (handles.host_hwnd == nullptr) return false;

    if (previous_foreground_ != nullptr &&
        previous_foreground_ != handles.host_hwnd &&
        ::IsWindow(previous_foreground_)) {
      ::SetForegroundWindow(previous_foreground_);
    }
    previous_foreground_ = nullptr;

    auto& states = WindowStates();
    auto it = states.find(handles.host_hwnd);
    if (it != states.end()) {
      StartEnterAnimation(handles.host_hwnd, &it->second);
    } else {
      SetWindowAlpha(handles.host_hwnd, 255);
      ::ShowWindow(handles.host_hwnd, SW_SHOWNOACTIVATE);
    }

    ::RedrawWindow(handles.flutter_hwnd, nullptr, nullptr,
                   RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);
    return true;
  }

  bool UpdateBoundsAndShow(const flutter::EncodableMap& args) const {
    const int64_t view_id = IntFromMap(args, "viewId");
    if (view_id < 0) return false;
    const WindowHandles handles = ResolveHandles(view_id);
    if (handles.host_hwnd == nullptr) return false;

    const double width = DoubleFromMap(args, "width", 364.0);
    const double height = DoubleFromMap(args, "height", 114.0);
    const double margin_x = DoubleFromMap(args, "marginX", 16.0);
    const double margin_y = DoubleFromMap(args, "marginY", 16.0);
    const std::string corner = StringFromMap(args, "corner", "bottomRight");

    RECT target = {};
    double scale = 1.0;
    if (!ComputeTargetRect(width, height, margin_x, margin_y, corner,
                           &target, &scale)) {
      return false;
    }

    const bool was_visible = ::IsWindowVisible(handles.host_hwnd) != FALSE;
    RECT prev_flutter_rect = {};
    ::GetClientRect(handles.flutter_hwnd, &prev_flutter_rect);
    const int prev_w = prev_flutter_rect.right - prev_flutter_rect.left;
    const int prev_h = prev_flutter_rect.bottom - prev_flutter_rect.top;
    const int next_w = std::max(1L, target.right - target.left);
    const int next_h = std::max(1L, target.bottom - target.top);
    const bool same_size = (prev_w == next_w && prev_h == next_h);

    NotificationWindowState* state = EnsureSubclass(handles.host_hwnd, target);
    state->corner = corner;
    state->scale = scale;
    state->lock_bounds = false;

    const bool should_animate_enter = !was_visible || state->hidden_by_alpha ||
                                      state->anim_mode == AnimMode::kExit;
    if (should_animate_enter) {
      ApplyDwmStyling(handles.host_hwnd);
      const int start_x =
          (state->anim_mode == AnimMode::kExit)
              ? state->current_x
              : (target.left + SlideOffsetPx(*state, 48.0));
      if (!was_visible || state->hidden_by_alpha) {
        SetWindowAlpha(handles.host_hwnd, 0);
        state->current_alpha = 0;
      }
      ::SetWindowPos(handles.host_hwnd, HWND_TOPMOST, start_x, target.top,
                     next_w, next_h, SWP_NOACTIVATE | SWP_SHOWWINDOW);
      if (!same_size) {
        ::MoveWindow(handles.flutter_hwnd, 0, 0, next_w, next_h, TRUE);
      }
      StartEnterAnimation(handles.host_hwnd, state);
    } else if (state->anim_mode == AnimMode::kEnter) {
      state->anim_end_x = target.left;
      state->anim_y = target.top;
      if (!same_size) {
        ::SetWindowPos(handles.host_hwnd, HWND_TOPMOST, state->current_x,
                       target.top, next_w, next_h, SWP_NOACTIVATE);
        ::MoveWindow(handles.flutter_hwnd, 0, 0, next_w, next_h, TRUE);
      }
    } else {
      state->current_x = target.left;
      state->current_alpha = 255;
      if (same_size) {
        ::SetWindowPos(handles.host_hwnd, HWND_TOPMOST, target.left, target.top,
                       0, 0, SWP_NOSIZE | SWP_NOACTIVATE);
      } else {
        ::SetWindowPos(handles.host_hwnd, HWND_TOPMOST, target.left, target.top,
                       next_w, next_h, SWP_NOACTIVATE);
        ::MoveWindow(handles.flutter_hwnd, 0, 0, next_w, next_h, TRUE);
      }
    }
    return true;
  }

  bool HideWindow(const flutter::EncodableMap& args) const {
    const int64_t view_id = IntFromMap(args, "viewId");
    if (view_id < 0) return false;
    const WindowHandles handles = ResolveHandles(view_id);
    if (handles.host_hwnd == nullptr) return false;
    auto& states = WindowStates();
    auto it = states.find(handles.host_hwnd);
    if (it != states.end()) {
      StartExitAnimation(handles.host_hwnd, &it->second);
    } else {
      ::ShowWindow(handles.host_hwnd, SW_HIDE);
    }
    return true;
  }

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    if (call.method_name() == "captureForegroundWindow") {
      previous_foreground_ = ::GetForegroundWindow();
      result->Success();
      return;
    }
    if (call.method_name() == "cancelPrepare") {
      CancelPrepare();
      result->Success(flutter::EncodableValue(true));
      return;
    }
    if (call.method_name() == "isSystemDarkMode") {
      result->Success(flutter::EncodableValue(IsSystemDarkMode()));
      return;
    }

    const auto* arguments =
        std::get_if<flutter::EncodableMap>(call.arguments());
    if (arguments == nullptr) {
      result->Error("invalid_argument", "expects a map");
      return;
    }

    if (call.method_name() == "prepareForCreation") {
      result->Success(flutter::EncodableValue(PrepareForCreation(*arguments)));
    } else if (call.method_name() == "configure") {
      result->Success(flutter::EncodableValue(ConfigureWindow(*arguments)));
    } else if (call.method_name() == "reveal") {
      result->Success(flutter::EncodableValue(RevealWindow(*arguments)));
    } else if (call.method_name() == "updateBoundsAndShow") {
      result->Success(flutter::EncodableValue(UpdateBoundsAndShow(*arguments)));
    } else if (call.method_name() == "hide") {
      result->Success(flutter::EncodableValue(HideWindow(*arguments)));
    } else {
      result->NotImplemented();
    }
  }

  HWND previous_foreground_ = nullptr;
  std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

}  // namespace
}  // namespace neko_chat

void neko_chat::NotificationWindowManager::Register(
    flutter::BinaryMessenger* messenger) {
  static NotificationWindowManagerImpl* instance =
      new NotificationWindowManagerImpl();
  instance->Initialize(messenger);
}
