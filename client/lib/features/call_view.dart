import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../core/app_theme.dart';
import '../core/formatting.dart';
import '../core/l10n_ext.dart';
import '../core/platform.dart';
import '../media/media_models.dart';
import '../room/room_models.dart';
import '../room/room_session.dart';
import '../signaling/protocol.dart';
import '../widgets/avatar.dart';
import '../widgets/common.dart';
import 'dialogs.dart';
import 'music/music_kiosk.dart';
import 'music/now_playing.dart';
import 'screen_fullscreen.dart';

/// 通话视图：成员条 + （屏幕共享 / 点歌台）两个页签 + 控制条。
///
/// * 「屏幕共享」页：房间氛围音卡片 + 共享画面 + 缩略图条 + 聊天面板；
/// * 「点歌台」页：搜索 / 推荐 / 歌单 / 排行榜 / 最近点过 + 右侧播放队列 +
///   底部正在播放条。
///
/// 服务器没开音乐元数据聚合（`/server/info` 的 `musicEnabled=false`）时不显示
/// 点歌台入口，界面与之前完全一致。
class CallView extends StatefulWidget {
  const CallView({super.key, required this.session});

  final RoomSession session;

  @override
  State<CallView> createState() => _CallViewState();
}

class _CallViewState extends State<CallView> {
  final _chatController = TextEditingController();
  final _chatScroll = ScrollController();

  /// 当前页签：false = 屏幕共享，true = 点歌台。
  bool _kioskMode = false;

  @override
  void dispose() {
    _chatController.dispose();
    _chatScroll.dispose();
    super.dispose();
  }

  RoomSession get session => widget.session;

  Future<void> _toggleScreenShare() async {
    final state = context.read<AppState>();
    if (session.phase != RoomPhase.active) {
      return;
    }
    if (session.selfMember?.sharing ?? false) {
      await session.stopScreenShare();
      return;
    }
    final source = await showScreenSourceDialog(context, state.media);
    if (source == null) {
      return;
    }
    await session.startScreenShare(
      sourceId: source.id,
      withSystemAudio: source.withSystemAudio,
      policy: source.policy,
    );
  }

  @override
  Widget build(BuildContext context) {
    final members = session.members;
    final sharer = session.activeSharer;
    final selfSharing = session.selfMember?.sharing ?? false;
    // 只订阅「点歌台是否可用」这一个布尔值：AppState 每 5 秒会因为房间轮询通知，
    // 整页 watch 会让通话界面跟着白重建。
    final musicEnabled = context.select<AppState, bool>(
      (state) => state.serverInfo?.musicEnabled ?? false,
    );
    final state = context.read<AppState>();
    final music = state.music;
    final showKiosk = musicEnabled && _kioskMode;

    // 手机窄屏：三栏式的「画面 + 288 聊天栏」并排放不下，改成画面全宽 + 聊天面板
    final compact = useCompactLayout(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(session: session, compact: compact),
        _MemberStrip(members: members, session: session, compact: compact),
        if (musicEnabled)
          _RoomTabs(
            kiosk: showKiosk,
            onChanged: (kiosk) => setState(() => _kioskMode = kiosk),
          ),
        if (showKiosk)
          Expanded(
            child: MusicKiosk(
              library: music,
              session: session,
              player: state.musicPlayer,
              favorites: state.musicFavorites,
            ),
          )
        else ...[
          if (musicEnabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.page,
                0,
                AppSpacing.page,
                AppSpacing.sm,
              ),
              child: AmbientCard(
                queue: session.music,
                player: state.musicPlayer,
                favorites: state.musicFavorites,
                // 窄屏放不下「封面 + 标题 + 传输 + 音量」：音量条让位
                compact: compact,
              ),
            ),
          Expanded(
            child: compact
                ? _CompactStageArea(
                    session: session,
                    sharer: sharer,
                    selfSharing: selfSharing,
                    controller: _chatController,
                    scrollController: _chatScroll,
                  )
                : Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.page,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: _Stage(
                            session: session,
                            sharer: sharer,
                            selfSharing: selfSharing,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        SizedBox(
                          width: 288,
                          child: _ChatPanel(
                            session: session,
                            controller: _chatController,
                            scrollController: _chatScroll,
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
        // 点歌台整屏都是歌曲浏览：底部那排通话操作在这里用不到，
        // 收起来正好把这段高度让给点歌台
        if (!showKiosk)
          _ControlBar(
            session: session,
            onToggleShare: _toggleScreenShare,
            compact: compact,
          ),
      ],
    );
  }
}

/// 房间内容区的页签：屏幕共享 / 点歌台（视觉沿用左栏 `_ScopeTabs` 的高亮方式）。
class _RoomTabs extends StatelessWidget {
  const _RoomTabs({required this.kiosk, required this.onChanged});

  final bool kiosk;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        0,
        AppSpacing.page,
        10,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          height: 34,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            // 槽底：贴壁纸时舞台是透明的，用 track 才不会变成一个空框
            color: context.palette.track,
            borderRadius: AppRadii.medium,
            border: Border.all(color: context.palette.hairline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _tab(
                context,
                label: context.l10n.callTabScreenShare,
                icon: Icons.desktop_windows_outlined,
                selected: !kiosk,
                onTap: () => onChanged(false),
              ),
              const SizedBox(width: 3),
              _tab(
                context,
                label: context.l10n.callTabMusic,
                icon: Icons.library_music_outlined,
                selected: kiosk,
                onTap: () => onChanged(true),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tab(
    BuildContext context, {
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: selected ? context.palette.panelElevated : Colors.transparent,
            borderRadius: AppRadii.small,
            border: Border.all(
              color: selected ? context.palette.divider : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 14,
                color: selected ? context.palette.accent : context.palette.textMuted,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: selected
                      ? context.palette.textPrimary
                      : context.palette.textMuted,
                  fontSize: 12.5,
                  height: 1.2,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.session, this.compact = false});

  final RoomSession session;

  /// 手机窄屏：只留房名 + 人数 + 菜单，其余状态收进菜单/成员条
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final room = session.room;
    return Container(
      height: compact ? 52 : AppSizes.pageHeader,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.palette.hairline)),
      ),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: context.palette.accent.withValues(alpha: 0.13),
              borderRadius: AppRadii.small,
            ),
            child: Icon(
              Icons.forum_rounded,
              size: 14,
              color: context.palette.accent,
            ),
          ),
          const SizedBox(width: 10),
          // 左侧这一组整体吃掉中段空间：右侧的码率 / 菜单 / 离开才能真的贴到最右
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    room?.name ?? context.l10n.callRoomFallbackName,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.pageTitle,
                  ),
                ),
                // 手机上这一组会把房名挤到几十 dp：只留房名，人数看成员条
                if (!compact) ...[
                  const SizedBox(width: 10),
                  Icon(
                    Icons.group_rounded,
                    size: 13,
                    color: context.palette.textMuted.withValues(alpha: 0.8),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    formatCapacity(
                      session.members.length,
                      room?.capacity ?? session.members.length,
                    ),
                    style: TextStyle(
                      color: context.palette.textMuted,
                      fontSize: 11.5,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(width: 12),
                  StatusDot(color: context.palette.success, size: 5),
                  const SizedBox(width: 6),
                  Text(
                    context.l10n.callDirectConnected(
                      session.connectedPeerCount,
                      session.peerCount,
                    ),
                    style: TextStyle(
                      color: context.palette.textMuted,
                      fontSize: 11.5,
                      height: 1.2,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (!compact && session.stats.outgoingKbps != null) ...[
            Icon(
              Icons.arrow_upward_rounded,
              size: 12,
              color: context.palette.textMuted.withValues(alpha: 0.9),
            ),
            const SizedBox(width: 3),
            Text(
              formatKbps(session.stats.outgoingKbps),
              style: TextStyle(
                color: context.palette.textMuted,
                fontSize: 11,
                height: 1.2,
              ),
            ),
          ],
          const SizedBox(width: 6),
          PopupMenuButton<String>(
            tooltip: context.l10n.callMore,
            iconSize: 16,
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (value) async {
              final state = context.read<AppState>();
              switch (value) {
                case 'recover':
                  await session.recoverConnections();
                case 'diagnostics':
                  await showDiagnosticsDialog(context);
                case 'leave':
                  await state.leaveRoom();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                value: 'recover',
                child: Text(context.l10n.callReconnectAll),
              ),
              PopupMenuItem<String>(
                value: 'diagnostics',
                child: Text(context.l10n.callDiagnostics),
              ),
              PopupMenuItem<String>(
                value: 'leave',
                child: Text(context.l10n.callLeaveRoom),
              ),
            ],
          ),
          const SizedBox(width: 4),
          if (compact)
            IconButton(
              tooltip: context.l10n.callLeaveRoom,
              onPressed: () => context.read<AppState>().leaveRoom(),
              icon: Icon(
                Icons.logout_rounded,
                size: 18,
                color: context.palette.danger,
              ),
            )
          else
            OutlinedButton.icon(
              onPressed: () => context.read<AppState>().leaveRoom(),
              icon: const Icon(Icons.logout_rounded, size: 14),
              label: Text(context.l10n.callLeave),
            ),
        ],
      ),
    );
  }
}

class _MemberStrip extends StatelessWidget {
  const _MemberStrip({
    required this.members,
    required this.session,
    this.compact = false,
  });

  final List<RoomMemberView> members;
  final RoomSession session;

  /// 手机窄屏：成员卡矮一档，把纵向空间让给画面
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: compact ? 84 : 96,
      // builder 而不是 children 列表：进/离房、说话状态变化都会重建这一条，
      // 成员多了（房间上限 8 人）没必要每次把所有成员卡都重新构造一遍。
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          8,
          AppSpacing.page,
          6,
        ),
        // 末尾固定一个「邀请」格，所以是成员数 + 1
        itemCount: members.length + 1,
        itemBuilder: (context, index) {
          if (index == members.length) {
            return _InviteTile(roomId: session.room?.roomId ?? '');
          }
          return Padding(
            padding: const EdgeInsets.only(right: 10),
            child: _MemberTile(view: members[index], session: session),
          );
        },
      ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({required this.view, required this.session});

  final RoomMemberView view;
  final RoomSession session;

  @override
  Widget build(BuildContext context) {
    final member = view.info;
    final ring = member.speaking
        ? context.palette.success
        : (member.sharing ? context.palette.accent : null);

    return SizedBox(
      width: 84,
      child: Column(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              UserAvatar(
                userId: member.userId,
                label: member.displayName,
                avatarVersion: member.avatar,
                size: 46,
                ring: ring,
                dimmed:
                    !view.local &&
                    session.linkStateOf(member.peerId) == PeerLinkState.failed,
              ),
              Positioned(
                right: -1,
                bottom: -1,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: context.palette.panel,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    member.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                    size: 10,
                    color: member.muted
                        ? context.palette.textMuted
                        : context.palette.success,
                  ),
                ),
              ),
              if (member.sharing)
                Positioned(
                  left: -1,
                  top: -1,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: context.palette.accent,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.screen_share_rounded,
                      size: 9,
                      color: context.palette.onAccent,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            view.local
                ? context.l10n.shellMemberSelf(member.displayName)
                : member.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.5,
              height: 1.3,
              color: context.palette.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _InviteTile extends StatelessWidget {
  const _InviteTile({required this.roomId});

  final String roomId;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 84,
      child: Column(
        children: [
          GestureDetector(
            onTap: () async {
              await showRoomCodeDialog(context, roomId);
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  shape: BoxShape.circle,
                  border: Border.all(color: context.palette.divider),
                ),
                child: Icon(
                  Icons.add_rounded,
                  size: 18,
                  color: context.palette.textMuted,
                ),
              ),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            context.l10n.callInviteFriend,
            style: TextStyle(
              fontSize: 10.5,
              height: 1.3,
              color: context.palette.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _Stage extends StatelessWidget {
  const _Stage({
    required this.session,
    required this.sharer,
    required this.selfSharing,
  });

  final RoomSession session;
  final MemberInfo? sharer;
  final bool selfSharing;

  @override
  Widget build(BuildContext context) {
    if (sharer == null) {
      return PanelCard(
        padding: EdgeInsets.zero,
        color: context.palette.panel,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: context.palette.rail,
                  borderRadius: AppRadii.card,
                  border: Border.all(color: context.palette.hairline),
                ),
                child: Icon(
                  Icons.screen_share_outlined,
                  size: 20,
                  color: context.palette.textMuted,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                context.l10n.callNoOneSharing,
                style: TextStyle(
                  color: context.palette.textPrimary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                selfSharing
                    ? context.l10n.callShareStarting
                    : context.l10n.callShareHint,
                style: TextStyle(
                  color: context.palette.textMuted,
                  fontSize: 11.5,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 提成非空局部量：闭包里访问不到字段的类型提升
    final activeSharer = sharer!;
    final sharingSelf = activeSharer.peerId == session.selfPeerId;
    final media = context.read<AppState>().media;
    final sharerPeerId = activeSharer.peerId;
    // 自己是共享者时看的是本地采集流的预览，不是远端画面
    final renderer = sharingSelf
        ? media.localScreenRenderer
        : media.remoteScreenRenderer(sharerPeerId);
    // 全屏观看：渲染器每次重建重新取一遍，远端画面晚到 / 共享中断都跟得上
    void openFullscreen() {
      showScreenFullscreen(
        context,
        session: session,
        rendererOf: () => sharerPeerId == session.selfPeerId
            ? media.localScreenRenderer
            : media.remoteScreenRenderer(sharerPeerId),
      );
    }

    return PanelCard(
      padding: EdgeInsets.zero,
      color: Colors.black,
      child: ClipRRect(
        borderRadius: AppRadii.medium,
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: openFullscreen,
              child: renderer != null
                  ? RTCVideoView(
                      renderer,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                    )
                  : Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.screen_share_rounded,
                            size: 30,
                            color: context.palette.accent,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            sharingSelf
                                ? context.l10n.callShareStarting
                                : context.l10n.callReceivingScreen(
                                    activeSharer.displayName,
                                  ),
                            style: TextStyle(
                              // 这块是共享画面的舞台，底色固定是黑的（见上面 PanelCard 的
                              // Colors.black）：文字不能跟着主题走，浅色主题下会变成深灰压黑
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
            Positioned(
              left: AppSpacing.md,
              top: AppSpacing.md,
              // 让开双击：标签不参与命中测试，双击落在下面的画面上
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: AppRadii.pill,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.screen_share_rounded,
                        size: 13,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        sharingSelf
                            ? context.l10n.callSharingSelfBadge
                            : context.l10n.callSharingBadge(
                                activeSharer.displayName,
                              ),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              right: AppSpacing.md,
              top: AppSpacing.md,
              child: _StageButton(
                icon: Icons.fullscreen_rounded,
                tooltip: context.l10n.callFullscreenTooltip,
                onPressed: openFullscreen,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 压在共享画面上的圆形小按钮（半透明黑底 + 白图标）。
class _StageButton extends StatelessWidget {
  const _StageButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withValues(alpha: 0.55),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Icon(icon, size: 16, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// 房间聊天面板：桌面是右侧常驻栏，手机是底部弹层。
///
/// **自己订阅 `RoomSession`**：手机那条路径挂在 `showModalBottomSheet` 的独立路由里，
/// 外面通话页再怎么重建都传不进来；不自己听，新消息就得关掉弹层再打开才出现。
/// 只在消息条数变化时重建——成员静音、音量、电平这些通知一秒好几条，
/// 跟着重建整份消息列表纯属浪费。
class _ChatPanel extends StatefulWidget {
  const _ChatPanel({
    required this.session,
    required this.controller,
    required this.scrollController,
  });

  final RoomSession session;
  final TextEditingController controller;
  final ScrollController scrollController;

  @override
  State<_ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<_ChatPanel> {
  RoomSession get session => widget.session;
  TextEditingController get controller => widget.controller;
  ScrollController get scrollController => widget.scrollController;

  /// 上一次见过的消息条数。
  int _messageCount = -1;

  @override
  void initState() {
    super.initState();
    session.addListener(_onSessionChanged);
    _messageCount = session.chat.length;
    // 历史消息多时默认停在最新一条：否则打开弹层先看到的是最早那几条
    _scrollToLatest(jump: true);
  }

  @override
  void dispose() {
    session.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _onSessionChanged() {
    if (!mounted) {
      return;
    }
    final count = session.chat.length;
    if (count == _messageCount) {
      return;
    }
    _messageCount = count;
    setState(() {});
    _scrollToLatest();
  }

  /// 有新消息就钉到底部；用户自己往上翻看历史（离底部超过两行）时不打扰。
  void _scrollToLatest({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scrollController.hasClients) {
        return;
      }
      final position = scrollController.position;
      if (!jump && position.maxScrollExtent - position.pixels > 120) {
        return;
      }
      if (jump) {
        scrollController.jumpTo(position.maxScrollExtent);
        return;
      }
      scrollController.animateTo(
        position.maxScrollExtent,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final messages = session.chat;
    return PanelCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
          children: [
            Row(
              children: [
                Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 13,
                  color: context.palette.textMuted,
                ),
                const SizedBox(width: 7),
                Text(
                  context.l10n.callChatTitle,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
                const Spacer(),
                if (messages.isEmpty)
                  Text(
                    context.l10n.callChatEmpty,
                    style: TextStyle(
                      color: context.palette.textMuted,
                      fontSize: 10.5,
                      height: 1.3,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  final message = messages[index];
                  // 聊天消息只带 peerId，头像要回头从成员表里取
                  final sender = session.memberOf(message.peerId);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        UserAvatar(
                          userId: sender?.userId ?? 0,
                          label: message.displayName,
                          avatarVersion: sender?.avatar,
                          size: 20,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    message.isMine
                                        ? context.l10n.shellMemberSelf(
                                            message.displayName,
                                          )
                                        : message.displayName,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: context.palette.textSecondary,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    formatChatTime(message.sentAt),
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: context.palette.textMuted,
                                    ),
                                  ),
                                ],
                              ),
                              Text(
                                message.text,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  height: 1.5,
                                  color: context.palette.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    textAlignVertical: TextAlignVertical.center,
                    controller: controller,
                    style: const TextStyle(fontSize: 12.5),
                    onSubmitted: (value) {
                      if (value.trim().isEmpty) {
                        return;
                      }
                      session.sendChat(value);
                      controller.clear();
                      if (scrollController.hasClients) {
                        scrollController.jumpTo(
                          scrollController.position.maxScrollExtent,
                        );
                      }
                    },
                    decoration: InputDecoration(
                      hintText: context.l10n.callChatHint,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                IconButton(
                  tooltip: context.l10n.callSend,
                  onPressed: () {
                    if (controller.text.trim().isEmpty) {
                      return;
                    }
                    session.sendChat(controller.text);
                    controller.clear();
                  },
                  icon: Icon(
                    Icons.send_rounded,
                    size: 16,
                    color: context.palette.accent,
                  ),
                ),
              ],
            ),
          ],
      ),
    );
  }
}

class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.session,
    required this.onToggleShare,
    this.compact = false,
  });

  final RoomSession session;
  final Future<void> Function() onToggleShare;

  /// 手机窄屏：按钮允许换行，并藏掉安卓没有实现的「分享屏幕」
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final self = session.selfMember;
    final sharing = self?.sharing ?? false;

    // 局部例外：这条控制条不画顶部分割线——上方就是内容区，一条通栏的线
    // 把它和舞台切成两半，视觉上像多了一层底板（只改这一处，不动共享组件）
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Wrap(
        alignment: WrapAlignment.center,
        runSpacing: 6,
        children: [
          // 麦克风按钮就是本机的实时麦克风状态灯：
          // 说话时整颗按钮变绿，外圈电平环随音量长短起伏
          ValueListenableBuilder<MicLevel>(
            valueListenable: session.micLevel,
            builder: (context, mic, _) => _ControlButton(
              icon: session.microphoneMuted
                  ? Icons.mic_off_rounded
                  : Icons.mic_rounded,
              label: session.microphoneMuted
                  ? context.l10n.callUnmute
                  : context.l10n.callMute,
              active: session.microphoneMuted,
              highlighted: !session.microphoneMuted && mic.speaking,
              level: session.microphoneMuted || !mic.healthy
                  ? null
                  : mic.display,
              speaking: mic.speaking,
              onTap: session.toggleMicrophone,
            ),
          ),
          _ControlButton(
            icon: session.speakerEnabled
                ? Icons.headset_rounded
                : Icons.headset_off_rounded,
            label: context.l10n.callSpeaker,
            active: !session.speakerEnabled,
            onTap: session.toggleSpeaker,
          ),
          // 安卓没有屏幕捕获实现（getDisplayMedia 只覆盖桌面）：手机不摆这个按钮，
          // 免得点了没反应
          if (!compact)
            _ControlButton(
              icon: Icons.screen_share_rounded,
              label: sharing
                  ? context.l10n.callStopShare
                  : context.l10n.callShareScreen,
              highlighted: sharing,
              onTap: onToggleShare,
            ),
          _ControlButton(
            icon: Icons.tune_rounded,
            label: context.l10n.callMore,
            onTap: () => showDiagnosticsDialog(context),
          ),
        ],
      ),
    );
  }
}

class _ControlButton extends StatefulWidget {
  const _ControlButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.highlighted = false,
    this.level,
    this.speaking = false,
  });

  final IconData icon;
  final String label;
  final Future<void> Function() onTap;
  final bool active;
  final bool highlighted;

  /// 非空时在按钮外圈画一圈电平进度（0..1）。
  final double? level;

  /// 是否正在说话（电平环用绿色，否则用半透明绿）。
  final bool speaking;

  @override
  State<_ControlButton> createState() => _ControlButtonState();
}

class _ControlButtonState extends State<_ControlButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final background = widget.highlighted
        ? context.palette.success
        : (widget.active
              ? context.palette.danger
              : (_hovering ? context.palette.panelElevated : context.palette.panelSubtle));
    final iconColor = widget.highlighted || widget.active
        ? Colors.white
        : context.palette.textPrimary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: () => widget.onTap(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildDisc(background, iconColor),
              const SizedBox(height: 6),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.3,
                  color: context.palette.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 圆形按钮本体；有电平值时在外圈套一圈表示音量的进度环。
  Widget _buildDisc(Color background, Color iconColor) {
    final disc = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: 44,
      height: 44,
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
      child: Icon(widget.icon, size: 19, color: iconColor),
    );

    final level = widget.level;
    if (level == null) {
      return disc;
    }

    return SizedBox(
      width: 54,
      height: 54,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 54,
            height: 54,
            child: CircularProgressIndicator(
              value: level.clamp(0.0, 1.0),
              strokeWidth: 3,
              backgroundColor: context.palette.panelElevated,
              valueColor: AlwaysStoppedAnimation<Color>(
                widget.speaking
                    ? context.palette.success
                    : context.palette.success.withValues(alpha: 0.55),
              ),
            ),
          ),
          disc,
        ],
      ),
    );
  }
}

/// 手机上的舞台区：画面占满整宽，聊天收进右下角按钮弹出的面板。
///
/// 桌面把聊天面板钉成 288dp 的右栏；手机上这 288dp 是从画面里硬扣出来的，
/// 画面只剩几十 dp，所以改成按需弹出的底部面板。
class _CompactStageArea extends StatelessWidget {
  const _CompactStageArea({
    required this.session,
    required this.sharer,
    required this.selfSharing,
    required this.controller,
    required this.scrollController,
  });

  final RoomSession session;
  final MemberInfo? sharer;
  final bool selfSharing;
  final TextEditingController controller;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
            child: _Stage(
              session: session,
              sharer: sharer,
              selfSharing: selfSharing,
            ),
          ),
        ),
        Positioned(
          right: AppSpacing.page,
          bottom: AppSpacing.sm,
          child: FloatingActionButton.small(
            heroTag: 'call-chat',
            tooltip: context.l10n.callChat,
            elevation: 0,
            backgroundColor: context.palette.panelElevated,
            foregroundColor: context.palette.accent,
            onPressed: () => _openChat(context),
            child: const Icon(Icons.forum_rounded, size: 18),
          ),
        ),
      ],
    );
  }

  Future<void> _openChat(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.palette.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => Padding(
        // 键盘弹起时把面板顶上去，否则输入框被盖住
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * 0.6,
          child: _ChatPanel(
            session: session,
            controller: controller,
            scrollController: scrollController,
          ),
        ),
      ),
    );
  }
}
