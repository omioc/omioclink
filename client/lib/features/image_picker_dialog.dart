import 'dart:io';

import 'package:flutter/material.dart';

import '../core/app_theme.dart';

/// 选图框里认哪些扩展名（小写，带点）。
const Set<String> imagePickerExtensions = <String>{
  '.png',
  '.jpg',
  '.jpeg',
  '.webp',
  '.gif',
  '.bmp',
};

/// 在应用内的选图框里挑一张本机图片；用户取消返回 null。
///
/// 这里**不用系统文件选择框**（`file_selector`）：本应用是无边框自绘窗口，
/// 系统文件框会拿走焦点，却把自己的窗口留在主窗口后面；而它是模态的，主窗口
/// 这时被禁用——用户看到的就是「点一下上传，整个应用卡死」，随后关窗还会因为
/// 模态循环没退出而崩在原生窗口过程里。弹框期间控制台还会跟着刷
/// `device_info_ds.cc: Failed to get deviceUniqueIdUTF8`（WebRTC 枚举采集设备
/// 失败），也只在系统文件框出现的那段时间冒出来。
///
/// 所以壁纸、头像都走这个框：常用位置 + 目录列表 + 预览，全部走 dart:io，
/// 不碰原生模态框。
Future<String?> showImagePickerDialog(
  BuildContext context, {
  String title = '选择图片',
  String confirmLabel = '用这张',
  String? initialDirectory,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _ImagePickerDialog(
      title: title,
      confirmLabel: confirmLabel,
      initialDirectory: initialDirectory,
    ),
  );
}

class _ImagePickerDialog extends StatefulWidget {
  const _ImagePickerDialog({
    required this.title,
    required this.confirmLabel,
    this.initialDirectory,
  });

  final String title;

  /// 确认按钮文案：壁纸是「用这张」，头像是「用这张当头像」。
  /// 同一个框在两处用，文案具体一点才不至于让人怀疑点错了。
  final String confirmLabel;

  /// 上次挑图用的目录；目录不在了就回落到「图片」。
  final String? initialDirectory;

  @override
  State<_ImagePickerDialog> createState() => _ImagePickerDialogState();
}

class _ImagePickerDialogState extends State<_ImagePickerDialog> {
  /// 一次最多列多少条：某些目录（下载、桌面）能有几千项，
  /// 同步遍历 + 全部建行会让对话框卡住，够用就行。
  static const int _maxEntries = 600;

  late String _path;
  late final TextEditingController _pathField;
  List<Directory> _folders = const [];
  List<File> _images = const [];
  String? _error;
  String? _selected;

  @override
  void initState() {
    super.initState();
    _path = _resolveStart();
    _pathField = TextEditingController(text: _path);
    _reload(notify: false);
  }

  @override
  void dispose() {
    _pathField.dispose();
    super.dispose();
  }

  String _resolveStart() {
    final start = widget.initialDirectory;
    if (start != null && Directory(start).existsSync()) {
      return start;
    }
    for (final place in _quickPlaces()) {
      return place.path;
    }
    final home = Platform.environment['USERPROFILE'];
    if (home != null && Directory(home).existsSync()) {
      return home;
    }
    return Directory.current.path;
  }

  /// 常用位置：这几个目录覆盖了绝大多数「我的图片放哪儿」。
  List<({String label, String path})> _quickPlaces() {
    final home = Platform.environment['USERPROFILE'];
    if (home == null || home.isEmpty) {
      return const [];
    }
    final sep = Platform.pathSeparator;
    final candidates = <({String label, String path})>[
      (label: '图片', path: '$home${sep}Pictures'),
      (label: '桌面', path: '$home${sep}Desktop'),
      (label: '下载', path: '$home${sep}Downloads'),
      (label: '文档', path: '$home${sep}Documents'),
    ];
    return [
      for (final place in candidates)
        if (Directory(place.path).existsSync()) place,
    ];
  }

  void _reload({bool notify = true}) {
    final folders = <Directory>[];
    final images = <File>[];
    String? error;
    try {
      final dir = Directory(_path);
      if (!dir.existsSync()) {
        error = '这个目录不存在了';
      } else {
        final entries = dir.listSync(followLinks: false);
        for (final entity in entries) {
          if (entity is Directory) {
            folders.add(entity);
          } else if (entity is File) {
            final name = _baseName(entity.path).toLowerCase();
            final dot = name.lastIndexOf('.');
            if (dot > 0 && imagePickerExtensions.contains(name.substring(dot))) {
              images.add(entity);
            }
          }
        }
        folders.sort((a, b) => _baseName(a.path).compareTo(_baseName(b.path)));
        images.sort((a, b) => _baseName(a.path).compareTo(_baseName(b.path)));
      }
    } on FileSystemException catch (e) {
      error = '打不开这个目录：${e.message}';
    } on Object catch (e) {
      error = '列出目录失败：$e';
    }
    void apply() {
      _folders = folders.take(_maxEntries).toList();
      _images = images.take(_maxEntries).toList();
      _error = error;
      _selected = null;
    }

    if (notify) {
      setState(apply);
    } else {
      apply();
    }
  }

  String _baseName(String path) => path.split(Platform.pathSeparator).last;

  void _open(String path) {
    final target = Directory(path);
    if (!target.existsSync()) {
      setState(() => _error = '这个目录不存在了');
      return;
    }
    setState(() {
      _path = target.path;
      _pathField.text = target.path;
    });
    _reload();
  }

  void _up() {
    final parent = Directory(_path).parent;
    // 盘符根目录的 parent 还是自己：到顶就别再点
    if (parent.path == _path || !parent.existsSync()) {
      return;
    }
    _open(parent.path);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final places = _quickPlaces();

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.image_outlined, size: 17),
          const SizedBox(width: AppSpacing.sm),
          Text(widget.title),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      content: SizedBox(
        width: 720,
        height: 430,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (places.isNotEmpty) ...[
              Wrap(
                spacing: AppSpacing.sm,
                children: [
                  for (final place in places)
                    _PlaceChip(
                      label: place.label,
                      selected: place.path == _path,
                      onTap: () => _open(place.path),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: AppSizes.control,
                    child: TextField(
                      textAlignVertical: TextAlignVertical.center,
                      controller: _pathField,
                      style: AppText.field.copyWith(
                        color: palette.textPrimary,
                        fontSize: 12.5,
                      ),
                      cursorHeight: 15,
                      onSubmitted: _open,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.folder_open_rounded, size: 15),
                        hintText: '目录路径，回车跳转',
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                IconButton(
                  tooltip: '上一级',
                  onPressed: _up,
                  icon: const Icon(Icons.arrow_upward_rounded, size: 16),
                ),
                IconButton(
                  tooltip: '刷新',
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 3, child: _list(palette)),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(flex: 2, child: _preview(palette)),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _selected == null
              ? null
              : () => Navigator.of(context).pop(_selected),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }

  Widget _list(AppPalette palette) {
    final error = _error;
    final rows = <Widget>[
      for (final folder in _folders)
        _EntryRow(
          icon: Icons.folder_rounded,
          label: _baseName(folder.path),
          color: palette.warning,
          onTap: () => _open(folder.path),
        ),
      for (final image in _images)
        _EntryRow(
          icon: Icons.image_outlined,
          label: _baseName(image.path),
          color: palette.textSecondary,
          selected: image.path == _selected,
          onTap: () => setState(() => _selected = image.path),
        ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: palette.panelSubtle,
        borderRadius: AppRadii.medium,
        border: Border.all(color: palette.hairline),
      ),
      child: error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Text(
                  error,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: palette.textMuted,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ),
            )
          : rows.isEmpty
          ? Center(
              child: Text(
                '这个目录里没有图片',
                style: TextStyle(
                  color: palette.textMuted,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              children: rows,
            ),
    );
  }

  Widget _preview(AppPalette palette) {
    final selected = _selected;
    return Container(
      decoration: BoxDecoration(
        color: palette.panelSubtle,
        borderRadius: AppRadii.medium,
        border: Border.all(color: palette.hairline),
      ),
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: selected == null
          ? Center(
              child: Text(
                '选一张图片看预览',
                style: TextStyle(
                  color: palette.textMuted,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: AppRadii.small,
                    // 只看效果，不必按原图解码：缩到 480 宽省内存也更快
                    child: Image.file(
                      File(selected),
                      fit: BoxFit.contain,
                      cacheWidth: 480,
                      errorBuilder: (_, _, _) => Center(
                        child: Text(
                          '这张图看不了',
                          style: TextStyle(
                            color: palette.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _baseName(selected),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: palette.textSecondary,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ],
            ),
    );
  }
}

/// 常用位置的小胶囊。
class _PlaceChip extends StatelessWidget {
  const _PlaceChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadii.pill,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? palette.accentSoft : palette.panel,
          borderRadius: AppRadii.pill,
          border: Border.all(
            color: selected ? palette.accent : palette.hairline,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? palette.accent : palette.textSecondary,
            fontSize: 11.5,
            height: 1.4,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

/// 目录 / 图片的一行。
class _EntryRow extends StatefulWidget {
  const _EntryRow({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool selected;

  @override
  State<_EntryRow> createState() => _EntryRowState();
}

class _EntryRowState extends State<_EntryRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final selected = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 28,
          margin: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          decoration: BoxDecoration(
            color: selected
                ? palette.accentSoft
                : (_hovering ? palette.hover : Colors.transparent),
            borderRadius: AppRadii.small,
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 14, color: widget.color),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected
                        ? palette.accent
                        : (selected || _hovering
                              ? palette.textPrimary
                              : palette.textSecondary),
                    fontSize: 12,
                    height: 1.3,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
