"""Makes one of the icons in Resources/Icons the app icon: writes Resources/AppIcon.icns (what build.sh and
release.sh put in the app), Resources/AppIcon-1024.png and the README's docs/nerdpass-icon.png.

Usage:  python3 Tools/set_icon.py wave-burst        (or needle, wave-line: the file names in Resources/Icons)
Needs:  pip install pillow   (macOS: uses iconutil)
"""
import os, subprocess, sys, tempfile
from PIL import Image

ICONS = "Resources/Icons"
names = sorted(f[:-4] for f in os.listdir(ICONS) if f.endswith(".png"))
if len(sys.argv) != 2 or sys.argv[1] not in names:
    sys.exit(f"usage: python3 Tools/set_icon.py <{'|'.join(names)}>")
icon = Image.open(os.path.join(ICONS, sys.argv[1] + ".png")).convert("RGBA").resize((1024, 1024), Image.LANCZOS)
iconset = os.path.join(tempfile.mkdtemp(), "AppIcon.iconset"); os.makedirs(iconset)
for s in (16, 32, 64, 128, 256, 512):
    icon.resize((s, s), Image.LANCZOS).save(f"{iconset}/icon_{s}x{s}.png")
    icon.resize((s * 2, s * 2), Image.LANCZOS).save(f"{iconset}/icon_{s}x{s}@2x.png")
subprocess.run(["iconutil", "-c", "icns", iconset, "-o", "Resources/AppIcon.icns"], check=True)
icon.save("Resources/AppIcon-1024.png")
icon.save("docs/nerdpass-icon.png")
print(f"app icon: {sys.argv[1]}")
