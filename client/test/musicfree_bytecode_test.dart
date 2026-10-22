import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/musicfree/musicfree_bytecode.dart';
import 'package:omioclink_client/musicfree/musicfree_host.dart';
import 'package:omioclink_client/musicfree/plugin_paths.dart';
import 'package:quickjs_engine/quickjs_engine.dart';

/// 一个最小但「真」的插件：用 cheerio 解析 HTML，走 require 拿依赖。
const String _probePlugin = r'''
module.exports = {
  platform: "字节码探针",
  version: "1.0.0",
  author: "probe",
  primaryKey: ["id"],
  supportedSearchType: ["music"],

  search(query, page, type) {
    const cheerio = require("cheerio");
    const $ = cheerio.load("<div class='t'>" + query + "</div>");
    return {
      isEnd: true,
      data: [{ id: String(page), title: $(".t").text(), type: type }],
    };
  },
};
''';

void main() {
  late String bundle;
  late Directory tempRoot;

  setUpAll(() {
    bundle = File('assets/musicfree/runtime.bundle.js').readAsStringSync();
  });

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('omioc-mf-bytecode-');
  });

  tearDown(() {
    if (!tempRoot.existsSync()) {
      return;
    }
    for (var attempt = 0; attempt < 3; attempt += 1) {
      try {
        tempRoot.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        sleep(const Duration(milliseconds: 60));
      }
    }
  });

  /// 等一个文件出现（字节码是「不阻塞装载」地异步落盘的）。
  Future<File> waitForFile(File file) async {
    for (var attempt = 0; attempt < 100; attempt += 1) {
      if (file.existsSync() && file.lengthSync() > 0) {
        return file;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('字节码没有落盘：${file.path}');
  }

  test('native 桥带字节码接口（否则整条缓存链退化成源码编译）', () {
    expect(
      quickjsBytecode,
      isNotNull,
      reason: '当前加载的 quickjs_c_bridge_plugin 没有 jsCompileToBytecode/jsEvalBytecode，'
          '先跑 packages/quickjs_engine_local/tool/build_native.ps1 重新构建',
    );
  });

  test('字节码：一个运行时编译，另一个运行时反序列化执行，结果与源码一致', () {
    final source = "globalThis.__probeAdd = function (a, b) { return a + b; };\n'ok';";

    final compiler = getJavascriptRuntime(xhr: false) as QuickJsRuntime2;
    addTearDown(compiler.dispose);
    final booted = compiler.evaluate(bundle);
    expect(booted.isError, isFalse, reason: booted.stringResult);

    final bytes = compiler.compileToBytecode(source, name: 'probe.js');
    expect(bytes, isNotNull, reason: compiler.lastBytecodeError);
    expect(bytes!.length, greaterThan(16));

    // 换一个**全新**的运行时执行同一份字节码：这正是多个 worker 的场景。
    final runner = getJavascriptRuntime(xhr: false) as QuickJsRuntime2;
    addTearDown(runner.dispose);
    final loaded = runner.evaluateBytecode(bytes);
    expect(loaded.isError, isFalse, reason: loaded.stringResult);
    expect(runner.evaluate('__probeAdd(2, 3)').stringResult, '5');

    // 坏掉的字节码必须变成可捕获的错误（宿主据此删缓存并退回源码编译）
    final broken = runner.evaluateBytecode(
      Uint8List.fromList(List<int>.filled(bytes.length, 7)),
    );
    expect(broken.isError, isTrue);
  });

  test('宿主：首次装载编译并落盘，第二次命中的是字节码而不是重新编译', () async {
    final firstKeys = <String>[];
    final first = MusicFreeEngine(
      paths: PluginPaths(root: tempRoot.path),
      bundleSource: bundle,
      timingSink: (key, elapsed) => firstKeys.add(key),
    );
    addTearDown(first.dispose);

    final plugin = await first.loadPlugin(hash: 'probe-hash', code: _probePlugin, path: 'probe.js');
    expect(plugin.loadError, isNull, reason: plugin.loadError);
    expect(plugin.platform, '字节码探针');
    expect(
      firstKeys.any((key) => key.startsWith('插件.编译 插件probe-ha')),
      isTrue,
      reason: '首次装载应该走「编译」：$firstKeys',
    );

    final result = await first.invoke('probe-hash', 'search', <Object?>['你好', 2, 'music']);
    final item = ((result as Map)['data'] as List).first as Map;
    expect(item['title'], '你好');

    // 插件源码与运行时 bundle 都该落盘
    final pluginCache = File(
      '${tempRoot.path}/musicfree-data/bytecode/${MusicFreeBytecodeCache.pluginKey(_probePlugin)}',
    );
    await waitForFile(pluginCache);
    await waitForFile(
      File('${tempRoot.path}/musicfree-data/bytecode/${MusicFreeBytecodeCache.bundleKey(bundle)}'),
    );

    // 新宿主（= 重启后的进程 / 另一个 worker）必须直接吃缓存
    final secondKeys = <String>[];
    final second = MusicFreeEngine(
      paths: PluginPaths(root: tempRoot.path),
      bundleSource: bundle,
      timingSink: (key, elapsed) => secondKeys.add(key),
    );
    addTearDown(second.dispose);
    final again = await second.loadPlugin(hash: 'probe-hash', code: _probePlugin, path: 'probe.js');
    expect(again.loadError, isNull, reason: again.loadError);
    expect(again.platform, '字节码探针');
    expect(
      secondKeys.any((key) => key.startsWith('插件.字节码 插件probe-ha')),
      isTrue,
      reason: '第二次装载应该走「字节码」：$secondKeys',
    );
    expect(
      secondKeys.any((key) => key.startsWith('插件.编译')),
      isFalse,
      reason: '命中缓存时不该再编译：$secondKeys',
    );

    final againResult = await second.invoke('probe-hash', 'search', <Object?>['再见', 1, 'music']);
    final againItem = ((againResult as Map)['data'] as List).first as Map;
    expect(againItem['title'], '再见');
  });

  test('缓存文件坏掉时自动作废并退回源码编译', () async {
    final keys = <String>[];
    final engine = MusicFreeEngine(
      paths: PluginPaths(root: tempRoot.path),
      bundleSource: bundle,
      timingSink: (key, elapsed) => keys.add(key),
    );
    addTearDown(engine.dispose);
    await engine.loadPlugin(hash: 'probe-hash', code: _probePlugin, path: 'probe.js');

    final cacheFile = await waitForFile(
      File(
        '${tempRoot.path}/musicfree-data/bytecode/${MusicFreeBytecodeCache.pluginKey(_probePlugin)}',
      ),
    );
    // 截断成垃圾：反序列化必然失败，宿主应该删缓存重编译而不是报错
    cacheFile.writeAsBytesSync(List<int>.filled(64, 3));
    final secondKeys = <String>[];
    final second = MusicFreeEngine(
      paths: PluginPaths(root: tempRoot.path),
      bundleSource: bundle,
      timingSink: (key, elapsed) => secondKeys.add(key),
    );
    addTearDown(second.dispose);
    final plugin = await second.loadPlugin(hash: 'probe-hash', code: _probePlugin, path: 'probe.js');
    expect(plugin.loadError, isNull, reason: plugin.loadError);
    expect(
      secondKeys.any((key) => key.startsWith('插件.编译')),
      isTrue,
      reason: '缓存坏了必须重新编译：$secondKeys',
    );
  });

  test('清理：只留当前版本、仍在磁盘上的插件字节码', () async {
    final cacheDir = Directory('${tempRoot.path}/musicfree-data/bytecode')
      ..createSync(recursive: true);
    final cache = MusicFreeBytecodeCache(dir: cacheDir.path);
    // 活着的插件
    final live = File('${cacheDir.path}/${MusicFreeBytecodeCache.pluginKeyForHash('aaa')}')
      ..writeAsBytesSync(<int>[1, 2, 3]);
    // 插件已经删了
    final orphan = File('${cacheDir.path}/${MusicFreeBytecodeCache.pluginKeyForHash('bbb')}')
      ..writeAsBytesSync(<int>[1, 2, 3]);
    // 老格式版本（格式版本 +1 之后的遗留）
    final oldVersion = File('${cacheDir.path}/v99-plugin-ccc.qbc')
      ..writeAsBytesSync(<int>[1, 2, 3]);
    // 半截临时文件（时间戳挪到两小时前，模拟「肯定不在写」）
    final staleTemp = File('${cacheDir.path}/v1-plugin-ddd.qbc.tmp')
      ..writeAsBytesSync(<int>[1, 2, 3]);
    staleTemp.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 2)));
    // 当前版本的 bundle 必须保住
    final bundleFile = File('${cacheDir.path}/${MusicFreeBytecodeCache.bundleKey(bundle)}')
      ..writeAsBytesSync(<int>[1, 2, 3]);

    final removed = await cache.prunePlugins(<String>{'aaa'});

    expect(removed, 3, reason: '孤儿插件 / 旧版本 / 过期临时文件各一个');
    expect(live.existsSync(), isTrue);
    expect(bundleFile.existsSync(), isTrue);
    expect(orphan.existsSync(), isFalse);
    expect(oldVersion.existsSync(), isFalse);
    expect(staleTemp.existsSync(), isFalse);
  });
}
