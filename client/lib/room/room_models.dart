import '../data/models.dart';
import '../signaling/protocol.dart';

/// 房间列表里该展示的人数。
///
/// 如果正身处这个房间，就用实时会话的成员数——它由成员进出事件驱动、是真正的实时值；
/// 其余房间用列表接口返回的快照（由轮询刷新）。只靠轮询的话，通话中看到的人数会滞后。
int displayedMemberCount({
  required Room room,
  String? activeRoomId,
  int? activeMemberCount,
}) {
  if (activeRoomId == room.roomId && activeMemberCount != null) {
    return activeMemberCount;
  }
  return room.memberCount;
}

/// 房间会话的连接阶段。
enum RoomPhase {
  idle,
  connecting,
  joining,
  active,
  leaving,
  closed,
  failed;

  bool get isActive => this == RoomPhase.active;
}

/// 一条聊天消息（走 P2P DataChannel，服务器不承载也不存储）。
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.peerId,
    required this.displayName,
    required this.text,
    required this.sentAt,
    this.isMine = false,
    this.failed = false,
  });

  factory ChatMessage.fromWire(Map<String, dynamic> json) => ChatMessage(
    id: json['id'] as String? ?? '',
    peerId: json['from'] as String? ?? '',
    displayName: json['name'] as String? ?? '',
    text: json['text'] as String? ?? '',
    sentAt: DateTime.fromMillisecondsSinceEpoch(
      (json['at'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
    ),
  );

  final String id;
  final String peerId;
  final String displayName;
  final String text;
  final DateTime sentAt;
  final bool isMine;
  final bool failed;

  Map<String, dynamic> toWire() => {
    't': 'chat',
    'id': id,
    'from': peerId,
    'name': displayName,
    'at': sentAt.millisecondsSinceEpoch,
    'text': text,
  };
}

/// 房间统计（服务器媒体流量恒为 0，这里展示的是 P2P 码率与直连方式）。
class RoomStats {
  const RoomStats({
    this.outgoingKbps,
    this.incomingKbps,
    this.peers = const <String, double>{},
  });

  final double? outgoingKbps;
  final double? incomingKbps;

  /// peerId → 最近一次的往返时延（毫秒）。
  final Map<String, double> peers;
}

/// 房间内一名成员在本地视角下的完整视图。
class RoomMemberView {
  const RoomMemberView({
    required this.info,
    this.local = false,
    this.mutedLocally = false,
  });

  final MemberInfo info;

  /// 是否是自己。
  final bool local;

  /// 「对本地静音」——UI 层预留（设计稿的成员音量条）。
  final bool mutedLocally;

  RoomMemberView copyWith({MemberInfo? info, bool? mutedLocally}) =>
      RoomMemberView(
        info: info ?? this.info,
        local: local,
        mutedLocally: mutedLocally ?? this.mutedLocally,
      );
}
