#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/YCT.app"
DMG_STAGING="$BUILD_DIR/dmg_staging"
DMG_OUTPUT="$PROJECT_DIR/YCT-Installer.dmg"

echo "==> [1/6] Cleaning previous build artifacts..."
rm -rf "$BUILD_DIR" "$DMG_OUTPUT"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources/bin"
mkdir -p "$DMG_STAGING"
mkdir -p "$PROJECT_DIR/Resources/bin"

if [[ ! -f "$PROJECT_DIR/Resources/bin/yt-dlp" ]]; then
    echo "==> Downloading latest universal yt-dlp..."
    curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o "$PROJECT_DIR/Resources/bin/yt-dlp"
    chmod +x "$PROJECT_DIR/Resources/bin/yt-dlp"
fi

export TMPDIR=/tmp
echo "==> [2/6] Generating macOS AppIcon.icns..."
mkdir -p /tmp/swift_module_cache
swift -module-cache-path /tmp/swift_module_cache "$PROJECT_DIR/scripts/generate_icon.swift" "$PROJECT_DIR"

echo "==> [3/6] Compiling YCT native macOS application..."
swiftc -O \
    -module-cache-path /tmp/swift_module_cache \
    -parse-as-library \
    -framework AppKit \
    -framework SwiftUI \
    -framework Combine \
    -framework Foundation \
    "$PROJECT_DIR/Sources/Models.swift" \
    "$PROJECT_DIR/Sources/HighlightDetector.swift" \
    "$PROJECT_DIR/Sources/ClipEngine.swift" \
    "$PROJECT_DIR/Sources/ContentView.swift" \
    "$PROJECT_DIR/Sources/YCTApp.swift" \
    -o "$APP_BUNDLE/Contents/MacOS/YCT"

chmod +x "$APP_BUNDLE/Contents/MacOS/YCT"

echo "==> [4/6] Packaging bundle resources (Info.plist, AppIcon, yt-dlp, ffmpeg launcher)..."
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Resources/bin/yt-dlp" "$APP_BUNDLE/Contents/Resources/bin/yt-dlp"
chmod +x "$APP_BUNDLE/Contents/Resources/bin/yt-dlp"

cat << 'EOF' > "$APP_BUNDLE/Contents/Resources/bin/ffmpeg"
#!/bin/zsh
for candidate in "/opt/homebrew/bin/ffmpeg" "/usr/local/bin/ffmpeg" "/usr/bin/ffmpeg"; do
    if [[ -x "$candidate" ]]; then
        exec "$candidate" "$@"
    fi
done
echo "Error: ffmpeg not found in /opt/homebrew/bin or /usr/local/bin" >&2
exit 1
EOF
chmod +x "$APP_BUNDLE/Contents/Resources/bin/ffmpeg"

echo "==> [5/6] Signing YCT.app bundle..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> [6/6] Building installable disk image: YCT-Installer.dmg..."
cp -R "$APP_BUNDLE" "$DMG_STAGING/YCT.app"
ln -s /Applications "$DMG_STAGING/Applications"

cat << 'EOF' > "$DMG_STAGING/README - Install & Usage.txt"
======================================================================
           YCT — YouTube High-Moment Clipping Tool (macOS)
======================================================================

INSTALLATION:
1. Drag "YCT.app" into the "Applications" folder shortcut in this window.
2. Open "YCT" from your Applications folder (or Launchpad).

HOW TO USE:
1. Paste any YouTube Video URL (or select a Local Video File).
2. Set the Number of Clips you want to extract (e.g., 5 clips).
3. Set the Duration for every clip in seconds (e.g., 30s), or enable
   "Set custom duration for each individual clip".
4. Choose your Output Folder where all extracted clips will be saved.
5. (Optional) Choose Original 16:9 or Vertical 9:16 (Shorts/TikTok/Reels),
   or check "Also keep the full downloaded video".
6. Click "Download & Extract High-Moment Clips"!
======================================================================
EOF

hdiutil create \
    -volname "YCT Installer" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_OUTPUT"

echo ""
echo "======================================================================"
echo "SUCCESS! Built:"
echo "  • App Bundle : $APP_BUNDLE"
echo "  • DMG File   : $DMG_OUTPUT"
echo "======================================================================"
ls -lh "$DMG_OUTPUT"
