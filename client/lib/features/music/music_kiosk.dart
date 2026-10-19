import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import '../../core/app_theme.dart';
import '../../core/platform.dart';
import '../../data/music_models.dart';
import '../../music/music_free_library.dart';
import '../../music/music_player.dart';
import '../../musicfree/musicfree_service.dart';
import '../../room/room_music.dart';
import '../../room/room_session.dart';
import '../../signaling/protocol.dart';
import '../../widgets/common.dart';
import 'music_widgets.dart';
import 'now_playing.dart';

/// 点歌台（MusicFree 式）：顶部搜索框 + 左导航（排行榜 / 热门歌单）。
///
/// 搜索不占导航项——上面就是搜索框，清空搜索会回到原来看的那一屏。
///
/// * 数据全部来自 [MusicFreeLibrary]（插件由设置页「音乐插件」管理）；
/// * 队列仍走房间的 [RoomMusicQueue]，右侧面板与底部播放条看到的是同一份；
/// * 服务器元数据（平台能力 / 专题 / 最近点过）已不再参与点歌台。
class MusicKiosk extends StatefulWidget {
  const MusicKiosk({
    super.key,
    required this.library,
    required this.session,
    required this.player,
  });

  final MusicFreeLibrary library;
  final RoomSession session;

  /// 房间播放引擎（应用级单例，由 `CallView` 注入）。
  final MusicPlayer player;

  @override
  State<MusicKiosk> createState() => _MusicKioskState();
}

class _MusicKioskState extends State<MusicKiosk> {
  final TextEditingController _searchController = TextEditingController();
  /// 当前内容视图。默认落在排行榜：搜索由顶部搜索框触发，不再占导航项。
  MusicFreeSection _section = MusicFreeSection.charts;

  /// 搜索之前在看的那一屏（清空搜索时回到它）。
  MusicFreeSection _sectionBeforeSearch = MusicFreeSection.charts;
  bool _navCollapsed = false;

  MusicFreeLibrary get library => widget.library;

  /// 房间播放队列：`RoomSession` 拿到的就是 `AppState` 那份（进房时注入），
  /// 点歌台、右侧队列、底部播放条看到的是同一份数据。
  RoomMusicQueue get queue => widget.session.music;

  MusicPlayer get player => widget.player;

  @override
  void initState() {
    super.initState();
    // 音质是本地偏好；排行榜是左栏一级入口，挂载时预热一轮。
    // 热门歌单要按标签翻页，等用户真的点进来再取（也会按需同步订阅）。
    unawaited(library.loadPreferences());
    unawaited(library.loadCharts());
    // 点歌被服务端拒绝（队列满 / 冷却 / 权限）：弹一次 snackbar，不打扰主视觉
    queue.addListener(_drainMusicError);
  }

  @override
  void dispose() {
    queue.removeListener(_drainMusicError);
    _searchController.dispose();
    super.dispose();
  }

  /// 服务端拒绝点歌时给的提示：取出来弹一次就走。
  void _drainMusicError() {
    final message = queue.consumeError();
    if (message == null || !mounted) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _notify(message);
      }
    });
  }

  // ------------------------------------------------------------------ 动作
  /// 点歌＝把歌加进队列：**不切页面**，行尾的加号会变成勾，这就是全部反馈。
  ///
  /// 只有加不进去（重复 / 队列满）才弹提示——成功时的 toast 既打断人又多余。
  void _enqueue(MusicTrack track) {
    final added = queue.enqueue(track);
    if (added) {
      return;
    }
    _notify(queue.contains(track) ? '这首歌已经在播放队列里了' : '播放队列已满');
  }

  void _enqueueAll(Iterable<MusicTrack> tracks) {
    final added = queue.enqueueAll(tracks);
    _notify(added > 0 ? '已加入 $added 首' : '没有可加入的歌曲（重复或队列已满）');
  }

  void _notify(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  /// 音源报错不再铺在搜索结果上面：搜索框右侧只有一个很小的入口，
  /// 点开才看具体原因（含「已暂时跳过的音源」）。
  Future<void> _showSearchIssues() async {
    final issues = List<String>.of(library.searchWarnings);
    final skipped = List<String>.of(library.searchSkipped);
    if (issues.isEmpty && skipped.isEmpty) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('部分音源没有返回结果'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (issues.isNotEmpty)
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final issue in issues)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: SelectableText(
                              issue,
                              style: TextStyle(
                                color: context.palette.warning,
                                fontSize: 12,
                                height: 1.4,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              if (skipped.isNotEmpty) ...[
                if (issues.isNotEmpty) const SizedBox(height: 4),
                Text(
                  '已暂时跳过：${skipped.map(musicPlatformLabel).join('、')}'
                  '（连续失败，几分钟后自动重试）',
                  style: TextStyle(
                    color: context.palette.textMuted,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                '其它结果不受影响：歌照常能搜、能点。',
                style: TextStyle(color: context.palette.textMuted, fontSize: 11),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              // 用户可能是在榜单页点开这个入口的：先切回搜索结果，再重搜一遍，
              // 否则「重新搜索」看起来什么都没发生（只在后台跑）。
              if (_section != MusicFreeSection.search) {
                setState(() => _section = MusicFreeSection.search);
              }
              unawaited(library.search(library.query, refresh: true));
            },
            child: const Text('重新搜索'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  void _openSection(MusicFreeSection section) {
    library.closeDetail();
    if (section != MusicFreeSection.search) {
      // 记住「搜索之前在看哪一屏」，清空搜索时回到这里
      _sectionBeforeSearch = section;
    }
    setState(() => _section = section);
    switch (section) {
      case MusicFreeSection.search:
        break;
      case MusicFreeSection.charts:
        unawaited(library.loadCharts());
      case MusicFreeSection.sheets:
        unawaited(library.loadTagSections());
    }
  }

  void _submitSearch(String keyword) {
    final text = keyword.trim();
    if (text.isEmpty) {
      return;
    }
    library.closeDetail();
    if (_section != MusicFreeSection.search) {
      _sectionBeforeSearch = _section;
    }
    setState(() => _section = MusicFreeSection.search);
    unawaited(library.search(text));
  }

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: AnimatedBuilder(
        animation: Listenable.merge(<Listenable>[library, queue, player]),
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SearchBar(
              controller: _searchController,
              searching: library.searching,
              onSubmit: _submitSearch,
              onClear: () {
                _searchController.clear();
                library.clearSearch();
                // 清空搜索就回到进来之前那一屏（榜单 / 歌单），不留空结果页
                setState(() => _section = _sectionBeforeSearch);
              },
              // 只有正看着搜索结果时才显示这个入口：切到榜单 / 歌单后，
              // 描述上一次搜索的告警挂在那儿反而是噪音。
              issueCount: _section == MusicFreeSection.search
                  ? library.searchWarnings.length + library.searchSkipped.length
                  : 0,
              onShowIssues: () => unawaited(_showSearchIssues()),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.sm,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _NavRail(
                      section: _section,
                      onChanged: _openSection,
                      collapsed: _navCollapsed,
                      onToggleCollapse: () =>
                          setState(() => _navCollapsed = !_navCollapsed),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(child: _content()),
                    // 手机上 210dp 的队列侧栏是从内容里硬扣出来的（393dp 屏只剩
                    // 150dp 给歌单）：窄屏改成底部播放条上的「队列」按钮弹出
                    if (!useCompactLayout(context)) ...[
                      const SizedBox(width: AppSpacing.md),
                      SizedBox(
                        width: 210,
                        child: _QueuePanel(
                          queue: queue,
                          player: player,
                          onRemove: (track) => queue.remove(track),
                          onClear: queue.clear,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            _KioskNowPlayingBar(
              queue: queue,
              player: player,
              compact: useCompactLayout(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content() {
    // 榜单 / 歌单详情压在最上层：三种模式共用同一套详情。
    if (library.detail != null ||
        library.detailLoading ||
        library.detailError != null) {
      return _DetailPane(
        library: library,
        queue: queue,
        onEnqueue: _enqueue,
        onEnqueueAll: _enqueueAll,
      );
    }
    return switch (_section) {
      MusicFreeSection.search => _SearchPane(
        library: library,
        queue: queue,
        onEnqueue: _enqueue,
      ),
      MusicFreeSection.charts => _ChartsPane(
        library: library,
        onOpen: (sheet) => unawaited(library.openTopList(sheet)),
      ),
      MusicFreeSection.sheets => _SheetsPane(
        library: library,
        onOpen: (sheet) => unawaited(library.openSheet(sheet)),
      ),
    };
  }
}

// --------------------------------------------------------------------------- //
// 搜索栏
// --------------------------------------------------------------------------- //
class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.onSubmit,
    required this.onClear,
    required this.searching,
    this.issueCount = 0,
    this.onShowIssues,
  });

  final TextEditingController controller;
  final ValueChanged<String> onSubmit;
  final VoidCallback onClear;
  final bool searching;

  /// 这一轮没返回结果（或被跳过）的音源数：只用来决定右上角那个小入口。
  final int issueCount;
  final VoidCallback? onShowIssues;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              textAlignVertical: TextAlignVertical.center,
              controller: controller,
              onSubmitted: onSubmit,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                hintText: '搜索歌曲、歌手或歌单',
                prefixIcon: Icon(Icons.search, size: 15),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          FilledButton(
            onPressed: searching ? null : () => onSubmit(controller.text),
            child: const Text('搜索'),
          ),
          if (controller.text.isNotEmpty) ...<
            Widget
          >[
            const SizedBox(width: AppSpacing.xs),
            TextButton(onPressed: onClear, child: const Text('清空')),
          ],
          // 音源报错不占内容区：这里只是一个灰不溜秋的小入口，
          // 不点开就完全不影响搜索结果的排版。
          if (issueCount > 0) ...<Widget>[
            const SizedBox(width: AppSpacing.xs),
            Tooltip(
              message: '部分音源没有返回结果，点击查看原因',
              child: TextButton.icon(
                onPressed: onShowIssues,
                icon: const Icon(Icons.info_outline, size: 13),
                label: Text(
                  '$issueCount 个音源异常',
                  style: const TextStyle(fontSize: 11),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: context.palette.textMuted,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// --------------------------------------------------------------------------- //
// 左导航：只有排行榜 / 热门歌单两个入口（搜索走点歌台上面的搜索框）
// --------------------------------------------------------------------------- //
class _NavRail extends StatelessWidget {
  const _NavRail({
    required this.section,
    required this.onChanged,
    required this.collapsed,
    required this.onToggleCollapse,
  });

  final MusicFreeSection section;
  final ValueChanged<MusicFreeSection> onChanged;
  final bool collapsed;
  final VoidCallback onToggleCollapse;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: collapsed ? 44 : 92,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NavRow(
            icon: Icons.leaderboard_outlined,
            label: collapsed ? '' : '排行榜',
            dense: true,
            selected: section == MusicFreeSection.charts,
            accent: context.palette.accent,
            onTap: () => onChanged(MusicFreeSection.charts),
          ),
          NavRow(
            icon: Icons.local_fire_department_outlined,
            label: collapsed ? '' : '热门歌单',
            dense: true,
            selected: section == MusicFreeSection.sheets,
            accent: context.palette.accent,
            onTap: () => onChanged(MusicFreeSection.sheets),
          ),
          const Spacer(),
          _NavCollapseButton(
            collapsed: collapsed,
            onTap: onToggleCollapse,
          ),
        ],
      ),
    );
  }
}

/// 收起/展开按钮：小圆钮，居中。
class _NavCollapseButton extends StatelessWidget {
  const _NavCollapseButton({required this.collapsed, required this.onTap});

  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: collapsed ? '展开菜单' : '收起菜单',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            height: 28,
            decoration: BoxDecoration(
              color: context.palette.panelSubtle.withValues(alpha: 0.5),
              borderRadius: AppRadii.small,
            ),
            child: Icon(
              collapsed ? Icons.menu_open_rounded : Icons.menu_rounded,
              size: 16,
              color: context.palette.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 胶囊页签（标签 / 分类）：点歌台里所有「一排可选中的小圆角」都用它。
class _PillTab extends StatelessWidget {
  const _PillTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          // 固定高度 + 显式居中：文字在胶囊里才不会随着字体行高忽高忽低
          height: 30,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: selected
                ? context.palette.accentSoft.withValues(alpha: 0.6)
                : context.palette.panel,
            borderRadius: AppRadii.pill,
            border: Border.all(
              color: selected ? context.palette.accent : context.palette.divider,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected
                  ? context.palette.textPrimary
                  : context.palette.textSecondary,
              fontSize: 12,
              height: 1.2,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

// --------------------------------------------------------------------------- //
// 内容：搜索
// --------------------------------------------------------------------------- //
class _SearchPane extends StatelessWidget {
  const _SearchPane({
    required this.library,
    required this.queue,
    required this.onEnqueue,
  });

  final MusicFreeLibrary library;
  final RoomMusicQueue queue;
  final ValueChanged<MusicTrack> onEnqueue;

  /// 类型 tab 的中文名（未知类型直接用插件里的原始 id）。
  static String _searchTypeLabel(String type) => switch (type) {
    'music' => '音乐',
    'album' => '专辑',
    'artist' => '作者',
    'playlist' || 'sheet' => '歌单',
    _ => type,
  };

  /// 「全部音源」的哨兵 id（不会与真实 platform 冲突）。
  static const String _allPlatforms = '__all__';

  @override
  Widget build(BuildContext context) {
    if (!library.hasSearch) {
      return _emptyBeforeSearch(library);
    }
    if (library.searchError != null) {
      return MusicErrorHint(
        message: library.searchError!,
        onRetry: () => unawaited(library.search(library.query)),
      );
    }

    final tracks = library.tracks;
    final types = library.searchTypes;
    final platforms = library.searchPlatforms;
    final isMusic = library.searchType == 'music';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 第一层：搜索类型（音乐 / 专辑 / 作者 / 歌单）——都是插件声明的能力
        if (types.length > 1)
          _PillTabBar(
            key: const ValueKey<String>('search-types'),
            items: <({String id, String label})>[
              for (final type in types)
                (id: type, label: _searchTypeLabel(type)),
            ],
            selectedId: library.searchType,
            keyPrefix: 'search-type',
            onSelected: (type) => unawaited(library.selectSearchType(type)),
          ),
        if (types.length > 1) const SizedBox(height: AppSpacing.xs),
        // 第二层：音源（全部 + 支持该类型的插件）
        if (platforms.length > 1)
          _PillTabBar(
            key: const ValueKey<String>('search-platforms'),
            items: <({String id, String label})>[
              (id: _allPlatforms, label: '全部'),
              for (final platform in platforms)
                (id: platform, label: musicPlatformLabel(platform)),
            ],
            selectedId: library.searchPlatform ?? _allPlatforms,
            keyPrefix: 'search-platform',
            onSelected: (id) => unawaited(
              library.selectSearchPlatform(id == _allPlatforms ? null : id),
            ),
          ),
        if (platforms.length > 1) const SizedBox(height: AppSpacing.sm),
        Expanded(
          child: ListView(
            children: [
              // 音源报错挪到搜索框右边的小入口里（点开才有弹窗），
              // 这里只留一行「还在等几个音源」的轻提示，结果照常往下排。
              MusicSectionTitle(
                text: '「${library.query}」的搜索结果',
                trailing: library.searching && library.searchTotal > 0
                    ? Text(
                        '已收到 ${library.searchDone}/${library.searchTotal} 个音源…',
                        style: TextStyle(
                          color: context.palette.textMuted,
                          fontSize: 11,
                        ),
                      )
                    : null,
              ),
              if (!isMusic)
                _WarningLine(
                  text:
                      '「${_searchTypeLabel(library.searchType)}」的结果暂不支持直接点歌，'
                      '切到「音乐」再点',
                ),
              const SizedBox(height: AppSpacing.sm),
              if (library.searching && tracks.isEmpty)
                const MusicLoading(label: '搜索结果')
              else if (tracks.isEmpty)
                MusicEmptyHint(
                  icon: Icons.search_off,
                  text: '没有找到相关歌曲',
                  hint: library.searchWarnings.isEmpty && library.searchSkipped.isEmpty
                      ? '换个关键词，或换一个音源再试'
                      : '有些音源没返回结果，点右上角看原因',
                )
              else
                for (final track in tracks)
                  MusicSongTile(
                    key: ValueKey<String>('search:${track.key}'),
                    track: track,
                    onTap: isMusic ? () => onEnqueue(track) : null,
                    trailing: isMusic
                        ? MusicAddButton(
                            added: queue.contains(track),
                            onPressed: () => onEnqueue(track),
                          )
                        : null,
                  ),
            ],
          ),
        ),
      ],
    );
  }

  /// 还没搜索时的空态：区分「没装插件」与「插件没有搜索能力」。
  Widget _emptyBeforeSearch(MusicFreeLibrary library) {
    if (!library.hasPlugins) {
      return const MusicEmptyHint(
        icon: Icons.extension_outlined,
        text: '还没有安装音乐插件',
        hint: '到「设置 · 音乐插件」里刷新订阅后再来点歌',
      );
    }
    if (!library.canSearch) {
      return const MusicEmptyHint(
        icon: Icons.search_off,
        text: '插件没有提供搜索能力',
        hint: '当前启用的插件里没有实现 search 方法的，去设置页检查插件',
      );
    }
    return const MusicEmptyHint(
      icon: Icons.search,
      text: '搜索歌曲',
      hint: '输入歌名、歌手或歌单，回车或点「搜索」',
    );
  }
}

// --------------------------------------------------------------------------- //
// 内容：排行榜
class _ChartsPane extends StatefulWidget {
  const _ChartsPane({required this.library, required this.onOpen});

  final MusicFreeLibrary library;
  final ValueChanged<MusicFreeSheet> onOpen;

  @override
  State<_ChartsPane> createState() => _ChartsPaneState();
}

/// 排行榜：顶部按**音源 / 分类**分 tab（可横向滚动），下面对应那一类的榜单竖向滚动。
class _ChartsPaneState extends State<_ChartsPane> {
  /// 当前选中的音源（`group.platform`）。null = 用第一个有榜单的音源。
  String? _platform;

  MusicFreeLibrary get library => widget.library;

  @override
  Widget build(BuildContext context) {
    final groups = library.chartGroups;
    if (library.chartsLoading && groups.isEmpty) {
      return const MusicLoading(label: '排行榜');
    }
    if (groups.isEmpty) {
      final error = library.chartsError;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: MusicEmptyHint(
              icon: Icons.leaderboard_outlined,
              text: error ?? _emptyText(library),
              hint: library.hasPlugins
                  ? '插件没有返回榜单时可以点「重试」，或到设置页检查插件'
                  : '到「设置 · 音乐插件」里刷新订阅后再来点歌',
            ),
          ),
          if (error != null)
            Center(
              child: TextButton(
                onPressed: () => unawaited(library.loadCharts(force: true)),
                child: const Text('重试'),
              ),
            ),
        ],
      );
    }

    // 按音源归组（保持插件返回的顺序）
    final platforms = <String>[];
    final byPlatform = <String, List<MusicFreeTopListGroup>>{};
    for (final group in groups) {
      byPlatform
          .putIfAbsent(group.platform, () {
            platforms.add(group.platform);
            return <MusicFreeTopListGroup>[];
          })
          .add(group);
    }
    // 选中的音源被重载掉（插件变了）就回落到第一个
    final selected = _platform != null && byPlatform.containsKey(_platform)
        ? _platform!
        : platforms.first;
    final selectedGroups = byPlatform[selected]!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (library.chartsError != null)
          _WarningLine(text: library.chartsError!),
        // 音源 tab：横向滚动（鼠标拖拽 / 滚轮都能滚，音源多时一路滑过去）
        _PillTabBar(
          key: const ValueKey<String>('chart-tabs'),
          items: <({String id, String label})>[
            for (final platform in platforms)
              (id: platform, label: musicPlatformLabel(platform)),
          ],
          selectedId: selected,
          keyPrefix: 'chart-tab',
          onSelected: (platform) => setState(() => _platform = platform),
        ),
        const SizedBox(height: AppSpacing.sm),
        // 当前音源下的榜单：卡片网格，竖向滚动
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 每行固定三个卡片：以前宽屏三列、常规两列，卡片显得偏大；
              // 现在门槛降到 340（点歌台里还要让出右侧队列栏），
              // 只有窄到实在放不下三张时才退化成 2 / 1 列。
              final columns = constraints.maxWidth >= 340
                  ? 3
                  : (constraints.maxWidth >= 220 ? 2 : 1);
              final tileWidth = _tileWidth(constraints.maxWidth, columns);
              return CustomScrollView(
                slivers: [
                  for (final group in selectedGroups) ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                        child: MusicSectionTitle(
                          text: group.title,
                          trailing: MusicBadge(
                            text: musicPlatformLabel(group.platform),
                            color: context.palette.accent,
                          ),
                        ),
                      ),
                    ),
                    SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: AppSpacing.md,
                        crossAxisSpacing: AppSpacing.md,
                        mainAxisExtent: tileWidth + _SheetCard.textExtent,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final item = group.items[index];
                          return _SheetCard(
                            key: ValueKey<String>('chart:${item.key}'),
                            sheet: item,
                            seed: index,
                            onTap: () => widget.onOpen(item),
                          );
                        },
                        childCount: group.items.length,
                      ),
                    ),
                    const SliverToBoxAdapter(
                      child: SizedBox(height: AppSpacing.md),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ],
    );
  }


  String _emptyText(MusicFreeLibrary library) =>
      library.hasPlugins ? '插件没有提供排行榜' : '还没有安装音乐插件';
}

/// 顶部一条横向可滚动的 pill tab 条（排行榜的音源 / 热门歌单的标签共用）。
///
/// 桌面端点不动横向 `ListView`：默认 `ScrollBehavior` 不允许鼠标拖拽、滚轮又只会竖着走，
/// 这里两件事都补上——允许鼠标拖拽，并把竖向滚轮映射成横向滚动。
class _PillTabBar extends StatefulWidget {
  const _PillTabBar({
    super.key,
    required this.items,
    required this.selectedId,
    required this.onSelected,
    required this.keyPrefix,
  });

  /// `id` 用于选中判断与 key；`label` 是显示文字。
  final List<({String id, String label})> items;

  final String? selectedId;
  final ValueChanged<String> onSelected;

  /// tab key 的前缀（不同页面各用各的，避免同一个 id 撞 key）。
  final String keyPrefix;

  @override
  State<_PillTabBar> createState() => _PillTabBarState();
}

class _PillTabBarState extends State<_PillTabBar> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 桌面端常见的横向条习惯：滚轮上下 → 内容左右。
  ///
  /// 真正的横向滚动（Shift + 滚轮、触控板横扫，`delta.dx`）交给 `Scrollable` 自己处理，
  /// 这里只接管纯竖向滚轮，免得一次手势滚两倍。
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_controller.hasClients) {
      return;
    }
    final dy = event.scrollDelta.dy;
    if (dy == 0) {
      return;
    }
    final position = _controller.position;
    if (!position.hasContentDimensions || position.maxScrollExtent <= 0) {
      return;
    }
    final next = (_controller.offset + dy).clamp(0.0, position.maxScrollExtent);
    if (next != _controller.offset) {
      _controller.jumpTo(next);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: Listener(
        onPointerSignal: _onPointerSignal,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            scrollbars: false,
            // 鼠标也能拖动滚动（桌面端默认不含 mouse）
            dragDevices: <PointerDeviceKind>{
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.stylus,
              PointerDeviceKind.trackpad,
            },
          ),
          child: ListView.separated(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            itemCount: widget.items.length,
            separatorBuilder: (context, index) =>
                const SizedBox(width: AppSpacing.xs),
            itemBuilder: (context, index) {
              final item = widget.items[index];
              return Center(
                child: _PillTab(
                  key: ValueKey<String>('${widget.keyPrefix}:${item.id}'),
                  label: item.label,
                  selected: item.id == widget.selectedId,
                  onTap: () => widget.onSelected(item.id),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 卡片网格里一格的实际宽度（扣除列间距）。
double _tileWidth(double maxWidth, int columns) =>
    (maxWidth - AppSpacing.md * (columns - 1)) / columns;

/// 一张榜单 / 歌单卡片：大封面在上，标题最多两行，作者在下面用更小的字。
///
/// 不带外边框（参考 MusicFree 的卡片）：靠封面和留白分块，悬停时封面压一层高光。
class _SheetCard extends StatefulWidget {
  const _SheetCard({
    super.key,
    required this.sheet,
    required this.seed,
    required this.onTap,
  });

  /// 封面下方（间距 + 最多两行标题 + 作者）预留的高度。
  static const double textExtent = 58;

  final MusicFreeSheet sheet;

  /// 没有封面时按它取一组渐变底色，避免一排灰块。
  final int seed;

  final VoidCallback onTap;

  @override
  State<_SheetCard> createState() => _SheetCardState();
}

class _SheetCardState extends State<_SheetCard> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final sheet = widget.sheet;
    final creator = sheet.creator;
    final hasCreator = creator != null && creator.isNotEmpty;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 封面是正方形：卡片有多宽，封面就有多大
            final side = constraints.maxWidth;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    MusicCover(
                      url: sheet.coverUrl,
                      size: side,
                      radius: AppRadii.medium,
                      seed: widget.seed,
                    ),
                    if (_hovering)
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.08),
                            borderRadius: AppRadii.medium,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  sheet.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _hovering
                        ? context.palette.accent
                        : context.palette.textPrimary,
                    fontSize: 12.5,
                    height: 1.3,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (hasCreator) ...[
                  const SizedBox(height: 2),
                  Text(
                    creator,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.palette.textMuted,
                      fontSize: 10.5,
                      height: 1.2,
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}


// --------------------------------------------------------------------------- //
// 内容：热门歌单
// --------------------------------------------------------------------------- //
/// 热门歌单：双层 tab —— 第一层音源、第二层该音源下的类别，两层都横向可滚；
/// 下面是卡片网格的歌单。和排行榜共用同一套 pill tab 与卡片。
class _SheetsPane extends StatefulWidget {
  const _SheetsPane({required this.library, required this.onOpen});

  final MusicFreeLibrary library;
  final ValueChanged<MusicFreeSheet> onOpen;

  @override
  State<_SheetsPane> createState() => _SheetsPaneState();
}

class _SheetsPaneState extends State<_SheetsPane> {
  /// 第一层选中的音源（platform）。null = 跟随已选标签 / 第一个音源。
  String? _platform;

  /// 待自动选中的标签 id（`platform:id`）：切音源后保证下面立刻有歌单。
  String? _pendingAutoSelectId;

  MusicFreeLibrary get library => widget.library;

  /// 在下一帧补选一个标签：build 里不能直接改状态。
  void _scheduleAutoSelect(MusicFreeTag tag) {
    final id = '${tag.platform}:${tag.id}';
    if (_pendingAutoSelectId == id) {
      return;
    }
    _pendingAutoSelectId = id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pendingAutoSelectId != id) {
        return;
      }
      _pendingAutoSelectId = null;
      unawaited(library.selectTag(tag));
    });
  }

  @override
  Widget build(BuildContext context) {
    final tags = library.tags;
    if (library.tagsLoading && tags.isEmpty) {
      return const MusicLoading(label: '热门歌单');
    }
    if (tags.isEmpty) {
      final error = library.sheetsError;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: MusicEmptyHint(
              icon: Icons.local_fire_department_outlined,
              text: error ?? _emptyText(library),
              hint: library.hasPlugins
                  ? '插件没有返回歌单标签时可以点「重试」，或到设置页检查插件'
                  : '到「设置 · 音乐插件」里刷新订阅后再来点歌',
            ),
          ),
          if (error != null)
            Center(
              child: TextButton(
                onPressed: () =>
                    unawaited(library.loadTagSections(force: true)),
                child: const Text('重试'),
              ),
            ),
        ],
      );
    }

    // 标签去重：同 platform + id 只留一条（插件重复返回时会出现重复 key）。
    final chips = <MusicFreeTag>[];
    final seenTags = <String>{};
    for (final tag in <MusicFreeTag>[
      ...tags.pinned,
      for (final group in tags.groups) ...group.tags,
    ]) {
      if (seenTags.add('${tag.platform}:${tag.id}')) {
        chips.add(tag);
      }
    }

    // 第一层：音源（保持插件返回的顺序）
    final platforms = <String>[];
    final byPlatform = <String, List<MusicFreeTag>>{};
    for (final tag in chips) {
      byPlatform
          .putIfAbsent(tag.platform, () {
            platforms.add(tag.platform);
            return <MusicFreeTag>[];
          })
          .add(tag);
    }
    final selected = library.selectedTag;
    final platform = _platform != null && byPlatform.containsKey(_platform)
        ? _platform!
        : (selected != null && byPlatform.containsKey(selected.platform)
              ? selected.platform
              : platforms.first);
    final sourceTags = byPlatform[platform]!;
    // 切了音源 / 还没选过类别 → 自动选这个音源下的第一个类别
    if (selected == null || selected.platform != platform) {
      _scheduleAutoSelect(sourceTags.first);
    }

    // 歌单同样去重：同一张歌单被多个插件返回时 key 会撞。
    final sheets = <MusicFreeSheet>[];
    final seenSheets = <String>{};
    for (final sheet in library.sheets) {
      if (seenSheets.add(sheet.key)) {
        sheets.add(sheet);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 第一层：音源
        _PillTabBar(
          key: const ValueKey<String>('sheet-sources'),
          items: <({String id, String label})>[
            for (final item in platforms)
              (id: item, label: musicPlatformLabel(item)),
          ],
          selectedId: platform,
          keyPrefix: 'sheet-source',
          onSelected: (id) => setState(() => _platform = id),
        ),
        const SizedBox(height: AppSpacing.xs),
        // 第二层：当前音源下的类别
        _PillTabBar(
          key: const ValueKey<String>('sheet-tags'),
          items: <({String id, String label})>[
            for (final tag in sourceTags)
              (id: '${tag.platform}:${tag.id}', label: tag.title),
          ],
          selectedId: selected != null && selected.platform == platform
              ? '${selected.platform}:${selected.id}'
              : null,
          keyPrefix: 'sheet-tag',
          onSelected: (id) {
            final tag = sourceTags.firstWhere(
              (item) => '${item.platform}:${item.id}' == id,
            );
            unawaited(library.selectTag(tag));
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        // 歌单：卡片网格，竖向滚动
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 与排行榜一致：每行固定三个卡片，窄窗口才退化
              final columns = constraints.maxWidth >= 340
                  ? 3
                  : (constraints.maxWidth >= 220 ? 2 : 1);
              final tileWidth = _tileWidth(constraints.maxWidth, columns);
              return CustomScrollView(
                slivers: [
                  if (sheets.isEmpty && library.sheetsLoading)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: MusicLoading(label: '歌单'),
                    )
                  else if (sheets.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: MusicEmptyHint(
                        icon: Icons.queue_music,
                        text: library.sheetsError ?? '该分类下暂时没有歌单',
                      ),
                    )
                  else ...[
                    SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: AppSpacing.md,
                        crossAxisSpacing: AppSpacing.md,
                        mainAxisExtent: tileWidth + _SheetCard.textExtent,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final sheet = sheets[index];
                          return _SheetCard(
                            key: ValueKey<String>('sheet:${sheet.key}'),
                            sheet: sheet,
                            seed: index,
                            onTap: () => widget.onOpen(sheet),
                          );
                        },
                        childCount: sheets.length,
                      ),
                    ),
                    SliverToBoxAdapter(child: _loadMoreRow()),
                  ],
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  /// 列表底部：加载中转圈；否则「加载更多」+ 出错提示。
  Widget _loadMoreRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Center(
        child: library.sheetsLoading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (library.sheetsError != null)
                    _WarningLine(text: library.sheetsError!, center: true),
                  TextButton(
                    onPressed: () => unawaited(library.loadMoreSheets()),
                    child: const Text('加载更多'),
                  ),
                ],
              ),
      ),
    );
  }

  String _emptyText(MusicFreeLibrary library) =>
      library.hasPlugins ? '插件没有提供热门歌单' : '还没有安装音乐插件';
}

// --------------------------------------------------------------------------- //
// 内容：详情（榜单 / 歌单共用）
// --------------------------------------------------------------------------- //
class _DetailPane extends StatelessWidget {
  const _DetailPane({
    required this.library,
    required this.queue,
    required this.onEnqueue,
    required this.onEnqueueAll,
  });

  final MusicFreeLibrary library;
  final RoomMusicQueue queue;
  final ValueChanged<MusicTrack> onEnqueue;
  final ValueChanged<Iterable<MusicTrack>> onEnqueueAll;

  @override
  Widget build(BuildContext context) {
    final detail = library.detail;
    if (detail == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _backRow(library),
          Expanded(
            child: library.detailLoading
                ? MusicLoading(label: library.detailLoadingTitle)
                : MusicErrorHint(message: library.detailError ?? '内容加载失败'),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _backRow(library),
        Row(
          children: [
            MusicCover(
              url: detail.sheet.coverUrl,
              size: 56,
              radius: AppRadii.medium,
              seed: detail.sheet.key.hashCode,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      MusicBadge(
                        text: detail.kindLabel,
                        color: context.palette.accent,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          detail.sheet.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.palette.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_subtitle(detail).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        _subtitle(detail),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.palette.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    '共 ${detail.tracks.length} 首${detail.isEnd ? '' : '（还有更多）'}',
                    style: TextStyle(
                      color: context.palette.textMuted,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            OutlinedButton.icon(
              onPressed: detail.tracks.isEmpty
                  ? null
                  : () => onEnqueueAll(detail.tracks),
              icon: const Icon(Icons.playlist_add, size: 16),
              label: const Text('全部加入队列'),
            ),
          ],
        ),
        if (detail.error != null) _WarningLine(text: detail.error!),
        const SizedBox(height: AppSpacing.sm),
        Expanded(
          child: detail.tracks.isEmpty && !library.detailLoading
              ? const MusicEmptyHint(
                  icon: Icons.music_off_outlined,
                  text: '这个列表里还没有歌曲',
                  hint: '插件返回了空列表，换一个榜单或歌单试试',
                )
              : ListView.builder(
                  itemCount: detail.tracks.length + (detail.isEnd ? 0 : 1),
                  itemBuilder: (context, i) {
                    if (i >= detail.tracks.length) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.sm,
                        ),
                        child: Center(
                          child: library.detailLoading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : TextButton(
                                  onPressed: () =>
                                      unawaited(library.loadMoreDetail()),
                                  child: const Text('加载更多'),
                                ),
                        ),
                      );
                    }
                    final track = detail.tracks[i];
                    return MusicSongTile(
                      key: ValueKey<String>('detail:${track.key}'),
                      track: track,
                      rank: detail.isChart ? i + 1 : null,
                      onTap: () => onEnqueue(track),
                      trailing: MusicAddButton(
                        added: queue.contains(track),
                        onPressed: () => onEnqueue(track),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  String _subtitle(MusicFreeDetail detail) {
    final parts = <String>[
      if (detail.sheet.creator != null && detail.sheet.creator!.isNotEmpty)
        detail.sheet.creator!,
      if (detail.sheet.description != null &&
          detail.sheet.description!.isNotEmpty)
        detail.sheet.description!,
    ];
    return parts.join(' · ');
  }

  Widget _backRow(MusicFreeLibrary library) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      onPressed: library.closeDetail,
      icon: const Icon(Icons.arrow_back, size: 16),
      label: const Text('返回'),
    ),
  );
}


/// 一行警示（单个插件失败不影响整体结果，只把原因摆出来）。
class _WarningLine extends StatelessWidget {
  const _WarningLine({required this.text, this.center = false});
  final String text;
  final bool center;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs, bottom: 2),
      child: Text(
        text,
        textAlign: center ? TextAlign.center : TextAlign.start,
        style: TextStyle(color: context.palette.warning, fontSize: 11),
      ),
    );
  }
}

// --------------------------------------------------------------------------- //
// 右侧：房间播放队列
// --------------------------------------------------------------------------- //
class _QueuePanel extends StatelessWidget {
  const _QueuePanel({
    required this.queue,
    required this.player,
    required this.onRemove,
    required this.onClear,
  });

  final RoomMusicQueue queue;
  final MusicPlayer player;
  final ValueChanged<MusicTrack> onRemove;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final items = queue.queue;
    // 服务端模式下队列里就有「当前曲」，播放器还没接上时也照样显示这一行
    final current = player.current ?? queue.nowPlaying;
    final currentEntry = queue.current;
    final canSkip = queue.serverDriven && queue.canSkipCurrent;
    return PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionLabel(
            text: current == null
                ? '房间播放队列 (${items.length})'
                : '等待中 (${items.length})',
            trailing: _actions(items),
          ),
          const SizedBox(height: AppSpacing.xs),
          // 正在播放的那首起播时就从 queue.queue 里取走了，这里显式列出来：
          // 否则用户点完歌会觉得「队列里怎么什么都没有」。
          if (current != null) ...[
            Row(
              children: [
                Icon(Icons.graphic_eq, size: 12, color: context.palette.accent),
                const SizedBox(width: 6),
                Text(
                  '正在播放',
                  style: TextStyle(
                    color: context.palette.accent,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (canSkip)
                  IconButton(
                    onPressed: queue.skip,
                    iconSize: 14,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 24,
                      height: 20,
                    ),
                    tooltip: '切歌（房主或点歌人）',
                    icon: Icon(
                      Icons.skip_next,
                      color: context.palette.textSecondary,
                    ),
                  ),
                if (player.status == MusicPlayerStatus.resolving)
                  const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (player.status == MusicPlayerStatus.error)
                  Icon(
                    Icons.error_outline,
                    size: 12,
                    color: context.palette.danger,
                  ),
              ],
            ),
            const SizedBox(height: 2),
            MusicSongTile(
              track: current,
              dense: true,
              showPlatform: false,
              playing: player.playing,
              // 谁点的这首：房主切歌前能看清切的是谁的
              note: _requesterNote(currentEntry),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          Expanded(
            child: items.isEmpty
                ? MusicEmptyHint(
                    icon: Icons.queue_music,
                    text: current == null ? '队列还是空的' : '还没有下一首',
                    hint: '挑一首喜欢的歌，大家一起听',
                  )
                : ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final track = items[i];
                      final entry = _entryAt(i);
                      // 服务端只允许「本人或房主」删自己的点歌：没权限就别露按钮
                      final removable =
                          entry == null || queue.canRemoveEntry(entry);
                      return MusicSongTile(
                        track: track,
                        dense: true,
                        showPlatform: false,
                        note: _requesterNote(entry),
                        trailing: removable
                            ? IconButton(
                                onPressed: () => onRemove(track),
                                iconSize: 16,
                                tooltip: '从队列移除',
                                icon: Icon(
                                  Icons.close,
                                  color: context.palette.textMuted,
                                ),
                              )
                            : null,
                      );
                    },
                  ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            _footerHint(),
            style: TextStyle(color: context.palette.textMuted, fontSize: 10),
          ),
        ],
      ),
    );
  }

  /// 头部动作：清空（只有房主；切歌挪到了「正在播放」那一行）。
  ///
  /// 服务端会再校验一次权限，这里只负责别把点了必然失败的按钮摆出来。
  Widget _actions(List<MusicTrack> items) {
    if (items.isEmpty || !queue.canClear) {
      return const SizedBox.shrink();
    }
    return TextButton(
      onPressed: onClear,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        minimumSize: const Size(0, 24),
      ),
      child: const Text('清空', style: TextStyle(fontSize: 11)),
    );
  }

  /// 服务端模式下第 [index] 行对应的条目；本地模式没有条目（也就没有点歌人）。
  MusicEntry? _entryAt(int index) {
    if (!queue.serverDriven) {
      return null;
    }
    final entries = queue.entries;
    return index < entries.length ? entries[index] : null;
  }

  /// 「点歌人 小明」：本地模式不显示（那一层没有点歌人概念）。
  String? _requesterNote(MusicEntry? entry) {
    if (entry == null) {
      return null;
    }
    final name = entry.requestedBy.displayName.trim();
    final who = name.isEmpty ? '匿名' : name;
    return '点歌人 ${queue.isMine(entry) ? '$who（你）' : who}';
  }

  /// 底部一行说明：服务端模式下顺便当权限提示。
  String _footerHint() {
    if (!queue.serverDriven) {
      return '选中喜欢的歌曲，加入房间播放队列和大家一起听吧！';
    }
    if (queue.isOwner) {
      return '你是房主：可以切歌、清空队列，也能移除别人点的歌。';
    }
    return '每人最多 2 首；点歌人可以切自己点的歌，清空队列需要房主。';
  }
}

// --------------------------------------------------------------------------- //
// 底部：常驻「正在播放」条
// --------------------------------------------------------------------------- //
/// 与 `now_playing.dart` 的 `NowPlayingBar` 同一套视觉，但只依赖队列与播放器
/// （点歌台的音源已经换成 MusicFree，不再持有旧的 `MusicLibrary`）。
class _KioskNowPlayingBar extends StatelessWidget {
  const _KioskNowPlayingBar({
    required this.queue,
    required this.player,
    this.compact = false,
  });

  final RoomMusicQueue queue;
  final MusicPlayer player;

  /// 手机窄屏：音量条与队列侧栏让位，队列改成按钮弹出
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final current = player.current ?? queue.nowPlaying;
    final upcoming = current == null && !queue.isEmpty ? queue.queue.first : null;
    final track = current ?? upcoming;
    // 「按钮该画暂停还是播放」只能看播放器状态。以前这里取的是 `current != null`
    // （= 有没有当前曲目），于是按下暂停后声音停了、图标还挂在 pause 上，
    // 用户会以为按钮没生效——就是这条。
    final hasTrack = current != null;
    final playing = hasTrack && player.playing;
    final paused = hasTrack && !player.playing;
    // 播放失败 / 音源不可用都要落在这条上：以前它们只写进日志，
    // 用户看到的就是「点了没反应」。
    final error = player.error ?? (track == null ? player.sourceError : null);

    return Container(
      // 固定高度，和左栏用户页脚同档（AppSizes.bottomBar）：两条分隔线才对得齐
      height: AppSizes.bottomBar,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      decoration: BoxDecoration(
        color: context.palette.sidebar,
        border: Border(top: BorderSide(color: context.palette.divider)),
      ),
      child: Row(
        children: [
          if (track == null)
            Icon(
              Icons.library_music_outlined,
              size: 22,
              color: context.palette.textMuted,
            )
          else
            MusicCover(url: track.coverUrl, size: 40, seed: track.id.hashCode),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: track == null
                ? _emptySummary(context, error)
                : _trackSummary(
                    context,
                    track,
                    playing: playing,
                    paused: paused,
                    error: error,
                  ),
          ),
          const SizedBox(width: AppSpacing.sm),
          _transportControls(context, playing: playing),
          if (compact)
            IconButton(
              tooltip: '播放队列',
              onPressed: () => _openQueueSheet(context),
              iconSize: 18,
              icon: Icon(
                Icons.queue_music_rounded,
                color: context.palette.textSecondary,
              ),
            )
          else ...[
            const SizedBox(width: AppSpacing.md),
            PlayerVolumeControl(player: player, label: '我的音量'),
          ],
        ],
      ),
    );
  }

  /// 手机上的播放队列：侧栏放不下，改成底部面板（移除/清空都在里面）。
  Future<void> _openQueueSheet(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.palette.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.6,
        child: _QueuePanel(
          queue: queue,
          player: player,
          onRemove: (track) => queue.remove(track),
          onClear: queue.clear,
        ),
      ),
    );
  }
  Widget _emptySummary(BuildContext context, String? error) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '还没有人点歌',
          style: TextStyle(
            color: context.palette.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          error ?? '在点歌台挑一首加入播放队列，房间一起听',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: error == null ? context.palette.textMuted : context.palette.danger,
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  Widget _trackSummary(
    BuildContext context,
    MusicTrack track, {
    required bool playing,
    required bool paused,
    required String? error,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                track.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.palette.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            MusicBadge(
              // 三态：在播 / 已暂停 / 还没轮到它。暂停时不能沿用「即将播放」，
              // 那是给「有下一首但还没开始」的队列看的。
              text: playing ? '同步播放中' : (paused ? '已暂停' : '即将播放'),
              color: playing
                  ? context.palette.success
                  : context.palette.textSecondary,
              icon: playing ? Icons.link : null,
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          error ??
              <String>[
                if (track.artistLabel.isNotEmpty) track.artistLabel,
                musicPlatformLabel(track.platform),
              ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: error == null ? context.palette.textMuted : context.palette.danger,
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  Widget _transportControls(
    BuildContext context, {
    required bool playing,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: playing ? '暂停' : '播放',
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: context.palette.panelSubtle,
              shape: BoxShape.circle,
            ),
            child: IconButton(
              onPressed: () => unawaited(player.togglePlayPause()),
              iconSize: 20,
              icon: Icon(
                playing ? Icons.pause : Icons.play_arrow,
                color: context.palette.textPrimary,
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        Tooltip(
          message: '下一首',
          child: IconButton(
            onPressed: () => unawaited(player.playNext()),
            iconSize: 18,
            icon: Icon(Icons.skip_next, color: context.palette.textSecondary),
          ),
        ),
      ],
    );
  }
}
