import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/data/avatar_picker.dart';

/// 现场画一张 [width]×[height] 的 PNG，避免把二进制塞进测试文件。
Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF3366FF),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// 读一张 PNG 的像素尺寸（独立于被测代码，避免自证）。
Future<({int width, int height})> _sizeOf(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final size = (width: frame.image.width, height: frame.image.height);
  frame.image.dispose();
  codec.dispose();
  return size;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('长边缩到 maxSide，且保持比例', () async {
    final raw = await _png(400, 200);

    final compressed = await const AvatarPicker(maxSide: 100).compress(raw);

    expect(compressed, isNotNull);
    final size = await _sizeOf(compressed!);
    expect(size.width, 100);
    expect(size.height, 50);
  });

  test('竖图同样按长边缩', () async {
    final raw = await _png(60, 300);

    final compressed = await const AvatarPicker(maxSide: 120).compress(raw);

    final size = await _sizeOf(compressed!);
    expect(size.height, 120);
    expect(size.width, 24);
  });

  test('本来就不大的图不放大', () async {
    final raw = await _png(32, 32);

    final compressed = await const AvatarPicker(maxSide: 256).compress(raw);

    final size = await _sizeOf(compressed!);
    expect(size.width, 32);
    expect(size.height, 32);
  });

  test('不是图片的内容返回 null，而不是抛异常', () async {
    const picker = AvatarPicker();
    expect(
      await picker.compress(Uint8List.fromList(utf8.encode('not an image'))),
      isNull,
    );
    expect(await picker.compress(Uint8List(0)), isNull);
    // 只有 PNG 头、后面是垃圾：解码应当失败
    expect(
      await picker.compress(
        Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 1, 2, 3]),
      ),
      isNull,
    );
  });

  test('fromPath：读本地图片并缩到 maxSide', () async {
    final dir = Directory.systemTemp.createTempSync('omioclink-avatar-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}${Platform.pathSeparator}portrait.png');
    file.writeAsBytesSync(await _png(400, 200));

    final picked = await const AvatarPicker(maxSide: 100).fromPath(file.path);

    expect(picked.error, isNull);
    final size = await _sizeOf(picked.bytes!);
    expect(size.width, 100);
    expect(size.height, 50);
  });

  test('fromPath：文件不存在 / 不是图片都给错误文案，不抛异常', () async {
    const picker = AvatarPicker();
    final sep = Platform.pathSeparator;

    final missing = await picker.fromPath(
      '${Directory.systemTemp.path}${sep}omioclink-not-here.png',
    );
    expect(missing.bytes, isNull);
    expect(missing.error, '读不了这个文件');

    final dir = Directory.systemTemp.createTempSync('omioclink-avatar-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final text = File('${dir.path}${sep}note.png')
      ..writeAsStringSync('不是图片');
    final notImage = await picker.fromPath(text.path);
    expect(notImage.bytes, isNull);
    expect(notImage.error, '这个文件不是能识别的图片');
  });
}
