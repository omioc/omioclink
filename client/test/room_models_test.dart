import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/data/models.dart';
import 'package:omioclink_client/room/room_models.dart';

Room _room({int memberCount = 3}) => Room.fromJson(<String, dynamic>{
  'roomId': 'BX4K9K',
  'name': '游戏开黑',
  'ownerId': 7,
  'capacity': 5,
  'memberCount': memberCount,
  'isPublic': true,
});

void main() {
  group('房间列表里展示的人数', () {
    test('身处其中时用实时会话人数（成员进出即时更新）', () {
      expect(
        displayedMemberCount(
          room: _room(memberCount: 3),
          activeRoomId: 'BX4K9K',
          activeMemberCount: 5,
        ),
        5,
      );
    });

    test('在别的房间时仍用列表快照', () {
      expect(
        displayedMemberCount(
          room: _room(memberCount: 3),
          activeRoomId: 'OTHER1',
          activeMemberCount: 5,
        ),
        3,
      );
    });

    test('不在房间里时用列表快照', () {
      expect(displayedMemberCount(room: _room(memberCount: 4)), 4);
    });

    test('拿不到实时人数时退回快照，不会显示 0', () {
      expect(
        displayedMemberCount(
          room: _room(memberCount: 4),
          activeRoomId: 'BX4K9K',
        ),
        4,
      );
    });
  });
}
