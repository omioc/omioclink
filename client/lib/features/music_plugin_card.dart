import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../core/l10n_ext.dart';
import '../music/music_free_library.dart';
import '../musicfree/musicfree_plugins.dart';
import '../musicfree/musicfree_service.dart';
import '../musicfree/plugin_models.dart';
import '../widgets/common.dart';
import 'dialogs.dart';

/// 「音乐插件」卡片：订阅同步 + 插件启用/排序/卸载/配置 + 音质。
///
/// 设置页与点歌台左侧「插件」用的是**同一个组件**：插件操作只有一套逻辑，
/// 两处入口看到的内容、按钮、失败提示才不会有偏差（以前它只存在于设置页）。
///
/// 数据全部来自 [MusicFreeLibrary]；订阅地址由服务器下发（`AppState`），
/// 这里**不发请求**，只调 [onRefreshSubscription]。
class MusicPluginCard extends StatefulWidget {
  const MusicPluginCard({
    super.key,
    required this.library,
    this.syncing = false,
    this.subscriptionUrls = const <String>[],
    this.onRefreshSubscription,
  });

  final MusicFreeLibrary library;

  /// `AppState.musicSyncing`：订阅同步/更新全部进行中。
  final bool syncing;

  /// 服务器下发的订阅地址（只用于展示与空态提示）。
  final List<String> subscriptionUrls;

  /// 刷新订阅（接到 `AppState.refreshMusicPlugins(force: true)`）。
  final Future<void> Function()? onRefreshSubscription;

  @override
  State<MusicPluginCard> createState() => _MusicPluginCardState();
}

class _MusicPluginCardState extends State<MusicPluginCard> {
  MusicFreeLibrary get library => widget.library;

  bool get _busy => widget.syncing || library.syncing;

  // 刻意不在 initState 里自动装载插件：装载要起 worker、把插件源码装进 QuickJS，
  // 是一次实打实的 CPU/IO 活（字节码缓存之后快了很多，但仍然不该在打开这一页时
  // 偷偷跑一遍）。装载只由用户显式点「刷新订阅」触发，可预期、可取消。

  @override
  void initState() {
    super.initState();
    // 「刷新订阅」要先把订阅清单摆给用户选，再只装选中的那些。弹框需要
    // BuildContext，所以由这张卡片挂到 library 上。
    //
    // 设置页与点歌台可能同时挂着这张卡片（一个在后台）：谁最后挂上谁接管，
    // 两者弹的是同一个选择框，行为一致；卸载时只清掉「还指向自己」的那一个，
    // 免得先卸载的那份把另一份的入口也抹掉。
    library.pickSubscriptionEntries = _pickEntries;
  }

  @override
  void dispose() {
    if (library.pickSubscriptionEntries == _pickEntries) {
      library.pickSubscriptionEntries = null;
    }
    super.dispose();
  }

  Future<Set<String>?> _pickEntries(
    List<MusicFreeSubscriptionEntry> entries,
    Set<String> preselected,
  ) {
    return showPluginPickerDialog(
      context,
      entries: entries,
      preselected: preselected,
    );
  }

  Future<void> _refresh() async {
    final action = widget.onRefreshSubscription;
    if (action == null) {
      return;
    }
    await action();
  }

  Future<void> _confirmUninstall(MusicFreePlugin plugin) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.settingsPluginUninstallTitle),
        content: Text(l10n.settingsPluginUninstallMessage(plugin.platform)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.palette.danger,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.settingsPluginUninstall),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await library.uninstallPlugin(plugin.hash);
    }
  }

  /// 插件的用户自定义变量（MusicFree 的 `IUserVariable`）。
  Future<void> _editVariables(MusicFreePlugin plugin) async {
    final l10n = context.l10n;
    final current = library.userVariablesOf(plugin.platform);
    final controllers = <String, TextEditingController>{
      for (final variable in plugin.userVariables)
        variable.key: TextEditingController(text: current[variable.key] ?? ''),
    };
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.settingsPluginConfigure(plugin.platform)),
        content: SizedBox(
          // 手机弹窗可用宽只有屏宽减去边距：420 会被压扁，按可用宽封顶
          width: MediaQuery.sizeOf(context).width > 500
              ? 420
              : MediaQuery.sizeOf(context).width - 96,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final variable in plugin.userVariables) ...[
                  Text(
                    variable.name.isEmpty ? variable.key : variable.name,
                    style: TextStyle(
                      color: context.palette.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  if (variable.hint.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        variable.hint,
                        style: TextStyle(
                          color: context.palette.textMuted,
                          fontSize: 11,
                          height: 1.4,
                        ),
                      ),
                    ),
                  const SizedBox(height: 4),
                  TextField(
                    textAlignVertical: TextAlignVertical.center,
                    controller: controllers[variable.key],
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: variable.key,
                    ),
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.commonSave),
          ),
        ],
      ),
    );
    if (saved == true) {
      await library.savePluginVariables(plugin.hash, <String, String>{
        for (final variable in plugin.userVariables)
          variable.key: controllers[variable.key]?.text.trim() ?? '',
      });
    }
    for (final controller in controllers.values) {
      controller.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: library,
      builder: (context, _) {
        final plugins = library.plugins;
        return PanelCard(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 手机上（点歌台右栏、设置页）卡片内容宽只有两百多 dp：小标题右边那两个
              // 按钮、插件行里的「开关 + 4 个按钮」都会把一行撑爆，看上去就是一堆黄黑
              // 溢出条。这里按**卡片内容宽**切成竖排，桌面宽布局维持原样。
              final compact = constraints.maxWidth < 320;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(compact),
                  const SizedBox(height: AppSpacing.sm),
                  _kv(
                    context,
                    context.l10n.pluginWord,
                    plugins.isEmpty
                        ? context.l10n.settingsPluginsNone
                        : context.l10n.settingsPluginsCount(
                            plugins.length,
                            library.enabledPlugins.length,
                          ),
                  ),
                  _kv(
                    context,
                    context.l10n.settingsSubscriptionUrls,
                    widget.subscriptionUrls.isEmpty
                        ? context.l10n.settingsSubscriptionNotProvided
                        : widget.subscriptionUrls.join(
                            context.l10n.connectListSeparator,
                          ),
                  ),
                  _qualityRow(),
                  if (library.syncMessage != null)
                    _hintText(library.syncMessage!, context.palette.textMuted),
                  if (library.syncError != null)
                    _hintText(
                      context.l10n.settingsPluginsSyncFailed(library.syncError!),
                      context.palette.danger,
                    ),
                  const SizedBox(height: AppSpacing.sm),
                  if (plugins.isEmpty)
                    _emptyHint()
                  else
                    for (var i = 0; i < plugins.length; i += 1)
                      _pluginBlock(
                        plugins[i],
                        i,
                        plugins.length,
                        compact: compact,
                      ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    context.l10n.settingsPluginsHint(
                      MusicFreePlugins.defaultSelectionSize,
                    ),
                    style: TextStyle(
                      color: context.palette.textMuted,
                      fontSize: 11,
                      height: 1.5,
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  /// 小标题 + 「刷新订阅 / 全部更新」。
  ///
  /// 宽的时候按钮挂在标题右侧；窄的时候按钮换到标题下面一行（用 Wrap，日 / 韩文案
  /// 更长也不会溢出）。
  Widget _header(bool compact) {
    final l10n = context.l10n;
    final refresh = TextButton.icon(
      onPressed: _busy || widget.onRefreshSubscription == null
          ? null
          : _refresh,
      icon: _busy
          ? const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.sync, size: 16),
      // 装载期间把文案也换掉：只把按钮变灰不够明显，
      // 用户会以为「点了没反应」，然后继续点
      label: Text(
        _busy ? l10n.settingsPluginsLoading : l10n.settingsPluginsRefreshSubscription,
      ),
    );
    final updateAll = TextButton(
      onPressed: _busy || library.plugins.isEmpty
          ? null
          : () => unawaited(library.updateAllPlugins()),
      child: Text(l10n.settingsPluginsUpdateAll),
    );
    if (!compact) {
      return SectionLabel(
        text: l10n.settingsMusicPlugins,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            refresh,
            const SizedBox(width: AppSpacing.xs),
            updateAll,
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(text: l10n.settingsMusicPlugins),
        Wrap(
          spacing: AppSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [refresh, updateAll],
        ),
      ],
    );
  }

  Widget _qualityRow() {
    final l10n = context.l10n;
    return Row(
      children: [
        SizedBox(
          width: 84,
          child: Text(
            l10n.settingsQuality,
            style: TextStyle(color: context.palette.textMuted, fontSize: 11),
          ),
        ),
        DropdownButton<MusicFreeQuality>(
          value: library.quality,
          isDense: true,
          underline: const SizedBox.shrink(),
          style: TextStyle(color: context.palette.textSecondary, fontSize: 12),
          items: [
            for (final quality in MusicFreeQuality.values)
              DropdownMenuItem<MusicFreeQuality>(
                value: quality,
                child: Text(quality.label),
              ),
          ],
          onChanged: (next) {
            if (next != null) {
              unawaited(library.setQuality(next));
            }
          },
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            l10n.settingsQualityHint,
            style: TextStyle(color: context.palette.textMuted, fontSize: 11),
          ),
        ),
      ],
    );
  }

  Widget _emptyHint() {
    final l10n = context.l10n;
    // 两种空态各写一句完整的句子：把「前缀 + 后缀」拼起来在日 / 韩里语序不成立
    final message = widget.subscriptionUrls.isEmpty
        ? l10n.settingsPluginsNoSubscription
        : l10n.settingsPluginsEmptyHint;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          Icon(
            Icons.extension_outlined,
            size: 16,
            color: context.palette.textMuted,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: context.palette.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 一个插件块。
  ///
  /// [compact]（卡片内容宽 < 320，手机上就是这种情况）时「名称 + 详情」与「开关 +
  /// 4 个按钮」不可能挤在一行，改成上下两行：上行信息 + 开关，下行操作按钮用 Wrap
  /// （日 / 韩文案更长时自己换行，不会溢出）。宽布局仍是原来那一行。
  Widget _pluginBlock(
    MusicFreePlugin plugin,
    int index,
    int total, {
    required bool compact,
  }) {
    final l10n = context.l10n;
    final source = _sourceOf(plugin);
    final details = <String>[
      plugin.subtitle,
      if (source.isNotEmpty) source,
      l10n.settingsPluginMethodsCount(plugin.supportedMethods.length),
    ].join(' · ');

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                plugin.platform,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.palette.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (!plugin.enabled) ...[
              const SizedBox(width: 6),
              Text(
                l10n.settingsPluginDisabled,
                style: TextStyle(color: context.palette.warning, fontSize: 11),
              ),
            ],
          ],
        ),
        const SizedBox(height: 2),
        Text(
          details,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: context.palette.textMuted, fontSize: 11),
        ),
      ],
    );

    // 手机上这一行固定宽度太贵：把两个排序按钮收成 32dp 的紧凑点击区
    final moveUp = IconButton(
      onPressed: _busy || index <= 0
          ? null
          : () => unawaited(library.movePlugin(plugin.hash, -1)),
      iconSize: 16,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      tooltip: l10n.settingsPluginMoveUp,
      icon: const Icon(Icons.arrow_upward),
    );
    final moveDown = IconButton(
      onPressed: _busy || index >= total - 1
          ? null
          : () => unawaited(library.movePlugin(plugin.hash, 1)),
      iconSize: 16,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      tooltip: l10n.settingsPluginMoveDown,
      icon: const Icon(Icons.arrow_downward),
    );
    final configure = plugin.userVariables.isEmpty
        ? null
        : TextButton(
            onPressed: _busy ? null : () => unawaited(_editVariables(plugin)),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
            ),
            child: Text(
              l10n.settingsPluginConfigureAction,
              style: const TextStyle(fontSize: 11),
            ),
          );
    final uninstall = TextButton(
      onPressed: _busy ? null : () => unawaited(_confirmUninstall(plugin)),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 32),
      ),
      child: Text(
        l10n.settingsPluginUninstall,
        style: TextStyle(fontSize: 11, color: context.palette.danger),
      ),
    );
    final toggle = Switch(
      value: plugin.enabled,
      onChanged: _busy
          ? null
          : (next) => unawaited(library.setPluginEnabled(plugin.hash, next)),
    );

    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.xs),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: context.palette.panelSubtle.withValues(alpha: 0.35),
        borderRadius: AppRadii.small,
        border: Border.all(color: context.palette.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (compact) ...[
            Row(children: [Expanded(child: info), toggle]),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                moveUp,
                moveDown,
                ?configure,
                uninstall,
              ],
            ),
          ] else
            Row(
              children: [
                Expanded(child: info),
                moveUp,
                moveDown,
                ?configure,
                uninstall,
                toggle,
              ],
            ),
          if (plugin.loadError != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                l10n.settingsPluginLoadFailed(plugin.loadError!),
                style: TextStyle(color: context.palette.danger, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  /// 插件来源只显示域名，完整 URL 太长。
  String _sourceOf(MusicFreePlugin plugin) {
    final url = plugin.srcUrl.trim();
    if (url.isEmpty) {
      return context.l10n.settingsPluginLocalInstall;
    }
    return Uri.tryParse(url)?.host ?? url;
  }

  Widget _hintText(String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 11, height: 1.5),
      ),
    );
  }
}

/// 一行「标签 : 内容」（设置页与插件页共用同一套排版）。
Widget _kv(BuildContext context, String label, String value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 3),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 84,
        child: Text(
          label,
          style: TextStyle(
            color: context.palette.textMuted,
            fontSize: 11.5,
            height: 1.6,
          ),
        ),
      ),
      Expanded(
        child: Text(
          value,
          style: TextStyle(
            color: context.palette.textSecondary,
            fontSize: 12,
            height: 1.5,
          ),
        ),
      ),
    ],
  ),
);
