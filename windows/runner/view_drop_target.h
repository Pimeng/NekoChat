#ifndef RUNNER_VIEW_DROP_TARGET_H_
#define RUNNER_VIEW_DROP_TARGET_H_

#include <flutter/binary_messenger.h>

namespace neko_chat {

// Registers the "neko_chat/view_drop" method channel and manages OLE drop
// targets for multiview_desktop secondary windows.
//
// The desktop_drop plugin only registers a drop target for the primary view,
// so files dragged onto an independent conversation window are never
// delivered to Dart. This manager lets Dart register a drop target for any
// extra view; enter/leave/drop events are forwarded back over the channel
// with the public view id.
class ViewDropTargetManager {
 public:
  static void Register(flutter::BinaryMessenger* messenger);
};

}  // namespace neko_chat

#endif  // RUNNER_VIEW_DROP_TARGET_H_
