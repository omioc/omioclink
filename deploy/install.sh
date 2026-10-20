#!/usr/bin/env bash
# =============================================================================
# OmiocLink 服务端 · 在线部署一键脚本
#
# 做的事（全部可重复执行，任何一步中断后直接重跑即可）：
#   1. 在 /opt/omioc_server 建目录并进去（已存在就复用）
#   2. 从仓库 deploy/ 下载 docker-compose.yml 与 .env.example，没有 .env 才复制一份
#   3. 生成两个随机密钥（优先 openssl，没有就用 /dev/urandom）写进 .env
#   4. 按参数配置自建 STUN（写 OMIOCLINK_ICE_SERVERS）
#   5. 先 docker compose down，再 pull（带进度），最后 up -d
#   6. 等健康检查，打印状态与下一步建议
#
# 用法：
#   sudo bash install.sh                      # 交互询问是否启用 STUN
#   sudo bash install.sh --stun 1.2.3.4       # 启用自建 STUN（公网 IP 或域名）
#   sudo bash install.sh --no-stun            # 不启用，完全非交互
#   sudo bash install.sh -d /srv/omioc -f     # 换目录 + 强制重新下载 compose
#
# 幂等约定（重跑时）：
#   * 安装目录已存在        → 复用
#   * compose / .env.example 已存在 → 跳过下载（--force 才重新拉）
#   * .env 已存在          → 不覆盖，只补齐缺失的键
#   * 密钥已有非空值        → 不再生成
#   * 每次都先 down 再 up  → 避免端口占用与旧配置残留；数据在命名卷里，不受影响
#
# 日志：屏幕全程输出，同时追加到 <安装目录>/deploy-<日期>.log（密钥只打印前 8 位）
# =============================================================================
set -Eeuo pipefail

DEFAULT_INSTALL_DIR="/opt/omioc_server"
COMPOSE_FILE_NAME="docker-compose.yml"
ENV_TEMPLATE_NAME=".env.example"
ENV_FILE=".env"
COMPOSE_PROJECT_NAME="omioclink"
DATA_VOLUME="omioclink_server-data"
APP_PORT="21077"
STUN_PORT="3478"

# 下载源：官方 raw 打头，后面几个是镜像/加速（国内 raw.githubusercontent.com 经常不通）。
# 公共加速站的可用性会变，真都不行就用 --raw-base 或环境变量 OMIOC_RAW_BASE 指到自己的源。
DEFAULT_RAW_BASES=(
  "https://raw.githubusercontent.com/omioc/omioclink/main/deploy"
  "https://cdn.jsdelivr.net/gh/omioc/omioclink@main/deploy"
  "https://fastly.jsdelivr.net/gh/omioc/omioclink@main/deploy"
  "https://gh-proxy.com/https://raw.githubusercontent.com/omioc/omioclink/main/deploy"
)

INSTALL_DIR="${OMIOC_INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
FORCE_DOWNLOAD=0
STUN_MODE="unset"   # unset / on / off
STUN_HOST_RAW=""
RAW_BASES=()

# ----------------------------------------------------------------------------- 日志
ts_now() { date '+%Y-%m-%d %H:%M:%S'; }
log()    { printf '%s [INFO ] %s\n' "$(ts_now)" "$*"; }
step()   { printf '\n%s [STEP ] %s\n' "$(ts_now)" "$*"; }
warn()   { printf '%s [WARN ] %s\n' "$(ts_now)" "$*" >&2; }
die()    { printf '%s [ERROR] %s\n' "$(ts_now)" "$*" >&2; exit 1; }

# 出错时给出「哪一行、哪条命令」，并明确告诉用户可以直接重跑
on_error() {
  local code=$?
  printf '\n%s [ERROR] 第 %s 行执行失败（退出码 %s）：%s\n' \
    "$(ts_now)" "${1:-?}" "$code" "${2:-?}" >&2
  printf '%s [ERROR] 已完成的步骤都会保留，排查后可直接重跑本脚本继续\n' "$(ts_now)" >&2
  exit "$code"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

usage() {
  cat <<'EOF'
OmiocLink 服务端在线部署（幂等，可反复执行）

用法：sudo bash install.sh [选项]

选项：
  -s, --stun <公网IP或域名>  启用自建 STUN（UDP 3478），并写入 OMIOCLINK_ICE_SERVERS
      --no-stun              不启用自建 STUN（不改动 OMIOCLINK_ICE_SERVERS）
  -d, --dir <目录>           安装目录，默认 /opt/omioc_server
  -f, --force                强制重新下载 docker-compose.yml 与 .env.example
      --raw-base <URL>       自定义下载源（默认官方 raw + 两个镜像依次尝试）
  -h, --help                 显示本帮助

不带 --stun / --no-stun 时：终端里会问你要不要启用 STUN；非交互环境按「不启用」处理

示例：
  sudo bash install.sh                      # 交互式
  sudo bash install.sh --stun 1.2.3.4       # 启用 STUN，地址 1.2.3.4:3478
  sudo bash install.sh --no-stun            # 只要信令服务
EOF
}

# ----------------------------------------------------------------------------- 参数
parse_args() {
  local raw_base=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -s|--stun)
        [ $# -ge 2 ] || die "--stun 后面要跟公网 IP 或域名，例如：--stun 1.2.3.4"
        STUN_MODE="on"
        STUN_HOST_RAW="$2"
        shift 2
        ;;
      --stun=*)
        STUN_MODE="on"
        STUN_HOST_RAW="${1#--stun=}"
        shift
        ;;
      --no-stun)
        STUN_MODE="off"
        shift
        ;;
      -d|--dir)
        [ $# -ge 2 ] || die "--dir 后面要跟目录路径"
        INSTALL_DIR="$2"
        shift 2
        ;;
      --dir=*)
        INSTALL_DIR="${1#--dir=}"
        shift
        ;;
      --raw-base)
        [ $# -ge 2 ] || die "--raw-base 后面要跟下载源地址"
        raw_base="$2"
        shift 2
        ;;
      --raw-base=*)
        raw_base="${1#--raw-base=}"
        shift
        ;;
      -f|--force)
        FORCE_DOWNLOAD=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "不认识的参数：$1"
        ;;
    esac
  done

  # 下载源优先级：--raw-base > OMIOC_RAW_BASE > 内置三源
  if [ -n "$raw_base" ]; then
    RAW_BASES=("${raw_base%/}")
  elif [ -n "${OMIOC_RAW_BASE:-}" ]; then
    RAW_BASES=("${OMIOC_RAW_BASE%/}")
  else
    RAW_BASES=("${DEFAULT_RAW_BASES[@]}")
  fi

  [ -n "$INSTALL_DIR" ] || die "安装目录不能为空"
}

# 没显式指定时，终端里问一句；非交互环境默认不启用 STUN
resolve_stun_mode() {
  if [ "$STUN_MODE" != "unset" ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    STUN_MODE="off"
    log "非交互环境，默认不启用自建 STUN（要开请加 --stun <公网IP或域名>）"
    return 0
  fi

  local answer=""
  read -r -p "是否启用自建 STUN（UDP 3478，公网可达后打洞更稳）？[y/N] " answer || true
  case "$answer" in
    y|Y|yes|YES|Yes) STUN_MODE="on" ;;
    *) STUN_MODE="off" ;;
  esac

  if [ "$STUN_MODE" = "on" ]; then
    while [ -z "$STUN_HOST_RAW" ]; do
      # 拿不到输入（stdin 关闭，比如 curl | bash）时不要死循环
      if ! read -r -p "填服务器公网 IP 或域名（客户端用它打洞，例如 1.2.3.4 或 vps.example.com）： " STUN_HOST_RAW; then
        die "没读到公网 IP / 域名；请直接用参数传：sudo bash install.sh --stun <IP或域名>"
      fi
      if [ -z "$STUN_HOST_RAW" ]; then
        warn "不能为空；不打算自建 STUN 的话请重新运行并选择 N"
      fi
    done
  fi
}

# ----------------------------------------------------------------------------- 权限
ensure_root() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  if [ "${OMIOC_DEPLOY_REEXEC:-0}" = "1" ]; then
    die "已经用 sudo 重跑过一次仍然不是 root，请检查 sudo 配置"
  fi
  command -v sudo >/dev/null 2>&1 \
    || die "需要 root 权限（要写 $INSTALL_DIR、要操作 docker）：请用 sudo 运行"

  local self
  self="$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")"
  log "当前不是 root，自动用 sudo 重新执行本脚本"
  # 不用 exec：sudo 本身失败（比如被禁用、密码错）时要给一句中文提示，而不是默默退出
  if ! OMIOC_DEPLOY_REEXEC=1 sudo -E -- bash "$self" "$@"; then
    die "用 sudo 重新执行失败（原因见上面的输出）；也可以手动执行：sudo bash $self"
  fi
  exit 0
}

# ----------------------------------------------------------------------------- 日志落盘
setup_logging() {
  LOG_FILE="$INSTALL_DIR/deploy-$(date +%Y%m%d).log"
  if command -v tee >/dev/null 2>&1; then
    # 之后所有输出同时进文件（含 docker pull 的进度）
    exec > >(tee -a "$LOG_FILE") 2>&1
  else
    warn "没有 tee，日志只打印到屏幕"
  fi
  log "日志同时追加到：$LOG_FILE"
}

# ----------------------------------------------------------------------------- 下载
http_get() { # http_get <url> <目标文件>
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 180 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --tries=2 --timeout=30 -O "$2" "$1"
  else
    die "既没有 curl 也没有 wget，先装一个再跑（apt install curl / dnf install curl）"
  fi
}

download_from_repo() { # download_from_repo <仓库内相对路径> <目标文件> <描述>
  local rel="$1" dest="$2" desc="$3" base url tmp
  tmp="${dest}.part"
  for base in "${RAW_BASES[@]}"; do
    url="${base%/}/${rel}"
    log "下载 $desc：$url"
    if http_get "$url" "$tmp"; then
      if [ -s "$tmp" ]; then
        mv -f "$tmp" "$dest"
        log "已保存 $dest（$(wc -c < "$dest" | tr -d ' ') 字节）"
        return 0
      fi
      warn "下载到的内容是空的：$url"
    else
      warn "下载失败：$url"
    fi
    rm -f "$tmp"
  done
  die "所有下载源都拿不到 $rel；可以手动把该文件放到 $INSTALL_DIR 后重跑本脚本"
}

# ----------------------------------------------------------------------------- .env
env_get() { # env_get <键名>：没有这行或值为空都返回空串
  local key="$1"
  grep -E "^[[:space:]]*${key}=" "$ENV_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2- || true
}

env_set() { # env_set <键名> <值>：有这行就替换，没有就追加（不碰注释行）
  local key="$1" value="$2" escaped
  # sed 替换串里 & | \ 需要转义，否则会被当成特殊字符
  escaped="$(printf '%s' "$value" | sed -e 's/[&|\\]/\\&/g')"
  if grep -Eq "^[[:space:]]*${key}=" "$ENV_FILE"; then
    sed -i -E "s|^[[:space:]]*${key}=.*|${key}=${escaped}|" "$ENV_FILE"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    log "在 .env 中补上缺失的 $key"
  fi
}

# 32 字节随机密钥（64 个十六进制字符）。目标机不一定有 openssl，所以要能降级。
random_secret() {
  local secret=""
  if command -v openssl >/dev/null 2>&1; then
    secret="$(openssl rand -hex 32 2>/dev/null || true)"
  fi
  if [ -z "$secret" ] && command -v od >/dev/null 2>&1; then
    # od 是 coreutils 自带的，busybox 上也有
    secret="$(head -c 32 /dev/urandom | od -An -v -tx1 | tr -d ' \n')"
  fi
  if [ -z "$secret" ]; then
    secret="$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 64 || true)"
  fi
  if [ "${#secret}" -lt 32 ]; then
    die "生成随机密钥失败（openssl / od / tr 都不可用或输出异常）"
  fi
  printf '%s' "$secret"
}

ensure_secret() { # ensure_secret <键名> <中文名>
  local key="$1" label="$2" current secret
  current="$(env_get "$key")"
  if [ -n "$current" ]; then
    log "$label 已有值（$key 前 8 位 ${current:0:8}…），不再重新生成"
    return 0
  fi
  secret="$(random_secret)"
  env_set "$key" "$secret"
  log "$label 已生成并写入 $key（前 8 位 ${secret:0:8}…，共 ${#secret} 字符）"
}

# ----------------------------------------------------------------------------- STUN
apply_stun() {
  local host stun_uri current
  if [ "$STUN_MODE" = "on" ]; then
    host="${STUN_HOST_RAW#stun:}"     # 容忍用户把 stun: 前缀一起粘进来
    host="${host#//}"
    host="${host%%/*}"                # 去掉可能的 /path
    host="$(printf '%s' "$host" | tr -d '[:space:]')"
    [ -n "$host" ] || die "启用 STUN 但没给公网 IP / 域名：sudo bash install.sh --stun 1.2.3.4"

    if [[ "$host" == *"["* || "$host" == *"]"* ]]; then
      warn "看起来是 IPv6 字面量，脚本按原样写入；若客户端打洞失败，换成域名或 IPv4 更稳"
    fi

    if [[ "$host" =~ :[0-9]+$ ]]; then
      stun_uri="stun:${host}"         # 用户自己带了端口
    else
      stun_uri="stun:${host}:${STUN_PORT}"
    fi

    # 自建 + 公共兜底：自建那条最快，cloudflare 那条防自建端口被拦
    env_set OMIOCLINK_ICE_SERVERS "${stun_uri},stun:stun.cloudflare.com:3478"
    log "OMIOCLINK_ICE_SERVERS = $(env_get OMIOCLINK_ICE_SERVERS)"
    log "自建 STUN 会监听 UDP ${STUN_PORT}，记得在防火墙/安全组放行"
  else
    current="$(env_get OMIOCLINK_ICE_SERVERS)"
    log "未启用自建 STUN，OMIOCLINK_ICE_SERVERS 保持：${current:-（空，用代码默认值）}"
    if [[ "$current" == *":${STUN_PORT}"* && "$current" != *"cloudflare"* ]]; then
      warn "它指向自建 STUN，但这次没有启动 STUN 容器；若那正是本机地址，客户端会打洞失败"
    fi
  fi
}

# ----------------------------------------------------------------------------- docker
detect_docker() {
  command -v docker >/dev/null 2>&1 \
    || die "没装 docker。先装 Docker Engine：https://docs.docker.com/engine/install/"

  if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
  else
    die "没装 docker compose 插件（或用 docker-compose）。装完再跑：apt install docker-compose-plugin"
  fi
  log "使用：${COMPOSE[*]} $(docker compose version --short 2>/dev/null || docker-compose version --short 2>/dev/null || true)"
}

# 等容器健康检查通过。返回 0 = healthy，1 = 不健康或超时
wait_healthy() {
  local i id status="unknown"
  for ((i = 1; i <= 60; i++)); do
    id="$("${COMPOSE[@]}" ps -q server 2>/dev/null | head -n 1 || true)"
    if [ -n "$id" ]; then
      status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null || echo unknown)"
      case "$status" in
        healthy)
          log "容器健康检查通过（用时约 $((i * 2)) 秒）"
          return 0
          ;;
        unhealthy)
          warn "容器状态是 unhealthy"
          return 1
          ;;
      esac
    fi
    if [ $((i % 10)) -eq 0 ]; then
      log "等待启动中…（${i} 次检查，当前状态：${status}）"
    fi
    sleep 2
  done
  warn "等了 120 秒仍未 healthy（最后状态：${status}）"
  return 1
}

print_summary() {
  local stun_line admin_line check_cmds fw_line
  if [ "$STUN_MODE" = "on" ]; then
    stun_line="已启用（UDP ${STUN_PORT}，$(env_get OMIOCLINK_ICE_SERVERS)）"
  else
    stun_line="未启用（只起信令服务）"
  fi
  if [ -n "$(env_get OMIOCLINK_ADMIN_TOKEN)" ]; then
    admin_line="已启用：http://<服务器IP或域名>:${APP_PORT}/admin （令牌见 $ENV_FILE 的 OMIOCLINK_ADMIN_TOKEN）"
  else
    admin_line="未启用（OMIOCLINK_ADMIN_TOKEN 为空）"
  fi

  fw_line="TCP ${APP_PORT}"
  if [ "$STUN_MODE" = "on" ]; then
    fw_line="TCP ${APP_PORT} 和 UDP ${STUN_PORT}"
  fi

  check_cmds="  ss -nltp | grep ${APP_PORT}        # TCP 端口（iproute2，绝大多数发行版自带）
  ss -nlup | grep ${STUN_PORT}         # UDP 端口（仅启用 STUN 时需要看）
  # 没有 ss 就试：netstat -nltp | grep ${APP_PORT}   （net-tools 需要另外装）
  # 也可以直接问 docker：${COMPOSE[*]} port server ${APP_PORT}"

  cat <<EOF

============================================================
✅ 部署完成

  安装目录   : $INSTALL_DIR
  数据卷     : ${DATA_VOLUME} → /app/data（SQLite + 头像，备份把卷拿走即可）
  服务端口   : ${APP_PORT}/tcp（HTTP + WebSocket）
  自建 STUN  : ${stun_line}
  Web 管理台 : ${admin_line}

接下来建议确认三件事：
  1) 容器状态：cd $INSTALL_DIR && ${COMPOSE[*]} ps
  2) 启动日志：cd $INSTALL_DIR && ${COMPOSE[*]} logs -f server
  3) 端口在听吗：
${check_cmds}

客户端连接页填：<你的公网IP或域名>:${APP_PORT}
别忘了在防火墙/安全组放行 ${fw_line}

改配置：编辑 $INSTALL_DIR/.env 后重跑本脚本（或 ${COMPOSE[*]} up -d）即可生效
完整日志：$LOG_FILE
============================================================
EOF
}

# ----------------------------------------------------------------------------- 主流程
main() {
  parse_args "$@"
  resolve_stun_mode
  ensure_root "$@"

  step "1/8 准备安装目录"
  mkdir -p "$INSTALL_DIR"
  setup_logging
  cd "$INSTALL_DIR"
  log "工作目录：$(pwd)"

  # 提前确认 docker / compose 可用：这一步过不了，后面的下载和启动都没意义
  detect_docker

  step "2/8 获取 ${COMPOSE_FILE_NAME} 与 ${ENV_TEMPLATE_NAME}"
  if [ -f "$COMPOSE_FILE_NAME" ] && [ "$FORCE_DOWNLOAD" -eq 0 ]; then
    log "已存在 $COMPOSE_FILE_NAME，跳过下载（要更新加 --force）"
  else
    download_from_repo "$COMPOSE_FILE_NAME" "$COMPOSE_FILE_NAME" "部署用 compose"
    grep -q '^services:' "$COMPOSE_FILE_NAME" \
      || die "$COMPOSE_FILE_NAME 内容不像 compose 文件（缺少 services:），删掉后加 --force 重跑"
  fi
  if [ -f "$ENV_TEMPLATE_NAME" ] && [ "$FORCE_DOWNLOAD" -eq 0 ]; then
    log "已存在 $ENV_TEMPLATE_NAME，跳过下载（要更新加 --force）"
  else
    download_from_repo "$ENV_TEMPLATE_NAME" "$ENV_TEMPLATE_NAME" "环境变量模板"
    grep -q '^OMIOCLINK_JWT_SECRET=' "$ENV_TEMPLATE_NAME" \
      || die "$ENV_TEMPLATE_NAME 内容不像变量模板（缺少 OMIOCLINK_JWT_SECRET=）"
  fi

  step "3/8 准备 ${ENV_FILE}"
  if [ -f "$ENV_FILE" ]; then
    log "已存在 $ENV_FILE，保留现有配置（不会覆盖你改过的值）"
  else
    cp "$ENV_TEMPLATE_NAME" "$ENV_FILE"
    log "已从 $ENV_TEMPLATE_NAME 复制出 $ENV_FILE"
  fi
  chmod 600 "$ENV_FILE"   # 里面有密钥，别让同机其他用户读到
  log "$ENV_FILE 权限已设为 600"

  step "4/8 生成并写入密钥"
  ensure_secret OMIOCLINK_JWT_SECRET "JWT 签名密钥"
  ensure_secret OMIOCLINK_ADMIN_TOKEN "Web 管理台令牌"

  step "5/8 处理 STUN 配置"
  apply_stun

  step "6/8 停止旧容器（保留数据卷）"
  log "项目名 ${COMPOSE_PROJECT_NAME}，数据在命名卷 ${DATA_VOLUME} 里，down 不会删数据"
  if "${COMPOSE[@]}" down --remove-orphans; then
    log "旧容器已清理（本来没有在跑也算正常）"
  else
    warn "docker compose down 返回非零，继续尝试启动"
  fi

  step "7/8 拉取镜像（会显示进度）"
  if ! "${COMPOSE[@]}" pull; then
    warn "拉取失败，3 秒后重试一次"
    sleep 3
    "${COMPOSE[@]}" pull
  fi

  step "8/8 启动服务"
  if [ "$STUN_MODE" = "on" ]; then
    log "启动命令：${COMPOSE[*]} --profile stun up -d"
    "${COMPOSE[@]}" --profile stun up -d
  else
    log "启动命令：${COMPOSE[*]} up -d"
    "${COMPOSE[@]}" up -d
  fi

  if ! wait_healthy; then
    printf '\n'
    "${COMPOSE[@]}" ps || true
    printf '\n'
    "${COMPOSE[@]}" logs --tail=80 server || true
    die "服务没有在 120 秒内变 healthy，上面是最近 80 行日志；修好后直接重跑本脚本"
  fi

  print_summary
}

# 只在「直接执行」时跑主流程；被 source 时只提供函数，方便本地单测各段逻辑
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
