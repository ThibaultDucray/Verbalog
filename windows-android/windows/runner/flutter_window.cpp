#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

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

  loopback_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "verbalog/loopback",
      &flutter::StandardMethodCodec::GetInstance());
  loopback_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const std::string& method = call.method_name();
        if (method == "start") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          std::string path;
          if (args) {
            auto it = args->find(flutter::EncodableValue("path"));
            if (it != args->end()) {
              if (const auto* s = std::get_if<std::string>(&it->second)) path = *s;
            }
          }
          if (path.empty()) {
            result->Error("bad_args", "path is required");
            return;
          }
          int n = MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, nullptr, 0);
          std::wstring wide(n > 0 ? n - 1 : 0, L'\0');
          if (n > 1) MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, wide.data(), n);
          std::string error = loopback_.Start(wide);
          if (error.empty()) {
            result->Success();
          } else {
            result->Error("loopback", error);
          }
        } else if (method == "pause") {
          loopback_.Pause();
          result->Success();
        } else if (method == "resume") {
          loopback_.Resume();
          result->Success();
        } else if (method == "stop") {
          loopback_.Stop();
          result->Success();
        } else if (method == "level") {
          result->Success(flutter::EncodableValue(loopback_.LevelDb()));
        } else {
          result->NotImplemented();
        }
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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
  loopback_.Stop();
  loopback_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
