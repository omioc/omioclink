cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
# 原生崩溃报告：MiniDumpWriteDump / StackWalk64（见 runner/utils.cpp）
target_link_libraries(${BINARY_NAME} PRIVATE "dbghelp.lib")
# 运行库版本读取：GetFileVersionInfoW / VerQueryValueW
target_link_libraries(${BINARY_NAME} PRIVATE "version.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# 主线程栈加大到 8MB（MSVC 默认 1MB）。
#
# QuickJS 里深递归的插件（真实案例：1.4MB 的六源聚合插件）会先把**原生**线程栈耗尽，
# 引擎自己的 JS 栈上限检查来不及生效，表现为整个进程消失
# （Windows 事件：quickjs 桥 0xc00000fd / STACK_OVERFLOW）。
# 栈给到 8MB 后，QuickJS 的 1MB JS 栈上限会先触发，深递归变成可捕获的 RangeError，
# 插件调用回落成普通错误提示，不至于把客户端带走。
if (MSVC)
  target_link_options(${BINARY_NAME} PRIVATE "/STACK:8388608")
endif()

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
