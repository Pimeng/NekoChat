#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "single_instance.h"

namespace {

constexpr int kBossKeyHotKeyId = 0x4E4B;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Used by the runner to notify Dart about duplicate launches.
  single_instance_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "neko_chat/single_instance",
          &flutter::StandardMethodCodec::GetInstance());

  boss_key_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "neko_chat/boss_key",
          &flutter::StandardMethodCodec::GetInstance());
  boss_key_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "configure") {
          result->NotImplemented();
          return;
        }
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("invalid_argument", "configure expects a map");
          return;
        }
        const auto enabled_it =
            arguments->find(flutter::EncodableValue("enabled"));
        const auto modifiers_it =
            arguments->find(flutter::EncodableValue("modifiers"));
        const auto virtual_key_it =
            arguments->find(flutter::EncodableValue("virtualKey"));
        if (enabled_it == arguments->end() ||
            modifiers_it == arguments->end() ||
            virtual_key_it == arguments->end()) {
          result->Error("invalid_argument", "configure map is incomplete");
          return;
        }
        const auto* enabled = std::get_if<bool>(&enabled_it->second);
        auto read_integer = [](const flutter::EncodableValue& value,
                               int64_t* output) {
          if (const auto* int32_value = std::get_if<int32_t>(&value)) {
            *output = *int32_value;
            return true;
          }
          if (const auto* int64_value = std::get_if<int64_t>(&value)) {
            *output = *int64_value;
            return true;
          }
          return false;
        };
        int64_t modifiers_value = 0;
        int64_t virtual_key_value = 0;
        if (enabled == nullptr ||
            !read_integer(modifiers_it->second, &modifiers_value) ||
            !read_integer(virtual_key_it->second, &virtual_key_value) ||
            modifiers_value <= 0 ||
            (modifiers_value & ~(MOD_ALT | MOD_CONTROL | MOD_SHIFT | MOD_WIN)) !=
                0 ||
            virtual_key_value <= 0 || virtual_key_value > 0xff) {
          result->Error("invalid_argument", "invalid shortcut");
          return;
        }
        const UINT new_modifiers = static_cast<UINT>(modifiers_value);
        const UINT new_virtual_key = static_cast<UINT>(virtual_key_value);
        if (!*enabled) {
          if (boss_key_enabled_) {
            ::UnregisterHotKey(GetHandle(), kBossKeyHotKeyId);
          }
          boss_key_enabled_ = false;
          boss_key_modifiers_ = new_modifiers;
          boss_key_virtual_key_ = new_virtual_key;
          result->Success();
          return;
        }
        if (boss_key_enabled_ && new_modifiers == boss_key_modifiers_ &&
            new_virtual_key == boss_key_virtual_key_) {
          result->Success();
          return;
        }
        const bool was_enabled = boss_key_enabled_;
        const UINT old_modifiers = boss_key_modifiers_;
        const UINT old_virtual_key = boss_key_virtual_key_;
        if (was_enabled) {
          ::UnregisterHotKey(GetHandle(), kBossKeyHotKeyId);
        }
        if (!::RegisterHotKey(GetHandle(), kBossKeyHotKeyId,
                              new_modifiers | MOD_NOREPEAT,
                              new_virtual_key)) {
          boss_key_enabled_ =
              was_enabled &&
              ::RegisterHotKey(GetHandle(), kBossKeyHotKeyId,
                               old_modifiers | MOD_NOREPEAT, old_virtual_key);
          result->Error("hotkey_conflict",
                        "The shortcut is already registered by another app");
          return;
        }
        boss_key_enabled_ = true;
        boss_key_modifiers_ = new_modifiers;
        boss_key_virtual_key_ = new_virtual_key;
        result->Success();
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (boss_key_enabled_) {
    ::UnregisterHotKey(GetHandle(), kBossKeyHotKeyId);
    boss_key_enabled_ = false;
  }
  boss_key_channel_ = nullptr;
  single_instance_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // A second instance was launched: bring this window to the front.
  if (message == neko_chat::ActivateInstanceMessage()) {
    neko_chat::BringWindowToForeground(hwnd);
    NotifyBossKeyVisibility(false);
    if (single_instance_channel_) {
      single_instance_channel_->InvokeMethod(
          "alreadyRunning", std::make_unique<flutter::EncodableValue>());
    }
    return 0;
  }

  if (message == WM_HOTKEY && wparam == kBossKeyHotKeyId &&
      boss_key_enabled_) {
    const bool hide = ::IsWindowVisible(hwnd) != FALSE;
    if (hide) {
      ::ShowWindow(hwnd, SW_HIDE);
    } else {
      neko_chat::BringWindowToForeground(hwnd);
    }
    NotifyBossKeyVisibility(hide);
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::NotifyBossKeyVisibility(bool hidden) {
  if (!boss_key_channel_) {
    return;
  }
  boss_key_channel_->InvokeMethod(
      "visibilityChanged",
      std::make_unique<flutter::EncodableValue>(hidden));
}
