#include "flutter_window.h"

#include <dwmapi.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// 窗口最外侧那一圈细线是 DWM 画的，不是 Flutter 画的，所以 Dart 侧动不了。
// 本应用是自绘标题栏的无边框窗口，系统仍会在最外圈描一道浅色边框——
// 贴着深色界面看就是「套了个相框」，本意却是让卡片浮在桌面上。
// DWMWA_BORDER_COLOR 是 Windows 11 (22000+) 的属性，设成 DWMWA_COLOR_NONE
// 就是「不画边框」；Win10 上这次调用直接失败，行为与原来一致。
#ifndef DWMWA_BORDER_COLOR
#define DWMWA_BORDER_COLOR 34
#endif
constexpr DWORD kDwmBorderNone = 0xFFFFFFFE;  // DWMWA_COLOR_NONE

void RemoveWindowBorder(HWND window) {
  if (window == nullptr) {
    return;
  }
  const DWORD color = kDwmBorderNone;
  DwmSetWindowAttribute(window, DWMWA_BORDER_COLOR, &color, sizeof(color));
}

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

  // 建窗时就先关一次边框；window_manager 之后会为「无边框标题栏」重构窗口
  // （SWP_FRAMECHANGED），边框可能被系统重新画回来，所以 Dart 侧启动完还会
  // 通过下面这个通道再压一次。
  RemoveWindowBorder(GetHandle());
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "omioclink/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "removeFrameBorder") {
          RemoveWindowBorder(GetHandle());
          result->Success();
          return;
        }
        result->NotImplemented();
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
  // 通道比引擎先活：messenger 属于引擎，引擎拆掉后回调就不能再挂着
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // window_manager 处理 WM_NCCALCSIZE 时会往客户区顶部塞 1px：它想在 Windows 10
  // 上避开「顶部白线」，但 `IsWindows11OrGreater()` 里的判断写反了（返回的是
  // build < 22000），于是 Win11 上反而留了那一像素——就是标题栏上方那道细线。
  // 这里在插件算完之后把它还给客户区；它给窗口缩放留的左侧/右侧/底部 8px 不动。
  const bool mayNeedTopFix = message == WM_NCCALCSIZE && wparam == TRUE;
  LONG proposed_top = 0;
  if (mayNeedTopFix) {
    proposed_top = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam)->rgrc[0].top;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      if (mayNeedTopFix) {
        auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
        // 只削掉「正好多出来的那 1px」：最大化时插件走的是另一套调整，别碰
        if (params->rgrc[0].top == proposed_top + 1) {
          params->rgrc[0].top = proposed_top;
        }
      }
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
