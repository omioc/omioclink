import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:omioclink_client/data/models.dart';
import 'package:omioclink_client/data/server_endpoint.dart';
import 'package:omioclink_client/media/media_engine.dart';
import 'package:omioclink_client/media/media_models.dart';
import 'package:omioclink_client/media/media_port.dart';
import 'package:omioclink_client/media/share_policy.dart';
import 'package:omioclink_client/room/room_models.dart';
import 'package:omioclink_client/room/room_session.dart';
import 'package:omioclink_client/room/room_music_sync.dart';
import 'package:omioclink_client/signaling/protocol.dart';
import 'package:omioclink_client/signaling/signaling_client.dart';

import 'signaling_client_test.dart' show FakeTransport, helloPayload, pump;

/// 内存媒体端口：记录编排层下达的每一个动作，不触碰 flutter_webrtc。
class FakeMediaPort implements MediaPort {
  @override
  MediaEngineCallbacks? callbacks;

  final List<String> iceServerUpdates = <String>[];
  final List<({String peerId, bool polite, bool createDataChannel})> ensured =
      <({String peerId, bool polite, bool createDataChannel})>[];
  final List<String> negotiated = <String>[];
  final List<({String peerId, String sdp})> remoteOffers =
      <({String peerId, String sdp})>[];
  final List<({String peerId, String sdp})> remoteAnswers =
      <({String peerId, String sdp})>[];
  final List<({String peerId, IceCandidatePayload? candidate})>
  remoteCandidates = <({String peerId, IceCandidatePayload? candidate})>[];
  final List<String> restartedIce = <String>[];
  final List<String> closedPeers = <String>[];
  final List<String> broadcast = <String>[];
  final Map<String, PeerStatsSnapshot?> stats = <String, PeerStatsSnapshot?>{};

  bool audioStarted = false;
  bool audioStopped = false;
  bool screenStarted = false;
  bool screenStopped = false;
  bool screenSharing = false;

  /// 最后一次共享请求带的参数（编码策略 / 是否要系统声音）。
  SharePolicy? screenPolicy;
  bool? screenWithSystemAudio;
  bool muted = false;
  bool speakerEnabled = true;
  bool disposed = false;
  bool closeAllCalled = false;
  bool failLocalAudio = false;

  /// 假电平计：测试直接往里灌值，即可驱动「我在说话」的上报。
  final ValueNotifier<MicLevel> micLevelNotifier = ValueNotifier<MicLevel>(
    const MicLevel(),
  );

  @override
  ValueListenable<MicLevel> get micLevel => micLevelNotifier;

  @override
  void updateIceServers(List<String> servers) =>
      iceServerUpdates.addAll(servers);

  @override
  Future<void> startLocalAudio({String? deviceId}) async {
    if (failLocalAudio) {
      throw const MediaException('无法使用麦克风', code: 'microphone_denied');
    }
    audioStarted = true;
  }

  @override
  Future<void> stopLocalAudio() async => audioStopped = true;

  @override
  Future<void> setMicrophoneMuted(bool value) async {
    muted = value;
    // 真实引擎会立刻把电平计置为「静音且不说话」，这里保持一致，
    // 才能验证编排层不会因此多发一条 speaking=false
    micLevelNotifier.value = micLevelNotifier.value.copyWith(
      muted: value,
      speaking: false,
      level: 0,
    );
  }

  @override
  Future<void> setSpeakerEnabled(bool value) async => speakerEnabled = value;

  @override
  Future<void> switchAudioInput(String deviceId) async {}

  @override
  Future<void> switchAudioOutput(String deviceId) async {}

  @override
  Future<void> startScreenShare({
    String? sourceId,
    bool withSystemAudio = false,
    SharePolicy policy = SharePolicy.fallback,
  }) async {
    screenStarted = true;
    screenSharing = true;
    screenPolicy = policy;
    screenWithSystemAudio = withSystemAudio;
  }

  @override
  Future<void> stopScreenShare() async {
    screenStopped = true;
    screenSharing = false;
  }

  @override
  bool get isScreenSharing => screenSharing;

  @override
  Future<void> ensurePeer(
    String peerId, {
    required bool polite,
    bool createDataChannel = false,
  }) async {
    ensured.add((
      peerId: peerId,
      polite: polite,
      createDataChannel: createDataChannel,
    ));
  }

  @override
  Future<void> negotiate(String peerId, {bool iceRestart = false}) async =>
      negotiated.add(peerId);

  @override
  Future<void> handleRemoteOffer(String peerId, String sdp) async =>
      remoteOffers.add((peerId: peerId, sdp: sdp));

  @override
  Future<void> handleRemoteAnswer(String peerId, String sdp) async =>
      remoteAnswers.add((peerId: peerId, sdp: sdp));

  @override
  Future<void> handleRemoteCandidate(
    String peerId,
    IceCandidatePayload? candidate,
  ) async => remoteCandidates.add((peerId: peerId, candidate: candidate));

  @override
  Future<void> restartIce(String peerId) async => restartedIce.add(peerId);

  @override
  Future<void> closePeer(String peerId) async => closedPeers.add(peerId);

  @override
  Future<void> closeAllPeers() async {
    closeAllCalled = true;
    closedPeers.clear();
  }

  final List<({String peerId, bool muted})> peerAudioMutes =
      <({String peerId, bool muted})>[];

  @override
  Future<void> setPeerAudioMuted(String peerId, bool muted) async =>
      peerAudioMutes.add((peerId: peerId, muted: muted));

  /// 记录「按成员调音量」的调用（peerId → 增益），单测据此断言互不覆盖与钳制。
  final List<({String peerId, double gain})> peerAudioVolumes =
      <({String peerId, double gain})>[];

  @override
  Future<void> setPeerAudioVolume(String peerId, double gain) async =>
      peerAudioVolumes.add((peerId: peerId, gain: gain));

  @override
  int broadcastData(String payload) {
    broadcast.add(payload);
    return 1;
  }

  @override
  Future<PeerStatsSnapshot?> statsFor(String peerId) async => stats[peerId];

  @override
  Future<void> dispose() async => disposed = true;

  List<Map<String, dynamic>> get broadcastJson => broadcast
      .map((item) => jsonDecode(item) as Map<String, dynamic>)
      .toList();
}

const _endpoint = ServerEndpoint(host: '127.0.0.1', port: 21077);
const _me = User(id: 7, username: 'alice', displayName: '小明');

Map<String, dynamic> roomStatePayload({
  String selfPeerId = 'ac4b0391',
  List<Map<String, dynamic>>? members,
  Map<String, dynamic>? music,
}) => <String, dynamic>{
  'type': 'room_state',
  'room': <String, dynamic>{
    'roomId': 'BX4K9K',
    'name': '游戏开黑',
    'ownerId': 7,
    'capacity': 5,
    'memberCount': (members ?? <Map<String, dynamic>>[]).length,
    'hasPassword': false,
    'isPublic': true,
  },
  'selfPeerId': selfPeerId,
  'members':
      members ??
      <Map<String, dynamic>>[
        <String, dynamic>{
          'peerId': selfPeerId,
          'userId': 7,
          'username': 'alice',
          'displayName': '小明',
        },
      ],
  'music': ?music,
};

/// 服务端的点歌快照（`room_state.music` 与 `music_state` 同一个结构）。
Map<String, dynamic> musicStatePayload({int revision = 3}) => <String, dynamic>{
  'revision': revision,
  'serverTimeMs': 1000,
  'current': <String, dynamic>{
    'entryId': 'e1',
    'source': 'test',
    'songId': '1',
    'musicInfo': <String, dynamic>{'id': '1'},
    'title': '在播的歌',
    'artist': '歌手',
    'durationMs': 200000,
    'requestedBy': <String, dynamic>{
      'peerId': 'ac4b0391',
      'displayName': '小明',
    },
    'anchorServerMs': 1000,
    'anchorPositionMs': 0,
  },
  'queue': <Map<String, dynamic>>[
    <String, dynamic>{
      'entryId': 'e2',
      'source': 'test',
      'songId': '2',
      'musicInfo': <String, dynamic>{'id': '2'},
      'title': '下一首',
      'artist': '歌手',
      'durationMs': 200000,
      'requestedBy': <String, dynamic>{
        'peerId': 'f9caeec5',
        'displayName': '小红',
      },
    },
  ],
};

Map<String, dynamic> memberPayload({
  String peerId = 'f9caeec5',
  int userId = 8,
  String displayName = '小红',
  bool muted = false,
  bool sharing = false,
}) => <String, dynamic>{
  'peerId': peerId,
  'userId': userId,
  'username': 'user$userId',
  'displayName': displayName,
  'muted': muted,
  'sharing': sharing,
};

/// 假的播放器：记录「被要求起播哪首」，真实现是 `MusicPlayer.applyRoomState`。
class _AudioRecorder {
  final List<({String? entryId, int revision})> applied =
      <({String? entryId, int revision})>[];

  Future<void> apply(MusicCurrent? current, {required int revision}) async {
    applied.add((entryId: current?.entryId, revision: revision));
  }
}

void main() {
  late FakeMediaPort media;
  late List<FakeTransport> transports;
  late SignalingClient signaling;
  late RoomSession session;

  setUp(() {
    media = FakeMediaPort();
    transports = <FakeTransport>[];
    signaling = SignalingClient(
      endpoint: _endpoint,
      accessToken: 'token',
      random: Random(11),
      transportFactory: (uri) {
        final transport = FakeTransport(uri);
        transports.add(transport);
        return transport;
      },
    );
    session = RoomSession(
      signaling: signaling,
      media: media,
      currentUser: _me,
      statsInterval: const Duration(hours: 1), // 测试里不跑统计定时器
    );
  });

  tearDown(() async {
    session.dispose();
    await signaling.dispose();
  });

  /// 走完「建连 → 入房」：返回时会话已 active。
  Future<void> joinRoom({List<Map<String, dynamic>>? extraMembers}) async {
    final joinFuture = session.join(roomId: 'BX4K9K');
    await pump();
    transports.first.emit(helloPayload());
    await pump();
    transports.first.emit(
      roomStatePayload(
        members: <Map<String, dynamic>>[
          memberPayload(peerId: 'ac4b0391', userId: 7, displayName: '小明'),
          ...?extraMembers,
        ],
      ),
    );
    await joinFuture;
    await pump();
  }

  test('进房：先握手再入房，随后采集麦克风并向既有成员发起 offer', () async {
    await joinRoom(extraMembers: <Map<String, dynamic>>[memberPayload()]);

    expect(session.phase, RoomPhase.active);
    expect(session.selfPeerId, 'ac4b0391');
    expect(session.room!.roomId, 'BX4K9K');
    expect(session.members, hasLength(2));
    expect(session.members.first.local, isTrue, reason: '自己排最前');

    expect(media.audioStarted, isTrue);
    expect(media.iceServerUpdates, <String>['stun:stun.example.com:3478']);

    // 新成员向既有成员发 offer，且由自己创建数据通道
    expect(media.ensured, hasLength(1));
    expect(media.ensured.single.peerId, 'f9caeec5');
    expect(media.ensured.single.createDataChannel, isTrue);
    expect(media.negotiated, <String>['f9caeec5']);

    final joined = transports.first.sentJson.firstWhere(
      (item) => item['type'] == 'join_room',
    );
    expect(joined['roomId'], 'BX4K9K');
  });

  test('离开房间后不再残留点歌快照：否则会把刚停掉的歌重新放起来', () async {
    // 照 AppState 的接法：会话每次通知 → 闸门 → 播放器
    final audio = _AudioRecorder();
    final sync = RoomMusicSync(
      queue: session.music,
      applyToPlayer: audio.apply,
    );
    session.addListener(
      () => sync.apply(
        session,
        phase: session.phase,
        snapshot: session.musicSnapshot,
      ),
    );

    final joinFuture = session.join(roomId: 'BX4K9K');
    await pump();
    transports.first.emit(helloPayload());
    await pump();
    transports.first.emit(roomStatePayload(music: musicStatePayload()));
    await joinFuture;
    await pump();

    expect(session.music.serverDriven, isTrue, reason: '进房就拿到了权威队列');
    expect(session.music.nowPlaying?.name, '在播的歌');
    expect(audio.applied, hasLength(1));

    audio.applied.clear();
    await session.leave();

    expect(
      audio.applied,
      isEmpty,
      reason: '离开房间后播放器不该再被快照驱动，否则刚停的歌会重新起播',
    );
    expect(session.musicSnapshot, isNull);
    expect(session.music.serverDriven, isFalse);
    expect(session.music.isEmpty, isTrue);
  });

  test('重新进同一个房间：同一 revision 的点歌快照照常收下并起播', () async {
    final audio = _AudioRecorder();
    final sync = RoomMusicSync(
      queue: session.music,
      applyToPlayer: audio.apply,
    );
    session.addListener(
      () => sync.apply(
        session,
        phase: session.phase,
        snapshot: session.musicSnapshot,
      ),
    );

    var joinFuture = session.join(roomId: 'BX4K9K');
    await pump();
    transports.first.emit(helloPayload());
    await pump();
    transports.first.emit(
      roomStatePayload(music: musicStatePayload(revision: 3)),
    );
    await joinFuture;
    await pump();
    expect(audio.applied, hasLength(1));

    // 离开房间：AppState 的顺序是「停播 → 清队列 → 忘掉旧 revision → leave」
    audio.applied.clear();
    session.music.reset();
    sync.forget();
    await session.leave();
    await pump();

    // 再进一次：房间状态没变，服务端还是 revision 3
    joinFuture = session.join(roomId: 'BX4K9K');
    await pump();
    transports.first.emit(
      roomStatePayload(music: musicStatePayload(revision: 3)),
    );
    await joinFuture;
    await pump();

    expect(
      audio.applied,
      hasLength(1),
      reason: '换了会话拿到同一个 revision 也必须重放，否则队列停在本地模式、点歌发不出去',
    );
    expect(session.music.serverDriven, isTrue);
    expect(session.music.nowPlaying?.name, '在播的歌');
    expect(session.music.queue.single.name, '下一首');
  });

  test('被叫方收到 offer：建连（不建数据通道）并回 answer', () async {
    await joinRoom();
    media.callbacks!.onLocalDescription('f9caeec5', 'answer', 'v=0-answer');
    await pump();

    expect(transports.first.sentJson.last['type'], 'answer');
    expect(transports.first.sentJson.last['dst'], 'f9caeec5');
  });

  test('polite 角色按 peerId 字典序确定性指派，两侧互补', () async {
    // self = 'ac4b0391' < 'f9caeec5' → 本端 impolite
    await joinRoom(
      extraMembers: <Map<String, dynamic>>[memberPayload(peerId: 'f9caeec5')],
    );
    expect(media.ensured.single.polite, isFalse);

    // 反向：self = 'f9caeec5' > '0a0a0a0a' → 本端 polite（与上例恰好互补）
    media.ensured.clear();
    transports.first.emit(
      roomStatePayload(
        selfPeerId: 'f9caeec5',
        members: <Map<String, dynamic>>[memberPayload(peerId: '0a0a0a0a')],
      ),
    );
    await pump();
    expect(media.ensured.single.polite, isTrue);
    expect(media.ensured.single.createDataChannel, isTrue);
  });

  test('转发 offer / answer / candidate 全部交给媒体层', () async {
    await joinRoom(extraMembers: <Map<String, dynamic>>[memberPayload()]);

    transports.first.emit(<String, dynamic>{
      'type': 'offer',
      'src': 'f9caeec5',
      'sdp': 'v=0-offer',
    });
    transports.first.emit(<String, dynamic>{
      'type': 'answer',
      'src': 'f9caeec5',
      'sdp': 'v=0-answer',
    });
    transports.first.emit(<String, dynamic>{
      'type': 'candidate',
      'src': 'f9caeec5',
      'candidate': <String, dynamic>{'candidate': 'candidate:1', 'sdpMid': '0'},
      'endOfCandidates': false,
    });
    transports.first.emit(<String, dynamic>{
      'type': 'candidate',
      'src': 'f9caeec5',
      'candidate': null,
      'endOfCandidates': true,
    });
    await pump();

    expect(media.remoteOffers.single.sdp, 'v=0-offer');
    expect(media.remoteAnswers.single.sdp, 'v=0-answer');
    expect(media.remoteCandidates, hasLength(2));
    expect(media.remoteCandidates.first.candidate!.sdpMid, '0');
    expect(media.remoteCandidates.last.candidate, isNull);

    // 被叫方会再 ensurePeer 一次（引擎内部幂等复用连接），但绝不创建数据通道
    expect(media.ensured, hasLength(2));
    expect(media.ensured.last.peerId, 'f9caeec5');
    expect(
      media.ensured.last.createDataChannel,
      isFalse,
      reason: '数据通道由 offer 方创建',
    );
  });

  test('本地 SDP 与候选通过信令发给对应成员', () async {
    await joinRoom();
    media.callbacks!.onLocalDescription('f9caeec5', 'offer', 'v=0-offer');
    media.callbacks!.onLocalCandidate(
      'f9caeec5',
      const IceCandidatePayload(
        candidate: 'candidate:1',
        sdpMid: '0',
        sdpMLineIndex: 0,
      ),
    );
    media.callbacks!.onLocalCandidate('f9caeec5', null);
    await pump();

    final messages = transports.first.sentJson;
    final offer = messages.firstWhere((item) => item['type'] == 'offer');
    expect(offer['dst'], 'f9caeec5');
    expect(offer['sdp'], 'v=0-offer');

    final candidates = messages
        .where((item) => item['type'] == 'candidate')
        .toList();
    expect(candidates, hasLength(2));
    expect(
      (candidates.first['candidate']! as Map<String, dynamic>)['sdpMid'],
      '0',
    );
    expect(candidates.last['candidate'], isNull);
  });

  test('成员状态补丁与成员离开', () async {
    await joinRoom(extraMembers: <Map<String, dynamic>>[memberPayload()]);

    transports.first.emit(<String, dynamic>{
      'type': 'member_state_changed',
      'peerId': 'f9caeec5',
      'patch': <String, dynamic>{'muted': true, 'sharing': true},
    });
    await pump();
    final bob = session.members.firstWhere(
      (view) => view.info.peerId == 'f9caeec5',
    );
    expect(bob.info.muted, isTrue);
    expect(bob.info.sharing, isTrue);
    expect(session.activeSharer!.peerId, 'f9caeec5');

    transports.first.emit(<String, dynamic>{
      'type': 'member_left',
      'peerId': 'f9caeec5',
      'reason': 'disconnected',
    });
    await pump();
    expect(session.members, hasLength(1));
    expect(media.closedPeers, contains('f9caeec5'));
    expect(session.activeSharer, isNull);
  });

  test('新成员加入只更新成员表，不主动发起协商（由对方发起）', () async {
    await joinRoom();
    media.ensured.clear();
    media.negotiated.clear();

    transports.first.emit(<String, dynamic>{
      'type': 'member_joined',
      'member': memberPayload(),
    });
    await pump();

    expect(session.members, hasLength(2));
    expect(media.ensured, isEmpty);
    expect(media.negotiated, isEmpty);
  });

  test('麦克风与屏幕共享同步为服务器权威状态', () async {
    await joinRoom(extraMembers: <Map<String, dynamic>>[memberPayload()]);

    await session.toggleMicrophone();
    expect(session.microphoneMuted, isTrue);
    expect(media.muted, isTrue);
    expect(session.selfMember!.muted, isTrue);

    await session.startScreenShare(
      sourceId: 'screen:1',
      withSystemAudio: true,
      policy: SharePolicy.resolutionFirst,
    );
    expect(media.screenStarted, isTrue);
    // 界面选的策略要原样传到媒体层
    expect(media.screenPolicy, SharePolicy.resolutionFirst);
    expect(media.screenWithSystemAudio, isTrue);
    expect(session.selfMember!.sharing, isTrue);

    await session.stopScreenShare();
    expect(media.screenStopped, isTrue);
    expect(session.selfMember!.sharing, isFalse);

    final states = transports.first.sentJson
        .where((item) => item['type'] == 'member_state')
        .toList();
    expect(states, hasLength(3));
    expect(states[0]['muted'], isTrue);
    expect(states[1]['sharing'], isTrue);
    expect(states[2]['sharing'], isFalse);
  });

  test('重进房间时纠正服务端残留的共享状态：本地没在采集就不该显示共享', () async {
    // 服务端的 peer 对象在离开房间后是被复用的，sharing 标记可能还留在进房快照里。
    // 不纠正的话界面会显示一块黑屏，共享按钮第一次点也只是「停止」。
    final joinFuture = session.join(roomId: 'BX4K9K');
    await pump();
    transports.first.emit(helloPayload());
    await pump();
    transports.first.emit(
      roomStatePayload(
        members: <Map<String, dynamic>>[
          memberPayload(peerId: 'ac4b0391', userId: 7, sharing: true),
        ],
      ),
    );
    await joinFuture;
    await pump();

    expect(media.screenSharing, isFalse);
    expect(session.selfMember!.sharing, isFalse);
    // 还要回告服务器，否则别人那边还挂着「他在共享」
    final patch = transports.first.sentJson.lastWhere(
      (item) => item['type'] == 'member_state',
    );
    expect(patch['sharing'], isFalse);
  });

  test('本地确实在共享时不乱改状态：服务端说没共享也要纠回来', () async {
    await joinRoom(extraMembers: <Map<String, dynamic>>[memberPayload()]);
    await session.startScreenShare(sourceId: 'screen:1');
    expect(media.screenSharing, isTrue);

    // 模拟「重新订阅到一份把我说成没共享的快照」
    transports.first.emit(
      roomStatePayload(
        members: <Map<String, dynamic>>[
          memberPayload(peerId: 'ac4b0391', userId: 7, sharing: false),
        ],
      ),
    );
    await pump();

    expect(session.selfMember!.sharing, isTrue);
  });

  test('说话状态翻转时上报 speaking，且不因电平抖动重复上报', () async {
    await joinRoom(extraMembers: <Map<String, dynamic>>[memberPayload()]);
    transports.first.sent.clear(); // 注意 sentJson 是每次新建的副本，清它没用

    // 开始说话
    media.micLevelNotifier.value = const MicLevel(
      level: 0.25,
      speaking: true,
      capturing: true,
    );
    var states = transports.first.sentJson
        .where((item) => item['type'] == 'member_state')
        .toList();
    expect(states, hasLength(1));
    expect(states.single['speaking'], isTrue);
    expect(session.selfMember!.speaking, isTrue);

    // 还在说话：电平每 100ms 都在变，但状态没翻转 → 一条都不该再发
    transports.first.sent.clear();
    media.micLevelNotifier.value = const MicLevel(
      level: 0.4,
      speaking: true,
      capturing: true,
    );
    media.micLevelNotifier.value = const MicLevel(
      level: 0.05,
      speaking: true,
      capturing: true,
    );
    expect(transports.first.sentJson, isEmpty);

    // 说完了
    media.micLevelNotifier.value = const MicLevel(
      level: 0.001,
      speaking: false,
      capturing: true,
    );
    states = transports.first.sentJson
        .where((item) => item['type'] == 'member_state')
        .toList();
    expect(states, hasLength(1));
    expect(states.single['speaking'], isFalse);
    expect(session.selfMember!.speaking, isFalse);
  });

  test('静音立刻结束说话状态，且只发一条合并消息', () async {
    await joinRoom(extraMembers: <Map<String, dynamic>>[memberPayload()]);
    media.micLevelNotifier.value = const MicLevel(
      level: 0.3,
      speaking: true,
      capturing: true,
    );
    transports.first.sent.clear();

    await session.setMicrophoneMuted(true);

    final states = transports.first.sentJson
        .where((item) => item['type'] == 'member_state')
        .toList();
    expect(states, hasLength(1), reason: '静音只该发一条消息');
    expect(states.single['muted'], isTrue);
    expect(states.single['speaking'], isFalse);
    expect(session.selfMember!.speaking, isFalse);
  });

  test('进房时把进房前的说话状态补报一次', () async {
    // 进房前电平计已判定在说话：本地缓存的「已上报状态」还是 false，需要补报
    media.micLevelNotifier.value = const MicLevel(
      level: 0.3,
      speaking: true,
      capturing: true,
    );
    await joinRoom(extraMembers: <Map<String, dynamic>>[memberPayload()]);

    // 进房后电平计继续采样（真实场景每 100ms 一次）：状态没翻转，
    // 但房间里的我还被记成「没说话」，这一拍必须把它补上
    media.micLevelNotifier.value = const MicLevel(
      level: 0.32,
      speaking: true,
      capturing: true,
    );

    final states = transports.first.sentJson
        .where((item) => item['type'] == 'member_state')
        .toList();
    expect(states, hasLength(1));
    expect(states.single['speaking'], isTrue);
  });

  test('自己的电平经数据通道广播出去，且不刷屏', () async {
    await joinRoom(extraMembers: <Map<String, dynamic>>[memberPayload()]);
    media.broadcast.clear();

    // 大声说话：先出一条 presence
    media.micLevelNotifier.value = const MicLevel(
      level: 0.5,
      speaking: true,
      capturing: true,
    );
    var presence = media.broadcastJson
        .where((item) => item['t'] == 'presence')
        .toList();
    expect(presence, hasLength(1));
    expect(presence.single['speaking'], isTrue);
    expect((presence.single['level'] as num).toDouble(), greaterThan(0.8));

    // 电平几乎没变 → 不再发（不然每 100ms 一条太吵）
    media.broadcast.clear();
    media.micLevelNotifier.value = const MicLevel(
      level: 0.51,
      speaking: true,
      capturing: true,
    );
    expect(media.broadcastJson, isEmpty);

    // 明显变小 → 再发一条
    media.micLevelNotifier.value = const MicLevel(
      level: 0.02,
      speaking: true,
      capturing: true,
    );
    presence = media.broadcastJson
        .where((item) => item['t'] == 'presence')
        .toList();
    expect(presence, hasLength(1));
    expect((presence.single['level'] as num).toDouble(), lessThan(0.5));
  });

  test('静音后把自己的电平清零并广播出去', () async {
    await joinRoom(extraMembers: <Map<String, dynamic>>[memberPayload()]);

    // 先大声说话，让外面看到有电平
    media.micLevelNotifier.value = const MicLevel(
      level: 0.5,
      speaking: true,
      capturing: true,
    );
    expect(
      (media.broadcastJson.last['level'] as num).toDouble(),
      greaterThan(0.8),
    );

    media.broadcast.clear();
    await session.setMicrophoneMuted(true);

    final presence = media.broadcastJson
        .where((item) => item['t'] == 'presence')
        .toList();
    expect(presence, isNotEmpty, reason: '静音是明显的电平变化，必须广播出去');
    expect(presence.last['level'], 0);
    expect(presence.last['speaking'], isFalse);
    expect(
      session.peerLevels.levelOf('ac4b0391').level,
      0,
      reason: '自己的电平条也应清零',
    );
  });

  test('收到成员的电平广播后，成员列表就能画出他的电平条', () async {
    await joinRoom(extraMembers: <Map<String, dynamic>>[memberPayload()]);
    final channel = _FakeDataChannel();
    media.callbacks!.onDataChannel('f9caeec5', channel);

    channel.receive(
      jsonEncode(<String, dynamic>{
        't': 'presence',
        'level': 0.62,
        'speaking': true,
      }),
    );

    final level = session.peerLevels.levelOf('f9caeec5');
    expect(level.measured, isTrue);
    expect(level.level, closeTo(0.62, 0.001));
    expect(level.speaking, isTrue);

    channel.receive(
      jsonEncode(<String, dynamic>{
        't': 'presence',
        'level': 0,
        'speaking': false,
      }),
    );
    expect(session.peerLevels.levelOf('f9caeec5').level, 0);
    expect(session.peerLevels.levelOf('f9caeec5').speaking, isFalse);
  });

  test('还没直连时，绿灯靠服务端中继的成员状态（但没有电平）', () async {
    await joinRoom(extraMembers: <Map<String, dynamic>>[memberPayload()]);

    transports.first.emit(<String, dynamic>{
      'type': 'member_state_changed',
      'peerId': 'f9caeec5',
      'patch': <String, dynamic>{'speaking': true},
    });
    await pump();

    final level = session.peerLevels.levelOf('f9caeec5');
    expect(level.speaking, isTrue);
    expect(level.measured, isFalse, reason: '没直连就没有真实电平可画');
    expect(level.level, 0);
  });

  test('点别人的麦克风＝本地静音，且完全不惊动服务器', () async {
    await joinRoom(extraMembers: <Map<String, dynamic>>[memberPayload()]);
    transports.first.sent.clear();

    await session.togglePeerAudio('f9caeec5');

    expect(session.isLocallyMuted('f9caeec5'), isTrue);
    expect(media.peerAudioMutes, <({String peerId, bool muted})>[
      (peerId: 'f9caeec5', muted: true),
    ]);
    final view = session.members.firstWhere(
      (item) => item.info.peerId == 'f9caeec5',
    );
    expect(view.mutedLocally, isTrue);
    expect(transports.first.sent, isEmpty, reason: '本地静音与服务器无关');

    // 再点一次恢复收听
    await session.togglePeerAudio('f9caeec5');
    expect(session.isLocallyMuted('f9caeec5'), isFalse);
    expect(media.peerAudioMutes.last.muted, isFalse);
  });

  test('点自己的麦克风＝开关自己的麦，不是「屏蔽成员」', () async {
    await joinRoom(extraMembers: <Map<String, dynamic>>[memberPayload()]);

    await session.togglePeerAudio('ac4b0391');

    expect(session.microphoneMuted, isTrue);
    expect(media.muted, isTrue);
    expect(media.peerAudioMutes, isEmpty);

    await session.togglePeerAudio('ac4b0391');
    expect(session.microphoneMuted, isFalse);
  });

  test('重建连接时补上已生效的本地屏蔽（点击可能早于连接）', () async {
    await joinRoom(extraMembers: <Map<String, dynamic>>[memberPayload()]);
    await session.togglePeerAudio('f9caeec5');
    media.peerAudioMutes.clear();

    // 对端重新发起 offer ≈ 重连，会话应把屏蔽状态再落一次
    transports.first.emit(<String, dynamic>{
      'type': 'offer',
      'src': 'f9caeec5',
      'sdp': 'v=0-offer',
    });
    await pump();

    expect(media.peerAudioMutes.last, (peerId: 'f9caeec5', muted: true));
  });

  test('成员离开会清掉他的电平与本地屏蔽', () async {
    await joinRoom(extraMembers: <Map<String, dynamic>>[memberPayload()]);
    await session.togglePeerAudio('f9caeec5');
    final channel = _FakeDataChannel();
    media.callbacks!.onDataChannel('f9caeec5', channel);
    channel.receive(
      jsonEncode(<String, dynamic>{
        't': 'presence',
        'level': 0.5,
        'speaking': true,
      }),
    );
    expect(session.peerLevels.levelOf('f9caeec5').measured, isTrue);

    transports.first.emit(<String, dynamic>{
      'type': 'member_left',
      'peerId': 'f9caeec5',
    });
    await pump();

    expect(session.isLocallyMuted('f9caeec5'), isFalse);
    expect(session.peerLevels.levelOf('f9caeec5').measured, isFalse);
    expect(session.peerLevels.levelOf('f9caeec5').level, 0);
  });

  test('通话中改昵称：本地成员名与聊天署名一起更新', () async {
    await joinRoom(extraMembers: <Map<String, dynamic>>[memberPayload()]);

    session.updateCurrentUser(
      const User(id: 7, username: 'alice', displayName: '小明改名了'),
    );

    expect(session.selfMember!.displayName, '小明改名了');
    expect(session.sendChat('我改名了').displayName, '小明改名了');
  });

  test('服务端广播的昵称补丁会更新成员名', () async {
    await joinRoom(extraMembers: <Map<String, dynamic>>[memberPayload()]);

    transports.first.emit(<String, dynamic>{
      'type': 'member_state_changed',
      'peerId': 'f9caeec5',
      'patch': <String, dynamic>{'displayName': '小红改名了'},
    });
    await pump();

    final bob = session.members.firstWhere(
      (item) => item.info.peerId == 'f9caeec5',
    );
    expect(bob.info.displayName, '小红改名了');
  });

  test('会话释放不销毁共享的媒体引擎，也不重复释放', () async {
    await joinRoom();
    session.dispose();
    expect(
      media.disposed,
      isFalse,
      reason: '媒体引擎由 AppState 持有并跨房间复用，会话只摘自己的监听',
    );
    // tearDown 还会再 dispose 一次，必须是幂等的
    expect(() => session.dispose(), returnsNormally);
  });

  test('聊天走数据通道广播，并记录本地回显', () async {
    await joinRoom(extraMembers: <Map<String, dynamic>>[memberPayload()]);

    session.sendChat('延迟很低，几乎感觉不到');
    expect(session.chat, hasLength(1));
    expect(session.chat.single.isMine, isTrue);
    expect(media.broadcastJson.single['t'], 'chat');
    expect(media.broadcastJson.single['text'], '延迟很低，几乎感觉不到');
    expect(media.broadcastJson.single['from'], 'ac4b0391');

    // 空消息不入库
    session.sendChat('   ');
    expect(session.chat, hasLength(1));
  });

  test('聊天只保留最近若干条，超出的从最旧的丢', () async {
    await joinRoom(extraMembers: <Map<String, dynamic>>[memberPayload()]);

    final total = RoomSession.chatHistoryLimit + 5;
    for (var i = 0; i < total; i += 1) {
      session.sendChat('第 $i 条');
    }

    // 消息是 P2P 的、没有服务端兜底：不设上限的话开一天就是几千条
    expect(session.chat, hasLength(RoomSession.chatHistoryLimit));
    expect(session.chat.first.text, '第 5 条', reason: '最旧的被丢掉了');
    expect(session.chat.last.text, '第 ${total - 1} 条', reason: '最新的还在末尾');
  });

  test('收到对端数据通道消息（聊天）后追加到消息流', () async {
    await joinRoom();
    final channel = _FakeDataChannel();
    media.callbacks!.onDataChannel('f9caeec5', channel);

    channel.receive(
      jsonEncode(<String, dynamic>{
        't': 'chat',
        'id': 'm1',
        'from': 'f9caeec5',
        'name': '小红',
        'at': 1700000000000,
        'text': '画面好清晰啊',
      }),
    );
    await pump();

    expect(session.chat, hasLength(1));
    expect(session.chat.single.text, '画面好清晰啊');
    expect(session.chat.single.displayName, '小红');
    expect(session.chat.single.isMine, isFalse);

    // 非法内容与二进制帧被忽略
    channel.receive('not json');
    await pump();
    expect(session.chat, hasLength(1));
  });

  test('直连状态与统计被记录，可描述连接路径', () async {
    await joinRoom(extraMembers: <Map<String, dynamic>>[memberPayload()]);
    media.stats['f9caeec5'] = const PeerStatsSnapshot(
      bytesSent: 1000,
      bytesReceived: 2000,
      localCandidateType: 'srflx',
      roundTripTimeMs: 42,
    );

    media.callbacks!.onLinkStateChanged('f9caeec5', PeerLinkState.connected);
    await pump();
    expect(session.connectedPeerCount, 1);
    expect(session.linkStateOf('f9caeec5').isLive, isTrue);

    media.callbacks!.onLinkStateChanged('f9caeec5', PeerLinkState.failed);
    await pump();
    expect(session.hasPunchFailure, isTrue);

    await session.refreshStats();
    expect(session.stats.peers['f9caeec5'], 42);

    expect(await session.describePath('f9caeec5'), contains('公网打洞直连'));
  });

  test('服务器错误会作为进房失败抛出', () async {
    final joinFuture = session.join(roomId: 'BX4K9K');
    await pump();
    transports.first.emit(helloPayload());
    await pump();
    transports.first.emit(<String, dynamic>{
      'type': 'error',
      'code': 'bad_password',
      'message': '房间密码错误',
    });

    await expectLater(joinFuture, throwsA(isA<RoomException>()));
    expect(session.lastError, '房间密码错误');
  });

  test('房间解散与账号被顶下线会终止会话', () async {
    await joinRoom();
    transports.first.emit(<String, dynamic>{
      'type': 'room_closed',
      'roomId': 'BX4K9K',
      'reason': 'closed',
    });
    await pump();
    expect(session.phase, RoomPhase.closed);
    expect(session.members, isEmpty);
    expect(media.closeAllCalled, isTrue);
  });

  test('被顶下线标记为不可恢复失败', () async {
    await joinRoom();
    transports.first.emit(<String, dynamic>{
      'type': 'kicked',
      'reason': 'duplicate_session',
      'code': 'duplicate_session',
    });
    await pump();
    expect(session.phase, RoomPhase.failed);
    expect(session.lastError, contains('其他设备登录'));
  });

  test('被管理员移出时给出可读原因并终止会话', () async {
    await joinRoom();
    transports.first.emit(<String, dynamic>{
      'type': 'kicked',
      'reason': 'kicked_by_admin',
      'code': 'kicked_by_admin',
    });
    await pump();
    expect(session.phase, RoomPhase.failed);
    expect(session.lastError, contains('管理员'));
  });

  test('被踢下线的原因按业务语义细化（禁用/删除/房主注销）', () async {
    Future<String?> reasonFor(String reason) async {
      final localMedia = FakeMediaPort();
      final localTransports = <FakeTransport>[];
      final localSignaling = SignalingClient(
        endpoint: _endpoint,
        accessToken: 'token',
        random: Random(3),
        transportFactory: (uri) {
          final transport = FakeTransport(uri);
          localTransports.add(transport);
          return transport;
        },
      );
      final local = RoomSession(
        signaling: localSignaling,
        media: localMedia,
        currentUser: _me,
        statsInterval: const Duration(hours: 1),
      );
      final joinFuture = local.join(roomId: 'BX4K9K');
      await pump();
      localTransports.first.emit(helloPayload());
      await pump();
      localTransports.first.emit(roomStatePayload());
      await joinFuture;
      await pump();

      localTransports.first.emit(<String, dynamic>{
        'type': 'kicked',
        'reason': reason,
        'code': 'kicked_by_admin',
      });
      await pump();
      final message = local.lastError;
      local.dispose();
      await localSignaling.dispose();
      return message;
    }

    expect(await reasonFor('account_disabled'), '账号已被管理员禁用');
    expect(await reasonFor('account_deleted'), '账号已被管理员删除');
    expect(await reasonFor('owner_deleted'), '房主已注销，房间已解散');
    expect(await reasonFor('kicked_by_admin'), '你已被管理员移出房间');
  });

  test('离开房间会停止采集与全部连接，并保留信令连接', () async {
    await joinRoom(extraMembers: <Map<String, dynamic>>[memberPayload()]);
    await session.leave();

    expect(session.phase, RoomPhase.idle);
    expect(session.room, isNull);
    expect(session.selfPeerId, isNull);
    expect(session.members, isEmpty);
    expect(media.closeAllCalled, isTrue);
    expect(media.audioStopped, isTrue);
    expect(signaling.isConnected, isTrue, reason: '离开房间不切断信令');
    expect(
      transports.first.sentJson.map((item) => item['type']),
      contains('leave_room'),
    );
  });

  test('信令重连后自动重新进房', () async {
    await joinRoom(extraMembers: <Map<String, dynamic>>[memberPayload()]);
    final before = transports.first.sentJson
        .where((m) => m['type'] == 'join_room')
        .length;

    transports.first.serverClose(1012, 'restart');
    await pump();
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    expect(transports, hasLength(2));

    transports.last.emit(helloPayload());
    await pump(8);

    final after = transports.last.sentJson
        .where((m) => m['type'] == 'join_room')
        .length;
    expect(after, 1, reason: '重连后应重新入房');
    expect(before, 1);
  });

  test('麦克风被拒绝时不影响入房，仅提示错误', () async {
    media.failLocalAudio = true;
    await joinRoom(extraMembers: <Map<String, dynamic>>[memberPayload()]);

    expect(session.phase, RoomPhase.active);
    expect(session.lastError, contains('麦克风'));
    expect(media.ensured, hasLength(1), reason: '采集失败不影响建连');
  });
}

/// 内存数据通道：只实现编排层用到的那几个成员，其余交给 noSuchMethod。
class _FakeDataChannel implements RTCDataChannel {
  Function(RTCDataChannelMessage data)? _onMessage;

  @override
  Function(RTCDataChannelMessage data)? get onMessage => _onMessage;

  @override
  set onMessage(Function(RTCDataChannelMessage data)? value) =>
      _onMessage = value;

  @override
  RTCDataChannelState? get state => RTCDataChannelState.RTCDataChannelOpen;

  @override
  String? get label => kDataChannelLabel;

  /// 模拟对端发来一条文本；`binary` 为 true 时走二进制分支。
  void receive(String text) => _onMessage?.call(RTCDataChannelMessage(text));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
