#include "utils.h"

#include <flutter_windows.h>
#include <io.h>
#include <stdio.h>
#include <windows.h>

#include <dbghelp.h>
#include <tlhelp32.h>

#include <exception>
#include <iostream>
#include <string>
#include <vector>

void CreateAndAttachConsole() {
  if (::AllocConsole()) {
    FILE *unused;
    if (freopen_s(&unused, "CONOUT$", "w", stdout)) {
      _dup2(_fileno(stdout), 1);
    }
    if (freopen_s(&unused, "CONOUT$", "w", stderr)) {
      _dup2(_fileno(stdout), 2);
    }
    std::ios::sync_with_stdio();
    FlutterDesktopResyncOutputStreams();
  }
}

std::vector<std::string> GetCommandLineArguments() {
  // Convert the UTF-16 command line arguments to UTF-8 for the Engine to use.
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::vector<std::string>();
  }

  std::vector<std::string> command_line_arguments;

  // Skip the first argument as it's the binary name.
  for (int i = 1; i < argc; i++) {
    command_line_arguments.push_back(Utf8FromUtf16(argv[i]));
  }

  ::LocalFree(argv);

  return command_line_arguments;
}

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return std::string();
  }
  // First, find the length of the string with a safe upper bound (CWE-126).
  // UNICODE_STRING_MAX_CHARS (32767) is the maximum length of a UNICODE_STRING.
  int input_length = static_cast<int>(wcsnlen(utf16_string, UNICODE_STRING_MAX_CHARS));
  // Now use that bounded length to determine the required buffer size.
  // When an explicit length is passed, WideCharToMultiByte does not include
  // the null terminator in its returned size.
  int target_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, nullptr, 0, nullptr, nullptr);
  std::string utf8_string;
  if (target_length == 0 || static_cast<size_t>(target_length) > utf8_string.max_size()) {
    return utf8_string;
  }
  utf8_string.resize(target_length);
  int converted_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, utf8_string.data(), target_length, nullptr, nullptr);
  if (converted_length == 0) {
    return std::string();
  }
  return utf8_string;
}

namespace {

// ---------------------------------------------------------------------------
// 原生崩溃报告
// ---------------------------------------------------------------------------
//
// 访问违例、非法指令这类异常会把进程直接带走，Dart 侧一行日志都留不下——出了
// 故障的那台机器上只剩这份报告能说话。报告写进 Dart 运行日志所在的同一个目录
// （与 `lib/core/log_file.dart` 的 `LogFile.defaultDirectory()` 同一套规则，
// 改这里要一起改），内容包括异常码、出错地址所在模块、访问类型和调用栈。

// %LOCALAPPDATA%\OmiocLink\logs；拿不到环境变量时退回 exe 目录下的 logs。
std::wstring CrashLogDirectory() {
  wchar_t buffer[32767];
  DWORD length = ::GetEnvironmentVariableW(L"LOCALAPPDATA", buffer, 32767);
  if (length > 0 && length < 32767) {
    return std::wstring(buffer, length) + L"\\OmiocLink\\logs";
  }
  wchar_t module_path[MAX_PATH] = {0};
  DWORD module_length = ::GetModuleFileNameW(nullptr, module_path, MAX_PATH);
  std::wstring exe_path(module_path, module_length);
  size_t slash = exe_path.find_last_of(L"\\/");
  if (slash != std::wstring::npos) {
    exe_path.erase(slash);
  }
  return exe_path + L"\\logs";
}

// CreateDirectoryW 不创建中间层，逐级来一遍。
void EnsureDirectory(const std::wstring& directory) {
  for (size_t i = 1; i <= directory.size(); ++i) {
    if (i != directory.size() && directory[i] != L'\\' &&
        directory[i] != L'/') {
      continue;
    }
    ::CreateDirectoryW(directory.substr(0, i).c_str(), nullptr);
  }
}

// 地址 -> `模块名+0x偏移`。这是报告里最关键的一行：它指出崩在哪个 DLL。
std::string DescribeAddress(const void* address) {
  HMODULE module = nullptr;
  if (::GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                               GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           reinterpret_cast<LPCWSTR>(address), &module) &&
      module != nullptr) {
    wchar_t path[MAX_PATH] = {0};
    DWORD length = ::GetModuleFileNameW(module, path, MAX_PATH);
    std::wstring name(path, length);
    size_t slash = name.find_last_of(L"\\/");
    if (slash != std::wstring::npos) {
      name.erase(0, slash + 1);
    }
    const auto* base = reinterpret_cast<const unsigned char*>(module);
    const auto* at = reinterpret_cast<const unsigned char*>(address);
    char offset[32];
    _snprintf_s(offset, sizeof(offset), _TRUNCATE, "+0x%llX",
                static_cast<unsigned long long>(at - base));
    return Utf8FromUtf16(name.c_str()) + offset;
  }
  char raw[32];
  _snprintf_s(raw, sizeof(raw), _TRUNCATE, "%p", address);
  return raw;
}

// 崩溃线程的栈只能说「谁崩了」；真正决定怎么修的是**平台线程（主线程）**
// 当时在干什么——比如是不是正在销毁插件/拆引擎。这个 id 在安装处理器时记下。
DWORD g_platform_thread_id = 0;

// 本次运行的 native 日志路径（首次写入时确定，后续追加到同一份）。
std::wstring g_native_log_path;

// 把某个线程的调用栈（模块+偏移）写进报告。
//
// 注意：dbghelp 的符号初始化会碰加载器锁，**只能在扩展报告线程里调用**。
// 早期版本把它放在崩溃线程上直接跑，探针实测会死锁（报告 0 字节、进程卡住）——
// 「闪退」因此变成「卡死」，比崩溃还糟。
void DumpThreadStack(DWORD thread_id, std::string* out) {
  if (thread_id == 0 || thread_id == ::GetCurrentThreadId()) {
    *out += "  （与当前线程相同，见上面的崩溃线程栈）\n";
    return;
  }
  HANDLE thread = ::OpenThread(
      THREAD_GET_CONTEXT | THREAD_SUSPEND_RESUME | THREAD_QUERY_INFORMATION,
      FALSE, thread_id);
  if (thread == nullptr) {
    *out += "  （打不开该线程）\n";
    return;
  }
  if (::SuspendThread(thread) == static_cast<DWORD>(-1)) {
    *out += "  （挂起该线程失败）\n";
    ::CloseHandle(thread);
    return;
  }
  CONTEXT context = {};
  context.ContextFlags = CONTEXT_FULL;
  if (!::GetThreadContext(thread, &context)) {
    *out += "  （读取线程上下文失败）\n";
    ::ResumeThread(thread);
    ::CloseHandle(thread);
    return;
  }

  ::SymSetOptions(SYMOPT_UNDNAME | SYMOPT_DEFERRED_LOADS);
  ::SymInitialize(::GetCurrentProcess(), nullptr, TRUE);

  STACKFRAME64 frame = {};
  frame.AddrPC.Offset = context.Rip;
  frame.AddrPC.Mode = AddrModeFlat;
  frame.AddrFrame.Offset = context.Rbp;
  frame.AddrFrame.Mode = AddrModeFlat;
  frame.AddrStack.Offset = context.Rsp;
  frame.AddrStack.Mode = AddrModeFlat;

  for (int index = 0; index < 40; ++index) {
    if (!::StackWalk64(IMAGE_FILE_MACHINE_AMD64, ::GetCurrentProcess(), thread,
                       &frame, &context, nullptr, ::SymFunctionTableAccess64,
                       ::SymGetModuleBase64, nullptr)) {
      break;
    }
    if (frame.AddrPC.Offset == 0) {
      break;
    }
    *out += "  #" + std::to_string(index) + " " +
            DescribeAddress(
                reinterpret_cast<const void*>(frame.AddrPC.Offset)) +
            "\n";
  }

  ::ResumeThread(thread);
  ::CloseHandle(thread);
}

// 取文件版本号（形如 `14.51.36247.0`）；读不到时返回空串。
std::string FileVersionOf(const std::wstring& path) {
  DWORD handle = 0;
  const DWORD size = ::GetFileVersionInfoSizeW(path.c_str(), &handle);
  if (size == 0) {
    return std::string();
  }
  std::vector<unsigned char> buffer(size);
  if (!::GetFileVersionInfoW(path.c_str(), 0, size, buffer.data())) {
    return std::string();
  }
  VS_FIXEDFILEINFO* info = nullptr;
  UINT length = 0;
  if (!::VerQueryValueW(buffer.data(), L"\\",
                        reinterpret_cast<LPVOID*>(&info),
                        &length) ||
      info == nullptr) {
    return std::string();
  }
  char text[64];
  _snprintf_s(text, sizeof(text), _TRUNCATE, "%u.%u.%u.%u",
              static_cast<unsigned>(HIWORD(info->dwFileVersionMS)),
              static_cast<unsigned>(LOWORD(info->dwFileVersionMS)),
              static_cast<unsigned>(HIWORD(info->dwFileVersionLS)),
              static_cast<unsigned>(LOWORD(info->dwFileVersionLS)));
  return text;
}

// 已加载模块清单（名称/基址/大小）。同一份崩溃报告在不同机器上出现不一样的
// 运行库版本时，这一节就是证据（例如 msvcp140.dll 的版本差异）。
//
// [crt_only] 只写 C++ 运行库（msvcp/vcruntime/ucrtbase/concrt），并带上完整
// 路径与文件版本——「这台机器到底用的哪份运行库」是这类 ABI 问题的第一现场。
void DumpModuleList(std::string* out, bool crt_only = false) {
  *out += crt_only ? "C++ 运行库（实际加载）:\n" : "模块（名称 基址 大小）:\n";
  HANDLE snapshot =
      ::CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, ::GetCurrentProcessId());
  if (snapshot == INVALID_HANDLE_VALUE) {
    *out += "  （枚举模块失败）\n";
    return;
  }
  MODULEENTRY32W entry = {};
  entry.dwSize = sizeof(entry);
  if (::Module32FirstW(snapshot, &entry)) {
    do {
      const std::string name = Utf8FromUtf16(entry.szModule);
      // 模块名的原始大小写不固定（`MSVCP140.dll` / `vcruntime140.dll`），
      // 过滤前先转小写，否则会把大写的那几个运行库整个漏掉。
      std::string lower = name;
      for (char& ch : lower) {
        ch = static_cast<char>(::tolower(static_cast<unsigned char>(ch)));
      }
      char line[1024];
      // 运行库（msvcp/vcruntime/ucrtbase/concrt）连同**完整路径**一起写：
      // 「这台机器用的是哪份 C++ 运行库」是排查 ABI/版本问题的第一现场。
      const bool is_crt = lower.rfind("msvcp", 0) == 0 ||
                          lower.rfind("vcruntime", 0) == 0 ||
                          lower.rfind("concrt", 0) == 0 ||
                          lower.rfind("ucrtbase", 0) == 0;
      if (crt_only && !is_crt) {
        continue;
      }
      const std::wstring path(entry.szExePath);
      if (is_crt) {
        const std::string version = FileVersionOf(path);
        _snprintf_s(line, sizeof(line), _TRUNCATE,
                    "  %s 0x%llX %uKB %s\n    %s\n", name.c_str(),
                    static_cast<unsigned long long>(reinterpret_cast<
                        unsigned long long>(entry.modBaseAddr)),
                    static_cast<unsigned>(entry.modBaseSize / 1024),
                    version.c_str(), Utf8FromUtf16(entry.szExePath).c_str());
      } else {
        _snprintf_s(line, sizeof(line), _TRUNCATE, "  %s 0x%llX %uKB\n",
                    name.c_str(),
                    static_cast<unsigned long long>(reinterpret_cast<
                        unsigned long long>(entry.modBaseAddr)),
                    static_cast<unsigned>(entry.modBaseSize / 1024));
      }
      *out += line;
    } while (::Module32NextW(snapshot, &entry));
  }
  ::CloseHandle(snapshot);
}

// 启动时写一份「原生运行信息」小文件。
//
// 崩溃只在某些机器上复现时，第一个要问的问题就是「那台机器加载的是哪一版
// C++ 运行库」——这里在启动时就给出答案，不用等崩溃，也便于确认修复生效
// （例如是否用上了随包发布的 app-local msvcp140.dll）。
void WriteRuntimeInfo() {
  const std::wstring directory = CrashLogDirectory();
  EnsureDirectory(directory);
  SYSTEMTIME time;
  ::GetLocalTime(&time);

  // 文件名只算一次：这个方法会在「进程起来」与「引擎/插件加载完」各调一次，
  // 两次内容要落到同一个文件里（第二次才看得到 MSVCP140 这些插件依赖的运行库）。
  if (g_native_log_path.empty()) {
    wchar_t file_name[128];
    ::swprintf_s(file_name, L"native-%04u%02u%02u-%02u%02u%02u-%lu.log",
                 static_cast<unsigned>(time.wYear),
                 static_cast<unsigned>(time.wMonth),
                 static_cast<unsigned>(time.wDay),
                 static_cast<unsigned>(time.wHour),
                 static_cast<unsigned>(time.wMinute),
                 static_cast<unsigned>(time.wSecond),
                 static_cast<unsigned long>(::GetCurrentProcessId()));
    g_native_log_path = directory + L"\\" + file_name;
  }

  std::string text = "\nomioclink 原生运行信息\n";
  char line[1024];
  _snprintf_s(line, sizeof(line), _TRUNCATE,
              "时间: %04u-%02u-%02u %02u:%02u:%02u 进程: pid=%lu\n",
              static_cast<unsigned>(time.wYear),
              static_cast<unsigned>(time.wMonth),
              static_cast<unsigned>(time.wDay),
              static_cast<unsigned>(time.wHour),
              static_cast<unsigned>(time.wMinute),
              static_cast<unsigned>(time.wSecond),
              static_cast<unsigned long>(::GetCurrentProcessId()));
  text += line;
  wchar_t exe_path[MAX_PATH] = {0};
  ::GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
  text += "可执行文件: " + Utf8FromUtf16(exe_path) + "\n";
  DumpModuleList(&text, true);

  HANDLE file = ::CreateFileW(g_native_log_path.c_str(), GENERIC_WRITE,
                              FILE_SHARE_READ, nullptr, OPEN_ALWAYS,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }
  ::SetFilePointer(file, 0, nullptr, FILE_END);
  DWORD written = 0;
  ::WriteFile(file, text.data(), static_cast<DWORD>(text.size()), &written,
              nullptr);
  ::CloseHandle(file);
}

// 崩溃现场的「扩展信息」：minidump、模块清单、平台线程栈。
struct CrashReportJob {
  std::wstring report_path;
  std::wstring dump_path;
  DWORD platform_thread_id = 0;
  bool has_exception = false;
  MINIDUMP_EXCEPTION_INFORMATION exception = {};
};

CrashReportJob g_crash_job;

// 往报告尾部追加一段文本。每段单独打开/关闭：前面的内容一旦落盘，后面就算
// 卡住也不会把它丢掉。
void AppendToReport(const std::wstring& path, const std::string& text) {
  HANDLE file = ::CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                              nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }
  DWORD written = 0;
  ::WriteFile(file, text.data(), static_cast<DWORD>(text.size()), &written,
              nullptr);
  ::CloseHandle(file);
}

// 危险动作（写 minidump、枚举模块、符号栈回溯）全放在这个线程里做：崩溃线程上
// 做这些事可能卡在加载器锁或堆上，把「闪退」拖成「卡死」——探针实测过一次。
// 主线程只等一段有限时间，而核心报告此时已经落盘。
DWORD WINAPI WriteCrashExtrasProc(LPVOID parameter) {
  auto* job = static_cast<CrashReportJob*>(parameter);

  // 1) 全线程转储：信息量最大，且不依赖 dbghelp 的符号初始化
  HANDLE dump = ::CreateFileW(job->dump_path.c_str(), GENERIC_WRITE,
                              FILE_SHARE_READ, nullptr, CREATE_ALWAYS,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
  if (dump != INVALID_HANDLE_VALUE) {
    const auto type = static_cast<MINIDUMP_TYPE>(
        MiniDumpNormal | MiniDumpWithThreadInfo | MiniDumpWithUnloadedModules |
        MiniDumpWithProcessThreadData);
    ::MiniDumpWriteDump(::GetCurrentProcess(), ::GetCurrentProcessId(), dump,
                        type, job->has_exception ? &job->exception : nullptr,
                        nullptr, nullptr);
    ::CloseHandle(dump);
  }

  // 2) 模块清单：用来看「那台机器的运行库是不是和开发机同一版」
  std::string modules;
  DumpModuleList(&modules);
  AppendToReport(job->report_path, modules);

  // 3) 平台（主）线程栈：最容易卡住的一步，放最后
  std::string platform_stack = "平台（主）线程调用栈:\n";
  DumpThreadStack(job->platform_thread_id, &platform_stack);
  AppendToReport(job->report_path, platform_stack);
  return 0;
}

// 只写第一份报告：同一个崩溃可能被多个线程/多层 handler 重复上报。
volatile LONG g_crash_reported = 0;

void WriteCrashReport(const char* reason, const EXCEPTION_POINTERS* info) {
  if (::InterlockedExchange(&g_crash_reported, 1) != 0) {
    return;
  }
  const std::wstring directory = CrashLogDirectory();
  EnsureDirectory(directory);

  SYSTEMTIME time;
  ::GetLocalTime(&time);
  wchar_t file_name[128];
  ::swprintf_s(file_name, L"crash-%04u%02u%02u-%02u%02u%02u-%lu.log",
               static_cast<unsigned>(time.wYear),
               static_cast<unsigned>(time.wMonth),
               static_cast<unsigned>(time.wDay),
               static_cast<unsigned>(time.wHour),
               static_cast<unsigned>(time.wMinute),
               static_cast<unsigned>(time.wSecond),
               static_cast<unsigned long>(::GetCurrentProcessId()));
  HANDLE file = ::CreateFileW((directory + L"\\" + file_name).c_str(),
                              GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }

  char line[512];
  std::string text = "omioclink 原生崩溃报告\n";
  _snprintf_s(line, sizeof(line), _TRUNCATE,
              "时间: %04u-%02u-%02u %02u:%02u:%02u\n",
              static_cast<unsigned>(time.wYear),
              static_cast<unsigned>(time.wMonth),
              static_cast<unsigned>(time.wDay),
              static_cast<unsigned>(time.wHour),
              static_cast<unsigned>(time.wMinute),
              static_cast<unsigned>(time.wSecond));
  text += line;
  _snprintf_s(line, sizeof(line), _TRUNCATE, "原因: %s\n", reason);
  text += line;
  _snprintf_s(line, sizeof(line), _TRUNCATE, "进程: pid=%lu 线程=%lu\n",
              static_cast<unsigned long>(::GetCurrentProcessId()),
              static_cast<unsigned long>(::GetCurrentThreadId()));
  text += line;

  if (info != nullptr && info->ExceptionRecord != nullptr) {
    const EXCEPTION_RECORD* record = info->ExceptionRecord;
    _snprintf_s(line, sizeof(line), _TRUNCATE, "异常码: 0x%08lX\n",
                static_cast<unsigned long>(record->ExceptionCode));
    text += line;
    text += "异常地址: " + DescribeAddress(record->ExceptionAddress) + "\n";
    if (record->ExceptionCode == EXCEPTION_ACCESS_VIOLATION &&
        record->NumberParameters >= 2) {
      const char* operation = "未知";
      switch (record->ExceptionInformation[0]) {
        case 0:
          operation = "读取";
          break;
        case 1:
          operation = "写入";
          break;
        case 8:
          operation = "执行";
          break;
        default:
          break;
      }
      _snprintf_s(line, sizeof(line), _TRUNCATE, "访问类型: %s 目标地址: %p\n",
                  operation,
                  reinterpret_cast<const void*>(record->ExceptionInformation[1]));
      text += line;
    }
  }

  // 调用栈只有「模块+偏移」——没有 PDB 也能看出是崩在 libwebrtc.dll 还是
  // flutter_windows.dll 里，越靠前越接近崩溃点。
  void* frames[32] = {0};
  USHORT count = ::CaptureStackBackTrace(0, 32, frames, nullptr);
  text += "崩溃线程调用栈（模块+偏移）:\n";
  for (USHORT i = 0; i < count; ++i) {
    text += "  #" + std::to_string(static_cast<unsigned>(i)) + " " +
            DescribeAddress(frames[i]) + "\n";
  }

  text += "崩溃前的操作见同目录 client-*.log 的最后几行\n";
  text += "扩展信息（模块清单 / 平台线程栈 / crash-*.dmp 全线程转储）随后追加\n";

  DWORD written = 0;
  ::WriteFile(file, text.data(), static_cast<DWORD>(text.size()), &written,
              nullptr);
  ::CloseHandle(file);

  // 到这一步核心报告（异常码 / 地址 / 崩溃线程栈）已经落盘。余下扩展信息交给
  // 独立线程，主线程最多等 10 秒——崩溃处理器里绝不能无限等待，否则用户看到的
  // 就不是「闪退」而是「卡死」。
  std::wstring dump_name(file_name);
  const size_t dot = dump_name.find_last_of(L'.');
  if (dot != std::wstring::npos) {
    dump_name.erase(dot);
  }
  g_crash_job.report_path = directory + L"\\" + file_name;
  g_crash_job.dump_path = directory + L"\\" + dump_name + L".dmp";
  g_crash_job.platform_thread_id = g_platform_thread_id;
  g_crash_job.has_exception =
      info != nullptr && info->ExceptionRecord != nullptr;
  if (g_crash_job.has_exception) {
    g_crash_job.exception.ThreadId = ::GetCurrentThreadId();
    g_crash_job.exception.ExceptionPointers =
        const_cast<EXCEPTION_POINTERS*>(info);
    g_crash_job.exception.ClientPointers = TRUE;
  }
  HANDLE extras = ::CreateThread(nullptr, 0, WriteCrashExtrasProc, &g_crash_job,
                                 0, nullptr);
  if (extras != nullptr) {
    ::WaitForSingleObject(extras, 10000);
    ::CloseHandle(extras);
  }
}

// VEH 对进程里的每个异常都会被调用一次（包括程序自己用 SEH/VEH 正常处理的
// C++ 异常、guard page 探测等），所以只给「必死」的异常码留报告。
bool IsFatalException(DWORD code) {
  switch (code) {
    case EXCEPTION_ACCESS_VIOLATION:
    case EXCEPTION_IN_PAGE_ERROR:
    case EXCEPTION_ILLEGAL_INSTRUCTION:
    case EXCEPTION_INT_DIVIDE_BY_ZERO:
    case EXCEPTION_PRIV_INSTRUCTION:
    case EXCEPTION_STACK_OVERFLOW:
    case STATUS_STACK_BUFFER_OVERRUN:
    case 0x40000015:  // STATUS_FATAL_APP_EXIT：CRT 的 abort()
      return true;
    default:
      return false;
  }
}

LONG CALLBACK FatalExceptionHandler(EXCEPTION_POINTERS* info) {
  if (info != nullptr && info->ExceptionRecord != nullptr &&
      IsFatalException(info->ExceptionRecord->ExceptionCode)) {
    WriteCrashReport("未处理异常（访问违例等）", info);
  }
  return EXCEPTION_CONTINUE_SEARCH;  // 不改变原有处理流程
}

}  // namespace

void LogRuntimeInfo() {
  WriteRuntimeInfo();
}

void InstallCrashHandler() {
  // 记下平台/主线程 id：崩溃时最想知道它当时在干什么（是不是正在拆引擎/销毁插件）
  g_platform_thread_id = ::GetCurrentThreadId();
  // 用 VEH 而不是 SetUnhandledExceptionFilter：引擎或插件后面可能把 UEH 覆盖掉，
  // VEH 是异常分发里最先执行的一层，不会被别人抢走。
  ::AddVectoredExceptionHandler(1, &FatalExceptionHandler);
  std::set_terminate([]() {
    WriteCrashReport("std::terminate（未捕获的 C++ 异常）", nullptr);
    ::TerminateProcess(::GetCurrentProcess(), 3);
  });
}
