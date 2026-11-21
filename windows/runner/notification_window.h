#ifndef RUNNER_NOTIFICATION_WINDOW_H_
#define RUNNER_NOTIFICATION_WINDOW_H_

#include <flutter/binary_messenger.h>

namespace neko_chat {

// Registers the "neko_chat/notification_window" method channel so Dart can
// turn a secondary multiview_desktop window into a frameless, non-activating,
// taskbar-hidden, always-on-top Windows toast popup anchored to the work area.
class NotificationWindowManager {
 public:
  static void Register(flutter::BinaryMessenger* messenger);
};

}  // namespace neko_chat

#endif  // RUNNER_NOTIFICATION_WINDOW_H_
