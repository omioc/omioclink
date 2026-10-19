import 'dart:math';

import 'package:flutter/foundation.dart';


import '../data/music_models.dart';
import '../signaling/protocol.dart';

/// 播放模式（房间级）：服务端权威，改了就全房间一起变。
///
/// 服务端模式下「下一首怎么来」由服务器推进；本地模式（老服务器 / 离线）
/// 下同一套模式由队列自己解释，两种模式的行为保持一致。
class PlaybackMode {
  const PlaybackMode._();

  static const String repeatAll = 'repeat_all';
  static const String repeatOne = 'repeat_one';
  static const String sequential = 'sequential';
  static const String shuffle = 'shuffle';

  /// 按钮轮换顺序：列表循环 → 单曲循环 → 顺序播放 → 随机播放。
  static const List<String> cycle = <String>[
    repeatAll,
    repeatOne,
    sequential,
    shuffle,
  ];
}


/// 点歌意图的出口：由 `RoomSession` 实现（把消息发到信令）。
///
/// 队列本身不认识 WebSocket：它只管「视图 + 意图」，这样单测里塞个假实现就能测。
abstract interface class MusicCommandSink {
  /// 服务端是否支持「一次点一批」：老服务器只认单条，批量点歌会退回逐条发。
  bool get supportsBatch;

  bool enqueue(MusicEntryDraft draft);

  /// 一次把 [drafts] 全发出去（整批算一次请求）；返回信令是否发出。
  bool enqueueBatch(List<MusicEntryDraft> drafts);

  void remove(String entryId);

  void skip({String? entryId});

  void clear();

  void reportEos({required String entryId, required int revision});

  /// 切换播放模式（房间级：服务端改完广播给所有人）。
  void setMode(String mode);
}

/// 点歌时提交给服务端的原始字段（`musicInfo` 是音源原始对象）。
class MusicEntryDraft {
  const MusicEntryDraft({
    required this.source,
    required this.songId,
    required this.musicInfo,
    required this.title,
    required this.artist,
    this.durationMs,
  });

  factory MusicEntryDraft.fromTrack(MusicTrack track) => MusicEntryDraft(
    source: track.platform,
    songId: track.id,
    musicInfo: track.musicInfo,
    title: track.name,
    artist: track.artistLabel,
    durationMs: track.durationMs,
  );

  final String source;
  final String songId;
  final Map<String, dynamic> musicInfo;
  final String title;
  final String artist;
  final int? durationMs;

  /// 同一条点歌的身份（音源 + 歌曲 id）：与服务端去重口径一致。
  String get key => '$source:$songId';
}

/// 房间点歌队列。
///
/// 两种模式：
/// * **服务端模式**（默认，进房后 `bind(sink)` 且收到过 `music_state`）：
///   视图只由服务端快照驱动，`enqueue/remove/skip/clear` 只发意图；
/// * **本地模式**（没有绑 sink，或服务器不支持点歌）：退化成离线本地队列，
///   保持旧行为，老服务器上也能用。
class RoomMusicQueue extends ChangeNotifier {
  RoomMusicQueue({
    this.capacity = 429,
    this.enqueueInterval = const Duration(milliseconds: 2200),
  });

  /// 队列上限（服务端同口径，本地模式也按这个来）。
  final int capacity;

  /// 批量点歌时两条之间的间隔。
  ///
  /// 服务端有 2 秒点歌冷却（`ENQUEUE_COOLDOWN_MS`），连发会让第 2 条起全被拒；
  /// 这里多留 10% 余量，抵掉网络与服务器侧的计时抖动。
  final Duration enqueueInterval;

  MusicCommandSink? _sink;

  /// 批量点歌的代次：解绑 / 换出口 / 又点了一批，都靠它让在跑的循环退出。
  int _batchToken = 0;

  /// 服务端快照（服务端模式下的唯一数据源）。
  int _revision = -1;
  MusicCurrent? _current;
  List<MusicEntry> _entries = const <MusicEntry>[];

  /// 本地模式的数据（服务端模式下不参与视图）。
  final List<MusicTrack> _local = <MusicTrack>[];
  MusicTrack? _localCurrent;
  /// 本地模式已经播完的歌：列表循环靠它把这一轮重新排一遍。
  final List<MusicTrack> _localPlayed = <MusicTrack>[];
  /// 随机播放用的随机源。
  final Random _rng = Random();

  /// 播放模式：服务端模式下由快照驱动，本地模式自己说了算。
  String _mode = PlaybackMode.repeatAll;

  /// 最近一次被服务端拒绝的原因（界面取走后清空）。
  String? _error;
  /// 观察者身份：界面据此决定「哪些按钮该露出来」，服务端仍会终审一次。
  /// 由 `RoomSession` 在收到 `room_state` 时写入（peerId 才是服务端口径的身份）。
  String? _selfPeerId;
  bool _isOwner = false;

  bool get serverDriven => _revision >= 0;


  /// 当前播放模式（房间级）：默认列表循环。
  String get mode => _mode;

  /// 切到下一个模式时的目标值（界面按钮按固定顺序轮换）。
  String get nextMode {
    final index = PlaybackMode.cycle.indexOf(_mode);
    return PlaybackMode.cycle[(index + 1) % PlaybackMode.cycle.length];
  }
  int get revision => _revision;

  MusicCurrent? get current => _current;

  /// 待播列表（服务端模式：服务器分配的条目；本地模式：本地队列）。
  List<MusicEntry> get entries => _entries;

  bool get isEmpty => serverDriven
      ? _current == null && _entries.isEmpty
      : _local.isEmpty;

  MusicTrack? get nowPlaying {
    if (!serverDriven) {
      return _localCurrent;
    }
    final current = _current;
    return current == null ? null : _trackOf(current);
  }

  int get length => serverDriven ? _entries.length : _local.length;

  bool get isFull => _entries.length >= capacity || _local.length >= capacity;


  /// 待播歌曲（点歌台右侧面板 / 卡片「接下来 N 首」都读它）。
  List<MusicTrack> get queue => serverDriven
      ? _entries.map(_trackOf).toList(growable: false)
      : List<MusicTrack>.unmodifiable(_local);

  bool contains(MusicTrack track) {
    if (serverDriven) {
      final current = _current;
      if (current != null && current.source == track.platform && current.songId == track.id) {
        return true;
      }
      return _entries.any(
        (entry) => entry.source == track.platform && entry.songId == track.id,
      );
    }
    return _localCurrent?.key == track.key ||
        _local.any((item) => item.key == track.key);
  }

  String? get lastError => _error;

  /// 取走错误（界面拿到后弹一次提示）。
  String? consumeError() {
    final message = _error;
    _error = null;
    return message;
  }

  void noteError(String message) {
    _error = message;
    notifyListeners();
  }

  // ------------------------------------------------------------------ 权限判断
  /// 我的会话内 peerId（`music_state` 里 `requestedBy.peerId` 的同口径标识）。
  String? get selfPeerId => _selfPeerId;

  /// 当前的意图出口（会话销毁时用它判断「还是不是我」）。
  MusicCommandSink? get sink => _sink;

  /// 只在出口还是 [target] 时解绑。
  ///
  /// 会话销毁可能晚于新会话绑定（进房失败后重建、被踢后重进）：无条件解绑会把
  /// 新会话的出口一起摘掉，之后点歌就静默失败了。
  void unbind(MusicCommandSink target) {
    if (identical(_sink, target)) {
      _sink = null;
      // 批量点歌还在跑的话立刻收手：出口没了，接着发只会刷一串「没发出去」
      _batchToken += 1;
    }
  }

  /// 我是不是房主（服务端只认房主清空队列 / 切别人的歌）。
  bool get isOwner => _isOwner;

  /// 身份还不知道（`room_state` 还没到）：这时不做本地拦截，交给服务端裁决。
  bool get _identityKnown => (_selfPeerId ?? '').isNotEmpty;

  /// 能不能切**当前曲**：房主，或这首的点歌人。
  bool get canSkipCurrent {
    if (!serverDriven) {
      return true;
    }
    final current = _current;
    return current != null && _canControl(current);
  }

  /// 能不能把这行移出队列：房主，或点这首歌的人。
  bool canRemoveEntry(MusicEntry entry) => !serverDriven || _canControl(entry);

  /// 能不能清空队列（服务端只认房主）。
  bool get canClear => !serverDriven || _isOwner || !_identityKnown;

  /// 这行是不是我点的（界面显示「（我）」）。
  bool isMine(MusicEntry entry) =>
      _identityKnown && entry.requestedBy.peerId == _selfPeerId;

  bool _canControl(MusicEntry entry) {
    if (_isOwner || !_identityKnown) {
      return true;
    }
    return entry.requestedBy.peerId == _selfPeerId;
  }

  /// 写观察者身份（进房拿到 `room_state` 后调用）。
  void setViewer({String? peerId, bool isOwner = false}) {
    if (_selfPeerId == peerId && _isOwner == isOwner) {
      return;
    }
    _selfPeerId = peerId;
    _isOwner = isOwner;
    notifyListeners();
  }

  // ------------------------------------------------------------------ 绑定
  /// 进入房间时绑定信令出口；离房时传 null 回到本地模式。
  void bind(MusicCommandSink? sink) {
    _sink = sink;
    // 换了出口：上一批还在跑的逐条发送要作废，否则会发到旧会话里
    _batchToken += 1;
  }

  /// 应用服务端快照（幂等：旧 revision 直接丢）。
  void applySnapshot(MusicSnapshot snapshot) {
    if (snapshot.revision < _revision) {
      return;
    }
    _revision = snapshot.revision;
    _current = snapshot.current;
    _entries = snapshot.queue;
    _mode = snapshot.mode;
    // 服务端接管之后，本地列表不再有意义
    _local.clear();
    _localPlayed.clear();
    _localCurrent = null;
    notifyListeners();
  }

  // ------------------------------------------------------------------ 意图
  /// 点歌。返回 false 表示本地就能判定加不进去（重复 / 已满）。
  bool enqueue(MusicTrack track) {
    if (contains(track) || isFull) {
      return false;
    }
    final sink = _sink;
    if (sink == null || !serverDriven) {
      // 本地模式（老服务器 / 离线）：直接进本地队列，等播放器来取
      _local.add(track);
      notifyListeners();
      return true;
    }
    if (!sink.enqueue(MusicEntryDraft.fromTrack(track))) {
      // 信令没发出去（断线中）：否则界面看起来「点成功了却什么都没发生」
      noteError('点歌没发出去：与服务器的连接已断开，稍后重试');
    }
    return true;
  }

  /// 批量点歌：服务端支持批量就**一次发完**（整批算一次请求，不受 2 秒冷却限制）。
  ///
  /// 老服务器只认单条，只能按 [enqueueInterval] 逐条发，一次操作要等一会儿。
  /// 返回值是发出去的条数；重复、超出每人配额、队列满了的先在这里挡掉。
  Future<int> enqueueAll(Iterable<MusicTrack> tracks, {int limit = 88}) async {
    final picked = <MusicTrack>[];
    final seen = <String>{};
    // 每人配额含正在播的那首：自己已经占了多少要扣掉，否则服务端会静默丢尾巴
    final quota = limit - mineCount;
    for (final track in tracks) {
      if (isFull || picked.length >= quota) {
        break;
      }
      // 同一批里重复的歌要先记下来：快照回来之前 contains() 还看不见刚发出去的那首
      if (seen.contains(track.key) || contains(track)) {
        continue;
      }
      seen.add(track.key);
      picked.add(track);
    }
    if (picked.isEmpty) {
      return 0;
    }
    final sink = _sink;
    if (sink == null || !serverDriven) {
      // 本地模式（老服务器 / 离线）：直接进本地队列，等播放器来取
      final before = _local.length;
      for (final track in picked) {
        if (isFull) {
          break;
        }
        _local.add(track);
      }
      if (_local.length != before) {
        notifyListeners();
      }
      return _local.length - before;
    }
    final drafts = picked.map(MusicEntryDraft.fromTrack).toList(growable: false);
    if (!sink.supportsBatch) {
      return _sendPaced(drafts);
    }
    if (!sink.enqueueBatch(drafts)) {
      noteError('点歌没发出去：与服务器的连接已断开，稍后重试');
      return 0;
    }
    return drafts.length;
  }

  /// 老服务器只认单条点歌：按 [enqueueInterval] 逐条发，免得第 2 条起撞上冷却。
  Future<int> _sendPaced(List<MusicEntryDraft> drafts) async {
    final token = ++_batchToken;
    var added = 0;
    for (final draft in drafts) {
      // 换会话 / 离房 / 又点了一批：这一批立刻收手，别接着往旧出口发
      if (token != _batchToken) {
        break;
      }
      if (added > 0) {
        await Future<void>.delayed(enqueueInterval);
        if (token != _batchToken) {
          break;
        }
      }
      final sink = _sink;
      if (sink == null || !sink.enqueue(draft)) {
        noteError('点歌没发出去：与服务器的连接已断开，稍后重试');
        break;
      }
      added += 1;
    }
    return added;
  }

  /// 我已经占了多少个名额（服务端每人上限含正在播的那首）；身份未知时算 0。
  int get mineCount {
    final me = _selfPeerId;
    if (me == null || me.isEmpty || !serverDriven) {
      return 0;
    }
    final current = _current;
    var count = _entries.where((entry) => entry.requestedBy.peerId == me).length;
    if (current != null && current.requestedBy.peerId == me) {
      count += 1;
    }
    return count;
  }

  /// 从队列移除（本人或房主；服务端会再校验一次）。
  void remove(MusicTrack track) {
    if (!serverDriven) {
      final before = _local.length;
      _local.removeWhere((item) => item.key == track.key);
      if (_local.length != before) {
        notifyListeners();
      }
      return;
    }
    for (final entry in _entries) {
      if (entry.source == track.platform && entry.songId == track.id) {
        _sink?.remove(entry.entryId);
        return;
      }
    }
  }

  /// 清空队列（房主；服务端会再校验）。
  void clear() {
    if (!serverDriven) {
      if (_local.isEmpty) {
        return;
      }
      _local.clear();
      _localPlayed.clear();
      notifyListeners();
      return;
    }
    _sink?.clear();
  }

  /// 切歌（房主或当前曲点歌人；服务端会再校验）。
  void skip() {
    if (!serverDriven) {
      next();
      return;
    }
    _sink?.skip(entryId: current?.entryId);
  }

  /// 本机放完了（服务端模式下上报 EOS）。
  void reportEos() {
    final current = _current;
    if (!serverDriven || current == null || _sink == null) {
      return;
    }
    _sink!.reportEos(entryId: current.entryId, revision: _revision);
  }

  /// 切换播放模式：服务端模式下只发意图（广播回来才算数），本地模式立刻生效。
  void setMode(String mode) {
    if (serverDriven) {
      _sink?.setMode(mode);
      return;
    }
    if (mode == _mode) {
      return;
    }
    _mode = mode;
    notifyListeners();
  }

  /// 切指定条目（队列面板里的「切歌」）。
  ///
  /// 服务端只接受**当前曲**的 entryId（别的条目会回 `music_not_found`）：
  /// 想跳到某首歌得等它自己排到，这里不发明协议。
  void skipEntry(String entryId) {
    if (!serverDriven) {
      next();
      return;
    }
    _sink?.skip(entryId: entryId);
  }

  // ---------------------------------------------------------------- 本地模式
  /// 本地模式：取下一首（只有本地模式会用到；服务端模式由服务器推进）。
  MusicTrack? next() {
    if (serverDriven) {
      final roomCurrent = _current;
      return roomCurrent == null ? null : _trackOf(roomCurrent);
    }
    // 列表循环：这一轮播完了，把刚播过的按原顺序重新排一遍
    if (_local.isEmpty &&
        _mode == PlaybackMode.repeatAll &&
        _localPlayed.isNotEmpty) {
      _local.addAll(_localPlayed);
      _localPlayed.clear();
    }
    if (_local.isEmpty) {
      _localCurrent = null;
      notifyListeners();
      return null;
    }
    // 随机播放：从待播里随便挑一首；其余模式都是先进先出
    final index = _mode == PlaybackMode.shuffle && _local.length > 1
        ? _rng.nextInt(_local.length)
        : 0;
    _localCurrent = _local.removeAt(index);
    _localPlayed.add(_localCurrent!);
    notifyListeners();
    return _localCurrent;
  }

  void finishPlaying() {
    if (serverDriven) {
      return;
    }
    if (_localCurrent == null) {
      return;
    }
    _localCurrent = null;
    notifyListeners();
  }

  /// 离房 / 换服务器：回到「没有数据」的状态（服务端模式一并退出）。
  void reset() {
    _selfPeerId = null;
    _isOwner = false;
    _sink = null;
    _revision = -1;
    _current = null;
    _entries = const <MusicEntry>[];
    _local.clear();
    _localPlayed.clear();
    _localCurrent = null;
    _mode = PlaybackMode.repeatAll;
    _error = null;
    notifyListeners();
  }

  MusicTrack _trackOf(MusicEntry entry) => MusicTrack(
    platform: entry.source,
    id: entry.songId,
    name: entry.title,
    artists: <MusicArtist>[
      if (entry.artist.isNotEmpty) MusicArtist(name: entry.artist),
    ],
    durationMs: entry.durationMs,
    musicInfo: entry.musicInfo,
  );
}
