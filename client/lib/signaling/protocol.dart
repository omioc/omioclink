/// 信令协议 v1：与服务端 `app/signaling/protocol.py` 一一对应。
///
/// 线上统一 camelCase；服务器只做信令/状态转发，协议里没有聊天消息，
/// 也没有任何媒体/中继语义。
library;

const int kProtocolVersion = 1;

/// WebSocket 关闭码（4000-4999 为应用私有区间，与服务端 `CloseCode` 一致）。
abstract final class SignalingCloseCode {
  static const int normal = 1000;
  static const int unauthorized = 4401;
  static const int roomClosed = 4403;
  static const int heartbeatTimeout = 4408;
  static const int duplicateSession = 4409;
  static const int kickedByAdmin = 4410;
  static const int internalError = 4500;
}

/// 服务端返回的机器可读错误码。
abstract final class SignalingErrorCode {
  static const String invalidMessage = 'invalid_message';
  static const String notAuthenticated = 'not_authenticated';
  static const String notInRoom = 'not_in_room';
  static const String alreadyInRoom = 'already_in_room';
  static const String roomNotFound = 'room_not_found';
  static const String roomFull = 'room_full';
  static const String badPassword = 'bad_password';
  static const String peerUnavailable = 'peer_unavailable';
  static const String duplicateSession = 'duplicate_session';
  static const String kickedByAdmin = 'kicked_by_admin';
  // 点歌（房间共享队列）
  static const String musicQueueFull = 'music_queue_full';
  static const String musicRateLimited = 'music_rate_limited';
  static const String musicForbidden = 'music_forbidden';
  static const String musicNotFound = 'music_not_found';
  static const String musicInvalidEntry = 'music_invalid_entry';
}

class IceCandidatePayload {
  const IceCandidatePayload({
    required this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
    this.usernameFragment,
  });

  factory IceCandidatePayload.fromJson(Map<String, dynamic> json) =>
      IceCandidatePayload(
        candidate: json['candidate'] as String? ?? '',
        sdpMid: json['sdpMid'] as String?,
        sdpMLineIndex: (json['sdpMLineIndex'] as num?)?.toInt(),
        usernameFragment: json['usernameFragment'] as String?,
      );

  final String candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;
  final String? usernameFragment;

  Map<String, dynamic> toJson() => {
    'candidate': candidate,
    if (sdpMid != null) 'sdpMid': sdpMid,
    if (sdpMLineIndex != null) 'sdpMLineIndex': sdpMLineIndex,
    if (usernameFragment != null) 'usernameFragment': usernameFragment,
  };
}

/// 房间内一名成员的权威状态。
class MemberInfo {
  const MemberInfo({
    required this.peerId,
    required this.userId,
    required this.username,
    required this.displayName,
    this.avatar,
    this.muted = false,
    this.sharing = false,
    this.speaking = false,
    this.joinedAt,
  });

  factory MemberInfo.fromJson(Map<String, dynamic> json) => MemberInfo(
    peerId: json['peerId'] as String,
    userId: (json['userId'] as num).toInt(),
    username: json['username'] as String,
    displayName: json['displayName'] as String? ?? json['username'] as String,
    avatar: json['avatar'] as String?,
    muted: json['muted'] as bool? ?? false,
    sharing: json['sharing'] as bool? ?? false,
    speaking: json['speaking'] as bool? ?? false,
    joinedAt: DateTime.tryParse(json['joinedAt'] as String? ?? ''),
  );

  final String peerId;
  final int userId;
  final String username;
  final String displayName;
  final String? avatar;
  final bool muted;
  final bool sharing;
  final bool speaking;
  final DateTime? joinedAt;

  String get initial => displayName.isEmpty ? '?' : displayName.substring(0, 1);

  MemberInfo copyWith({
    bool? muted,
    bool? sharing,
    bool? speaking,
    String? displayName,
  }) => MemberInfo(
    peerId: peerId,
    userId: userId,
    username: username,
    displayName: displayName ?? this.displayName,
    avatar: avatar,
    muted: muted ?? this.muted,
    sharing: sharing ?? this.sharing,
    speaking: speaking ?? this.speaking,
    joinedAt: joinedAt,
  );

  /// 整体覆盖昵称与头像。
  ///
  /// 与 [copyWith] 的区别：这里的 null 就是「没有头像」，而不是「别动」——
  /// 移除头像时服务端下发的正是显式 null。
  MemberInfo withProfile({
    required String displayName,
    required String? avatar,
  }) => MemberInfo(
    peerId: peerId,
    userId: userId,
    username: username,
    displayName: displayName,
    avatar: avatar,
    muted: muted,
    sharing: sharing,
    speaking: speaking,
    joinedAt: joinedAt,
  );

  /// 应用服务端下发的增量状态补丁。
  ///
  /// `displayName` / `avatar` 也会出现在补丁里：有人在通话中改了昵称或头像，
  /// 服务端会即时播给同房间的人。`avatar` 用 containsKey 判断，
  /// 因为「补丁里带 null」表示这个人的头像被移除了，不能当成「没提到」。
  MemberInfo applyPatch(Map<String, dynamic> patch) => MemberInfo(
    peerId: peerId,
    userId: userId,
    username: username,
    displayName: patch['displayName'] as String? ?? displayName,
    avatar: patch.containsKey('avatar') ? patch['avatar'] as String? : avatar,
    muted: patch['muted'] as bool? ?? muted,
    sharing: patch['sharing'] as bool? ?? sharing,
    speaking: patch['speaking'] as bool? ?? speaking,
    joinedAt: joinedAt,
  );
}

class RoomSummary {
  const RoomSummary({
    required this.roomId,
    required this.name,
    required this.ownerId,
    required this.capacity,
    this.memberCount = 0,
    this.hasPassword = false,
    this.isPublic = true,
  });

  factory RoomSummary.fromJson(Map<String, dynamic> json) => RoomSummary(
    roomId: json['roomId'] as String,
    name: json['name'] as String? ?? '',
    ownerId: (json['ownerId'] as num?)?.toInt() ?? 0,
    capacity: (json['capacity'] as num?)?.toInt() ?? 0,
    memberCount: (json['memberCount'] as num?)?.toInt() ?? 0,
    hasPassword: json['hasPassword'] as bool? ?? false,
    isPublic: json['isPublic'] as bool? ?? true,
  );

  final String roomId;
  final String name;
  final int ownerId;
  final int capacity;
  final int memberCount;
  final bool hasPassword;
  final bool isPublic;
}

// --------------------------------------------------------------------------- //
// 房间共享点歌队列（与服务端 protocol.py 的 Music* 一一对应）
// --------------------------------------------------------------------------- //
/// 点歌人：会话级 peerId + 当时的昵称。
class MusicRequester {
  const MusicRequester({required this.peerId, required this.displayName});

  factory MusicRequester.fromJson(Map<String, dynamic> json) => MusicRequester(
    peerId: json['peerId'] as String? ?? '',
    displayName: json['displayName'] as String? ?? '',
  );

  final String peerId;
  final String displayName;
}

/// 队列里的一条点歌（`musicInfo` 是音源原始对象，解析直链时原样回传）。
class MusicEntry {
  const MusicEntry({
    required this.entryId,
    required this.source,
    required this.songId,
    required this.musicInfo,
    this.title = '',
    this.artist = '',
    this.durationMs,
    this.requestedBy = const MusicRequester(peerId: '', displayName: ''),
    this.requestedAtMs = 0,
  });

  factory MusicEntry.fromJson(Map<String, dynamic> json) => MusicEntry(
    entryId: json['entryId'] as String? ?? '',
    source: json['source'] as String? ?? '',
    songId: json['songId'] as String? ?? '',
    musicInfo:
        (json['musicInfo'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{},
    title: json['title'] as String? ?? '',
    artist: json['artist'] as String? ?? '',
    durationMs: (json['durationMs'] as num?)?.toInt(),
    requestedBy: MusicRequester.fromJson(
      (json['requestedBy'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{},
    ),
    requestedAtMs: (json['requestedAtMs'] as num?)?.toInt() ?? 0,
  );

  final String entryId;
  final String source;
  final String songId;
  final Map<String, dynamic> musicInfo;
  final String title;
  final String artist;
  final int? durationMs;
  final MusicRequester requestedBy;
  final int requestedAtMs;

  /// 同一条点歌的身份：`entryId` 由服务器分配，重连后仍然可用。
  String get key => entryId;
}

/// 正在播放的那首：多出播放状态与时间锚点。
class MusicCurrent extends MusicEntry {
  const MusicCurrent({
    required super.entryId,
    required super.source,
    required super.songId,
    required super.musicInfo,
    super.title,
    super.artist,
    super.durationMs,
    super.requestedBy,
    super.requestedAtMs,
    this.playing = true,
    this.anchorServerMs = 0,
    this.anchorPositionMs = 0,
  });

  factory MusicCurrent.fromJson(Map<String, dynamic> json) {
    final entry = MusicEntry.fromJson(json);
    return MusicCurrent(
      entryId: entry.entryId,
      source: entry.source,
      songId: entry.songId,
      musicInfo: entry.musicInfo,
      title: entry.title,
      artist: entry.artist,
      durationMs: entry.durationMs,
      requestedBy: entry.requestedBy,
      requestedAtMs: entry.requestedAtMs,
      playing: json['playing'] as bool? ?? true,
      anchorServerMs: (json['anchorServerMs'] as num?)?.toInt() ?? 0,
      anchorPositionMs: (json['anchorPositionMs'] as num?)?.toInt() ?? 0,
    );
  }

  final bool playing;
  final int anchorServerMs;
  final int anchorPositionMs;
}

/// 队列全量快照（服务器是唯一权威）。
class MusicSnapshot {
  const MusicSnapshot({
    this.revision = 0,
    this.serverTimeMs = 0,
    this.current,
    this.queue = const <MusicEntry>[],
  });

  factory MusicSnapshot.fromJson(Map<String, dynamic> json) => MusicSnapshot(
    revision: (json['revision'] as num?)?.toInt() ?? 0,
    serverTimeMs: (json['serverTimeMs'] as num?)?.toInt() ?? 0,
    current: json['current'] == null
        ? null
        : MusicCurrent.fromJson((json['current'] as Map).cast<String, dynamic>()),
    queue: (json['queue'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(MusicEntry.fromJson)
        .toList(growable: false),
  );

  final int revision;
  final int serverTimeMs;
  final MusicCurrent? current;
  final List<MusicEntry> queue;
}
// --------------------------------------------------------------------------- //
// 服务器 → 客户端
// --------------------------------------------------------------------------- //
sealed class ServerMessage {
  const ServerMessage();

  /// 解析一条服务端消息；无法识别的类型返回 [UnknownServerMessage]。
  static ServerMessage fromJson(Map<String, dynamic> json) {
    final type = json['type'];
    return switch (type) {
      'hello' => ServerHello.fromJson(json),
      'ping' => ServerPingMessage((json['t'] as num?)?.toDouble()),
      'pong' => PongMessage(
        (json['t'] as num?)?.toDouble(),
        serverTimeMs: (json['serverTimeMs'] as num?)?.toInt() ?? 0,
      ),
      'room_state' => RoomStateMessage.fromJson(json),
      'music_state' => MusicStateMessage.fromJson(json),
      'member_joined' => MemberJoinedMessage.fromJson(json),
      'member_left' => MemberLeftMessage.fromJson(json),
      'member_state_changed' => MemberStateChangedMessage.fromJson(json),
      'offer' => RelayOfferMessage.fromJson(json),
      'answer' => RelayAnswerMessage.fromJson(json),
      'candidate' => RelayCandidateMessage.fromJson(json),
      'room_closed' => RoomClosedMessage.fromJson(json),
      'kicked' => KickedMessage.fromJson(json),
      'error' => ServerErrorMessage.fromJson(json),
      _ => UnknownServerMessage(type?.toString() ?? ''),
    };
  }
}

/// 连接建立后的第一条消息：会话身份 + 服务器能力 + ICE 配置。
final class ServerHello extends ServerMessage {
  const ServerHello({
    required this.peerId,
    required this.protocolVersion,
    required this.heartbeatInterval,
    required this.iceServers,
    required this.roomCapacity,
    required this.serverName,
    required this.serverVersion,
    required this.displayName,
    required this.username,
    required this.userId,
    this.avatar,
    this.serverTimeMs = 0,
    this.musicEnabled = false,
  });

  factory ServerHello.fromJson(Map<String, dynamic> json) {
    final server =
        json['server'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    final user =
        json['user'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    return ServerHello(
      peerId: json['peerId'] as String,
      protocolVersion:
          (json['protocolVersion'] as num?)?.toInt() ?? kProtocolVersion,
      heartbeatInterval: (json['heartbeatInterval'] as num?)?.toInt() ?? 30,
      iceServers: (json['iceServers'] as List<dynamic>? ?? const <dynamic>[])
          .cast<String>(),
      roomCapacity: (json['roomCapacity'] as num?)?.toInt() ?? 5,
      serverName: server['name'] as String? ?? '',
      serverVersion: server['version'] as String? ?? '',
      serverTimeMs: (json['serverTimeMs'] as num?)?.toInt() ?? 0,
      musicEnabled: json['musicEnabled'] as bool? ?? false,
      displayName: user['displayName'] as String? ?? '',
      username: user['username'] as String? ?? '',
      userId: (user['id'] as num?)?.toInt() ?? 0,
      avatar: user['avatar'] as String?,
    );
  }

  final String peerId;
  final int protocolVersion;
  final int heartbeatInterval;
  final List<String> iceServers;
  final int roomCapacity;
  final String serverName;
  final String serverVersion;
  /// 服务器时钟（毫秒）：进房前就能先估一次时钟偏移。
  final int serverTimeMs;
  /// 服务器是否开启房间点歌（关闭时客户端不该显示点歌台）。
  final bool musicEnabled;
  final String username;
  final String displayName;
  final int userId;
  final String? avatar;
}

final class PongMessage extends ServerMessage {
  const PongMessage(this.t, {this.serverTimeMs = 0});

  final double? t;

  /// 服务器时钟（毫秒）：客户端做 SNTP 式偏移估计用。
  final int serverTimeMs;
}

/// 服务端应用层心跳：客户端必须回 `pong`。
final class ServerPingMessage extends ServerMessage {
  const ServerPingMessage(this.t);

  final double? t;
}

final class RoomStateMessage extends ServerMessage {
  const RoomStateMessage({
    required this.room,
    required this.selfPeerId,
    required this.members,
    this.music = const MusicSnapshot(),
  });

  factory RoomStateMessage.fromJson(Map<String, dynamic> json) =>
      RoomStateMessage(
        room: RoomSummary.fromJson(
          json['room'] as Map<String, dynamic>? ?? const {},
        ),
        selfPeerId: json['selfPeerId'] as String? ?? '',
        members: (json['members'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(MemberInfo.fromJson)
            .toList(growable: false),
        music: MusicSnapshot.fromJson(
          (json['music'] as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{},
        ),
      );

  final RoomSummary room;
  final String selfPeerId;
  final List<MemberInfo> members;

  /// 进房即拿到权威的点歌队列（含当前曲与时间锚点）。
  final MusicSnapshot music;
}

/// 点歌队列变化（服务端每次变化都全量广播，revision 单调递增）。
final class MusicStateMessage extends ServerMessage {
  const MusicStateMessage(this.snapshot);

  factory MusicStateMessage.fromJson(Map<String, dynamic> json) =>
      MusicStateMessage(MusicSnapshot.fromJson(json));

  final MusicSnapshot snapshot;
}

final class MemberJoinedMessage extends ServerMessage {
  const MemberJoinedMessage(this.member);

  factory MemberJoinedMessage.fromJson(Map<String, dynamic> json) =>
      MemberJoinedMessage(
        MemberInfo.fromJson(
          json['member'] as Map<String, dynamic>? ?? const {},
        ),
      );

  final MemberInfo member;
}

final class MemberLeftMessage extends ServerMessage {
  const MemberLeftMessage({required this.peerId, required this.reason});

  factory MemberLeftMessage.fromJson(Map<String, dynamic> json) =>
      MemberLeftMessage(
        peerId: json['peerId'] as String,
        reason: json['reason'] as String? ?? 'left',
      );

  final String peerId;
  final String reason;
}

final class MemberStateChangedMessage extends ServerMessage {
  const MemberStateChangedMessage({required this.peerId, required this.patch});

  factory MemberStateChangedMessage.fromJson(Map<String, dynamic> json) =>
      MemberStateChangedMessage(
        peerId: json['peerId'] as String,
        patch:
            json['patch'] as Map<String, dynamic>? ?? const <String, dynamic>{},
      );

  final String peerId;
  final Map<String, dynamic> patch;
}

/// 转发类消息的公共形状（服务器按 dst/src 路由，不解析 SDP）。
sealed class RelayMessage extends ServerMessage {
  const RelayMessage({required this.src});

  final String src;
}

final class RelayOfferMessage extends RelayMessage {
  const RelayOfferMessage({required super.src, required this.sdp});

  factory RelayOfferMessage.fromJson(Map<String, dynamic> json) =>
      RelayOfferMessage(
        src: json['src'] as String,
        sdp: json['sdp'] as String? ?? '',
      );

  final String sdp;
}

final class RelayAnswerMessage extends RelayMessage {
  const RelayAnswerMessage({required super.src, required this.sdp});

  factory RelayAnswerMessage.fromJson(Map<String, dynamic> json) =>
      RelayAnswerMessage(
        src: json['src'] as String,
        sdp: json['sdp'] as String? ?? '',
      );

  final String sdp;
}

final class RelayCandidateMessage extends RelayMessage {
  const RelayCandidateMessage({
    required super.src,
    this.candidate,
    this.endOfCandidates = false,
  });

  factory RelayCandidateMessage.fromJson(Map<String, dynamic> json) {
    final candidate = json['candidate'];
    return RelayCandidateMessage(
      src: json['src'] as String,
      candidate: candidate is Map<String, dynamic>
          ? IceCandidatePayload.fromJson(candidate)
          : null,
      endOfCandidates: json['endOfCandidates'] as bool? ?? false,
    );
  }

  /// null 表示候选收集结束。
  final IceCandidatePayload? candidate;
  final bool endOfCandidates;
}

final class RoomClosedMessage extends ServerMessage {
  const RoomClosedMessage({required this.roomId, required this.reason});

  factory RoomClosedMessage.fromJson(Map<String, dynamic> json) =>
      RoomClosedMessage(
        roomId: json['roomId'] as String? ?? '',
        reason: json['reason'] as String? ?? 'closed',
      );

  final String roomId;
  final String reason;
}

final class KickedMessage extends ServerMessage {
  const KickedMessage({required this.reason, this.code = ''});

  factory KickedMessage.fromJson(Map<String, dynamic> json) => KickedMessage(
    reason: json['reason'] as String? ?? '',
    code: json['code'] as String? ?? '',
  );

  final String reason;
  final String code;
}

final class ServerErrorMessage extends ServerMessage {
  const ServerErrorMessage({
    required this.code,
    required this.message,
    this.ref,
  });

  factory ServerErrorMessage.fromJson(Map<String, dynamic> json) =>
      ServerErrorMessage(
        code: json['code'] as String? ?? 'unknown',
        message: json['message'] as String? ?? '',
        ref: json['ref'] as String?,
      );

  final String code;
  final String message;
  final String? ref;
}

final class UnknownServerMessage extends ServerMessage {
  const UnknownServerMessage(this.type);

  final String type;
}

// --------------------------------------------------------------------------- //
// 客户端 → 服务器
// --------------------------------------------------------------------------- //
Map<String, dynamic> pingMessage({double? t}) => {
  'v': kProtocolVersion,
  'type': 'ping',
  't': ?t,
};

Map<String, dynamic> joinRoomMessage({
  required String roomId,
  String? password,
}) => {
  'v': kProtocolVersion,
  'type': 'join_room',
  'roomId': roomId,
  if (password != null && password.isNotEmpty) 'password': password,
};

Map<String, dynamic> leaveRoomMessage() => {
  'v': kProtocolVersion,
  'type': 'leave_room',
};

/// 上报自身状态；只提交需要变更的字段。
Map<String, dynamic> memberStateMessage({
  bool? muted,
  bool? sharing,
  bool? speaking,
}) => {
  'v': kProtocolVersion,
  'type': 'member_state',
  'muted': ?muted,
  'sharing': ?sharing,
  'speaking': ?speaking,
};

Map<String, dynamic> offerMessage({required String dst, required String sdp}) =>
    {'v': kProtocolVersion, 'type': 'offer', 'dst': dst, 'sdp': sdp};

Map<String, dynamic> answerMessage({
  required String dst,
  required String sdp,
}) => {'v': kProtocolVersion, 'type': 'answer', 'dst': dst, 'sdp': sdp};

Map<String, dynamic> candidateMessage({
  required String dst,
  IceCandidatePayload? candidate,
}) => {
  'v': kProtocolVersion,
  'type': 'candidate',
  'dst': dst,
  'candidate': candidate?.toJson(),
};

// ---- 点歌（房间共享队列）----
/// 点歌：`musicInfo` 是音源原始对象，服务端原样保留并广播给全房间。
Map<String, dynamic> musicEnqueueMessage({
  required String source,
  required String songId,
  required Map<String, dynamic> musicInfo,
  String title = '',
  String artist = '',
  int? durationMs,
}) => {
  'v': kProtocolVersion,
  'type': 'music_enqueue',
  'source': source,
  'songId': songId,
  'musicInfo': musicInfo,
  'title': title,
  'artist': artist,
  'durationMs': ?durationMs,
};

Map<String, dynamic> musicRemoveMessage({required String entryId}) => {
  'v': kProtocolVersion,
  'type': 'music_remove',
  'entryId': entryId,
};

Map<String, dynamic> musicSkipMessage({String? entryId}) => {
  'v': kProtocolVersion,
  'type': 'music_skip',
  'entryId': ?entryId,
};

Map<String, dynamic> musicClearMessage() => {
  'v': kProtocolVersion,
  'type': 'music_clear',
};

/// 「本机放完了」：`duration` 不可信时的兜底（服务端按 revision 幂等）。
Map<String, dynamic> musicEosMessage({
  required String entryId,
  required int revision,
}) => {
  'v': kProtocolVersion,
  'type': 'music_eos',
  'entryId': entryId,
  'revision': revision,
};
