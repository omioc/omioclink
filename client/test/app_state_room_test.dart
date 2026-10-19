import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 进房相关的守卫：重复进同一个房间不该把会话拆了重建。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('没进房间时 isInRoom 恒为 false', () {
    final state = AppState();
    addTearDown(state.dispose);

    expect(state.isInRoom('room-1'), isFalse);
  });

  test('未登录时 joinRoom 直接失败，不会建出半个会话', () async {
    final state = AppState();
    addTearDown(state.dispose);

    final ok = await state.joinRoom(roomId: 'room-1');

    expect(ok, isFalse);
    expect(state.error, '请先登录');
    expect(state.session, isNull);
  });
}
