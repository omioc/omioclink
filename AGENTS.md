# OmiocLink 工作规范（给 AI 代理）

本文件是这个仓库里**长期生效**的协作约定。开工前先读一遍；与下面冲突的临时指令，以用户当次的原话为准。

## 仓库结构

- `client/` — Flutter 桌面客户端（Windows，无边框窗口）。**美化/交互类需求默认只改这里。**
- `server/` — FastAPI 信令服务器（含 Web 管理控制台）。除明确要求，不要动。

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
  flutter build appbundle --release
  powershell -ExecutionPolicy Bypass -File tool\stage_release.ps1   # 加 -Target windows/android 只收一端
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
