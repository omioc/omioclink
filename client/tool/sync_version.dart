// 版本号只有 client/pubspec.yaml 的 `version:` 一个来源。
//
// 有些地方必须写字面量（C++ 资源文件、Dart 运行时常量），这个脚本负责把 pubspec 的值同步过去：
//   * lib/core/app_version.dart —— 运行时用（插件 UA、诊断信息）
//   * windows/runner/Runner.rc —— 版本资源兜底（真正构建时 Flutter 会注入 FLUTTER_VERSION*，
//     但文件里留着 1.0.1 这种陈旧值会让人以为版本没升，所以一起同步）
//
// 用法（在 client/ 下执行）：
//   dart run tool/sync_version.dart            写入
//   dart run tool/sync_version.dart --check    只校验，漂移则返回 1（CI 用）

import 'dart:io';

/// pubspec 里的 `version: x.y.z+build`（build 可省）。
final RegExp _pubspecVersion = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true);

void main(List<String> args) {
  final checkOnly = args.contains('--check');

  final pubspec = File('pubspec.yaml');
  if (!pubspec.existsSync()) {
    stderr.writeln('找不到 pubspec.yaml：请在 client/ 目录下运行');
    exit(2);
  }
  final match = _pubspecVersion.firstMatch(pubspec.readAsStringSync());
  if (match == null) {
    stderr.writeln('pubspec.yaml 里没有 version: x.y.z（+build）');
    exit(2);
  }

  final full = match.group(1)!;
  final segments = full.split('+');
  final numbers = segments.first.split('.');
  if (numbers.length != 3 || segments.length > 2) {
    stderr.writeln('版本号格式不是 x.y.z 或 x.y.z+build：$full');
    exit(2);
  }
  final build = segments.length == 2 ? segments[1] : '0';

  var drifted = false;
  drifted |= _syncFile(
    File('lib/core/app_version.dart'),
    _appVersionDart(version: segments.first, full: full),
    checkOnly: checkOnly,
  );
  drifted |= _patchDefines(
    File('windows/runner/Runner.rc'),
    <String, String>{
      'VERSION_AS_NUMBER': '${numbers.join(',')},$build',
      'VERSION_AS_STRING': '"${segments.first}"',
    },
    checkOnly: checkOnly,
  );

  if (!checkOnly) {
    stdout.writeln('已同步到 $full');
    return;
  }
  if (drifted) {
    stderr.writeln('版本号有漂移：跑 `dart run tool/sync_version.dart` 同步后再提交');
    exit(1);
  }
  stdout.writeln('版本号一致：$full');
}

String _appVersionDart({required String version, required String full}) => '''
// 由 `dart run tool/sync_version.dart` 从 pubspec.yaml 生成，不要手改。
// 版本号只有 pubspec.yaml 的 `version:` 一个来源；这个文件与 Runner.rc 的兜底值
// 一旦和 pubspec 漂移，`flutter test` 里的 app_version_test 会直接失败。

/// 应用版本，不含 build 号（插件 UA、诊断信息用）。
const String kAppVersion = '$version';

/// 完整版本（含 build 号），与 pubspec.yaml 的 `version:` 逐字一致。
const String kAppVersionFull = '$full';
''';

/// 整份文件比对后覆盖；返回「原本不一致」（checkOnly 时也返回 true，只是不写盘）。
bool _syncFile(File file, String content, {required bool checkOnly}) {
  final current = file.existsSync() ? file.readAsStringSync() : '';
  // 只比内容、不比行尾：GitHub 的 Windows runner 上 core.autocrlf=true，检出来的文件是 CRLF，
  // 而这里生成的是 LF。直接比字节会在这类工作区里误报「版本号漂移」（本机是 LF 所以看不出来）。
  if (_sameIgnoringEol(current, content)) {
    return false;
  }
  if (!checkOnly) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    stdout.writeln('写入 ${file.path}');
  }
  return true;
}

/// 忽略 CRLF / LF 差异的文本相等判断。
bool _sameIgnoringEol(String a, String b) =>
    a.replaceAll('\r\n', '\n') == b.replaceAll('\r\n', '\n');

/// 逐行替换 `#define <key> <值>`；返回是否有行需要改。
///
/// 不用正则整段替换：这文件的行尾与转义都很敏感，按行比对既不会误伤别的 `#define`，
/// 也能把原来的行尾符（CRLF / LF）原样带回去。
bool _patchDefines(
  File file,
  Map<String, String> defines, {
  required bool checkOnly,
}) {
  if (!file.existsSync()) {
    stderr.writeln('找不到 ${file.path}');
    exit(2);
  }
  final lines = file.readAsStringSync().split('\n');
  var drifted = false;

  for (final entry in defines.entries) {
    final prefix = '#define ${entry.key} ';
    var hits = 0;
    for (var i = 0; i < lines.length; i++) {
      final carriage = lines[i].endsWith('\r') ? '\r' : '';
      final body = carriage.isEmpty
          ? lines[i]
          : lines[i].substring(0, lines[i].length - 1);
      // 同一个宏在文件里有两行：`#if` 分支指向 FLUTTER_VERSION*（真构建走这条），
      // `#else` 分支才是要维护的兜底字面量 —— 后者以数字或引号开头，前者以 FLUTTER_ 开头
      final value = body.startsWith(prefix) ? body.substring(prefix.length) : null;
      if (value == null || value.startsWith('FLUTTER_')) {
        continue;
      }
      hits += 1;
      final replaced = '$prefix${entry.value}$carriage';
      if (lines[i] != replaced) {
        drifted = true;
        lines[i] = replaced;
      }
    }
    // 只认唯一的那一行：匹配不到或匹配到多行都说明文件被改坏了
    if (hits != 1) {
      stderr.writeln('${file.path} 里 #define ${entry.key} 出现 $hits 次（应为 1）');
      exit(2);
    }
  }

  if (drifted && !checkOnly) {
    file.writeAsStringSync(lines.join('\n'));
    stdout.writeln('写入 ${file.path}');
  }
  return drifted;
}
