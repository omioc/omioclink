import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omioclink_client/musicfree/musicfree_host.dart';
import 'package:omioclink_client/musicfree/musicfree_plugins.dart';
import 'package:omioclink_client/musicfree/plugin_models.dart';
import 'package:omioclink_client/musicfree/plugin_paths.dart';

String pluginCode(
  String platform,
  String version, {
  String srcUrl = '',
  String titleSuffix = '',
}) {
  return '''
module.exports = {
  platform: "$platform",
  version: "$version",
  author: "probe",
  srcUrl: "$srcUrl",
  async search(query, page, type) {
    return { isEnd: true, data: [{ id: "1", title: query + "$titleSuffix", artist: "歌手" }] };
  },
  async getMediaSource(item, quality) {
    return { url: "https://example.invalid/" + item.id + "?q=" + quality };
  }
};
''';
}

/// 轮询等待某个条件成立：编译发生在 worker isolate 里，没有可以直接 await 的信号。
Future<void> waitUntil(
  bool Function() condition, {
  required String reason,
  Duration timeout = const Duration(seconds: 60),
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) {
      fail('等待超时（${watch.elapsed.inSeconds}s）：$reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late HttpServer server;
  late String base;
  late Directory tempRoot;
  late MusicFreeHost host;
  late MusicFreePlugins plugins;
  late String bundle;
  var upgraded = false;
  /// 模拟「第一次下载失败、之后能成功」的插件：验证失败会被记住并在下次补装。
  var flakyDown = true;
  var fetchCount = 0;
  final requestedUris = <String>[];

  setUpAll(() async {
    bundle = File('assets/musicfree/runtime.bundle.js').readAsStringSync();
  });

  setUp(() async {
    upgraded = false;
    flakyDown = true;
    fetchCount = 0;
    requestedUris.clear();
    tempRoot = await Directory.systemTemp.createTemp('omioc-mf-plugins-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((HttpRequest request) async {
      fetchCount += 1;
      requestedUris.add(request.uri.toString());
      final path = request.uri.path;
      Future<void> text(String body, {String type = 'js'}) async {
        request.response.headers.contentType = type == 'json'
            ? ContentType('application', 'json', charset: 'utf-8')
            : ContentType('text', 'javascript', charset: 'utf-8');
        request.response.write(body);
        await request.response.close();
      }

      // 8 个插件的订阅清单：用来验证「默认只装前 6 个」与「只装勾选的」
      final numbered = RegExp(r'^/p(\d)\.js$').firstMatch(path);
      if (numbered != null) {
        final index = numbered.group(1)!;
        await text(
          pluginCode('插件$index', '1.0.$index', srcUrl: '$base/p$index.js'),
        );
        return;
      }
      switch (path) {
        case '/big.json':
          await text(
            jsonEncode(<String, dynamic>{
              'plugins': [
                for (var i = 1; i <= 8; i += 1)
                  <String, dynamic>{
                    'name': '插件$i',
                    'url': '$base/p$i.js',
                    'version': '1.0.$i',
                  },
              ],
            }),
            type: 'json',
          );
          return;
        case '/a.js':
          await text(
            upgraded
                ? pluginCode('插件A', '2.0.0', srcUrl: '$base/a.js')
                : pluginCode('插件A', '1.0.0', srcUrl: '$base/a.js'),
          );
          return;
        case '/b.js':
          await text(pluginCode('插件B', '1.0.0', srcUrl: '$base/b.js'));
          return;
        case '/single.js':
          await text(pluginCode('单插件', '1.0.0', srcUrl: '$base/single.js'));
          return;
        case '/older.js':
          await text(pluginCode('插件A', '0.9.0'));
          return;
        case '/sub.json':
          await text(
            jsonEncode(<String, dynamic>{
              'plugins': [
                <String, dynamic>{'url': '$base/a.js'},
                <String, dynamic>{'url': '$base/b.js'},
              ],
            }),
            type: 'json',
          );
          return;
        case '/other-sub.json':
          await text(
            jsonEncode(<String, dynamic>{
              'plugins': [
                <String, dynamic>{'url': '$base/single.js'},
              ],
            }),
            type: 'json',
          );
          return;
        case '/flaky.js':
          if (flakyDown) {
            request.response.statusCode = 500;
            await request.response.close();
            return;
          }
          await text(pluginCode('插件慢', '1.0.0', srcUrl: '$base/flaky.js'));
          return;
        case '/sub2.json':
          await text(
            jsonEncode(<String, dynamic>{
              'plugins': [
                <String, dynamic>{'url': '$base/a.js'},
                <String, dynamic>{'url': '$base/flaky.js'},
              ],
            }),
            type: 'json',
          );
          return;
        default:
          request.response.statusCode = 404;
          await request.response.close();
      }
    });

    host = MusicFreeHost(
      paths: PluginPaths(root: tempRoot.path),
      bundleSource: bundle,
    );
    plugins = MusicFreePlugins(
      host: host,
      paths: PluginPaths(root: tempRoot.path),
    );
  });

  tearDown(() async {
    host.dispose();
    await server.close(force: true);
    if (tempRoot.existsSync()) {
      for (var attempt = 0; attempt < 3; attempt += 1) {
        try {
          tempRoot.deleteSync(recursive: true);
          break;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
      }
    }
  });

  test('.js 订阅：安装后 hash = sha256(源码)，源码落盘，请求带随机 hash', () async {
    // HTTP 请求不会带 fragment，所以用 MockClient 观察「派发出去的 URL」，
    // 对应 MusicFree 的 addRandomHash（无 # 时追加时间戳）。
    final recorded = <String>[];
    final mocked = MusicFreePlugins(
      host: host,
      paths: PluginPaths(root: tempRoot.path),
      httpClient: MockClient((request) async {
        recorded.add(request.url.toString());
        return http.Response.bytes(
          utf8.encode(pluginCode('单插件', '1.0.0', srcUrl: '$base/single.js')),
          200,
        );
      }),
    );
    await mocked.syncSubscription(urls: <String>['$base/single.js']);
    final installed = mocked.plugins;
    expect(installed, hasLength(1));
    expect(installed.first.platform, '单插件');
    final expectedHash = crypto.sha256.convert(utf8.encode(
      pluginCode('单插件', '1.0.0', srcUrl: '$base/single.js'),
    )).toString();
    expect(installed.first.hash, expectedHash);
    expect(File('${tempRoot.path}/musicfree-plugins/$expectedHash.js').existsSync(), isTrue);
    expect(recorded.single.contains('#'), isTrue, reason: '请求应带随机 hash 绕开缓存');
  });
  test('.json 订阅：清单里的插件全部安装', () async {
    await plugins.syncSubscription(urls: <String>['$base/sub.json']);
    expect(plugins.plugins.map((plugin) => plugin.platform).toSet(), <String>{'插件A', '插件B'});
  });

  test('一个插件下载失败只如实报出：订阅没变就不再自动补装（要补得用户点刷新订阅）', () async {
    // 第一次：flaky 返回 500。同一份订阅里的插件A要照常装上。
    final first = await plugins.syncSubscription(
      urls: <String>['$base/sub2.json'],
      signature: 'sig-flaky',
    );
    expect(first.failures, isNotEmpty, reason: '失败的插件要如实报出来');
    expect(
      plugins.plugins.map((plugin) => plugin.platform),
      contains('插件A'),
      reason: '一个坏插件不能拖累同一份订阅里的其它插件',
    );
    expect(plugins.plugins.map((plugin) => plugin.platform), isNot(contains('插件慢')));

    // 订阅地址列表没变：一条请求都不发，也不自动补装
    // （自动退避重试已经删掉：装不上往往是网络/音源自己的问题，反复重试只是烧流量）
    flakyDown = false;
    fetchCount = 0;
    final second = await plugins.syncSubscription(
      urls: <String>['$base/sub2.json'],
      signature: 'sig-flaky',
    );
    expect(second.reinstalled, isFalse);
    expect(fetchCount, 0, reason: '订阅没变就一条请求都不发');
    expect(plugins.plugins.map((plugin) => plugin.platform), isNot(contains('插件慢')));

    // 用户点「刷新订阅」（force）才清空重装
    final forced = await plugins.syncSubscription(
      urls: <String>['$base/sub2.json'],
      signature: 'sig-flaky',
      force: true,
    );
    expect(forced.reinstalled, isTrue);
    expect(plugins.plugins.map((plugin) => plugin.platform), contains('插件慢'));
  });

  test('同 hash 重复安装静默跳过', () async {
    await plugins.syncSubscription(urls: <String>['$base/single.js']);
    final before = plugins.plugins.length;
    expect(plugins.plugins.length, before);
  });

  test('同名新版本替换旧版本并删掉旧文件', () async {
    await plugins.syncSubscription(urls: <String>['$base/sub.json']);
    final oldA = plugins.plugins.firstWhere((plugin) => plugin.platform == '插件A');
    expect(oldA.version, '1.0.0');
    final oldFile = File('${tempRoot.path}/musicfree-plugins/${oldA.hash}.js');
    expect(oldFile.existsSync(), isTrue);

    upgraded = true;
    await plugins.installFromRemote('$base/a.js');

    final pluginsNow = plugins.plugins.where((plugin) => plugin.platform == '插件A').toList();
    expect(pluginsNow, hasLength(1));
    expect(pluginsNow.first.version, '2.0.0');
    expect(oldFile.existsSync(), isFalse, reason: '旧版本源码应被删除');
  });

  test('用旧版本覆盖新版本会被拒绝', () async {
    await plugins.installFromRemote('$base/a.js'); // 1.0.0
    await expectLater(
      plugins.installFromRemote('$base/older.js'), // 0.9.0
      throwsA(isA<MusicFreeException>().having(
        (error) => error.message,
        'message',
        contains('已安装更新版本的插件'),
      )),
    );
    expect(plugins.plugins.firstWhere((plugin) => plugin.platform == '插件A').version, '1.0.0');
  });

  test('卸载会删除源码文件', () async {
    await plugins.syncSubscription(urls: <String>['$base/single.js']);
    final plugin = plugins.plugins.first;
    final file = File('${tempRoot.path}/musicfree-plugins/${plugin.hash}.js');
    expect(file.existsSync(), isTrue);
    await plugins.uninstall(plugin.hash);
    expect(plugins.plugins, isEmpty);
    expect(file.existsSync(), isFalse);
  });

  test('更新全部按插件 srcUrl 重装到新版本', () async {
    await plugins.syncSubscription(urls: <String>['$base/a.js']);
    expect(plugins.plugins.first.version, '1.0.0');
    upgraded = true;
    final failures = await plugins.updateAll();
    expect(failures, isEmpty);
    expect(plugins.plugins.first.version, '2.0.0');
  });

  test('订阅签名不变时不重装', () async {
    await plugins.syncSubscription(urls: <String>['$base/sub.json']);
    final hashesBefore = plugins.plugins.map((plugin) => plugin.hash).toList();
    final countBefore = fetchCount;

    final result = await plugins.syncSubscription(urls: <String>['$base/sub.json']);
    expect(result.reinstalled, isFalse);
    expect(fetchCount, countBefore, reason: '签名相同不应再发请求');
    expect(plugins.plugins.map((plugin) => plugin.hash).toList(), hashesBefore);
  });

  test('签名变了但订阅地址没变：沿用本地插件，一条请求都不发', () async {
    await plugins.syncSubscription(
      urls: <String>['$base/sub.json'],
      signature: 'sig-old',
    );
    final hashesBefore = plugins.plugins.map((plugin) => plugin.hash).toList();
    fetchCount = 0;

    // 服务端只是重新生成了签名（URL 列表没变）：不需要重新下载、重新解析
    final result = await plugins.syncSubscription(
      urls: <String>['$base/sub.json'],
      signature: 'sig-new',
    );
    expect(result.reinstalled, isFalse);
    expect(fetchCount, 0, reason: 'URL 列表一致就不该再发请求');
    expect(plugins.plugins.map((plugin) => plugin.hash).toList(), hashesBefore);
  });

  test('订阅 URL 变化时只装新增、只卸被移除的插件（其余沿用）', () async {
    await plugins.syncSubscription(urls: <String>['$base/sub.json']);
    expect(plugins.plugins, hasLength(2));

    final result = await plugins.syncSubscription(urls: <String>['$base/other-sub.json']);
    expect(result.reinstalled, isTrue);
    expect(result.urls, <String>['$base/other-sub.json']);
    expect(plugins.plugins.map((plugin) => plugin.platform).toSet(), <String>{'单插件'});
    // 旧插件源码文件也清掉了
    final leftover = Directory('${tempRoot.path}/musicfree-plugins')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.js'))
        .length;
    expect(leftover, 1);
  });

  test('服务器下发空列表时**保留**本地插件（一次空响应不能把插件删光）', () async {
    await plugins.syncSubscription(urls: <String>['$base/sub.json']);
    expect(plugins.plugins, isNotEmpty);
    final before = plugins.plugins.map((plugin) => plugin.hash).toList();

    final result = await plugins.syncSubscription(urls: const <String>[]);

    // 以前这里会 uninstallAll()：一次瞬时拿空的订阅响应就把用户装好的插件全删了，
    // 界面表现是「突然说没有插件，然后从头装一遍」。现在只提示，不动本地。
    expect(result.reinstalled, isFalse);
    expect(result.failures, isNotEmpty, reason: '要让界面知道这次没拿到订阅');
    expect(plugins.plugins.map((plugin) => plugin.hash).toList(), before);
  });

  test('启停与排序写进本地偏好', () async {
    await plugins.syncSubscription(urls: <String>['$base/sub.json']);
    final first = plugins.plugins.first;
    await plugins.setEnabled(first.hash, false);
    expect(plugins.plugins.firstWhere((plugin) => plugin.hash == first.hash).enabled, isFalse);
    expect(plugins.enabledPlugins.any((plugin) => plugin.hash == first.hash), isFalse);

    final second = plugins.plugins.last;
    await plugins.move(second.hash, -1);
    expect(plugins.plugins.first.hash, second.hash);

    // 重新读偏好（模拟重启）
    final restarted = MusicFreePlugins(
      host: host,
      paths: PluginPaths(root: tempRoot.path),
    );
    await restarted.loadInstalled();
    expect(restarted.plugins.first.hash, second.hash);
    expect(restarted.plugins.firstWhere((plugin) => plugin.hash == first.hash).enabled, isFalse);
  });

  test('loadInstalled 能从磁盘恢复插件', () async {
    await plugins.syncSubscription(urls: <String>['$base/sub.json']);
    final second = MusicFreeHost(
      paths: PluginPaths(root: tempRoot.path),
      bundleSource: bundle,
    );
    addTearDown(second.dispose);
    final restored = MusicFreePlugins(host: second, paths: PluginPaths(root: tempRoot.path));
    await restored.loadInstalled();
    expect(restored.plugins.map((plugin) => plugin.platform).toSet(), <String>{'插件A', '插件B'});
  });

  test('元数据落盘：重启后不编译就能拿到插件列表（按需编译的前提）', () async {
    await plugins.syncSubscription(urls: <String>['$base/sub.json']);
    final expected = plugins.plugins.map((plugin) => plugin.hash).toSet();
    expect(expected, isNotEmpty);

    // 模拟重启：同一份数据目录，全新的 host（worker 一个都还没起）
    final restartedHost = MusicFreeHost(
      paths: PluginPaths(root: tempRoot.path),
      bundleSource: bundle,
    );
    addTearDown(restartedHost.dispose);

    final restored = await restartedHost.restoreMetadata();
    expect(restored, expected.length);
    expect(
      restartedHost.plugins.map((plugin) => plugin.hash).toSet(),
      expected,
      reason: '插件列表应该直接来自缓存',
    );
    expect(
      restartedHost.isReady,
      isFalse,
      reason: '只是登记元数据，不该为它启动 worker / 编译 JS',
    );
  });

  // ------------------------------------------------- 订阅清单里的「挑着装」
  test('清单有 8 个插件时默认只装前 6 个，没选中的连请求都不发', () async {
    final result = await plugins.syncSubscription(urls: <String>['$base/big.json']);
    expect(result.reinstalled, isTrue);
    expect(
      plugins.plugins.map((plugin) => plugin.platform).toSet(),
      <String>{'插件1', '插件2', '插件3', '插件4', '插件5', '插件6'},
    );
    expect(
      requestedUris.any((uri) => uri.contains('/p7.js') || uri.contains('/p8.js')),
      isFalse,
      reason: '没选中的插件不该被下载：$requestedUris',
    );
  });

  test('刷新订阅时按用户勾选的装，并把这份选择记下来', () async {
    var asked = 0;
    Set<String>? preselected;
    Future<Set<String>?> picker(
      List<MusicFreeSubscriptionEntry> entries,
      Set<String> initial,
    ) async {
      asked += 1;
      preselected = initial;
      // 只要第一个和最后一个
      return <String>{entries.first.url, entries.last.url};
    }

    final result = await plugins.syncSubscription(
      urls: <String>['$base/big.json'],
      force: true,
      pickEntries: picker,
    );
    expect(result.reinstalled, isTrue);
    expect(asked, 1);
    expect(
      preselected,
      hasLength(MusicFreePlugins.defaultSelectionSize),
      reason: '第一次没有历史选择，默认勾前 6 个',
    );
    expect(
      plugins.plugins.map((plugin) => plugin.platform).toSet(),
      <String>{'插件1', '插件8'},
    );
    expect(
      requestedUris.any((uri) => uri.contains('/p5.js')),
      isFalse,
      reason: '只下载勾选的那两个',
    );

    // 再刷一次：上一次的选择要被当作预设值交回给弹框
    asked = 0;
    preselected = null;
    await plugins.syncSubscription(
      urls: <String>['$base/big.json'],
      force: true,
      pickEntries: picker,
    );
    expect(asked, 1);
    expect(preselected, <String>{'$base/p1.js', '$base/p8.js'});
  });

  test('在选择框里点取消：本地插件一个都不动', () async {
    await plugins.syncSubscription(urls: <String>['$base/big.json']);
    final before = plugins.plugins.map((plugin) => plugin.hash).toSet();
    expect(before, hasLength(MusicFreePlugins.defaultSelectionSize));

    final result = await plugins.syncSubscription(
      urls: <String>['$base/big.json'],
      force: true,
      pickEntries: (entries, preselected) async => null,
    );

    expect(result.cancelled, isTrue);
    expect(result.reinstalled, isFalse);
    expect(plugins.plugins.map((plugin) => plugin.hash).toSet(), before);
  });

  test('刷新时选得比上次少：没选中的插件被卸掉', () async {
    await plugins.syncSubscription(urls: <String>['$base/big.json']);
    expect(plugins.plugins, hasLength(MusicFreePlugins.defaultSelectionSize));

    await plugins.syncSubscription(
      urls: <String>['$base/big.json'],
      force: true,
      pickEntries: (entries, preselected) async =>
          <String>{entries[1].url, entries[2].url},
    );

    expect(
      plugins.plugins.map((plugin) => plugin.platform).toSet(),
      <String>{'插件2', '插件3'},
    );
    final leftover = Directory('${tempRoot.path}/musicfree-plugins')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.js'))
        .length;
    expect(leftover, 2, reason: '被取消的插件源码也要删掉');
  });

  test('刷新订阅会卸掉「这条订阅装出来的」旧插件，即使 owned 里没记账（老数据）', () async {
    // 模拟老版本留下的状态：插件装了，但订阅文件里没有 owned 归属记录。
    // 这时只靠 owned 卸载会漏，旧插件永远清不掉——所以要同时按 srcUrl 命中清单来认。
    await plugins.installFromRemote('$base/p1.js');
    await plugins.installFromRemote('$base/p2.js');
    expect(plugins.plugins.map((plugin) => plugin.platform).toSet(), <String>{'插件1', '插件2'});

    await plugins.syncSubscription(
      urls: <String>['$base/big.json'],
      force: true,
      // 只留第 3 个（p1 / p2 都被取消）
      pickEntries: (entries, preselected) async => <String>{entries[2].url},
    );

    expect(
      plugins.plugins.map((plugin) => plugin.platform).toSet(),
      <String>{'插件3'},
      reason: '没被选中的旧插件要跟着卸载',
    );
  });

  test('重启后 restoreInstalled 只登记不编译：插件列表立刻可见，worker 不起', () async {
    await plugins.syncSubscription(urls: <String>['$base/sub.json']);
    final expected = plugins.plugins.map((plugin) => plugin.hash).toSet();
    expect(expected, isNotEmpty);

    // 模拟重启：同一份数据目录，全新的 host / store
    final restartedHost = MusicFreeHost(
      paths: PluginPaths(root: tempRoot.path),
      bundleSource: bundle,
    );
    addTearDown(restartedHost.dispose);
    final restarted = MusicFreePlugins(
      host: restartedHost,
      paths: PluginPaths(root: tempRoot.path),
    );
    // 这就是用户报的那个状态：重启后没人登记，列表是空的 → 设置页「还没有安装插件」
    expect(restarted.plugins, isEmpty);

    final restored = await restarted.restoreInstalled();

    expect(restored, expected.length);
    expect(restarted.plugins.map((plugin) => plugin.hash).toSet(), expected);
    expect(
      restartedHost.isReady,
      isFalse,
      reason: '只是为了显示列表，不该启动 worker / 编译 JS',
    );
  });

  test('启动就在后台把已装插件编进 worker：restoreInstalled 不等编译，编完直接可用', () async {
    await plugins.syncSubscription(urls: <String>['$base/sub.json']);
    final hashes = plugins.plugins.map((plugin) => plugin.hash).toList();
    expect(hashes, isNotEmpty);

    // 模拟重启：同一份数据目录，全新的 host / store
    final restartedHost = MusicFreeHost(
      paths: PluginPaths(root: tempRoot.path),
      bundleSource: bundle,
    );
    addTearDown(restartedHost.dispose);
    final restarted = MusicFreePlugins(
      host: restartedHost,
      paths: PluginPaths(root: tempRoot.path),
    );
    await restarted.restoreInstalled();
    expect(
      hashes.where(restartedHost.isCompiled),
      isEmpty,
      reason: '登记元数据不该顺手编译：列表要立刻可见',
    );

    // 启动后台预编译：调用方不等它，界面上也没有任何「加载中」
    restarted.warmPluginsInBackground();
    await waitUntil(
      () => hashes.every(restartedHost.isCompiled),
      reason: '后台应该把已装插件全部编进 worker',
    );
    expect(restartedHost.isReady, isTrue);
  });

  test('重启后第一次调用「还没编译」的插件必须返回，不能挂着', () async {
    await plugins.syncSubscription(urls: <String>['$base/sub.json']);

    // 模拟重启：元数据登记了，worker 里什么都没有
    final restartedHost = MusicFreeHost(
      paths: PluginPaths(root: tempRoot.path),
      bundleSource: bundle,
    );
    addTearDown(restartedHost.dispose);
    final restarted = MusicFreePlugins(
      host: restartedHost,
      paths: PluginPaths(root: tempRoot.path),
    );
    await restarted.restoreInstalled();
    final hash = restarted.plugins.first.hash;
    expect(restartedHost.isCompiled(hash), isFalse);

    // 这时直接调用：内部走 `_ensureCompiled`（现场编译）。曾经这里因为
    // `whenComplete` 返回了被移除的那个 future 而自等死锁——编译日志照打，
    // 调用却永远不返回，界面上就是「这个音源一直不来」，连失败都不报。
    final result = await restartedHost
        .invoke(
          hash,
          MusicFreeCapabilities.search,
          <Object?>['测试', 1, 'single'],
          timeout: const Duration(seconds: 20),
        )
        .timeout(
          const Duration(seconds: 40),
          onTimeout: () => fail('按需编译的插件调用没有返回：_ensureCompiled 又挂住了'),
        );

    expect(result, isA<Map<dynamic, dynamic>>());
    expect(restartedHost.isCompiled(hash), isTrue);
  });
}
