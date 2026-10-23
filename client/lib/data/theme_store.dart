import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_log.dart';
import '../core/app_palette.dart';
import '../core/app_paths.dart';
import '../core/l10n_ext.dart';
import '../core/theme_packs.dart';
import 'avatar_picker.dart';

/// 主题与壁纸的本机设置（纯本地：服务器不知道，也不影响房间里的其他人）。
///
/// 两件事各存一处：
/// * 主题只记一个 id（`omioclink.theme.pack`），配色本身在 [AppThemePacks] 里；
/// * 壁纸要落盘（选区里那张图随时可能被删/被移动），只把绝对路径记进
///   `omioclink.theme.wallpaper`，启动时按路径读；路径失效就顺手把记录清掉，
///   免得每次启动都去找一个不存在的文件。
class ThemeStore extends ChangeNotifier {
  /// [directoryBase] 只在测试里传：不传就落到和日志同一个根目录。
  ThemeStore({this.directoryBase});

  static const _packKey = 'omioclink.theme.pack';
  static const _wallpaperKey = 'omioclink.theme.wallpaper';

  /// 壁纸文件名前缀。**每次都写一个新文件名**（`wallpaper-<戳>.png`），不再同名覆盖：
  /// * 图片缓存按 provider key（含路径）建键，同名覆盖后 `ResizeImage` / `FileImage`
  ///   仍命中旧条目，界面表现为「换了壁纸没反应」；
  /// * Windows 上正在解码的图片会占住文件，同名写入本身也可能失败。
  /// 旧文件在切换成功后删掉，长住磁盘的只有当前一张。
  static const String wallpaperFilePrefix = 'wallpaper';

  /// 壁纸长度上限（重编码后 2400px 的 PNG 通常 3~8MB，给到 32MB 足够宽裕）。
  static const int wallpaperMaxBytes = 32 * 1024 * 1024;

  /// 壁纸长边上限：1320×860 的窗口在 200% 缩放下也就 2640px 宽，
  /// 再大只是白占内存（一张 4000px 的图解码后要 60MB 以上）。
  static const int wallpaperMaxSide = 2400;

  /// 测试注入的壁纸目录；正常运行为空，按平台规则算（见 [directory]）。
  final String? directoryBase;

  AppThemePack _pack = AppThemePacks.defaultPack;
  String? _wallpaperPath;
  int _wallpaperRevision = 0;

  AppThemePack get pack => _pack;

  /// 壁纸的换图计数。
  ///
  /// 换图走的是**同一个文件路径**（固定 wallpaper.png），而 `DecorationImage`
  /// 是按值比较的：新旧 `BoxDecoration` 相等时 `RenderDecoratedBox` 会直接早退，
  /// 已经解析好的图片流继续画旧字节，表现就是「点了换一张，背景没变」。
  /// 界面把这个计数挂成 key，换图后强制重建一次才能真的重读文件。
  int get wallpaperRevision => _wallpaperRevision;

  /// 壁纸文件的绝对路径；没贴壁纸时为 null。
  String? get wallpaperPath => _wallpaperPath;

  bool get hasWallpaper => _wallpaperPath != null;

  /// 当前生效的色板：贴了壁纸就让表面半透明（见 [AppPalette.withWallpaper]）。
  AppPalette get palette =>
      hasWallpaper ? _pack.palette.withWallpaper() : _pack.palette;

  /// 壁纸目录：桌面是 `%LOCALAPPDATA%\OmiocLink\theme`（便携运行落在可执行文件
  /// 旁的 `theme`），手机是应用私有目录下的 `theme`——规则见 [AppPaths]。
  String get directory {
    final override = directoryBase;
    return override ?? AppPaths.themeDir;
  }

  /// 读回上次的选择。坏数据一律回落默认主题，绝不抛给界面。
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    String? packId;
    try {
      packId = prefs.getString(_packKey);
    } on Object {
      // 存成了别的类型（手改/旧版本残留）：当没选过
      packId = null;
    }
    _pack = AppThemePacks.byId(packId);

    String? path;
    try {
      path = prefs.getString(_wallpaperKey);
    } on Object {
      path = null;
    }
    if (path == null || path.isEmpty) {
      _wallpaperPath = null;
    } else if (File(path).existsSync()) {
      _wallpaperPath = path;
      // 换图现在是「写新文件 + 删旧文件」：万一上次删除失败，这里顺手收掉
      _pruneStale(path);
    } else {
      // 图没了（被删/被移动/换了机器）：记录一起清掉
      _wallpaperPath = null;
      await prefs.remove(_wallpaperKey);
    }
    notifyListeners();
  }

  /// 切换主题。同 id 不重复通知（否则点同一张卡片也会重刷一遍界面）。
  Future<void> select(String id) async {
    final pack = AppThemePacks.byId(id);
    if (pack.id == _pack.id) {
      return;
    }
    _pack = pack;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_packKey, pack.id);
  }

  /// 把本机的一个图片文件设成壁纸；返回错误文案，成功返回 null。
  ///
  /// 读文件 → 按长边压到 [wallpaperMaxSide] 的 PNG → 落盘。压缩放在这里而不是
  /// 直接把原图当背景：4K 的 JPG 解码成位图要几十 MB 内存，而背景只是铺满窗口。
  Future<String?> applyWallpaperFile(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      return appL10n.wallpaperFileMissing;
    }
    if (file.lengthSync() > wallpaperMaxBytes * 2) {
      return appL10n.wallpaperTooLarge;
    }
    final raw = await _readBytes(file);
    if (raw == null) {
      return appL10n.dataFileUnreadable;
    }
    final png = await AvatarPicker(
      maxSide: wallpaperMaxSide,
    ).compress(raw);
    if (png == null) {
      return appL10n.dataNotAnImage;
    }
    return applyWallpaper(png);
  }

  Future<Uint8List?> _readBytes(File file) async {
    try {
      return await file.readAsBytes();
    } on Object catch (error) {
      AppLog.warn('壁纸读取失败', error: error);
      return null;
    }
  }

  /// 把已经解码好的 PNG 字节落盘并启用；返回错误文案，成功返回 null。
  ///
  /// 单独抽出来是为了能在测试里直接喂字节，不走文件选择框。
  Future<String?> applyWallpaper(Uint8List bytes) async {
    if (bytes.isEmpty) {
      return appL10n.wallpaperEmptyImage;
    }
    if (bytes.length > wallpaperMaxBytes) {
      return appL10n.wallpaperTooLarge;
    }
    // 每次换图都写一个新文件名：Flutter 的图片缓存按 provider key（含文件路径）
    // 建键，同名覆盖会让背景继续画缓存里那张旧图 —— 「换了壁纸没反应」就是这么来的；
    // 另外 Windows 上正在解码的文件会被占住，同名写入本身也可能失败。
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final path =
        '$directory${Platform.pathSeparator}$wallpaperFilePrefix-$stamp.png';
    final previous = _wallpaperPath;
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_wallpaperKey, path);
      _wallpaperPath = path;
      _wallpaperRevision++;
      notifyListeners();
      // 新图落盘之后才删旧图：中途失败时至少还留着上一张能看
      if (previous != null && previous != path) {
        await _deleteQuietly(previous);
      }
      return null;
    } on Object catch (error) {
      AppLog.warn('壁纸保存失败', error: error);
      return appL10n.wallpaperSaveFailed('$error');
    }
  }

  /// 去掉壁纸（连同磁盘上的文件）。
  Future<void> clearWallpaper() async {
    if (_wallpaperPath == null) {
      return;
    }
    final path = _wallpaperPath!;
    _wallpaperPath = null;
    _wallpaperRevision++;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_wallpaperKey);
    await _deleteQuietly(path);
  }

  /// 删文件，失败只记日志：设置已经改过了，删不掉只是留个垃圾文件。
  Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
      }
    } on Object catch (error) {
      AppLog.warn('壁纸文件删除失败', error: error);
    }
  }

  /// 收掉壁纸目录里不属于当前那张的旧文件。
  ///
  /// 换图改成「写新文件 + 删旧文件」之后，只要有一次删除失败（文件正被解码器占用），
  /// 旧图就会一直躺着；启动时顺手收一遍，别让目录越攒越多。
  void _pruneStale(String keep) {
    try {
      final dir = Directory(directory);
      if (!dir.existsSync()) {
        return;
      }
      for (final entity in dir.listSync()) {
        if (entity is! File || entity.path == keep) {
          continue;
        }
        final segments = entity.uri.pathSegments;
        final name = segments.isEmpty ? '' : segments.last;
        if (name.startsWith('$wallpaperFilePrefix-')) {
          entity.deleteSync();
        }
      }
    } on Object catch (error) {
      AppLog.warn('清理旧壁纸失败', error: error);
    }
  }
}
