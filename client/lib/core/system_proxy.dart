import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';

/// 常见本地代理端口（Clash / Clash Verge / v2rayN / Shadowsocks …）。
const List<int> _localProxyPorts = <int>[
  7890,
  7897,
  10809,
  10808,
  1080,
  8889,
  2080,
  8080,
];

/// 音源请求的出口代理。
///
/// `dart:io` 的 `HttpClient` **不会**自动使用系统代理（Chromium / Electron 会），
/// 而音源接口在国内常被运营商按 SNI 阻断、只有走代理才通——不读系统代理的后果
/// 就是「洛雪能播、我们连不上」。取值优先级：
///
/// 1. 用户在设置页手填的代理（持久化，不想开全局代理时用这个）；
/// 2. 环境变量 `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY`（大小写都认）；
/// 3. Windows 的 IE 代理设置（Clash / v2ray 这类客户端默认写这里）。
///
/// **只在启动时读一次**（[load]）：改完设置要重启客户端才生效。
abstract final class SystemProxy {
  static const String _prefsKey = 'music_proxy_override';

  static String? _address;
  static String? _source;
  static String? _override;
  static bool _loaded = false;
  static Future<void>? _detectFuture;

  /// 本次运行实际生效的代理（`host:port`）；null 表示直连。
  static String? get address => _address;

  /// 生效来源说明（自定义 / 环境变量 / Windows Internet 设置 / 直连）。
  static String get source => _source ?? '直连';

  static bool get loaded => _loaded;

  /// 用户手填的代理（没填则为 null）。
  static String? get override => _override;

  /// 启动时调用一次（读不到就退回直连，不影响主流程）。
  ///
  /// [detectLocal] 打开时，若前三处都没配代理，会在**后台**试着找本地代理
  /// （见 [detectLocalProxy]）；调用方在真正要用代理前先 [resolve] 等一下即可。
  static Future<void> load({bool detectLocal = true}) async {
    if (_loaded) {
      return;
    }
    _loaded = true;
    _override = await _readOverride();
    final custom = parseProxyAddress(_override);
    if (custom != null) {
      _address = custom;
      _source = '自定义';
      AppLog.info('系统代理：$custom（设置页手填）');
      return;
    }
    final env = _fromEnvironment();
    if (env != null) {
      _address = env;
      _source = '环境变量';
      AppLog.info('系统代理：$env（环境变量）');
      return;
    }
    if (Platform.isWindows) {
      _address = await _fromWindowsRegistry();
      if (_address != null) {
        _source = 'Windows Internet 设置';
      }
    }
    if (_address != null) {
      AppLog.info('系统代理：$_address（$_source）');
      return;
    }
    AppLog.info('系统代理：未配置（音源请求直连）');
    if (detectLocal) {
      _detectFuture = _detect();
    }
  }

  /// 等后台的自动探测出结果（没有在探测时立即返回）。
  ///
  /// 音源宿主在第一次拉脚本前会先等它：如果这台机器上跑着代理软件只是没开
  /// 系统代理，这一步能直接把它接上，用户不用配任何东西。
  static Future<void> resolve() async {
    final pending = _detectFuture;
    if (pending != null) {
      await pending;
    }
  }

  static Future<void> _detect() async {
    final found = await detectLocalProxy();
    if (found != null) {
      _address = found;
      _source = '自动发现';
      AppLog.info('系统代理：未配置，自动发现本地代理 $found（已采用）');
    }
    _detectFuture = null;
  }

  /// 在常见端口上找一台**真能出网**的本地代理。
  ///
  /// 现实里最常见的拦路虎是「代理软件在跑，但系统代理开关没开」——这时连洛雪
  /// （Electron）都连不上，用户却以为是客户端的问题。命中要过两关：TCP 能连上，
  /// 且能通过它访问一个只在墙外可达的探测端点（避免把别的本地服务当成代理）。
  static Future<String?> detectLocalProxy() async {
    final candidates = await Future.wait(<Future<String?>>[
      for (final port in _localProxyPorts) _probePort(port),
    ]);
    final listening = candidates.whereType<String>().toList(growable: false);
    if (listening.isEmpty) {
      return null;
    }
    for (final address in listening) {
      if (await _canProxyThrough(address)) {
        return address;
      }
    }
    AppLog.info('系统代理：本地端口 ${listening.join(', ')} 在监听，但都出不了网');
    return null;
  }

  static Future<String?> _probePort(int port) async {
    try {
      final socket = await Socket.connect(
        '127.0.0.1',
        port,
        timeout: const Duration(milliseconds: 300),
      );
      socket.destroy();
      return '127.0.0.1:$port';
    } on Object {
      return null;
    }
  }

  /// 探测端点：第一个只在墙外可达（能通说明这代理**真能出墙**），
  /// 第二个是国内有时可直连的通用 204 端点（兜底，用来确认端口确实是个能用的代理）。
  static const List<String> _probeUrls = <String>[
    'https://www.google.com/generate_204',
    'https://www.gstatic.com/generate_204',
  ];

  static Future<bool> _canProxyThrough(String address) async {
    for (final probe in _probeUrls) {
      try {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 4)
          ..findProxy = (uri) => 'PROXY $address';
        try {
          final request = await client
              .getUrl(Uri.parse(probe))
              .timeout(const Duration(seconds: 5));
          final response = await request.close().timeout(
            const Duration(seconds: 5),
          );
          await response.drain<void>();
          if (response.statusCode == 204 || response.statusCode == 200) {
            return true;
          }
        } finally {
          client.close(force: true);
        }
      } on Object {
        continue;
      }
    }
    return false;
  }

  /// 保存（或清除）手填代理。下次启动生效。
  static Future<void> setOverride(String? value) async {
    final trimmed = value?.trim() ?? '';
    _override = trimmed.isEmpty ? null : trimmed;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (trimmed.isEmpty) {
        await prefs.remove(_prefsKey);
      } else {
        await prefs.setString(_prefsKey, trimmed);
      }
    } on Object catch (error) {
      AppLog.warn('保存音源代理失败', error: error);
    }
  }

  /// 只探测「系统现在是什么状态」，不改变本次运行已生效的值。
  ///
  /// 设置页用它显示：本次运行用的是哪套、系统当前又是哪套（改完没重启时分得清）。
  static Future<String?> probeSystem() async {
    final env = _fromEnvironment();
    if (env != null) {
      return env;
    }
    if (Platform.isWindows) {
      return _fromWindowsRegistry();
    }
    return null;
  }

  @visibleForTesting
  static void debugReset() {
    _address = null;
    _source = null;
    _override = null;
    _loaded = false;
    _detectFuture = null;
  }

  static Future<String?> _readOverride() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(_prefsKey);
      return value == null || value.trim().isEmpty ? null : value.trim();
    } on Object catch (error) {
      AppLog.warn('读取音源代理设置失败', error: error);
      return null;
    }
  }

  static String? _fromEnvironment() {
    const names = <String>[
      'HTTPS_PROXY',
      'https_proxy',
      'HTTP_PROXY',
      'http_proxy',
      'ALL_PROXY',
      'all_proxy',
    ];
    for (final name in names) {
      final parsed = parseProxyAddress(Platform.environment[name]);
      if (parsed != null) {
        return parsed;
      }
    }
    return null;
  }

  static Future<String?> _fromWindowsRegistry() async {
    try {
      final result = await Process.run('reg', <String>[
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
      ]);
      if (result.exitCode != 0) {
        return null;
      }
      // reg.exe 输出的是窄字符文本，个别环境下会带上 UTF-16 的零字节，先清掉
      final text = result.stdout.toString().replaceAll('\u0000', '');
      if (!RegExp(r'ProxyEnable\s+REG_DWORD\s+0x1').hasMatch(text)) {
        if (RegExp(r'ProxyServer\s+REG_SZ\s+\S').hasMatch(text)) {
          AppLog.info('系统代理：检测到代理地址但未启用（ProxyEnable=0）');
        }
        return null;
      }
      final match = RegExp(r'ProxyServer\s+REG_SZ\s+(.+)').firstMatch(text);
      return parseProxyAddress(match?.group(1));
    } on Object catch (error) {
      AppLog.debug('读取 Windows 代理设置失败：$error');
      return null;
    }
  }

  /// 归一化用户/系统给的代理地址：接受 `host:port`、`http://host:port`、
  /// `http=host:port;https=host:port` 三种写法，统一返回 `host:port`。
  @visibleForTesting
  static String? parseProxyAddress(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    for (final chunk in trimmed.split(';')) {
      final entry = chunk.trim();
      if (entry.isEmpty) {
        continue;
      }
      final index = entry.indexOf('=');
      final target = index >= 0 ? entry.substring(index + 1).trim() : entry;
      final withoutScheme = target.replaceFirst(
        RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'),
        '',
      );
      final hostPort = withoutScheme.split('/').first;
      if (hostPort.isEmpty) {
        continue;
      }
      return hostPort.contains(':') ? hostPort : '$hostPort:80';
    }
    return null;
  }
}
