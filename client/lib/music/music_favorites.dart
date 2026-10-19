import 'package:flutter/foundation.dart';

import '../core/app_log.dart';
import '../data/music_models.dart';
import '../data/music_store.dart';

/// 「我喜欢」：本机自己的一份收藏，与服务器、插件都无关。
///
/// 与 MusicFree 的做法一致——「喜欢」就是一张不出现在别处的本地歌单：
/// 行尾的心形只管往这里加 / 删，左导航读同一份数据，点里面的歌能再点一遍。
/// 数据落在客户端（`MusicStore` → SharedPreferences），所以换电脑、换账号都不同步，
/// 服务器既不知道也不需要知道。
class MusicFavorites extends ChangeNotifier {
  MusicFavorites({MusicStore? store, this.limit = 500})
    : _store = store ?? MusicStore();

  /// 一份「我喜欢」最多存这么多首。
  ///
  /// 每条都要带上完整的 `musicInfo` 才能再次解析播放地址，条目没有上限的话
  /// SharedPreferences 会越写越慢（每次切换都要整份重写）；超出就丢最老的那首，
  /// 顺序本身是「新的在前」，从尾部丢即是丢最老的。
  final int limit;

  final MusicStore _store;

  /// 新的排在最前：点喜欢基本都发生在刚听到的那首上，放顶上不用先滚到底。
  final List<MusicTrack> _tracks = <MusicTrack>[];

  /// 与 [_tracks] 同步的键集合（`platform:id`）：每帧判断心形状态时不用扫列表。
  final Set<String> _keys = <String>{};

  bool _loaded = false;
  bool _loading = false;
  bool _disposed = false;

  /// 落盘串行化：连点几下心形会触发多次写入，乱序落盘会让「刚取消的歌」
  /// 在重启后又冒出来。所以统一排队，最后写入的那份快照为准。
  Future<void> _writing = Future<void>.value();

  List<MusicTrack> get tracks => List<MusicTrack>.unmodifiable(_tracks);

  int get length => _tracks.length;

  bool get isEmpty => _tracks.isEmpty;

  bool get loaded => _loaded;

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

  /// 从本机读回上次的收藏。
  ///
  /// 幂等：点歌台挂载时会调、`AppState` 启动时也会调，重复调用直接返回。
  Future<void> load() async {
    if (_loaded || _loading) {
      return;
    }
    _loading = true;
    try {
      final stored = await _store.loadFavorites();
      _tracks
        ..clear()
        ..addAll(stored.take(limit));
      _keys
        ..clear()
        ..addAll(_tracks.map((track) => track.key));
      _loaded = true;
    } on Object catch (error) {
      // 读不出来就当没有收藏：不能因为一份坏数据让点歌台起不来
      AppLog.warn('读取「我喜欢」失败', error: error);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  bool contains(MusicTrack track) => _keys.contains(track.key);

  /// 心形按钮：已在列表里就移出，否则加到最前面。返回操作后的状态。
  bool toggle(MusicTrack track) {
    if (_keys.contains(track.key)) {
      remove(track);
      return false;
    }
    add(track);
    return true;
  }

  void add(MusicTrack track) {
    if (!_keys.add(track.key)) {
      return;
    }
    _tracks.insert(0, track);
    while (_tracks.length > limit) {
      final dropped = _tracks.removeLast();
      _keys.remove(dropped.key);
    }
    notifyListeners();
    _persist();
  }

  void remove(MusicTrack track) {
    if (!_keys.remove(track.key)) {
      return;
    }
    _tracks.removeWhere((item) => item.key == track.key);
    notifyListeners();
    _persist();
  }

  void clear() {
    if (_tracks.isEmpty) {
      return;
    }
    _tracks.clear();
    _keys.clear();
    notifyListeners();
    _persist();
  }

  /// 等落盘结束（测试用）。
  ///
  /// 只能在普通 `test` 里 await：`testWidgets` 里界面已经挂载时，写盘要等 fake async
  /// 把平台消息跑完，而 `await` 本身不会推进时钟——那条用例会永远等下去。
  /// 界面上不需要它：写盘本来就是排队的后台动作。
  Future<void> flush() => _writing;

  void _persist() {
    final snapshot = List<MusicTrack>.of(_tracks);
    _writing = _writing.then((_) async {
      try {
        await _store.saveFavorites(snapshot);
      } on Object catch (error) {
        AppLog.warn('保存「我喜欢」失败', error: error);
      }
    });
  }
}
