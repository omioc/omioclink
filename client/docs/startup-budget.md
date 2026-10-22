# 启动与插件性能预算

这份文档记录两件事：**性能打点在哪、口径是什么**，以及**改动过哪些点**。
排查"首次启动很卡"时，先照本文 §1 抓一份日志，再谈优化。

## 1. 打点（已内置，正式发布也保留）

所有打点都走 `AppLog.timing(场景, 时长)`，落到 `client-<时间>.log`，形如
`2026-10-21 21:37:04.123 [INFO] omioclink: 启动.首帧：812ms`。
在日志里 grep `ms` 就能拼出时间线。

| 场景 key | 含义 | 代码位置 |
| --- | --- | --- |
| `启动.AppPaths` | 数据根目录就绪 | `lib/main.dart` |
| `启动.runApp 前` | 首帧之前被 await 的全部初始化（窗口、日志）走完 | `lib/main.dart` |
| `启动.首帧` | 第一帧画完；**这是"冷启动"的验收口径** | `lib/main.dart` |
| `插件.JS 运行时创建` | `getJavascriptRuntime` + 桥注册 | `lib/musicfree/musicfree_host.dart` |
| `插件.bundle 读取` | `rootBundle` 读 `runtime.bundle.js`（约 577KB） | 同上 |
| `插件.bundle 编译执行` | 运行时 bundle 进引擎（缓存命中时只有反序列化）；**每次进程启动一次** | 同上 |
| `插件.字节码 <标签>` | 命中磁盘字节码后「读文件 + 反序列化 + 执行」的耗时 | 同上 |
| `插件.编译 <标签>` | 没命中缓存时把源码编译成字节码（并落盘）的耗时 | 同上 |
| `插件.worker#N 就绪（含引擎预热）` | worker isolate 起来 + QuickJS 运行时建好 + bundle 装载完 | 同上 |

后三条是 §3.8 的字节码缓存加进来的：`<标签>` 是 `bundle` 或 `插件<hash 前 8 位>`。
worker 里的打点经端口回主 isolate 再落盘（见 `MusicFreeEngine.timingSink`）。

`启动.首帧` 之后 3 秒会清一次 7 天前的旧日志（同步 IO 不占启动路径）。

## 2. 当前预算（目标值，需实机日志校准）

| 指标 | 目标 |
| --- | --- |
| 冷启动 → 首帧（首次安装） | ≤ 1.2 s |
| 冷启动 → 首帧（后续启动） | ≤ 0.8 s |
| 首帧后 3 s 内单次主线程阻塞 | ≤ 50 ms |
| 首次插件同步（5 个插件） | ≤ 8 s，且 UI 不卡 |
| 二次启动 → 点歌台可用 | ≤ 2 s |
| 稳态空闲（未进房） | 无周期 rebuild，CPU ≤ 1% |

## 3. 这一轮改了什么（按用户可感知的顺序）

### 3.1 启动路径

- **不再探测系统代理**：删掉 `core/system_proxy.dart`（含 `reg query` 子进程、
  8 端口扫描、TLS 探测）与设置页那张「音源代理」卡片。代理交给用户的
  TUN / 虚拟网卡在系统层接管；插件 HTTP 客户端不再设 `findProxy`。
- **libmpv 延迟加载**：`MediaKit.ensureInitialized()` 从 `main()` 挪到
  `MusicPlayer._createPlayer()`，第一次真的要播才映射那份 14.8MB DLL。
- **日志异步缓冲**：`LogFile.write` 改为内存缓冲 + 120ms 刷盘（或攒满 32KB），
  `close()`/`flush()` 显式落盘；过期日志清理挪到首帧后 3 秒。
- 窗口初始化保持在启动序列末尾（紧贴 `runApp`），窗口出现即接近首帧。

### 3.2 音乐插件

- **订阅改为差集安装**：URL 列表一致 → 一条请求都不发；只装新增、只卸被移除，
  不再 `uninstallAll()` 全量重装。归属关系记在订阅文件里（`owned`）。
- **失败不再自动重试**：删掉 3/8/20/45 秒的退避重试；要重装由用户点设置页
  「刷新订阅」（`force: true`）。
- **单次 evaluate 装载插件**：`__mfRuntime.install()` 在 JS 侧一次完成
  "建 require → 执行源码 → describe"，每插件从 4 次进引擎降到 1 次。
- **运行时 bundle 压缩**：esbuild `minify: true`，1.12 MB → 577 KB
  （`node tool/build_musicfree_runtime.mjs` 重新生成）。
- **不再在登录后自动同步订阅**：QuickJS 只在真正要用音乐时 boot。
  触发点只剩「打开点歌台」和「用户点设置页的『刷新订阅』」——
  **进房不再触发**（进房只读音质偏好），因为 bundle 编译是同步的，会把窗口冻住。
- **进房 warmUp 不碰插件**：进房只读本地音质偏好；排行榜/标签/插件装载都要等
  用户真的点开点歌台（那里有骨架屏，卡一下也解释得清）。

### 3.3 渲染与通知

- 麦克风电平：采样 100ms → 200ms，`MicLevelBar` 加 `RepaintBoundary`，
  静默（≤0.001）时不再跑补间动画；说话指示的模糊阴影改 1.5px 实边。
- 通话统计：2s → 3s 一次 `getStats`。
- 点歌台搜索结果：`ListView(children:)` → `ListView.builder`（只建可见项）。
- 成员条：`ListView(children:)` → `ListView.builder`（末尾「邀请」格用 index 判断）。
- 壁纸：`ResizeImage` 按窗口像素尺寸解码，不再"原图解码 + 每帧缩放"。
- **根 build 收窄**：`_RootState.build` 从 `context.watch<AppState>()` 改成
  `context.select` 只看 6 个字段；房间轮询按内容签名比对，**内容没变不再 notify**
  （以前每 5 秒把左栏+中栏+右栏重建一遍）。
- **点歌台分区订阅**：以前整块包在一个 `AnimatedBuilder(Listenable.merge(4 个源))`
  里（播放进度一跳就全重建，且 merge 是 build 里现造的）；现在
  `_contentSources / _queueSources / _nowPlayingSources` 三个 `late final` 字段，
  搜索框只订阅 `library`、左导航不订阅、内容区/队列栏/播放条各自订阅所需源。

### 3.4 榜单 / 标签落盘

`MusicFreeService` 的排行榜（`topLists`）、热门歌单标签（`recommendTags`）、
标签下歌单（`sheetsByTag`）改成三层读取：**内存 10 分钟 → 磁盘 6 小时（`MusicFreeCache`）
→ 插件**。`refresh: true` 绕开两层并在成功后覆盖磁盘；插件失败/返回空不写盘。
缓存 key = `方法|插件hash|参数(标签id/页码)`，插件更新后自然失效。
（`MusicFreeSheet` 等模型的 `toJson/fromJson` 就地补在 `musicfree_service.dart`。）

### 3.5 P2：QuickJS 进 worker isolate（这一轮的核心）

`musicfree_host.dart` 现在拆成两层：

* **`MusicFreeEngine`**（原 `MusicFreeHost` 本体）：真正的 QuickJS 运行时 + 全部桥
  （HTTP / storage / cookie / timer），只在 worker isolate 里存在。
* **`MusicFreeHost`**（门面）：主 isolate 侧，负责 spawn worker、收发 JSON、
  缓存插件元数据（`plugins` / `byHash` 仍是同步 API），对外 API 与以前完全一致。

关键设计：

* **bundle 在 spawn 前读好**传进去（子 isolate 里没有 `rootBundle` / `AppPaths`）。
* **HTTP 反向代发**：worker 把请求（method/url/headers/bodyBase64）发给主 isolate，
  由主 isolate 上的 `http.Client` 真正发出 —— 这样 `MockClient` 之类注入仍然有效，
  测试里「观察派发出去的 URL」的用例一条都不用改。
* **日志经端口回主 isolate**：worker 里 `AppLog` 落不到文件，插件 console 日志改走
  `logSink`；`WARN` 仍然即时刷盘。
* **崩溃隔离**：worker 挂掉只会让 pending 请求抛 `MusicFreeException`，应用不再被
  插件（`0xc00000fd`）一起带走；下次调用会自动重新 spawn。
* 新增打点 `插件.首次装载（worker 内含 JS 编译）`：包含 worker 启动 + 577KB bundle
  编译 + 插件源码执行。**这条现在慢也没关系——它不在 UI 线程上**。

### 3.6 真机反馈的三个问题（已修）

1. **装载过程 UI 不刷新**：`syncSubscription` 新增 `onProgress` 回调，
   `MusicFreeLibrary` 每装上一个插件就更新 `_syncMessage`（「已装载 N 个插件」）并
   `notifyListeners()`。以前只有整轮结束才通知一次。
2. **「突然说没有插件，从头再装」**：根因是 `syncSubscription` 在**服务器下发空
   列表**时会 `uninstallAll()` —— 一次瞬时的空响应就能把本地插件全删了。
   现在空列表只提示「服务器没有下发订阅地址（本地插件已保留）」，不动本地文件。
   同时给 worker 加了 `runZonedGuarded`：插件里的未捕获异常不再让 worker 退出
   （退出就会表现为「插件全没了」）。
3. **装插件太慢**：加了分段打点，日志里现在能看到
   `插件.下载 <url>：Xms`、`插件.编译 <平台>：Xms`、
   `插件.首次装载（worker 内含 JS 编译）：Xms`；订阅安装改成 **3 路并发下载**
   （编译仍在 worker 内串行，因为 JS 是单线程）。瓶颈是网络还是 QuickJS 编译，
   看这三条日志就能定位。
4. **装载期间按钮可点（能连点）**：`AppState.musicSyncing` 现在把
   `_musicPluginsInflight` 也算进去 —— 最慢的「把磁盘插件装回 worker」发生在
   `MusicFreeLibrary._syncing` 变 true **之前**，只看后者的话那几秒按钮仍可点。
   `_loadMusicPlugins` 开始/结束各通知一次（开始那次走 `scheduleMicrotask`，
   避免调用方在 build 中触发导致 `setState() during build`），界面据此把
   「刷新订阅」变成「装载中… + 转圈」、连同「更新全部」「上移/下移/配置/卸载/启用」
   一起禁用；`MusicFreeLibrary.syncSubscription` / `updateAllPlugins` 另加了
   重入保护，连点也只会复用同一轮。
5. **装插件慢（实测 30 个约 5.5 分钟）**：瓶颈是 QuickJS 编译，不是网络
   （`插件.下载` 只有 276ms）。做了两件事：
   * **源码只转义一次**：以前 `jsonEncode(整个 payload)` + JS 侧 `JSON.parse`
     等于把源码解析三次、字面量接近翻倍；现在 code 作为独立参数传。
   * **worker 池 + 元数据复用**（见 §3.7）。

### 3.7 worker 池 + 元数据复用（“最好的形态”）

* **worker 池**：`MusicFreeHost` 按需扩充 worker（`_poolSize`）：**桌面**
  ≥8 核取 3、否则 2；**移动端固定 2**（手机内存紧，3 份 QuickJS 运行时容易被
  系统杀掉）。`loadInstalled` 用 3 路并行编译 —— QuickJS 单线程，唯一能并行的
  办法就是多开运行时。串行装载时只会起 1 个，不会平白多占内存。
* **元数据复用**：每个插件的 `describe` 结果落盘到
  `musicfree-metadata.json`（key = 源码 hash）。启动时
  `restoreMetadata()` 只**登记**不编译 —— 插件列表立刻可见；
  `invoke()` 里发现「登记了但没编译」才读盘编译（`插件.按需编译 <平台>`）。
  `loadInstalled` 顺带走一遍 `prefetch()`，在后台把剩下的逐个补上。
* 新增打点：`插件.worker#N 就绪（含 bundle 编译）`、`插件.按需编译 <平台>`。

代价与注意：
* 每个 worker 都要自己编译一遍 577KB bundle，内存与启动成本 ×N（默认 2~3）。
  **§3.8 的字节码缓存已经把这笔账消掉了**：首份编译并落盘，其余读缓存。
* 重启后的**第一次**搜索/榜单如果撞上还没编译完的音源，那个音源会因为超时被跳过；
  后台 `prefetch()` 跑完（约几十秒）就恢复正常。插件顺序/启用状态来自偏好文件，
  不受元数据缓存影响。
* 卸载插件时会同时清掉它的元数据（`forgetMetadata`），不会「复活」。

### 3.8 字节码缓存 + 引擎按发布版编译（这一轮的核心，彻底解决「装载极慢」）

真机日志里的数字（改前）：`插件.装载 agg：22239ms`、`插件.编译 kugou：6170ms`，
577KB 的运行时 bundle 每个 worker 各要编译一遍（`插件.worker#N 就绪：32ms` 只是
isolate 起来了，真正的编译被算进了第一个插件的装载里）。53 个插件装完 5 分钟起步。

**根因有两个，都不是网络**（`插件.下载` 只有 70~400ms）：

1. **QuickJS 每次都从源码重新编译**：插件是「一整份几 MB 的 JS」，`JS_Eval` 每次
   装载都要做一遍词法/语法分析。
2. **引擎被编成了 Debug**：`flutter run` 出来的构建让 CMake 走 Debug 配置，MSVC 就是
   `/Od`，GCC/Clang 就是不优化。QuickJS 的解析器在这个级别下慢两个数量级。

做了四件事（不改变任何插件行为）：

1. **引擎内置进仓库**（`packages/quickjs_engine_local`，`dependency_overrides` 指向它）：
   上游桥只导出 `JS_Eval`，我们补了 `jsCompileToBytecode` / `jsEvalBytecode` /
   `jsFreeBinaryBuffer` 三个 C 导出（QuickJS 本来就有 `JS_WriteObject` / `JS_ReadObject`，
   `qjsc` 就是这么发布预编译脚本的）。Dart 侧是 `QuickJsRuntime2.compileToBytecode` /
   `evaluateBytecode`，符号缺失时（没重编的旧 DLL）自动退回源码路径。
2. **引擎永远按发布版编译**：`native/CMakeLists.txt` 给 Debug/Profile 也追加 `/O2`、`/Oi`
   （MSVC）或 `-O2`，并摘掉与 `/O2` 互斥的 `/RTC1`；同时加 `/utf-8`（不然后面的中文注释
   在 GBK 代码页下会把下一行吞进注释，直接编不过）。
3. **字节码磁盘缓存**（`lib/musicfree/musicfree_bytecode.dart`）：`<数据根>/musicfree-data/bytecode`，
   文件名 = `v<格式版本>-plugin-<源码 sha256>.qbc`（bundle 单独一套 `bundle-` 前缀）。
   源码一变键就变；反序列化失败会自动删缓存重编译；插件卸载/更新时清掉旧文件
   （一个插件几 MB，不清会攒出几百 MB）。
4. **插件包装方式固定下来**：`Function('require', …)` 换成等价的
   `globalThis.__mfPluginFactory = (function (require, …) { 'use strict'; <源码> });`，
   编译产物就是这个脚本的字节码；运行时 `install()` 发现全局上有工厂就用它，
   没有才回退源码编译。**改这段包装（或改桥）必须同时把 `formatVersion` +1**。

顺带修的三个结构问题：

* **worker 先暖机再报到**：`MusicFreeEngine.boot()` 在把 SendPort 发回去之前就把
  QuickJS 建好、bundle 装好。于是「worker 就绪」这个数字终于可信，`_pickLink` 选到的
  空闲 worker 也真能立刻干活（以前第一份插件要替整个 worker 付 bundle 的编译时间）。
* **worker 启动串行化**：冷启动时三份 worker 各自编译一遍 bundle 是纯浪费；现在排队启动，
  第一个编译并把字节码写进磁盘，后面的直接读。
* **worker 里的打点回传主 isolate**（`timingSink`）：`插件.字节码 <标签>` /
  `插件.编译 <标签>` 现在能落进 `client-*.log`，缓存命中率一眼可见。

实测（同一台机器，用真实插件源码，`flutter test` 里量的）：

| 对象 | 源码体积 | 改前（Debug/`Od`，日志） | 改后（`/O2` 首次编译） | 改后（命中字节码） |
| --- | --- | --- | --- | --- |
| 运行时 bundle | 577KB | ≈5.7s（每 worker 一次） | 88ms | **25ms**（字节码 2.2MB） |
| 聚合插件 agg | 2.96MB | 22013ms | 348ms | **24ms**（字节码 12.0MB） |
| 一般插件 | 150~190KB | 4~6s | 15~16ms | **1~2ms** |
| 小插件 | 11KB | 500~700ms | 3ms | **0ms** |

代价与注意：

* **磁盘**：字节码会把源码与调试信息一起序列化（体积约源码的 3~4 倍）。53 个插件
  源 8.2MB → 字节码约 35MB。卸载/更新会自动清理，见 `prunePlugins`。
* **首次运行**仍要编译一遍（最坏 348ms/插件，3 路并行约 2~4 秒装完 53 个），之后
  每次启动、每个 worker 都是读缓存。
* **换引擎版本/改包装方式必须 `MusicFreeBytecodeCache.formatVersion + 1`**，否则会读到
  格式不兼容的字节码（虽然会自动自愈重编译，但那是一次白跑的编译）。
* 字节码按「源码 sha256」命名，与插件文件名同源，所以「插件更新」天然失效，
  不需要额外的版本比对。
* **未验证**：Android 上只验证了 native 库能编出（NDK r28 / arm64 / clang，
  已确认导出三个新符号），没在真机上跑过装载耗时；armv7/x86 也没单独编。

### 3.9 订阅清单按需勾选（不再「清单里有几个就装几个」）

订阅清单里常见的数量是 50+（`hebijunge/musicfree-plugins` 的 `plugins-fastly.json`
有 57 个）。以前「刷新订阅」= 把清单里每一个都下载 + 编译 + 装载，即使只用两三个
音源。现在：

* **点「刷新订阅」→ 先只读清单（一次请求），弹框让用户勾**；默认勾清单前
  `MusicFreePlugins.defaultSelectionSize`（6）个，可全选/全不选，确认后
  **只下载、只编译、只装载勾中的那些**（没勾的连请求都不发）；
* 选择记进 `musicfree-subscription.json` 的 `selection`（订阅地址 → 插件地址列表），
  下次启动/后台同步沿用；再点刷新时把上次的选择作为预设勾选值交回弹框；
* 刷新时「取消」= 一个插件都不动（`SubscriptionSyncResult.cancelled`）；
  刷新时选得比上次少 → 被取消的那些会连同源码一起卸载；
* 弹框由设置页的插件卡片注入（`MusicFreeLibrary.pickSubscriptionEntries`），
  后台同步（启动 / 进房）没有 UI 就不弹框，按「上次的选择 / 默认前 6 个」走——
  绝不因为「没弹框」就把几十个插件全装回来；
* 纯 `.js` 订阅（单插件）不弹框，也不会为「读清单」多发一次请求（以前同一份源码
  会下两遍）。`force` 的「重装」也只动这条订阅带来的插件，不再 `uninstallAll()`。

实现：`MusicFreePlugins.fetchSubscriptionEntries` / `syncSubscription(pickEntries:)` /
`_installEntries`；弹框是 `features/dialogs.dart` 的 `showPluginPickerDialog`。
## 4. 还没做的（下一轮）

1. **worker 内部的 `AppLog` 调用**（bundle 编译耗时、卸载失败等）目前只进
   `developer.log`：如果需要它们落到 `client-*.log`，得把这几处也接到 `logSink`。
2. 好友页 / 设置页仍是 `ListView(children:)`：受产品规模限制（私人小圈子），
   评估后**暂不改**（改成 `CustomScrollView` + sliver 属于结构改造）。
3. ~~字节码/快照缓存~~ **已完成**，见 §3.8（vendor 引擎 + 三个 C 导出 + 磁盘缓存）。
   还剩两件小事：Android 真机耗时未实测；iOS/macOS 平台目录在 vendored 包里已删
   （客户端只构建 Windows/Android）。
4. `sheetsByTag` 没有 `refresh` 参数（加它会破坏 3 个既有 test stub）；
   要作废标签下的歌单走 `clearCache()`。
