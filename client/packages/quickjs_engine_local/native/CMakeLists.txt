cmake_minimum_required(VERSION 3.10)

project(quickjs_engine_native LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_C_VISIBILITY_PRESET hidden)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ---------------------------------------------------------------- 优化开关
# 引擎必须永远按「发布版」编译。
#
# 这个库是 C，编译优化级别直接决定 QuickJS 的解析与执行速度：flutter run 出来的
# Debug 构建会把 CMake 配置成 Debug，MSVC 就是 /Od、GCC/Clang 就是不优化。实测
# 同一份 2.96MB 的插件，/Od 下要 22 秒才能编译完，差了两个数量级——用户在
# debug 里开发时感知到的「插件加载极慢」有一大半来自这里。
#
# /RTC1 与 /O2 互斥（MSVC 会直接报 D8016），所以 Debug 配置里的 /RTC1 要先摘掉；
# 剩下的 /Od 会被后面追加的 /O2 覆盖（命令行后者生效）。这里都是第三方 C 代码，
# 不需要单步调试它。
if(MSVC)
  string(REPLACE "/RTC1" "" CMAKE_C_FLAGS_DEBUG "${CMAKE_C_FLAGS_DEBUG}")
  string(REPLACE "/RTC1" "" CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG}")
  set(ENGINE_OPT_FLAGS
    "$<$<NOT:$<CONFIG:Release>>:/O2>"
    "$<$<NOT:$<CONFIG:Release>>:/Oi>"
    # 桥的注释是中文（UTF-8）：MSVC 默认按系统代码页（GBK）读源文件，UTF-8
    # 中文会被解成乱码字节，注释里冒出反斜杠时会把下一行也吞进注释，直接编不过。
    "/utf-8"
  )
else()
  set(ENGINE_OPT_FLAGS "$<$<NOT:$<CONFIG:Release>>:-O2>")
endif()

set(QJS_SOURCES
  ${CMAKE_CURRENT_SOURCE_DIR}/cxx/quickjs/quickjs.c
  ${CMAKE_CURRENT_SOURCE_DIR}/cxx/quickjs/libregexp.c
  ${CMAKE_CURRENT_SOURCE_DIR}/cxx/quickjs/libunicode.c
  ${CMAKE_CURRENT_SOURCE_DIR}/cxx/quickjs/dtoa.c
)

set(BRIDGE_SOURCES
  ${CMAKE_CURRENT_SOURCE_DIR}/cxx/libfastdev_quickjs_runtime.cpp
)

set(BRIDGE_NAME quickjs_c_bridge_plugin)

add_library(${BRIDGE_NAME} SHARED ${BRIDGE_SOURCES} ${QJS_SOURCES})

# 见文件开头「优化开关」：Debug/Profile 也按 /O2 编译引擎本身。
target_compile_options(${BRIDGE_NAME} PRIVATE ${ENGINE_OPT_FLAGS})

target_include_directories(${BRIDGE_NAME} PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/cxx
  ${CMAKE_CURRENT_SOURCE_DIR}/cxx/quickjs
)

target_compile_definitions(${BRIDGE_NAME} PRIVATE
  CONFIG_VERSION="ng-0.14.0"
)

set_target_properties(${BRIDGE_NAME} PROPERTIES
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden
  OUTPUT_NAME quickjs_c_bridge_plugin
)

if(APPLE)
  target_link_libraries(${BRIDGE_NAME} PRIVATE m)
  set_target_properties(${BRIDGE_NAME} PROPERTIES
    MACOSX_RPATH ON
    INSTALL_NAME_DIR "@rpath"
  )
elseif(UNIX)
  if(ANDROID)
    find_library(log-lib log)
    target_link_libraries(${BRIDGE_NAME} PRIVATE m ${log-lib})
    # NDK r28 and newer use 16 KB ELF LOAD alignment by default. Flutter
    # 3.38 still defaults to NDK r27, where these flags are required for the
    # resulting .so to run natively on Android devices with 16 KB pages.
    if(COMMAND target_link_options)
      target_link_options(${BRIDGE_NAME} PRIVATE
        "-Wl,-z,max-page-size=16384"
        "-Wl,-z,common-page-size=16384"
      )
    else()
      # target_link_options was introduced in CMake 3.13. Keep the plugin's
      # advertised CMake 3.10 minimum working for older host toolchains.
      set_property(TARGET ${BRIDGE_NAME} APPEND_STRING PROPERTY LINK_FLAGS
        " -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"
      )
    endif()
  else()
    target_link_libraries(${BRIDGE_NAME} PRIVATE m)
  endif()
elseif(WIN32)
  target_compile_definitions(${BRIDGE_NAME} PRIVATE _CRT_SECURE_NO_WARNINGS)
endif()

# Hint for plugin platform CMakeLists to bundle the produced .so
set(quickjs_engine_bundled_libraries
  $<TARGET_FILE:${BRIDGE_NAME}>
  PARENT_SCOPE
)
