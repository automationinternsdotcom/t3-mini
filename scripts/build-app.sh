#!/bin/zsh
# Build "T3 Mini.app" into ./build (and optionally install to ~/Applications).
#   scripts/build-app.sh            build release app bundle
#   scripts/build-app.sh --install  also copy to ~/Applications and (re)launch it
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
APP="$ROOT/build/T3 Mini.app"
VERSION=$(cat VERSION 2>/dev/null || echo 0.1.0)

if [[ ! -f assets/pets/tee/spritesheet.png ]]; then
  echo "==> Generating pets"
  python3 tools/make_pets.py assets/pets >/dev/null
fi

echo "==> Compiling (release)"
swift build -c release --product T3Mini 2>&1 | grep -v "search path" || true
swift build -c release --product t3mini-check 2>&1 | grep -v "search path" || true
BIN=$(swift build -c release --show-bin-path)
[[ -x "$BIN/T3Mini" ]] || { echo "build failed"; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/pets"
cp "$BIN/T3Mini" "$APP/Contents/MacOS/T3Mini"
cp "$BIN/t3mini-check" "$APP/Contents/MacOS/t3mini-check"
for d in assets/pets/*/; do cp -R "${d%/}" "$APP/Contents/Resources/pets/"; done

# App icon: the idle frame of the default pet, on a rounded tile.
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
python3 - "$ICONSET" <<'PY'
import sys
from PIL import Image, ImageDraw
out = sys.argv[1]
sheet = Image.open("assets/pets/tee/spritesheet.png")
cell = sheet.crop((0, 0, 192, 208))
bbox = cell.getbbox()
pet = cell.crop(bbox)
for size in (16, 32, 64, 128, 256, 512, 1024):
    tile = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(tile)
    m = int(size * 0.09)
    d.rounded_rectangle([m, m, size - m, size - m], radius=int(size * 0.2), fill=(28, 32, 48, 255))
    inner = int(size * 0.62)
    scale = inner / max(pet.size)
    p = pet.resize((max(1, int(pet.width * scale)), max(1, int(pet.height * scale))), Image.NEAREST)
    tile.alpha_composite(p, ((size - p.width) // 2, (size - p.height) // 2 + int(size * 0.02)))
    if size <= 512:
        tile.save(f"{out}/icon_{size}x{size}.png")
    if size >= 32:
        tile.save(f"{out}/icon_{size // 2}x{size // 2}@2x.png")
PY
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || echo "   (iconutil skipped)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>T3 Mini</string>
  <key>CFBundleDisplayName</key><string>T3 Mini</string>
  <key>CFBundleIdentifier</key><string>com.t3mini.app</string>
  <key>CFBundleExecutable</key><string>T3Mini</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Unofficial community project, not affiliated with T3 Tools or OpenAI. MIT License.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>T3 Mini control</string>
      <key>CFBundleURLSchemes</key><array><string>t3mini</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 && echo "==> Ad-hoc signed"
echo "==> Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/T3 Mini.app"
  pkill -x T3Mini 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
  open "$DEST"
  echo "==> Installed and launched $DEST"
fi
