import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/core/theme_packs.dart';
import 'package:omioclink_client/data/theme_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 现场画一张 PNG：壁纸要真的能解码，测试文件里不塞二进制。
Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    const ui.Rect.fromLTWH(0, 0, 8, 8),
    ui.Paint()..color = const ui.Color(0xFF22B573),
  );
  final image = await recorder.endRecording().toImage(8, 8);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  // applyWallpaper 会去踢图片缓存，需要绑定（不用 pumpWidget 也要先初始化）
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('omioclink-theme-');
  });

  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  String wallpaperAt(String name) =>
      '${dir.path}${Platform.pathSeparator}$name';

  test('第一次启动：默认薄荷汽水、没有壁纸、表面是不透明的', () async {
    final store = ThemeStore(directoryBase: dir.path);
    await store.load();

    expect(store.pack.id, AppThemePacks.defaultPack.id);
    expect(store.hasWallpaper, isFalse);
    expect(store.palette.stage, AppThemePacks.defaultPack.palette.stage);
  });

  test('切主题会记住，重开能读回来', () async {
    final store = ThemeStore(directoryBase: dir.path);
    await store.load();
    await store.select(AppThemePacks.cinnabar.id);
    expect(store.pack.name, '朱砂');

    final again = ThemeStore(directoryBase: dir.path);
    await again.load();
    expect(again.pack.id, AppThemePacks.cinnabar.id);
  });

  test('存了不存在的主题 id：回落默认，而不是起不来', () async {
    SharedPreferences.setMockInitialValues({
      'omioclink.theme.pack': 'no-such-pack',
    });
    final store = ThemeStore(directoryBase: dir.path);
    await store.load();
    expect(store.pack.id, AppThemePacks.defaultPack.id);
  });

  test('上传壁纸：落盘 + 表面半透明；换图换新文件名；移除时文件一起删掉', () async {
    final store = ThemeStore(directoryBase: dir.path);
    await store.load();

    final bytes = Uint8List.fromList(List<int>.filled(64, 7));
    expect(await store.applyWallpaper(bytes), isNull);
    expect(store.wallpaperRevision, 1);

    expect(store.hasWallpaper, isTrue);
    final first = File(store.wallpaperPath!);
    expect(first.existsSync(), isTrue);
    expect(first.lengthSync(), 64);
    expect(store.palette.stage.a, 0, reason: '舞台要让出透明度，否则壁纸被盖住');
    expect(store.palette.panel.a, lessThan(1));

    // 换另一张必须落到新文件名：同名覆盖会命中图片缓存，界面继续画上一张
    expect(await store.applyWallpaper(Uint8List.fromList([1, 2, 3])), isNull);
    expect(store.wallpaperRevision, 2);
    final second = File(store.wallpaperPath!);
    expect(second.path, isNot(first.path), reason: '同名覆盖会命中图片缓存');
    expect(second.lengthSync(), 3);
    expect(first.existsSync(), isFalse, reason: '旧图要删掉，目录里只留当前那张');

    await store.clearWallpaper();
    expect(store.hasWallpaper, isFalse);
    expect(second.existsSync(), isFalse);
    expect(store.palette.stage.a, 1);
  });

  test('壁纸文件被删掉：启动时把记录也清掉', () async {
    SharedPreferences.setMockInitialValues({
      'omioclink.theme.wallpaper': wallpaperAt('wallpaper-7.png'),
    });
    final store = ThemeStore(directoryBase: dir.path);
    await store.load();

    expect(store.hasWallpaper, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('omioclink.theme.wallpaper'), isNull);
  });

  test('空图 / 过大的图会被挡下来', () async {
    final store = ThemeStore(directoryBase: dir.path);
    await store.load();

    expect(await store.applyWallpaper(Uint8List(0)), isNotNull);
    final tooBig = Uint8List(ThemeStore.wallpaperMaxBytes + 1);
    expect(await store.applyWallpaper(tooBig), isNotNull);
    expect(store.hasWallpaper, isFalse);
  });

  test('从文件设壁纸：认得出的图片才收，其它给出原因', () async {
    final store = ThemeStore(directoryBase: dir.path);
    await store.load();
    final sep = Platform.pathSeparator;

    final png = File('${dir.path}${sep}source.png');
    png.writeAsBytesSync(await _png());
    expect(await store.applyWallpaperFile(png.path), isNull);
    expect(store.hasWallpaper, isTrue);

    // 扩展名对、内容不是图片：要挡下来并给出原因，不能存一张坏图当背景
    final broken = File('${dir.path}${sep}broken.png');
    broken.writeAsStringSync('这不是图片');
    expect(await store.applyWallpaperFile(broken.path), '这个文件不是能识别的图片');

    expect(
      await store.applyWallpaperFile('${dir.path}${sep}missing.png'),
      '这个文件已经不在了',
    );
  });

  test('目录里已有壁纸时直接沿用，不必重新上传', () async {
    final file = File(wallpaperAt('wallpaper-42.png'));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(List<int>.filled(8, 1));
    SharedPreferences.setMockInitialValues({
      'omioclink.theme.wallpaper': file.path,
    });

    final store = ThemeStore(directoryBase: dir.path);
    await store.load();
    expect(store.hasWallpaper, isTrue);
    expect(store.wallpaperPath, file.path);
  });

  test('启动时清掉遗留的旧壁纸文件（换图删除失败留下的）', () async {
    final keep = File(wallpaperAt('wallpaper-2.png'))
      ..writeAsBytesSync(List<int>.filled(8, 2));
    final stale = File(wallpaperAt('wallpaper-1.png'))
      ..writeAsBytesSync(List<int>.filled(8, 1));
    SharedPreferences.setMockInitialValues({
      'omioclink.theme.wallpaper': keep.path,
    });

    final store = ThemeStore(directoryBase: dir.path);
    await store.load();
    expect(store.wallpaperPath, keep.path);
    expect(stale.existsSync(), isFalse, reason: '只保留当前那张');
    expect(keep.existsSync(), isTrue);
  });
}
