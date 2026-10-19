import 'dart:async';

import '../core/app_log.dart';
import '../data/music_models.dart';
import 'musicfree_cache.dart';
import 'musicfree_host.dart';
import 'musicfree_plugins.dart';
import 'plugin_models.dart';

/// 音质键，与 MusicFree 的 `IQualityKey` 完全一致。
enum MusicFreeQuality { low, standard, high, super_ }

extension MusicFreeQualityKey on MusicFreeQuality {
  String get key => switch (this) {
    MusicFreeQuality.low => 'low',
    MusicFreeQuality.standard => 'standard',
    MusicFreeQuality.high => 'high',
    MusicFreeQuality.super_ => 'super',
  };

  String get label => switch (this) {
    MusicFreeQuality.low => '流畅',
    MusicFreeQuality.standard => '标准',
    MusicFreeQuality.high => '高品',
    MusicFreeQuality.super_ => '无损',
  };

  static MusicFreeQuality fromKey(String? key) {
    return switch ((key ?? '').trim()) {
      'low' => MusicFreeQuality.low,
      'high' => MusicFreeQuality.high,
      'super' => MusicFreeQuality.super_,
      _ => MusicFreeQuality.standard,
    };
  }
}

/// 解析出来的播放地址（含插件要求的请求头）。
class MusicFreeMediaSource {
  const MusicFreeMediaSource({required this.url, this.headers = const <String, String>{}, this.userAgent});

  final String url;
  final Map<String, String> headers;
  final String? userAgent;
}

/// 榜单 / 歌单条目（对应 MusicFree 的 `IMusicSheetItem`）。
class MusicFreeSheet {
  const MusicFreeSheet({
    required this.platform,
    required this.id,
    required this.title,
    this.coverUrl,
    this.creator,
    this.description,
    this.raw = const <String, dynamic>{},
  });

  final String platform;
  final String id;
  final String title;
  final String? coverUrl;
  final String? creator;
  final String? description;

  /// 插件给的原始对象：翻页/取详情时要原样传回。
  final Map<String, dynamic> raw;

  String get key => '$platform:$id';
}

class MusicFreeTopListGroup {
  const MusicFreeTopListGroup({required this.platform, required this.title, required this.items});

  final String platform;
  final String title;
  final List<MusicFreeSheet> items;
}

class MusicFreeTag {
  const MusicFreeTag({required this.platform, required this.id, required this.title, this.raw});

  final String platform;
  final String id;
  final String title;
  final Map<String, dynamic>? raw;
}

class MusicFreeTagGroup {
  const MusicFreeTagGroup({required this.title, required this.tags});

  final String title;
  final List<MusicFreeTag> tags;
}

class MusicFreeTags {
  const MusicFreeTags({this.pinned = const <MusicFreeTag>[], this.groups = const <MusicFreeTagGroup>[]});

  final List<MusicFreeTag> pinned;
  final List<MusicFreeTagGroup> groups;

  bool get isEmpty => pinned.isEmpty && groups.isEmpty;
}

class MusicFreeTrackPage {
  const MusicFreeTrackPage({required this.tracks, this.isEnd = true, this.errors = const <String>[]});

  final List<MusicTrack> tracks;
  final bool isEnd;
  final List<String> errors;
}

/// 一次（一轮）搜索结果。
///
/// [done] / [total] 是给「边搜边显示」用的：每有一个音源返回（或超时）就回调一次，
/// 界面据此判断「已经收到几个音源、还剩几个」，不用整轮转圈。
class MusicFreeSearchResult {
  const MusicFreeSearchResult({
    required this.tracks,
    this.errors = const <String>[],
    this.skipped = const <String>[],
    this.done = 0,
    this.total = 0,
  });

  final List<MusicTrack> tracks;
  final List<String> errors;

  /// 本轮被临时跳过的音源（连续失败，熔断中）。
  final List<String> skipped;

  /// 已返回 / 总参与的音源数。
  final int done;
  final int total;
}

/// 点歌台的服务层：把各插件的 MusicFree 方法聚合成界面要的数据。
///
/// 与 MusicFree 的 renderer 侧 `PluginManager` 一致：
/// * 只调用「支持该方法」的插件；
/// * 单个插件失败不影响别人（错误单独收集）；
/// * 结果统一补 `platform`，并保留插件原始对象供后续 `getMediaSource` 使用。
class MusicFreeService {
  MusicFreeService(this.plugins, {MusicFreeCache? cache}) : _cacheOverride = cache;

  final MusicFreePlugins plugins;

  MusicFreeQuality quality = MusicFreeQuality.standard;

  /// 「全部音源」搜索的单个音源截止时间。
  ///
  /// MusicFree 是「一次只搜一个音源、回来一个显示一个」，所以慢音源从来不会拖累
  /// 别人；聚合搜索没有这个便利，只能靠截止时间：超过就判这个音源失败，
  /// 结果照旧显示（谁回来算谁的），界面也不再整轮转圈。
  Duration searchTimeout = const Duration(milliseconds: 2000);

  /// 指定了某个音源时多等一会儿：用户就是想听这个源，急着判失败没意义。
  Duration singleSourceTimeout = const Duration(seconds: 8);

  /// 榜单 / 歌单详情 / 歌词这类「点进去才发」的请求。
  Duration detailTimeout = const Duration(seconds: 8);

  /// 聚合加载（排行榜分组、歌单标签）的单个音源截止时间。
  ///
  /// 这类是「进页面就要」的数据，等太久整屏都空着：4 秒没给就说一声拉倒。
  Duration listTimeout = const Duration(seconds: 4);

  /// 连续失败几次之后把音源熔断掉多久。
  static const int failureThreshold = 3;
  static const Duration skipWindow = Duration(minutes: 5);

  final Map<String, int> _failures = <String, int>{};
  final Map<String, DateTime> _skipUntil = <String, DateTime>{};

  /// 榜单 / 标签这类「一进页面就要」的数据，内存里放 10 分钟。
  static const Duration _listTtl = Duration(minutes: 10);
  final _MemoryCache _memory = _MemoryCache();

  final MusicFreeCache? _cacheOverride;
  MusicFreeCache? _cacheInstance;

  MusicFreeCache get cache =>
      _cacheInstance ??= (_cacheOverride ?? MusicFreeCache(dir: plugins.paths.cacheDir));

  /// 某个音源现在是否在熔断期（「全部音源」里会被跳过）。
  ///
  /// 只按**搜索**记账：榜单 / 歌单失败不应该连坐搜索（反之亦然），
  /// 否则一个「能搜不能看榜」的音源会被莫名跳过。
  bool isSkipped(String platform) {
    final until = _skipUntil[platform];
    if (until == null) {
      return false;
    }
    if (DateTime.now().isBefore(until)) {
      return true;
    }
    _skipUntil.remove(platform);
    _failures.remove(platform);
    return false;
  }

  /// 当前处于熔断期的音源（界面上说明「暂时跳过」用）。
  ///
  /// 先拷贝键再过滤：`isSkipped` 在过期时会顺手删 map，边遍历边删会抛
  /// `ConcurrentModificationError`。
  List<String> get skippedPlatforms {
    final platforms = List<String>.of(_skipUntil.keys);
    return platforms.where(isSkipped).toList(growable: false);
  }

  void _noteSuccess(String platform) {
    _failures.remove(platform);
    _skipUntil.remove(platform);
  }

  void _noteFailure(String platform) {
    final count = (_failures[platform] ?? 0) + 1;
    _failures[platform] = count;
    if (count >= failureThreshold) {
      _skipUntil[platform] = DateTime.now().add(skipWindow);
      AppLog.info('音源「$platform」连续失败 $count 次，暂时跳过 ${skipWindow.inMinutes} 分钟');
    }
  }

  /// 插件换了 / 用户手动重试：缓存与熔断状态一起清掉。
  Future<void> clearCache() async {
    _memory.clear();
    _failures.clear();
    _skipUntil.clear();
    await cache.clear();
  }

  List<MusicFreePlugin> get allPlugins => plugins.plugins;

  List<MusicFreePlugin> get enabledPlugins => plugins.enabledPlugins;

  List<MusicFreePlugin> withMethod(String method) =>
      enabledPlugins.where((plugin) => plugin.supports(method)).toList(growable: false);

  bool get hasSearchPlugin => withMethod(MusicFreeCapabilities.search).isNotEmpty;

  // ------------------------------------------------------------------ 搜索
  /// 插件声明支持的搜索类型并集（顺序固定：音乐 / 专辑 / 作者 / 歌单，其余按插件顺序）。
  ///
  /// 与 MusicFree 一致：类型是插件能力（`supportedSearchType`），不是客户端写死的。
  List<String> get searchTypes {
    final types = <String>{};
    for (final plugin in withMethod(MusicFreeCapabilities.search)) {
      for (final type in plugin.supportedSearchType) {
        if (type.isNotEmpty) {
          types.add(type);
        }
      }
    }
    if (types.isEmpty) {
      return const <String>['music'];
    }
    final ordered = <String>[
      for (final type in const <String>['music', 'album', 'artist', 'playlist'])
        if (types.remove(type)) type,
    ];
    ordered.addAll(types);
    return ordered;
  }

  /// 某个类型下能搜的音源（platform 列表，保持插件顺序）。
  List<String> platformsForType(String type) => <String>[
    for (final plugin in withMethod(MusicFreeCapabilities.search))
      if (plugin.supportedSearchType.isEmpty ||
          plugin.supportedSearchType.contains(type))
        plugin.platform,
  ];

  /// 聚合搜索：谁先回来先显示。
  ///
  /// 与 MusicFree 的差别在于它是「一次只搜一个音源」，我们是「一次搜全部」，
  /// 所以慢音源的代价得自己压掉：
  ///
  /// * 到 [searchTimeout]（默认 2 秒）就判这个音源失败，不再等它的 10 秒超时；
  /// * 每回来一个音源就通过 [onUpdate] 回调一次，界面不必等到最后一个才显示；
  /// * 连续失败的音源熔断 [skipWindow]，之后的「全部音源」搜索直接跳过；
  /// * 命中本地缓存（[MusicFreeCache]）的音源立刻返回，连请求都不发。
  Future<MusicFreeSearchResult> search(
    String keyword, {
    int page = 1,
    String type = 'music',
    String? platform,
    bool refresh = false,
    void Function(MusicFreeSearchResult partial)? onUpdate,
  }) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) {
      return const MusicFreeSearchResult(tracks: <MusicTrack>[]);
    }
    final targets = <MusicFreePlugin>[
      for (final plugin in withMethod(MusicFreeCapabilities.search))
        if ((platform == null || plugin.platform == platform) &&
            (plugin.supportedSearchType.isEmpty ||
                plugin.supportedSearchType.contains(type)))
          plugin,
    ];
    if (targets.isEmpty) {
      return MusicFreeSearchResult(
        tracks: const <MusicTrack>[],
        errors: <String>[
          if (allPlugins.isEmpty)
            '还没有安装音乐插件'
          else if (platform != null)
            '「${musicPlatformLabel(platform)}」这个音源没有提供该类型的搜索'
          else
            '没有插件支持搜索',
        ],
      );
    }

    // 熔断中的音源在「全部音源」里跳过；用户点名要的照搜（他愿意等）。
    final skipped = <String>[];
    final active = <MusicFreePlugin>[];
    for (final plugin in targets) {
      if (platform == null && !refresh && isSkipped(plugin.platform)) {
        skipped.add(plugin.platform);
      } else {
        active.add(plugin);
      }
    }
    if (active.isEmpty) {
      return MusicFreeSearchResult(
        tracks: const <MusicTrack>[],
        errors: <String>[
          '音源暂时都不可用（${skipped.map(musicPlatformLabel).join('、')}），稍后会自动重试',
        ],
        skipped: skipped,
        total: targets.length,
      );
    }

    final timeout = platform == null ? searchTimeout : singleSourceTimeout;
    final pages = List<MusicFreeTrackPage?>.filled(active.length, null);
    final errors = <String>[];
    var done = 0;

    MusicFreeSearchResult snapshot() {
      final tracks = <MusicTrack>[];
      for (final item in pages) {
        if (item != null) {
          tracks.addAll(item.tracks);
        }
      }
      return MusicFreeSearchResult(
        tracks: tracks,
        errors: List<String>.unmodifiable(errors),
        skipped: skipped,
        done: done,
        total: active.length,
      );
    }

    // 注意：这里刻意不用 `await for`，每个音源各自跑完就回调，
    // 慢的那个（2 秒上限）只影响它自己。
    await Future.wait<void>(<Future<void>>[
      for (var index = 0; index < active.length; index += 1)
        () async {
          final result = await _searchOne(
            active[index],
            trimmed,
            page,
            type: type,
            timeout: timeout,
            refresh: refresh,
          );
          pages[index] = result;
          errors.addAll(result.errors);
          done += 1;
          onUpdate?.call(snapshot());
        }(),
    ]);
    return snapshot();
  }

  /// 只搜一个插件。[type] 由调用方给出（类型 tab 选的），不再用插件自己的默认值。
  ///
  /// 顺序是「缓存 → 插件」，插件失败（含到期未返回）只记一条给人看的原因。
  Future<MusicFreeTrackPage> _searchOne(
    MusicFreePlugin plugin,
    String keyword,
    int page, {
    required String type,
    required Duration timeout,
    bool refresh = false,
  }) async {
    final key = 'search|${plugin.hash}|$type|$page|$keyword';
    if (!refresh) {
      final cached = await _readCache(key);
      if (cached != null) {
        final tracks = _tracksFromRaw(plugin, cached['data']);
        if (tracks.isNotEmpty) {
          return MusicFreeTrackPage(
            tracks: tracks,
            isEnd: cached['isEnd'] != false,
          );
        }
      }
    }
    try {
      final raw = await plugins.host.invoke(
        plugin.hash,
        MusicFreeCapabilities.search,
        <Object?>[keyword, page, type],
        timeout: timeout,
        flushWrites: false,
      );
      final map = raw is Map ? raw.cast<String, dynamic>() : const <String, dynamic>{};
      final tracks = _tracksFromRaw(plugin, map['data']);
      _noteSuccess(plugin.platform);
      if (tracks.isNotEmpty) {
        // 只缓存有内容的页：空结果可能只是这一秒抽风，缓存它反而害人。
        _writeCache(key, <String, dynamic>{
          'data': map['data'],
          'isEnd': map['isEnd'] != false,
        });
      }
      return MusicFreeTrackPage(tracks: tracks, isEnd: map['isEnd'] != false);
    } on Object catch (error) {
      final message = _message(error);
      AppLog.warn('插件搜索失败 ${plugin.platform}', error: error);
      _noteFailure(plugin.platform);
      return MusicFreeTrackPage(
        tracks: const <MusicTrack>[],
        errors: <String>['${musicPlatformLabel(plugin.platform)}：${_shortReason(message)}'],
      );
    }
  }

  List<MusicTrack> _tracksFromRaw(MusicFreePlugin plugin, Object? data) {
    final tracks = <MusicTrack>[];
    if (data is List) {
      for (final item in data) {
        final track = _toTrack(plugin, item);
        if (track != null) {
          tracks.add(track);
        }
      }
    }
    return tracks;
  }

  Future<Map<String, dynamic>?> _readCache(String key) async {
    try {
      return await cache.read(key);
    } on Object catch (error) {
      AppLog.debug('读缓存失败 $key：$error');
      return null;
    }
  }

  void _writeCache(String key, Map<String, dynamic> value) {
    unawaited(cache.write(key, value).catchError((Object error) {
      AppLog.debug('写缓存失败 $key：$error');
    }));
  }

  static String _shortReason(String message) {
    final oneLine = message.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (oneLine.length <= 120) {
      return oneLine;
    }
    return '${oneLine.substring(0, 120)}…';
  }

  // ---------------------------------------------------------------- 排行榜
  /// 各插件提供的榜单分组。
  ///
  /// 以前是一个插件一个插件地 `await`，几十个插件排队加载光等就得好几秒；
  /// 现在并发跑 + [detailTimeout] 截止，再叠 10 分钟内存缓存（进进出出点歌台
  /// 不必重拉）。结果按插件顺序重排，界面的 tab 不会因为谁先回来而乱跳。
  Future<List<MusicFreeTopListGroup>> topLists({bool refresh = false}) async {
    const key = 'toplists';
    if (!refresh) {
      final cached = _memory.read(key);
      if (cached is List<MusicFreeTopListGroup>) {
        return cached;
      }
    }
    final targets = withMethod(MusicFreeCapabilities.getTopLists);
    final perPlugin = List<List<MusicFreeTopListGroup>>.generate(
      targets.length,
      (_) => <MusicFreeTopListGroup>[],
    );
    await Future.wait<void>(<Future<void>>[
      for (var index = 0; index < targets.length; index += 1)
        () async {
          final plugin = targets[index];
          try {
            final raw = await plugins.host.invoke(
              plugin.hash,
              MusicFreeCapabilities.getTopLists,
              <Object?>[],
              timeout: listTimeout,
              flushWrites: false,
            );
            if (raw is! List) {
              return;
            }
            final groups = <MusicFreeTopListGroup>[];
            for (final group in raw) {
              if (group is! Map) {
                continue;
              }
              final title = group['title']?.toString() ?? plugin.platform;
              final data = group['data'];
              final items = <MusicFreeSheet>[];
              if (data is List) {
                for (final item in data) {
                  final sheet = _toSheet(plugin, item);
                  if (sheet != null) {
                    items.add(sheet);
                  }
                }
              }
              if (items.isNotEmpty) {
                groups.add(
                  MusicFreeTopListGroup(
                    platform: plugin.platform,
                    title: title,
                    items: items,
                  ),
                );
              }
            }
            perPlugin[index] = groups;
          } on Object catch (error) {
            // 榜单失败不记账到搜索熔断里：两个方法族互不连坐。
            AppLog.warn('获取榜单失败 ${plugin.platform}', error: error);
          }
        }(),
    ]);
    final groups = <MusicFreeTopListGroup>[
      for (final item in perPlugin) ...item,
    ];
    // 一个都没拿到（网络抖动 / 全超时）就别缓存了，否则接下来 10 分钟都显示
    // 「插件没有提供排行榜」这种错误归因。
    if (groups.isNotEmpty) {
      _memory.write(key, groups, _listTtl);
    }
    return groups;
  }

  Future<MusicFreeTrackPage> topListDetail(MusicFreeSheet sheet, {int page = 1}) async {
    return _sheetTracks(
      sheet,
      MusicFreeCapabilities.getTopListDetail,
      page,
      listKey: 'musicList',
    );
  }

  // ------------------------------------------------------------ 热门歌单
  /// 歌单标签（同样并发 + 缓存，理由同 [topLists]）。
  Future<MusicFreeTags> recommendTags({bool refresh = false}) async {
    const key = 'tags';
    if (!refresh) {
      final cached = _memory.read(key);
      if (cached is MusicFreeTags) {
        return cached;
      }
    }
    final targets = withMethod(MusicFreeCapabilities.getRecommendSheetTags);
    final perPlugin = List<MusicFreeTags>.generate(
      targets.length,
      (_) => const MusicFreeTags(),
    );
    await Future.wait<void>(<Future<void>>[
      for (var index = 0; index < targets.length; index += 1)
        () async {
          final plugin = targets[index];
          try {
            final raw = await plugins.host.invoke(
              plugin.hash,
              MusicFreeCapabilities.getRecommendSheetTags,
              <Object?>[],
              timeout: listTimeout,
              flushWrites: false,
            );
            if (raw is! Map) {
              return;
            }
            final pinned = <MusicFreeTag>[];
            final pinnedData = raw['pinned'];
            if (pinnedData is List) {
              for (final item in pinnedData) {
                final tag = _toTag(plugin, item);
                if (tag != null) {
                  pinned.add(tag);
                }
              }
            }
            final groups = <MusicFreeTagGroup>[];
            final groupData = raw['data'];
            if (groupData is List) {
              for (final group in groupData) {
                if (group is! Map) {
                  continue;
                }
                final tags = <MusicFreeTag>[];
                final tagList = group['data'];
                if (tagList is List) {
                  for (final item in tagList) {
                    final tag = _toTag(plugin, item);
                    if (tag != null) {
                      tags.add(tag);
                    }
                  }
                }
                if (tags.isNotEmpty) {
                  groups.add(
                    MusicFreeTagGroup(
                      title: group['title']?.toString() ?? plugin.platform,
                      tags: tags,
                    ),
                  );
                }
              }
            }
            perPlugin[index] = MusicFreeTags(pinned: pinned, groups: groups);
          } on Object catch (error) {
            AppLog.warn('获取歌单标签失败 ${plugin.platform}', error: error);
          }
        }(),
    ]);
    final tags = MusicFreeTags(
      pinned: <MusicFreeTag>[for (final item in perPlugin) ...item.pinned],
      groups: <MusicFreeTagGroup>[for (final item in perPlugin) ...item.groups],
    );
    if (!tags.isEmpty) {
      _memory.write(key, tags, _listTtl);
    }
    return tags;
  }

  Future<MusicFreeTrackPage> recommendSheetsByTag(MusicFreeTag tag, {int page = 1}) async {
    final plugin = _pluginOf(tag.platform);
    if (plugin == null || !plugin.supports(MusicFreeCapabilities.getRecommendSheetsByTag)) {
      return const MusicFreeTrackPage(tracks: <MusicTrack>[]);
    }
    return _sheetTracks(
      MusicFreeSheet(platform: tag.platform, id: tag.id, title: tag.title, raw: tag.raw ?? const <String, dynamic>{}),
      MusicFreeCapabilities.getRecommendSheetsByTag,
      page,
      listKey: 'data',
      asSheets: true,
    );
  }

  /// 热门歌单里的歌单条目（`getRecommendSheetsByTag` 返回的是歌单而不是歌曲）。
  Future<List<MusicFreeSheet>> sheetsByTag(MusicFreeTag tag, {int page = 1}) async {
    final plugin = _pluginOf(tag.platform);
    if (plugin == null || !plugin.supports(MusicFreeCapabilities.getRecommendSheetsByTag)) {
      return const <MusicFreeSheet>[];
    }
    try {
      final raw = await plugins.host.invoke(
        plugin.hash,
        MusicFreeCapabilities.getRecommendSheetsByTag,
        <Object?>[tag.raw ?? <String, dynamic>{'id': tag.id, 'title': tag.title}, page],
        timeout: detailTimeout,
        flushWrites: false,
      );
      if (raw is! Map) {
        return const <MusicFreeSheet>[];
      }
      final data = raw['data'];
      if (data is! List) {
        return const <MusicFreeSheet>[];
      }
      final sheets = <MusicFreeSheet>[];
      for (final item in data) {
        final sheet = _toSheet(plugin, item);
        if (sheet != null) {
          sheets.add(sheet);
        }
      }
      return sheets;
    } on Object catch (error) {
      AppLog.warn('获取歌单列表失败 ${plugin.platform}', error: error);
      return const <MusicFreeSheet>[];
    }
  }

  Future<MusicFreeTrackPage> sheetInfo(MusicFreeSheet sheet, {int page = 1}) {
    return _sheetTracks(
      sheet,
      MusicFreeCapabilities.getMusicSheetInfo,
      page,
      listKey: 'musicList',
    );
  }

  Future<MusicFreeTrackPage> _sheetTracks(
    MusicFreeSheet sheet,
    String method,
    int page, {
    required String listKey,
    bool asSheets = false,
  }) async {
    final plugin = _pluginOf(sheet.platform);
    if (plugin == null || !plugin.supports(method)) {
      return const MusicFreeTrackPage(tracks: <MusicTrack>[]);
    }
    try {
      final raw = await plugins.host.invoke(
        plugin.hash,
        method,
        <Object?>[sheet.raw, page],
        timeout: detailTimeout,
        flushWrites: false,
      );
      if (raw is! Map) {
        return const MusicFreeTrackPage(tracks: <MusicTrack>[]);
      }
      final list = raw[listKey];
      final tracks = <MusicTrack>[];
      if (list is List) {
        for (final item in list) {
          final track = _toTrack(plugin, item);
          if (track != null) {
            tracks.add(track);
          }
        }
      }
      return MusicFreeTrackPage(tracks: tracks, isEnd: raw['isEnd'] != false);
    } on Object catch (error) {
      AppLog.warn('获取列表失败 ${plugin.platform}', error: error);
      return MusicFreeTrackPage(
        tracks: const <MusicTrack>[],
        errors: <String>['${plugin.platform}：${_message(error)}'],
      );
    }
  }

  // ------------------------------------------------------------ 播放 / 歌词
  Future<MusicFreeMediaSource> mediaSource(MusicTrack track, {MusicFreeQuality? qualityOverride}) async {
    final plugin = _pluginOf(track.platform);
    if (plugin == null) {
      throw MusicFreeException('找不到平台「${track.platform}」对应的插件');
    }
    // 原样传回插件自己产出的对象（只补 platform，避免丢字段）
    final item = <String, dynamic>{
      ...track.musicInfo,
      'platform': track.platform,
      'id': track.musicInfo['id'] ?? track.id,
    };
    final key = (qualityOverride ?? quality).key;
    if (!plugin.supports(MusicFreeCapabilities.getMediaSource)) {
      final fallback = _qualityUrlFromItem(item, key);
      if (fallback != null) {
        return MusicFreeMediaSource(url: fallback);
      }
      throw MusicFreeException('插件「${plugin.platform}」不支持解析播放地址');
    }
    final raw = await plugins.host.invoke(
      plugin.hash,
      MusicFreeCapabilities.getMediaSource,
      <Object?>[item, key],
      timeout: detailTimeout,
      flushWrites: false,
    );
    if (raw is! Map) {
      throw MusicFreeException('插件「${plugin.platform}」没有返回播放地址');
    }
    final url = raw['url']?.toString() ?? '';
    if (url.isEmpty) {
      final fallback = _qualityUrlFromItem(item, key);
      if (fallback != null) {
        return MusicFreeMediaSource(url: fallback);
      }
      throw MusicFreeException('插件「${plugin.platform}」没有返回播放地址');
    }
    final headers = <String, String>{};
    final rawHeaders = raw['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((headerKey, value) {
        if (value != null) {
          headers[headerKey.toString()] = value.toString();
        }
      });
    }
    // MusicFree 的 PluginMethods 也是从 headers 里回填 userAgent 的
    final declaredAgent = raw['userAgent']?.toString();
    final agentEntries = headers.entries
        .where((entry) => entry.key.toLowerCase() == 'user-agent')
        .toList(growable: false);
    final headerAgent = agentEntries.isEmpty ? null : agentEntries.first.value;
    final userAgent = (declaredAgent != null && declaredAgent.isNotEmpty)
        ? declaredAgent
        : (headerAgent != null && headerAgent.isNotEmpty ? headerAgent : null);
    if (userAgent != null) {
      headers.putIfAbsent('user-agent', () => userAgent);
    }
    return MusicFreeMediaSource(url: url, headers: headers, userAgent: userAgent);
  }

  Future<String?> lyric(MusicTrack track) async {
    final plugin = _pluginOf(track.platform);
    if (plugin == null || !plugin.supports(MusicFreeCapabilities.getLyric)) {
      return null;
    }
    try {
      final raw = await plugins.host.invoke(
        plugin.hash,
        MusicFreeCapabilities.getLyric,
        <Object?>[
          <String, dynamic>{...track.musicInfo, 'platform': track.platform, 'id': track.musicInfo['id'] ?? track.id},
        ],
        timeout: detailTimeout,
        flushWrites: false,
      );
      if (raw is Map) {
        final text = raw['rawLrc']?.toString() ?? raw['translation']?.toString() ?? '';
        return text.isEmpty ? null : text;
      }
      return null;
    } on Object catch (error) {
      AppLog.warn('获取歌词失败 ${plugin.platform}', error: error);
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> comments(MusicTrack track, {int page = 1}) async {
    final plugin = _pluginOf(track.platform);
    if (plugin == null || !plugin.supports(MusicFreeCapabilities.getMusicComments)) {
      return const <Map<String, dynamic>>[];
    }
    try {
      final raw = await plugins.host.invoke(
        plugin.hash,
        MusicFreeCapabilities.getMusicComments,
        <Object?>[
          <String, dynamic>{...track.musicInfo, 'platform': track.platform, 'id': track.musicInfo['id'] ?? track.id},
          page,
        ],
        timeout: detailTimeout,
        flushWrites: false,
      );
      if (raw is Map && raw['data'] is List) {
        return (raw['data'] as List)
            .whereType<Map>()
            .map((item) => item.cast<String, dynamic>())
            .toList(growable: false);
      }
      return const <Map<String, dynamic>>[];
    } on Object catch (error) {
      AppLog.warn('获取评论失败 ${plugin.platform}', error: error);
      return const <Map<String, dynamic>>[];
    }
  }

  // ---------------------------------------------------------------- 映射
  MusicFreePlugin? _pluginOf(String platform) {
    for (final plugin in plugins.plugins) {
      if (plugin.platform == platform) {
        return plugin;
      }
    }
    return null;
  }

  MusicTrack? _toTrack(MusicFreePlugin plugin, Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final item = raw.map((key, value) => MapEntry(key.toString(), value));
    final id = item['id']?.toString() ?? '';
    if (id.isEmpty) {
      return null;
    }
    final platform = item['platform']?.toString();
    final resolvedPlatform = platform == null || platform.isEmpty ? plugin.platform : platform;
    item['platform'] = resolvedPlatform;
    item['id'] = id;
    final artists = <MusicArtist>[];
    final artistList = item['artistList'];
    if (artistList is List) {
      for (final artist in artistList) {
        final name = artist is Map ? artist['name']?.toString() ?? '' : artist?.toString() ?? '';
        if (name.isNotEmpty) {
          artists.add(MusicArtist(id: artist is Map ? artist['id']?.toString() : null, name: name));
        }
      }
    }
    if (artists.isEmpty) {
      final artistText = item['artist']?.toString() ?? '';
      for (final name in artistText.split(RegExp(r'\s*[/、,&]\s*'))) {
        if (name.trim().isNotEmpty) {
          artists.add(MusicArtist(name: name.trim()));
        }
      }
    }
    final albumName = item['album']?.toString();
    final artwork = item['artwork']?.toString();
    final duration = item['duration'];
    return MusicTrack(
      platform: resolvedPlatform,
      id: id,
      name: item['title']?.toString() ?? '',
      artists: artists,
      album: (albumName == null || albumName.isEmpty) && (artwork == null || artwork.isEmpty)
          ? null
          : MusicAlbum(
              id: item['albumId']?.toString(),
              name: albumName,
              coverUrl: artwork,
            ),
      durationMs: duration is num && duration > 0 ? (duration * 1000).round() : null,
      coverUrl: artwork,
      musicInfo: item,
    );
  }

  MusicFreeSheet? _toSheet(MusicFreePlugin plugin, Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final item = raw.map((key, value) => MapEntry(key.toString(), value));
    final id = item['id']?.toString() ?? '';
    if (id.isEmpty) {
      return null;
    }
    item['platform'] = plugin.platform;
    return MusicFreeSheet(
      platform: plugin.platform,
      id: id,
      title: (item['title'] ?? item['name'] ?? '').toString(),
      coverUrl: (item['coverImg'] ?? item['artwork'])?.toString(),
      creator: (item['artist'] ?? item['creator'])?.toString(),
      description: item['description']?.toString(),
      raw: item,
    );
  }

  MusicFreeTag? _toTag(MusicFreePlugin plugin, Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final item = raw.map((key, value) => MapEntry(key.toString(), value));
    final id = item['id']?.toString() ?? '';
    if (id.isEmpty) {
      return null;
    }
    return MusicFreeTag(
      platform: plugin.platform,
      id: id,
      title: (item['title'] ?? item['name'] ?? '').toString(),
      raw: item,
    );
  }

  static String? _qualityUrlFromItem(Map<String, dynamic> item, String quality) {
    final qualities = item['qualities'];
    if (qualities is Map) {
      final entry = qualities[quality];
      if (entry is Map) {
        final url = entry['url']?.toString();
        if (url != null && url.isNotEmpty) {
          return url;
        }
      }
    }
    final url = item['url']?.toString();
    return url == null || url.isEmpty ? null : url;
  }

  static String _message(Object error) =>
      error is MusicFreeException ? error.message : '$error';
}

/// 进程内的短期缓存（榜单 / 歌单标签这种「一进页面就要」的数据）。
///
/// 只活在这次运行里：插件换了会 [MusicFreeService.clearCache] 清掉。
class _MemoryCache {
  final Map<String, ({Object value, DateTime expiresAt})> _entries =
      <String, ({Object value, DateTime expiresAt})>{};

  Object? read(String key) {
    final entry = _entries[key];
    if (entry == null) {
      return null;
    }
    if (entry.expiresAt.isBefore(DateTime.now())) {
      _entries.remove(key);
      return null;
    }
    return entry.value;
  }

  void write(String key, Object value, Duration ttl) {
    _entries[key] = (value: value, expiresAt: DateTime.now().add(ttl));
  }

  void clear() => _entries.clear();
}