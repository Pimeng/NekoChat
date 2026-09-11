#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

namespace neko_chat {

// Custom window message posted by a freshly launched instance to the already
// running one, asking it to come to the front. The value is stable for the
// lifetime of the process and shared by every instance of the application.
UINT ActivateInstanceMessage();

// Restores |window| (if needed) and brings it to the foreground. Best effort:
// Windows may refuse the foreground change unless the call is associated with
// the current foreground thread.
void BringWindowToForeground(HWND window);

// Enforces that only one instance of the application runs at a time.
//
// Returns true when another instance is already running. In that case the
// existing window is brought to the foreground (best effort) and asked to
// bring itself forward, and the caller must exit immediately. Returns false
// when this is the first instance and startup should continue normally.
bool FocusExistingInstanceOrStart();

}  // namespace neko_chat

#endif  // RUNNER_SINGLE_INSTANCE_H_
