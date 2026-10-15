#!/usr/bin/env python3
"""Render every app-icon asset from icon.svg.

Chrome rasterizes the SVG once at 1024 px; sips downsamples that master for the
smaller sizes. Rendering the vector directly at 16/32 px dithers the shadow
filters, while the downsampled master stays clean.

Usage: python3 scripts/render_app_icon.py
"""
import json
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
README_ICON_SIZE = 256


def render_master(svg: pathlib.Path, png: pathlib.Path) -> None:
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--force-device-scale-factor=1", "--default-background-color=00000000",
                    "--window-size=1024,1024", f"--screenshot={png}", svg.as_uri()],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def resize(master: pathlib.Path, size: int, dst: pathlib.Path) -> None:
    if size == 1024:
        dst.write_bytes(master.read_bytes())
        return
    subprocess.run(["sips", "-z", str(size), str(size), str(master), "--out", str(dst)],
                   check=True, stdout=subprocess.DEVNULL)


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        master = pathlib.Path(tmp) / "master.png"
        render_master(ROOT / "icon.svg", master)

        resize(master, README_ICON_SIZE, ROOT / "icon.png")

        iconset = ROOT / "RuSwitcher.iconset"
        for base in (16, 32, 128, 256, 512):
            resize(master, base, iconset / f"icon_{base}x{base}.png")
            resize(master, base * 2, iconset / f"icon_{base}x{base}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(ROOT / "RuSwitcher.icns")],
                       check=True)

        appiconset = ROOT / "Assets.xcassets" / "AppIcon.appiconset"
        contents = json.loads((appiconset / "Contents.json").read_text())
        for name in {image["filename"] for image in contents["images"]}:
            resize(master, int(name.removeprefix("icon_").removesuffix(".png")), appiconset / name)


if __name__ == "__main__":
    main()
