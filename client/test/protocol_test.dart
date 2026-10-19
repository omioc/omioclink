import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/signaling/protocol.dart';

void main() {
  test('成员状态补丁可以更新昵称，其余字段不受影响', () {
    const member = MemberInfo(
      peerId: 'p1',
      userId: 1,
      username: 'alice',
      displayName: '小明',
    );

    final renamed = member.applyPatch(<String, dynamic>{
      'displayName': '小明改名了',
      'speaking': true,
    });
    expect(renamed.displayName, '小明改名了');
    expect(renamed.speaking, isTrue);
    expect(renamed.peerId, 'p1');

    // 补丁里没有昵称时保持原样
    expect(
      member.applyPatch(<String, dynamic>{'muted': true}).displayName,
      '小明',
    );
    expect(member.copyWith(displayName: '换个名字').displayName, '换个名字');
  });

  group('服务端消息解析', () {
    test('hello 携带会话身份、ICE 配置与服务器能力', () {
      final message = ServerMessage.fromJson(<String, dynamic>{
        'v': 1,
        'type': 'hello',
        'peerId': 'ac4b0391',
        'protocolVersion': 1,
        'heartbeatInterval': 30,
        'iceServers': <String>['stun:stun.example.com:3478'],
        'roomCapacity': 5,
        'server': <String, dynamic>{
          'name': 'OmiocLink 信令服务器',
          'version': '0.1.0',
        },
        'user': <String, dynamic>{
          'id': 7,
          'username': 'alice',
          'displayName': '小明',
        },
      });

      expect(message, isA<ServerHello>());
      final hello = message as ServerHello;
      expect(hello.peerId, 'ac4b0391');
      expect(hello.heartbeatInterval, 30);
      expect(hello.iceServers, <String>['stun:stun.example.com:3478']);
      expect(hello.roomCapacity, 5);
      expect(hello.displayName, '小明');
      expect(hello.userId, 7);
      expect(hello.avatar, isNull);
    });

    test('room_state 解析房间与成员快照', () {
      final message = ServerMessage.fromJson(<String, dynamic>{
        'type': 'room_state',
        'room': <String, dynamic>{
          'roomId': 'BX4K9K',
          'name': '游戏开黑',
          'ownerId': 7,
          'capacity': 5,
          'memberCount': 2,
          'hasPassword': false,
          'isPublic': true,
        },
        'selfPeerId': 'ac4b0391',
        'members': <Map<String, dynamic>>[
          <String, dynamic>{
            'peerId': 'ac4b0391',
            'userId': 7,
            'username': 'alice',
            'displayName': '小明',
            'muted': false,
            'sharing': false,
            'joinedAt': '2026-10-12T04:00:00Z',
          },
          <String, dynamic>{
            'peerId': 'f9caeec5',
            'userId': 8,
            'username': 'bob',
            'displayName': '小红',
            'muted': true,
            'sharing': true,
            'speaking': true,
          },
        ],
      });

      final state = message as RoomStateMessage;
      expect(state.room.roomId, 'BX4K9K');
      expect(state.room.capacity, 5);
      expect(state.selfPeerId, 'ac4b0391');
      expect(state.members, hasLength(2));
      expect(state.members.first.displayName, '小明');
      expect(state.members.first.joinedAt, DateTime.utc(2026, 10, 12, 4));
      expect(state.members.last.muted, isTrue);
      expect(state.members.last.sharing, isTrue);
      expect(state.members.last.speaking, isTrue);
      expect(state.members.last.initial, '小');
    });

    test('转发消息带 src，候选为 null 表示收集结束', () {
      final offer = ServerMessage.fromJson(<String, dynamic>{
        'type': 'offer',
        'src': 'f9caeec5',
        'sdp': 'v=0-offer',
      }) as RelayOfferMessage;
      expect(offer.src, 'f9caeec5');
      expect(offer.sdp, 'v=0-offer');

      final candidate = ServerMessage.fromJson(<String, dynamic>{
        'type': 'candidate',
        'src': 'f9caeec5',
        'candidate': <String, dynamic>{
          'candidate':
              'candidate:1 1 UDP 2122260223 192.168.1.10 50000 typ host',
          'sdpMid': '0',
          'sdpMLineIndex': 0,
        },
        'endOfCandidates': false,
      }) as RelayCandidateMessage;
      expect(candidate.candidate!.sdpMid, '0');
      expect(candidate.candidate!.sdpMLineIndex, 0);
      expect(candidate.endOfCandidates, isFalse);

      final end = ServerMessage.fromJson(<String, dynamic>{
        'type': 'candidate',
        'src': 'f9caeec5',
        'candidate': null,
        'endOfCandidates': true,
      }) as RelayCandidateMessage;
      expect(end.candidate, isNull);
      expect(end.endOfCandidates, isTrue);
    });

    test('成员状态变更以 patch 形式下发', () {
      final changed = ServerMessage.fromJson(<String, dynamic>{
        'type': 'member_state_changed',
        'peerId': 'f9caeec5',
        'patch': <String, dynamic>{'sharing': true},
      }) as MemberStateChangedMessage;
      expect(changed.peerId, 'f9caeec5');
      expect(changed.patch, <String, dynamic>{'sharing': true});
    });

    test('房间解散 / 被顶下线 / 错误', () {
      expect(
        (ServerMessage.fromJson(<String, dynamic>{
          'type': 'room_closed',
          'roomId': 'BX4K9K',
          'reason': 'closed',
        }) as RoomClosedMessage).reason,
        'closed',
      );
      expect(
        (ServerMessage.fromJson(<String, dynamic>{
          'type': 'kicked',
          'reason': 'duplicate_session',
          'code': 'duplicate_session',
        }) as KickedMessage).code,
        SignalingErrorCode.duplicateSession,
      );
      final error = ServerMessage.fromJson(<String, dynamic>{
        'type': 'error',
        'code': 'room_full',
        'message': '房间已满',
        'ref': 'BX4K9K',
      }) as ServerErrorMessage;
      expect(error.code, SignalingErrorCode.roomFull);
      expect(error.ref, 'BX4K9K');
    });

    test('未知类型不抛异常', () {
      final message = ServerMessage.fromJson(<String, dynamic>{
        'type': 'future_thing',
      });
      expect(message, isA<UnknownServerMessage>());
      expect((message as UnknownServerMessage).type, 'future_thing');
    });
  });

  group('客户端消息编码', () {
    test('全部带协议版本且字段用 camelCase', () {
      expect(jsonDecode(jsonEncode(pingMessage(t: 12.5))), <String, dynamic>{
        'v': 1,
        'type': 'ping',
        't': 12.5,
      });
      expect(
        jsonDecode(
          jsonEncode(joinRoomMessage(roomId: 'BX4K9K', password: 'pw')),
        ),
        {'v': 1, 'type': 'join_room', 'roomId': 'BX4K9K', 'password': 'pw'},
      );
      expect(jsonDecode(jsonEncode(joinRoomMessage(roomId: 'BX4K9K'))), {
        'v': 1,
        'type': 'join_room',
        'roomId': 'BX4K9K',
      });
      expect(jsonDecode(jsonEncode(leaveRoomMessage())), {
        'v': 1,
        'type': 'leave_room',
      });
    });

    test('member_state 只提交需要变更的字段', () {
      expect(jsonDecode(jsonEncode(memberStateMessage(muted: true))), {
        'v': 1,
        'type': 'member_state',
        'muted': true,
      });
      expect(
        jsonDecode(
          jsonEncode(memberStateMessage(sharing: false, speaking: true)),
        ),
        {'v': 1, 'type': 'member_state', 'sharing': false, 'speaking': true},
      );
    });

    test('offer / answer / candidate', () {
      expect(jsonDecode(jsonEncode(offerMessage(dst: 'f9', sdp: 'v=0'))), {
        'v': 1,
        'type': 'offer',
        'dst': 'f9',
        'sdp': 'v=0',
      });
      expect(jsonDecode(jsonEncode(answerMessage(dst: 'f9', sdp: 'v=0'))), {
        'v': 1,
        'type': 'answer',
        'dst': 'f9',
        'sdp': 'v=0',
      });
      final relay = jsonDecode(
        jsonEncode(
          candidateMessage(
            dst: 'f9',
            candidate: const IceCandidatePayload(
              candidate: 'candidate:1 1 UDP 1 10.0.0.1 1 typ host',
              sdpMid: '0',
              sdpMLineIndex: 1,
            ),
          ),
        ),
      ) as Map<String, dynamic>;
      expect(relay['candidate'], <String, dynamic>{
        'candidate': 'candidate:1 1 UDP 1 10.0.0.1 1 typ host',
        'sdpMid': '0',
        'sdpMLineIndex': 1,
      });

      final end = jsonDecode(
        jsonEncode(candidateMessage(dst: 'f9')),
      ) as Map<String, dynamic>;
      expect(end['candidate'], isNull);
      expect(end['dst'], 'f9');
    });

    test('成员状态补丁只覆盖提交的字段', () {
      const member = MemberInfo(
        peerId: 'p1',
        userId: 1,
        username: 'alice',
        displayName: '小明',
        muted: false,
        sharing: true,
      );
      final patched = member.applyPatch(<String, dynamic>{'muted': true});
      expect(patched.muted, isTrue);
      expect(patched.sharing, isTrue, reason: '未提交的字段保持原值');
      expect(patched.displayName, '小明');
    });
  });
}
