import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../core/app_log.dart';
import '../core/l10n_ext.dart';

/// 把用户选中的图片缩成适合当头像的尺寸。
///
/// 缩放放在客户端做：上传流量小一个量级，服务端也不用为了裁图引入图像库。
/// 服务端仍会兜底校验大小与真实类型，这里只是「尽量传得小」。
class AvatarPicker {
  const AvatarPicker({this.maxSide = 256});

  /// 长边上限。256 足够让 30~64px 的头像在任何 DPI 下都清晰，PNG 通常几十 KB。
  final int maxSide;

  /// 读 [path] 并处理成待上传的 PNG 字节。
  ///
  /// 选文件那一步交给界面层（`showImagePickerDialog`），这里只认路径：
  /// 系统文件选择框（`file_selector`）在无边框窗口上会拿走焦点、把自己的窗口
  /// 留在主窗口后面，而它又是模态的，主窗口这时被禁用——用户看到的就是
  /// 「点一下上传，整个应用卡死」。所以桌面端统一走应用内的选图框。
  ///
  /// 两种失败分得很清楚，界面才能给出准确提示：
  /// * `(bytes: ..., error: null)` —— 处理好了；
  /// * `(bytes: null, error: ...)` —— 这个文件读不了 / 不是能识别的图片。
  Future<({Uint8List? bytes, String? error})> fromPath(String path) async {
    final Uint8List raw;
    try {
      raw = await File(path).readAsBytes();
    } on Object catch (error) {
      AppLog.warn('头像读取失败', error: error);
      return (bytes: null, error: appL10n.dataFileUnreadable);
    }
    if (raw.isEmpty) {
      return (bytes: null, error: appL10n.avatarFileEmpty);
    }
    final bytes = await compress(raw);
    if (bytes == null) {
      return (bytes: null, error: appL10n.dataNotAnImage);
    }
    return (bytes: bytes, error: null);
  }

  /// 按长边缩放到 [maxSide] 并重新编码成 PNG；无法解码时返回 null。
  Future<Uint8List?> compress(Uint8List raw) async {
    if (raw.isEmpty) {
      return null;
    }
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      // 先从头部读尺寸，不整张解码：一张 4000×3000 的照片全解码要几十 MB 内存，
      // 而我们只想要 256px 的缩略图。
      final buffer = await ui.ImmutableBuffer.fromUint8List(raw);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final scale =
          maxSide /
          (descriptor.width > descriptor.height
              ? descriptor.width
              : descriptor.height);
      // 本来就不大就按原尺寸重编码，不放大
      final factor = scale < 1 ? scale : 1.0;
      codec = await descriptor.instantiateCodec(
        targetWidth: (descriptor.width * factor).round().clamp(1, maxSide),
        targetHeight: (descriptor.height * factor).round().clamp(1, maxSide),
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } on Object catch (error) {
      AppLog.warn('图片处理失败', error: error);
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
    }
  }
}
