#Requires -Version 5.1
<#
.SYNOPSIS
    为 Windows 插件预置目录链接（junction），让 Flutter 在未开启「开发人员模式」时也能构建。

.DESCRIPTION
    Flutter 在构建 Windows 桌面端时会在 windows/flutter/ephemeral/.plugin_symlinks/
    下为每个插件创建符号链接。Windows 创建符号链接需要 SeCreateSymbolicLinkPrivilege
    权限——只有开启「开发人员模式」或以管理员身份运行终端才有；否则 flutter_tools 会以
    ERROR_PRIVILEGE_NOT_HELD(1314) 抛错：

        Building with plugins requires symlink support.
        Please enable Developer Mode in your system settings. Run
          start ms-settings:developers

    而 flutter_tools 的实现是「只创建缺失的链接」（flutter_plugins.dart:
    _createPlatformPluginSymlinks -> if (link.existsSync()) continue;），
    并且 **目录 junction 不需要任何特权**。于是可以预先用 junction 占位，
    让 Flutter 直接跳过创建符号链接这一步。

    推荐做法仍然是开启开发人员模式（一次性、系统级、最省事）：
        以管理员身份运行 PowerShell：
        reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v AllowDevelopmentWithoutDevLicense /d 1
    或：设置 → 系统 → 开发者选项 → 开发人员模式。

    什么时候需要重跑本脚本：执行过 `flutter clean`（会删除 ephemeral 目录）、
    新增或移除插件之后。

    清理提示：删除这些 junction 时 **不要** 用 `Remove-Item -Recurse` ——
    Windows 上它会顺着链接递归删掉 Pub 缓存里的真实文件。请用：
        cmd /c rmdir "<junction 路径>"
    或者直接 flutter clean（Flutter 自己知道怎么删）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tool\ensure_plugin_links.ps1
#>
[CmdletBinding()]
param(
    # client 工程根目录；留空则取本脚本所在目录的上一级
    [string]$ProjectRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 注意：不能在 param 默认值里用 $PSCommandPath —— Windows PowerShell 5.1 在该阶段
# 尚未填充它；$PSScriptRoot 在 5.1 / 7 下都可靠。
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}

$dependenciesFile = Join-Path $ProjectRoot '.flutter-plugins-dependencies'
if (-not (Test-Path -LiteralPath $dependenciesFile)) {
    throw "找不到 $dependenciesFile，请先执行 flutter pub get"
}

$destDir = Join-Path $ProjectRoot 'windows\flutter\ephemeral\.plugin_symlinks'
if (-not (Test-Path -LiteralPath $destDir)) {
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
}

$manifest = Get-Content -LiteralPath $dependenciesFile -Raw -Encoding utf8 | ConvertFrom-Json
$plugins = @($manifest.plugins.windows)
if ($plugins.Count -eq 0) {
    Write-Host '没有需要的 Windows 插件，无需处理'
    exit 0
}

$created = 0
$skipped = 0
foreach ($plugin in $plugins) {
    $target = ($plugin.path -replace '\\\\', '\').TrimEnd('\')
    $link = Join-Path $destDir $plugin.name

    if (Test-Path -LiteralPath $link) {
        Write-Host "跳过  $($plugin.name)（链接已存在）"
        $skipped++
        continue
    }
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Warning "跳过  $($plugin.name)：目标不存在 $target"
        continue
    }

    New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    Write-Host "创建  $($plugin.name) -> $target"
    $created++
}

Write-Host ''
Write-Host "完成：新建 $created 个、跳过 $skipped 个，共 $($plugins.Count) 个 Windows 插件"
Write-Host '现在可以直接 flutter run -d windows'
