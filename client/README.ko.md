# OmiocLink 클라이언트

<p><b>语言 / Languages:</b> <a href="README.md">中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a></p>

Flutter로 작성한 데스크톱 + 모바일 클라이언트입니다. Windows는 테두리 없는 창, Android 휴대폰은 단일 컬럼이며, **태블릿과 데스크톱은 같은 3분할 레이아웃을 그대로 사용**합니다
(짧은 변 600dp 이상). 휴대폰(짧은 변 600dp 미만)은 자동으로 단일 컬럼 + 하단 내비게이션으로 전환됩니다. 판정은 `lib/core/platform.dart`를 참고하세요

---

## 1. 실행 환경

| 용도 | 필요 항목 |
| --- | --- |
| 공통 | Flutter **3.47.7 stable** / Dart 3.13.5 |
| Windows | Visual Studio 2022/2026에서 "C++를 사용한 데스크톱 개발" 체크 + Windows 10/11 SDK |
| Android | **JDK 21**, Android SDK(platform 36, build-tools 36.0.0, platform-tools, emulator), NDK(버전은 Flutter가 지정하며 현재 28.2.13676358) |

Android 빌드에 필요한 두 가지 환경 변수(사용자 수준이면 충분합니다):

```powershell
[Environment]::SetEnvironmentVariable('JAVA_HOME', 'D:\Java\jdk-21', 'User')
[Environment]::SetEnvironmentVariable('ANDROID_HOME', 'D:\Android\Sdk', 'User')
```

설정한 뒤 새 터미널을 열면 `flutter doctor -v`의 Android toolchain 항목이 `[√]`로 표시됩니다

---

## 2. 로컬에서 실행하기

**데스크톱(Windows)**

```powershell
cd client
flutter run -d windows
```

**휴대폰(에뮬레이터)**

```powershell
cd client
flutter emulators                        # 만들어 둔 AVD 확인
flutter emulators --launch Omio_393x852  # 먼저 에뮬레이터 실행(393×852dp)
flutter run -d emulator-5554             # 그다음 앱 실행
```

이 PC에는 4가지 크기를 준비해 두었습니다(AVD 데이터는 `D:\Android\avd`에 있고 `ANDROID_AVD_HOME`으로 지정):

| AVD | 해상도 @dpi | 환산 dp | 대상 기기 |
| --- | --- | --- | --- |
| `Omio_360x780` | 1080×2340 @480 | 360×780 | Android 좁은 화면의 하한 |
| `Omio_375x667` | 750×1334 @320 | 375×667 | iPhone SE 계열(가장 낮음, 필수 테스트) |
| `Omio_393x852` | 1180×2556 @480 | 393×852 | iPhone 15 계열 |
| `Omio_411x914` | 1080×2400 @420 | 411×914 | Pixel 7 / 주류 대화면 |

**휴대폰(실기기)**

휴대폰에서 "개발자 옵션 → USB 디버깅"을 켭니다(Xiaomi는 "USB 설치"와 "USB 디버깅(보안 설정)"도 함께 켜야 합니다). 그다음:

```powershell
adb devices          # 기기 확인
flutter devices      # 기기 id 확인
flutter run -d <기기 id>
```

에뮬레이터와 실기기 모두 핫 리로드(`r`) / 핫 리스타트(`R`)를 지원합니다

---

## 3. 릴리스 패키지 빌드

모든 산출물은 **저장소 루트의 `releases/client-v<tag>/`** 에 모읍니다(`<tag>`는 `pubspec.yaml`의 `version:`에서 가져오며,
`x.y.z+build` 중 `x.y.z`만 사용합니다). 파일 이름에도 버전이 들어가므로 패키지만 봐도 어느 버전인지 알 수 있습니다. `releases/`는 `.gitignore`에 있어 버전 관리에 들어가지 않습니다

먼저 빌드하고, 그다음 스크립트로 모읍니다(`tool/stage_release.ps1`, 버전을 자동으로 읽어 디렉터리까지 만들어 줍니다):

```powershell
cd client
flutter build windows --release        # Android만 빌드할 때는 생략 가능
flutter build apk --release
powershell -ExecutionPolicy Bypass -File tool\stage_release.ps1
# 한쪽만 모으려면 -Target windows 또는 -Target android 추가
```

`..\releases\client-v<tag>\`에 다음과 같이 생성됩니다:

| 산출물 | 원본 | 크기 |
| --- | --- | --- |
| `omioclink-client-win-x64-<tag>.zip` | `build\windows\x64\runner\Release\` 디렉터리 전체(`omioclink_client.exe` + dll + `data\`) | 약 29 MB |
| `omioclink-client-android-<tag>.apk` | `build\app\outputs\flutter-apk\app-release.apk`, ABI 4종 모두 포함 | 약 112 MB |

- Windows 패키지는 아무 디렉터리에나 압축을 풀고 exe를 더블클릭하면 실행되며 설치가 필요 없습니다. `Compress-Archive`가 기록하는 항목 구분자는 역슬래시
  (`data\app.so`)이지만 Windows에서 압축을 풀 때는 문제가 되지 않습니다. Linux/macOS에서 풀어야 한다면 7-Zip으로 다시 압축하세요
- **VC++ 런타임은 직접 복사해야 합니다**: Flutter 템플릿의 CMake는 `msvcp140.dll` / `vcruntime140.dll`을
  `Release\`에 넣지 않습니다. 게다가 이 dll들은 `flutter clean`으로 한 번 지워지면 다시 생기지 않기 때문에, 배포한 패키지는 런타임이 설치되지 않은 PC에서
  "vcruntime140.dll을(를) 찾을 수 없습니다" 오류가 납니다. 패키징 전에
  `<VS 설치 경로>\VC\Redist\MSVC\<버전>\x64\Microsoft.VC14x.CRT\*.dll`을 `build\windows\x64\runner\Release\`로 복사한 다음
  스크립트를 실행하세요(경로 형태는 `<VS>\VC\Redist\MSVC\<버전>\x64\Microsoft.VC14x.CRT\`입니다).
  `stage_release.ps1`은 `vcruntime140.dll`이 없으면 경고합니다
- ABI별로 작은 패키지를 만들려면(arm64는 약 39 MB로 실기기 설치에 가장 적합): `flutter build apk --release --split-per-abi`를 실행한 뒤 스크립트를 돌리면
  `omioclink-client-android-<tag>-<abi>.apk`로 함께 모입니다(GitHub Release에는 arm64 하나만 첨부하고 나머지는 이 PC에만 보관).
  `build\app\outputs\flutter-apk\`에는 이전에 만든 분할 패키지가
  남아 있을 수 있으니, 모으기 전에 타임스탬프를 확인하거나 `flutter clean` 후 다시 빌드하세요
- **AAB는 기본적으로 빌드·패키징·수집 대상이 아닙니다**: Google Play에만 업로드할 수 있고 휴대폰에는 설치할 수 없으며, 현재는 debug 서명이라
  스토어에도 올릴 수 없습니다. 정말 필요할 때만 `flutter build appbundle --release`를 실행하고 스크립트에 `-IncludeAab`를 추가하세요
- 휴대폰에 설치: `adb install -r ..\releases\client-v<tag>\omioclink-client-android-<tag>.apk`

> 현재 릴리스는 템플릿에 기본 포함된 **debug 서명**을 사용합니다. 설치와 실행은 되지만 스토어에 올릴 수는 없습니다
> 스토어 등록 전에 `android/app/build.gradle.kts`에서 자체 `signingConfigs`(keystore)를 설정해야 합니다

---

## 4. Android 빌드 시 주의점 (이 PC에서 겪은 것들이며, 한 번 설정하면 더 볼 일이 없습니다)

1. **Gradle 배포판 / 의존성은 미러 사용**: `android/gradle/wrapper/gradle-wrapper.properties`가 Tencent Gradle 미러를 가리키고,
   `~\.gradle\init.gradle`이 Maven Central을 Tencent 미러로 바꾸며, `google()`은 직접 연결을 유지합니다
2. **media_kit의 Android 네이티브 라이브러리는 GitHub Releases에만 있습니다**: github.com 직접 연결이 타임아웃된다면
   `~\.gradle\gradle.properties`에서 Gradle 프록시를 설정해야 합니다(`systemProp.http.proxyHost/Port`와 https 두 항목).
   설정하지 않으면 `default-arm64-v8a.jar` 다운로드에서 멈춥니다. 프록시를 끈 뒤에는 원래대로 되돌리는 것을 잊지 마세요
3. **`kotlin.incremental=false`** (`android/gradle.properties`): Windows + Kotlin 2.4 + AGP 9 조합에서는
   플러그인 모듈 컴파일이 끝나는 시점에 `Could not close incremental caches`가 뜨면서 빌드가 그대로 실패합니다
4. **권한**: 녹음 / 카메라는 처음 방에 입장할 때 시스템 권한을 요청합니다. `ws://` 평문 시그널링은 Manifest의
   `android:usesCleartextTraffic="true"`에 의존하며, 시그널링을 https로 바꾸면 더 좁힐 수 있습니다
5. Android에서 제공하지 않는 기능: 화면 공유(`getDisplayMedia`에 Android 구현 없음), 로컬 마이크의 시스템 볼륨(Windows 전용)

---

## 5. 커밋 전 자체 점검

```powershell
cd client
flutter analyze lib test
flutter test
```

둘 다 깨끗해야 하고 / 모두 통과해야 합니다. 저장소 전체 `dart format`은 실행하지 마세요(이 저장소는 format-clean이 아닙니다)

点歌台(노래 신청) 관련 테스트는 실제로 JS를 실행합니다. `quickjs_engine`은 FFI 브리지일 뿐이고 저장소에는 미리 빌드한 산출물을
포함하지 않습니다(`native/build/`는 gitignore 대상). 이 PC의 `client/native/build/`에 `quickjs_c_bridge_plugin.dll`이 없으면 해당 테스트가
전부 실패합니다. 없다면 엔진에 들어 있는 스크립트를 한 번 실행하세요(패키지는 `packages/quickjs_engine_local`에 내장):

```powershell
cd packages\quickjs_engine_local
powershell -ExecutionPolicy Bypass -File tool\build_native.ps1
Copy-Item native\build\Release\quickjs_c_bridge_plugin.dll ..\..\native\build\ -Force
```

CI에서는 workflow가 그 자리에서 `.so`를 빌드하고 `LIBQUICKJSC_TEST_PATH`로 테스트 프로세스에 넘깁니다.

> 엔진을 pub이 아니라 저장소 안에 두는 이유: 이 저장소가 QuickJS 바이트코드 인터페이스
> (`JS_WriteObject` / `JS_ReadObject`)를 추가했기 때문에 플러그인 소스는 한 번만 컴파일하면 됩니다. 자세한 내용은
> `packages/quickjs_engine_local/pubspec.yaml`과 `docs/startup-budget.md` §3.8을 참고하세요.

---

## 6. 코드 위치 빠른 참조

| 항목 | 파일 |
| --- | --- |
| 휴대폰/태블릿 레이아웃 전환 | `lib/core/platform.dart`(`useCompactLayout`, 짧은 변 600dp 기준) |
| 데이터 디렉터리(로그 / 배경화면 / 음악 플러그인) | `lib/core/app_paths.dart`(데스크톱은 `%LOCALAPPDATA%\OmiocLink`, 휴대폰은 앱 전용 디렉터리) |
| 단일 컬럼 셸 + 휴대폰 방 화면 | `lib/features/home_shell.dart` 끝부분의 `_CompactShell` / `_CompactRoomsPane` |
| 통화 화면의 좁은 화면 분기 | `lib/features/call_view.dart`(`_CompactStageArea`, 채팅과 대기열은 하단 패널로 변경) |
| Android 프로젝트 설정 | `android/app/build.gradle.kts`, `android/app/src/main/AndroidManifest.xml` |

서버는 저장소 루트의 `server/`에 있고 이 디렉터리와는 무관합니다. 클라이언트는 `client/`만 수정하세요
