# OmiocLink 信令服务器镜像。
#
# 关于基础镜像的选择（实测得出，不是偏好）：
#   ghcr.io 在国内多数网络下不可达 —— 实测 `docker pull ghcr.io/astral-sh/uv:...`
#   中途会以 "unexpected EOF" 失败；换 DaoCloud 的 ghcr 镜像站也是 502。
#   因此这里用 Docker Hub 的官方 python 镜像（实测可达，或已有本地镜像站配置），
#   uv 改用 pip 从 PyPI 国内镜像安装。
#   项目依赖仍然严格由 uv + uv.lock 管理（版本全部来自 uv.lock），
#   只是「uv 自身的来源」与「下载地址指向哪个索引」换了。
#
# 单阶段构建的理由：依赖只有 8 个、镜像已经 slim，多阶段省下的体积有限，
# 却能避免把 .venv 跨镜像复制带来的解释器符号链接 / ABI 兼容风险。
#
# 这个镜像里只有信令/状态/房间/连接发现与 STUN：
# 没有 TURN、没有 relay、没有任何媒体转发代码。
FROM python:3.13-slim-bookworm

# 依赖下载源：默认清华 PyPI 镜像。需要官方源时覆盖即可：
#   docker compose build --build-arg PIP_INDEX_URL=https://pypi.org/simple
# 其他可选镜像：
#   https://mirrors.cloud.tencent.com/pypi/simple
#   https://mirrors.aliyun.com/pypi/simple/
#   https://pypi.mirrors.ustc.edu.cn/simple
ARG PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple

ENV PIP_INDEX_URL=${PIP_INDEX_URL} \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    UV_DEFAULT_INDEX=${PIP_INDEX_URL} \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=0 \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/app/.venv/bin:$PATH"

WORKDIR /app

# 先只复制依赖清单：源码改动不会让依赖层缓存失效
COPY pyproject.toml uv.lock ./

# 为什么不是 `uv sync --frozen`：uv.lock 把每个 wheel 的完整下载地址钉死在
# files.pythonhosted.org，并记录 source = { registry = "https://pypi.org/simple" }。
# 实测：在配置了 UV_DEFAULT_INDEX 的情况下 `uv sync --frozen` 仍然逐个从
# files.pythonhosted.org 拉包 —— 镜像对「锁定安装」不生效。
#
# 因此先用镜像源重新锁定一次（uv lock 会沿用 uv.lock 里已钉定的版本，只把索引与
# 下载地址指向镜像），再安装。已核实清华站提供的是与官方逐字节相同的包
# （854 个 sha256 完全一致），换源不改变产物。
RUN pip install --no-cache-dir uv \
    && uv lock --refresh \
    && uv sync --no-dev

COPY app ./app

# 非 root 运行；/app/data 用于挂载 SQLite 数据卷
RUN groupadd --system --gid 10001 omioclink \
    && useradd --system --uid 10001 --gid omioclink --no-create-home --home-dir /app omioclink \
    && mkdir -p /app/data \
    && chown -R omioclink:omioclink /app

USER omioclink

EXPOSE 21077

# 用 Python 标准库做健康检查，避免为镜像额外装 curl
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["python", "-c", "import sys, urllib.request; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:21077/api/v1/health', timeout=2).status == 200 else 1)"]

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "21077", "--proxy-headers", "--forwarded-allow-ips", "*"]
