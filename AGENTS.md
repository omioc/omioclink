# OmiocLink 工作规范（给 AI 代理）

本文件是这个仓库里**长期生效**的协作约定。开工前先读一遍；与下面冲突的临时指令，以用户当次的原话为准。

## 仓库结构

- `client/` — Flutter 桌面客户端（Windows，无边框窗口）。**美化/交互类需求默认只改这里。**
- `server/` — FastAPI 信令服务器（含 Web 管理控制台）。除明确要求，不要动。
- `deploy/` — 部署用 compose：只拉 Docker Hub 上的 `omioc/omioclink:latest`，不构建；离线部署（把源码拷到目标机、本地构建）用 `server/docker-compose.yml`。

## 版本号：只有一个来源，不许硬编码

- 客户端版本 = `client/pubspec.yaml` 的 `version:`；服务端版本 = `server/pyproject.toml` 的 `version`。
- 代码里**不要再写版本字面量**：`server/app/__init__.py` 从 pyproject 读（`app.__version__`），
  `server/app/core/config.py` 直接用它；客户端运行时要用的版本走 `client/lib/core/app_version.dart`，
  该文件由 `dart run tool/sync_version.dart` 从 pubspec 生成，**不要手改**。
- 升版本只有三步：改 pubspec + pyproject 两处 → `cd client && dart run tool/sync_version.dart` → 提交。
- 漂移会被测试拦下：`client/test/app_version_test.dart`（常量与 Runner.rc 兜底值）与
  `server/tests/test_version.py`（包版本与 pyproject）。tag 与两处版本号不一致时，发版流水线第一步就会失败。

## 发版：打 tag 就行，不要手工 build/上传

- `git tag v1.0.3 && git push origin v1.0.3` → Windows/Android 构建、镜像推送、GitHub Release 全自动
  （`.github/workflows/release.yml`）；PR 与 main push 的静态检查+单测在 `.github/workflows/ci.yml`。
- 发行说明写在 `.github/release-notes/v<版本>.md`，没有就自动用「自上一个 tag 以来的提交列表」。
- **提交信息与 tag 说明只写「改了什么」**：动了哪个功能、修了哪个 bug、为什么这么改。
  不要写「发布 1.0.7」「版本统一到 1.0.7」「固定到 1.0.7」这类套话 —— 版本号在 tag
  和发行说明里已经有了，提交正文再重复一遍等于没写。tag 的说明也一样：总结自上一个
  tag 以来的改动（功能 / 修复 / 结构调整），而不是一句「发布某版本」。

## 构建产物落位：一律进 `releases/`

- 任何一端的最终产物（Windows zip、Android apk/aab、服务端 tar）都收到仓库根的
  `releases/<组件>-v<版本>/`：不要丢在仓库根，也不要只留在 `client/build` 里等人翻。
  - 目录名带组件和版本：`releases/client-v1.0.0`、`releases/server-v0.1.0`；
    客户端版本取 `client/pubspec.yaml` 的 `version:`，服务端取 `server/pyproject.toml`。
  - 文件名也带版本：`omioclink-client-android-1.0.0.apk`、`omioclink-client-win-x64-1.0.0.zip`。
- 客户端产物用脚本收拢，不要手抄路径：

  ```powershell
  cd client
  flutter build windows --release        # 按需，只打安卓时可跳过
  flutter build apk --release
  powershell -ExecutionPolicy Bypass -File tool\stage_release.ps1   # 加 -Target windows/android 只收一端
  # AAB 默认不构建也不收（它只给 Google Play，手机装不了）；确实要才 flutter build appbundle --release 并加 -IncludeAab
  ```

- 服务端离线包用脚本导出，别手搓 `docker save`（镜像名/文件名容易和版本对不上）：

  ```powershell
  cd server
  powershell -ExecutionPolicy Bypass -File tool\export_image.ps1                                    # linux/amd64
  powershell -ExecutionPolicy Bypass -File tool\export_image.ps1 -Platform linux/arm64 -BuildIfMissing
  # 产出 releases\server-v<版本>\omioclink-server-<版本>-<架构>.tar
  # 版本读 pyproject；导出前会把镜像跑起来核对 app.__version__，对不上直接失败
  ```

- `releases/` 在 `.gitignore` 里（本机/发布机的产物区），不要把二进制提交上去。

## 验证与截图：不要自己截图

**这条是硬规矩。**

- **不要**为了确认视觉效果去运行客户端、截图、裁剪放大或做像素测量。
- 视觉问题由用户运行后提供截图；代理只依据用户的截图和代码本身判断。
- 代理在交付前只做**静态验证**：
  - `cd client; flutter analyze lib test` —— 不允许有 error/warning；
  - `cd client; flutter test` —— 必须全绿；
  - 代码结构、缩进、命名、注释与周边代码保持一致。
- 需要跑起来才能确认的事情，写清楚「未验证 + 用户需确认什么」，不要自己跑一遍再声称已验证。

## 代码风格

- 注释一律中文，解释**为什么**这么写（踩过的坑、约束来源），不复述代码在做什么。
- **不要**跑仓库级 `dart format`：本仓库并非 format-clean（很多未改动文件也会被重排），
  全量格式化会制造巨大噪声 diff。只保证自己新增/修改的片段风格与周围一致。
- 公开 API、状态管理、调用链保持不动的前提下做 UI 改动；不顺手重构无关代码。

## 改动范围：就地定制，不要外溢

- 一处特例只改一处。**不要**因为某个列表要「去边框/去分割线」就去改 `PanelCard`、
  主题或共享组件——那会波及全应用。
- 需要「例外」时，用组件已有的参数就地覆盖（例如 `PanelCard(border: Colors.transparent)`），
  并在该处写一行注释说明这是局部例外。
- 视觉令牌集中在 `client/lib/core/`：
  - 颜色一律走 `context.palette.xxx`（色板在 `app_palette.dart`，主题包在 `theme_packs.dart`）：
    深浅两套主题的文字与底色是反的，写死的 `Color(0x…)` / `Colors.white` 必在其中一套里失效；
  - 控件高度统一用 `AppSizes.control`（按钮 / 输入框 / 下拉 / 聊天框 / 分段 tab 同一档）；
  - 输入框文字用 `AppText.field`（行高必须比正文紧，否则会撑破固定高度的框；颜色由主题给）；
  - 不要引入 `VisualDensity.compact`：它会再削掉 8px 可见高度，造成按钮与输入框错位；
  - 输入框禁止再私设 `contentPadding` 的上下留白，统一用主题值。

## 收尾清单

1. `flutter analyze lib test` 干净、`flutter test` 全绿。
2. 没有新增未使用的常量/组件；没有残留调试代码。
3. 动过本机运行态（如 `%APPDATA%\omioclink\omioclink_client\shared_preferences.json`）必须原样还原。
4. 汇报时写清楚：改了哪几处、为什么、验证了什么、还有什么需要用户亲自确认。
