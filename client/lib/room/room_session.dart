import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';

import '../core/app_log.dart';
import '../data/models.dart';
import '../data/volume_store.dart';
import '../media/media_engine.dart';
import '../media/media_models.dart';
import '../media/media_port.dart';
import '../media/share_policy.dart';
import '../music/clock_sync.dart';
import '../signaling/protocol.dart';
import '../signaling/signaling_client.dart';
import 'peer_levels.dart';
import 'peer_volume_controller.dart';
import 'room_models.dart';
import 'room_music.dart';

/// 可直接展示给用户的房间错误。
class RoomException implements Exception {
  const RoomException(this.message, {this.code = 'room_error'});

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// 房间会话：把信令事件翻译成媒体动作，把媒体事件翻译成信令消息。
///
/// 组网规则（与服务端约定一致，结构上避免 glare）：
/// **新进房的成员主动向房间内所有既有成员发起 offer**；被叫方回 answer。
/// Perfect Negotiation 的 polite/impolite 仅作兜底，由 peerId 字典序确定性指派。
class RoomSession extends ChangeNotifier implements MusicCommandSink {
  RoomSession({
    required this.signaling,
    required this.media,
    required this.currentUser,
    RoomMusicQueue? music,
    VolumeStore? volumeStore,
    this.clock,
    this.onMusicError,
    this.statsInterval = const Duration(seconds: 2),
  }) : music = music ?? RoomMusicQueue(),
       _ownsMusic = music == null {
    // 点歌队列的意图从会话发出去（队列自己不认识 WebSocket）
    this.music.bind(this);
    media.callbacks = MediaEngineCallbacks(
      onLocalDescription: _onLocalDescription,
      onLocalCandidate: _onLocalCandidate,
      onLinkStateChanged: _onLinkStateChanged,
      onDataChannel: _onDataChannel,
    );
    media.micLevel.addListener(_onMicLevelChanged);
    peerVolumes = PeerVolumeController(
      sink: MediaPortPeerAudioSink(media),
      store: volumeStore,
    );
  }

  final SignalingClient signaling;

  /// 只依赖媒体端口，便于纯 Dart 单测注入内存实现。
  final MediaPort media;

  /// 播放队列由应用级状态注入，保证点歌台、右侧队列和播放条看到同一份数据。
  final RoomMusicQueue music;

  /// 队列是不是自己建的。外部注入的队列跨房间复用，**不能**跟着会话一起释放——
  /// 释放会清掉它的监听者，之后点歌再也不会自动起播。
  final bool _ownsMusic;

  /// 时钟偏移（与播放器共用一份）：ping/pong 采样后，`music_state` 的锚点才能换算。
  final ClockSync? clock;

  /// 点歌被服务端拒绝时的回调（界面弹 snackbar；不写进房间错误横幅）。
  final void Function(String message)? onMusicError;

  /// 当前用户；昵称改了之后会随着 [updateCurrentUser] 更新（聊天署名要用新名字）。
  User currentUser;

  /// 连接质量采样周期。
  final Duration statsInterval;

  final _uuid = const Uuid();

  StreamSubscription<ServerMessage>? _messageSubscription;
  Timer? _statsTimer;
  bool _disposed = false;
  bool _tearingDown = false;
  String? _joinedRoomId;
  String? _joinedPassword;

  /// peerId → 上一次的字节计数（用于算实时码率）。
  final Map<String, ({int sent, int received, DateTime at})> _lastBytes =
      <String, ({int sent, int received, DateTime at})>{};

  RoomPhase _phase = RoomPhase.idle;
  RoomPhase get phase => _phase;

  String? _selfPeerId;
  String? get selfPeerId => _selfPeerId;

  RoomSummary? _room;
  RoomSummary? get room => _room;

  /// 房间点歌队列的最近一次权威快照（`room_state.music` / `music_state`）。
  ///
  /// 只存快照、不在这里做业务：真正的队列视图与播放控制由
  /// `RoomMusicQueue` / `MusicPlayer` 消费它（服务端是唯一权威）。
  MusicSnapshot? _musicSnapshot;
  MusicSnapshot? get musicSnapshot => _musicSnapshot;

  /// 服务端是否支持一次点一批（`hello.musicBatch`）：老服务器只认单条点歌。
  bool _musicBatchSupported = false;
  bool get musicBatchSupported => _musicBatchSupported;

  String? _lastError;
  String? get lastError => _lastError;

  final Map<String, MemberInfo> _members = <String, MemberInfo>{};
  final Map<String, PeerLinkState> _linkStates = <String, PeerLinkState>{};
  final List<ChatMessage> _chat = <ChatMessage>[];

  /// 每个成员的实时电平（自己来自本地电平计，别人来自 P2P presence 广播）。
  ///
  /// 单独的通知源：电平每 100ms 变一次，只有订阅它的成员行会重建。
  final PeerLevels peerLevels = PeerLevels();

  /// 被我本地屏蔽了声音的成员（只影响我听不听得到，对方无感知）。
  final Set<String> _locallyMuted = <String>{};

  /// 每个成员的音量：按成员的服务器身份（userId）持久化，只影响本机听感。
  ///
  /// 音量 0 走确定性静音（见 `PeerAudioMixer`），与「对某人静音」并联。
  late final PeerVolumeController peerVolumes;

  /// 上一次广播出去的电平，用来抑制高频重复发送。
  ({double level, bool speaking})? _lastPresence;

  /// 电平变化超过这个档位才重发一次 presence（约等于 2.4dB）。
  static const double _presenceLevelStep = 0.04;

  RoomStats _stats = const RoomStats();
  RoomStats get stats => _stats;

  bool _microphoneMuted = false;
  bool get microphoneMuted => _microphoneMuted;

  /// 上一次上报给房间的「我在说话」状态，用来避免每 100ms 的电平抖动都打一条信令。
  bool _selfSpeaking = false;

  /// 本地麦克风实时状态（电平 + 是否在说话），界面直接监听它画电平条。
  ValueListenable<MicLevel> get micLevel => media.micLevel;

  bool _speakerEnabled = true;
  bool get speakerEnabled => _speakerEnabled;

  List<ChatMessage> get chat => List.unmodifiable(_chat);

  /// 成员列表（自己排最前，其余按进房时间）。
  List<RoomMemberView> get members {
    final list = _members.values
        .map(
          (info) => RoomMemberView(
            info: info,
            local: info.peerId == _selfPeerId,
            mutedLocally: _locallyMuted.contains(info.peerId),
          ),
        )
        .toList();
    list.sort((a, b) {
      if (a.local != b.local) {
        return a.local ? -1 : 1;
      }
      final left = a.info.joinedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final right = b.info.joinedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final byTime = left.compareTo(right);
      return byTime != 0 ? byTime : a.info.peerId.compareTo(b.info.peerId);
    });
    return list;
  }

  MemberInfo? get selfMember =>
      _selfPeerId == null ? null : _members[_selfPeerId!];

  /// 当前正在共享屏幕的成员（同一时刻只认第一个，与服务端语义一致）。
  MemberInfo? get activeSharer {
    for (final view in members) {
      if (view.info.sharing) {
        return view.info;
      }
    }
    return null;
  }

  PeerLinkState linkStateOf(String peerId) =>
      _linkStates[peerId] ?? PeerLinkState.idle;

  /// 按 peerId 取成员信息（聊天消息的头像要用它反查）。
  MemberInfo? memberOf(String peerId) => _members[peerId];

  /// 已直连的成员数（不含自己）。
  int get connectedPeerCount =>
      _linkStates.values.where((state) => state.isLive).length;

  /// 有没有成员打洞失败（用于「网络受限」提示）。
  bool get hasPunchFailure =>
      _linkStates.values.any((state) => state == PeerLinkState.failed);

  int get peerCount => _members.length - 1;

  // ------------------------------------------------------------------ 生命周期
  /// 进入房间。成功时 [phase] 变为 [RoomPhase.active]。
  Future<void> join({required String roomId, String? password}) async {
    if (_disposed) {
      throw const RoomException('会话已释放');
    }
    AppLog.info(
      '加入房间 $roomId（${password == null || password.isEmpty ? '无密码' : '带密码'}）',
    );
    AppLog.memory('进房前');
    _lastError = null;
    // 读本机保存的成员音量：不挡住进房流程（读不到就按默认 100%）
    unawaited(peerVolumes.load());
    _joinedRoomId = roomId;
    _joinedPassword = password;
    _messageSubscription ??= signaling.messages.listen(_onMessage);

    _setPhase(RoomPhase.connecting);
    await _ensureSignalingReady();

    _setPhase(RoomPhase.joining);
    final waiter = Completer<void>();
    _joinWaiter = waiter;
    if (!signaling.send(joinRoomMessage(roomId: roomId, password: password))) {
      _joinWaiter = null;
      throw const RoomException('信令未就绪，请稍后重试');
    }
    try {
      await waiter.future.timeout(
        const Duration(seconds: 12),
        onTimeout: () => throw const RoomException('进房超时，请检查网络'),
      );
    } on Object {
      _joinWaiter = null;
      _setPhase(RoomPhase.failed);
      rethrow;
    }
  }

  /// 主动离开房间（保留信令连接，便于再进其他房间）。
  Future<void> leave() async {
    if (_phase == RoomPhase.idle) {
      return;
    }

    // 先把点歌视图摘掉再改 phase：改 phase 会 notify，AppState 收到通知就会去
    // 「应用最新的 music_state」——快照还留着的话，离开房间这一刻会把刚停掉的
    // 那首歌重新解析、起播（现象就是「人已经离开房间，歌还在响」）。
    _musicSnapshot = null;
    music.reset();
    _setPhase(RoomPhase.leaving);
    _joinedRoomId = null;
    _joinedPassword = null;
    signaling.send(leaveRoomMessage());
    await _teardownMedia();
    _resetRoomState();
    _setPhase(RoomPhase.idle);
  }

  Completer<void>? _joinWaiter;

  Future<void> _ensureSignalingReady() async {
    if (signaling.isConnected) {
      return;
    }
    final completer = Completer<void>();
    void listener() {
      if (signaling.phase.value == SignalingPhase.failed) {
        if (!completer.isCompleted) {
          completer.completeError(
            RoomException(
              signaling.lastError.value ?? '无法连接到服务器',
              code: 'signaling_failed',
            ),
          );
        }
      } else if (signaling.isConnected && !completer.isCompleted) {
        completer.complete();
      }
    }

    signaling.phase.addListener(listener);
    signaling.connect();
    try {
      await completer.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw const RoomException(
          '连接服务器超时，请检查地址与网络',
          code: 'connect_timeout',
        ),
      );
    } finally {
      signaling.phase.removeListener(listener);
    }
  }

  // ------------------------------------------------------------------ 信令分发
  Future<void> _onMessage(ServerMessage message) async {
    switch (message) {
      case ServerHello():
        media.updateIceServers(message.iceServers);
        // 老服务器没有这个能力位：批量点歌会退回逐条发
        _musicBatchSupported = message.musicBatch;
        if (_joinedRoomId != null && _phase == RoomPhase.active) {
          unawaited(_rejoinAfterReconnect());
        }
      case RoomStateMessage():
        await _onRoomState(message);
      case MusicStateMessage():
        _onMusicState(message.snapshot);
      case MemberJoinedMessage():
        _members[message.member.peerId] = message.member;
        notifyListeners();
      case MemberLeftMessage():
        await _onMemberLeft(message);
      case MemberStateChangedMessage():
        final existing = _members[message.peerId];
        if (existing != null) {
          final updated = existing.applyPatch(message.patch);
          _members[message.peerId] = updated;
          // P2P 还没接通时，绿灯靠服务端中继的这个布尔值
          peerLevels.applySpeaking(message.peerId, updated.speaking);
          notifyListeners();
        }
      case RelayOfferMessage():
        await _onOffer(message);
      case RelayAnswerMessage():
        await media.handleRemoteAnswer(message.src, message.sdp);
      case RelayCandidateMessage():
        await media.handleRemoteCandidate(message.src, message.candidate);
      case RoomClosedMessage():
        await _onRoomClosed(message);
      case KickedMessage():
        await _onKicked(message);
      case ServerErrorMessage():
        _onServerError(message);
      case ServerPingMessage():
        break;
      case PongMessage():
        _onPong(message);
      case UnknownServerMessage():
        break;
    }
  }

  /// 服务端推送的点歌队列快照。
  ///
  /// 只保留最新 `revision`：乱序到达的旧快照会让界面「倒退」，直接丢掉。
  void _onMusicState(MusicSnapshot snapshot) {
    final current = _musicSnapshot;
    if (current != null && snapshot.revision < current.revision) {
      return;
    }
    _musicSnapshot = snapshot;
    notifyListeners();
  }

  // ------------------------------------------------------------- 点歌意图出口
  @override
  bool enqueue(MusicEntryDraft draft) => signaling.send(
    musicEnqueueMessage(
      source: draft.source,
      songId: draft.songId,
      musicInfo: draft.musicInfo,
      title: draft.title,
      artist: draft.artist,
      durationMs: draft.durationMs,
    ),
  );

  @override
  bool get supportsBatch => _musicBatchSupported;

  @override
  bool enqueueBatch(List<MusicEntryDraft> drafts) => signaling.send(
    musicEnqueueBatchMessage([
      for (final draft in drafts)
        musicEnqueueEntry(
          source: draft.source,
          songId: draft.songId,
          musicInfo: draft.musicInfo,
          title: draft.title,
          artist: draft.artist,
          durationMs: draft.durationMs,
        ),
    ]),
  );

  @override
  void remove(String entryId) =>
      signaling.send(musicRemoveMessage(entryId: entryId));

  @override
  void skip({String? entryId}) =>
      signaling.send(musicSkipMessage(entryId: entryId));

  @override
  void clear() => signaling.send(musicClearMessage());

  @override
  void reportEos({required String entryId, required int revision}) =>
      signaling.send(musicEosMessage(entryId: entryId, revision: revision));

  @override
  void setMode(String mode) => signaling.send(musicModeMessage(mode: mode));

  /// 客户端自己发的 ping 还没收到 pong 的样本：`t` → 发出时刻（本机毫秒）。
  final Map<double, int> _pendingPings = <double, int>{};

  /// ping/pong 采样：`t` 是客户端发出的本机毫秒，`serverTimeMs` 是服务器时刻。
  void _onPong(PongMessage message) {
    final t = message.t;
    if (t == null || message.serverTimeMs <= 0) {
      return;
    }
    final sentAt = _pendingPings.remove(t);
    if (sentAt == null) {
      return;
    }
    clock?.addSample(
      t0: sentAt,
      serverTimeMs: message.serverTimeMs,
      t1: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 进房后连打几发 ping：取 RTT 最小的一次作为时钟偏移（协议 §5.1）。
  Future<void> _calibrateClock() async {
    if (clock == null) {
      return;
    }
    for (var index = 0; index < 5; index += 1) {
      if (!signaling.isConnected) {
        return;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final t = now.toDouble();
      _pendingPings[t] = now;
      signaling.send(pingMessage(t: t));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    _pendingPings.clear();
  }

  Future<void> _onRoomState(RoomStateMessage message) async {
    AppLog.info(
      '进房成功 room=${message.room.roomId} 成员=${message.members.length} '
      '自己=${message.selfPeerId}',
    );
    _room = message.room;
    _selfPeerId = message.selfPeerId;
    // 队列面板要靠身份决定露出哪些按钮（服务端仍会终审）
    _syncMusicViewer();
    _musicSnapshot = message.music;
    _members
      ..clear()
      ..addEntries(
        message.members.map((member) => MapEntry(member.peerId, member)),
      );
    _linkStates.clear();
    _lastBytes.clear();
    // 进房时房间里的我还被服务端记成「没说话」，清掉本地缓存以便
    // 下一个采样周期把当前真实状态补报一次
    _selfSpeaking = false;
    // 服务端可能还记着上一次会话的共享状态（peer 对象在离开房间时被复用），
    // 先按本地媒体层纠一次，免得进来的第一帧就画一块黑屏
    _reconcileSharing();
    _setPhase(RoomPhase.active);
    // 进房就连打几发 ping 估时钟偏移：点歌锚点要靠它换算成本机时刻
    unawaited(_calibrateClock());

    final waiter = _joinWaiter;
    _joinWaiter = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }

    await _startLocalMedia();
    AppLog.info('本地采集处理完毕，开始与既有成员建连（${_members.length - 1} 人）');
    await _dialExistingMembers();
    AppLog.info('与既有成员的建连已发起完毕');
    _startStatsTimer();
  }

  /// 把「我是否在共享」的对外状态与本地媒体层对齐。
  ///
  /// 服务端在离开房间时只把会话摘出房间，重进房间用的还是同一个 peer 对象：那边要是
  /// 残留着 `sharing=true`，进房快照里自己就是「正在共享」。界面会照着一块没有数据源
  /// 的画面去渲染（黑屏），而共享按钮按「已经在共享」处理——第一次点只是「停止」，
  /// 得点第二次才真的开始共享。所以这里以本地有没有在采集为准纠正一次，并回告服务器。
  void _reconcileSharing() {
    final self = _selfPeerId;
    if (self == null) {
      return;
    }
    final member = _members[self];
    if (member == null) {
      return;
    }
    final actual = media.isScreenSharing;
    if (member.sharing == actual) {
      return;
    }
    AppLog.info(
      '进房时纠正共享状态：服务端=${member.sharing} 本地=$actual，以本地为准',
    );
    _members[self] = member.copyWith(sharing: actual);
    signaling.send(memberStateMessage(sharing: actual));
  }

  /// 把「我是谁 / 我是不是房主」告诉点歌队列。
  ///
  /// 服务端权限口径是 peerId（房主另有 userId）：这里同步一份，界面据此隐藏
  /// 没有权限的按钮，免得用户点了才收到「只有房主可以…」。
  void _syncMusicViewer() {
    final room = _room;
    music.setViewer(
      peerId: _selfPeerId,
      isOwner: room != null && room.ownerId == currentUser.id,
    );
  }

  Future<void> _rejoinAfterReconnect() async {
    final roomId = _joinedRoomId;
    if (roomId == null) {
      return;
    }
    AppLog.info('信令重连成功，重新进房 $roomId');
    await _teardownMedia();
    _linkStates.clear();
    _lastBytes.clear();
    signaling.send(joinRoomMessage(roomId: roomId, password: _joinedPassword));
  }

  Future<void> _onMemberLeft(MemberLeftMessage message) async {
    _members.remove(message.peerId);
    await media.closePeer(message.peerId);
    _linkStates.remove(message.peerId);
    _lastBytes.remove(message.peerId);
    _locallyMuted.remove(message.peerId);
    peerVolumes.releasePeer(message.peerId);
    peerLevels.remove(message.peerId);
    notifyListeners();
  }

  Future<void> _onOffer(RelayOfferMessage message) async {
    // 被叫方：不创建数据通道（由 offer 方创建）
    await media.ensurePeer(message.src, polite: _isPolite(message.src));
    await _applyPeerAudio(message.src);
    await media.handleRemoteOffer(message.src, message.sdp);
  }

  Future<void> _onRoomClosed(RoomClosedMessage message) async {
    _lastError = '房间已被解散';
    await _teardownMedia();
    _resetRoomState();
    _setPhase(RoomPhase.closed);
  }

  Future<void> _onKicked(KickedMessage message) async {
    _lastError = switch (message.code) {
      SignalingErrorCode.duplicateSession => '该账号已在其他设备登录',
      SignalingErrorCode.kickedByAdmin => switch (message.reason) {
        'account_disabled' => '账号已被管理员禁用',
        'account_deleted' => '账号已被管理员删除',
        'owner_deleted' => '房主已注销，房间已解散',
        _ => '你已被管理员移出房间',
      },
      _ => message.reason.isEmpty ? '已被移出房间' : message.reason,
    };
    await _teardownMedia();
    _resetRoomState();
    _setPhase(RoomPhase.failed);
  }

  void _onServerError(ServerErrorMessage message) {
    // 点歌被拒（队列满 / 冷却 / 权限 / 不在队列…）：只弹提示，不写进房间错误横幅
    if (message.ref != null && message.ref!.startsWith('music_')) {
      onMusicError?.call(message.message);
      return;
    }
    _lastError = message.message;
    final waiter = _joinWaiter;
    if (waiter != null && !waiter.isCompleted) {
      _joinWaiter = null;
      waiter.completeError(RoomException(message.message, code: message.code));
      return;
    }
    AppLog.warn('信令错误 ${message.code}: ${message.message}');
    notifyListeners();
  }

  // ------------------------------------------------------------------ P2P 组网
  Future<void> _startLocalMedia() async {
    try {
      await media.startLocalAudio();
      if (_microphoneMuted) {
        await media.setMicrophoneMuted(true);
      }
    } on MediaException catch (error) {
      AppLog.warn('进房时本地麦克风不可用：${error.message}');
      _lastError = error.message;
      notifyListeners();
    }
  }

  Future<void> _dialExistingMembers() async {
    final others = _members.values
        .where((member) => member.peerId != _selfPeerId)
        .toList();
    for (final member in others) {
      try {
        AppLog.info('与成员建连 peer=${member.peerId}');
        await media.ensurePeer(
          member.peerId,
          polite: _isPolite(member.peerId),
          createDataChannel: true,
        );
        await _applyPeerAudio(member.peerId);
        await media.negotiate(member.peerId);
      } on Object catch (error) {
        AppLog.warn('与成员建连失败 peer=${member.peerId}', error: error);
      }
    }
  }

  /// polite 角色：peerId 字典序较大的一方为 polite，两侧结果必然互补。
  bool _isPolite(String peerId) {
    final self = _selfPeerId;
    if (self == null) {
      return true;
    }
    return self.compareTo(peerId) > 0;
  }

  Future<void> _onLocalDescription(
    String peerId,
    String type,
    String sdp,
  ) async {
    final payload = type == 'offer'
        ? offerMessage(dst: peerId, sdp: sdp)
        : answerMessage(dst: peerId, sdp: sdp);
    signaling.send(payload);
  }

  void _onLocalCandidate(String peerId, IceCandidatePayload? candidate) {
    signaling.send(candidateMessage(dst: peerId, candidate: candidate));
  }

  void _onLinkStateChanged(String peerId, PeerLinkState state) {
    _linkStates[peerId] = state;
    notifyListeners();
    if (state == PeerLinkState.failed) {
      AppLog.warn('与成员 $peerId 无法直连（对称 NAT 或 UDP 受限）');
    }
  }

  // ------------------------------------------------------------------ P2P 数据
  void _onDataChannel(String peerId, RTCDataChannel channel) {
    channel.onMessage = (RTCDataChannelMessage message) {
      if (message.isBinary) {
        return;
      }
      final text = message.text;
      Object? decoded;
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        AppLog.warn('数据通道收到无法解析的内容 peer=$peerId');
        return;
      }
      if (decoded is Map<String, dynamic>) {
        _handlePeerData(peerId, decoded);
      }
    };
  }

  void _handlePeerData(String peerId, Map<String, dynamic> payload) {
    switch (payload['t']) {
      case 'chat':
        final message = ChatMessage.fromWire(payload);
        if (message.text.isEmpty) {
          return;
        }
        _chat.add(message);
        notifyListeners();
      case 'presence':
        // 对方在说话时的实时电平（P2P 直发，服务器不参与）
        peerLevels.applyRemote(
          peerId,
          level: ((payload['level'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0),
          speaking: payload['speaking'] as bool? ?? false,
        );
    }
  }

  /// 发送一条聊天消息（P2P 广播，不经服务器）。
  ChatMessage sendChat(String text) {
    final trimmed = text.trim();
    final self = _selfPeerId;
    final message = ChatMessage(
      id: _uuid.v4(),
      peerId: self ?? '',
      displayName: currentUser.displayName,
      text: trimmed,
      sentAt: DateTime.now(),
      isMine: true,
    );
    if (trimmed.isEmpty) {
      return message;
    }
    _chat.add(message);
    final sent = media.broadcastData(jsonEncode(message.toWire()));
    notifyListeners();
    if (sent == 0) {
      AppLog.info('聊天消息暂无已连接的成员，仅本地显示');
    }
    return message;
  }

  // ------------------------------------------------------------------ 本地控制
  Future<void> setMicrophoneMuted(bool muted) async {
    _microphoneMuted = muted;
    if (muted) {
      // 先落下标志：静音会让电平计立刻判定「不说话」，先置好可让下面那条
      // 合并消息成为唯一一次上报，不会多发一条 speaking=false。
      _selfSpeaking = false;
    }
    await media.setMicrophoneMuted(muted);
    _patchSelf(muted: muted, speaking: false);
    signaling.send(memberStateMessage(muted: muted, speaking: false));
    notifyListeners();
  }

  Future<void> toggleMicrophone() => setMicrophoneMuted(!_microphoneMuted);

  /// 某个成员的声音是否被我本地屏蔽了。
  bool isLocallyMuted(String peerId) => _locallyMuted.contains(peerId);

  /// 自己的资料变了（改昵称）：更新聊天署名与本地的成员快照。
  ///
  /// 房间里其他人看到的那个名字由服务端广播补丁更新；这里只处理「自己这台」的
  /// 两处——`currentUser`（发消息时的署名）以及本地成员表（万一广播还没到）。
  void updateCurrentUser(User user) {
    currentUser = user;
    // 改名可能伴随换号登录：房主身份要跟着重算一次
    _syncMusicViewer();
    final self = _selfPeerId;
    if (self == null) {
      return;
    }
    final current = _members[self];
    if (current == null ||
        (current.displayName == user.displayName &&
            current.avatar == user.avatar)) {
      return;
    }
    _members[self] = current.withProfile(
      displayName: user.displayName,
      avatar: user.avatar,
    );
    notifyListeners();
  }

  /// 点击成员列表里的麦克风：自己就开/关自己的麦，别人就本地静音 / 恢复收听。
  ///
  /// 静音别人只影响本机播放（不再听到他说话），不通知对方、也不改服务端状态。
  Future<void> togglePeerAudio(String peerId) async {
    if (peerId == _selfPeerId) {
      await toggleMicrophone();
      return;
    }
    final muted = !_locallyMuted.contains(peerId);
    if (muted) {
      _locallyMuted.add(peerId);
    } else {
      _locallyMuted.remove(peerId);
    }
    await peerVolumes.setMuted(peerId, muted);
    notifyListeners();
  }

  /// 设置某成员的音量（0~200 的百分比）。只影响本机听感，并按 userId 记住。
  Future<void> setPeerVolume(String peerId, double percent) async {
    final member = _members[peerId];
    if (member == null || peerId == _selfPeerId) {
      return;
    }
    await peerVolumes.setPercent(
      peerId: peerId,
      userId: member.userId,
      percent: percent,
    );
  }

  Future<void> setSpeakerEnabled(bool enabled) async {
    _speakerEnabled = enabled;
    await media.setSpeakerEnabled(enabled);
    notifyListeners();
  }

  Future<void> toggleSpeaker() => setSpeakerEnabled(!_speakerEnabled);

  /// 开始共享屏幕；[withSystemAudio] 打开会并入系统回环声音。
  ///
  /// [policy] 只是「带宽不够时先牺牲什么」的偏好，每一路发多大由媒体层按观众人数
  /// 现算（见 `uplink_budget.dart`），房间层不参与分配。
  Future<void> startScreenShare({
    String? sourceId,
    bool withSystemAudio = false,
    SharePolicy policy = SharePolicy.fallback,
  }) async {
    await media.startScreenShare(
      sourceId: sourceId,
      withSystemAudio: withSystemAudio,
      policy: policy,
    );
    _patchSelf(sharing: true);
    signaling.send(memberStateMessage(sharing: true));
    notifyListeners();
  }

  Future<void> stopScreenShare() async {
    await media.stopScreenShare();
    _patchSelf(sharing: false);
    signaling.send(memberStateMessage(sharing: false));
    notifyListeners();
  }

  /// 网络切换后的恢复动作：对全部成员做 ICE 重启。
  Future<void> recoverConnections() async {
    for (final peerId in _members.keys.where((id) => id != _selfPeerId)) {
      await media.restartIce(peerId);
    }
  }

  void _patchSelf({bool? muted, bool? sharing, bool? speaking}) {
    final self = _selfPeerId;
    if (self == null) {
      return;
    }
    final current = _members[self];
    if (current == null) {
      return;
    }
    _members[self] = current.copyWith(
      muted: muted,
      sharing: sharing,
      speaking: speaking,
    );
  }

  /// 电平计每次采样都会进这里：更新自己的电平条、广播电平、上报说话状态。
  void _onMicLevelChanged() {
    final mic = media.micLevel.value;
    final self = _selfPeerId;
    if (self != null) {
      peerLevels.updateLocal(
        self,
        level: _announcedLevel(mic),
        speaking: mic.speaking,
      );
    }
    _broadcastPresence(mic);

    if (mic.speaking == _selfSpeaking) {
      return;
    }
    _selfSpeaking = mic.speaking;
    if (self == null) {
      return;
    }
    // 服务端中继的红绿灯：没和我们直连上的人也能看到「我在说话」
    _patchSelf(speaking: mic.speaking);
    signaling.send(memberStateMessage(speaking: mic.speaking));
    notifyListeners();
  }

  /// 对外公布的自己的电平：静音或麦克风不可用时为 0，否则是 dBFS 映射后的展示值。
  double _announcedLevel(MicLevel mic) =>
      mic.healthy && !mic.muted ? mic.display : 0;

  /// 把本地电平经数据通道直接发给房间里其他人（P2P，不经服务器）。
  ///
  /// 只在「说话状态翻转」或电平变化超过一档时才发：正常说话约 100ms 一条，
  /// 每条不到 60 字节，且只走已直连的成员。还没直连上的人看不到电平条，
  /// 但能从服务端中继的 `member_state.speaking` 看到绿灯。
  void _broadcastPresence(MicLevel mic) {
    if (_selfPeerId == null || _phase != RoomPhase.active) {
      return;
    }
    final level = _announcedLevel(mic);
    final last = _lastPresence;
    if (last != null &&
        last.speaking == mic.speaking &&
        (last.level - level).abs() < _presenceLevelStep) {
      return;
    }
    _lastPresence = (level: level, speaking: mic.speaking);
    media.broadcastData(
      jsonEncode(<String, dynamic>{
        't': 'presence',
        'level': double.parse(level.toStringAsFixed(3)),
        'speaking': mic.speaking,
      }),
    );
  }

  /// 新连接建立后补上「本地静音 + 成员音量」——点击/调音量都可能早于连接建立。
  Future<void> _applyPeerAudio(String peerId) async {
    final member = _members[peerId];
    if (member != null) {
      await peerVolumes.bindPeer(peerId: peerId, userId: member.userId);
    }
    if (_locallyMuted.contains(peerId)) {
      await peerVolumes.setMuted(peerId, true);
    }
  }

  // ------------------------------------------------------------------ 统计
  void _startStatsTimer() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(
      statsInterval,
      (_) => unawaited(refreshStats()),
    );
  }

  /// 采样各成员的连接质量（码率 / RTT / 直连方式）。
  Future<void> refreshStats() async {
    if (_phase != RoomPhase.active) {
      return;
    }
    final now = DateTime.now();
    final latencies = <String, double>{};
    var outgoingKbps = 0.0;
    var incomingKbps = 0.0;

    for (final peerId in _members.keys.where((id) => id != _selfPeerId)) {
      final snapshot = await media.statsFor(peerId);
      if (snapshot == null) {
        continue;
      }
      if (snapshot.roundTripTimeMs != null) {
        latencies[peerId] = snapshot.roundTripTimeMs!;
      }
      final previous = _lastBytes[peerId];
      if (previous != null) {
        final seconds = now.difference(previous.at).inMilliseconds / 1000;
        if (seconds > 0.4) {
          if (snapshot.bytesSent != null) {
            final delta = snapshot.bytesSent! - previous.sent;
            if (delta >= 0) {
              outgoingKbps += delta * 8 / 1000 / seconds;
            }
          }
          if (snapshot.bytesReceived != null) {
            final delta = snapshot.bytesReceived! - previous.received;
            if (delta >= 0) {
              incomingKbps += delta * 8 / 1000 / seconds;
            }
          }
        }
      }
      _lastBytes[peerId] = (
        sent: snapshot.bytesSent ?? 0,
        received: snapshot.bytesReceived ?? 0,
        at: now,
      );
    }

    _stats = RoomStats(
      outgoingKbps: outgoingKbps,
      incomingKbps: incomingKbps,
      peers: latencies,
    );
    notifyListeners();
  }

  /// 某个成员到本机的直连方式描述（用于「点对点、不经过服务器」的可验证展示）。
  Future<String> describePath(String peerId) async {
    final snapshot = await media.statsFor(peerId);
    return snapshot?.pathDescription ?? '尚未建立连接';
  }

  // ------------------------------------------------------------------ 内部
  void _setPhase(RoomPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  void _resetRoomState() {
    _statsTimer?.cancel();
    _statsTimer = null;
    _room = null;
    _musicSnapshot = null;
    _selfPeerId = null;
    _members.clear();
    _linkStates.clear();
    _lastBytes.clear();
    _locallyMuted.clear();
    peerVolumes.clear();
    _lastPresence = null;
    peerLevels.clear();
    music.reset();
    _stats = const RoomStats();
    notifyListeners();
  }

  Future<void> _teardownMedia() async {
    if (_tearingDown) {
      return;
    }
    _tearingDown = true;
    try {
      _statsTimer?.cancel();
      _statsTimer = null;
      await media.closeAllPeers();
      await media.stopScreenShare();
      await media.stopLocalAudio();
      _linkStates.clear();
      _lastBytes.clear();
    } finally {
      _tearingDown = false;
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _statsTimer?.cancel();
    unawaited(_messageSubscription?.cancel());
    _messageSubscription = null;
    media.micLevel.removeListener(_onMicLevelChanged);
    peerLevels.dispose();
    if (_ownsMusic) {
      music.dispose();
    }
    else {
      // 只摘掉自己的绑定：队列是 AppState 的，别让它继续往一个已销毁的会话里发消息
      music.unbind(this);
    }
    // 注意：**不要**在这里 dispose 媒体引擎——它由 AppState 持有并跨房间复用，
    // 会话只摘掉自己的回调与监听（连接与采集已由 `_teardownMedia` 释放）。
    media.callbacks = null;
    peerVolumes.dispose();
    super.dispose();
  }
}
