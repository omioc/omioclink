import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:omioclink_client/core/platform.dart';

void main() {
  // 手机/平板的分界是整个窄屏适配的总开关：判错了要么手机上挤三栏，
  // 要么平板上被迫退回单栏。所以这里把边界值钉死。
  testWidgets('短边 < 600 走手机单栏，>= 600 沿用桌面三栏', (tester) async {
    Future<bool> compactAt(Size size) async {
      late bool compact;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: size),
          child: Builder(
            builder: (context) {
              compact = useCompactLayout(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return compact;
    }

    // 手机竖屏与横屏：按短边判定，横过来不该突然变成桌面三栏
    expect(await compactAt(const Size(360, 780)), isTrue);
    expect(await compactAt(const Size(780, 360)), isTrue);
    expect(await compactAt(const Size(393, 852)), isTrue);

    // 平板（768dp 短边起）与桌面窗口：保持现有三栏布局
    expect(await compactAt(const Size(768, 1024)), isFalse);
    expect(await compactAt(const Size(1320, 860)), isFalse);
  });
}
