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

/// 「我创建的 / 我加入的 / 公开」分段切换。
///
/// 桌面上「我创建的房间」挂在左栏导航上（点一下就是这一套），这排 tab 只放
/// 后两档；手机上左栏没有位置，「我创建的」必须放进这排 tab，否则用户点完
/// 「公开」就再也找不到回自己房间的入口了（除非想起来再点一次底部导航）。
///
/// 这是与导航「我的房间」并列的**另一套逻辑**：点 tab 切换的是左栏/中栏展示的
/// 房间列表，不动「我创建的房间」那份数据；反过来点导航也不会改这里的选中态。
class _ScopeTabs extends StatelessWidget {
  const _ScopeTabs({
    required this.source,
    required this.joinedCount,
    required this.publicCount,
    required this.onChanged,
    this.createdCount,
    this.compactLabel = false,
  });

  /// 当前展示的那一套：命中哪个 tab 就高亮哪个；
  /// 「我创建的房间」只有传了 [createdCount] 时才在这排里。
  final RoomListSource source;
  final int joinedCount;
  final int publicCount;

  /// 「我创建的」数量；null = 不显示这一档（桌面端）。
  final int? createdCount;

  /// 窄屏：文案缩成「我创建 / 我加入」，三个 tab 才挤得下 360dp 宽的屏幕。
  final bool compactLabel;

  final ValueChanged<RoomListSource> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        // 槽底平时是舞台色，贴壁纸后舞台透明：用 track 才不会变成一个空框
        color: context.palette.track,
        borderRadius: AppRadii.medium,
        border: Border.all(color: context.palette.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (createdCount != null) ...[
            Expanded(
              child: _tab(
                context,
                compactLabel ? '我创建' : '我创建的',
                createdCount!,
                RoomListSource.created,
              ),
            ),
            const SizedBox(width: 3),
          ],
          Expanded(
            child: _tab(
              context,
              compactLabel ? '我加入' : '我加入的',
              joinedCount,
              RoomListSource.joined,
            ),
          ),
          const SizedBox(width: 3),
          Expanded(child: _tab(context, '公开', publicCount, RoomListSource.public)),
        ],
      ),
    );
  }

  Widget _tab(
    BuildContext context,
    String label,
    int count,
    RoomListSource value,
  ) {
    final selected = source == value;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onChanged(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? context.palette.panelElevated : Colors.transparent,
            borderRadius: AppRadii.small,
            border: Border.all(
              color: selected ? context.palette.divider : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.2,
                  color: selected
                      ? context.palette.textPrimary
                      : context.palette.textMuted,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.2,
                  color: selected
                      ? context.palette.textSecondary
                      : context.palette.textMuted.withValues(alpha: 0.75),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final endpoint = state.endpoint;
    final info = state.serverInfo;
    final connected = state.isConnectedToServer;

    return PanelCard(
      color: context.palette.panel,
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: context.palette.accent.withValues(alpha: 0.14),
              borderRadius: AppRadii.small,
            ),
            child: Icon(
              Icons.cloud_rounded,
              size: 14,
              color: context.palette.accent,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  info?.name ?? '我的服务器',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    height: 1.35,
                  ),
                ),
                Text(
                  endpoint?.display ?? '未配置',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.palette.textMuted,
                    fontSize: 10.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          StatusDot(
            color: connected ? context.palette.success : context.palette.textMuted,
            size: 6,
            glow: connected,
          ),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------------------- //
// 中栏
// --------------------------------------------------------------------------- //
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

class _RoomsPane extends StatelessWidget {
  const _RoomsPane({
    required this.roomSource,
    required this.rooms,
    required this.selectedRoomId,
    required this.onSelectRoom,
    required this.onEnterRoom,
    required this.onReturnToCall,
  });

  final RoomListSource roomSource;
  final List<Room> rooms;
  final String? selectedRoomId;
  final ValueChanged<Room> onSelectRoom;
  final ValueChanged<Room> onEnterRoom;
  final VoidCallback onReturnToCall;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: AppSizes.pageHeader,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
          child: Row(
            children: [
              // 标题跟着当前这一套走（我创建的 / 我加入的 / 公开）
              Text(_roomListTitle(roomSource), style: AppText.pageTitle),
              const SizedBox(width: 10),
              Text(
                '${rooms.length} 个',
                style: TextStyle(
                  color: context.palette.textMuted,
                  fontSize: 11.5,
                  height: 1.2,
                ),
              ),
              if (rooms.isNotEmpty) ...[
                const SizedBox(width: 14),
                Text(
                  '双击房间直接进入',
                  style: TextStyle(
                    color: context.palette.textMuted,
                    fontSize: 11,
                    height: 1.2,
                  ),
                ),
              ],
              const Spacer(),
              TextButton.icon(
                onPressed: () => state.refreshRooms(),
                icon: const Icon(Icons.refresh_rounded, size: 14),
                label: const Text('刷新'),
                style: TextButton.styleFrom(
                  foregroundColor: context.palette.textMuted,
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 4),
              OutlinedButton.icon(
                onPressed: () => showJoinRoomDialog(context),
                icon: const Icon(Icons.login_rounded, size: 14),
                label: const Text('加入房间'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => showCreateRoomDialog(context),
                icon: const Icon(Icons.add_rounded, size: 15),
                label: const Text('创建房间'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: rooms.isEmpty
              ? _EmptyRooms(roomSource: roomSource)
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.page,
                    14,
                    AppSpacing.page,
                    AppSpacing.xl,
                  ),
                  itemCount: rooms.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final room = rooms[index];
                    // 选中的房间**就地展开**（密码 / 进入 / 解散），列表本身不再被换掉：
                    // 以前选中就把整张列表替换成详情页，看起来像「我的房间没显示全」
                    return _RoomCard(
                      key: ValueKey(room.roomId),
                      room: room,
                      expanded: room.roomId == selectedRoomId,
                      onTap: () => onSelectRoom(room),
                      onDoubleTap: () => onEnterRoom(room),
                      onReturnToCall: onReturnToCall,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _EmptyRooms extends StatelessWidget {
  const _EmptyRooms({required this.roomSource});

  final RoomListSource roomSource;

  @override
  Widget build(BuildContext context) {
    final (icon, title, hint) = switch (roomSource) {
      RoomListSource.created => (
        Icons.meeting_room_outlined,
        '还没有你创建的房间',
        '创建一个，或去「我加入的」看看进过的房间',
      ),
      RoomListSource.joined => (
        Icons.exit_to_app_rounded,
        '还没有加入过房间',
        '可以创建一个，或用好友给你的房间号加入',
      ),
      RoomListSource.public => (
        Icons.public_off_rounded,
        '服务器上还没有公开房间',
        '私有房间不会出现在这里，需要房间号才能加入',
      ),
    };
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: context.palette.panel,
                borderRadius: AppRadii.card,
                border: Border.fromBorderSide(
                  BorderSide(color: context.palette.hairline),
                ),
              ),
              child: Icon(icon, size: 20, color: context.palette.textMuted),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.palette.textPrimary,
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.palette.textMuted,
                fontSize: 11.5,
                height: 1.6,
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: () => showJoinRoomDialog(context),
                  icon: const Icon(Icons.login_rounded, size: 14),
                  label: const Text('输入房间号加入'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => showCreateRoomDialog(context),
                  icon: const Icon(Icons.add_rounded, size: 15),
                  label: const Text('创建房间'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RoomCard extends StatefulWidget {
  const _RoomCard({
    super.key,
    required this.room,
    required this.expanded,
    required this.onTap,
    required this.onDoubleTap,
    required this.onReturnToCall,
  });

  final Room room;

  /// 选中：卡片高亮，并在卡片下方展开操作区（房间密码 / 进入房间 / 解散）。
  final bool expanded;

  /// 单击：选中房间（等双击判定结束再执行，否则双击会先被单击吃掉）。
  final VoidCallback onTap;

  /// 双击：直接进房（没密码或密码已记住时一步到位）。
  final VoidCallback onDoubleTap;

  /// 已经在这个房间里时，「进入房间」会变成「回到通话」，点它就是切回通话视图。
  final VoidCallback onReturnToCall;

  @override
  State<_RoomCard> createState() => _RoomCardState();
}

class _RoomCardState extends State<_RoomCard> {
  bool _hovering = false;

  /// 按下即高亮：单击选中要等双击判定，不给即时反馈会显得很迟钝。
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) {
      setState(() => _pressed = value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final room = widget.room;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        child: PanelCard(
          color: widget.expanded || _hovering || _pressed
              ? context.palette.panelElevated
              : context.palette.panel,
          border: widget.expanded ? context.palette.divider : context.palette.hairline,
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: context.palette.accent.withValues(alpha: 0.13),
                      borderRadius: AppRadii.small,
                    ),
                    child: Icon(
                      room.isPublic ? Icons.forum_rounded : Icons.lock_rounded,
                      size: 15,
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
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  height: 1.35,
                                ),
                              ),
                            ),
                            if (room.hasPassword) ...[
                              const SizedBox(width: 5),
                              Icon(
                                Icons.key_rounded,
                                size: 11,
                                color: context.palette.warning.withValues(alpha: 0.9),
                              ),
                            ],
                          ],
                        ),
                        Text(
                          '房间号 ${room.roomId}'
                          '${room.ownerName == null ? '' : ' · 房主 ${room.ownerName}'}',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.palette.textMuted,
                            fontSize: 10.5,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  // 人数 / 状态并成一行，右侧只留一个安静的箭头
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      StatusDot(
                        color: room.online
                            ? context.palette.success
                            : context.palette.textMuted.withValues(alpha: 0.5),
                        size: 5,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        formatCapacity(
                          context.watch<AppState>().memberCountFor(room),
                          room.capacity,
                        ),
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.2,
                          color: room.online
                              ? context.palette.textSecondary
                              : context.palette.textMuted,
                        ),
                      ),
                      if (room.online) ...[
                        const SizedBox(width: 6),
                        Text(
                          '通话中',
                          style: TextStyle(
                            fontSize: 10.5,
                            height: 1.2,
                            color: context.palette.success,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(width: 6),
                  // 复制只在该出现的时候出现：悬停或展开
                  SizedBox(
                    width: 26,
                    child: (_hovering || widget.expanded)
                        ? IconButton(
                            tooltip: '复制房间号',
                            onPressed: () async {
                              await Clipboard.setData(
                                ClipboardData(text: room.roomId),
                              );
                              if (!context.mounted) {
                                return;
                              }
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('房间号 ${room.roomId} 已复制'),
                                ),
                              );
                            },
                            icon: const Icon(Icons.copy_rounded, size: 13),
                          )
                        : null,
                  ),
                  Icon(
                    widget.expanded
                        ? Icons.expand_less_rounded
                        : Icons.chevron_right_rounded,
                    size: 16,
                    color: context.palette.textMuted,
                  ),
                ],
              ),
              if (widget.expanded) ...[
                const Divider(height: 18),
                _RoomDetail(
                  key: ValueKey(room.roomId),
                  room: room,
                  onReturnToCall: widget.onReturnToCall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 选中房间后展开在卡片里的操作区：房间密码 + 进入 / 解散。
///
/// 以前它是一整页详情（选中就把列表顶掉），现在挂在房间卡片下方就地展开——
/// 「我的房间」任何时候都能把房间列全。
class _RoomDetail extends StatefulWidget {
  /// 带上房间 id 作为 key：切换房间时重建状态，密码框才不会残留上一个房间的输入。
  const _RoomDetail({
    super.key,
    required this.room,
    required this.onReturnToCall,
    this.onJoined,
  });

  final Room room;

  /// 已经在这个房间里时，按钮就是「回到通话」。
  final VoidCallback onReturnToCall;

  /// 进房成功后的回调：手机上的底部面板靠它自己关掉。
  ///
  /// 不用「监听 AppState 变了就 pop」：那会在面板重建的同一帧里销毁密码框
  /// 的 controller，Flutter 会先报 `TextEditingController was used after
  /// being disposed`，再抛一次渲染断言，整页变空白。
  final VoidCallback? onJoined;

  @override
  State<_RoomDetail> createState() => _RoomDetailState();
}

class _RoomDetailState extends State<_RoomDetail> {
  final _passwordController = TextEditingController();
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    // 记住过密码的房间直接填上，双击列表就能一步进
    final remembered = context.read<AppState>().roomPasswordFor(
      widget.room.roomId,
    );
    if (remembered != null && remembered.isNotEmpty) {
      _passwordController.text = remembered;
    }
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final state = context.read<AppState>();
    setState(() => _joining = true);
    try {
      final joined = await state.joinRoom(
        roomId: widget.room.roomId,
        password: _passwordController.text.isEmpty
            ? null
            : _passwordController.text,
      );
      if (joined) {
        widget.onJoined?.call();
      }
    } finally {
      if (mounted) {
        setState(() => _joining = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final room = widget.room;
    final isOwner = room.ownerId == state.user?.id;
    // 自己正待在这个房间里（通话中）
    final inThisRoom = state.isInRoom(room.roomId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (room.hasPassword && !inThisRoom) ...[
          SizedBox(
            // 手机上给满宽：260dp 的输入框在 360dp 屏里贴着边很难点
            width: MediaQuery.sizeOf(context).width < 420
                ? double.infinity
                : 260,
            child: TextField(
              textAlignVertical: TextAlignVertical.center,
              controller: _passwordController,
              obscureText: true,
              onSubmitted: (_) => _join(),
              style: const TextStyle(fontSize: 12.5),
              decoration: const InputDecoration(
                hintText: '房间密码',
                prefixIcon: Icon(Icons.key_rounded, size: 14),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            state.hasRememberedRoomPassword(room.roomId)
                ? '已经记住这个房间的密码，双击房间可直接进入'
                : '密码会被记住，下次进来不用再输',
            style: TextStyle(
              color: context.palette.textMuted,
              fontSize: 10.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        Row(
          children: [
            // 已经在这个房间里：别再「重新进一次」（那会把连接和媒体层拆了重建），
            // 按钮改成回到通话视图。
            if (inThisRoom)
              FilledButton.icon(
                onPressed: widget.onReturnToCall,
                icon: const Icon(Icons.meeting_room_rounded, size: 14),
                label: const Text('回到通话'),
              )
            else
              FilledButton.icon(
                onPressed: room.isFull || _joining ? null : _join,
                icon: _joining
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.8),
                      )
                    : const Icon(Icons.login_rounded, size: 14),
                label: Text(room.isFull ? '房间已满' : '进入房间'),
              ),
            if (isOwner) ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  final confirmed = await showConfirmDialog(
                    context,
                    title: '解散房间',
                    message: '房间内所有成员都会被断开，确定解散「${room.name}」吗',
                    confirmText: '解散',
                  );
                  if (confirmed) {
                    await state.deleteRoom(room.roomId);
                  }
                },
                icon: const Icon(Icons.delete_outline_rounded, size: 14),
                label: const Text('解散'),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

// --------------------------------------------------------------------------- //
// 好友
// --------------------------------------------------------------------------- //
class _FriendsPane extends StatefulWidget {
  const _FriendsPane();

  @override
  State<_FriendsPane> createState() => _FriendsPaneState();
}

class _FriendsPaneState extends State<_FriendsPane> {
  final _usernameController = TextEditingController();

  @override
  void dispose() {
    _usernameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final incoming = state.friendRequests
        .where((r) => r.direction == FriendRequestDirection.incoming)
        .toList();
    final outgoing = state.friendRequests
        .where((r) => r.direction == FriendRequestDirection.outgoing)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: AppSizes.pageHeader,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
          child: Row(
            children: [
              const Text('好友', style: AppText.pageTitle),
              const SizedBox(width: 10),
              Text(
                '${state.friends.length} 位',
                style: TextStyle(
                  color: context.palette.textMuted,
                  fontSize: 11.5,
                  height: 1.2,
                ),
              ),
              const SizedBox(width: 10),
              Container(
                width: 3,
                height: 3,
                decoration: BoxDecoration(
                  color: context.palette.textMuted.withValues(alpha: 0.6),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${state.onlineFriends.length} 在线',
                style: TextStyle(
                  color: state.onlineFriends.isEmpty
                      ? context.palette.textMuted
                      : context.palette.success,
                  fontSize: 11.5,
                  height: 1.2,
                ),
              ),
              const Spacer(),
              // 手机上没有下拉刷新，页头这个按钮就是唯一的「手动拉一次」入口：
              // 首次登录那次请求抖掉时，用户不用等 15 秒轮询，也不用重启应用
              IconButton(
                tooltip: '刷新好友',
                onPressed: () => state.refreshFriends(),
                icon: Icon(
                  Icons.refresh_rounded,
                  size: 18,
                  color: context.palette.textSecondary,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.page,
                  16,
                  AppSpacing.page,
                  AppSpacing.xl,
                ),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: AppSizes.control,
                          child: TextField(
                            textAlignVertical: TextAlignVertical.center,
                            controller: _usernameController,
                            style: const TextStyle(fontSize: 12.5),
                            cursorHeight: 15,
                            onSubmitted: (value) =>
                                state.sendFriendRequest(value.trim()),
                            decoration: const InputDecoration(
                              hintText: '输入用户名添加好友',
                              prefixIcon: Icon(
                                Icons.person_add_alt_1_rounded,
                                size: 14,
                              ),
                              prefixIconConstraints: BoxConstraints(
                                minWidth: 32,
                                minHeight: 30,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () => state.sendFriendRequest(
                          _usernameController.text.trim(),
                        ),
                        child: const Text('添加'),
                      ),
                    ],
                  ),
                  if (incoming.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.xl),
                    const SectionLabel(text: '待处理的好友申请'),
                    const SizedBox(height: 8),
                    PanelCard(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          for (var i = 0; i < incoming.length; i++) ...[
                            if (i > 0) const Divider(height: 1),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                12,
                                8,
                                10,
                                8,
                              ),
                              child: Row(
                                children: [
                                  UserAvatar(
                                    userId: incoming[i].user.id,
                                    label: incoming[i].user.displayName,
                                    avatarVersion: incoming[i].user.avatar,
                                    size: 28,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      incoming[i].user.displayName,
                                      style: const TextStyle(
                                        fontSize: 12.5,
                                        height: 1.3,
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        state.respondFriendRequest(
                                          incoming[i].id,
                                          accept: false,
                                        ),
                                    child: const Text('拒绝'),
                                  ),
                                  const SizedBox(width: 4),
                                  FilledButton(
                                    onPressed: () =>
                                        state.respondFriendRequest(
                                          incoming[i].id,
                                          accept: true,
                                        ),
                                    child: const Text('同意'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  if (outgoing.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.xl),
                    const SectionLabel(text: '已发出的申请'),
                    const SizedBox(height: 8),
                    PanelCard(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          for (var i = 0; i < outgoing.length; i++) ...[
                            if (i > 0) const Divider(height: 1),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 11,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      outgoing[i].user.displayName,
                                      style: TextStyle(
                                        color: context.palette.textSecondary,
                                        fontSize: 12.5,
                                        height: 1.3,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    '等待对方处理',
                                    style: TextStyle(
                                      color: context.palette.textMuted,
                                      fontSize: 11,
                                      height: 1.3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.xl),
                  SectionLabel(text: '好友列表'),
                  const SizedBox(height: 8),
                  if (state.friends.isEmpty)
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 18),
                      child: Text(
                        '还没有好友，输入用户名添加',
                        style: TextStyle(
                          color: context.palette.textMuted,
                          fontSize: 11.5,
                          height: 1.5,
                        ),
                      ),
                    )
                  else
                    Column(
                      // 这一处列表不要卡片：底色与外框都去掉，只留行间分隔线
                      children: [
                        for (final (i, friend) in state.friends.indexed) ...[
                          // 内收：左端对齐头像左边（行内左留白 12），
                          // 右端对齐删除图标右边（行内右留白 10 + 图标盒居中多出的 7）
                          if (i > 0)
                            const Divider(
                              height: 1,
                              indent: 12,
                              endIndent: 17,
                            ),
                          _FriendRow(
                            friend: friend,
                            onRemove: () async {
                              final confirmed = await showConfirmDialog(
                                context,
                                title: '删除好友',
                                message:
                                    '确定删除好友「${friend.user.displayName}」吗',
                                confirmText: '删除',
                              );
                              if (confirmed) {
                                await state.api?.removeFriend(
                                  friend.user.username,
                                );
                                await state.refreshFriends();
                              }
                            },
                          ),
                        ],
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 好友列表的一行：头像 + 昵称/状态 + 删除。
///
/// 单独抽出来是因为它要记自己的悬停态——删除按钮平时只露一个很淡的图标，
/// 悬停才变得明确，一列红字「删除」会把整页的注意力拉走。
class _FriendRow extends StatefulWidget {
  const _FriendRow({required this.friend, required this.onRemove});

  final Friend friend;
  final Future<void> Function() onRemove;

  @override
  State<_FriendRow> createState() => _FriendRowState();
}

class _FriendRowState extends State<_FriendRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final friend = widget.friend;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        color: _hovering ? context.palette.hover : Colors.transparent,
        padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
        child: Row(
          children: [
            UserAvatar(
              userId: friend.user.id,
              label: friend.user.displayName,
              avatarVersion: friend.user.avatar,
              size: 30,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                friend.user.displayName,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, height: 1.3),
              ),
            ),
            const SizedBox(width: 8),
            StatusDot(
              color: friend.online
                  ? context.palette.success
                  : context.palette.textMuted.withValues(alpha: 0.5),
              size: 5,
            ),
            const SizedBox(width: 6),
            Text(
              friend.online ? '在线' : '离线',
              style: TextStyle(
                fontSize: 11,
                height: 1.3,
                color: friend.online
                    ? context.palette.textSecondary
                    : context.palette.textMuted,
              ),
            ),
            const SizedBox(width: 10),
            AnimatedOpacity(
              duration: const Duration(milliseconds: 120),
              // 红色本身已经是「危险动作」的信号，平时压到 0.6 够看清但不抢戏
              opacity: _hovering ? 1 : 0.6,
              child: IconButton(
                tooltip: '删除好友',
                onPressed: () => widget.onRemove(),
                icon: Icon(
                  Icons.delete_outline_rounded,
                  size: 14,
                  color: context.palette.danger,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --------------------------------------------------------------------------- //
// 设置
// --------------------------------------------------------------------------- //
class _SettingsPane extends StatelessWidget {
  const _SettingsPane();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final session = state.session;
    final info = state.serverInfo;
    final library = state.music;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: AppSizes.pageHeader,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
          child: Row(
            children: [
              const Text('设置', style: AppText.pageTitle),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.page,
                  16,
                  AppSpacing.page,
                  AppSpacing.xl,
                ),
                children: [
        const _AccountCard(),
        const SizedBox(height: AppSpacing.md),
        PanelCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionLabel(text: '音频设备'),
              const SizedBox(height: AppSpacing.sm),
              _DeviceRow(
                media: state.media,
                input: true,
                onSwitched: state.reapplyMicVolume,
              ),
              const SizedBox(height: AppSpacing.sm),
              _DeviceRow(media: state.media, input: false),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        const _MicCheckCard(),
        const SizedBox(height: AppSpacing.md),
        const _VolumeCard(),
        const SizedBox(height: AppSpacing.md),
        MusicPluginSettingsCard(
          library: library,
          syncing: state.musicSyncing,
          subscriptionUrls: state.musicSubscriptionUrls,
          onRefreshSubscription: () => state.refreshMusicPlugins(force: true),
        ),
        const SizedBox(height: AppSpacing.md),
        const _LogCard(),
        const SizedBox(height: AppSpacing.md),
        PanelCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: AppSpacing.sm),
              _kv(context, '地址', state.endpoint?.display ?? '未连接'),
              _kv(context, '名称', info?.name ?? '—'),
              _kv(
                context,
                '版本',
                info == null
                    ? '—'
                    : 'v${info.version} · 协议 v${info.protocolVersion}',
              ),
              _kv(
                context,
                'ICE 服务器',
                info == null || info.iceServers.isEmpty
                    ? '—'
                    : info.iceServers.join('、'),
              ),
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton.icon(
                onPressed: () => showDiagnosticsDialog(context),
                icon: const Icon(Icons.health_and_safety_rounded, size: 16),
                label: const Text('运行网络诊断'),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        PanelCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionLabel(text: '当前连接'),
              const SizedBox(height: AppSpacing.sm),
              if (session == null || !session.phase.isActive)
                Text(
                  '尚未进入房间',
                  style: TextStyle(color: context.palette.textMuted, fontSize: 12),
                )
              else ...[
                _kv(
                  context,
                  '房间',
                  '${session.room?.name ?? ''}（${session.room?.roomId ?? ''}）',
                ),
                _kv(
                  context,
                  '已直连',
                  '${session.connectedPeerCount}/${session.peerCount} 位成员',
                ),
                _kv(context, '上行码率', formatKbps(session.stats.outgoingKbps)),
                _kv(context, '下行码率', formatKbps(session.stats.incomingKbps)),
                if (session.hasPunchFailure)
                  Padding(
                    padding: EdgeInsets.only(top: AppSpacing.sm),
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
            ],
          ),
        ),
        // 手机上退出登录放在设置页最底部：桌面在左栏页脚有常驻入口，手机没有左栏，
        // 危险动作放到底部也更符合「翻到底才点」的习惯
        if (useCompactLayout(context)) ...[
          const SizedBox(height: AppSpacing.md),
          PanelCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionLabel(text: '账号'),
                const SizedBox(height: AppSpacing.sm),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final confirmed = await showConfirmDialog(
                        context,
                        title: '退出登录',
                        message: '退出后会回到「连接服务器」页面，房间与通话都会断开。'
                            '本地记住的账号密码仍会保留，下次可以直接登录。',
                        confirmText: '退出登录',
                      );
                      if (confirmed && context.mounted) {
                        await context.read<AppState>().logout();
                      }
                    },
                    icon: const Icon(Icons.logout_rounded, size: 16),
                    label: const Text('退出登录'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: context.palette.danger,
                      side: BorderSide(color: context.palette.hairline),
                      minimumSize: const Size.fromHeight(AppSizes.control),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '退出后服务器地址与账号密码仍会保留，可以换一台服务器重新登录',
                  style: TextStyle(
                    color: context.palette.textMuted,
                    fontSize: 11,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 设置页的账号卡片：改昵称（通话中立刻同步给同房间的人）+ 改密码。
class _AccountCard extends StatefulWidget {
  const _AccountCard();

  @override
  State<_AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends State<_AccountCard> {
  final TextEditingController _name = TextEditingController();
  final AvatarPicker _picker = const AvatarPicker();
  String? _nameError;
  String? _avatarError;
  bool _busy = false;
  bool _avatarBusy = false;

  /// 上次挑头像用的目录；再点「更换头像」时从这里开始，不用每次从头翻。
  String? _avatarDir;

  /// 已经同步进输入框的昵称，避免用户正在输入时被重建覆盖掉
  String? _synced;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _nameError = null;
    });
    try {
      await state.updateDisplayName(_name.text);
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(const SnackBar(content: Text('昵称已更新')));
    } on ApiException catch (failure) {
      if (mounted) {
        setState(() => _nameError = failure.message);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /// 选图 → 本地缩放 → 上传。用户取消时静默返回。
  Future<void> _uploadAvatar() async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    // 选图分两端：桌面走应用内选图框（系统文件框在无边框窗口上会把主窗口
    // 压住又禁用），手机走系统相册（安卓分区存储下列不出照片目录），
    // 见 pickImagePath 的注释。
    final path = await pickImagePath(
      context,
      title: '选择头像图片',
      confirmLabel: '用这张当头像',
      initialDirectory: _avatarDir,
    );
    if (path == null || !mounted) {
      return; // 用户取消
    }
    _avatarDir = File(path).parent.path;
    setState(() {
      _avatarBusy = true;
      _avatarError = null;
    });
    try {
      final picked = await _picker.fromPath(path);
      if (!mounted) {
        return;
      }
      if (picked.error != null) {
        setState(() => _avatarError = picked.error);
        return;
      }
      final bytes = picked.bytes;
      if (bytes == null) {
        return;
      }
      await state.uploadAvatar(bytes);
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(const SnackBar(content: Text('头像已更新')));
    } on ApiException catch (failure) {
      if (mounted) {
        setState(() => _avatarError = failure.message);
      }
    } finally {
      if (mounted) {
        setState(() => _avatarBusy = false);
      }
    }
  }

  Future<void> _removeAvatar() async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _avatarBusy = true;
      _avatarError = null;
    });
    try {
      await state.removeAvatar();
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(const SnackBar(content: Text('头像已移除')));
    } on ApiException catch (failure) {
      if (mounted) {
        setState(() => _avatarError = failure.message);
      }
    } finally {
      if (mounted) {
        setState(() => _avatarBusy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final user = state.user;
    if (user == null) {
      return const SizedBox.shrink();
    }
    // 昵称也可能在别处被改（比如另一台设备），这里跟随一次
    if (_synced != user.displayName && !_busy) {
      _synced = user.displayName;
      _name.text = user.displayName;
    }

    return PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel(text: '账号'),
          const SizedBox(height: AppSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 96,
                child: Column(
                  children: [
                    UserAvatar(
                      userId: user.id,
                      label: user.displayName,
                      avatarVersion: user.avatar,
                      size: 64,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextButton(
                      onPressed: _avatarBusy ? null : _uploadAvatar,
                      child: Text(user.avatar == null ? '上传头像' : '更换头像'),
                    ),
                    if (user.avatar != null)
                      TextButton(
                        onPressed: _avatarBusy ? null : _removeAvatar,
                        child: const Text('移除头像'),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kv(context, '用户名', user.username),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        SizedBox(
                          width: 84,
                          child: Text(
                            '昵称',
                            style: TextStyle(
                              color: context.palette.textMuted,
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 320),
                              child: SizedBox(
                                height: AppSizes.control,
                                child: TextField(
                                  textAlignVertical: TextAlignVertical.center,
                                  controller: _name,
                                  maxLength: 48,
                                  style: const TextStyle(fontSize: 12.5),
                                  cursorHeight: 15,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    counterText: '',
                                    hintText: '通话时其他人看到的名字',
                                  ),
                                  onSubmitted: (_) {
                                    if (!_busy) {
                                      _save();
                                    }
                                  },
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_nameError != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        _nameError!,
                        style: TextStyle(
                          color: context.palette.danger,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.md),
                    Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.sm,
                      children: [
                        FilledButton(
                          onPressed: _busy ? null : _save,
                          child: Text(_busy ? '保存中…' : '保存昵称'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => showChangePasswordDialog(context),
                          icon: const Icon(Icons.lock_reset_rounded, size: 16),
                          label: const Text('修改密码'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_avatarError != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              _avatarError!,
              style: TextStyle(color: context.palette.danger, fontSize: 12),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Text(
            '头像会先在本机缩到 256px 再上传；通话中改昵称或头像会立刻同步给同一房间的人',
            style: TextStyle(
              color: context.palette.textMuted,
              fontSize: 11,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}


// --------------------------------------------------------------------------- //
// 音乐插件（MusicFree）
// --------------------------------------------------------------------------- //
/// 设置页的「音乐插件」卡片：订阅同步 + 插件启用/排序/卸载/配置 + 音质。
///
/// 数据全部来自 [MusicFreeLibrary]；订阅地址由服务器下发（`AppState`），
/// 这里**不发请求**，只调 [onRefreshSubscription]。
class MusicPluginSettingsCard extends StatefulWidget {
  const MusicPluginSettingsCard({
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
  State<MusicPluginSettingsCard> createState() =>
      _MusicPluginSettingsCardState();
}

class _MusicPluginSettingsCardState extends State<MusicPluginSettingsCard> {
  MusicFreeLibrary get library => widget.library;

  bool get _busy => widget.syncing || library.syncing;

  // 刻意不在 initState 里自动装载插件：装载要起 worker、把插件源码装进 QuickJS，
  // 是一次实打实的 CPU/IO 活（字节码缓存之后快了很多，但仍然不该在打开设置页时
  // 偷偷跑一遍）。装载只由用户显式点「刷新订阅」触发，可预期、可取消。

  @override
  void initState() {
    super.initState();
    // 「刷新订阅」要先把订阅清单摆给用户选，再只装选中的那些。弹框需要
    // BuildContext，所以由这张卡片挂到 library 上（设置页是唯一入口）。
    library.pickSubscriptionEntries = _pickEntries;
  }

  @override
  void dispose() {
    library.pickSubscriptionEntries = null;
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('卸载插件'),
        content: Text(
          '确定卸载「${plugin.platform}」吗？卸载后需要重新同步订阅才能再用。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.palette.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('卸载'),
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
    final current = library.userVariablesOf(plugin.platform);
    final controllers = <String, TextEditingController>{
      for (final variable in plugin.userVariables)
        variable.key: TextEditingController(text: current[variable.key] ?? ''),
    };
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('配置 ${plugin.platform}'),
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
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('保存'),
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionLabel(
                text: '音乐插件',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton.icon(
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
                      label: Text(_busy ? '装载中…' : '刷新订阅'),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    TextButton(
                      onPressed: _busy || plugins.isEmpty
                          ? null
                          : () => unawaited(library.updateAllPlugins()),
                      child: const Text('更新全部'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              _kv(
                context,
                '插件',
                plugins.isEmpty
                    ? '还没有安装插件'
                    : '共 ${plugins.length} 个（启用 ${library.enabledPlugins.length} 个）',
              ),
              _kv(
                context,
                '订阅地址',
                widget.subscriptionUrls.isEmpty
                    ? '服务器没有下发'
                    : widget.subscriptionUrls.join('、'),
              ),
              _qualityRow(),
              if (library.syncMessage != null)
                _hintText(library.syncMessage!, context.palette.textMuted),
              if (library.syncError != null)
                _hintText('同步失败：${library.syncError}', context.palette.danger),
              const SizedBox(height: AppSpacing.sm),
              if (plugins.isEmpty)
                _emptyHint()
              else
                for (var i = 0; i < plugins.length; i += 1)
                  _pluginBlock(plugins[i], i, plugins.length),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '插件由服务器下发的订阅地址统一管理；单个插件加载失败不影响其它插件，'
                '点歌台会把失败原因标出来。点「刷新订阅」会先列出订阅里的插件，'
                '只装你勾选的（默认前 ${MusicFreePlugins.defaultSelectionSize} 个），'
                '没勾的不下载也不编译。',
                style: TextStyle(
                  color: context.palette.textMuted,
                  fontSize: 11,
                  height: 1.5,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _qualityRow() {
    return Row(
      children: [
        SizedBox(
          width: 84,
          child: Text(
            '音质',
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
            '解析播放地址时向插件要的音质，越高越吃带宽',
            style: TextStyle(color: context.palette.textMuted, fontSize: 11),
          ),
        ),
      ],
    );
  }

  Widget _emptyHint() {
    final message = widget.subscriptionUrls.isEmpty
        ? '服务器还没有配置插件订阅地址'
        : '还没有安装插件';
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
              widget.subscriptionUrls.isEmpty
                  ? message
                  : '$message，点「刷新订阅」重新拉取',
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

  Widget _pluginBlock(MusicFreePlugin plugin, int index, int total) {
    final source = _sourceOf(plugin);
    final details = <String>[
      plugin.subtitle,
      if (source.isNotEmpty) source,
      '${plugin.supportedMethods.length} 项能力',
    ].join(' · ');
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
          Row(
            children: [
              Expanded(
                child: Column(
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
                            '已停用',
                            style: TextStyle(
                              color: context.palette.warning,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      details,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.palette.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              // 手机上这一行固定宽度太贵：把两个排序按钮收成 32dp 的紧凑点击区
              IconButton(
                onPressed: _busy || index <= 0
                    ? null
                    : () => unawaited(library.movePlugin(plugin.hash, -1)),
                iconSize: 16,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                tooltip: '上移',
                icon: const Icon(Icons.arrow_upward),
              ),
              IconButton(
                onPressed: _busy || index >= total - 1
                    ? null
                    : () => unawaited(library.movePlugin(plugin.hash, 1)),
                iconSize: 16,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                tooltip: '下移',
                icon: const Icon(Icons.arrow_downward),
              ),
              if (plugin.userVariables.isNotEmpty)
                TextButton(
                  onPressed: _busy ? null : () => unawaited(_editVariables(plugin)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                  ),
                  child: const Text('配置', style: TextStyle(fontSize: 11)),
                ),
              TextButton(
                onPressed: _busy ? null : () => unawaited(_confirmUninstall(plugin)),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                ),
                child: Text(
                  '卸载',
                  style: TextStyle(fontSize: 11, color: context.palette.danger),
                ),
              ),
              Switch(
                value: plugin.enabled,
                onChanged: _busy
                    ? null
                    : (next) => unawaited(
                        library.setPluginEnabled(plugin.hash, next),
                      ),
              ),
            ],
          ),
          if (plugin.loadError != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '加载失败：${plugin.loadError}',
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
      return '本地安装';
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

/// 设置页的麦克风自检：是否有效 + 实时电平，不进房间也能试麦。
///
/// 「试麦」就是让媒体层单独采集一次麦克风：房间外没有 PeerConnection，
/// 媒体层会用一条本地回环连接产出电平统计，所以不需要服务器也不需要对方在线。
/// 三条音量通道里的两条「本机通道」：麦克风输出音量与音乐播放音量。
///
/// 成员音量在右栏成员列表里（每人一条）。三者互不影响：音乐音量只关本机播放器，
/// 麦克风音量改的是系统录音设备的主音量（对方听到的大小）。
class _VolumeCard extends StatelessWidget {
  const _VolumeCard();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel(text: '音量'),
          const SizedBox(height: AppSpacing.sm),
          AnimatedBuilder(
            animation: Listenable.merge(<Listenable>[
              state.micVolumeController,
              state.musicPlayer,
            ]),
            builder: (context, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                VolumeSliderTile(
                  label: '麦克风音量（对方听到我的大小）',
                  value: state.micVolume,
                  max: 100,
                  icon: Icons.mic_rounded,
                  subtitle: '直接调本机当前默认录音设备的系统音量，与成员、音乐音量互不影响',
                  notice: state.micVolumeSupported
                      ? null
                      : (state.micVolumeNotice ?? '本机没有可调的录音设备'),
                  sliderKey: const Key('mic-volume-slider'),
                  onChanged: state.setMicVolume,
                ),
                const SizedBox(height: AppSpacing.md),
                VolumeSliderTile(
                  label: '音乐音量（只影响本机）',
                  value: state.musicVolume,
                  max: 100,
                  icon: Icons.music_note_rounded,
                  subtitle: '音乐调到 0 也不会影响任何成员的声音，反之亦然',
                  sliderKey: const Key('music-volume-slider'),
                  onChanged: state.setMusicVolume,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MicCheckCard extends StatefulWidget {
  const _MicCheckCard();

  @override
  State<_MicCheckCard> createState() => _MicCheckCardState();
}

class _MicCheckCardState extends State<_MicCheckCard> {
  bool _busy = false;

  Future<void> _toggle() async {
    final state = context.read<AppState>();
    final capturing = state.media.micLevel.value.capturing;
    setState(() => _busy = true);
    try {
      if (capturing) {
        await state.media.stopLocalAudio();
      } else {
        // 用设置页当前选中的麦克风试麦（空值即跟随系统默认设备）
        await state.media.startLocalAudio(
          deviceId: state.media.activeAudioInputId,
        );
      }
    } on MediaException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final inCall = state.session?.phase.isActive ?? false;

    return PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel(text: '麦克风'),
          const SizedBox(height: AppSpacing.sm),
          ValueListenableBuilder<MicLevel>(
            valueListenable: state.media.micLevel,
            builder: (context, mic, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MicStatusLine(level: mic),
                const SizedBox(height: 10),
                // 没在采集时不画电平条：一条灰条只会多出一段看不懂的空白
                if (mic.capturing) ...[
                  MicLevelBar(
                    level: mic.display,
                    enabled: mic.healthy && !mic.muted,
                    speaking: mic.speaking,
                    height: 8,
                  ),
                  const SizedBox(height: 10),
                ],
                Text(
                  mic.healthy
                      ? '对着麦克风说话，绿条应随音量起伏；不说话时应几乎不动'
                      : '点下面的按钮开始试麦，不需要进房间',
                  style: TextStyle(
                    color: context.palette.textMuted,
                    fontSize: 11,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                if (inCall)
                  Text(
                    '通话中麦克风已打开，无需单独试麦',
                    style: TextStyle(color: context.palette.textMuted, fontSize: 11),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _toggle,
                    icon: Icon(
                      mic.capturing ? Icons.stop_rounded : Icons.mic_rounded,
                      size: 16,
                    ),
                    label: Text(mic.capturing ? '停止试麦' : '测试麦克风'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 运行日志：闪退这类问题只能靠日志定位，这里把本次运行的文件路径摆出来，
/// 并提供「打开日志文件夹」——出问题的机器上用户要能把文件发出来。
class _LogCard extends StatelessWidget {
  const _LogCard();

  @override
  Widget build(BuildContext context) {
    final path = AppLog.filePath;
    return PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel(text: '运行日志'),
          const SizedBox(height: AppSpacing.sm),
          Text(
            path ?? '本次运行没有落盘（日志目录不可写）',
            style: TextStyle(
              color: context.palette.textMuted,
              fontSize: 11,
              height: 1.5,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton.icon(
            onPressed: path == null ? null : () => _openDirectory(context, path),
            icon: const Icon(Icons.folder_open_rounded, size: 16),
            label: const Text('打开日志文件夹'),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '遇到闪退时把最新的 client-*.log 发出来即可；同目录里若有 crash-*.log（原生崩溃报告）也一起发',
            style: TextStyle(
              color: context.palette.textMuted,
              fontSize: 11,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openDirectory(BuildContext context, String filePath) async {
    final messenger = ScaffoldMessenger.of(context);
    final directory = File(filePath).parent.path;
    try {
      if (isDesktopPlatform) {
        await Process.run('explorer.exe', <String>[directory]);
      } else {
        // 手机没有「打开所在文件夹」这个概念：把路径本身给用户看
        messenger.showSnackBar(SnackBar(content: Text(filePath)));
      }
    } on Object catch (error) {
      AppLog.warn('打开日志目录失败', error: error);
      messenger.showSnackBar(SnackBar(content: Text('打开失败：$directory')));
    }
  }
}

/// 音频设备选择：麦克风（输入）与扬声器（输出）。
///
/// 列表第一项是「系统默认设备」（空串哨兵），选中表示不指定、跟随系统。
/// 输入设备在桌面端要走 `sourceId` 约束，输出设备要走原生
/// `selectAudioOutput`——两者都在媒体层落地，这里只管选。
class _DeviceRow extends StatefulWidget {
  const _DeviceRow({
    required this.media,
    required this.input,
    this.onSwitched,
  });

  final MediaEngine media;
  final bool input;

  /// 设备切换成功后的回调（麦克风音量要按新设备重新压一次）。
  final VoidCallback? onSwitched;

  @override
  State<_DeviceRow> createState() => _DeviceRowState();
}

class _DeviceRowState extends State<_DeviceRow> {
  /// 「系统默认设备」的哨兵值：空串不会与任何真实 deviceId 冲突。
  static const String _systemDefault = '';

  List<AudioDevice> _devices = const <AudioDevice>[];
  bool _loading = true;
  bool _switching = false;

  @override
  void initState() {
    super.initState();
    // 耳机插拔等设备变化时自动刷新（媒体层订阅系统事件后自增）
    widget.media.audioDevicesVersion.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.media.audioDevicesVersion.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    // 首次加载时 _loading 已是初始值 true，不必再 setState（initState 期间也少一次）
    if (mounted && !_loading) {
      setState(() => _loading = true);
    }
    final devices = await widget.media.audioDevices(input: widget.input);
    if (!mounted) {
      return;
    }
    setState(() {
      _devices = devices;
      _loading = false;
    });
  }

  Future<void> _apply(String deviceId) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _switching = true);
    try {
      if (widget.input) {
        await widget.media.switchAudioInput(deviceId);
      } else {
        await widget.media.switchAudioOutput(deviceId);
      }
      // 新设备有它自己的系统音量：把本机记住的值再压一次
      widget.onSwitched?.call();
    } on MediaException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) {
        setState(() => _switching = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.input
        ? widget.media.activeAudioInputId
        : widget.media.activeAudioOutputId;
    // 选中的设备被拔掉（或还没采集）时回落到「系统默认设备」，别让下拉空白
    final selected = _devices.any((device) => device.deviceId == current)
        ? current!
        : _systemDefault;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 84,
              child: Text(
                widget.input ? '麦克风' : '扬声器',
                style: TextStyle(
                  color: context.palette.textMuted,
                  fontSize: 11.5,
                ),
              ),
            ),
            Expanded(
              child: SizedBox(
                height: AppSizes.control,
                child: DropdownButtonFormField<String>(
                  initialValue: selected,
                  isDense: true,
                  decoration: const InputDecoration(),
                  items: <DropdownMenuItem<String>>[
                    const DropdownMenuItem<String>(
                      value: _systemDefault,
                      child: Text('系统默认设备', style: TextStyle(fontSize: 12)),
                    ),
                    for (final device in _devices)
                      DropdownMenuItem<String>(
                        value: device.deviceId,
                        child: Text(
                          device.displayName,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                  ],
                  onChanged: _switching
                      ? null
                      : (value) {
                          if (value != null) {
                            _apply(value);
                          }
                        },
                ),
              ),
            ),
          ],
        ),
        if (!_loading && _devices.isEmpty) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              const SizedBox(width: 84),
              Icon(
                Icons.warning_amber_rounded,
                size: 14,
                color: context.palette.warning,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '没有检测到设备，请检查系统声音设置后重新检测',
                  style: TextStyle(color: context.palette.textMuted, fontSize: 11),
                ),
              ),
              TextButton(
                onPressed: _load,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('重新检测'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

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

// --------------------------------------------------------------------------- //
// 右栏
// --------------------------------------------------------------------------- //
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
