# OmiocLink Client

<p><b>语言 / Languages:</b> <a href="README.md">中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a></p>

A desktop + mobile client written in Flutter: a borderless window on Windows, a single column on Android phones; **tablets and desktops share the same three-pane layout**
(short side ≥ 600dp), while phones (short side < 600dp) switch to a single column with bottom navigation automatically — see `lib/core/platform.dart` for the check.

---

## 1. Requirements

| Purpose | Needs |
| --- | --- |
| Common | Flutter **3.47.7 stable** / Dart 3.13.5 |
| Windows | Visual Studio 2022/2026 with the "Desktop development with C++" workload checked + Windows 10/11 SDK |
| Android | **JDK 21**, Android SDK (platform 36, build-tools 36.0.0, platform-tools, emulator), NDK (version chosen by Flutter, currently 28.2.13676358) |

Two environment variables are required for Android builds (user level is enough):

```powershell
[Environment]::SetEnvironmentVariable('JAVA_HOME', 'D:\Java\jdk-21', 'User')
[Environment]::SetEnvironmentVariable('ANDROID_HOME', 'D:\Android\Sdk', 'User')
```

Open a new terminal afterwards; the Android toolchain section of `flutter doctor -v` should read `[√]`

---

## 2. Running locally

**Desktop (Windows)**

```powershell
cd client
flutter run -d windows
```

**Phone (emulator)**

```powershell
cd client
flutter emulators                        # list the AVDs you already created
flutter emulators --launch Omio_393x852  # start the emulator first (393×852dp)
flutter run -d emulator-5554             # then run the app
```

Four screen sizes are already set up on this machine (AVD data lives in `D:\Android\avd`, pointed to by `ANDROID_AVD_HOME`):

| AVD | Resolution @dpi | Equivalent dp | Covers |
| --- | --- | --- | --- |
| `Omio_360x780` | 1080×2340 @480 | 360×780 | lower bound of narrow Android screens |
| `Omio_375x667` | 750×1334 @320 | 375×667 | iPhone SE class (the shortest, must test) |
| `Omio_393x852` | 1180×2556 @480 | 393×852 | iPhone 15 class |
| `Omio_411x914` | 1080×2400 @420 | 411×914 | Pixel 7 / mainstream large screens |

**Phone (physical device)**

On the phone, enable "Developer options → USB debugging" (on Xiaomi also "Install via USB" and "USB debugging (Security settings)"), then:

```powershell
adb devices          # confirm the device
flutter devices      # get the device id
flutter run -d <device-id>
```

Both the emulator and a physical device support hot reload (`r`) / hot restart (`R`)

---

## 3. Building release packages

All artifacts are collected into **`releases/client-v<tag>/` at the repository root** (`<tag>` comes from `version:` in `pubspec.yaml`,
keeping only `x.y.z` out of `x.y.z+build`). File names carry the version too, so one package tells you which build it is; `releases/` is in `.gitignore` and never enters version control

Build first, then collect with the script (`tool/stage_release.ps1`, which reads the version and creates the directory for you):

```powershell
cd client
flutter build windows --release        # skip it when you only build Android
flutter build apk --release
powershell -ExecutionPolicy Bypass -File tool\stage_release.ps1
# only one target: add -Target windows or -Target android
```

The output lands in `..\releases\client-v<tag>\`:

| Artifact | Source | Size |
| --- | --- | --- |
| `omioclink-client-win-x64-<tag>.zip` | the whole `build\windows\x64\runner\Release\` directory (`omioclink_client.exe` + dlls + `data\`) | ~29 MB |
| `omioclink-client-android-<tag>.apk` | `build\app\outputs\flutter-apk\app-release.apk`, with all 4 ABIs | ~112 MB |

- The Windows package runs by unzipping it into any directory and double-clicking the exe — no installation needed; entries written by `Compress-Archive` use backslashes as separators
  (`data\app.so`), which is harmless when unzipping on Windows; if it has to be unzipped on Linux/macOS, repack it with 7-Zip
- **You have to copy the VC++ runtime yourself**: the Flutter template's CMake does not put `msvcp140.dll` / `vcruntime140.dll` into
  `Release\`, and once `flutter clean` removes those dlls they never come back, so a shipped package fails with
  "vcruntime140.dll was not found" on machines without the runtime installed; before packaging, copy
  `<VS install dir>\VC\Redist\MSVC\<version>\x64\Microsoft.VC14x.CRT\*.dll` into `build\windows\x64\runner\Release\`
  and then run the script (the path looks like `<VS>\VC\Redist\MSVC\<version>\x64\Microsoft.VC14x.CRT\`);
  `stage_release.ps1` warns when `vcruntime140.dll` is missing
- For smaller per-ABI packages (arm64 is about 39 MB and the first choice for installing): run `flutter build apk --release --split-per-abi` and then the script,
  which also collects them as `omioclink-client-android-<tag>-<abi>.apk` (GitHub Releases ships only the arm64 one, the rest are archived locally);
  `build\app\outputs\flutter-apk\` may still hold
  split APKs from a previous run, so check the timestamps before collecting, or `flutter clean` and rebuild
- **AAB is excluded from building, packaging and collecting by default**: it can only be uploaded to Google Play, cannot be installed on a phone, and is still debug-signed,
  so it cannot be published anyway. Only when you really need it: `flutter build appbundle --release`, then add `-IncludeAab` to the script
- Install on a phone: `adb install -r ..\releases\client-v<tag>\omioclink-client-android-<tag>.apk`

> Releases currently use the template's built-in **debug signing**: they install and run, but cannot be published
> Before publishing, configure your own `signingConfigs` (keystore) in `android/app/build.gradle.kts`

---

## 4. Android build pitfalls (already hit here; nothing to do once configured)

1. **Gradle distribution / dependencies go through a mirror**: `android/gradle/wrapper/gradle-wrapper.properties` points at the Tencent Gradle mirror,
   `~\.gradle\init.gradle` swaps Maven Central for the Tencent mirror, and `google()` stays direct
2. **media_kit's Android native libraries are hosted only on GitHub Releases**: if connecting to github.com times out,
   configure a proxy for Gradle in `~\.gradle\gradle.properties` (`systemProp.http.proxyHost/Port` plus the two https entries),
   otherwise it stalls downloading `default-arm64-v8a.jar`; remember to revert it after turning the proxy off
3. **`kotlin.incremental=false`** (`android/gradle.properties`): on Windows + Kotlin 2.4 + AGP 9
   the plugin module fails the build outright with `Could not close incremental caches` as soon as compilation finishes
4. **Permissions**: recording / camera prompt for system permission the first time you join a room; plaintext `ws://` signaling relies on
   `android:usesCleartextTraffic="true"` in the Manifest, which can be tightened once signaling moves to https
5. Not available on Android: screen sharing (`getDisplayMedia` has no Android implementation), system volume of the local microphone (Windows only)

---

## 5. Self-check before committing

```powershell
cd client
flutter analyze lib test
flutter test
```

Both must be clean / all green; do not run a repository-wide `dart format` (this repo is not format-clean)

The song-request board (`点歌台`) tests really execute JS. `quickjs_engine` is only an FFI bridge and the repo ships no prebuilt
artifact (`native/build/` is gitignored): you need a `quickjs_c_bridge_plugin.dll` in `client/native/build/` on your machine, otherwise those cases
all fail. If you don't have one, run the engine's own script once (the package is bundled in `packages/quickjs_engine_local`):

```powershell
cd packages\quickjs_engine_local
powershell -ExecutionPolicy Bypass -File tool\build_native.ps1
Copy-Item native\build\Release\quickjs_c_bridge_plugin.dll ..\..\native\build\ -Force
```

On CI the workflow builds the `.so` on the fly and points the test process at it via `LIBQUICKJSC_TEST_PATH`.

> Why the engine lives in the repo instead of on pub: this repo adds a QuickJS bytecode interface to it
> (`JS_WriteObject` / `JS_ReadObject`), so plugin sources only have to be compiled once. See
> `packages/quickjs_engine_local/pubspec.yaml` and `docs/startup-budget.md` §3.8.

---

## 6. Code map

| Concern | File |
| --- | --- |
| Phone/tablet layout switch | `lib/core/platform.dart` (`useCompactLayout`, keyed on the 600dp short side) |
| Data directory (logs / wallpapers / music plugins) | `lib/core/app_paths.dart` (desktop `%LOCALAPPDATA%\OmiocLink`, app-private directory on phones) |
| Single-column shell + phone room page | `_CompactShell` / `_CompactRoomsPane` at the end of `lib/features/home_shell.dart` |
| Narrow-screen branch of the call page | `lib/features/call_view.dart` (`_CompactStageArea`; chat and queue become bottom panels) |
| Android project configuration | `android/app/build.gradle.kts`, `android/app/src/main/AndroidManifest.xml` |

The server lives in `server/` at the repository root and has nothing to do with this directory; client changes stay inside `client/`
