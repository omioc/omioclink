import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/core/app_version.dart';

/// 版本号只有 pubspec.yaml 一个来源：运行时用的常量与 Runner.rc 的兜底值都必须跟着它走。
/// 这几条断言就是「别改漏」的守门员 —— 漏了先由 `flutter test` 拦住，而不是等发出去的包
/// 在「关于」里显示旧版本号。
void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final full = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true)
      .firstMatch(pubspec)!
      .group(1)!;
  final segments = full.split('+');
  final numbers = segments.first.split('.');
  final build = segments.length == 2 ? segments[1] : '0';

  test('kAppVersion / kAppVersionFull 与 pubspec.yaml 一致', () {
    expect(kAppVersionFull, full);
    expect(kAppVersion, segments.first);
  });

  test('Runner.rc 的兜底版本与 pubspec.yaml 一致', () {
    final rc = File('windows/runner/Runner.rc').readAsStringSync();
    expect(rc, contains('#define VERSION_AS_NUMBER ${numbers.join(',')},$build'));
    expect(rc, contains('#define VERSION_AS_STRING "${segments.first}"'));
  });
}
