import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'core/app_log.dart';
import 'core/l10n_ext.dart';
import 'data/api_client.dart';
import 'data/avatar_cache.dart';
import 'data/models.dart';
import 'data/server_endpoint.dart';
import 'data/session_store.dart';
import 'data/volume_store.dart';
import 'media/media_engine.dart';
import 'media/mic_volume_controller.dart';
import 'media/media_port.dart';
import 'music/clock_sync.dart';
import 'music/music_favorites.dart';
import 'music/music_free_library.dart';
import 'musicfree/musicfree_host.dart';
import 'musicfree/musicfree_plugins.dart';
import 'music/music_player.dart';
import 'room/room_music.dart';
import 'room/room_music_sync.dart';
import 'room/room_models.dart';
import 'room/room_session.dart';
import 'signaling/signaling_client.dart';

/// 按服务器地址创建 REST 客户端（单测可替换）。
typedef ApiClientFactory = ApiClient Function(ServerEndpoint endpoint);

/// 应用级状态：服务器连接 → 登录 → 房间/好友 → 进入房间。
///
/// 只有一个信令连接与一份本地采集（麦克风），因此 [media] 归应用所有，
/// 由当前 [session] 接管。
class AppState extends ChangeNotifier {
  /// [apiFactory] 与 [micVolume] 是给测试用的注入口：默认按服务器地址新建真实客户端、
  /// 用真实的系统录音设备音量；单测里可以换成走 MockClient 的实例与假端口。
  AppState({
    SessionStore? store,
    ApiClientFactory? apiFactory,
    MicVolumeController? micVolume,
  }) : _store = store ?? SessionStore(),
       _apiFactory = apiFactory ?? ((endpoint) => ApiClient(endpoint: endpoint)),
       _injectedMicVolume = micVolume {
    _musicQueue.addListener(_onMusicQueueChanged);
    // 启动时把上次的麦克风音量重新压到设备上（读不到就按 100%）
    unawaited(_micVolume.load());
    // 点歌台发现没有可用插件时（比如首次登录那次还在失败重试中）能主动要一次同步
    _music.requestSync = () => _loadMusicPlugins();
    // 上次装好的插件列表先从磁盘登记出来（只读 metadata、不编译 JS）：重启后第一次
    // 进设置页 / 点歌台就能看到它们，而不是空着要等一次「刷新订阅」。
    unawaited(_restoreMusicPlugins());
    // 「我喜欢」是本机缓存：启动时读一次，点进点歌台之前心形状态就已经是对的
    unawaited(_favorites.load());
  }

  final SessionStore _store;
  final ApiClientFactory _apiFactory;

  /// 测试注入的麦克风音量控制器（生产环境为 null，走真实的系统录音设备）。
  final MicVolumeController? _injectedMicVolume;
  final MediaEngine _media = MediaEngine();

  ApiClient? _api;

  /// MusicFree 插件宿主：一个 JS 运行时托管所有插件（与 MusicFree 主进程一致）。
  late final MusicFreeHost _pluginHost = MusicFreeHost();

  late final MusicFreePlugins _pluginStore = MusicFreePlugins(host: _pluginHost);

  /// 点歌台数据源（应用级：搜索、排行榜、热门歌单、插件管理）。
  late final MusicFreeLibrary _music = MusicFreeLibrary(plugins: _pluginStore);

  /// 「我喜欢」：本机收藏（`SharedPreferences`），不进服务器、不跨设备同步。
  final MusicFavorites _favorites = MusicFavorites();

  final RoomMusicQueue _musicQueue = RoomMusicQueue();

  /// 与房间会话共用的时钟偏移：点歌锚点换算成本机时刻就靠它。
  final ClockSync _clock = ClockSync();

  late final MusicPlayer _musicPlayer = MusicPlayer(
    queue: _musicQueue,
    resolve: _music.resolveMedia,
    // 播放前插件还没装好（登录时那次同步失败/还没回来）就补一次
    ensureReady: _loadMusicPlugins,
    // 房间氛围音卡片左侧的滚动歌词：跟随本机播放进度，插件拿不到就显示「暂无歌词」
    loadLyric: _music.lyric,
    clock: _clock,
    // 切歌：服务端模式发 music_skip，本地模式由播放器自己推进队列
    onSkipRoom: _musicQueue.skip,
    onReportEos: ({required entryId, required revision}) =>
        _session?.reportEos(entryId: entryId, revision: revision),
  );

  /// 点歌快照的闸门：离开房间后不再应用、重新进房一定重放（见 `RoomMusicSync`）。
  late final RoomMusicSync _musicSync = RoomMusicSync(
    queue: _musicQueue,
    applyToPlayer: (current, {required revision}) =>
        _musicPlayer.applyRoomState(current, revision: revision),
  );

  /// 三条音量通道的本机存储：成员音量 + 麦克风音量。
  ///
  /// 音乐音量存在 `MusicStore` 里（跟播放器一起读写），三者都是纯本地偏好。
  final VolumeStore _volumeStore = VolumeStore();

  /// 麦克风输出音量（Windows Core Audio，纯本机行为）。
  late final MicVolumeController _micVolume =
      _injectedMicVolume ??
      MicVolumeController(
        load: _volumeStore.loadMicVolume,
        save: _volumeStore.saveMicVolume,
      );

  void _onMusicQueueChanged() {
    // 服务端模式的起播归快照负责（`applyRoomState` 按锚点起播），这里只管本地模式。
    // 队列的这次通知就是从 `applySnapshot` 里同步发出来的，那一刻锚点那一路还没轮到，
    // 在这儿插一脚会让本机先自己放出声音、紧接着被锚点路径重开——「第一首先放一两秒
    // 又回到开头」就是这么来的（后面的歌播放器已经有当前曲，不会走到这里，所以像偶发）。
    if (_musicQueue.serverDriven) {
      return;
    }
    if (_musicQueue.isEmpty) return;
    if (_musicPlayer.current != null || _musicPlayer.playing) {
      return;
    }
    if (_musicPlayer.status == MusicPlayerStatus.resolving) {
      return;
    }
    unawaited(_musicPlayer.playCurrent());
  }

  /// 头像字节缓存：带令牌拉取并按 `<userId>:<版本号>` 命中，见 [AvatarCache]。
  late final AvatarCache avatars = AvatarCache(loader: _loadAvatarBytes);
  ServerEndpoint? _endpoint;
  ServerDescriptor? _serverInfo;
  SignalingClient? _signaling;
  RoomSession? _session;
  /// 上一次看到的会话阶段：用来区分「通话中掉线/被踢」和「进房过程中失败」。
  RoomPhase? _lastSessionPhase;
  User? _user;

  /// 本地记住的服务器地址 / 用户名 / 密码，连接页拿它们回填输入框。
  String? _rememberedAddress;
  String? _rememberedUsername;
  String? _rememberedPassword;

  /// 本地记住的房间密码：`roomId → 密码`。
  final Map<String, String> _roomPasswords = <String, String>{};

  /// 本地凭据是否已经读完（读完之前连接页不回填，免得先闪一下空白再被填上）。
  bool _rememberedLoaded = false;

  bool _busy = false;
  String? _error;
  String? _notice;

  List<Room> _myRooms = const <Room>[];
  List<Room> _publicRooms = const <Room>[];

  List<Friend> _friends = const <Friend>[];
  List<FriendRequest> _friendRequests = const <FriendRequest>[];

  Timer? _roomPollTimer;

  /// 前后台观察者：窗口最小化 / 手机切后台时停掉房间列表轮询。
  _AppVisibilityObserver? _visibilityObserver;
  bool _foreground = true;

  bool _disposed = false;

  ServerEndpoint? get endpoint => _endpoint;
  ServerDescriptor? get serverInfo => _serverInfo;
  ApiClient? get api => _api;
  SignalingClient? get signaling => _signaling;
  MusicFreeLibrary get music => _music;
  RoomSession? get session => _session;
  User? get user => _user;
  MediaEngine get media => _media;
  MusicPlayer get musicPlayer => _musicPlayer;

  /// 「我喜欢」：本机收藏，纯客户端缓存（服务器不知道，换账号也不同步）。
  MusicFavorites get musicFavorites => _favorites;

  /// 麦克风音量控制器（本机默认录音设备的主音量，纯本地）。
  MicVolumeController get micVolumeController => _micVolume;

  /// 本机麦克风输出音量（0~100）。
  double get micVolume => _micVolume.volume;

  /// 本机有没有可调的录音设备（没有时设置页显示降级提示）。
  bool get micVolumeSupported => _micVolume.supported;

  /// 麦克风调不了的降级原因（正常为 null）。
  String? get micVolumeNotice => _micVolume.notice;

  /// 调麦克风音量：立刻改系统录音设备主音量 + 持久化。
  Future<void> setMicVolume(double percent) => _micVolume.setVolume(percent);

  /// 换了麦克风设备之后重新应用一次（新设备有它自己的音量）。
  Future<void> reapplyMicVolume() => _micVolume.reapply();

  /// 本机音乐播放音量（0~100），与房间语音完全独立。
  double get musicVolume => _musicPlayer.volume;

  /// 调音乐音量：只改本机播放器，不碰任何人的语音。
  Future<void> setMusicVolume(double percent) => _musicPlayer.setVolume(percent);
  RoomMusicQueue get musicQueue => _musicQueue;

  /// 上次连过的服务器地址（连接页回填）。
  String? get rememberedAddress => _rememberedAddress;

  /// 记住的用户名（连接页回填）。
  String? get rememberedUsername => _rememberedUsername;

  /// 记住的登录密码（连接页回填）。
  String? get rememberedPassword => _rememberedPassword;

  /// 本地凭据是否已读完。
  bool get rememberedLoaded => _rememberedLoaded;

  /// 该房间记住的密码；没记住时返回 null。
  String? roomPasswordFor(String roomId) => _roomPasswords[roomId];

  /// 是否记住了该房间的密码（有密码的房间据此免输直接进）。
  bool hasRememberedRoomPassword(String roomId) =>
      (_roomPasswords[roomId] ?? '').isNotEmpty;

  bool get isConnectedToServer => _endpoint != null && _serverInfo != null;
  bool get isLoggedIn => _user != null;
  bool get busy => _busy;
  String? get error => _error;
  String? get notice => _notice;

  /// 「我创建的房间」：房主是我自己的那些（公开、私有都算）。
  ///
  /// 与 [myRooms]（我建的 + 我进过的）是**两套不同的逻辑**：
  /// * 导航「我的房间」看的是这一份——只管我建的，用于管理（改名 / 解散）；
  /// * tab「我加入的」看的是 [myRooms]——所有我进过的房间，含别人建的。
  ///
  /// 数据来自同一份 `scope=mine` 响应，按 ownerId 筛即可，不用多跑一次请求。
  List<Room> get createdRooms {
    final me = _user?.id;
    if (me == null) {
      return const <Room>[];
    }
    return _myRooms
        .where((room) => room.ownerId == me)
        .toList(growable: false);
  }

  /// 「我加入的房间」：我创建的 + 我进过的（含私有房间）。
  List<Room> get myRooms => _myRooms;

  /// 公开房间列表（用于发现）。
  List<Room> get publicRooms => _publicRooms;

  /// 房间列表里要显示的人数：身处其中的房间用实时会话成员数，其余用列表快照。
  int memberCountFor(Room room) {
    final session = _session;
    final active = (session != null && session.phase.isActive) ? session : null;
    return displayedMemberCount(
      room: room,
      activeRoomId: active?.room?.roomId,
      activeMemberCount: active?.members.length,
    );
  }

  List<Friend> get friends => _friends;
  List<FriendRequest> get friendRequests => _friendRequests;

  List<Friend> get onlineFriends =>
      _friends.where((friend) => friend.online).toList();

  void clearMessages() {
    _error = null;
    _notice = null;
    notifyListeners();
  }

  // ------------------------------------------------------------------ 启动
  /// 用本地保存的地址/令牌尝试自动恢复会话。
  ///
  /// 无论能否自动恢复，都先把记住的服务器地址、用户名与密码读出来——
  /// 连接页要用它们回填，用户不用每次重新输。
  Future<void> bootstrap() async {
    StoredSession stored;
    try {
      stored = await _store.load();
    } on Object catch (error) {
      // 本地存储读不出来（少数机器上 SharedPreferences 会抛）也要按「首次启动」
      // 走完，尤其是把 rememberedLoaded 置上：否则连接页会一直等一个不会来的
      // 通知，地址/用户名/密码永远停在硬编码默认值上。
      AppLog.warn('读取本地会话失败，按首次启动处理', error: error);
      stored = const StoredSession();
    }
    _rememberedAddress = stored.serverAddress;
    _rememberedUsername = stored.username;
    _rememberedPassword = stored.password;
    _roomPasswords
      ..clear()
      ..addAll(stored.roomPasswords);
    _rememberedLoaded = true;
    notifyListeners();

    final address = stored.serverAddress;
    if (address == null || address.isEmpty) {
      return;
    }
    try {
      await connectToServer(address, silent: true);
    } on Object catch (error) {
      AppLog.warn('自动连接上次的服务器失败', error: error);
      return;
    }
    if (stored.hasToken && _api != null) {
      _api!.token = stored.accessToken;
      try {
        final user = await _api!.me();
        _applyLogin(user, stored.accessToken!);
        // 自动登录不经过连接页，房间/好友得在这里补一轮：否则首屏两个房间 tab
        // 都是空的，只能等 5 秒轮询或用户自己去点「刷新」
        await _loadWorkspace();
      } on Object catch (error) {
        AppLog.info('本地登录状态已失效：$error');
        await _store.clearAuth();
        _api!.token = null;
      }
    }
  }

  /// 连接服务器并拉取能力信息。成功返回 true。
  Future<bool> connectToServer(String address, {bool silent = false}) async {
    final parsed = ServerEndpoint.tryParse(address);
    if (parsed == null) {
      _fail(appL10n.connectAddressInvalid);
      return false;
    }
    // 地址先落盘再连：服务器暂时连不上（重启、换网络、端口还没起）时，
    // 下次打开看到的仍是用户自己填的地址，而不是硬编码的默认值。
    final trimmed = address.trim();
    _rememberedAddress = trimmed;
    _rememberedLoaded = true;
    try {
      await _store.saveServerAddress(trimmed);
    } on Object catch (error) {
      AppLog.warn('保存服务器地址失败', error: error);
    }
    _setBusy(true);
    if (!silent) {
      _error = null;
    }
    _api?.close();
    final api = _apiFactory(parsed);
    try {
      final info = await api.serverInfo();
      final previous = _endpoint;
      _endpoint = parsed;
      _serverInfo = info;
      _api = api;
      _media.updateIceServers(info.iceServers);
      if (previous != parsed) {
        // 换服务器必须换信令连接；头像与点歌台缓存也跟着清（同一 user id 在
        // 另一台服务器上可能是别人，能听的平台/榜单也完全不同）
        await _resetSignaling();
        avatars.clear();
        _music.reset();
      }
      _error = null;
      _notice = appL10n.connectConnectedNotice(info.name, parsed.display);
      return true;
    } on ApiException catch (error) {
      api.close();
      if (!silent) {
        _fail(error.message);
      }
      return false;
    } finally {
      _setBusy(false);
    }
  }

  // ------------------------------------------------------------------ 账号
  /// 登录已有账号。
  Future<bool> signIn({
    required String username,
    required String password,
  }) async {
    final api = _api;
    if (api == null) {
      _fail(appL10n.dataConnectFirst);
      return false;
    }
    _setBusy(true);
    try {
      await _completeLogin(
        await api.login(username: username, password: password),
        password: password,
      );
      return true;
    } on ApiException catch (error) {
      _fail(error.message);
      return false;
    } finally {
      _setBusy(false);
    }
  }

  /// 注册新账号并登录。
  ///
  /// 服务器关闭注册时会失败（code=registration_disabled），错误信息直接展示给用户。
  Future<bool> register({
    required String username,
    required String password,
  }) async {
    final api = _api;
    if (api == null) {
      _fail(appL10n.dataConnectFirst);
      return false;
    }
    _setBusy(true);
    try {
      await _completeLogin(
        await api.register(username: username, password: password),
        password: password,
      );
      return true;
    } on ApiException catch (error) {
      _fail(error.message);
      return false;
    } finally {
      _setBusy(false);
    }
  }

  /// 登录/注册成功后落地会话。[password] 是用户刚输入的明文密码，
  /// 记住它以后连接页就能直接回填。
  ///
  /// 顺序是「先记住内存里的 → 再拉首屏数据 → 最后落盘」：本地存储在少数安卓机上
  /// 会抛错甚至一直不返回，以前卡在落盘上，后面的房间/好友就再也拉不回来——
  /// 用户看到的是首页一片空，得自己点一下刷新才出数据。
  Future<void> _completeLogin(AuthSession auth, {String? password}) async {
    _applyLogin(auth.user, auth.accessToken);
    _rememberedUsername = auth.user.username;
    if (password != null && password.isNotEmpty) {
      _rememberedPassword = password;
    }
    await _loadWorkspace();
    await _persistSession(
      () => _store.saveAuth(
        accessToken: auth.accessToken,
        username: auth.user.username,
        displayName: auth.user.displayName,
        password: password,
      ),
    );
  }

  /// 登录态就绪后拉一轮「工作区」数据：房间列表（我的 + 公开）与好友。
  ///
  /// 登录页登录与启动时自动登录都要走这一步——少了它，首屏的房间列表是空的，
  /// 用户得手动点「刷新」才看得到自己的房间。
  Future<void> _loadWorkspace() async {
    _friendsRetryRound = 0;
    _roomRetryRound = 0;
    await refreshRooms();
    await refreshFriends();
    // 插件订阅也不在这里同步：QuickJS 首次编译要吃掉一份 577KB 的 bundle，
    // 而大部分会话根本不听歌。**登录完成不会碰插件**；真正要听时才由
    // MusicFreeLibrary._ensurePlugins 触发（打开点歌台 / 点歌台里搜索），
    // 或者用户在设置页手点「刷新订阅」。
    // 首屏好友偶尔会拿空（刚登录那一下后端还在忙、或者请求抖了一下）：
    // 补两轮，别让用户盯着空列表等 15 秒后的轮询——那之前他也没有刷新入口。
    if (!_disposed && _friends.isEmpty) {
      _scheduleFriendsRetry();
    }
    // 房间同理：一个都没拿到就先补两轮。手机上没有左栏、也没有常驻的刷新
    // 入口，整屏空白会被当成「我的房间全没了」。
    if (!_disposed && _myRooms.isEmpty && _publicRooms.isEmpty) {
      _scheduleRoomsRetry();
    }
    // 点歌台不在这里预热：平台能力是网络请求，只有真正打开点歌台的用户才需要，
    // 由点歌台界面在挂载时按需调用 `music.loadPlatforms()`。
  }

  List<String> _musicSubscriptionUrls = const <String>[];
  String? _musicSubscriptionHash;

  /// 服务器下发的插件订阅地址（设置页展示用）。
  List<String> get musicSubscriptionUrls => _musicSubscriptionUrls;

  /// 服务器下发的订阅签名（用来判断「URL 是否变过」）。
  String? get musicSubscriptionHash => _musicSubscriptionHash;

  /// 装载 / 同步进行中。
  ///
  /// 必须把 `_musicPluginsInflight` 也算进去：最慢的一段「把磁盘插件装回 worker」
  /// 发生在 `MusicFreeLibrary._syncing` 变 true 之前，只看后者的话界面在那几秒里
  /// 仍然显示可点（用户会以为没反应，反复点）。
  bool get musicSyncing => _musicPluginsInflight != null || _music.syncing;

  /// 手动刷新订阅（设置页「刷新订阅」按钮）。
  ///
  /// 自动补装已经删掉（见 `_syncMusicPlugins`）：只有用户主动点才会 force 重装，
  /// 失败就让用户自己决定要不要再来一次。
  Future<void> refreshMusicPlugins({bool force = false}) {
    return _loadMusicPlugins(force: force);
  }

  /// 启动时把「磁盘上已装插件」登记进宿主，再把列表通知给界面。
  ///
  /// 只读 `musicfree-metadata.json`（不编译 JS、不起 worker）：这是「重启后第一次
  /// 进设置页 / 点歌台能看见之前装过的插件」的那一步。以前只有 `_loadMusicPlugins`
  /// 会调 `loadInstalled()`，于是没点过「刷新订阅」时列表一直是空的。
  Future<void> _restoreMusicPlugins() async {
    await _music.restorePlugins();
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void>? _musicPluginsInflight;

  /// 装载过程中又点了「刷新订阅」：记一笔，等这一轮结束后补跑一次（force 不能丢）。
  bool _musicPluginsForceQueued = false;

  /// 拉取服务器下发的订阅并同步本地插件；并发调用共用同一次请求。
  ///
  /// 同步规则在 `MusicFreePlugins.syncSubscription` 里：签名没变不动本地插件，
  /// 变了就清空重装（等价 MusicFree 的订阅行为）。
  Future<void> _loadMusicPlugins({bool force = false}) {
    final inflight = _musicPluginsInflight;
    if (inflight != null) {
      // 装载中又点了一次按钮：复用同一轮，但 force 不能丢——用户点了「刷新订阅」
      // 却什么都不发生，看起来就是「点了没反应」。等这一轮结束补跑一次。
      if (force && !_musicPluginsForceQueued) {
        _musicPluginsForceQueued = true;
        return inflight.then((_) async {
          _musicPluginsForceQueued = false;
          await _loadMusicPlugins(force: true);
        });
      }
      return inflight;
    }
    late final Future<void> future;
    future = _syncMusicPlugins(force: force).whenComplete(() {
      if (identical(_musicPluginsInflight, future)) {
        _musicPluginsInflight = null;
      }
      if (!_disposed) {
        notifyListeners();
      }
    });
    _musicPluginsInflight = future;
    // 立刻通知一次，但延到微任务：最慢的「把磁盘插件装回 worker」发生在
    // `MusicFreeLibrary._syncing` 变 true 之前，界面只看后者的话那几秒按钮仍可点；
    // 而调用方（点歌台 initState / _ensurePlugins）可能正在 build 中，同步 notify
    // 会撞上「setState() called during build」。
    scheduleMicrotask(() {
      if (!_disposed) {
        notifyListeners();
      }
    });
    return future;
  }

  Future<void> _syncMusicPlugins({bool force = false}) async {
    final api = _api;
    if (api == null || (api.token?.isEmpty ?? true)) {
      return;
    }
    // 不再等系统代理探测：代理交给用户的 TUN/虚拟网卡在系统层接管，
    // 这里直接进插件装载（以前最坏白等 3 秒）。
    // 先把磁盘上已安装的插件装回 JS 运行时（首次启动时为空）
    try {
      await _pluginStore.loadInstalled();
    } on Object catch (error) {
      AppLog.warn('装载本地插件失败', error: error);
    }
    try {
      final subscription = await api.musicPluginSubscription();
      if (_disposed) {
        return;
      }
      _musicSubscriptionUrls = subscription.urls;
      _musicSubscriptionHash = subscription.hash;
      await _music.syncSubscription(
        urls: subscription.urls,
        hash: subscription.hash,
        force: force,
      );
      AppLog.info(
        '插件订阅已同步：${subscription.urls.length} 个订阅地址，'
        '当前 ${_music.plugins.length} 个插件',
      );
      // 插件装上是发生在后台的，界面得知道一声：设置页的插件卡片、点歌台的空态
      // 都靠这条通知重画，否则用户要切出去再切回来才看得见。
      if (!_disposed) {
        notifyListeners();
      }
    } on ApiException catch (error) {
      // 服务器取不到订阅时**不要**清空本地插件：老订阅还能用。
      // 也不再自动补装：装不上往往是网络/音源自己的问题，退避重试只是继续烧
      // 流量与 CPU（还要占 UI 线程去解析 JS）。要重来由用户点「刷新订阅」。
      AppLog.warn('拉取插件订阅失败', error: error);
      if (_disposed) {
        return;
      }
      notifyListeners();
    }
  }

  void _applyLogin(User user, String token) {
    _user = user;
    _api?.token = token;
    _signaling = SignalingClient(
      endpoint:
          _endpoint ?? const ServerEndpoint(host: '127.0.0.1', port: 21077),
      accessToken: token,
    );
    notifyListeners();
    _startRoomPolling();
  }

  Future<Uint8List?> _loadAvatarBytes(int userId, String version) async {
    final api = _api;
    if (api == null) {
      return null;
    }
    try {
      return await api.avatarBytes(userId, version);
    } on ApiException catch (error) {
      AppLog.debug('拉取头像失败：${error.message}');
      return null;
    }
  }

  /// 上传头像（字节由 `AvatarPicker` 选好并缩放）。失败时抛 [ApiException]。
  Future<void> uploadAvatar(Uint8List bytes) async {
    final api = _api;
    if (api == null || _user == null) {
      throw ApiException(
        code: 'not_logged_in',
        message: appL10n.dataSignInFirst,
      );
    }
    final updated = await api.uploadAvatar(bytes);
    _applyProfile(updated);
  }

  /// 移除头像。失败时抛 [ApiException]。
  Future<void> removeAvatar() async {
    final api = _api;
    if (api == null || _user == null) {
      throw ApiException(
        code: 'not_logged_in',
        message: appL10n.dataSignInFirst,
      );
    }
    final updated = await api.deleteAvatar();
    _applyProfile(updated);
  }

  /// 资料变了（昵称/头像）：更新本地账号、同步到当前房间并通知界面。
  ///
  /// 头像版本号不必写本地存储：它每次登录都会随 `/auth/me` 回来。
  void _applyProfile(User updated) {
    _user = updated;
    _session?.updateCurrentUser(updated);
    notifyListeners();
  }

  /// 修改自己的昵称。失败时抛 [ApiException]，由调用方就地展示原因。
  ///
  /// 服务端落库后会把新名字实时播给同房间的其他人，所以通话中改也能立刻生效。
  Future<void> updateDisplayName(String name) async {
    final api = _api;
    final current = _user;
    if (api == null || current == null) {
      throw ApiException(
        code: 'not_logged_in',
        message: appL10n.dataSignInFirst,
      );
    }
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ApiException(
        code: 'invalid_request',
        message: appL10n.dataDisplayNameEmpty,
      );
    }
    if (trimmed == current.displayName) {
      return;
    }
    final updated = await api.updateProfile(displayName: trimmed);
    final token = api.token;
    // 通话中改的：聊天署名与本地成员名一并更新（同房间其他人由服务端广播同步）
    _applyProfile(updated);
    if (token != null) {
      await _persistSession(
        () => _store.saveAuth(
          accessToken: token,
          username: updated.username,
          displayName: updated.displayName,
        ),
      );
    }
    notifyListeners();
  }

  /// 修改密码。成功返回后本地已换用新令牌，**本机不需要重新登录**；
  /// 其他设备上的登录态会在它们下次请求时失效。
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final api = _api;
    if (api == null || _user == null) {
      throw ApiException(
        code: 'not_logged_in',
        message: appL10n.dataSignInFirst,
      );
    }
    final auth = await api.changePassword(
      currentPassword: currentPassword,
      newPassword: newPassword,
    );
    _api?.token = auth.accessToken;
    // 信令连接用的是同一张令牌：热更新，免得掉线重连时拿着旧令牌被拒
    _signaling?.updateAccessToken(auth.accessToken);
    _user = auth.user;
    // 内存里的先换新：落盘只影响「下次回填」，不该让改密码看起来没成功
    _rememberedPassword = newPassword;
    notifyListeners();
    await _persistSession(
      () => _store.saveAuth(
        accessToken: auth.accessToken,
        username: auth.user.username,
        displayName: auth.user.displayName,
        // 记住的密码跟着换新，否则下次回填的是旧密码
        password: newPassword,
      ),
    );
  }

  Future<void> logout() async {
    // 每一步都可能抛：离开房间要走信令、停播放器要碰原生、清令牌要写磁盘。
    // 任何一步失败都不能把「退出登录」卡在半路——那样用户会停在原界面，
    // 以为按钮没反应（手机上尤其明显：没有左栏状态提示，只能干等）。
    // 所以每步单独兜住，最后的「清登录态 + 通知界面」一定要跑到。
    await _logoutStep('离开房间', leaveRoom);
    await _logoutStep('断开信令', _resetSignaling);
    _api?.token = null;
    avatars.clear();
    _music.reset();
    // leaveRoom() 里已经停过一次；这里兜底（比如会话早就断了、leaveRoom 提前返回）
    await _logoutStep('停止氛围音', _musicPlayer.stop);
    _musicQueue.reset();
    await _logoutStep(
      '清除本地令牌',
      // 本地存储偶尔会卡住不返回：退出登录不能停在「清令牌」这一步不动
      () => _store.clearAuth().timeout(
        const Duration(seconds: 3),
        onTimeout: () {},
      ),
    );
    _user = null;
    _myRooms = const <Room>[];
    _publicRooms = const <Room>[];
    _friends = const <Friend>[];
    _friendRequests = const <FriendRequest>[];
    _stopRoomPolling();
    _error = null;
    _notice = null;
    // 服务器地址、用户名、记住的密码都不动：连接页要拿它们回填，下次不用重输
    notifyListeners();
  }

  /// 退出登录里的单步收尾：失败只记日志，绝不打断整个退出流程。
  Future<void> _logoutStep(String what, Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error) {
      AppLog.warn('退出登录：$what 失败（继续退出）', error: error);
    }
  }

  /// 把登录信息写进本地存储，**绝不让它拖住界面和后续流程**。
  ///
  /// 安卓上 `shared_preferences` 偶发抛错，甚至一直不返回；这类失败只该让
  /// 「下次进来要重新输密码」，不该把首屏的房间/好友一起拖死——以前就是卡在
  /// 这一步，用户进了首页只看到一堆空列表，得自己点刷新才出数据。
  /// 超时是兜底：挂住的那个 future 丢在后台，流程照常往下走。
  Future<void> _persistSession(Future<void> Function() write) async {
    try {
      // 5 秒足够慢盘写完；超时只是兜底，挂住的 future 丢在后台（首屏数据早已拉到）
      await write().timeout(const Duration(seconds: 5));
    } on Object catch (error) {
      AppLog.warn('保存登录信息失败', error: error);
    }
  }

  // ------------------------------------------------------------------ 房间
  Future<void>? _roomsInflight;

  /// 首屏一个房间都没拿到时的补拉间隔（两轮，之后交给 5 秒轮询里的那一档）。
  ///
  /// 刚连上网络那一下最容易撞上：手机上后端稍慢、请求抖一下就是整屏空白，
  /// 而手机没有左栏、也没有常驻的刷新入口，用户只能自己去找那个小图标。
  static const List<Duration> _roomsRetryDelays = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 6),
  ];

  int _roomRetryRound = 0;
  Timer? _roomRetryTimer;

  void _scheduleRoomsRetry() {
    if (_disposed || _roomRetryTimer != null) {
      return;
    }
    if (_roomRetryRound >= _roomsRetryDelays.length) {
      return;
    }
    final delay = _roomsRetryDelays[_roomRetryRound];
    _roomRetryRound += 1;
    // 用 Timer 而不是 Future.delayed：退出登录 / 释放状态时要能立刻取消
    _roomRetryTimer = Timer(delay, () {
      _roomRetryTimer = null;
      if (_disposed || _user == null) {
        return;
      }
      unawaited(refreshRooms());
    });
  }

  /// 同时刷新两个范围（飞行中的重复调用直接复用同一次请求）。
  ///
  /// 公开列表用于发现，我的房间（含私有）用于回访——私有房间不会出现在公开列表里，
  /// 只拉公开列表会让用户自己建的私有房间在界面上完全消失。
  ///
  /// 两份列表**分开兜错**（与 [refreshFriends] 同一个道理）：以前任一失败就整轮
  /// 作废，手机端后端稍慢一点首屏就是一片空，用户得自己点刷新才看得到房间。
  /// 现在谁成功谁落地。
  Future<void> refreshRooms() {
    final inflight = _roomsInflight;
    if (inflight != null) {
      return inflight;
    }
    late final Future<void> future;
    future = _refreshRooms().whenComplete(() {
      if (identical(_roomsInflight, future)) {
        _roomsInflight = null;
      }
    });
    _roomsInflight = future;
    return future;
  }

  Future<void> _refreshRooms() async {
    final api = _api;
    if (api == null || _user == null || _disposed) {
      return;
    }
    final results = await Future.wait<List<Room>?>(<Future<List<Room>?>>[
      _fetchRooms(api, RoomScope.public),
      _fetchRooms(api, RoomScope.mine),
    ]);
    // 请求期间可能已经登出（令牌失效时 _fetchRooms 自己会走 logout）或被销毁，
    // 这时候再把旧列表写回去 + notifyListeners 就是往已释放的对象上打
    if (_disposed || _user == null) {
      return;
    }
    final publicRooms = results[0];
    final myRooms = results[1];
    if (publicRooms == null && myRooms == null) {
      return; // 两份都没拿到：保持原样，交给补拉与轮询
    }
    // 轮询每 5 秒一次：内容没变就**不要**通知。以前无脑 notifyListeners，
    // 等于每 5 秒把整棵已登录界面（左栏 + 中栏 + 右栏）重建一遍，
    // 用户在滚动/输入时最容易被这一下打断。
    final changed =
        (publicRooms != null &&
            _roomsSignature(publicRooms) != _roomsSignature(_publicRooms)) ||
        (myRooms != null && _roomsSignature(myRooms) != _roomsSignature(_myRooms));
    if (publicRooms != null) {
      _publicRooms = publicRooms;
    }
    if (myRooms != null) {
      _myRooms = myRooms;
    }
    if (_myRooms.isNotEmpty || _publicRooms.isNotEmpty) {
      _roomRetryRound = 0;
    }
    if (changed) {
      notifyListeners();
    }
  }

  /// 房间列表的轻量签名：只取会影响界面的字段，用来判断「内容真的变了没有」。
  static String _roomsSignature(List<Room> rooms) => rooms
      .map(
        (room) =>
            '${room.roomId}|${room.name}|${room.ownerId}|${room.memberCount}'
            '|${room.capacity}|${room.hasPassword}|${room.isPublic}'
            '|${room.online}|${room.joined}',
      )
      .join(',');

  /// 拉一份房间列表；失败返回 null，两份互不牵连。
  Future<List<Room>?> _fetchRooms(ApiClient api, RoomScope scope) async {
    try {
      return await api.listRooms(scope: scope);
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        await logout();
      } else {
        AppLog.warn('刷新房间列表失败：${error.message}');
      }
      return null;
    } on Object catch (error) {
      // 这个方法是后台轮询与切页调用进来的（fire-and-forget），
      // 让它抛出去只会变成没人处理的异步异常
      AppLog.warn('刷新房间列表失败：$error');
      return null;
    }
  }

  Future<Room?> createRoom({
    required String name,
    int? capacity,
    String? password,
    bool isPublic = true,
  }) async {
    final api = _api;
    if (api == null) {
      _fail(appL10n.dataConnectFirst);
      return null;
    }
    _setBusy(true);
    try {
      final room = await api.createRoom(
        name: name,
        capacity: capacity,
        password: password,
        isPublic: isPublic,
      );
      // 拉一次列表：新建的房间会出现在「我创建的房间」（私有房间尤其是这样）
      await refreshRooms();
      _notice = appL10n.roomsCreatedNotice(room.name, room.roomId);
      return room;
    } on ApiException catch (error) {
      _fail(error.message);
      return null;
    } finally {
      _setBusy(false);
    }
  }

  Future<void> deleteRoom(String roomId) async {
    final api = _api;
    if (api == null) {
      return;
    }
    try {
      await api.deleteRoom(roomId);
      await _forgetRoomPassword(roomId);
      // 解散的是自己正待着的房间：本机先收尾（停播 + 丢会话），
      // 别等着服务端的 room_closed 之后再干活。
      if (isInRoom(roomId)) {
        await leaveRoom();
      }
      await refreshRooms();
    } on ApiException catch (error) {
      _fail(error.message);
    }
  }

  /// 是否**已经**在这个房间里（通话中）。
  bool isInRoom(String roomId) {
    final session = _session;
    return session != null &&
        session.phase.isActive &&
        session.room?.roomId == roomId;
  }

  /// 进入房间并建立 P2P 连接。
  ///
  /// [password] 只在房间设了密码时需要，进房成功后会被记住（下次免输）；
  /// 密码错误则把记住的那份清掉，免得一直拿着废密码重试。
  Future<bool> joinRoom({required String roomId, String? password}) async {
    final signaling = _signaling;
    final user = _user;
    if (signaling == null || user == null) {
      _fail(appL10n.dataSignInFirst);
      return false;
    }
    // 已经在这个房间里就别再拆一次：以前「再进一次同一个房间」会先 leaveRoom()
    // 再新建会话——连接、采集、渲染器全部重建，音乐也会被停掉、队列被清空，
    // 万一重连失败人就掉出房间了。这里直接当成功返回。
    if (isInRoom(roomId)) {
      return true;
    }
    await leaveRoom();
    final session = RoomSession(
      signaling: signaling,
      media: EngineMediaPort(_media),
      currentUser: user,
      music: _musicQueue,
      volumeStore: _volumeStore,
      clock: _clock,
      // 点歌被拒（队列满/冷却/权限）只弹提示，交给点歌台的 snackbar
      onMusicError: _musicQueue.noteError,
    );
    session.addListener(_onSessionChanged);
    _session = session;
    _lastSessionPhase = null;
    notifyListeners();

    try {
      await session.join(roomId: roomId, password: password);
      // 密码是对的：记住它，同一个房间下次直接进
      await _rememberRoomPassword(roomId, password);
      // 进房只预热音质偏好（本地 SharedPreferences），**不装插件、不拉榜单**：
      // 插件装载要先在 QuickJS 里编译运行时 bundle，进房付这笔会表现为「一进房就卡」。
      // 真正的装载等用户点开点歌台（那里有骨架屏）。没开音乐的服务器跳过。
      if (_serverInfo?.musicEnabled ?? false) {
        _music.warmUp();
      }
      // 进过的房间会进入「我加入的房间」，立刻刷新一次，
      // 让左栏马上就能看到自己进的房间和它的实时人数
      unawaited(refreshRooms());
      return true;
    } on RoomException catch (error) {
      if (error.code == 'bad_password') {
        // 房主改过密码之类：把失效的那份清掉，让用户重新输一次
        await _forgetRoomPassword(roomId);
      }
      _fail(error.message);
      _disposeSession();
      return false;
    } on Object catch (error) {
      _fail(appL10n.roomsJoinFailedReason('$error'));
      _disposeSession();
      return false;
    }
  }

  Future<void> _rememberRoomPassword(String roomId, String? password) async {
    final value = password?.trim() ?? '';
    if (value.isEmpty || _roomPasswords[roomId] == value) {
      return;
    }
    _roomPasswords[roomId] = value;
    await _store.saveRoomPassword(roomId, value);
  }
  Future<void> _forgetRoomPassword(String roomId) async {
    if (_roomPasswords.remove(roomId) == null) {
      return;
    }
    await _store.clearRoomPassword(roomId);
  }

  Future<void> leaveRoom() async {
    final session = _session;
    if (session == null) {
      return;
    }
    // 氛围音是本机播的，信令断开不会自动停：先掐掉声音，再清掉房间队列，
    // 否则「人已经离开房间，歌还在响」。
    await _musicPlayer.stop();
    _musicQueue.reset();
    // 旧快照的 revision 不许再参与去重：重新进房要能收下第一份快照
    _musicSync.forget();
    try {
      await session.leave();
    } on Object catch (error) {
      AppLog.warn('离开房间时出错', error: error);
    }
    _disposeSession();
    unawaited(refreshRooms());
  }

  /// 退出前的收尾：离开房间并把媒体层（连接、采集、渲染器）关干净。
  ///
  /// 必须赶在**引擎销毁插件之前**做完：flutter_webrtc 在引擎销毁时会先拆掉
  /// 自己的任务运行器、之后才去停 WebRTC 线程，中间那段窗口期里只要有 WebRTC
  /// 线程回调进插件（刚建连时尤其容易有 onRenegotiationNeeded），就是一次
  /// 访问违例闪退。窗口关闭流程见 `main.dart` 的 `_RootState`。
  Future<void> shutdownMedia() async {
    if (_disposed) {
      return;
    }
    final stopwatch = Stopwatch()..start();
    AppLog.info('退出前收尾：关闭媒体层（连接 / 采集 / 渲染器）');
    // 顺序有讲究：先关媒体。这一步是收尾里最重的部分（每条连接、每个渲染器、
    // 每条采集轨道都要真的释放），也正是「引擎销毁插件之前必须做完」的那部分。
    await _media.dispose();
    final mediaMs = stopwatch.elapsedMilliseconds;
    // 关窗也要把氛围音掐掉：媒体层关了不代表本机播放器停了
    await _musicPlayer.stop();
    // 再走一次 leave()：它内部那套 teardown 这时已经无事可做（连接都关了），
    // 实际只剩「告诉服务器我走了 + 复位房间状态」，开销可以忽略。
    try {
      await _session?.leave();
    } on Object catch (error) {
      AppLog.warn('退出前离开房间失败', error: error);
    }
    AppLog.info(
      '收尾完成：媒体 ${mediaMs}ms，离开房间 ${stopwatch.elapsedMilliseconds - mediaMs}ms',
    );
  }

  void _disposeSession() {
    final session = _session;
    _session = null;
    session?.removeListener(_onSessionChanged);
    session?.dispose();
    // dispose() 自己也会走到这里，此时再 notify 就是「用完已释放的 ChangeNotifier」
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _onSessionChanged() {
    final session = _session;
    if (session == null) {
      return;
    }
    if (session.lastError != null) {
      _error = session.lastError;
    }
    final phase = session.phase;
    final wasActive = _lastSessionPhase == RoomPhase.active;
    _lastSessionPhase = phase;
    // 通话中房间被解散 / 自己被移出：会话已经收尾了，本机这边也得收干净——
    // 尤其是氛围音，它是本机播放器在放，不会跟着房间一起停。
    if (wasActive && (phase == RoomPhase.closed || phase == RoomPhase.failed)) {
      unawaited(_endRoomLocally());
      return;
    }
    // 服务端点歌快照 → 队列视图 + 播放器（锚点驱动）
    _musicSync.apply(session, phase: phase, snapshot: session.musicSnapshot);
    notifyListeners();
  }

  /// 房间在「通话中」被服务端结束（解散 / 被踢）：停播、清队列、丢掉会话。
  Future<void> _endRoomLocally() async {
    await _musicPlayer.stop();
    _musicQueue.reset();
    _musicSync.forget();
    _disposeSession();
    unawaited(refreshRooms());
  }

  // ------------------------------------------------------------------ 好友
  /// 首屏好友拿空时的补拉间隔（两轮，之后交给 5 秒轮询里的那一档）。
  static const List<Duration> _friendsRetryDelays = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 6),
  ];

  int _friendsRetryRound = 0;
  Timer? _friendsRetryTimer;

  void _scheduleFriendsRetry() {
    if (_disposed || _friendsRetryTimer != null) {
      return;
    }
    if (_friendsRetryRound >= _friendsRetryDelays.length) {
      return;
    }
    final delay = _friendsRetryDelays[_friendsRetryRound];
    _friendsRetryRound += 1;
    // 用 Timer 而不是 Future.delayed：退出登录 / 释放状态时要能立刻取消，
    // 否则这条重试会挂着一个 2~6 秒的定时器活到下一次会话里。
    _friendsRetryTimer = Timer(delay, () {
      _friendsRetryTimer = null;
      if (_disposed || _user == null) {
        return;
      }
      unawaited(refreshFriends());
    });
  }

  Future<void>? _friendsInflight;

  /// 拉好友与好友申请。
  ///
  /// 两个接口**分开兜错**：以前任一失败就整轮作废，`/friends/requests` 抖一下
  /// 连已经拿到的好友列表也一起丢掉——手机端后端稍慢时就是这样，用户只能干等
  /// 15 秒后的轮询。现在谁成功谁落地；飞行中的重复调用直接复用同一次。
  Future<void> refreshFriends() {
    final inflight = _friendsInflight;
    if (inflight != null) {
      return inflight;
    }
    late final Future<void> future;
    future = _refreshFriends().whenComplete(() {
      if (identical(_friendsInflight, future)) {
        _friendsInflight = null;
      }
    });
    _friendsInflight = future;
    return future;
  }

  Future<void> _refreshFriends() async {
    final api = _api;
    if (api == null || _user == null || _disposed) {
      return;
    }
    try {
      final friends = await api.listFriends();
      if (_disposed) {
        return;
      }
      _friends = friends;
      if (friends.isNotEmpty) {
        _friendsRetryRound = 0;
      }
      notifyListeners();
    } on ApiException catch (error) {
      AppLog.warn('刷新好友失败：${error.message}');
    } on Object catch (error) {
      AppLog.warn('刷新好友失败：$error');
    }
    try {
      final requests = await api.listFriendRequests();
      if (_disposed) {
        return;
      }
      _friendRequests = requests;
      notifyListeners();
    } on ApiException catch (error) {
      AppLog.warn('刷新好友申请失败：${error.message}');
    } on Object catch (error) {
      AppLog.warn('刷新好友申请失败：$error');
    }
  }

  Future<void> sendFriendRequest(String username) async {
    final api = _api;
    if (api == null) {
      return;
    }
    try {
      await api.sendFriendRequest(username);
      _notice = appL10n.friendsRequestSent(username);
      await refreshFriends();
    } on ApiException catch (error) {
      _fail(error.message);
    }
  }

  Future<void> respondFriendRequest(
    int requestId, {
    required bool accept,
  }) async {
    final api = _api;
    if (api == null) {
      return;
    }
    try {
      await api.respondFriendRequest(requestId, accept: accept);
      await refreshFriends();
    } on ApiException catch (error) {
      _fail(error.message);
    }
  }

  // ------------------------------------------------------------------ 内部
  /// 房间列表的轮询间隔。
  ///
  /// 原来是 5 秒一次。可房间里变的只是「谁进了谁退了」，不是秒级数据；对自部署的小
  /// 机器来说，这却是最稳定的一笔负载。放到 15 秒；好友在线状态变化更慢，两个 tick
  /// （30 秒）刷一次。
  static const Duration _roomPollInterval = Duration(seconds: 15);

  void _startRoomPolling() {
    _roomPollTimer?.cancel();
    _watchVisibility();
    if (!_foreground) {
      // 窗口最小化 / 手机切后台：不排 timer，等回到前台时补一次再继续
      _roomPollTimer = null;
      return;
    }
    var tick = 0;
    // 房间列表的成员数是实时状态，靠轻量轮询保持新鲜。
    // 注意：**通话中不能停**——左栏的房间列表在通话时依然可见，
    // 一旦停掉就会看到冻结的人数（也看不到自己刚进的房间）。
    _roomPollTimer = Timer.periodic(_roomPollInterval, (_) {
      tick += 1;
      unawaited(refreshRooms());
      if (tick % 2 == 0) {
        unawaited(refreshFriends());
      }
    });
  }

  /// 只在第一次调用时挂上前后台观察者。
  void _watchVisibility() {
    if (_visibilityObserver != null) {
      return;
    }
    final observer = _AppVisibilityObserver(_onVisibilityChanged);
    _visibilityObserver = observer;
    WidgetsBinding.instance.addObserver(observer);
  }

  void _onVisibilityChanged(bool visible) {
    if (_disposed || _foreground == visible) {
      return;
    }
    _foreground = visible;
    if (visible) {
      // 回前台先补一次：否则用户看到的是切走那一刻的人数
      unawaited(refreshRooms());
      _startRoomPolling();
      return;
    }
    _roomPollTimer?.cancel();
    _roomPollTimer = null;
  }

  void _stopRoomPolling() {
    _roomPollTimer?.cancel();
    _roomPollTimer = null;
  }

  Future<void> _resetSignaling() async {
    final signaling = _signaling;
    _signaling = null;
    await signaling?.dispose();
  }

  void _setBusy(bool value) {
    if (_busy == value) {
      return;
    }
    _busy = value;
    notifyListeners();
  }

  void _fail(String message) {
    _error = message;
    _notice = null;
    AppLog.warn(message);
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) {
      return; // 幂等：界面与测试收尾都可能触发一次
    }
    _disposed = true;
    _stopRoomPolling();
    final visibility = _visibilityObserver;
    if (visibility != null) {
      WidgetsBinding.instance.removeObserver(visibility);
      _visibilityObserver = null;
    }
    // 补拉用的定时器在这里收掉：留着会一直吊到下一次会话，
    // 测试收尾时也会被判成「组件树销毁后仍有 Timer 挂着」
    _friendsRetryTimer?.cancel();
    _friendsRetryTimer = null;
    _roomRetryTimer?.cancel();
    _roomRetryTimer = null;
    _disposeSession();
    unawaited(_signaling?.dispose());
    unawaited(_media.dispose());
    _api?.close();
    _pluginHost.dispose();
    _micVolume.dispose();
    _favorites.dispose();
    super.dispose();
  }

  bool get isDisposed => _disposed;
}


/// 监听前后台切换，用来启停房间列表轮询。
///
/// 单独抽出来而不是让 `AppState` 直接 `with WidgetsBindingObserver`：AppState 是
/// ChangeNotifier，混入观察者会让它的类型变复杂，测试里也不好塞假的生命周期。
class _AppVisibilityObserver with WidgetsBindingObserver {
  _AppVisibilityObserver(this.onChanged);

  final void Function(bool visible) onChanged;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    onChanged(state == AppLifecycleState.resumed);
  }
}
