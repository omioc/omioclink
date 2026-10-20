# OmiocLink 客户端

Flutter 编写的桌面 + 手机客户端：Windows 无边框窗口，安卓手机单栏；**平板与桌面沿用同一套三栏布局**
（短边 ≥ 600dp），手机（短边 < 600dp）自动切单栏 + 底部导航，判定见 `lib/core/platform.dart`

---

## 一、环境要求

| 用途 | 需要 |
| --- | --- |
| 公共 | Flutter **3.47.7 stable** / Dart 3.13.5 |
| Windows 端 | Visual Studio 2022/2026，勾选「使用 C++ 的桌面开发」+ Windows 10/11 SDK |
| 安卓端 | **JDK 21**、Android SDK（platform 36、build-tools 36.0.0、platform-tools、emulator）、NDK（版本由 Flutter 指定，当前 28.2.13676358） |

安卓构建需要的两个环境变量（用户级即可）：

```powershell
[Environment]::SetEnvironmentVariable('JAVA_HOME', 'D:\Java\jdk-21', 'User')
[Environment]::SetEnvironmentVariable('ANDROID_HOME', 'D:\Android\Sdk', 'User')
```

改完新开终端，`flutter doctor -v` 的 Android toolchain 那一段应该是 `[√]`

---

## 二、本地跑起来

**桌面（Windows）**

```powershell
cd client
flutter run -d windows
```

**手机（模拟器）**

```powershell
cd client
flutter emulators                        # 看已建好的 AVD
flutter emulators --launch Omio_393x852  # 先起模拟器（393×852dp）
flutter run -d emulator-5554             # 再跑应用
```

本机已备好 4 档尺寸（AVD 数据在 `D:\Android\avd`，靠 `ANDROID_AVD_HOME` 指向）：

| AVD | 分辨率 @dpi | 等效 dp | 覆盖机型 |
| --- | --- | --- | --- |
| `Omio_360x780` | 1080×2340 @480 | 360×780 | 安卓窄屏下限 |
| `Omio_375x667` | 750×1334 @320 | 375×667 | iPhone SE 类（最矮，必测） |
| `Omio_393x852` | 1180×2556 @480 | 393×852 | iPhone 15 类 |
| `Omio_411x914` | 1080×2400 @420 | 411×914 | Pixel 7 / 主流大屏 |

**手机（真机）**

手机打开「开发者选项 → USB 调试」（小米还需「USB 安装」「USB 调试(安全设置)」），然后：

```powershell
adb devices          # 确认设备
flutter devices      # 拿设备 id
flutter run -d <设备id>
```

模拟器和真机都支持热重载（`r`）/ 热重启（`R`）

---

## 三、构建发布包

所有产物统一收拢到**仓库根的 `releases/client-v<tag>/`**（`<tag>` 取 `pubspec.yaml` 的 `version:`，
`x.y.z+build` 只保留 `x.y.z`），文件名也带版本，拿到一个包就知道它是哪一版；`releases/` 在 `.gitignore` 里，不进版本库

先构建，再用脚本收拢（`tool/stage_release.ps1`，自动读版本号并建目录）：

```powershell
cd client
flutter build windows --release        # 只打安卓时可跳过
flutter build apk --release
powershell -ExecutionPolicy Bypass -File tool\stage_release.ps1
# 只想收一端：加 -Target windows 或 -Target android
```

落到 `..\releases\client-v<tag>\`：

| 产物 | 来源 | 体积 |
| --- | --- | --- |
| `omioclink-client-win-x64-<tag>.zip` | `build\windows\x64\runner\Release\` 整个目录（`omioclink_client.exe` + dll + `data\`） | ~29 MB |
| `omioclink-client-android-<tag>.apk` | `build\app\outputs\flutter-apk\app-release.apk`，4 个 ABI 全带 | ~112 MB |

- Windows 包解压到任意目录双击 exe 就能跑，不需要安装；`Compress-Archive` 写出的条目分隔符是反斜杠
  （`data\app.so`），Windows 解压无影响；要到 Linux/macOS 上解压就换 7-Zip 打一次
- **VC++ 运行库要自己拷**：Flutter 模板的 CMake 不会把 `msvcp140.dll` / `vcruntime140.dll` 装进
  `Release\`，而这些 dll 一旦被 `flutter clean` 清掉就不会自己回来，发出去的包在没装运行库的机器上
  会报「找不到 vcruntime140.dll」；打包前把
  `<VS 安装目录>\VC\Redist\MSVC\<版本>\x64\Microsoft.VC14x.CRT\*.dll` 拷进 `build\windows\x64\runner\Release\`
  再跑脚本（形如 `<VS>\VC\Redist\MSVC\<版本>\x64\Microsoft.VC14x.CRT\`）；
  `stage_release.ps1` 发现缺 `vcruntime140.dll` 会警告
- 想按 ABI 出小包（arm64 约 39 MB，装机首选）：`flutter build apk --release --split-per-abi` 再跑脚本，
  会一并收成 `omioclink-client-android-<tag>-<abi>.apk`（GitHub Release 只挂 arm64 那一个，其余仅本机留档）；
  `build\app\outputs\flutter-apk\` 里可能残留
  上一次的旧分包，收拢前看一眼时间戳，或者 `flutter clean` 重打
- **AAB 默认不参与构建、打包、收拢**：它只能传 Google Play，手机上装不了，而且现在还是 debug 签名、
  上不了架。确实要时才 `flutter build appbundle --release`，再给脚本加 `-IncludeAab`
- 装到手机：`adb install -r ..\releases\client-v<tag>\omioclink-client-android-<tag>.apk`

> 目前 release 用的是模板自带的 **debug 签名**，能装能跑但不能上架
> 上架前要在 `android/app/build.gradle.kts` 里配自己的 `signingConfigs`（keystore）

---

## 四、安卓构建的几个坑（本机踩过，配好就不用再管）

1. **Gradle 分发包 / 依赖走镜像**：`android/gradle/wrapper/gradle-wrapper.properties` 指向腾讯 Gradle 镜像，
   `~\.gradle\init.gradle` 把 Maven Central 换到腾讯镜像，`google()` 保持直连
2. **media_kit 的安卓原生库只托管在 GitHub Releases**：直连 github.com 超时的话，
   需要在 `~\.gradle\gradle.properties` 里给 Gradle 配代理（`systemProp.http.proxyHost/Port` 与 https 两项），
   否则会卡在下载 `default-arm64-v8a.jar`；关掉代理后要记得改回来
3. **`kotlin.incremental=false`**（`android/gradle.properties`）：Windows + Kotlin 2.4 + AGP 9 下
   插件模块编译结束会报 `Could not close incremental caches` 直接构建失败
4. **权限**：录音 / 摄像头在首次进房时弹系统权限；`ws://` 明文信令依赖 Manifest 里的
   `android:usesCleartextTraffic="true"`，改信令为 https 后可收紧
5. 安卓上不提供的能力：屏幕共享（`getDisplayMedia` 无安卓实现）、本机麦克风系统音量（仅 Windows）

---

## 五、提交前自检

```powershell
cd client
flutter analyze lib test
flutter test
```

两条都必须干净 / 全绿；不要跑仓库级 `dart format`（本仓库并非 format-clean）

点歌台相关测试要真跑 JS，`quickjs_engine` 只是 FFI 桥、pub 包不自带预编译产物：本机要在
`client/native/build/` 放一份 `quickjs_c_bridge_plugin.dll`（目录已被 gitignore），否则那些用例整片失败；
没有就从 pub 缓存里的包跑一次 `tool/build_native.ps1` 重新编。CI 上由 workflow 现编 `.so` 并用
`LIBQUICKJSC_TEST_PATH` 指给测试进程

---

## 六、代码位置速查

| 关注点 | 文件 |
| --- | --- |
| 手机/平板布局开关 | `lib/core/platform.dart`（`useCompactLayout`，按短边 600dp 判） |
| 数据目录（日志/壁纸/音乐插件） | `lib/core/app_paths.dart`（桌面 `%LOCALAPPDATA%\OmiocLink`，手机应用私有目录） |
| 单栏壳层 + 手机房间页 | `lib/features/home_shell.dart` 末尾的 `_CompactShell` / `_CompactRoomsPane` |
| 通话页窄屏分支 | `lib/features/call_view.dart`（`_CompactStageArea`、聊天与队列改底部面板） |
| 安卓工程配置 | `android/app/build.gradle.kts`、`android/app/src/main/AndroidManifest.xml` |

服务端在仓库根的 `server/`，与本目录无关；客户端只改 `client/`
