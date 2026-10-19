"""从品牌原图生成 Android 启动图标（各密度 legacy / round / 自适应图层）。

原图：仓库根的 ``OmiocLink.png``（1254×1254，深蓝底 + 蓝色圆环与麦克风图形）。
之前安卓工程里用的是 Flutter 模板自带的那个白色图标，装上手机认不出是哪个应用。

写进 ``client/android/app/src/main/res/``：

* ``mipmap-*/ic_launcher.png``          Android 7 及以下的方形图标（圆角，和 Windows 图标同一套处理）；
* ``mipmap-*/ic_launcher_round.png``    同上，裁成圆形（清单里的 ``roundIcon``）；
* ``mipmap-*/ic_launcher_foreground.png``
  + ``mipmap-anydpi-v26/ic_launcher*.xml``
  Android 8+ 的自适应图标。前景直接用整张原图：这套品牌图形本身是满幅设计
  （圆环直径约占边长 87%），裁到圆形遮罩里时环的两端仍在半径之内，
  缩进 72dp 安全区反而会平白小一圈；背景取原图角上的底色，遮罩怎么裁都接得上。

用法::

    python client/tool/make_android_icons.py      # 需要 Pillow

改完图要重新打包才生效（图标进的是 APK 资源）。
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent.parent  # 仓库根
SOURCE = ROOT / "OmiocLink.png"
BRANDING = ROOT / "client" / "assets" / "branding" / "omioclink.png"
RES = ROOT / "client" / "android" / "app" / "src" / "main" / "res"

#: 密度 → 缩放比（48dp 的图标在各密度下的像素边长）
DENSITIES = {
    "mdpi": 1.0,
    "hdpi": 1.5,
    "xhdpi": 2.0,
    "xxhdpi": 3.0,
    "xxxhdpi": 4.0,
}

#: 图标边长（dp）。legacy 与 round 都是 48dp，自适应前景层是 108dp。
LEGACY_DP = 48
ADAPTIVE_DP = 108

#: 圆角半径占边长的比例，与 ``client/tool/make_brand_assets.py`` 的 Windows 图标一致
CORNER_RATIO = 0.18
#: 图形占图标的比例（其余是底色留白），同样沿用 Windows 那套
INNER_RATIO = 0.9


def _load_source() -> Image.Image:
    path = SOURCE if SOURCE.exists() else BRANDING
    image = Image.open(path).convert("RGBA")
    if image.width != image.height:
        side = min(image.width, image.height)
        left = (image.width - side) // 2
        top = (image.height - side) // 2
        image = image.crop((left, top, left + side, top + side))
    return image


def _scale(image: Image.Image, size: int) -> Image.Image:
    return image.resize((size, size), Image.LANCZOS)


def _corner_color(image: Image.Image) -> tuple[int, int, int]:
    return image.getpixel((2, 2))[:3]


def _rounded(image: Image.Image) -> Image.Image:
    """圆角方形（抗锯齿）：与 Windows 图标的观感对齐。"""
    size = image.width
    radius = round(size * CORNER_RATIO)
    mask = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size * 4 - 1, size * 4 - 1), radius=radius * 4, fill=255
    )
    rounded = image.convert("RGBA")
    rounded.putalpha(mask.resize((size, size), Image.LANCZOS))
    return rounded


def _circle(image: Image.Image) -> Image.Image:
    size = image.width
    mask = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, size * 4 - 1, size * 4 - 1), fill=255)
    circled = image.convert("RGBA")
    circled.putalpha(mask.resize((size, size), Image.LANCZOS))
    return circled


def _legacy(source: Image.Image, size: int) -> Image.Image:
    """方形图标：底色画布 + 居中缩到 90% 的图形。"""
    canvas = Image.new("RGBA", (size, size), _corner_color(source))
    inner = round(size * INNER_RATIO)
    offset = (size - inner) // 2
    canvas.paste(_scale(source, inner), (offset, offset))
    return canvas


def _write(path: Path, image: Image.Image) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, optimize=True)


def _write_adaptive_xml(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        "</adaptive-icon>\n",
        encoding="utf-8",
    )


def _write_background_color(color: tuple[int, int, int]) -> None:
    values = RES / "values" / "ic_launcher_background.xml"
    values.parent.mkdir(parents=True, exist_ok=True)
    hex_color = "#{:02X}{:02X}{:02X}".format(*color)
    values.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<!-- 由 client/tool/make_android_icons.py 生成：自适应图标的背景色 -->\n"
        "<resources>\n"
        f'    <color name="ic_launcher_background">{hex_color}</color>\n'
        "</resources>\n",
        encoding="utf-8",
    )


def main() -> None:
    source = _load_source()
    color = _corner_color(source)

    for density, scale in DENSITIES.items():
        folder = RES / f"mipmap-{density}"
        size = round(LEGACY_DP * scale)
        icon = _legacy(source, size)
        _write(folder / "ic_launcher.png", _rounded(icon))
        _write(folder / "ic_launcher_round.png", _circle(icon))
        # 自适应前景：整张原图（满幅设计，见文件头说明）
        _write(
            folder / "ic_launcher_foreground.png",
            _scale(source, round(ADAPTIVE_DP * scale)),
        )
        print(f"写入 mipmap-{density}：icon {size}px、前景 {round(ADAPTIVE_DP * scale)}px")

    _write_adaptive_xml(RES / "mipmap-anydpi-v26" / "ic_launcher.xml")
    _write_adaptive_xml(RES / "mipmap-anydpi-v26" / "ic_launcher_round.xml")
    _write_background_color(color)
    print(f"写入 mipmap-anydpi-v26 自适应图标，背景色 #%02X%02X%02X" % color)


if __name__ == "__main__":
    main()
