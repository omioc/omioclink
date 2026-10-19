/// REST 层的领域模型（与服务端 `app/schemas.py` 对应）。
library;

class User {
  const User({
    required this.id,
    required this.username,
    required this.displayName,
    this.avatar,
    this.online = false,
    this.createdAt,
  });

  factory User.fromJson(Map<String, dynamic> json) => User(
    id: (json['id'] as num).toInt(),
    username: json['username'] as String,
    displayName: json['displayName'] as String? ?? json['username'] as String,
    avatar: json['avatar'] as String?,
    online: json['online'] as bool? ?? false,
    createdAt: _tryParseDate(json['createdAt']),
  );

  final int id;
  final String username;
  final String displayName;
  final String? avatar;
  final bool online;
  final DateTime? createdAt;

  User copyWith({bool? online, String? displayName, String? avatar}) => User(
    id: id,
    username: username,
    displayName: displayName ?? this.displayName,
    avatar: avatar ?? this.avatar,
    online: online ?? this.online,
    createdAt: createdAt,
  );

  /// 头像占位用的单字（取昵称首字符）。
  String get initial => displayName.isEmpty ? '?' : displayName.substring(0, 1);
}

class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.expiresIn,
    required this.user,
  });

  factory AuthSession.fromJson(Map<String, dynamic> json) => AuthSession(
    accessToken: json['accessToken'] as String,
    expiresIn: (json['expiresIn'] as num?)?.toInt() ?? 0,
    user: User.fromJson(json['user'] as Map<String, dynamic>),
  );

  final String accessToken;
  final int expiresIn;
  final User user;
}

/// 房间列表查询范围。
enum RoomScope { public, mine }

/// 房间（REST 视图，含实时成员数与在线标记）。
class Room {
  const Room({
    required this.roomId,
    required this.name,
    required this.ownerId,
    this.ownerName,
    required this.capacity,
    this.memberCount = 0,
    this.hasPassword = false,
    this.isPublic = true,
    this.createdAt,
    this.online = false,
    this.joined = false,
  });

  factory Room.fromJson(Map<String, dynamic> json) => Room(
    roomId: json['roomId'] as String,
    name: json['name'] as String,
    ownerId: (json['ownerId'] as num).toInt(),
    ownerName: json['ownerName'] as String?,
    capacity: (json['capacity'] as num).toInt(),
    memberCount: (json['memberCount'] as num?)?.toInt() ?? 0,
    hasPassword: json['hasPassword'] as bool? ?? false,
    isPublic: json['isPublic'] as bool? ?? true,
    createdAt: _tryParseDate(json['createdAt']),
    online: json['online'] as bool? ?? false,
    joined: json['joined'] as bool? ?? false,
  );

  final String roomId;
  final String name;
  final int ownerId;
  final String? ownerName;
  final int capacity;
  final int memberCount;
  final bool hasPassword;
  final bool isPublic;
  final DateTime? createdAt;
  final bool online;
  final bool joined;

  bool get isFull => memberCount >= capacity;
}

class Friend {
  const Friend({required this.user, this.online = false});

  factory Friend.fromJson(Map<String, dynamic> json) => Friend(
    user: User.fromJson(json['user'] as Map<String, dynamic>),
    online: json['online'] as bool? ?? false,
  );

  final User user;
  final bool online;
}

/// 好友申请方向。
enum FriendRequestDirection { incoming, outgoing }

class FriendRequest {
  const FriendRequest({
    required this.id,
    required this.user,
    required this.direction,
    this.createdAt,
  });

  factory FriendRequest.fromJson(Map<String, dynamic> json) => FriendRequest(
    id: (json['id'] as num).toInt(),
    user: User.fromJson(json['user'] as Map<String, dynamic>),
    direction: json['direction'] == 'outgoing'
        ? FriendRequestDirection.outgoing
        : FriendRequestDirection.incoming,
    createdAt: _tryParseDate(json['createdAt']),
  );

  final int id;
  final User user;
  final FriendRequestDirection direction;
  final DateTime? createdAt;
}

/// `/server/info`：服务器能力与 ICE 配置。
class ServerDescriptor {
  const ServerDescriptor({
    required this.name,
    required this.version,
    this.protocolVersion = 1,
    this.roomCapacity = 5,
    this.maxRoomCapacity = 8,
    this.iceServers = const <String>[],
    this.heartbeatInterval = 30,
    this.webSocketPath = '/ws',
    this.apiPrefix = '/api/v1',
    this.allowRegistration = false,
    this.mediaRelay = false,
    this.musicEnabled = false,
  });

  factory ServerDescriptor.fromJson(Map<String, dynamic> json) =>
      ServerDescriptor(
        name: json['name'] as String? ?? '未知服务器',
        version: json['version'] as String? ?? '0.0.0',
        protocolVersion: (json['protocolVersion'] as num?)?.toInt() ?? 1,
        roomCapacity: (json['roomCapacity'] as num?)?.toInt() ?? 5,
        maxRoomCapacity: (json['maxRoomCapacity'] as num?)?.toInt() ?? 8,
        iceServers: (json['iceServers'] as List<dynamic>? ?? const <dynamic>[])
            .cast<String>(),
        heartbeatInterval: (json['heartbeatInterval'] as num?)?.toInt() ?? 30,
        webSocketPath: json['websocketPath'] as String? ?? '/ws',
        apiPrefix: json['apiPrefix'] as String? ?? '/api/v1',
        allowRegistration: json['allowRegistration'] as bool? ?? false,
        mediaRelay: json['mediaRelay'] as bool? ?? false,
        musicEnabled: json['musicEnabled'] as bool? ?? false,
      );

  final String name;
  final String version;
  final int protocolVersion;
  final int roomCapacity;
  final int maxRoomCapacity;
  final List<String> iceServers;
  final int heartbeatInterval;
  final String webSocketPath;
  final String apiPrefix;

  /// 服务器是否开放用户自注册（默认关闭）；客户端据此显隐注册入口。
  final bool allowRegistration;

  /// 恒为 false：服务器不提供任何媒体中继。
  final bool mediaRelay;

  /// 点歌台是否可用（服务器关掉了音乐元数据聚合时为 false）。
  final bool musicEnabled;
}

DateTime? _tryParseDate(Object? value) {
  if (value is! String || value.isEmpty) {
    return null;
  }
  return DateTime.tryParse(value);
}
