# OmiocLink クライアント

<p><b>语言 / Languages:</b> <a href="README.md">中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a></p>

Flutter 製のデスクトップ + モバイルクライアントです。Windows はボーダーレスウィンドウ、Android スマートフォンは 1 カラムで表示します。**タブレットとデスクトップは同じ 3 ペイン構成を使います**
（短辺 600dp 以上）。スマートフォン（短辺 600dp 未満）は自動的に 1 カラム + ボトムナビゲーションへ切り替わります。判定は `lib/core/platform.dart` を参照してください

---

## 1. 動作環境

| 用途 | 必要なもの |
| --- | --- |
| 共通 | Flutter **3.47.7 stable** / Dart 3.13.5 |
| Windows 版 | Visual Studio 2022/2026（「C++ によるデスクトップ開発」にチェック）+ Windows 10/11 SDK |
| Android 版 | **JDK 21**、Android SDK（platform 36、build-tools 36.0.0、platform-tools、emulator）、NDK（バージョンは Flutter が指定。現在 28.2.13676358） |

Android ビルドに必要な 2 つの環境変数（ユーザー単位で十分です）:

```powershell
[Environment]::SetEnvironmentVariable('JAVA_HOME', 'D:\Java\jdk-21', 'User')
[Environment]::SetEnvironmentVariable('ANDROID_HOME', 'D:\Android\Sdk', 'User')
```

設定後はターミナルを開き直してください。`flutter doctor -v` の Android toolchain の項目が `[√]` になっていれば OK です

---

## 2. ローカルでの起動

**デスクトップ（Windows）**

```powershell
cd client
flutter run -d windows
```

**スマートフォン（エミュレーター）**

```powershell
cd client
flutter emulators                        # 作成済みの AVD を確認
flutter emulators --launch Omio_393x852  # 先にエミュレーターを起動（393×852dp）
flutter run -d emulator-5554             # そのうえでアプリを実行
```

本機には 4 種類のサイズを用意済みです（AVD データは `D:\Android\avd` にあり、`ANDROID_AVD_HOME` で参照しています）:

| AVD | 解像度 @dpi | 相当 dp | 対象機種 |
| --- | --- | --- | --- |
| `Omio_360x780` | 1080×2340 @480 | 360×780 | Android 狭幅画面の下限 |
| `Omio_375x667` | 750×1334 @320 | 375×667 | iPhone SE 系（最も低い。必ずテスト） |
| `Omio_393x852` | 1180×2556 @480 | 393×852 | iPhone 15 系 |
| `Omio_411x914` | 1080×2400 @420 | 411×914 | Pixel 7 / 一般的な大画面 |

**スマートフォン（実機）**

実機で「開発者向けオプション → USB デバッグ」を有効にします（Xiaomi の場合は「USB 経由のインストール」と「USB デバッグ（セキュリティ設定）」も有効に）。そのうえで:

```powershell
adb devices          # デバイスを確認
flutter devices      # デバイス ID を取得
flutter run -d <デバイスID>
```

エミュレーターでも実機でもホットリロード（`r`）/ ホットリスタート（`R`）が使えます

---

## 3. リリースパッケージのビルド

生成物はすべて**リポジトリ直下の `releases/client-v<tag>/`** に集約します（`<tag>` は `pubspec.yaml` の `version:` から取得し、
`x.y.z+build` の場合は `x.y.z` のみを使用）。ファイル名にもバージョンが入るので、パッケージを見ればどのバージョンか分かります。`releases/` は `.gitignore` に含まれており、バージョン管理には入りません

まずビルドし、そのあとスクリプトで集約します（`tool/stage_release.ps1`。バージョンを自動で読み取り、ディレクトリも作成します）:

```powershell
cd client
flutter build windows --release        # Android だけ作る場合は省略可
flutter build apk --release
powershell -ExecutionPolicy Bypass -File tool\stage_release.ps1
# 片方だけ集約する場合は -Target windows または -Target android を付ける
```

`..\releases\client-v<tag>\` に次のとおり出力されます:

| 生成物 | 取得元 | サイズ |
| --- | --- | --- |
| `omioclink-client-win-x64-<tag>.zip` | `build\windows\x64\runner\Release\` ディレクトリ全体（`omioclink_client.exe` + dll + `data\`） | 約 29 MB |
| `omioclink-client-android-<tag>.apk` | `build\app\outputs\flutter-apk\app-release.apk`、4 つの ABI をすべて同梱 | 約 112 MB |

- Windows 版は任意のディレクトリに展開して exe をダブルクリックすれば動きます。インストールは不要です。`Compress-Archive` が書き出すエントリの区切り文字は
  円記号（`data\app.so`）ですが、Windows での展開には影響ありません。Linux/macOS で展開するなら 7-Zip で固め直してください
- **VC++ ランタイムは自分でコピーが必要**: Flutter テンプレートの CMake は `msvcp140.dll` / `vcruntime140.dll` を
  `Release\` に入れません。しかもこれらの dll は `flutter clean` で消えると戻ってきません。そのため配布したパッケージは、ランタイム未導入の環境で
  「vcruntime140.dll が見つかりません」になります。パッケージングの前に
  `<VS インストール先>\VC\Redist\MSVC\<バージョン>\x64\Microsoft.VC14x.CRT\*.dll` を `build\windows\x64\runner\Release\` へコピーしてから
  スクリプトを実行してください（`<VS>\VC\Redist\MSVC\<バージョン>\x64\Microsoft.VC14x.CRT\` のようなパスです）。
  `stage_release.ps1` は `vcruntime140.dll` の欠落を検出すると警告します
- ABI ごとの小さいパッケージを作る場合（arm64 は約 39 MB で、実機へのインストールに最適）: `flutter build apk --release --split-per-abi` を実行してからスクリプトを流すと、
  `omioclink-client-android-<tag>-<abi>.apk` として一緒に集約されます（GitHub Release に添付するのは arm64 の 1 つだけで、残りは本機保管のみ）。
  `build\app\outputs\flutter-apk\` には前回の分割パッケージが
  残っていることがあるので、集約前にタイムスタンプを確認するか、`flutter clean` してからビルドし直してください
- **AAB は既定ではビルド・パッケージング・集約の対象外**です。Google Play にしかアップロードできず、スマートフォンにはインストールできません。さらに現状は debug 署名なので
  ストアにも出せません。本当に必要なときだけ `flutter build appbundle --release` を実行し、スクリプトに `-IncludeAab` を付けます
- 実機へのインストール: `adb install -r ..\releases\client-v<tag>\omioclink-client-android-<tag>.apk`

> 現在のリリースはテンプレート標準の **debug 署名** です。インストールして動かせますが、ストアには公開できません
> 公開の前に `android/app/build.gradle.kts` で独自の `signingConfigs`（keystore）を設定してください

---

## 4. Android ビルドのつまずきどころ（本機で踏んだもの。設定済みなら気にしなくて大丈夫です）

1. **Gradle ディストリビューション / 依存関係はミラー経由**: `android/gradle/wrapper/gradle-wrapper.properties` は Tencent の Gradle ミラーを指し、
   `~\.gradle\init.gradle` で Maven Central を Tencent ミラーに置き換え、`google()` は直接接続のままにしています
2. **media_kit の Android ネイティブライブラリは GitHub Releases にしかありません**: github.com への直接接続がタイムアウトする場合は、
   `~\.gradle\gradle.properties` で Gradle にプロキシを設定してください（`systemProp.http.proxyHost/Port` と https の 2 項目）。
   設定しないと `default-arm64-v8a.jar` のダウンロードで止まります。プロキシを切ったあとは元に戻すのを忘れずに
3. **`kotlin.incremental=false`**（`android/gradle.properties`）: Windows + Kotlin 2.4 + AGP 9 の組み合わせでは、
   プラグインモジュールのコンパイル終了時に `Could not close incremental caches` が出てビルドがそのまま失敗します
4. **権限**: 録音 / カメラは初回のルーム入室時にシステム権限を求めます。`ws://` の平文シグナリングは Manifest の
   `android:usesCleartextTraffic="true"` に依存しているので、シグナリングを https に変えたあとで絞り込めます
5. Android では提供しない機能: 画面共有（`getDisplayMedia` に Android 実装がない）、マイクのシステム音量（Windows のみ）

---

## 5. コミット前のセルフチェック

```powershell
cd client
flutter analyze lib test
flutter test
```

どちらもクリーン / オールグリーンであること。リポジトリ全体への `dart format` は実行しないでください（本リポジトリは format-clean ではありません）

点歌台（曲のリクエスト機能）関連のテストは実際に JS を実行します。`quickjs_engine` は FFI ブリッジにすぎず、リポジトリにはビルド済みの
成果物を含めていません（`native/build/` は gitignore 対象）。本機の `client/native/build/` に `quickjs_c_bridge_plugin.dll` を置いていないと、それらのケースは
まとめて失敗します。ない場合はエンジン付属のスクリプトを一度実行してください（パッケージは `packages/quickjs_engine_local` に同梱）:

```powershell
cd packages\quickjs_engine_local
powershell -ExecutionPolicy Bypass -File tool\build_native.ps1
Copy-Item native\build\Release\quickjs_c_bridge_plugin.dll ..\..\native\build\ -Force
```

CI では workflow がその場で `.so` をビルドし、`LIBQUICKJSC_TEST_PATH` でテストプロセスに渡しています。

> エンジンを pub ではなくリポジトリ内に置いている理由: 本リポジトリが QuickJS のバイトコードインターフェース
> （`JS_WriteObject` / `JS_ReadObject`）を追加しており、プラグインのソースは一度コンパイルするだけで済むからです。詳しくは
> `packages/quickjs_engine_local/pubspec.yaml` と `docs/startup-budget.md` §3.8 を参照してください。

---

## 6. コードの場所早見表

| 項目 | ファイル |
| --- | --- |
| スマホ / タブレットのレイアウト切り替え | `lib/core/platform.dart`（`useCompactLayout`、短辺 600dp で判定） |
| データディレクトリ（ログ / 壁紙 / 音楽プラグイン） | `lib/core/app_paths.dart`（デスクトップは `%LOCALAPPDATA%\OmiocLink`、スマホはアプリ専用ディレクトリ） |
| 1 カラムのシェル + スマホのルーム画面 | `lib/features/home_shell.dart` 末尾の `_CompactShell` / `_CompactRoomsPane` |
| 通話画面の狭幅分岐 | `lib/features/call_view.dart`（`_CompactStageArea`、チャットとキューはボトムパネルに変更） |
| Android プロジェクト設定 | `android/app/build.gradle.kts`、`android/app/src/main/AndroidManifest.xml` |

サーバーはリポジトリ直下の `server/` にあり、このディレクトリとは関係ありません。クライアント側は `client/` だけを変更してください
