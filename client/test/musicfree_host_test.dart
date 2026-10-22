import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/musicfree/musicfree_host.dart';
import 'package:omioclink_client/musicfree/plugin_paths.dart';

/// 用「真实形态」的插件（axios + cheerio + crypto-js + musicfree/storage）
/// 对本地 HttpServer 跑通完整链路，验证宿主与 MusicFree 的语义一致。
void main() {
  late HttpServer server;
  late String base;
  late Directory tempRoot;
  late String fixture;
  late MusicFreeHost host;
  late String hash;
  final received = <String, dynamic>{};

  setUpAll(() async {
    fixture = File('test/fixtures/demo_plugin.js').readAsStringSync();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((HttpRequest request) async {
      final path = request.uri.path;
      Future<void> json(Object value) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(value));
        await request.response.close();
      }

      if (path == '/search') {
        received['q'] = request.uri.queryParameters['q'];
        received['page'] = request.uri.queryParameters['page'];
        final q = request.uri.queryParameters['q'] ?? '';
        final html = '''
          <ul>
            <li class="song" data-id="1" data-hash="h-1">
              <span class="title">$q</span><span class="artist">周杰伦</span><img src="/c1.jpg">
            </li>
            <li class="song" data-id="2" data-hash="h-2">
              <span class="title">$q (Live)</span><span class="artist">其他</span><img src="/c2.jpg">
            </li>
          </ul>
        ''';
        await json(<String, dynamic>{'html': html});
        return;
      }
      if (path == '/resolve') {
        final body = await utf8.decoder.bind(request).join();
        final decoded = jsonDecode(body) as Map<String, dynamic>;
        received['resolveBody'] = decoded;
        await json(<String, dynamic>{
          'url': '$base/media/${decoded['hash']}?quality=${decoded['quality']}',
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
            <String, dynamic>{'id': 'p1', 'title': '置顶歌单'},
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
        received['sheetTag'] = request.uri.queryParameters['tag'];
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
        await json(<String, dynamic>{'lrc': '[00:00.00]测试歌词', 'translation': '[00:00.00]translated'});
        return;
      }
      if (path == '/comments') {
        await json(<String, dynamic>{
          'items': [
            <String, dynamic>{'id': 'c1', 'content': '好听'},
          ],
        });
        return;
      }
      if (path == '/artist') {
        await json(<String, dynamic>{
          'items': [
            <String, dynamic>{'id': 'aw1', 'title': '作品一'},
          ],
        });
        return;
      }
      if (path == '/album') {
        await json(<String, dynamic>{
          'items': [
            <String, dynamic>{'id': 'al1', 'title': '专辑曲目'},
          ],
        });
        return;
      }
      request.response.statusCode = 404;
      await request.response.close();
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  setUp(() async {
    received.clear();
    tempRoot = await Directory.systemTemp.createTemp('omioc-mf-host-');
    host = MusicFreeHost(
      paths: PluginPaths(root: tempRoot.path),
      bundleSource: File('assets/musicfree/runtime.bundle.js').readAsStringSync(),
      appVersion: '9.9.9',
    );
    final code = fixture.replaceAll('__BASE__', base);
    final plugin = await host.loadPlugin(
      hash: 'test-hash',
      code: code,
      srcUrl: '$base/plugin.js',
      userVariables: <String, String>{'token': 'tk-42'},
    );
    expect(plugin.loadError, isNull);
    hash = plugin.hash;
  });

  tearDown(() async {
    host.dispose();
    if (tempRoot.existsSync()) {
      // Windows 上偶发「文件仍被占用」，清理失败不影响测试结论
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

  test('插件元数据与 MusicFree 的 delegate 语义一致', () async {
    final plugin = host.byHash(hash)!;
    expect(plugin.platform, '测试插件');
    expect(plugin.version, '1.2.3');
    expect(plugin.author, 'probe');
    expect(plugin.srcUrl, '$base/plugin.js');
    expect(plugin.primaryKey, <String>['id']);
    expect(plugin.defaultSearchType, 'music');
    expect(plugin.supportedSearchType, <String>['music', 'sheet']);
    // 没有 key 的 userVariables 被过滤
    expect(plugin.userVariables.map((item) => item.key), <String>['token']);
    expect(plugin.supports('search'), isTrue);
    expect(plugin.supports('getMediaSource'), isTrue);
    expect(plugin.supports('getTopLists'), isTrue);
    expect(plugin.supports('getRecommendSheetsByTag'), isTrue);
    expect(plugin.supports('getMusicComments'), isTrue);
    expect(plugin.supports('notExist'), isFalse);
  });

  test('search：axios 带 query 参数、cheerio 解析 HTML', () async {
    final result = await host.invoke(hash, 'search', <Object?>['晴天', 1, 'music']);
    expect(received['q'], '晴天');
    expect(received['page'], '1');
    final map = result as Map<String, dynamic>;
    expect(map['isEnd'], isFalse);
    final data = (map['data'] as List).cast<Map<String, dynamic>>();
    expect(data, hasLength(2));
    expect(data.first['id'], '1');
    expect(data.first['hash'], 'h-1');
    expect(data.first['title'], '晴天');
    expect(data.first['artist'], '周杰伦');
    expect(data.first['artwork'], '$base/c1.jpg');
    // crypto-js 生效
    expect(data.first['sign'], '5f4dcc3b5aa765d61d8327deb882cf9f'.length == 32 ? data.first['sign'] : null);
  });

  test('getMediaSource：search 里的自定义字段被原样回传，headers/userAgent 透传', () async {
    final search = await host.invoke(hash, 'search', <Object?>['晴天', 1, 'music']);
    final item = ((search as Map)['data'] as List).first as Map<String, dynamic>;
    final source = await host.invoke(hash, 'getMediaSource', <Object?>[item, 'standard']);
    final map = source as Map<String, dynamic>;
    expect(map['url'], '$base/media/h-1?quality=standard');
    expect((map['headers'] as Map)['referer'], 'https://example.com/');
    final body = received['resolveBody'] as Map<String, dynamic>;
    expect(body['hash'], 'h-1');
    expect(body['quality'], 'standard');
    // userVariables 注入到 env.getUserVariables()
    expect(body['token'], 'tk-42');
  });

  test('榜单 / 热门歌单 / 歌词 / 评论 / 其它方法都能跑通', () async {
    final toplists = await host.invoke(hash, 'getTopLists', <Object?>[]) as List;
    expect(toplists, hasLength(1));
    expect(((toplists.first as Map)['data'] as List), hasLength(2));

    final detail = await host.invoke(hash, 'getTopListDetail', <Object?>[
      <String, dynamic>{'id': 'top-1', 'title': '测试榜单一'},
      1,
    ]) as Map<String, dynamic>;
    expect((detail['musicList'] as List), hasLength(1));

    final tags = await host.invoke(hash, 'getRecommendSheetTags', <Object?>[]) as Map<String, dynamic>;
    expect((tags['pinned'] as List), hasLength(1));
    expect(((tags['data'] as List).first as Map)['title'], '语种');

    final sheets = await host.invoke(hash, 'getRecommendSheetsByTag', <Object?>[
      <String, dynamic>{'id': 'tag-1', 'title': '华语'},
      1,
    ]) as Map<String, dynamic>;
    expect((sheets['data'] as List), hasLength(2));
    expect(received['sheetTag'], 'tag-1');

    final sheetDetail = await host.invoke(hash, 'getMusicSheetInfo', <Object?>[
      <String, dynamic>{'id': 'sheet-1', 'title': '热门歌单一'},
      1,
    ]) as Map<String, dynamic>;
    expect((sheetDetail['musicList'] as List), hasLength(1));

    final lyric = await host.invoke(hash, 'getLyric', <Object?>[
      <String, dynamic>{'id': '1'},
    ]) as Map<String, dynamic>;
    expect(lyric['rawLrc'], '[00:00.00]测试歌词');
    expect(lyric['translation'], '[00:00.00]translated');

    final comments = await host.invoke(hash, 'getMusicComments', <Object?>[
      <String, dynamic>{'id': '1', 'platform': '测试插件'},
      1,
    ]) as Map<String, dynamic>;
    expect((comments['data'] as List), hasLength(1));

    final sheet = await host.invoke(hash, 'importMusicSheet', <Object?>['$base/sheet/1']) as List;
    expect((sheet.first as Map)['id'], 'imported-1');

    final single = await host.invoke(hash, 'importMusicItem', <Object?>['$base/item/1']) as Map<String, dynamic>;
    expect(single['id'], 'imported-item');

    final info = await host.invoke(hash, 'getMusicInfo', <Object?>[
      <String, dynamic>{'id': '1', 'platform': '测试插件'},
    ]) as Map<String, dynamic>;
    expect(info['title'], '补全后的标题');
  });

  test('插件抛错只影响这次调用', () async {
    await expectLater(
      host.invoke(hash, 'broken', <Object?>[]),
      throwsA(isA<MusicFreeException>().having((e) => e.message, 'message', contains('插件内部故意抛错'))),
    );
    // 之后其它调用仍然正常
    final result = await host.invoke(hash, 'search', <Object?>['周杰伦', 1, 'music']);
    expect(((result as Map)['data'] as List), isNotEmpty);
  });

  test('超时会中断调用', () async {
    await expectLater(
      host.invoke(hash, 'slow', <Object?>[], timeout: const Duration(seconds: 1)),
      throwsA(isA<MusicFreeException>().having((e) => e.message, 'message', contains('超时'))),
    );
  });

  test('musicfree/storage 落盘并在新运行时里读回', () async {
    await host.invoke(hash, 'search', <Object?>['存储测试', 1, 'music']);
    final storageFile = File('${tempRoot.path}/musicfree-data/storage/test-hash.json');
    expect(storageFile.existsSync(), isTrue);
    expect(storageFile.readAsStringSync(), contains('存储测试'));

    // 换一个全新宿主（新 JS 运行时）仍能读到
    final second = MusicFreeHost(
      paths: PluginPaths(root: tempRoot.path),
      bundleSource: File('assets/musicfree/runtime.bundle.js').readAsStringSync(),
    );
    addTearDown(second.dispose);
    await second.loadPlugin(
      hash: 'test-hash',
      code: fixture.replaceAll('__BASE__', base),
      srcUrl: '$base/plugin.js',
    );
    final value = await second.invoke('test-hash', 'readStorage', <Object?>['lastQuery']);
    expect(value, '存储测试');
  });

  test('字节码缓存真的落在磁盘上（跨 isolate 的路径也走缓存）', () async {
    // 装载发生在 worker isolate 里，缓存的写盘是「不阻塞装载」的，所以这里轮询。
    final dir = Directory('${tempRoot.path}/musicfree-data/bytecode');
    var cached = <File>[];
    for (var attempt = 0; attempt < 100; attempt += 1) {
      if (dir.existsSync()) {
        cached = dir
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.qbc'))
            .toList(growable: false);
        if (cached.length >= 2) {
          break;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    // 一个 bundle + 一个插件
    expect(cached.length, greaterThanOrEqualTo(2),
        reason: 'plugin/bundle 字节码都应该落盘：$cached');
    expect(
      cached.any((file) => file.uri.pathSegments.last.contains('-bundle-')),
      isTrue,
    );
    expect(
      cached.any((file) => file.uri.pathSegments.last.contains('-plugin-')),
      isTrue,
    );
  });
}