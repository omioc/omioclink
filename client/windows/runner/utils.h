#ifndef RUNNER_UTILS_H_
#define RUNNER_UTILS_H_

#include <string>
#include <vector>

// Creates a console for the process, and redirects stdout and stderr to
// it for both the runner and the Flutter library.
void CreateAndAttachConsole();

// Takes a null-terminated wchar_t* encoded in UTF-16 and returns a std::string
// encoded in UTF-8. Returns an empty std::string on failure.
std::string Utf8FromUtf16(const wchar_t* utf16_string);

// Gets the command line arguments passed in as a std::vector<std::string>,
// encoded in UTF-8. Returns an empty std::vector<std::string> on failure.
std::vector<std::string> GetCommandLineArguments();

// Installs an in-process handler for native crashes (access violation, illegal
// instruction, abort/terminate...). Those kill the process outright, so nothing
// reaches the Dart log; the handler drops a `crash-*.log` next to the Dart log
// files with the exception code, the faulting module and a module+offset stack.
void InstallCrashHandler();

// Writes a small `native-*.log` next to the Dart logs with the executable path
// and the C++ runtime DLLs actually loaded (name, full path, version). Which
// msvcp140.dll a machine uses decides whether the plugin's std::mutex ABI
// matches, so it is the first thing to look at when a crash only happens on
// some machines.
void LogRuntimeInfo();

#endif  // RUNNER_UTILS_H_
