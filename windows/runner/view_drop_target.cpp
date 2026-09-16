#include "view_drop_target.h"

#include <windows.h>
#include <ole2.h>
#include <oleidl.h>
#include <shellapi.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <multiview_desktop/multi_view_desktop_plugin.h>

#include <map>
#include <memory>
#include <string>
#include <vector>

namespace neko_chat {
namespace {

constexpr char kChannelName[] = "neko_chat/view_drop";

int64_t IntFromMap(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return -1;
  if (const auto* value32 = std::get_if<int32_t>(&it->second)) return *value32;
  if (const auto* value64 = std::get_if<int64_t>(&it->second)) return *value64;
  return -1;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                       value.data(),
                                       static_cast<int>(value.size()), nullptr,
                                       0, nullptr, nullptr);
  if (size <= 0) return {};
  std::string result(size, 0);
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), result.data(), size,
                      nullptr, nullptr);
  return result;
}

class ViewDropTarget : public IDropTarget {
 public:
  ViewDropTarget(std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>>
                     channel,
                 int64_t public_view_id, HWND window)
      : channel_(std::move(channel)),
        public_view_id_(public_view_id),
        window_(window) {}

  HRESULT DragEnter(IDataObject* data_object, DWORD key_state, POINTL point,
                    DWORD* effect) override {
    Emit("enter", {});
    return S_OK;
  }

  HRESULT DragOver(DWORD key_state, POINTL point, DWORD* effect) override {
    return S_OK;
  }

  HRESULT DragLeave() override {
    Emit("leave", {});
    return S_OK;
  }

  HRESULT Drop(IDataObject* data_object, DWORD key_state, POINTL point,
               DWORD* effect) override {
    std::vector<std::string> paths;
    FORMATETC format = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    STGMEDIUM medium;
    if (data_object->QueryGetData(&format) == S_OK &&
        data_object->GetData(&format, &medium) == S_OK) {
      if (auto* drop = static_cast<HDROP>(GlobalLock(medium.hGlobal))) {
        const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
        for (UINT index = 0; index < count; ++index) {
          const UINT length = DragQueryFileW(drop, index, nullptr, 0);
          std::wstring buffer(length + 1, L'\0');
          DragQueryFileW(drop, index, buffer.data(), length + 1);
          buffer.resize(length);
          paths.push_back(WideToUtf8(buffer));
        }
        GlobalUnlock(medium.hGlobal);
      }
      ReleaseStgMedium(&medium);
    }
    Emit("drop", paths);
    return S_OK;
  }

  HRESULT QueryInterface(const IID& iid, void** object) override {
    if (iid == IID_IDropTarget || iid == IID_IUnknown) {
      AddRef();
      *object = this;
      return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
  }

  HWND window() const { return window_; }

  ULONG AddRef() override { return InterlockedIncrement(&ref_count_); }

  ULONG Release() override {
    const LONG count = InterlockedDecrement(&ref_count_);
    if (count == 0) {
      delete this;
      return 0;
    }
    return count;
  }

 private:
  ~ViewDropTarget() = default;

  void Emit(const char* type, const std::vector<std::string>& paths) {
    if (!channel_) return;
    flutter::EncodableMap event = {
        {flutter::EncodableValue("viewId"),
         flutter::EncodableValue(public_view_id_)},
        {flutter::EncodableValue("type"), flutter::EncodableValue(type)},
    };
    if (!paths.empty()) {
      flutter::EncodableList list;
      list.reserve(paths.size());
      for (const auto& path : paths) {
        list.push_back(flutter::EncodableValue(path));
      }
      event[flutter::EncodableValue("paths")] = flutter::EncodableValue(list);
    }
    channel_->InvokeMethod(
        "event", std::make_unique<flutter::EncodableValue>(event));
  }

  std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  int64_t public_view_id_;
  HWND window_;
  LONG ref_count_ = 1;
};

class ViewDropTargetManagerImpl {
 public:
  void Initialize(flutter::BinaryMessenger* messenger) {
    OleInitialize(nullptr);
    channel_ = std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
        messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler(
        [this](const auto& call, auto result) {
          HandleMethodCall(call, std::move(result));
        });
  }

 private:
  // Public ids on Windows are shifted by one relative to the native real view
  // id used by multiview_desktop (the main real view starts at 0).
  int64_t ToRealViewId(int64_t public_view_id) const {
    return public_view_id + MultiViewDesktopGetMainViewId() - 1;
  }

  int64_t ToPublicViewId(int64_t real_view_id) const {
    return real_view_id - MultiViewDesktopGetMainViewId() + 1;
  }

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    const auto* arguments =
        std::get_if<flutter::EncodableMap>(call.arguments());
    if (arguments == nullptr) {
      result->Error("invalid_argument", "expects a map");
      return;
    }
    const int64_t public_view_id = IntFromMap(*arguments, "viewId");
    if (public_view_id < 0) {
      result->Error("invalid_argument", "missing viewId");
      return;
    }
    if (call.method_name() == "register") {
      result->Success(flutter::EncodableValue(RegisterView(public_view_id)));
    } else if (call.method_name() == "unregister") {
      UnregisterView(public_view_id);
      result->Success();
    } else {
      result->NotImplemented();
    }
  }

  bool RegisterView(int64_t public_view_id) {
    if (targets_.find(public_view_id) != targets_.end()) return true;
    const HWND window =
        MultiViewDesktopGetFlutterHwnd(ToRealViewId(public_view_id));
    if (window == nullptr) return false;
    auto* target = new ViewDropTarget(channel_, public_view_id, window);
    const HRESULT registered = RegisterDragDrop(window, target);
    if (registered != S_OK) {
      target->Release();
      return false;
    }
    targets_[public_view_id] = target;
    return true;
  }

  void UnregisterView(int64_t public_view_id) {
    const auto it = targets_.find(public_view_id);
    if (it == targets_.end()) return;
    RevokeDragDrop(it->second->window());
    it->second->Release();
    targets_.erase(it);
  }

  std::map<int64_t, ViewDropTarget*> targets_;
  std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

}  // namespace
}  // namespace neko_chat

void neko_chat::ViewDropTargetManager::Register(
    flutter::BinaryMessenger* messenger) {
  static ViewDropTargetManagerImpl* instance = new ViewDropTargetManagerImpl();
  instance->Initialize(messenger);
}
