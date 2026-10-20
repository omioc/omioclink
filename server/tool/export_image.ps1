<#
.SYNOPSIS
  把服务端镜像导出成离线 tar，落到仓库根的 releases/server-v<版本>/ 下。

.DESCRIPTION
  仓库约定（见 AGENTS.md「构建产物落位」）：离线包放
  releases/server-v<版本>/omioclink-server-<版本>-<架构>.tar，文件名带版本与架构。

  版本号只有 server/pyproject.toml 一个来源；导出前会把镜像跑起来读一次 app.__version__，
  和 pyproject 对不上就直接失败 —— 免得把本地 stale 的 latest 当成新版本发出去。

  镜像是双架构的（linux/amd64 + linux/arm64），而 docker save 一次只能存一个架构，
  所以按 -Platform 逐个导出。本地没有该架构时：给 -BuildIfMissing 就现场用
  server/Dockerfile 构建（amd64 走缓存约十几秒，arm64 是 QEMU 模拟、约 2 分钟）。

  用法（在 server/ 下执行）：

    # 导出 amd64（默认）
    powershell -ExecutionPolicy Bypass -File tool\export_image.ps1

    # 导出 arm64；本地没有就先编一个
    powershell -ExecutionPolicy Bypass -File tool\export_image.ps1 -Platform linux/arm64 -BuildIfMissing

    # 两个架构一起，且全程不联网
    powershell -ExecutionPolicy Bypass -File tool\export_image.ps1 -Platform linux/amd64,linux/arm64 -SkipPull -BuildIfMissing

  注意：-BuildIfMissing 会把本地 tag（默认 omioc/omioclink:latest）换成刚构建的那个架构，
  想换回来就 `docker pull --platform linux/amd64 omioc/omioclink:latest`。
#>
[CmdletBinding()]
param(
  # 要导出哪些架构；docker save 一次只存一个，所以可以给多个。
  # 这里不用 ValidateSet：`powershell -File x.ps1 -Platform a,b` 这种调用不会把逗号拆成数组，
  # 一刀切用 ValidateSet 会直接拒绝合法写法，所以改成下面手动拆 + 手动校验。
  [string[]] $Platform = @('linux/amd64'),

  # 要导出的镜像
  [string] $Image = 'omioc/omioclink:latest',

  # 本地没有该架构（或版本对不上）时，用 server/Dockerfile 现场构建
  [switch] $BuildIfMissing,

  # 完全不联网：不执行 docker pull
  [switch] $SkipPull,

  # 跳过「镜像里报的版本 == pyproject 版本」的校验（只有明确知道自己在干什么时才用）
  [switch] $SkipVersionCheck
)

# 这里刻意用 Continue 而不是 Stop：docker 会把进度/警告写到 stderr（例如「本地没有这个镜像」），
# PS 5.1 在 Stop 下会把它当终止错误，脚本会莫名其妙停在半路。失败一律由下面的 $LASTEXITCODE
# 判断，再用 throw 明确终止，不会漏掉真正的错误。
$ErrorActionPreference = 'Continue'

# 兼容 `powershell -File ... -Platform linux/amd64,linux/arm64`（原生调用不会自动拆数组）
$Platform = @($Platform | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })
$unsupported = @($Platform | Where-Object { $_ -notin @('linux/amd64', 'linux/arm64') })
if ($Platform.Count -eq 0) {
  throw '至少给一个 -Platform（linux/amd64 或 linux/arm64）'
}
if ($unsupported.Count -gt 0) {
  throw "不支持的架构：$($unsupported -join ', ')（只支持 linux/amd64 与 linux/arm64）"
}

$serverDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$repoRoot = Split-Path -Parent $serverDir

# 版本号唯一来源：pyproject 的 [project] version
$pyproject = Get-Content -LiteralPath (Join-Path $serverDir 'pyproject.toml') -Encoding UTF8
$match = [regex]::Match(($pyproject -join "`n"), '(?m)^version\s*=\s*"([^"]+)"')
if (-not $match.Success) {
  throw 'server/pyproject.toml 里没有 version = "x.y.z"，无法确定版本号'
}
$Version = $match.Groups[1].Value

$outDir = Join-Path $repoRoot "releases\server-v$Version"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# 把镜像跑起来读一次版本：既是版本校验，也顺便证明这个架构在本地真的可用。
# 用 2>&1 合流而不是 2>$null —— PS 5.1 在 $ErrorActionPreference='Stop' 下会把原生命令的
# stderr 当成终止错误，docker run 找不到镜像时脚本会莫名其妙停在半路。
function Get-ImageVersion([string] $targetPlatform) {
  $out = & docker run --rm --platform $targetPlatform $Image python -c "import app; print(app.__version__)" 2>&1
  if ($LASTEXITCODE -ne 0) {
    return $null
  }
  $line = $out | Where-Object { "$_" -match '^\d+\.\d+\.\d+' } | Select-Object -Last 1
  if (-not $line) {
    return $null
  }
  return "$line".Trim()
}

$exported = New-Object System.Collections.Generic.List[string]

foreach ($target in $Platform) {
  $arch = $target.Split('/')[1]
  $dest = Join-Path $outDir "omioclink-server-$Version-$arch.tar"

  Write-Host "=== $target ==="

  if (-not $SkipPull) {
    Write-Host "-> docker pull --platform $target $Image"
    & docker pull --platform $target $Image 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Warning '拉取失败（网络不可达，或镜像还没推到 Docker Hub），继续用本地已有的镜像'
    }
  }

  $reported = $null
  if (-not $SkipVersionCheck) {
    $reported = Get-ImageVersion $target
  }

  # 探测不到（本地没这个架构）或版本对不上，都只有给了 -BuildIfMissing 才自动现场构建；
  # 否则直接失败 —— 导出一个「文件名写 1.0.3、里面其实是 1.0.2」的离线包最坑人。
  if (-not $SkipVersionCheck -and $reported -ne $Version) {
    if ($null -eq $reported) {
      $reason = "本地没有 $target 的 $Image"
    } else {
      $reason = "镜像里报的版本是 $reported，pyproject 是 $Version"
    }
    if (-not $BuildIfMissing) {
      throw "$reason。加 -BuildIfMissing 现场构建，或先 docker pull --platform $target $Image"
    }
    Write-Host "-> docker build --platform $target（$reason，现场构建）"
    & docker build --platform $target -t $Image $serverDir
    if ($LASTEXITCODE -ne 0) {
      throw "构建 $target 失败"
    }
    # 构建完再探一次：源码和 pyproject 版本对不上时这里就该失败，而不是导出一个名不副实的包
    $again = Get-ImageVersion $target
    if ($again -ne $Version) {
      throw "刚构建出来的镜像报的版本是 $again，pyproject 是 $Version：先把 server/pyproject.toml 的 version 改对"
    }
  }

  Write-Host "-> docker save --platform $target -o $dest"
  & docker save --platform $target $Image -o $dest
  if ($LASTEXITCODE -ne 0) {
    throw "导出 $target 失败：本地可能没有这个架构（试试 -BuildIfMissing，或先 docker pull --platform $target）"
  }

  $exported.Add($dest)
  Write-Host ('  ' + (Split-Path -Leaf $dest))
}

Write-Host ''
Write-Host "版本 $Version -> $outDir"
foreach ($file in $exported) {
  $size = [math]::Round((Get-Item -LiteralPath $file).Length / 1MB, 1)
  $sha = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
  Write-Host ("  {0}  {1} MB  SHA256={2}" -f (Split-Path -Leaf $file), $size, $sha)
}
