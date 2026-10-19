/// 点歌台的领域模型（与服务端 `app/services/music/models.py` 一一对应）。
///
/// 与服务端保持一致的两条硬约定：
/// * [MusicTrack.musicInfo] **原样保存平台原生对象**——客户端解析播放地址时
///   （洛雪音源脚本宿主）要把它整块交给脚本，任何裁剪都会让解析失败；
/// * 模型里**没有播放地址**：直链只存在于客户端解析之后的内存里，服务器不知道它。
library;

/// 平台展示名：服务端 `/music/platforms` 会下发权威名字，这里是兜底与短标签。
const Map<String, String> kMusicPlatformLabels = <String, String>{
  'wy': '网易云',
  'tx': 'QQ音乐',
  'kw': '酷我',
  'kg': '酷狗',
  'mg': '咪咕',
};

/// 平台短标签（歌曲行上的来源徽章）。
String musicPlatformLabel(String platform) =>
    kMusicPlatformLabels[platform] ?? platform;

/// 能力位（与服务端 `Capability` 一致）。
abstract final class MusicCapability {
  static const String search = 'search';
  static const String playlistSearch = 'playlistSearch';
  static const String charts = 'charts';
  static const String playlists = 'playlists';
}

class MusicArtist {
  const MusicArtist({this.id, required this.name});

  factory MusicArtist.fromJson(Map<String, dynamic> json) => MusicArtist(
    id: json['id'] as String?,
    name: json['name'] as String? ?? '',
  );

  final String? id;
  final String name;
}

class MusicAlbum {
  const MusicAlbum({this.id, this.name, this.coverUrl});

  factory MusicAlbum.fromJson(Map<String, dynamic> json) => MusicAlbum(
    id: json['id'] as String?,
    name: json['name'] as String?,
    coverUrl: json['coverUrl'] as String?,
  );

  final String? id;
  final String? name;
  final String? coverUrl;
}

/// 统一歌曲模型（搜索 / 榜单 / 歌单 / 队列共用）。
class MusicTrack {
  const MusicTrack({
    required this.platform,
    required this.id,
    required this.name,
    this.artists = const <MusicArtist>[],
    this.album,
    this.durationMs,
    this.coverUrl,
    this.musicInfo = const <String, dynamic>{},
  });

  factory MusicTrack.fromJson(Map<String, dynamic> json) => MusicTrack(
    platform: json['platform'] as String? ?? '',
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    artists: (json['artists'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(MusicArtist.fromJson)
        .toList(growable: false),
    album: json['album'] is Map<String, dynamic>
        ? MusicAlbum.fromJson(json['album'] as Map<String, dynamic>)
        : null,
    durationMs: (json['durationMs'] as num?)?.toInt(),
    coverUrl: json['coverUrl'] as String?,
    musicInfo:
        json['musicInfo'] as Map<String, dynamic>? ?? const <String, dynamic>{},
  );

  final String platform;
  final String id;
  final String name;
  final List<MusicArtist> artists;
  final MusicAlbum? album;
  final int? durationMs;
  final String? coverUrl;

  /// 平台原生对象（跨层契约字段，见库文档）。
  final Map<String, dynamic> musicInfo;

  /// 队列/列表里判断「是不是同一首歌」用的键。
  String get key => '$platform:$id';

  /// 歌手展示串（没有歌手信息时退回专辑名）。
  String get artistLabel {
    if (artists.isEmpty) {
      return album?.name ?? '';
    }
    return artists.map((artist) => artist.name).join(' / ');
  }

  Duration? get duration =>
      durationMs == null ? null : Duration(milliseconds: durationMs!);

  /// 落本地存储用（「最近点过」）。字段与服务端模型保持一致，便于回读。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'platform': platform,
    'id': id,
    'name': name,
    'artists': artists
        .map((artist) => <String, dynamic>{'id': artist.id, 'name': artist.name})
        .toList(growable: false),
    if (album != null)
      'album': <String, dynamic>{
        'id': album!.id,
        'name': album!.name,
        'coverUrl': album!.coverUrl,
      },
    'durationMs': durationMs,
    'coverUrl': coverUrl,
    'musicInfo': musicInfo,
  };
}

class MusicPlaylist {
  const MusicPlaylist({
    required this.platform,
    required this.id,
    required this.name,
    this.coverUrl,
    this.trackCount,
    this.creator,
    this.description,
    this.playCount,
  });

  factory MusicPlaylist.fromJson(Map<String, dynamic> json) => MusicPlaylist(
    platform: json['platform'] as String? ?? '',
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    coverUrl: json['coverUrl'] as String?,
    trackCount: (json['trackCount'] as num?)?.toInt(),
    creator: json['creator'] as String?,
    description: json['description'] as String?,
    playCount: (json['playCount'] as num?)?.toInt(),
  );

  final String platform;
  final String id;
  final String name;
  final String? coverUrl;
  final int? trackCount;
  final String? creator;
  final String? description;
  final int? playCount;

  String get key => '$platform:$id';
}

class MusicChart {
  const MusicChart({
    required this.platform,
    required this.id,
    required this.name,
    this.coverUrl,
    this.updateFrequency,
    this.description,
    this.trackCount,
  });

  factory MusicChart.fromJson(Map<String, dynamic> json) => MusicChart(
    platform: json['platform'] as String? ?? '',
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    coverUrl: json['coverUrl'] as String?,
    updateFrequency: json['updateFrequency'] as String?,
    description: json['description'] as String?,
    trackCount: (json['trackCount'] as num?)?.toInt(),
  );

  final String platform;
  final String id;
  final String name;
  final String? coverUrl;
  final String? updateFrequency;
  final String? description;
  final int? trackCount;

  String get key => '$platform:$id';
}

/// 榜单条目：名次由服务端算好。
class RankedTrack {
  const RankedTrack({required this.rank, required this.track});

  factory RankedTrack.fromJson(Map<String, dynamic> json) => RankedTrack(
    rank: (json['rank'] as num?)?.toInt() ?? 0,
    track: MusicTrack.fromJson(
      json['track'] as Map<String, dynamic>? ?? const <String, dynamic>{},
    ),
  );

  final int rank;
  final MusicTrack track;
}

/// 点歌台首页的专题卡。
class MusicTopic {
  const MusicTopic({
    required this.id,
    required this.name,
    this.description,
    this.coverUrl,
    this.platform,
    this.kind = 'search',
    this.target = '',
  });

  factory MusicTopic.fromJson(Map<String, dynamic> json) => MusicTopic(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    description: json['description'] as String?,
    coverUrl: json['coverUrl'] as String?,
    platform: json['platform'] as String?,
    kind: json['kind'] as String? ?? 'search',
    target: json['target'] as String? ?? '',
  );

  final String id;
  final String name;
  final String? description;
  final String? coverUrl;
  final String? platform;
  final String kind;
  final String target;
}

class MusicPlatformInfo {
  const MusicPlatformInfo({
    required this.platform,
    required this.name,
    this.capabilities = const <String>[],
  });

  factory MusicPlatformInfo.fromJson(Map<String, dynamic> json) =>
      MusicPlatformInfo(
        platform: json['platform'] as String? ?? '',
        name: json['name'] as String? ?? '',
        capabilities: (json['capabilities'] as List<dynamic>? ?? const <dynamic>[])
            .cast<String>(),
      );

  final String platform;
  final String name;
  final List<String> capabilities;

  bool supports(String capability) => capabilities.contains(capability);
}

/// 单个平台失败时的降级说明（聚合搜索不会因为一个平台挂掉整体失败）。
class MusicError {
  const MusicError({required this.platform, required this.message});

  factory MusicError.fromJson(Map<String, dynamic> json) => MusicError(
    platform: json['platform'] as String? ?? '',
    message: json['message'] as String? ?? '',
  );

  final String platform;
  final String message;
}

class MusicSearchResult {
  const MusicSearchResult({
    this.items = const <MusicTrack>[],
    this.total = 0,
    this.hasMore = false,
    this.errors = const <MusicError>[],
  });

  factory MusicSearchResult.fromJson(Map<String, dynamic> json) =>
      MusicSearchResult(
        items: _tracks(json['items']),
        total: (json['total'] as num?)?.toInt() ?? 0,
        hasMore: json['hasMore'] as bool? ?? false,
        errors: _errors(json['errors']),
      );

  final List<MusicTrack> items;
  final int total;
  final bool hasMore;
  final List<MusicError> errors;
}

class MusicPlaylistSearchResult {
  const MusicPlaylistSearchResult({
    this.items = const <MusicPlaylist>[],
    this.total = 0,
    this.hasMore = false,
    this.errors = const <MusicError>[],
  });

  factory MusicPlaylistSearchResult.fromJson(Map<String, dynamic> json) =>
      MusicPlaylistSearchResult(
        items: (json['items'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(MusicPlaylist.fromJson)
            .toList(growable: false),
        total: (json['total'] as num?)?.toInt() ?? 0,
        hasMore: json['hasMore'] as bool? ?? false,
        errors: _errors(json['errors']),
      );

  final List<MusicPlaylist> items;
  final int total;
  final bool hasMore;
  final List<MusicError> errors;
}

class MusicTrackPage {
  const MusicTrackPage({
    this.items = const <MusicTrack>[],
    this.total = 0,
    this.hasMore = false,
  });

  factory MusicTrackPage.fromJson(Map<String, dynamic> json) => MusicTrackPage(
    items: _tracks(json['items']),
    total: (json['total'] as num?)?.toInt() ?? 0,
    hasMore: json['hasMore'] as bool? ?? false,
  );

  final List<MusicTrack> items;
  final int total;
  final bool hasMore;
}

class MusicChartList {
  const MusicChartList({
    this.items = const <MusicChart>[],
    this.total = 0,
    this.errors = const <MusicError>[],
  });

  factory MusicChartList.fromJson(Map<String, dynamic> json) => MusicChartList(
    items: (json['items'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(MusicChart.fromJson)
        .toList(growable: false),
    total: (json['total'] as num?)?.toInt() ?? 0,
    errors: _errors(json['errors']),
  );

  final List<MusicChart> items;
  final int total;
  final List<MusicError> errors;
}

class MusicChartTrackPage {
  const MusicChartTrackPage({
    required this.chart,
    this.items = const <RankedTrack>[],
    this.total = 0,
    this.hasMore = false,
  });

  factory MusicChartTrackPage.fromJson(Map<String, dynamic> json) =>
      MusicChartTrackPage(
        chart: MusicChart.fromJson(
          json['chart'] as Map<String, dynamic>? ?? const <String, dynamic>{},
        ),
        items: (json['items'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(RankedTrack.fromJson)
            .toList(growable: false),
        total: (json['total'] as num?)?.toInt() ?? 0,
        hasMore: json['hasMore'] as bool? ?? false,
      );

  final MusicChart chart;
  final List<RankedTrack> items;
  final int total;
  final bool hasMore;
}

class MusicPlaylistPage {
  const MusicPlaylistPage({
    this.items = const <MusicPlaylist>[],
    this.total = 0,
    this.hasMore = false,
  });

  factory MusicPlaylistPage.fromJson(Map<String, dynamic> json) =>
      MusicPlaylistPage(
        items: (json['items'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(MusicPlaylist.fromJson)
            .toList(growable: false),
        total: (json['total'] as num?)?.toInt() ?? 0,
        hasMore: json['hasMore'] as bool? ?? false,
      );

  final List<MusicPlaylist> items;
  final int total;
  final bool hasMore;
}

class MusicPlaylistDetail {
  const MusicPlaylistDetail({
    required this.playlist,
    this.items = const <MusicTrack>[],
    this.total = 0,
    this.hasMore = false,
  });

  factory MusicPlaylistDetail.fromJson(Map<String, dynamic> json) =>
      MusicPlaylistDetail(
        playlist: MusicPlaylist.fromJson(
          json['playlist'] as Map<String, dynamic>? ?? const <String, dynamic>{},
        ),
        items: _tracks(json['items']),
        total: (json['total'] as num?)?.toInt() ?? 0,
        hasMore: json['hasMore'] as bool? ?? false,
      );

  final MusicPlaylist playlist;
  final List<MusicTrack> items;
  final int total;
  final bool hasMore;
}

class MusicHomeChartSection {
  const MusicHomeChartSection({
    required this.chart,
    this.items = const <RankedTrack>[],
  });

  factory MusicHomeChartSection.fromJson(Map<String, dynamic> json) =>
      MusicHomeChartSection(
        chart: MusicChart.fromJson(
          json['chart'] as Map<String, dynamic>? ?? const <String, dynamic>{},
        ),
        items: (json['items'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(RankedTrack.fromJson)
            .toList(growable: false),
      );

  final MusicChart chart;
  final List<RankedTrack> items;
}

class MusicHomeResult {
  const MusicHomeResult({
    this.platform = '',
    this.topics = const <MusicTopic>[],
    this.charts = const <MusicHomeChartSection>[],
    this.errors = const <MusicError>[],
  });

  factory MusicHomeResult.fromJson(Map<String, dynamic> json) => MusicHomeResult(
    platform: json['platform'] as String? ?? '',
    topics: (json['topics'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(MusicTopic.fromJson)
        .toList(growable: false),
    charts: (json['charts'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(MusicHomeChartSection.fromJson)
        .toList(growable: false),
    errors: _errors(json['errors']),
  );

  final String platform;
  final List<MusicTopic> topics;
  final List<MusicHomeChartSection> charts;
  final List<MusicError> errors;
}

List<MusicTrack> _tracks(Object? value) =>
    (value as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(MusicTrack.fromJson)
        .toList(growable: false);

List<MusicError> _errors(Object? value) =>
    (value as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(MusicError.fromJson)
        .toList(growable: false);
