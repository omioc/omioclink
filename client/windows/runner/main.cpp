#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // 原生崩溃要在引擎起来之前就布好网：这类异常会把进程直接带走，
  // Dart 侧的日志与异常钩子都来不及说话。
  InstallCrashHandler();
  // 顺带记下「这台机器实际加载的是哪份 C++ 运行库」——插件是 C++ 写的，
  // 运行库版本不匹配时崩溃点会出现在 MSVCP140 里（见 utils.cpp）。
  LogRuntimeInfo();

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"omioclink_client", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // 引擎（以及它的插件，如 flutter_webrtc_plugin.dll）此刻已经加载，
  // 再记一次运行库信息——这时才看得到插件实际用的是哪份 msvcp140.dll。
  LogRuntimeInfo();

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
