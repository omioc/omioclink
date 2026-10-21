"""从品牌原图生成各处要用的图标/图片。

原图：仓库根目录的 ``OmiocLink.png``（1024×1024，深色底 + 圆环成员 + 麦克风）。
生成四份产物：

* ``client/assets/branding/omioclink.png``  —— 客户端界面里的品牌标识（圆角由控件裁）；
* ``client/windows/runner/resources/app_icon.ico`` —— 客户端窗口/任务栏/任务管理器图标（多尺寸，自带宽圆角）；
* ``server/app/web/logo.png`` —— 服务端 Web 管理页的 logo 与页签图标；
* ``assets/readme/omioclink-round.png`` —— 仓库根 README 标题左侧的圆形 logo（GitHub 会清掉
  ``style``，圆角/圆形只能烘进图里，见 ``_circular``）。

用法：``python client/tool/make_brand_assets.py``（需要 Pillow）。
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

# 脚本在 client/tool/ 下（和 make_android_icons.py 并列，一起进版本库），往上三层才是仓库根；
# 放在根 tool/ 时是两层，多了一层 client
ROOT = Path(__file__).resolve().parent.parent.parent
SOURCE = ROOT / "OmiocLink.png"

CLIENT_UI_ASSET = ROOT / "client" / "assets" / "branding" / "omioclink.png"
CLIENT_ICON = ROOT / "client" / "windows" / "runner" / "resources" / "app_icon.ico"
SERVER_LOGO = ROOT / "server" / "app" / "web" / "logo.png"
README_LOGO = ROOT / "assets" / "readme" / "omioclink-round.png"

UI_SIZE = 256
SERVER_LOGO_SIZE = 128
README_LOGO_SIZE = 256
#: Windows 图标的各档尺寸（从大到小都要有，任务栏/任务管理器用的不是同一档）
ICON_SIZES = (256, 128, 64, 48, 32, 24, 16)
#: 圆角半径占边长的比例：图标做成圆角方块，和 Win11 一票应用观感一致
CORNER_RATIO = 0.18
#: 图标里图形占边长的比例（其余是底色留白）
ICON_INNER_RATIO = 0.9


def _resize(image: Image.Image, size: int) -> Image.Image:
    return image.resize((size, size), Image.LANCZOS)


def _rounded(image: Image.Image, radius_ratio: float = CORNER_RATIO) -> Image.Image:
    """给方形图加圆角（抗锯齿），返回带透明角的 RGBA 图。"""
    size = image.width
    radius = round(size * radius_ratio)
    mask = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size * 4 - 1, size * 4 - 1), radius=radius * 4, fill=255
    )
    rounded = image.convert("RGBA")
    rounded.putalpha(mask.resize((size, size), Image.LANCZOS))
    return rounded


def _circular(image: Image.Image) -> Image.Image:
    """裁成圆形（抗锯齿），返回透明角的 RGBA 图。

    GitHub 渲染 README 时会清掉 ``style="border-radius"``，圆角只能烘进图片本身。
    """
    size = image.width
    mask = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, size * 4 - 1, size * 4 - 1), fill=255)
    circular = image.convert("RGBA")
    circular.putalpha(mask.resize((size, size), Image.LANCZOS))
    return circular


def main() -> None:
    source = Image.open(SOURCE).convert("RGBA")
    if source.width != source.height:
        side = min(source.width, source.height)
        left = (source.width - side) // 2
        top = (source.height - side) // 2
        source = source.crop((left, top, left + side, top + side))

    for path in (CLIENT_UI_ASSET, CLIENT_ICON, SERVER_LOGO, README_LOGO):
        path.parent.mkdir(parents=True, exist_ok=True)

    # 界面用：保持方图，圆角交给控件（ClipRRect）裁
    _resize(source, UI_SIZE).save(CLIENT_UI_ASSET, optimize=True)
    print(f"写出 {CLIENT_UI_ASSET.relative_to(ROOT)}（{UI_SIZE}×{UI_SIZE}）")

    # Windows 图标：圆角烘进图里，四周留一点边（图形贴边在任务栏里会显得挤），
    # 再让 Pillow 落成多尺寸 ICO
    icon_size = max(ICON_SIZES)
    canvas = Image.new("RGBA", (icon_size, icon_size), source.getpixel((2, 2)))
    inner = round(icon_size * ICON_INNER_RATIO)
    offset = (icon_size - inner) // 2
    canvas.paste(_resize(source, inner), (offset, offset))
    _rounded(canvas).save(CLIENT_ICON, sizes=[
        (size, size) for size in ICON_SIZES
    ])
    print(
        f"写出 {CLIENT_ICON.relative_to(ROOT)}（"
        + "、".join(f"{size}×{size}" for size in ICON_SIZES)
        + "）"
    )

    _resize(source, SERVER_LOGO_SIZE).save(SERVER_LOGO, optimize=True)
    print(f"写出 {SERVER_LOGO.relative_to(ROOT)}（{SERVER_LOGO_SIZE}×{SERVER_LOGO_SIZE}）")

    # README 标题左侧：圆形、透明角，尺寸给 4 倍是为了高分屏下不糊
    _circular(_resize(source, README_LOGO_SIZE)).save(README_LOGO, optimize=True)
    print(f"写出 {README_LOGO.relative_to(ROOT)}（{README_LOGO_SIZE}×{README_LOGO_SIZE}，圆形）")


if __name__ == "__main__":
    main()
