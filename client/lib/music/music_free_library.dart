import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_log.dart';
import '../core/l10n_ext.dart';
import '../data/music_models.dart';
import '../musicfree/musicfree_host.dart';
import '../musicfree/musicfree_plugins.dart';
import '../musicfree/musicfree_service.dart';
import '../musicfree/plugin_models.dart';

/// 点歌台的内容视图（与 MusicFree 的搜索 / 排行榜 / 热门歌单一一对应）。
///
/// 注意：`search` 不是左导航入口——搜索由点歌台顶部的搜索框触发，
/// 用户清空搜索后会回到进来之前那一屏（榜单或歌单）。
///
/// `favorites` 与 `plugins` 是例外：前者不来自插件（本机收藏 `MusicFavorites`），
/// 后者管的是插件本身（`MusicPluginCard`，与设置页那张卡片是同一个组件），
/// 所以插件全挂了这两屏照样能用——而榜单 / 歌单在没有插件时直接提示去装。
enum MusicFreeSection { search, charts, sheets, favorites, plugins }

/// 内容区正在看的详情（榜单 / 歌单共用一套）。
class MusicFreeDetail {
  const MusicFreeDetail({
    required this.sheet,
    required this.tracks,
    required this.isEnd,
    required this.isChart,
    this.error,
  });

  final MusicFreeSheet sheet;
  final List<MusicTrack> tracks;
  final bool isEnd;
  final bool isChart;
  final String? error;

  /// 详情页头部那颗胶囊（榜单 / 歌单）：数据层拿不到 BuildContext，
  /// 走 `appL10n` 那份全局文案。
  String get kindLabel =>
      isChart ? appL10n.musicNavCharts : appL10n.musicSearchTypePlaylist;
}

/// 点歌台 + 插件管理共用的数据门面。
///
/// 只做「状态 + 调用 MusicFreeService」这一件事，UI 不要直接碰宿主/插件。
class MusicFreeLibrary extends ChangeNotifier {
  MusicFreeLibrary({
    required MusicFreePlugins plugins,
    MusicFreeService? service,
  }) : _plugins = plugins,
       _service = service ?? MusicFreeService(plugins) {
    // 后台预编译、按需编译、worker 掉线都会改插件集合：把通知接到库的变更上，
    // 界面才会重建（否则卡片一直停在旧状态，看着像卡死）。
    _plugins.onPluginsChanged = notifyListeners;
  }

  final MusicFreePlugins _plugins;
  final MusicFreeService _service;

  MusicFreeService get service => _service;

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  // ------------------------------------------------------------------ 插件
  List<MusicFreePlugin> get plugins => _plugins.plugins;

  List<MusicFreePlugin> get enabledPlugins => _plugins.enabledPlugins;

  bool get hasPlugins => plugins.isNotEmpty;

  /// 声明了某个能力的音源（按插件顺序去重）。
  ///
  /// 榜单 / 歌单的 tab 用它来**摆全**：某个音源这次超时没回来，它的 tab 也要在，
  /// 点进去说明原因并给重试。从前 tab 是从「拿到数据的分组」里生成的，于是
  /// 「装了 6 个插件、排行榜只有 1 个音源」——正是用户看到的样子。
  List<String> _platformsWith(String method) {
    final seen = <String>{};
    final result = <String>[];
    for (final plugin in _service.withMethod(method)) {
      if (seen.add(plugin.platform)) {
        result.add(plugin.platform);
      }
    }
    return result;
  }

  /// 能提供排行榜的音源（插件顺序）。
  List<String> get chartPlatforms =>
      _platformsWith(MusicFreeCapabilities.getTopLists);

  /// 能提供热门歌单标签的音源（插件顺序）。
  List<String> get sheetPlatforms =>
      _platformsWith(MusicFreeCapabilities.getRecommendSheetTags);

  /// 上一次拉榜单失败/超时的音源（platform → 原因）。
  Map<String, String> get chartFailures => _service.lastTopListFailures;

  /// 上一次拉歌单标签失败/超时的音源（platform → 原因）。
  Map<String, String> get tagFailures => _service.lastTagFailures;

  /// 把「之前装过的插件」从磁盘登记出来（只读元数据、不编译 JS），然后交给后台预编译。
  ///
  /// 启动时调一次：设置页 / 点歌台一打开就能看到已有的插件列表，而不是空着等用户
  /// 点一次「刷新订阅」。**紧接着**就把这些插件放后台编进 worker（[warmPlugins]）：
  /// 元数据只让插件「列出来」，函数本体还不在 worker 里——等到用户点开点歌台才现场
  /// 编译的话，他看到的还是「已经装了插件却在转」。
  Future<void> restorePlugins() async {
    try {
      await _plugins.restoreInstalled();
    } on Object catch (error) {
      AppLog.warn('恢复本地插件列表失败', error: error);
    }
    notifyListeners();
    warmPlugins();
  }

  /// 后台把已装插件编进 worker：静默、不挡界面、不产生任何「加载中」。
  ///
  /// 没有插件时什么也不做（不装载、不下载——装音源仍然只由用户点「刷新订阅」触发）。
  void warmPlugins() {
    if (!hasPlugins) {
      return;
    }
    _plugins.warmPluginsInBackground();
  }

  bool get canSearch => _service.hasSearchPlugin;

  bool _syncing = false;
  String? _syncError;
  String? _syncMessage;

  bool get syncing => _syncing;
  String? get syncError => _syncError;
  String? get syncMessage => _syncMessage;

  // 这里曾经有一个 `requestSync` + `_ensurePlugins()`：没有插件时，打开点歌台
  // 或点一个搜索都会顺手触发一次订阅同步（起 QuickJS、把插件源码装进去）。
  // 现在**一律不自动装载**：装音源只由用户在本机点「插件 → 刷新订阅」触发，
  // 界面缺音源时给指路文案（`pluginNoneInstalled`）。理由是他亲眼看到「还在转」
  // 的那个加载其实是我们替他发起的——一次装载少则几秒、多则二十几秒，
  // 用户既没要求、也不知道在等什么。

  /// 刷新订阅时让用户挑要安装哪些插件（由设置页注入：那里有 BuildContext，
  /// 能弹框）。为 null 时按「上次的选择 / 默认前 6 个」走，不弹框。
  SubscriptionEntryPicker? pickSubscriptionEntries;

  /// 进房后的轻量预热：只读音质偏好（纯本地 SharedPreferences）。
  ///
  /// **不碰插件、不拉榜单**：插件装载要把 577KB 运行时 bundle 与每份插件源码
  /// 装进 QuickJS（首次运行还要编译，字节码缓存之后每份只剩几十毫秒），榜单则要
  /// 对 N 个音源并发打插件方法。进房时付这两笔会直接表现为「一进房就卡」——改成
  /// 用户真的点开点歌台时再做，那时界面上有骨架屏，卡一下也能解释得清。
  void warmUp() {
    unawaited(loadPreferences());
  }

  /// 从服务器取订阅 URL 并同步插件（首次启动 / 连上服务器时调用）。
  ///
  /// [urls] / [hash] 来自服务器的 `/music/plugin-subscription`。
  Future<void> syncSubscription({
    required List<String> urls,
    String? hash,
    bool force = false,
  }) async {
    // 重复触发直接忽略：按钮连点、进房预热与手动刷新撞在一起时，
    // 再来一轮只会让 worker 的队列更长、更难收场。
    if (_syncing) {
      return;
    }
    _syncing = true;
    _syncError = null;
    _syncMessage = null;
    notifyListeners();
    final before = _pluginFingerprint();
    try {
      final result = await _plugins.syncSubscription(
        urls: urls,
        signature: hash,
        force: force,
        // 只有「用户点刷新订阅」才弹框挑插件；启动/进房的后台同步沿用上次的选择。
        pickEntries: force ? pickSubscriptionEntries : null,
        // 每装上一个就刷一次界面：插件多的时候用户能看到「已装载 3 个」，
        // 而不是盯着一个不动的转圈等整轮结束（以前是全部装完才通知）。
        onProgress: (message) {
          _syncMessage = message;
          notifyListeners();
        },
      );
      if (result.hasFailures) {
        _syncError = result.failures.join('；');
      }
      _syncMessage = result.reinstalled
          ? appL10n.musicSyncInstalled(plugins.length)
          : result.cancelled
          ? appL10n.musicSyncCancelled
          : appL10n.musicSyncUpToDate(plugins.length);
      // 插件集合真的换了才清空已加载内容；换完立刻把原来在看的那些内容重拉一遍，
      // 免得界面突然停在「插件没有提供排行榜」这种空态上（点第一首歌就会触发一次同步）。
      if (_pluginFingerprint() != before) {
        _resetContent();
        _reloadContent();
      }
    } on Object catch (error) {
      _syncError = _message(error);
      AppLog.warn('同步插件订阅失败', error: error);
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> updateAllPlugins() async {
    // 同 syncSubscription：装载期间的重复点击不再开第二轮
    if (_syncing) {
      return;
    }
    _syncing = true;
    _syncError = null;
    notifyListeners();
    try {
      final failures = await _plugins.updateAll();
      _syncError = failures.isEmpty ? null : failures.join('；');
      _syncMessage = failures.isEmpty
          ? appL10n.musicSyncAllUpdated
          : appL10n.musicSyncPartialFailed;
      _resetContent();
      _reloadContent();
    } on Object catch (error) {
      _syncError = _message(error);
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> setPluginEnabled(String hash, bool enabled) async {
    await _plugins.setEnabled(hash, enabled);
    _resetContent();
    _reloadContent();
    notifyListeners();
  }

  Future<void> movePlugin(String hash, int delta) async {
    await _plugins.move(hash, delta);
    notifyListeners();
  }

  Future<void> uninstallPlugin(String hash) async {
    await _plugins.uninstall(hash);
    _resetContent();
    _reloadContent();
    notifyListeners();
  }

  Future<void> savePluginVariables(String hash, Map<String, String> values) async {
    await _plugins.saveUserVariables(hash, values);
    _resetContent();
    notifyListeners();
  }

  Map<String, String> userVariablesOf(String platform) => _plugins.userVariablesOf(platform);

  // ------------------------------------------------------------------ 音质
  static const String _qualityKey = 'musicfree.quality';

  MusicFreeQuality _quality = MusicFreeQuality.standard;

  MusicFreeQuality get quality => _quality;

  String get qualityKey => _quality.key;

  Future<void> loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_qualityKey);
      if (raw != null) {
        _quality = MusicFreeQualityKey.fromKey(raw);
        _service.quality = _quality;
      }
    } on Object catch (error) {
      AppLog.warn('读取音质偏好失败', error: error);
    }
    notifyListeners();
  }

  Future<void> setQuality(MusicFreeQuality next) async {
    if (_quality == next) {
      return;
    }
    _quality = next;
    _service.quality = next;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_qualityKey, next.key);
    } on Object catch (error) {
      AppLog.warn('保存音质偏好失败', error: error);
    }
  }

  // ------------------------------------------------------------------ 搜索
  String _query = '';
  List<MusicTrack> _tracks = const <MusicTrack>[];
  List<String> _warnings = const <String>[];
  List<String> _skipped = const <String>[];
  bool _searching = false;
  String? _searchError;
  int _searchDone = 0;
  int _searchTotal = 0;
  /// 每次 search 自增：并发跑两轮（切 tab 重搜）时只认最新那轮的结果。
  int _searchToken = 0;

  /// 第一层 tab：搜索类型（音乐 / 专辑 / 作者 / 歌单，由插件声明的能力决定）。
  String _searchType = 'music';

  /// 第二层 tab：音源（null = 全部音源）。
  String? _searchPlatform;

  String get query => _query;
  List<MusicTrack> get tracks => _tracks;

  /// 本轮没返回结果的音源（原因已经截短，直接给人看）。
  List<String> get searchWarnings => _warnings;

  /// 本轮被临时跳过的音源（连续失败熔断中）。
  List<String> get searchSkipped => _skipped;

  bool get searching => _searching;
  String? get searchError => _searchError;
  bool get hasSearch => _query.isNotEmpty;
  String get searchType => _searchType;
  String? get searchPlatform => _searchPlatform;

  /// 已返回 / 参与的音源数（界面用它显示「还剩几个音源」）。
  int get searchDone => _searchDone;
  int get searchTotal => _searchTotal;

  /// 可选的搜索类型（插件能力的并集）。
  List<String> get searchTypes => _service.searchTypes;

  /// 当前类型下可选的音源。
  List<String> get searchPlatforms => _service.platformsForType(_searchType);

  /// 切换搜索类型：清掉旧结果，用同一个关键词重搜。
  Future<void> selectSearchType(String type) async {
    if (_searchType == type) {
      return;
    }
    _searchType = type;
    // 新类型下没有当前音源 → 回到「全部」，别让列表空着
    if (_searchPlatform != null && !searchPlatforms.contains(_searchPlatform)) {
      _searchPlatform = null;
    }
    _tracks = const <MusicTrack>[];
    _warnings = const <String>[];
    notifyListeners();
    if (_query.isNotEmpty) {
      await search(_query);
    }
  }

  /// 切换音源（null = 全部），同样用当前关键词重搜。
  Future<void> selectSearchPlatform(String? platform) async {
    if (_searchPlatform == platform) {
      return;
    }
    _searchPlatform = platform;
    _tracks = const <MusicTrack>[];
    _warnings = const <String>[];
    notifyListeners();
    if (_query.isNotEmpty) {
      await search(_query);
    }
  }

  /// 聚合搜索。
  ///
  /// 边搜边显示：每有一个音源返回（或到 2 秒上限判失败）就把当前结果刷到界面，
  /// 不再等最后一个音源——这是 MusicFree 看起来「秒出」的关键。
  /// [refresh] 为 true 时跳过本地缓存（用户手动重试 / 换插件之后）。
  Future<void> search(String keyword, {bool refresh = false}) async {
    // 没有插件就不发请求、也不自动装插件：界面给的是「去左侧插件安装」的指路
    if (!hasPlugins) {
      clearSearch();
      return;
    }
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) {
      clearSearch();
      return;
    }
    // 同一个关键词重搜（切类型 / 切音源 / 刷新）会并发跑两轮：用自增 token 认领
    // 「这一次搜索」，只有最新那轮才有资格写状态，旧轮的迟到回调一律丢掉。
    final token = ++_searchToken;
    bool isCurrent() => token == _searchToken && _query == trimmed;

    // 关键词变了就清空上一轮的结果（别让新关键词下面挂着旧歌）；
    // 同一个关键词重搜先留着，等新结果覆盖。
    final sameQuery = _query == trimmed;
    _query = trimmed;
    _searching = true;
    _searchError = null;
    _warnings = const <String>[];
    _skipped = const <String>[];
    _searchDone = 0;
    _searchTotal = 0;
    if (refresh || !sameQuery) {
      _tracks = const <MusicTrack>[];
    }
    notifyListeners();
    try {
      final result = await _service.search(
        trimmed,
        type: _searchType,
        platform: _searchPlatform,
        refresh: refresh,
        onUpdate: (partial) {
          if (!isCurrent()) {
            return;
          }
          _tracks = partial.tracks;
          _warnings = partial.errors;
          _skipped = partial.skipped;
          _searchDone = partial.done;
          _searchTotal = partial.total;
          notifyListeners();
        },
      );
      if (isCurrent()) {
        _tracks = result.tracks;
        _warnings = result.errors;
        _skipped = result.skipped;
        _searchDone = result.total;
        _searchTotal = result.total;
      }
    } on Object catch (error) {
      if (isCurrent()) {
        _searchError = _message(error);
        _tracks = const <MusicTrack>[];
      }
    } finally {
      // 只有「最新那轮」结束才算搜索结束：旧轮先结束不能让按钮提前解禁。
      if (token == _searchToken) {
        _searching = false;
        notifyListeners();
      }
    }
  }

  void clearSearch() {
    if (_query.isEmpty && _tracks.isEmpty && _searchError == null) {
      return;
    }
    _query = '';
    _tracks = const <MusicTrack>[];
    _warnings = const <String>[];
    _skipped = const <String>[];
    _searchError = null;
    _searchDone = 0;
    _searchTotal = 0;
    notifyListeners();
  }

  // ---------------------------------------------------------------- 排行榜
  List<MusicFreeTopListGroup> _chartGroups = const <MusicFreeTopListGroup>[];
  bool _chartsLoading = false;
  String? _chartsError;

  List<MusicFreeTopListGroup> get chartGroups => _chartGroups;
  bool get chartsLoading => _chartsLoading;
  String? get chartsError => _chartsError;

  /// 拉排行榜。调用方是点歌台：**有插件时它进屏即调**，用户不用点任何按钮。
  ///
  /// `!hasPlugins` 时直接返回、不发请求、也不顺手同步订阅——以前这里会触发一次插件
  /// 装载，用户看到的就是「明明没让我加载，它却一直在转」。没插件时界面只给一句
  /// 装音源的提示（文案见 `pluginNoneInstalled`）。
  Future<void> loadCharts({bool force = false}) async {
    if (!hasPlugins) {
      if (_chartGroups.isNotEmpty || _chartsError != null) {
        _chartGroups = const <MusicFreeTopListGroup>[];
        _chartsError = null;
        notifyListeners();
      }
      return;
    }
    if (_chartsLoading) {
      return;
    }
    if (!force && _chartGroups.isNotEmpty) {
      return;
    }
    _chartsLoading = true;
    _chartsError = null;
    notifyListeners();
    try {
      _chartGroups = await _service.topLists(refresh: force);
      _chartsLoaded = true;
      if (_chartGroups.isEmpty) {
        // 分清「插件确实没有这个能力」和「有音源卡住了」：后者多半点一次重试就好
        // （服务层有 20 多秒的总闸，卡住的结果会被丢掉重拉）。
        _chartsError = !hasPlugins
            ? appL10n.pluginNoneInstalled
            : _service.lastListTimedOut
            ? appL10n.musicChartsTimeout
            : appL10n.pluginNoCharts;
      }
    } on Object catch (error) {
      _chartsError = _message(error);
    } finally {
      _chartsLoading = false;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------ 热门歌单
  MusicFreeTags _tags = const MusicFreeTags();
  List<MusicFreeSheet> _sheets = const <MusicFreeSheet>[];
  MusicFreeTag? _selectedTag;
  bool _tagsLoading = false;
  bool _sheetsLoading = false;
  String? _sheetsError;
  int _sheetPage = 1;

  MusicFreeTags get tags => _tags;
  List<MusicFreeSheet> get sheets => _sheets;
  MusicFreeTag? get selectedTag => _selectedTag;
  bool get tagsLoading => _tagsLoading;

  bool get sheetsLoading => _sheetsLoading;
  String? get sheetsError => _sheetsError;

  /// 拉热门歌单的第一层（标签）。与 [loadCharts] 一样：**没有插件就直接留空态**，
  /// 不在这里顺手同步订阅——那个动作现在只在用户点「插件」页里的「刷新订阅」时发生。
  Future<void> loadTagSections({bool force = false}) async {
    if (!hasPlugins) {
      if (!_tags.isEmpty || _selectedTag != null || _sheetsError != null) {
        _tags = const MusicFreeTags();
        _sheets = const <MusicFreeSheet>[];
        _selectedTag = null;
        _sheetsError = null;
        notifyListeners();
      }
      return;
    }
    if (_tagsLoading) {
      return;
    }
    if (!force && (!_tags.isEmpty || _selectedTag != null)) {
      return;
    }
    _tagsLoading = true;
    _sheetsError = null;
    notifyListeners();
    try {
      _tags = await _service.recommendTags(refresh: force);
      _tagsLoaded = true;
      final first = _tags.pinned.isNotEmpty
          ? _tags.pinned.first
          : (_tags.groups.isNotEmpty && _tags.groups.first.tags.isNotEmpty
                ? _tags.groups.first.tags.first
                : null);
      _tagsLoading = false;
      if (first != null) {
        await selectTag(first);
        return;
      }
      _sheetsError = hasPlugins
          ? appL10n.pluginNoSheets
          : appL10n.pluginNoneInstalled;
    } on Object catch (error) {
      _sheetsError = _message(error);
    } finally {
      _tagsLoading = false;
      notifyListeners();
    }
  }

  Future<void> selectTag(MusicFreeTag tag) async {
    _selectedTag = tag;
    _sheets = const <MusicFreeSheet>[];
    _sheetPage = 1;
    _sheetsLoading = true;
    _sheetsError = null;
    notifyListeners();
    try {
      _sheets = await _service.sheetsByTag(tag);
      if (_sheets.isEmpty) {
        _sheetsError = appL10n.musicSheetCategoryEmpty;
      }
    } on Object catch (error) {
      _sheetsError = _message(error);
    } finally {
      _sheetsLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadMoreSheets() async {
    final tag = _selectedTag;
    if (tag == null || _sheetsLoading) {
      return;
    }
    _sheetsLoading = true;
    notifyListeners();
    try {
      final next = _sheetPage + 1;
      final more = await _service.sheetsByTag(tag, page: next);
      if (more.isEmpty) {
        _sheetsError = appL10n.musicNoMoreSheets;
      } else {
        _sheetPage = next;
        _sheets = <MusicFreeSheet>[..._sheets, ...more];
      }
    } on Object catch (error) {
      _sheetsError = _message(error);
    } finally {
      _sheetsLoading = false;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------ 详情
  MusicFreeDetail? _detail;
  bool _detailLoading = false;
  String? _detailError;
  String _detailLoadingTitle = '';
  int _detailPage = 1;

  MusicFreeDetail? get detail => _detail;
  bool get detailLoading => _detailLoading;
  String? get detailError => _detailError;
  String get detailLoadingTitle => _detailLoadingTitle;

  Future<void> openTopList(MusicFreeSheet sheet) async {
    await _openDetail(sheet, isChart: true, loader: () => _service.topListDetail(sheet));
  }

  Future<void> openSheet(MusicFreeSheet sheet) async {
    await _openDetail(sheet, isChart: false, loader: () => _service.sheetInfo(sheet));
  }

  Future<void> _openDetail(
    MusicFreeSheet sheet, {
    required bool isChart,
    required Future<MusicFreeTrackPage> Function() loader,
  }) async {
    _detail = null;
    _detailError = null;
    _detailPage = 1;
    _detailLoadingTitle = sheet.title;
    _detailLoading = true;
    notifyListeners();
    try {
      final page = await loader();
      _detail = MusicFreeDetail(
        sheet: sheet,
        tracks: page.tracks,
        isEnd: page.isEnd,
        isChart: isChart,
        error: page.errors.isEmpty ? null : page.errors.first,
      );
    } on Object catch (error) {
      _detailError = _message(error);
    } finally {
      _detailLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadMoreDetail() async {
    final current = _detail;
    if (current == null || _detailLoading || current.isEnd) {
      return;
    }
    _detailLoading = true;
    notifyListeners();
    try {
      final next = _detailPage + 1;
      final page = current.isChart
          ? await _service.topListDetail(current.sheet, page: next)
          : await _service.sheetInfo(current.sheet, page: next);
      if (page.tracks.isEmpty) {
        _detail = MusicFreeDetail(
          sheet: current.sheet,
          tracks: current.tracks,
          isEnd: true,
          isChart: current.isChart,
          error: page.errors.isEmpty ? null : page.errors.first,
        );
      } else {
        _detailPage = next;
        _detail = MusicFreeDetail(
          sheet: current.sheet,
          tracks: <MusicTrack>[...current.tracks, ...page.tracks],
          isEnd: page.isEnd,
          isChart: current.isChart,
          error: page.errors.isEmpty ? null : page.errors.first,
        );
      }
    } on Object catch (error) {
      _detailError = _message(error);
    } finally {
      _detailLoading = false;
      notifyListeners();
    }
  }

  void closeDetail() {
    if (_detail == null && _detailError == null && !_detailLoading) {
      return;
    }
    _detail = null;
    _detailError = null;
    _detailLoading = false;
    _detailLoadingTitle = '';
    _detailPage = 1;
    notifyListeners();
  }

  /// 解析播放地址（播放器用）。
  Future<MusicFreeMediaSource> resolveMedia(MusicTrack track) => _service.mediaSource(track);

  /// 取歌词原文（LRC）。卡片里的滚动歌词用；没有歌词就返回 null。
  Future<String?> lyric(MusicTrack track) => _service.lyric(track);

  /// 已成功加载过排行榜 / 歌单标签（插件变化后按它们决定要不要重拉）。
  bool _chartsLoaded = false;
  bool _tagsLoaded = false;

  /// 插件集合的指纹（hash + 顺序 + 启停）：没变就不必清空已加载的内容。
  String _pluginFingerprint() =>
      plugins.map((plugin) => '${plugin.hash}:${plugin.enabled ? 1 : 0}').join('|');

  /// 插件换了一批之后，把用户原来在看的那些内容重新拉一遍。
  ///
  /// 只重拉「之前真的加载过」的东西：没打开过排行榜的用户不该被这次变化打扰。
  ///
  /// 这几次重拉一律 `refresh: true`：此时磁盘缓存正在被 [MusicFreeService.clearCache]
  /// 异步删除，走缓存会读到「本该作废」的旧结果。
  void _reloadContent() {
    final reloadCharts = _chartsLoaded;
    final reloadTags = _tagsLoaded;
    final query = _query;
    if (reloadCharts) {
      unawaited(loadCharts(force: true));
    }
    if (reloadTags) {
      unawaited(loadTagSections(force: true));
    }
    if (query.isNotEmpty) {
      unawaited(search(query, refresh: true));
    }
  }

  /// 插件换批 / 断线重连时清掉服务端相关状态。
  ///
  /// 插件变了，之前缓存的搜索结果（尤其是那些「能搜到但放不出」的音源）也该作废，
  /// 顺手把熔断记的账一起清了，换上来的新插件才能立刻参与搜索。
  void _resetContent() {
    _tracks = const <MusicTrack>[];
    _warnings = const <String>[];
    _skipped = const <String>[];
    _searchDone = 0;
    _searchTotal = 0;
    _chartGroups = const <MusicFreeTopListGroup>[];
    _chartsError = null;
    _tags = const MusicFreeTags();
    _sheets = const <MusicFreeSheet>[];
    _selectedTag = null;
    _detail = null;
    _detailError = null;
    _detailLoading = false;
    unawaited(_service.clearCache());
  }

  /// 退出登录 / 换服务器：清空所有内容状态。
  void reset() {
    _query = '';
    _searchError = null;
    _searching = false;
    _syncError = null;
    _syncMessage = null;
    _resetContent();
    _chartsLoaded = false;
    _tagsLoaded = false;
    notifyListeners();
  }

  static String _message(Object error) =>
      error is MusicFreeException ? error.message : '$error';
}