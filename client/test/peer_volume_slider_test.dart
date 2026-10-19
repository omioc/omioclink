import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/features/volume_controls.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: SizedBox(width: 240, child: child))),
);

void main() {
  testWidgets('成员音量滑块是 0~200%，拖动回调带着量程内的原始值', (tester) async {
    final values = <double>[];
    await tester.pumpWidget(
      _host(
        PeerVolumeSlider(
          label: '小明',
          percent: 100,
          sliderKey: const Key('peer-volume-42'),
          onChanged: values.add,
        ),
      ),
    );

    expect(find.byKey(const Key('peer-volume-42')), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    final slider = tester.widget<Slider>(find.byKey(const Key('peer-volume-42')));
    expect(slider.min, 0);
    expect(slider.max, 200, reason: '成员音量上限是 200%');

    // 拖到最右：200%
    await tester.drag(find.byKey(const Key('peer-volume-42')), const Offset(400, 0));
    await tester.pump();
    expect(values.last, 200);

    // 拖到最左：0%
    await tester.drag(find.byKey(const Key('peer-volume-42')), const Offset(-400, 0));
    await tester.pump();
    expect(values.last, 0);
  });

  testWidgets('成员音量滑块按当前值显示百分比，静音时图标变静音', (tester) async {
    await tester.pumpWidget(
      _host(
        PeerVolumeSlider(
          label: '小红',
          percent: 160,
          muted: true,
          sliderKey: const Key('peer-volume-8'),
          onChanged: (_) {},
        ),
      ),
    );

    expect(find.text('160%'), findsOneWidget);
    expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);
  });

  testWidgets('麦克风 / 音乐音量滑块是 0~100%，拖动回调带着量程内的原始值', (tester) async {
    final mic = <double>[];
    final music = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(
                width: 240,
                child: VolumeSliderTile(
                  label: '麦克风音量（对方听到我的大小）',
                  value: 100,
                  max: 100,
                  sliderKey: const Key('mic-volume-slider'),
                  onChanged: mic.add,
                ),
              ),
              SizedBox(
                width: 240,
                child: VolumeSliderTile(
                  label: '音乐音量（只影响本机）',
                  value: 100,
                  max: 100,
                  sliderKey: const Key('music-volume-slider'),
                  onChanged: music.add,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final micSlider = tester.widget<Slider>(
      find.byKey(const Key('mic-volume-slider')),
    );
    expect(micSlider.min, 0);
    expect(micSlider.max, 100);
    final musicSlider = tester.widget<Slider>(
      find.byKey(const Key('music-volume-slider')),
    );
    expect(musicSlider.max, 100);
    // 拖到左端 = 0%（滑块宽 240，偏移量足够盖过量程）
    await tester.drag(
      find.byKey(const Key('mic-volume-slider')),
      const Offset(-400, 0),
    );
    await tester.pump();
    expect(mic.last, 0);

    await tester.drag(
      find.byKey(const Key('music-volume-slider')),
      const Offset(-400, 0),
    );
    await tester.pump();
    expect(music.last, 0);

    // 再从中间往右推到量程上限 = 100%
    await tester.timedDrag(
      find.byKey(const Key('mic-volume-slider')),
      const Offset(400, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pump();
    expect(mic.last, greaterThan(50), reason: '往右拖必须变大');
    expect(mic.last, lessThanOrEqualTo(100), reason: '不能超过量程上限');
  });

  testWidgets('降级时显示原因', (tester) async {
    await tester.pumpWidget(
      _host(
        VolumeSliderTile(
          label: '麦克风音量',
          value: 100,
          max: 100,
          notice: '没有找到可用的录音设备',
          sliderKey: const Key('mic-volume-slider'),
          onChanged: (_) {},
        ),
      ),
    );
    expect(find.text('没有找到可用的录音设备'), findsOneWidget);
  });
}
