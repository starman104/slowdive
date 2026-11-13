#!/bin/zsh
# Builds Slowdive.app from main.swift.
#
#   1. Install Apple's command line tools once:   xcode-select --install
#   2. In Terminal, cd into this folder and run:  zsh build.sh
#
# Slowdive.app and a "Source" folder (settings, wallpaper, sounds, saves, games)
# are created next to this script. Keep them together; you can move the whole
# folder anywhere, including an external drive.

set -e
cd "$(dirname "$0")"
HERE="$(pwd)"

APP_NAME="Slowdive"
BUNDLE="${APP_NAME}.app"
SOURCE_DIR="$HERE/Source"
DATA_DIR="$SOURCE_DIR/$APP_NAME"             # settings (launcher-config.json)
ASSETS_DIR="$DATA_DIR/${APP_NAME}-src"       # wallpaper and sounds

# --- 1. Swift compiler check ------------------------------------------------
if ! command -v swiftc >/dev/null 2>&1; then
    echo "The Swift compiler was not found."
    echo "Installing Apple's command line tools (a window will pop up)..."
    xcode-select --install || true
    echo "When the install has finished, run this script again."
    exit 1
fi

# --- 2. Folders the launcher expects ---------------------------------------
mkdir -p "$SOURCE_DIR/Switch/Games" "$SOURCE_DIR/Switch/Save" "$ASSETS_DIR"

# --- 3. Starter wallpaper and sounds (files you already changed are kept) ---
for f in wallpaper.jpg enter.wav select.wav mainmenu.flac; do
    if [ -f "$f" ] && [ ! -f "$ASSETS_DIR/$f" ]; then
        cp "$f" "$ASSETS_DIR/"
    fi
done

# --- 4. Empty game list (only if you don't have a config yet) --------------
CONFIG="$DATA_DIR/launcher-config.json"
if [ ! -f "$CONFIG" ]; then
    echo "Creating empty game list..."
    cat > "$CONFIG" <<'EOF'
{
  "settings": {},
  "tiles": []
}
EOF
fi

# --- 5. Build ---------------------------------------------------------------
# main.swift finds its Source folder by the layout Source/<name>/<name>-src/main.swift, so we
# compile a copy that sits there (and rename the internal folder names to match this app).
sed "s/Gamecube/${APP_NAME}/g" main.swift > "$ASSETS_DIR/main.swift"

rm -rf "$HERE/$BUNDLE"
mkdir -p "$HERE/$BUNDLE/Contents/MacOS" "$HERE/$BUNDLE/Contents/Resources"

echo "Compiling (this takes about a minute)..."
swiftc -O -parse-as-library "$ASSETS_DIR/main.swift" \
    -target "$(uname -m)-apple-macos13.0" \
    -framework GameController -framework AVFoundation -framework AVKit \
    -o "$HERE/$BUNDLE/Contents/MacOS/$APP_NAME"

cp Info.plist "$HERE/$BUNDLE/Contents/Info.plist"

# --- 6. Icon ----------------------------------------------------------------
if [ -f "ico.icns" ]; then
    cp ico.icns "$HERE/$BUNDLE/Contents/Resources/AppIcon.icns"
fi
# Optional: precompiled Tahoe icon styles (Default / Dark / Clear / Tinted)
if [ -f "Assets.car" ]; then
    cp Assets.car "$HERE/$BUNDLE/Contents/Resources/Assets.car"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$HERE/$BUNDLE/Contents/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :CFBundleIconName AppIcon" "$HERE/$BUNDLE/Contents/Info.plist"
fi

# --- 7. Sign (free, ad-hoc) and finish --------------------------------------
codesign --force --deep --sign - "$HERE/$BUNDLE" 2>/dev/null || true
xattr -cr "$HERE/$BUNDLE" 2>/dev/null || true
touch "$HERE/$BUNDLE"

echo
echo "Done: $HERE/$BUNDLE"
echo "Double-click it to start. Press Cmd+, inside ${APP_NAME} to add your games."
