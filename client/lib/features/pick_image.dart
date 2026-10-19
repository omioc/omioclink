import 'package:flutter/widgets.dart';
import 'package:image_picker/image_picker.dart';

import '../core/app_log.dart';
import '../core/platform.dart';
import 'image_picker_dialog.dart';

/// 让用户挑一张本机图片，返回文件路径；用户取消返回 null。
///
/// 两端走两套东西，因为「能列出照片」这件事在安卓上根本不成立：
///
/// * **桌面**：应用内选图框（为什么不用系统文件框，见 [showImagePickerDialog]
///   的注释——无边框窗口下它会压住主窗口又把它禁用，看起来就是卡死）；
/// * **手机**：系统相册 / 文件选择器。安卓 10 起是分区存储，普通应用既读不到
///   `/storage/emulated/0/DCIM` 也列不出别家应用的目录，自绘的目录浏览器翻进去
///   只会是空的——用户看到的就是「读不到相册」，而且因为压根没申请过权限，
///   也不会弹权限框。系统选择器（SAF / Photo Picker）**不需要任何存储权限**，
///   权限申请这一环根本不存在。
///
/// 拿回来的都是真实文件路径：`image_picker` 会把选中的图复制到应用缓存目录，
/// 调用方可以直接 `File(path)` 读，不必操心 `content://` 这类 URI。
Future<String?> pickImagePath(
  BuildContext context, {
  String title = '选择图片',
  String confirmLabel = '用这张',
  String? initialDirectory,
}) async {
  if (!isMobilePlatform) {
    return showImagePickerDialog(
      context,
      title: title,
      confirmLabel: confirmLabel,
      initialDirectory: initialDirectory,
    );
  }
  try {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    return picked?.path;
  } on Object catch (error) {
    // 系统选择器打不开（个别 ROM 的相册组件缺失、被安全软件拦）：
    // 当成「没选」处理，界面上保持原样，但留一条日志便于事后排查
    AppLog.warn('打开系统相册失败', error: error);
    return null;
  }
}
