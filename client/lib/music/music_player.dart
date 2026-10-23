import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../core/app_log.dart';
import '../core/l10n_ext.dart';
import '../data/music_models.dart';
import '../data/music_store.dart';
import '../musicfree/musicfree_service.dart';
import '../room/room_music.dart';
import '../signaling/protocol.dart';
import 'clock_sync.dart';
import 'lrc.dart';

enum MusicPlayerStatus { idle, resolving, playing, paused, error }

/// 房间播放引擎：本机解析直链并播放。
///
/// 两种驱动方式：
/// * **服务端模式**（收到了房间点歌快照）：按 `anchorServerMs/anchorPositionMs`
///   起播与纠偏，播完上报 `music_eos`，切歌走服务端；
/// * **本地模式**（老服务器 / 没进房）：沿用本地队列自己推进。
class MusicPlayer extends ChangeNotifier {
  MusicPlayer({
    required this.queue,
    required this.resolve,
    this.ensureReady,
    this.loadLyric,
    this.clock,
    this.onSkipRoom,
    this.onReportEos,
    MusicStore? store,
  }) : _store = store ?? MusicStore() {
    unawaited(_restoreVolume());
  }

  /// 时钟偏移（与 `RoomSession` 共用一份，服务器时间统一从这里取）。
  final ClockSync? clock;

  /// 切歌（服务端模式：发 `music_skip`；本地模式由播放器自己推进）。
  final void Function()? onSkipRoom;

  /// 上报「本机放完了」（服务端模式：`music_eos`）。
  final void Function({required String entryId, required int revision})? onReportEos;

  /// 本机播放音量也落盘（各人独立，服务器不知道）。
  final MusicStore _store;
  /// 解析播放地址（`AppState` 接到 MusicFree 插件服务上）。
  final Future<MusicFreeMediaSource> Function(MusicTrack track) resolve;

  /// 取歌词（LRC 原文）。由 `AppState` 接到 MusicFree 插件服务上；
  /// 拿不到就返回 null，界面显示「暂无歌词」——歌词永远不该影响播放。
  final Future<String?> Function(MusicTrack track)? loadLyric;
  /// 插件还没装好时用来补装的钩子（由 `AppState` 提供）。
  final Future<void> Function()? ensureReady;

  static bool _mediaKitInitialized = false;

  static void ensureMediaKitInitialized() {
    if (_mediaKitInitialized) return;
    MediaKit.ensureInitialized();
    _mediaKitInitialized = true;
  }

  final RoomMusicQueue queue;
  final Set<String> _failedKeys = <String>{};

  Player? _audio;

  /// 底层播放器**首次真正要播时才创建**：`Player()` 一建就要媒体库就绪，
  /// 而音源装载、队列展示这些都不该被它拖住（单测环境里也没有 libmpv）。
  Player get _player => _audio ??= _createPlayer();

  Player _createPlayer() {
    // libmpv 到这里才加载：14.8MB 的 DLL，启动时同步 open 会白占首帧
    ensureMediaKitInitialized();
    final player = Player();
    player.stream.completed.listen((completed) {
      if (!completed) {
        return;
      }
      final entry = _roomCurrent;
      if (entry != null) {
        // 服务端模式：只上报 EOS，切歌由服务器决定（其他客户端也要跟着切）
        onReportEos?.call(entryId: entry.entryId, revision: _roomRevision);
        return;
      }
      _advance();
    });
    // 播放位置只用来推进歌词：没换句就不通知，避免每 100ms 重建一遍卡片。
    player.stream.position.listen(_onPosition);
    player.stream.error.listen((error) {
      AppLog.warn('音频播放错误', error: error);
      _fail(appL10n.musicAudioFailed);
    });
    return player;
  }

  MusicPlayerStatus _status = MusicPlayerStatus.idle;
  String? _error;
  MusicTrack? _current;
  MusicFreeMediaSource? _resolved;
  double _volume = 100;
  /// 静音前的音量：解除静音要回到它，而不是固定 100%。
  double _lastAudibleVolume = 100;
  /// 界面主动设过音量（含静音）：磁盘里的旧值不能再覆盖它。
  bool _volumeTouched = false;
  bool _disposed = false;

  /// 歌词（LRC 解析后）与当前句下标、当前播放位置。
  List<LyricLine> _lyrics = const <LyricLine>[];
  int _lyricIndex = -1;
  Duration _position = Duration.zero;
  final Map<String, List<LyricLine>> _lyricCache = <String, List<LyricLine>>{};

  /// 服务端模式的当前曲（null = 本地模式：由本地队列自己推进）。
  MusicCurrent? _roomCurrent;
  int _roomRevision = 0;
  int _lastDriftCheckMs = 0;

  /// 是否由服务端锚点驱动（收到过房间点歌快照）。
  bool get serverDriven => _roomCurrent != null;

  MusicPlayerStatus get status => _status;
  String? get error => _error;
  MusicTrack? get current => _current;
  MusicFreeMediaSource? get resolved => _resolved;
  bool get playing => _status == MusicPlayerStatus.playing;
  double get volume => _volume;

  /// 当前曲目的歌词与「唱到第几句」（-1 = 还没到第一句）。
  List<LyricLine> get lyrics => _lyrics;
  int get lyricIndex => _lyricIndex;
  Duration get position => _position;


  /// 音源脚本加载失败的原因（界面直接展示，别让「点了没反应」无迹可寻）。
  String? get sourceError => _sourceError;
  String? _sourceError;


  /// 播放前的兜底：插件还没装好就先补装一次（`AppState` 负责同步订阅）。
  Future<bool> _ensureReady() async {
    final loader = ensureReady;
    if (loader != null) {
      await loader();
      if (_disposed) {
        return false;
      }
    }
    return true;
  }

  Future<void> playCurrent() async {
    // 服务端模式的起播归 `applyRoomState`：它要先等锚点、必要时还得 seek。这条本地路径
    // 一旦也 open 一次，两边就对着同一个媒体各来一遍——先按 `open()` 的默认 play 出声，
    // 再被锚点那一路重开（`open(play: false)` + 等锚点），听感就是「放一两秒又回到开头」。
    if (queue.serverDriven) {
      return;
    }
    var track = queue.nowPlaying;
    if (track == null && !queue.isEmpty) {
      if (!await _ensureReady()) {
        return;
      }
      track = queue.next();
    }
    if (track == null || track.key == _current?.key && playing) {
      return;
    }
    await _playTrack(track);
  }

  /// 真正起播一首（本地模式）：解析直链 → 打开 → 播。
  ///
  /// 单曲循环要原地重来一遍，走的就是这里——`playCurrent` 有「同一首还在放就跳过」
  /// 的短路，直接调它会被挡掉。
  Future<void> _playTrack(MusicTrack track) async {
    _current = track;
    _status = MusicPlayerStatus.resolving;
    _error = null;
    // 换歌先把上一首的歌词清掉（界面立刻回「加载中/暂无歌词」），
    // 再并行去取——取歌词失败绝不能影响播放。
    _position = Duration.zero;
    _lyricIndex = -1;
    _lyrics = const <LyricLine>[];
    unawaited(_loadLyrics(track));
    notifyListeners();
    try {
      final resolved = await resolve(track);
      // 解析期间可能已经切歌 / 被叫停（离开房间、退出登录）：
      // 不拦一下，等慢音源返回后会把这歌重新放出来。
      if (_disposed || _current?.key != track.key) {
        return;
      }
      await _player.open(Media(resolved.url, httpHeaders: resolved.headers));
      await _player.setVolume(_volume);
      if (_disposed || _current?.key != track.key) {
        return;
      }
      _status = MusicPlayerStatus.playing;
      notifyListeners();
    } on Object catch (error) {
      if (_current?.key != track.key || _disposed) {
        return;
      }
      AppLog.warn('点歌播放失败 ${track.name}', error: error);
      _failedKeys.add(track.key);
      _fail(appL10n.musicPlayFailedSkipped(_briefMessage(error)));
      _advance();
    }
  }

  Future<void> togglePlayPause() async {
    if (_current == null) {
      await playNext();
      return;
    }
    if (_status == MusicPlayerStatus.playing) {
      await _player.pause();
      _status = MusicPlayerStatus.paused;
    } else if (_status == MusicPlayerStatus.paused) {
      await _player.play();
      _status = MusicPlayerStatus.playing;
    }
    notifyListeners();
  }

  Future<void> playNext() async {
    if (serverDriven) {
      // 服务端模式：切歌是房间行为（房主或点歌人），本地不自己出队
      onSkipRoom?.call();
      return;
    }
    await _advance();
  }

  /// 彻底停下（离开房间 / 退出登录）。
  ///
  /// 氛围音是本机用 media_kit 播的，**不会**跟着信令断开自动停——人已经离开房间、
  /// 歌还在响就是这个原因。这里把音频停掉、歌词和失败记录一起清干净；
  /// 队列由调用方决定要不要 reset（房间队列属于房间状态）。
  Future<void> stop() async {
    if (_disposed) {
      return;
    }
    _roomCurrent = null;
    await _stopAudio();
    _error = null;
    _failedKeys.clear();
    _goIdle();
  }

  /// 应用服务端下发的点歌状态（`music_state.current`）。
  ///
  /// * 没有当前曲 → 停播并回到空态；
  /// * 换了条目 → 解析直链、按锚点定位、到点起播（预滚 3 秒在服务端算好）；
  /// * 同一条目 → 什么都不做（播放位置由漂移纠偏负责）。
  Future<void> applyRoomState(MusicCurrent? current, {required int revision}) async {
    if (_disposed) {
      return;
    }
    _roomRevision = revision;
    final previous = _roomCurrent;
    _roomCurrent = current;
    if (current == null) {
      if (previous != null || _current != null) {
        await _stopAudio();
        _goIdle();
      }
      return;
    }
    // 同一条目：已经在放 / 正在解析才什么都不做。停过（idle）或上次失败（error）
    // 的时候要重来一次——重新进房拿到的往往就是同一条目，跳过的话它会一直不出声。
    // 锚点变了说明服务端让它重新开始（单曲循环），这时也要重来。
    if (previous?.entryId == current.entryId &&
        previous?.anchorServerMs == current.anchorServerMs &&
        _status != MusicPlayerStatus.idle &&
        _status != MusicPlayerStatus.error) {
      notifyListeners();
      return;
    }
    await _startRoomEntry(current);
  }

  Future<void> _startRoomEntry(MusicCurrent current) async {
    final track = MusicTrack(
      platform: current.source,
      id: current.songId,
      name: current.title,
      artists: <MusicArtist>[
        if (current.artist.isNotEmpty) MusicArtist(name: current.artist),
      ],
      durationMs: current.durationMs,
      musicInfo: current.musicInfo,
    );
    _current = track;
    _status = MusicPlayerStatus.resolving;
    _error = null;
    _position = Duration.zero;
    _lyricIndex = -1;
    _lyrics = const <LyricLine>[];
    unawaited(_loadLyrics(track));
    notifyListeners();
    try {
      final resolved = await resolve(track);
      if (_disposed || _roomCurrent?.entryId != current.entryId) {
        return;
      }
      // 先打开但不播：等锚点到了再 play，否则预滚那 3 秒会被听成「抢跑」
      await _player.open(Media(resolved.url, httpHeaders: resolved.headers), play: false);
      await _player.setVolume(_volume);
      final waitMs = _anchorWaitMs(current);
      if (waitMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: waitMs));
      } else {
        final positionMs = _expectedPositionMs(current);
        if (positionMs > 0 && (current.durationMs == null || positionMs < current.durationMs!)) {
          await _player.seek(Duration(milliseconds: positionMs));
        }
      }
      if (_disposed || _roomCurrent?.entryId != current.entryId) {
        return;
      }
      await _player.play();
      _status = MusicPlayerStatus.playing;
      _lastDriftCheckMs = 0;
      notifyListeners();
    } on Object catch (error) {
      if (_disposed || _roomCurrent?.entryId != current.entryId) {
        return;
      }
      AppLog.warn('房间点歌播放失败 ${current.title}', error: error);
      _fail(appL10n.musicPlayFailedLocal(_briefMessage(error)));
    }
  }

  /// 距离锚点还有多久（毫秒）：正数表示还在预滚，负数表示已经过点了。
  int _anchorWaitMs(MusicCurrent current) {
    final serverNow = clock?.serverNowMs() ?? DateTime.now().millisecondsSinceEpoch;
    return current.anchorServerMs - serverNow;
  }

  /// 按锚点算「此刻应该播到第几毫秒」。
  int _expectedPositionMs(MusicCurrent current) {
    final serverNow = clock?.serverNowMs() ?? DateTime.now().millisecondsSinceEpoch;
    final elapsed = serverNow - current.anchorServerMs;
    if (elapsed <= 0) {
      return current.anchorPositionMs;
    }
    final position = current.anchorPositionMs + elapsed;
    final duration = current.durationMs;
    if (duration != null && position > duration) {
      return duration;
    }
    return position;
  }

  /// 调本机播放音量（0~100）。
  ///
  /// 播放器还没真正创建（没播过任何东西）时不为了一个音量去建它：
  /// 音量先记着，下次 `open()` 之后会按当前值下发。
  Future<void> setVolume(double value) async {
    final next = value.clamp(0, 100).toDouble();
    // 用户/界面主动设过音量之后，启动时读到磁盘旧值也不能再覆盖它
    _volumeTouched = true;
    _volume = next;
    if (next > 0) {
      // 记下「静音前的音量」：解除静音要回到它，而不是固定 100%
      _lastAudibleVolume = next;
    }
    final audio = _audio;
    if (audio != null) {
      await audio.setVolume(_volume);
    }
    notifyListeners();
    unawaited(_store.saveVolume(_volume));
  }

  /// 静音 / 解除静音。
  ///
  /// 静音时把当前音量记下来，解除时还原——37% 静音再点回来还是 37%。
  Future<void> toggleMute() async {
    if (_volume > 0) {
      _lastAudibleVolume = _volume;
      await setVolume(0);
      return;
    }
    await setVolume(_lastAudibleVolume > 0 ? _lastAudibleVolume : 100);
  }

  /// 启动时恢复上次的音量（读不到就保持默认 100）。
  Future<void> _restoreVolume() async {
    try {
      final saved = await _store.loadVolume();
      // 读磁盘期间用户已经动过音量（或静音了）就以他为准，别把界面刚设的值顶掉
      if (saved == null || _disposed || _volumeTouched) {
        return;
      }
      _volume = saved.clamp(0, 100).toDouble();
      if (_volume > 0) {
        _lastAudibleVolume = _volume;
      }
      notifyListeners();
    } on Object catch (error) {
      AppLog.debug('读取音量偏好失败：$error');
    }
  }

  // ---------------------------------------------------------------- 歌词
  /// 拉这首的歌词并解析。
  ///
  /// 失败只记日志：歌词是锦上添花，绝不能影响播放，也不能让卡片一直转圈。
  Future<void> _loadLyrics(MusicTrack track) async {
    final loader = loadLyric;
    if (loader == null) {
      return;
    }
    final cached = _lyricCache[track.key];
    if (cached != null) {
      _applyLyrics(track, cached);
      return;
    }
    try {
      final raw = await loader(track);
      if (_disposed) {
        return;
      }
      final lines = raw == null ? const <LyricLine>[] : parseLrc(raw);
      if (lines.isNotEmpty) {
        if (_lyricCache.length >= 40) {
          _lyricCache.clear();
        }
        _lyricCache[track.key] = lines;
      }
      _applyLyrics(track, lines);
    } on Object catch (error) {
      AppLog.debug('取歌词失败 ${track.name}：$error');
      if (!_disposed) {
        _applyLyrics(track, const <LyricLine>[]);
      }
    }
  }

  /// 只写当前这首的歌词：迟到的旧歌歌词不能落到新歌头上。
  void _applyLyrics(MusicTrack track, List<LyricLine> lines) {
    if (_disposed || _current?.key != track.key) {
      return;
    }
    _lyrics = lines;
    _lyricIndex = activeLyricIndex(lines, _position);
    notifyListeners();
  }

  /// 播放位置推进：推进歌词；服务端模式下顺带做漂移纠偏（每 5 秒最多一次）。
  void _onPosition(Duration position) {
    _position = position;
    final room = _roomCurrent;
    if (room != null && _status == MusicPlayerStatus.playing) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastDriftCheckMs >= 5000) {
        _lastDriftCheckMs = now;
        final expected = _expectedPositionMs(room);
        final drift = position.inMilliseconds - expected;
        if (drift.abs() > 400) {
          // 落点差得多就硬拉回锚点；差得少交给播放器自己走（听感上更自然）
          AppLog.debug('点歌漂移纠偏 ${drift}ms');
          unawaited(_player.seek(Duration(milliseconds: expected < 0 ? 0 : expected)));
        }
      }
    }
    final index = activeLyricIndex(_lyrics, position);
    if (index == _lyricIndex) {
      return;
    }
    _lyricIndex = index;
    notifyListeners();
  }

  /// 测试位：单测里没有 libmpv，拿不到真实播放位置，用这个走同一条 [_onPosition]。
  @visibleForTesting
  void debugSetPosition(Duration position) => _onPosition(position);

  /// 测试位：按锚点算「此刻应该播到第几毫秒」（单测里没有真实播放器）。
  @visibleForTesting
  int debugExpectedPositionMs(MusicCurrent current) => _expectedPositionMs(current);

  /// 测试位：距离锚点还有多久（毫秒），正数表示还在预滚。
  @visibleForTesting
  int debugAnchorWaitMs(MusicCurrent current) => _anchorWaitMs(current);

  Future<void> _advance() async {
    if (_disposed) {
      return;
    }
    final current = _current;
    if (current != null &&
        queue.mode == PlaybackMode.repeatOne &&
        !_failedKeys.contains(current.key)) {
      // 单曲循环：同一首原地重来（不碰队列，也不会被「同一首跳过」的短路挡掉）
      await _playTrack(current);
      return;
    }
    if (queue.isEmpty) {
      await _stopAudio();
      _goIdle();
      return;
    }
    // 手动「播放 / 下一首」也走同一条兜底，别在音源没就绪时把歌从队列里吃掉
    if (!await _ensureReady()) {
      return;
    }
    var next = queue.next();
    while (next != null && _failedKeys.contains(next.key)) {
      next = queue.next();
    }
    if (next == null) {
      await _stopAudio();
      _goIdle();
      return;
    }
    await playCurrent();
  }

  /// 回到「什么都没在播」：清掉当前曲，同时把队列里的「正在播放」一起清掉。
  ///
  /// 后者很关键：底栏与「已在队列」的勾都会回落到 `queue.nowPlaying`，
  /// 不清掉的话最后一首放完还会停在那一首上，那首歌也永远点不回去。
  void _goIdle() {
    _current = null;
    _resolved = null;
    _status = MusicPlayerStatus.idle;
    _lyrics = const <LyricLine>[];
    _lyricIndex = -1;
    _position = Duration.zero;
    queue.finishPlaying();
    notifyListeners();
  }

  /// 只停已经创建出来的播放器：没播过就不必为此把媒体库拉起来。
  Future<void> _stopAudio() async {
    final audio = _audio;
    if (audio != null) {
      await audio.stop();
    }
  }

  void _fail(String message) {
    _status = MusicPlayerStatus.error;
    _error = message;
    notifyListeners();
  }

  /// 给界面看的错误文案：常见的网络故障翻译成人话，其余只放第一行（完整堆栈在日志里）。
  static String _briefMessage(Object error) {
    final text = error.toString();
    // 音源接口在国内常被按域名阻断，裸的 HandshakeException 用户看不懂
    if (text.contains('HandshakeException') ||
        text.contains('Connection terminated') ||
        text.contains('Connection reset')) {
      final l10n = appL10n;
      final host = RegExp(r'连接 ([^\s（()]+) 失败').firstMatch(text)?.group(1);
      final target = host == null
          ? l10n.musicSourceServer
          : l10n.musicSourceServerHost(host);
      // 客户端不再自己探测/配置代理（代理交给系统的 TUN/虚拟网卡接管），
      // 所以这里只提示「被网络阻断」，不再区分走没走代理
      return l10n.musicSourceBlocked(target);
    }
    if (text.contains('SocketException') ||
        text.contains('TimeoutException') ||
        text.contains('timed out')) {
      return appL10n.musicSourceTimeout;
    }
    final first = text.split('\n').first.trim();
    if (first.isEmpty) {
      return appL10n.musicUnknownError;
    }
    return first.length > 120 ? '${first.substring(0, 120)}…' : first;
  }

  void clearFailure(String trackKey) {
    _failedKeys.remove(trackKey);
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final audio = _audio;
    if (audio != null) {
      unawaited(audio.dispose());
    }
    super.dispose();
  }
}
