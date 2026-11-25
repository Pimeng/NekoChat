#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void NotifyBossKeyVisibility(bool hidden);

  // The project to run.
  flutter::DartProject project_;

  // Shared-engine messenger used by the existing runner channels.
  std::unique_ptr<flutter::BinaryMessenger> messenger_;

  // Channel used to tell Dart that another instance was launched while this
  // one is still running.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      single_instance_channel_;

  // Registers the global Alt+F shortcut and reports hidden/visible changes.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      boss_key_channel_;
  // Syncs DWM dark mode title bars for main and detached windows.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_theme_channel_;
  bool boss_key_enabled_ = false;
  UINT boss_key_modifiers_ = MOD_ALT;
  UINT boss_key_virtual_key_ = 'F';
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
