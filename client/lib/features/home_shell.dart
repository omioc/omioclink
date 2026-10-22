import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../core/app_log.dart';
import '../core/app_theme.dart';
import '../core/formatting.dart';
import '../core/platform.dart';
import '../data/api_client.dart';
import '../data/avatar_picker.dart';
import '../data/models.dart';
import '../media/media_engine.dart';
import '../media/media_models.dart';
import '../music/music_free_library.dart';
import '../musicfree/musicfree_plugins.dart';
import '../musicfree/musicfree_service.dart';
import '../musicfree/plugin_models.dart';
import '../room/room_session.dart';
import '../widgets/avatar.dart';
import '../widgets/common.dart';
import 'call_view.dart';
import 'dialogs.dart';
import 'pick_image.dart';
import 'volume_controls.dart';
import 'join_room_dialog.dart';
import 'theme_pane.dart';

part 'home_shell_rooms.dart';
part 'home_shell_friends.dart';
part 'home_shell_settings.dart';

enum NavSection { rooms, friends, theme, settings }

/// 左栏/中栏当前展示的是哪一套房间列表。
///
/// **两套逻辑各自独立**，互不改对方的数据：
/// * [created]（导航「我的房间」）：只我创建的房间，用来管理自己建的房；
/// * [joined]（tab「我加入的」）：我加入过的房间，含我建的（服务端 `scope=mine`）；
/// * [public]（tab「公开」）：服务器上的公开房间，用来发现新房间。
enum RoomListSource {
  created,
  joined,
  public,
}

/// 列表标题：左栏小标题与中栏大标题共用，跟着当前这一套走。
String _roomListTitle(RoomListSource source) => switch (source) {
  RoomListSource.created => '我创建的房间',
  RoomListSource.joined => '我加入的房间',
  RoomListSource.public => '公开房间',
};

/// 左/中/右三栏主界面。进入房间后中栏切换为通话视图、右栏切换为语音面板。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  NavSection _section = NavSection.rooms;

  /// 当前展示的是哪一套房间列表（导航「我的房间」 vs tab「我加入的 / 公开」）。
  ///
  /// 只决定「看哪一份数据」，与 tab 的选中状态各记各的：切 tab 不会改动
  /// 「我创建的房间」这份数据，点导航也不会把 tab 的选择改掉。
  ///
  /// 默认落在 tab 的「我加入的」：进软件先看自己进过的房间，想管理自己建的
  /// 再点上面的「我的房间」。
  RoomListSource _roomSource = RoomListSource.joined;

  String? _selectedRoomId;
  String _roomQuery = '';

  /// 中栏是否显示通话视图。
  ///
  /// 通话（房间连接）与「正在看哪一页」是两件事：进房后默认打开通话视图，
  /// 但用户去看房间列表、好友、设置时不再抢占中栏——房间照常在后台连着，
  /// 点左栏的「通话中」或自己所在的房间就能回来。
  bool _showCall = false;

  /// 上一次已自动切到通话视图的房间；换房间时才再自动切一次。
  String? _callRoomId;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final session = state.session;
    final inCall = session != null && session.phase.isActive;

    // 进房（或换房）时自动打开通话视图；离开房间时复位，
    // 用户手动切走之后不会再被拉回来。
    final callRoomId = inCall ? (session.room?.roomId ?? '') : null;
    if (callRoomId != _callRoomId) {
      _callRoomId = callRoomId;
      _showCall = callRoomId != null;
    }
    final showCall = inCall && _showCall;

    final rooms = _sourceRooms(state).where((room) {
      if (_roomQuery.isEmpty) {
        return true;
      }
      final query = _roomQuery.toLowerCase();
      return room.name.toLowerCase().contains(query) ||
          room.roomId.toLowerCase().contains(query);
    }).toList();

    if (useCompactLayout(context)) {
      return _CompactShell(
        section: _section,
        roomSource: _roomSource,
        rooms: rooms,
        selectedRoomId: _selectedRoomId,
        query: _roomQuery,
        showCall: showCall,
        session: session,
        createdCount: state.createdRooms.length,
        joinedCount: state.myRooms.length,
        publicCount: state.publicRooms.length,
        onQueryChanged: (value) => setState(() => _roomQuery = value),
        onSectionChanged: _selectSection,
        onEnterCall: _enterCall,
        onRoomSourceChanged: _changeRoomSource,
        onSelectRoom: _selectRoom,
        onEnterRoom: _enterRoom,
      );
    }

    return Row(
      children: [
        Container(
          width: AppSizes.sideRail,
          decoration: BoxDecoration(
            color: context.palette.rail,
            border: Border(right: BorderSide(color: context.palette.hairline)),
          ),
          child: _SideNav(
            section: _section,
            roomSource: _roomSource,
            rooms: rooms,
            createdCount: state.createdRooms.length,
            joinedCount: state.myRooms.length,
            publicCount: state.publicRooms.length,
            selectedRoomId: _selectedRoomId,
            query: _roomQuery,
            showCall: showCall,
            onQueryChanged: (value) => setState(() => _roomQuery = value),
            onSectionChanged: _selectSection,
            onEnterCall: _enterCall,
            onRoomSourceChanged: _changeRoomSource,
            onRoomSelected: _selectRoom,
          ),
        ),
        Expanded(
          child: showCall
              ? CallView(session: session)
              : _ContentPane(
                  section: _section,
                  roomSource: _roomSource,
                  rooms: rooms,
                  selectedRoomId: _selectedRoomId,
                  onSelectRoom: _selectRoom,
                  onEnterRoom: _enterRoom,
                  onReturnToCall: _enterCall,
                ),
        ),
        Container(
          width: AppSizes.infoRail,
          decoration: BoxDecoration(
            color: context.palette.rail,
            border: Border(left: BorderSide(color: context.palette.hairline)),
          ),
          child: showCall
              ? _VoicePanel(session: session)
              : const _OverviewPanel(),
        ),
      ],
    );
  }

  /// 切导航：去看别的页面时让出中栏，通话继续在后台跑。
  void _selectSection(NavSection value) {
    final compact = useCompactLayout(context);
    setState(() {
      _section = value;
      _showCall = false;
      if (value == NavSection.rooms) {
        // 桌面左栏的「我的房间」＝看「我创建的房间」；手机底部只有一个「房间」
        // 入口，回到它就是回房间列表，该看「我加入的」——想管自己建的，点上面
        // 那排 tab（那条路走 _changeRoomSource），不该被这里顺手改掉
        _roomSource = compact ? RoomListSource.joined : RoomListSource.created;
      }
    });
    // 切到好友页就顺手拉一次：首次登录那一次可能还在路上（也可能抖掉了），
    // 不该让用户只能干等 15 秒后的轮询
    if (value == NavSection.friends) {
      unawaited(context.read<AppState>().refreshFriends());
    }
    if (value == NavSection.rooms) {
      // 列表还空着就先补一次：手机上从设置/主题切回来只看到一片空白的话，
      // 用户根本不知道该去点那个小刷新图标
      final state = context.read<AppState>();
      if (state.myRooms.isEmpty && state.publicRooms.isEmpty) {
        unawaited(state.refreshRooms());
      }
    }
  }

  /// 回到通话视图（房间连接一直在后台，这里只是切界面）。
  void _enterCall() => setState(() => _showCall = true);

  void _changeRoomSource(RoomListSource source) {
    setState(() {
      _roomSource = source;
      _section = NavSection.rooms;
      _showCall = false;
    });
    // 切 tab 顺手刷新一次（我加入的 / 公开 都在这一轮里拉到）
    unawaited(context.read<AppState>().refreshRooms());
  }

  void _selectRoom(Room room) {
    final callRoomId = _callRoomId;
    setState(() {
      _selectedRoomId = room.roomId;
      _showCall = room.roomId == callRoomId;
      if (room.roomId != callRoomId) {
        _section = NavSection.rooms;
      }
    });
  }

  /// 当前这一套房间列表的数据源。
  ///
  /// 两套逻辑在这里分叉：导航「我的房间」= 我创建的（本地按 ownerId 筛），
  /// tab「我加入的 / 公开」= 服务端 `scope=mine` / `scope=public` 的两份列表。
  List<Room> _sourceRooms(AppState state) => switch (_roomSource) {
    RoomListSource.created => state.createdRooms,
    RoomListSource.joined => state.myRooms,
    RoomListSource.public => state.publicRooms,
  };

  /// 双击房间直接进入。
  ///
  /// 不需要密码、或密码已经被记住：一步进房；需要密码又没记住：切到房间详情，
  /// 让用户在那里输一次（输对之后就会记住）。
  Future<void> _enterRoom(Room room) async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    // 已经在这个房间里：直接回到通话视图，别再来一次进房流程
    if (state.isInRoom(room.roomId)) {
      setState(() => _showCall = true);
      return;
    }
    final count = state.memberCountFor(room);
    if (count >= room.capacity) {
      messenger.showSnackBar(const SnackBar(content: Text('房间已满，暂时进不去')));
      return;
    }
    if (room.hasPassword && !state.hasRememberedRoomPassword(room.roomId)) {
      setState(() => _selectedRoomId = room.roomId);
      return;
    }
    final password = room.hasPassword
        ? state.roomPasswordFor(room.roomId)
        : null;
    final ok = await state.joinRoom(roomId: room.roomId, password: password);
    if (!ok && mounted && room.hasPassword) {
      // 记住的密码可能已被房主改掉（AppState 已把它清掉）：回详情页重输
      setState(() => _selectedRoomId = room.roomId);
    }
  }
}

// --------------------------------------------------------------------------- //
// 左栏
// --------------------------------------------------------------------------- //
class _SideNav extends StatelessWidget {
  const _SideNav({
    required this.section,
    required this.roomSource,
    required this.rooms,
    required this.createdCount,
    required this.joinedCount,
    required this.publicCount,
    required this.selectedRoomId,
    required this.query,
    required this.showCall,
    required this.onQueryChanged,
    required this.onSectionChanged,
    required this.onEnterCall,
    required this.onRoomSourceChanged,
    required this.onRoomSelected,
  });

  final NavSection section;

  /// 当前展示的是哪一套房间列表（决定导航项与 tab 谁高亮、列表标题写什么）。
  final RoomListSource roomSource;

  final List<Room> rooms;

  /// 三个计数：我创建的 / 我加入的 / 公开。
  final int createdCount;
  final int joinedCount;
  final int publicCount;

  final String? selectedRoomId;
  final String query;

  /// 中栏当前是否显示通话视图（决定「通话中」这一项是否高亮）。
  final bool showCall;

  final ValueChanged<String> onQueryChanged;
  final ValueChanged<NavSection> onSectionChanged;

  /// 回到通话视图（房间连接一直在后台，这里只是切界面）。
  final VoidCallback onEnterCall;

  /// 切到 tab 的那一套（我加入的 / 公开）。
  final ValueChanged<RoomListSource> onRoomSourceChanged;
  final ValueChanged<Room> onRoomSelected;

  static const _roomAccents = <Color>[
    Color(0xFF5B7CFA),
    Color(0xFF38BDF8),
    Color(0xFFF59E0B),
    Color(0xFF34D399),
    Color(0xFFEC4899),
  ];

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final user = state.user;
    final session = state.session;
    final inCall = session != null && session.phase.isActive;
    final pending = state.friendRequests
        .where((r) => r.direction == FriendRequestDirection.incoming)
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
          child: SizedBox(
            height: AppSizes.control,
            child: TextField(
              textAlignVertical: TextAlignVertical.center,
              onChanged: onQueryChanged,
              style: const TextStyle(fontSize: 12.5),
              cursorHeight: 15,
              decoration: const InputDecoration(
                hintText: '搜索房间或好友',
                prefixIcon: Icon(Icons.search_rounded, size: 15),
                prefixIconConstraints: BoxConstraints(
                  minWidth: 32,
                  minHeight: 30,
                ),
              ),
            ),
          ),
        ),
        // 导航行统一左右留 8px：选中高亮是圆角块，顶到侧栏边缘就贴边了
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 在房间里时常驻一条「通话中」：房间在后台连着，点这里回到通话界面
              if (inCall) ...[
                NavRow(
                  icon: Icons.graphic_eq_rounded,
                  label: session.room?.name ?? '通话中',
                  selected: showCall,
                  accent: context.palette.success,
                  onTap: onEnterCall,
                  trailing: Text(
                    formatCapacity(
                      session.members.length,
                      session.room?.capacity ?? session.members.length,
                    ),
                    style: TextStyle(
                      color: context.palette.success,
                      fontSize: 10.5,
                      height: 1.2,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
              ],
              // 「我的房间」＝我**创建**的房间：与下面 tab 的「我加入的」是两套逻辑
              NavRow(
                icon: Icons.home_rounded,
                label: '我的房间',
                selected:
                    !showCall &&
                    section == NavSection.rooms &&
                    roomSource == RoomListSource.created,
                onTap: () => onSectionChanged(NavSection.rooms),
                trailing: Text(
                  '$createdCount',
                  style: TextStyle(
                    color: context.palette.textMuted,
                    fontSize: 10.5,
                    height: 1.2,
                  ),
                ),
              ),
              NavRow(
                icon: Icons.group_rounded,
                label: '好友',
                selected: !showCall && section == NavSection.friends,
                onTap: () => onSectionChanged(NavSection.friends),
                trailing: pending > 0
                    ? Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: context.palette.danger,
                          borderRadius: AppRadii.pill,
                        ),
                        child: Text(
                          '$pending',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9.5,
                            height: 1.3,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      )
                    : Text(
                        '${state.friends.length}',
                        style: TextStyle(
                          color: context.palette.textMuted,
                          fontSize: 10.5,
                          height: 1.2,
                        ),
                      ),
              ),
              NavRow(
                icon: Icons.palette_rounded,
                label: '主题',
                selected: !showCall && section == NavSection.theme,
                onTap: () => onSectionChanged(NavSection.theme),
              ),
              NavRow(
                icon: Icons.settings_rounded,
                label: '设置',
                selected: !showCall && section == NavSection.settings,
                onTap: () => onSectionChanged(NavSection.settings),
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(14, AppSpacing.lg, 14, AppSpacing.sm),
          child: SectionLabel(text: '服务器'),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: _ServerCard(),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: OutlinedButton.icon(
            onPressed: () => showJoinRoomDialog(context),
            icon: const Icon(Icons.login_rounded, size: 14),
            label: const Text('加入房间'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(AppSizes.control),
              padding: EdgeInsets.zero,
              foregroundColor: context.palette.textSecondary,
              side: BorderSide(color: context.palette.hairline),
              textStyle: const TextStyle(fontSize: 12),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: _ScopeTabs(
            source: roomSource,
            joinedCount: joinedCount,
            publicCount: publicCount,
            onChanged: onRoomSourceChanged,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 6, 4),
          child: SectionLabel(
            text: _roomListTitle(roomSource),
            trailing: IconButton(
              tooltip: '创建房间',
              onPressed: () => showCreateRoomDialog(context),
              icon: Icon(
                Icons.add_rounded,
                size: 15,
                color: context.palette.textSecondary,
              ),
            ),
          ),
        ),
        Expanded(
          child: rooms.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg,
                    ),
                    child: Text(
                      switch (roomSource) {
                        RoomListSource.created =>
                          '还没有你创建的房间。点右上角 + 创建，或用房间号加入好友的房间',
                        RoomListSource.joined =>
                          '还没有加入过房间。点右上角 + 创建，或用房间号加入好友的房间',
                        RoomListSource.public => '服务器上还没有公开房间',
                      },
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: context.palette.textMuted,
                        fontSize: 11,
                        height: 1.65,
                      ),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 2, 8, 10),
                  itemCount: rooms.length,
                  itemBuilder: (context, index) {
                    final room = rooms[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: NavRow(
                        icon: room.isPublic
                            ? Icons.forum_rounded
                            : Icons.lock_rounded,
                        accent: _roomAccents[index % _roomAccents.length],
                        label: room.name,
                        selected: !showCall && room.roomId == selectedRoomId,
                        onTap: () => onRoomSelected(room),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              formatCapacity(
                                state.memberCountFor(room),
                                room.capacity,
                              ),
                              style: TextStyle(
                                fontSize: 10.5,
                                height: 1.2,
                                color: room.online
                                    ? context.palette.success
                                    : context.palette.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        // 高度与点歌台底部播放条同档（AppSizes.bottomBar）：
        // 两处都贴着窗口底，定成同一个高度后顶部分隔线才对得齐
        SizedBox(
          height: AppSizes.bottomBar - 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                UserAvatar(
                  userId: user?.id ?? 0,
                  label: user?.displayName ?? '?',
                  avatarVersion: user?.avatar,
                  size: 30,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        user?.displayName ?? '未登录',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          height: 1.3,
                        ),
                      ),
                      Text(
                        state.isLoggedIn ? '在线' : '离线',
                        style: TextStyle(
                          color: state.isLoggedIn
                              ? context.palette.success
                              : context.palette.textMuted,
                          fontSize: 10.5,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '退出登录',
                  onPressed: () => state.logout(),
                  icon: const Icon(Icons.logout_rounded, size: 14),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
class _ContentPane extends StatelessWidget {
  const _ContentPane({
    required this.section,
    required this.roomSource,
    required this.rooms,
    required this.selectedRoomId,
    required this.onSelectRoom,
    required this.onEnterRoom,
    required this.onReturnToCall,
  });

  final NavSection section;
  final RoomListSource roomSource;
  final List<Room> rooms;
  final String? selectedRoomId;
  final ValueChanged<Room> onSelectRoom;

  /// 双击房间：不需要密码就一步进房。
  final ValueChanged<Room> onEnterRoom;

  /// 已经在某个房间里时，卡片上的「回到通话」：把中栏切回通话视图。
  final VoidCallback onReturnToCall;

  @override
  Widget build(BuildContext context) {
    return switch (section) {
      NavSection.rooms => _RoomsPane(
        roomSource: roomSource,
        rooms: rooms,
        selectedRoomId: selectedRoomId,
        onSelectRoom: onSelectRoom,
        onEnterRoom: onEnterRoom,
        onReturnToCall: onReturnToCall,
      ),
      NavSection.friends => const _FriendsPane(),
      NavSection.theme => const ThemePane(),
      NavSection.settings => const _SettingsPane(),
    };
  }
}
class _VoicePanel extends StatefulWidget {
  const _VoicePanel({required this.session});

  final RoomSession session;

  @override
  State<_VoicePanel> createState() => _VoicePanelState();
}

class _VoicePanelState extends State<_VoicePanel> {
  double _volume = 0.8;

  @override
  Widget build(BuildContext context) {
    final members = widget.session.members;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(14, 14, 14, 10),
          child: SectionLabel(text: '语音'),
        ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Row(
              children: [
                Icon(
                  _volume == 0
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded,
                  size: 16,
                  color: context.palette.textSecondary,
                ),
                Expanded(
                  child: Slider(
                    value: _volume,
                    onChanged: (value) async {
                      setState(() => _volume = value);
                      await context.read<AppState>().media.setSpeakerEnabled(
                        value > 0,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          // 自己的麦克风实时状态：有效性 + 电平，说话时其他人看到的绿灯也由它驱动
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            child: ValueListenableBuilder<MicLevel>(
              valueListenable: widget.session.micLevel,
              builder: (context, mic, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MicStatusLine(level: mic, dense: true),
                  const SizedBox(height: AppSpacing.sm),
                  MicLevelBar(
                    level: mic.display,
                    enabled: mic.healthy && !mic.muted,
                    speaking: mic.speaking,
                    height: 6,
                  ),
                ],
              ),
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: SectionLabel(
              text: '在线成员',
              trailing: Text(
                formatCapacity(
                  members.length,
                  widget.session.room?.capacity ?? members.length,
                ),
                style: TextStyle(
                  color: context.palette.textMuted,
                  fontSize: 11,
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              itemCount: members.length,
              itemBuilder: (context, index) {
                final view = members[index];
                final member = view.info;
                return Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: AnimatedBuilder(
                    // 只订阅电平表：电平每 100ms 变一次，
                    // 挂在会话通知上会让整块界面每秒重建十次
                    // 电平与成员音量是两个独立通知源，合并订阅即可
                    animation: Listenable.merge(<Listenable>[
                      widget.session.peerLevels,
                      widget.session.peerVolumes,
                    ]),
                    builder: (context, _) {
                      final level = widget.session.peerLevels.levelOf(
                        member.peerId,
                      );
                      final speaking = member.speaking || level.speaking;
                      final silent = member.muted || view.mutedLocally;
                      return Row(
                        // 顶对齐 + 名字那格钉成头像高度：头像和名字的中线才对齐。
                        // 整列垂直居中的话，别人那一行多了音量推子、列比头像高，
                        // 名字就会被顶到头像上方（看着就是「上飘」）。
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          UserAvatar(
                            userId: member.userId,
                            label: member.displayName,
                            avatarVersion: member.avatar,
                            size: 30,
                            ring: speaking && !silent
                                ? context.palette.success
                                : null,
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  height: 30,
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      view.local
                                          ? '${member.displayName}（我）'
                                          : member.displayName,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                MicLevelBar(
                                  level: level.level,
                                  enabled: !silent,
                                  speaking: speaking,
                                  height: 3,
                                ),
                                if (!view.local) ...<Widget>[
                                  const SizedBox(height: 2),
                                  PeerVolumeSlider(
                                    label: member.displayName,
                                    percent: widget.session.peerVolumes
                                        .percentOf(member.userId),
                                    muted: view.mutedLocally,
                                    sliderKey: ValueKey(
                                      'peer-volume-${member.userId}',
                                    ),
                                    onChanged: (value) => widget.session
                                        .setPeerVolume(member.peerId, value),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          // 徽标跟着名字那一行居中，不跟着整列走
                          SizedBox(
                            height: 30,
                            child: Center(
                              child: MemberBadges(
                                member: member,
                                isSelf: view.local,
                                latencyMs:
                                    widget.session.stats.peers[member.peerId],
                                linkState: widget.session.linkStateOf(
                                  member.peerId,
                                ),
                                micLevel: level.level,
                                micSpeaking: speaking,
                                micMutedLocally: view.mutedLocally,
                                // 点自己的 = 开关我的麦克风；点别人的 = 本地静音/恢复收听
                                onToggleMic: () =>
                                    widget.session.togglePeerAudio(member.peerId),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                );
              },
            ),
          ),
          if (widget.session.hasPunchFailure) ...[
            const Divider(),
            Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: Text(
                '有成员无法直连：多为对称型 NAT 或网络封锁 UDP，'
                '建议双方切换到手机热点或家庭宽带后重试',
                style: TextStyle(
                  color: context.palette.warning,
                  fontSize: 11,
                  height: 1.6,
                ),
              ),
            ),
          ],
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: PanelCard(
              color: context.palette.panelSubtle,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionLabel(text: '连接质量'),
                  const SizedBox(height: AppSpacing.sm),
                  _kv(
                    context,
                    '已直连',
                    '${widget.session.connectedPeerCount}/${widget.session.peerCount} 位成员',
                  ),
                  _kv(context, '上行', formatKbps(widget.session.stats.outgoingKbps)),
                  _kv(context, '下行', formatKbps(widget.session.stats.incomingKbps)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _OverviewPanel extends StatelessWidget {
  const _OverviewPanel();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final info = state.serverInfo;

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, AppSpacing.xl),
      children: [
        const SectionLabel(text: '服务器状态'),
        const SizedBox(height: AppSpacing.sm),
        PanelCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _kv(context, '名称', info?.name ?? '—'),
              _kv(context, '地址', state.endpoint?.display ?? '未连接'),
              _kv(
                context,
                '房间容量',
                info == null
                    ? '—'
                    : '${info.roomCapacity} 人（上限 ${info.maxRoomCapacity}）',
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        SectionLabel(text: '在线好友（${state.onlineFriends.length}）'),
        const SizedBox(height: AppSpacing.sm),
        if (state.friends.isEmpty)
          Text(
            '还没有好友',
            style: TextStyle(
              color: context.palette.textMuted,
              fontSize: 11.5,
              height: 1.5,
            ),
          )
        else
          // 右栏的好友列表不要卡片外框、也不要分割线：就是一组纯行
          Column(
            children: [
              for (final friend in state.friends)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      UserAvatar(
                        userId: friend.user.id,
                        label: friend.user.displayName,
                        avatarVersion: friend.user.avatar,
                        size: 24,
                        dimmed: !friend.online,
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          friend.user.displayName,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.3,
                            color: friend.online
                                ? context.palette.textPrimary
                                : context.palette.textSecondary,
                          ),
                        ),
                      ),
                      StatusDot(
                        color: friend.online
                            ? context.palette.success
                            : context.palette.textMuted.withValues(alpha: 0.4),
                        size: 5,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        friend.online ? '在线' : '离线',
                        style: TextStyle(
                          fontSize: 10.5,
                          height: 1.3,
                          color: friend.online
                              ? context.palette.textSecondary
                              : context.palette.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

// --------------------------------------------------------------------------- //
// 手机布局（单栏 + 底部导航）
// --------------------------------------------------------------------------- //

/// 桌面三栏最小要 536dp（248 侧栏 + 288 右栏），手机只有 360~430dp：
/// 这里换结构而不是压窄——导航沉到底部，右栏内容并进各页面自己。
class _CompactShell extends StatelessWidget {
  const _CompactShell({
    required this.section,
    required this.roomSource,
    required this.rooms,
    required this.selectedRoomId,
    required this.query,
    required this.showCall,
    required this.session,
    required this.createdCount,
    required this.joinedCount,
    required this.publicCount,
    required this.onQueryChanged,
    required this.onSectionChanged,
    required this.onEnterCall,
    required this.onRoomSourceChanged,
    required this.onSelectRoom,
    required this.onEnterRoom,
  });

  final NavSection section;
  final RoomListSource roomSource;
  final List<Room> rooms;
  final String? selectedRoomId;
  final String query;
  final bool showCall;
  final RoomSession? session;
  final int createdCount;
  final int joinedCount;
  final int publicCount;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<NavSection> onSectionChanged;
  final VoidCallback onEnterCall;
  final ValueChanged<RoomListSource> onRoomSourceChanged;
  final ValueChanged<Room> onSelectRoom;
  final ValueChanged<Room> onEnterRoom;

  @override
  Widget build(BuildContext context) {
    final inCall = session != null && session!.phase.isActive;
    final Widget body;
    if (showCall && inCall) {
      body = CallView(session: session!);
    } else {
      body = switch (section) {
        NavSection.rooms => _CompactRoomsPane(
          roomSource: roomSource,
          rooms: rooms,
          selectedRoomId: selectedRoomId,
          query: query,
          createdCount: createdCount,
          joinedCount: joinedCount,
          publicCount: publicCount,
          onQueryChanged: onQueryChanged,
          onRoomSourceChanged: onRoomSourceChanged,
          onSelectRoom: onSelectRoom,
          onEnterRoom: onEnterRoom,
        ),
        NavSection.friends => const _FriendsPane(),
        NavSection.theme => const ThemePane(),
        NavSection.settings => const _SettingsPane(),
      };
    }

    return Column(
      children: [
        Expanded(child: body),
        _CompactNavBar(
          section: section,
          inCall: inCall,
          showCall: showCall,
          onSection: onSectionChanged,
          onEnterCall: onEnterCall,
        ),
      ],
    );
  }
}

/// 底部导航：图标 + 一排小字，选中项用主题色 + 淡底。
class _CompactNavBar extends StatelessWidget {
  const _CompactNavBar({
    required this.section,
    required this.inCall,
    required this.showCall,
    required this.onSection,
    required this.onEnterCall,
  });

  final NavSection section;
  final bool inCall;
  final bool showCall;
  final ValueChanged<NavSection> onSection;
  final VoidCallback onEnterCall;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[
      // 通话项只在房间里出现：手机上没有左栏可以挂「通话中」常驻项
      if (inCall)
        _CompactNavItem(
          icon: Icons.graphic_eq_rounded,
          label: '通话',
          selected: showCall,
          accent: context.palette.success,
          onTap: onEnterCall,
        ),
      _CompactNavItem(
        icon: Icons.forum_rounded,
        label: '房间',
        selected: !showCall && section == NavSection.rooms,
        onTap: () => onSection(NavSection.rooms),
      ),
      _CompactNavItem(
        icon: Icons.group_rounded,
        label: '好友',
        selected: !showCall && section == NavSection.friends,
        onTap: () => onSection(NavSection.friends),
      ),
      _CompactNavItem(
        icon: Icons.palette_rounded,
        label: '主题',
        selected: !showCall && section == NavSection.theme,
        onTap: () => onSection(NavSection.theme),
      ),
      _CompactNavItem(
        icon: Icons.settings_rounded,
        label: '设置',
        selected: !showCall && section == NavSection.settings,
        onTap: () => onSection(NavSection.settings),
      ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: context.palette.rail,
        border: Border(top: BorderSide(color: context.palette.hairline)),
      ),
      height: AppSizes.bottomBar,
      child: Row(
        children: [
          for (final item in items) Expanded(child: item),
        ],
      ),
    );
  }
}

class _CompactNavItem extends StatelessWidget {
  const _CompactNavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.accent,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? (accent ?? context.palette.accent)
        : context.palette.textMuted;
    return Semantics(
      selected: selected,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 19, color: color),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              style: TextStyle(
                color: color,
                fontSize: 10,
                height: 1.2,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 手机上的房间页：页头（标题 + 三个动作）+ 分段 tab + 搜索 + 列表。
///
/// 桌面把「搜索/导航/房间列表」放在 248dp 侧栏、把「房间卡片」放在中栏；
/// 手机只有一栏，两处合成一页：搜索与 tab 在顶部，房间是整行可点的卡片。
class _CompactRoomsPane extends StatelessWidget {
  const _CompactRoomsPane({
    required this.roomSource,
    required this.rooms,
    required this.selectedRoomId,
    required this.query,
    required this.createdCount,
    required this.joinedCount,
    required this.publicCount,
    required this.onQueryChanged,
    required this.onRoomSourceChanged,
    required this.onSelectRoom,
    required this.onEnterRoom,
  });

  final RoomListSource roomSource;
  final List<Room> rooms;
  final String? selectedRoomId;
  final String query;
  final int createdCount;
  final int joinedCount;
  final int publicCount;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<RoomListSource> onRoomSourceChanged;
  final ValueChanged<Room> onSelectRoom;
  final ValueChanged<Room> onEnterRoom;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 52,
          child: Padding(
            padding: const EdgeInsets.only(left: AppSpacing.page, right: 6),
            child: Row(
              children: [
                // 标题与计数占满左侧，三个按钮才固定贴右。以前是 Flexible 标题
                // 和 Spacer 平分剩余空间：Flexible 是 loose 的，标题短的那一档
                // （「公开房间」）用不完自己那份，按钮就被往左推——三档之间对不齐。
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          _roomListTitle(roomSource),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.pageTitle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${rooms.length}',
                        style: TextStyle(
                          color: context.palette.textMuted,
                          fontSize: 11.5,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '刷新',
                  onPressed: () => state.refreshRooms(),
                  icon: Icon(
                    Icons.refresh_rounded,
                    size: 18,
                    color: context.palette.textSecondary,
                  ),
                ),
                IconButton(
                  tooltip: '输入房间号加入',
                  onPressed: () => showJoinRoomDialog(context),
                  icon: Icon(
                    Icons.login_rounded,
                    size: 18,
                    color: context.palette.textSecondary,
                  ),
                ),
                IconButton(
                  tooltip: '创建房间',
                  onPressed: () => showCreateRoomDialog(context),
                  icon: Icon(
                    Icons.add_rounded,
                    size: 20,
                    color: context.palette.accent,
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
          child: _ScopeTabs(
            source: roomSource,
            createdCount: createdCount,
            joinedCount: joinedCount,
            publicCount: publicCount,
            compactLabel: true,
            onChanged: onRoomSourceChanged,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.page,
            10,
            AppSpacing.page,
            6,
          ),
          child: SizedBox(
            height: AppSizes.control,
            child: TextField(
              textAlignVertical: TextAlignVertical.center,
              onChanged: onQueryChanged,
              style: AppText.field,
              decoration: const InputDecoration(
                hintText: '搜索房间',
                prefixIcon: Icon(Icons.search_rounded, size: 16),
                prefixIconConstraints: BoxConstraints(
                  minWidth: 34,
                  minHeight: 30,
                ),
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: rooms.isEmpty
              ? _EmptyRooms(roomSource: roomSource)
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.md,
                    AppSpacing.lg,
                    AppSpacing.xl,
                  ),
                  itemCount: rooms.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final room = rooms[index];
                    return _CompactRoomTile(
                      key: ValueKey(room.roomId),
                      room: room,
                      onTap: () {
                        onSelectRoom(room);
                        unawaited(_showRoomSheet(context, room));
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// 点房间弹出底部面板（详情 + 进房）。
  ///
  /// 桌面靠「单击展开、双击进入」，触屏上没有双击这种隐式操作：
  /// 一切收敛到面板里的一个明确按钮。
  Future<void> _showRoomSheet(BuildContext context, Room room) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.palette.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => _CompactRoomSheet(room: room),
    );
  }
}

/// 手机上的房间行：图标 + 名称/房间号 + 人数 + 箭头。
class _CompactRoomTile extends StatelessWidget {
  const _CompactRoomTile({super.key, required this.room, required this.onTap});

  final Room room;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final members = context.watch<AppState>().memberCountFor(room);
    return Material(
      color: context.palette.panel,
      borderRadius: AppRadii.card,
      child: InkWell(
        borderRadius: AppRadii.card,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          decoration: BoxDecoration(
            borderRadius: AppRadii.card,
            border: Border.all(color: context.palette.hairline),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: context.palette.accent.withValues(alpha: 0.13),
                  borderRadius: AppRadii.medium,
                ),
                child: Icon(
                  room.isPublic ? Icons.forum_rounded : Icons.lock_rounded,
                  size: 16,
                  color: context.palette.accent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            room.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              height: 1.35,
                            ),
                          ),
                        ),
                        if (room.hasPassword) ...[
                          const SizedBox(width: 4),
                          Icon(
                            Icons.key_rounded,
                            size: 12,
                            color: context.palette.warning,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '房间号 ${room.roomId}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.palette.textMuted,
                        fontSize: 11,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                formatCapacity(members, room.capacity),
                style: TextStyle(
                  color: room.online
                      ? context.palette.success
                      : context.palette.textMuted,
                  fontSize: 11.5,
                  height: 1.2,
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: context.palette.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 房间详情底部面板：房间信息 + 复用桌面那份「密码 / 进入 / 解散」。
///
/// 进房成功后自己关掉：面板留着会挡在通话页上面。
class _CompactRoomSheet extends StatelessWidget {
  const _CompactRoomSheet({required this.room});

  final Room room;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          room.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '房间号 ${room.roomId}'
                          '${room.ownerName == null ? '' : ' · 房主 ${room.ownerName}'}'
                          ' · ${formatCapacity(state.memberCountFor(room), room.capacity)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.palette.textMuted,
                            fontSize: 11.5,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.lg,
                AppSpacing.lg,
              ),
              child: _RoomDetail(
                key: ValueKey(room.roomId),
                room: room,
                onReturnToCall: () {
                  Navigator.of(context).maybePop();
                },
                onJoined: () {
                  if (context.mounted) {
                    Navigator.of(context).maybePop();
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
