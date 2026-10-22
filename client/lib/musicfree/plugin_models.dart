/// MusicFree 插件相关的数据模型。
///
/// 字段命名刻意与 MusicFree 的 `IPluginDefine` / `IPluginDelegate` 对齐，
/// 便于照着源码排错。
library;

/// 插件里声明的用户自定义变量（MusicFree 的 `IUserVariable`）。
class PluginUserVariable {
  const PluginUserVariable({required this.key, this.name = '', this.hint = ''});

  final String key;
  final String name;
  final String hint;

  static PluginUserVariable? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final key = raw['key']?.toString() ?? '';
    if (key.isEmpty) {
      return null;
    }
    return PluginUserVariable(
      key: key,
      name: raw['name']?.toString() ?? '',
      hint: raw['hint']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'key': key,
    if (name.isNotEmpty) 'name': name,
    if (hint.isNotEmpty) 'hint': hint,
  };
}

/// 一个已安装并成功加载的 MusicFree 插件。
class MusicFreePlugin {
  const MusicFreePlugin({
    required this.hash,
    required this.platform,
    required this.path,
    this.version = '',
    this.author = '',
    this.description = '',
    this.homepage = '',
    this.srcUrl = '',
    this.appVersion = '',
    this.supportedMethods = const <String>[],
    this.userVariables = const <PluginUserVariable>[],
    this.hints = const <String, dynamic>{},
    this.primaryKey = const <String>[],
    this.defaultSearchType = 'music',
    this.supportedSearchType = const <String>[],
    this.cacheControl = 'cache',
    this.order = 0,
    this.enabled = true,
    this.loadError,
  });

  /// sha256(插件源码)，MusicFree 用它做唯一 id。
  final String hash;

  /// 插件名（MusicFree 里 platform 就是插件名）。
  final String platform;
  final String path;
  final String version;
  final String author;
  final String description;
  final String homepage;

  /// 安装来源；「更新全部」按它重装。
  final String srcUrl;
  final String appVersion;

  /// 插件实现了哪些方法（等价 MusicFree 的 supportedMethod）。
  final List<String> supportedMethods;
  final List<PluginUserVariable> userVariables;
  final Map<String, dynamic> hints;
  final List<String> primaryKey;
  final String defaultSearchType;
  final List<String> supportedSearchType;
  final String cacheControl;

  /// 本地偏好：排序权重、是否启用。
  final int order;
  final bool enabled;

  /// 加载/解析失败时的原因（插件仍在列表里，但不可用）。
  final String? loadError;

  bool supports(String method) => supportedMethods.contains(method);

  bool get isUsable => loadError == null && supportedMethods.isNotEmpty;

  /// 展示用：作者或来源。
  String get subtitle {
    if (author.isNotEmpty && version.isNotEmpty) {
      return '$author · v$version';
    }
    if (author.isNotEmpty) {
      return author;
    }
    if (version.isNotEmpty) {
      return 'v$version';
    }
    return hash.isEmpty ? '未知插件' : hash.substring(0, 8);
  }

  MusicFreePlugin copyWith({
    int? order,
    bool? enabled,
    String? loadError,
    String? srcUrl,
  }) {
    return MusicFreePlugin(
      hash: hash,
      platform: platform,
      path: path,
      version: version,
      author: author,
      description: description,
      homepage: homepage,
      srcUrl: srcUrl ?? this.srcUrl,
      appVersion: appVersion,
      supportedMethods: supportedMethods,
      userVariables: userVariables,
      hints: hints,
      primaryKey: primaryKey,
      defaultSearchType: defaultSearchType,
      supportedSearchType: supportedSearchType,
      cacheControl: cacheControl,
      order: order ?? this.order,
      enabled: enabled ?? this.enabled,
      loadError: loadError ?? this.loadError,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'hash': hash,
    'platform': platform,
    'path': path,
    'version': version,
    'author': author,
    'description': description,
    'homepage': homepage,
    'srcUrl': srcUrl,
    'appVersion': appVersion,
    'supportedMethods': supportedMethods,
    'userVariables': userVariables.map((item) => item.toJson()).toList(growable: false),
    'hints': hints,
    'primaryKey': primaryKey,
    'defaultSearchType': defaultSearchType,
    'supportedSearchType': supportedSearchType,
    'cacheControl': cacheControl,
    'order': order,
    'enabled': enabled,
    if (loadError != null) 'loadError': loadError,
  };

  /// worker isolate 回传的元数据还原（字段与 [toJson] 一一对应）。
  ///
  /// `hash` / `path` / `srcUrl` 以调用方为准：worker 里的插件本来就是按主 isolate
  /// 给的 hash 装的，用回传值只会多一次「两边不一致就出鬼」的机会。
  factory MusicFreePlugin.fromJson(
    Map<String, dynamic> json, {
    required String hash,
    required String path,
    required String srcUrl,
  }) => MusicFreePlugin(
    hash: hash,
    platform: json['platform']?.toString() ?? '',
    path: path,
    version: json['version']?.toString() ?? '',
    author: json['author']?.toString() ?? '',
    description: json['description']?.toString() ?? '',
    homepage: json['homepage']?.toString() ?? '',
    srcUrl: srcUrl,
    appVersion: json['appVersion']?.toString() ?? '',
    supportedMethods: (json['supportedMethods'] as List? ?? const <dynamic>[])
        .map((item) => item.toString())
        .toList(growable: false),
    userVariables: (json['userVariables'] as List? ?? const <dynamic>[])
        .map(PluginUserVariable.tryParse)
        .whereType<PluginUserVariable>()
        .toList(growable: false),
    hints:
        (json['hints'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{},
    primaryKey: (json['primaryKey'] as List? ?? const <dynamic>[])
        .map((item) => item.toString())
        .toList(growable: false),
    defaultSearchType: json['defaultSearchType']?.toString() ?? 'music',
    supportedSearchType:
        (json['supportedSearchType'] as List? ?? const <dynamic>[])
            .map((item) => item.toString())
            .toList(growable: false),
    cacheControl: json['cacheControl']?.toString() ?? 'cache',
    loadError: json['loadError']?.toString(),
  );
}

/// 插件能力声明（App 里各处的「有没有这个能力」判断都走它）。
class MusicFreeCapabilities {
  const MusicFreeCapabilities._();

  static const String search = 'search';
  static const String getMediaSource = 'getMediaSource';
  static const String getMusicInfo = 'getMusicInfo';
  static const String getLyric = 'getLyric';
  static const String getAlbumInfo = 'getAlbumInfo';
  static const String getMusicSheetInfo = 'getMusicSheetInfo';
  static const String getArtistWorks = 'getArtistWorks';
  static const String getTopLists = 'getTopLists';
  static const String getTopListDetail = 'getTopListDetail';
  static const String getRecommendSheetTags = 'getRecommendSheetTags';
  static const String getRecommendSheetsByTag = 'getRecommendSheetsByTag';
  static const String getMusicComments = 'getMusicComments';
  static const String importMusicSheet = 'importMusicSheet';
  static const String importMusicItem = 'importMusicItem';
}

/// 订阅清单里的一条（`.json` 订阅的 `plugins` 数组项）。
///
/// 只带「挑选」需要的信息：名字、版本、插件源码地址。**插件源码要等用户确认之后
/// 才下载**——订阅里动辄几十个插件、几十 MB，先全下下来再让用户挑纯属浪费。
class MusicFreeSubscriptionEntry {
  const MusicFreeSubscriptionEntry({
    required this.url,
    this.name = '',
    this.version = '',
  });

  final String url;
  final String name;
  final String version;

  /// 列表里显示的名字：清单没给 `name` 就退回文件名
  /// （`xxx-source.plugin.v1.9.24.js` 这种，总比一串 URL 好认）。
  String get label {
    if (name.isNotEmpty) {
      return name;
    }
    final path = Uri.tryParse(url)?.path ?? url;
    final parts = path.split('/').where((part) => part.isNotEmpty).toList(growable: false);
    final file = parts.isEmpty ? '' : parts.last;
    return file.isEmpty ? url : file;
  }

  String get detail => version.isEmpty ? '' : 'v$version';

  /// 兼容两种清单写法：`{"url": "...", "name": "..."}` 与裸字符串 URL。
  static MusicFreeSubscriptionEntry? tryParse(Object? raw) {
    if (raw is String) {
      final url = raw.trim();
      return url.isEmpty ? null : MusicFreeSubscriptionEntry(url: url);
    }
    if (raw is! Map) {
      return null;
    }
    final url = raw['url']?.toString().trim() ?? '';
    if (url.isEmpty) {
      return null;
    }
    return MusicFreeSubscriptionEntry(
      url: url,
      name: raw['name']?.toString().trim() ?? '',
      version: raw['version']?.toString().trim() ?? '',
    );
  }
}