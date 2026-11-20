#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
swift build -c release --product Moonlight --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
APP="$PWD/dist/Moonlight.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Moonlight "$APP/Contents/MacOS/Moonlight"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Moonlight</string>
<key>CFBundleDisplayName</key><string>Moonlight 月光启动器</string>
<key>CFBundleIdentifier</key><string>dev.moonlight.launcher</string>
<key>CFBundleExecutable</key><string>Moonlight</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.5.0</string>
<key>CFBundleVersion</key><string>7</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.games</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Moonlight — independent Minecraft launcher</string>
</dict></plist>
PLIST
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp "docs/Microsoft登录配置.html" "$APP/Contents/Resources/MicrosoftLoginSetup.html"
python3 - "$APP/Contents/Info.plist" <<'PY'
import os, plistlib, sys, uuid
value = os.environ.get('MOONLIGHT_MICROSOFT_CLIENT_ID', '').strip()
if value:
    application = uuid.UUID(value)
    if application.int == 0:
        raise ValueError('Microsoft Client ID cannot be all zeros')
    with open(sys.argv[1], 'rb') as source:
        data = plistlib.load(source)
    data['MoonlightMicrosoftClientID'] = str(application)
    with open(sys.argv[1], 'wb') as destination:
        plistlib.dump(data, destination)
PY
swift scripts/make-icon.swift "$PWD/.build/icon.png"
ICONSET="$PWD/.build/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" .build/icon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$(( SIZE * 2 ))
    sips -z "$DOUBLE" "$DOUBLE" .build/icon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
python3 scripts/pack-icon.py "$ICONSET" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$PWD/dist/Moonlight-macOS.zip"
print "Ready: $APP"
