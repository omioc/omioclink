<#
.SYNOPSIS
  把构建产物按版本收拢到仓库根的 releases/<组件>-v<版本>/ 下。

.DESCRIPTION
  仓库约定（见根目录 AGENTS.md「构建产物落位」）：不管哪一端，最终产物都进
  releases/，按版本分目录，文件名也带版本——拿到一个 apk / zip 就知道它是哪一版，
  也不需要再回 client/build 里翻。

  先构建，再收拢：

    cd client
    flutter build windows --release        # 只打安卓时可以不跑
    flutter build apk --release
    powershell -ExecutionPolicy Bypass -File tool\stage_release.ps1

  AAB 默认不参与：它是给 Google Play 的，手机里装不了，而且现在还是 debug 签名、上不了架。
  确实要用时才 flutter build appbundle --release，并给这个脚本加 -IncludeAab。

  版本号取自 pubspec.yaml 的 `version:`（x.y.z+build 只取前面的 x.y.z）。
  没构建过的那一端会被跳过并给一条警告，不会猜一个包出来。
#>
[CmdletBinding()]
param(
  # 收拢哪几端；all = windows + android 都试一遍
  [ValidateSet('all', 'windows', 'android')]
  [string[]] $Target = @('all'),

  # 手动指定版本号（默认读 pubspec.yaml）
  [string] $Version,

  # 连 Android App Bundle 一起收；默认不收（AAB 只给 Google Play，本地发布用不上）
  [switch] $IncludeAab
)

$ErrorActionPreference = 'Stop'

$clientDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$repoRoot = Split-Path -Parent $clientDir

if (-not $Version) {
  $pubspec = Get-Content -LiteralPath (Join-Path $clientDir 'pubspec.yaml') -Encoding UTF8
  $match = [regex]::Match(($pubspec -join "`n"), '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)')
  if (-not $match.Success) {
    throw 'pubspec.yaml 里没有 version: x.y.z，无法确定版本号'
  }
  $Version = $match.Groups[1].Value
}

$outDir = Join-Path $repoRoot "releases\client-v$Version"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$targets = @($Target)
if ($targets -contains 'all') {
  $targets = @('windows', 'android')
}

$staged = New-Object System.Collections.Generic.List[string]

# 只拷贝真实存在的产物：哪端没构建过就返回，由调用处决定要不要警告
function Add-Artifact {
  param([string] $Path, [string] $Name)
  if (-not (Test-Path -LiteralPath $Path)) {
    return $false
  }
  $dest = Join-Path $outDir $Name
  Copy-Item -LiteralPath $Path -Destination $dest -Force
  $staged.Add($dest)
  return $true
}

if ($targets -contains 'windows') {
  # 绿色包：Release 目录整体压成 zip，解压即用（与 README 里的做法一致）
  $runnerDir = Join-Path $clientDir 'build\windows\x64\runner\Release'
  if (Test-Path -LiteralPath $runnerDir) {
    # 模板的 CMake 不会把 VC++ 运行库装进 Release；缺了它，没装运行库的机器双击就报
    # 「找不到 vcruntime140.dll」。这些 dll 是手工拷进去的，flutter clean 之后会一起没了，
    # 所以每回收拢前都检查一次，别悄悄发出一个起不来的包。
    if (-not (Test-Path -LiteralPath (Join-Path $runnerDir 'vcruntime140.dll'))) {
      Write-Warning 'Release 里没有 vcruntime140.dll：先按 README 把 VC++ 运行库 dll 拷进 Release 再打包'
    }
    $zip = Join-Path $outDir "omioclink-client-win-x64-$Version.zip"
    Compress-Archive -Path (Join-Path $runnerDir '*') -DestinationPath $zip -Force
    $staged.Add($zip)
  } else {
    Write-Warning "跳过 Windows：没有 $runnerDir（先 flutter build windows --release）"
  }
}

if ($targets -contains 'android') {
  $apkDir = Join-Path $clientDir 'build\app\outputs\flutter-apk'
  Add-Artifact (Join-Path $apkDir 'app-release.apk') "omioclink-client-android-$Version.apk" | Out-Null
  # --split-per-abi 出的分包：一个 ABI 一个文件，文件名带上 ABI 免得装错
  foreach ($abi in @('arm64-v8a', 'armeabi-v7a', 'x86_64')) {
    Add-Artifact (Join-Path $apkDir "app-$abi-release.apk") "omioclink-client-android-$Version-$abi.apk" | Out-Null
  }
  if ($IncludeAab) {
    Add-Artifact (Join-Path $clientDir 'build\app\outputs\bundle\release\app-release.aab') "omioclink-client-android-$Version.aab" | Out-Null
  }
}

# 一个文件都没收到，说明既没构建也不是路径写错：直接失败，别让人以为打包成功了
if ($staged.Count -eq 0) {
  Write-Error '没有收拢到任何构建产物：先跑 flutter build windows / apk --release'
  exit 1
}

Write-Host "版本 $Version → $outDir"
foreach ($file in $staged) {
  Write-Host ("  " + (Split-Path -Leaf $file))
}
