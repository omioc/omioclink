import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/core/app_theme.dart';
import 'package:omioclink_client/features/image_picker_dialog.dart';

/// 现场画一张 PNG 写进临时目录：选图框要真的能预览，测试文件里不塞二进制。
Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    const ui.Rect.fromLTWH(0, 0, 8, 8),
    ui.Paint()..color = const ui.Color(0xFF3366FF),
  );
  final image = await recorder.endRecording().toImage(8, 8);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('omioclink-picker-');
    final bytes = await _png();
    final sep = Platform.pathSeparator;
    File('${root.path}${sep}wall.png').writeAsBytesSync(bytes);
    File('${root.path}${sep}readme.txt').writeAsStringSync('不是图片');
    final sub = Directory('${root.path}$sep风景')..createSync();
    File('${sub.path}${sep}lake.png').writeAsBytesSync(bytes);
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  testWidgets('只列文件夹和图片，能进子目录，选中后确认按钮返回路径', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.standard(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  // 头像那种用法：标题和按钮文案由调用方给
                  picked = await showImagePickerDialog(
                    context,
                    title: '选择头像图片',
                    confirmLabel: '用这张当头像',
                    initialDirectory: root.path,
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('选择头像图片'), findsOneWidget, reason: '标题用调用方给的文案');
    expect(find.text('wall.png'), findsOneWidget);
    expect(find.text('风景'), findsOneWidget, reason: '文件夹要列出来');
    expect(find.text('readme.txt'), findsNothing, reason: '非图片不列');
    // 还没选图片：确认按钮是禁用的
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '用这张当头像'))
          .onPressed,
      isNull,
    );

    await tester.tap(find.text('风景'));
    await tester.pumpAndSettle();
    expect(find.text('lake.png'), findsOneWidget, reason: '进子目录后列子目录的图');
    expect(find.text('wall.png'), findsNothing);

    await tester.tap(find.text('lake.png'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '用这张当头像'))
          .onPressed,
      isNotNull,
      reason: '选中图片后要能确定',
    );

    await tester.tap(find.text('用这张当头像'));
    await tester.pumpAndSettle();

    expect(picked, isNotNull);
    expect(picked!.endsWith('lake.png'), isTrue);
  });
}
