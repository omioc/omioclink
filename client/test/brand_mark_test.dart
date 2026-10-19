import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/widgets/common.dart';

void main() {
  test('品牌图确实打进了资源包（路径写错会静默退回占位图标）', () async {
    final data = await rootBundle.load(BrandMark.assetName);
    expect(data.lengthInBytes, greaterThan(1000));
  });

  testWidgets('品牌标识用 OmiocLink 图标 + 名称', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: BrandMark())));

    expect(BrandMark.assetName, 'assets/branding/omioclink.png');
    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as AssetImage).assetName, BrandMark.assetName);
    expect(find.text('OmiocLink'), findsOneWidget);
  });

  testWidgets('compact 模式只留图标（标题栏右侧那种窄位）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: BrandMark(compact: true))),
    );

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('OmiocLink'), findsNothing);
  });
}
