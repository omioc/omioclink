import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/musicfree/musicfree_host.dart';
import 'package:omioclink_client/musicfree/musicfree_plugins.dart';
import 'package:omioclink_client/musicfree/musicfree_service.dart';
import 'package:omioclink_client/musicfree/plugin_paths.dart';

/// MusicFreeService：多插件聚合、失败隔离、原始字段往返。
void main() {
  late HttpServer server;
  late String base;
  late Directory tempRoot;
  late MusicFreeHost host;
  late MusicFreePlugins plugins;
  late MusicFreeService service;

  const badPlugin = '''
module.exports = {
  platform: "坏插件",
  version: "1.0.0",
  async search() { throw new Error("搜索故意失败"); },
  async getMediaSource() { throw new Error("解析故意失败"); }
};
''';

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('omioc-mf-service-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((HttpRequest request) async {
      Future<void> json(Object value) async {
        request.response.headers.contentType =
            ContentType('application', 'json', charset: 'utf-8');
        request.response.write(jsonEncode(value));
        await request.response.close();
      }

      final path = request.uri.path;
      if (path == '/search') {
        final q = request.uri.queryParameters['q'] ?? '';
        await json(<String, dynamic>{
          'html': '<ul>'
              '<li class="song" data-id="1" data-hash="h-1">'
              '<span class="title">$q</span><span class="artist">周杰伦</span><img src="/c1.jpg"></li>'
              '<li class="song" data-id="2" data-hash="h-2">'
              '<span class="title">$q 2</span><span class="artist">别人</span><img src="/c2.jpg"></li>'
              '</ul>',
        });
        return;
      }
      if (path == '/resolve') {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
        await json(<String, dynamic>{
          'url': '$base/media/${body['hash']}?quality=${body['quality']}',
          'referer': 'https://example.com/',
          'userAgent': 'TestUA/1.0',
        });
        return;
      }
      if (path == '/toplists') {
        await json(<String, dynamic>{
          'items': [
            <String, dynamic>{'id': 'top-1', 'title': '测试榜单一'},
            <String, dynamic>{'id': 'top-2', 'title': '测试榜单二'},
          ],
        });
        return;
      }
      if (path == '/toplist-detail') {
        await json(<String, dynamic>{
          'items': [
            <String, dynamic>{'id': 's1', 'hash': 'h-1', 'title': '榜单歌曲', 'artist': '歌手'},
          ],
        });
        return;
      }
      if (path == '/sheet-tags') {
        await json(<String, dynamic>{
          'pinned': [
            <String, dynamic>{'id': 'p1', 'title': '置顶'},
          ],
          'groups': [
            <String, dynamic>{
              'title': '语种',
              'tags': [
                <String, dynamic>{'id': 'tag-1', 'title': '华语'},
                <String, dynamic>{'id': 'tag-2', 'title': '欧美'},
              ],
            },
          ],
        });
        return;
      }
      if (path == '/sheets') {
        await json(<String, dynamic>{
          'items': [
            <String, dynamic>{'id': 'sheet-1', 'title': '热门歌单一'},
            <String, dynamic>{'id': 'sheet-2', 'title': '热门歌单二'},
          ],
        });
        return;
      }
      if (path == '/sheet-detail') {
        await json(<String, dynamic>{
          'items': [
            <String, dynamic>{'id': 'sd1', 'hash': 'h-9', 'title': '歌单歌曲', 'artist': '歌手'},
          ],
        });
        return;
      }
      if (path == '/lyric') {
        await json(<String, dynamic>{'lrc': '[00:00.00]测试歌词', 'translation': '[00:00.00]t'});
        return;
      }
      request.response.statusCode = 404;
      await request.response.close();
    });

    host = MusicFreeHost(
      paths: PluginPaths(root: tempRoot.path),
      bundleSource: File('assets/musicfree/runtime.bundle.js').readAsStringSync(),
    );
    plugins = MusicFreePlugins(host: host, paths: PluginPaths(root: tempRoot.path));
    final demo = File('test/fixtures/demo_plugin.js').readAsStringSync().replaceAll('__BASE__', base);
    await plugins.installCode(demo, srcUrl: '$base/plugin.js');
    await plugins.installCode(badPlugin);
    service = MusicFreeService(plugins);
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

  test('搜索聚合多个插件，单个插件失败只进 errors', () async {
    final result = await service.search('晴天');
    expect(result.tracks, hasLength(2));
    expect(result.tracks.first.platform, '测试插件');
    expect(result.tracks.first.name, '晴天');
    expect(result.tracks.first.artistLabel, '周杰伦');
    expect(result.tracks.first.coverUrl, '$base/c1.jpg');
    expect(result.errors, hasLength(1));
    expect(result.errors.first, contains('坏插件'));
  });

  test('搜索结果保留插件原始字段（getMediaSource 才能命中）', () async {
    final result = await service.search('晴天');
    final track = result.tracks.first;
    expect(track.musicInfo['hash'], 'h-1');
    expect(track.musicInfo['sign'], isNotNull);

    final media = await service.mediaSource(track);
    expect(media.url, '$base/media/h-1?quality=standard');
    expect(media.headers['referer'], 'https://example.com/');
    // MusicFree 从 headers 里回填 userAgent
    expect(media.headers['user-agent'], 'TestUA/1.0');
    expect(media.userAgent, 'TestUA/1.0');

    final high = await service.mediaSource(track, qualityOverride: MusicFreeQuality.high);
    expect(high.url, contains('quality=high'));
  });

  test('排行榜：分组、条目与详情', () async {
    final groups = await service.topLists();
    expect(groups, hasLength(1));
    expect(groups.first.title, '测试榜单分组');
    expect(groups.first.items, hasLength(2));
    expect(groups.first.items.first.platform, '测试插件');

    final page = await service.topListDetail(groups.first.items.first);
    expect(page.tracks, hasLength(1));
    expect(page.tracks.first.name, '榜单歌曲');
    expect(page.tracks.first.musicInfo['hash'], 'h-1');
  });
  test('搜索支持按类型 / 音源过滤（类型 tab、音源 tab 的数据源）', () async {
    // 类型 = 插件 supportedSearchType 的并集
    expect(service.searchTypes, containsAll(<String>['music', 'sheet']));
    expect(service.platformsForType('music'), contains('测试插件'));

    // 只看某个音源：别的插件（包括会失败的那个）不参与
    final only = await service.search('晴天', platform: '测试插件');
    expect(only.tracks, hasLength(2));
    expect(only.errors, isEmpty, reason: '坏插件被音源过滤掉了');

    // 不存在的音源：给出明确原因
    final missing = await service.search('晴天', platform: '不存在的音源');
    expect(missing.tracks, isEmpty);
    expect(missing.errors.single, contains('没有提供该类型的搜索'));
  });


  test('热门歌单：标签、歌单列表与歌单详情', () async {
    final tags = await service.recommendTags();
    expect(tags.pinned, hasLength(1));
    expect(tags.groups, hasLength(1));
    expect(tags.groups.first.title, '语种');
    expect(tags.groups.first.tags.map((tag) => tag.title), <String>['华语', '欧美']);

    final sheets = await service.sheetsByTag(tags.groups.first.tags.first);
    expect(sheets, hasLength(2));
    expect(sheets.first.title, '热门歌单一');

    final detail = await service.sheetInfo(sheets.first);
    expect(detail.tracks, hasLength(1));
    expect(detail.tracks.first.name, '歌单歌曲');
  });

  test('歌词按插件能力取用', () async {
    final result = await service.search('晴天');
    final lyric = await service.lyric(result.tracks.first);
    expect(lyric, contains('测试歌词'));
  });

  test('停用插件后不再参与聚合', () async {
    final demo = plugins.plugins.firstWhere((plugin) => plugin.platform == '测试插件');
    await plugins.setEnabled(demo.hash, false);
    final result = await service.search('晴天');
    expect(result.tracks, isEmpty);
    expect(service.withMethod('search').map((plugin) => plugin.platform), <String>['坏插件']);
  });

  // ---------------------------------------------------------------- 速度相关

  /// 永不作答的插件：只能靠截止时间判失败。
  const slowPlugin = '''
module.exports = {
  platform: "慢插件",
  version: "1.0.0",
  supportedSearchType: ["music"],
  async search() {
    await new Promise(function (resolve) { setTimeout(resolve, 60000); });
    return { data: [] };
  }
};
''';

  test('慢音源到点就判失败，不拖累其它音源', () async {
    await plugins.installCode(slowPlugin);
    service.searchTimeout = const Duration(milliseconds: 400);

    final watch = Stopwatch()..start();
    final result = await service.search('晴天');
    watch.stop();

    expect(watch.elapsed, lessThan(const Duration(seconds: 5)), reason: '整轮只等一个截止时间');
    expect(result.tracks, hasLength(2), reason: '快音源的结果照旧返回');
    expect(
      result.errors.any((line) => line.contains('慢插件') && line.contains('超时')),
      isTrue,
      reason: '慢音源单独报超时：${result.errors}',
    );
    expect(result.total, 3);
  });

  test('每个音源返回就回调一次（边搜边显示）', () async {
    final updates = <MusicFreeSearchResult>[];
    final result = await service.search('晴天', onUpdate: updates.add);
    expect(updates, isNotEmpty);
    expect(updates.last.done, result.total);
    expect(updates.any((item) => item.tracks.isNotEmpty), isTrue);
  });

  test('同样的关键词第二次吃本地缓存（服务器停了也能出结果）', () async {
    final first = await service.search('缓存测试');
    expect(first.tracks, isNotEmpty);

    // 关掉服务器：真去请求一定失败，还能出结果说明走的是缓存
    await server.close(force: true);
    final second = await service.search('缓存测试');
    expect(second.tracks, hasLength(first.tracks.length));
    expect(
      second.errors.any((line) => line.contains('测试插件')),
      isFalse,
      reason: '命中缓存就不该再发请求：${second.errors}',
    );
    expect(second.tracks.first.musicInfo['hash'], 'h-1', reason: '缓存的是插件原始对象');

    // refresh 强制重搜：服务器没了，这次必须失败
    final refreshed = await service.search('缓存测试', refresh: true);
    expect(refreshed.tracks, isEmpty);
    expect(refreshed.errors.any((line) => line.contains('测试插件')), isTrue);
  });

  test('连续失败达到阈值后「全部音源」里暂时跳过它', () async {
    service.searchTimeout = const Duration(milliseconds: 500);
    for (var index = 0; index < MusicFreeService.failureThreshold; index += 1) {
      await service.search('阈值$index');
    }
    expect(service.isSkipped('坏插件'), isTrue, reason: '连续失败应该熔断');

    final result = await service.search('阈值之后再搜');
    expect(result.skipped, contains('坏插件'));
    expect(
      result.errors.any((line) => line.contains('坏插件')),
      isFalse,
      reason: '跳过的不再重复报错',
    );

    // 点名要这个音源：照搜（用户愿意等），也不算跳过
    final only = await service.search('阈值之后再搜', platform: '坏插件');
    expect(only.skipped, isEmpty);
    expect(only.errors, isNotEmpty);
  });
}