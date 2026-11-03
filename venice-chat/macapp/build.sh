#!/bin/bash
# Сборка «И ВСЕ 3,14здец».
#   ./build.sh           — с ключом из venice-chat/.env: ставит в ~/Applications и кладёт .dmg на Рабочий стол
#   ./build.sh release   — БЕЗ ключа: zip для релиза на GitHub (из него приложение обновляется само)
# Перед сборкой закрой приложение: osascript -e 'quit app "И ВСЕ 3,14здец"'
set -euo pipefail

NAME="И ВСЕ 3,14здец"
EXE="VeniceChat"                       # не переименовывать
BUNDLE_ID="local.venice.chat"          # не переименовывать
REPO="dhanushppm762-afk/i-vse-314"     # откуда приложение берёт обновления
MODE="${1:-local}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
VERSION="$(tr -d ' \n' < "$HERE/VERSION")"
BUILD_NUM="$(echo "$VERSION" | awk -F. '{ printf "%d%02d%02d", $1, $2, $3 }')"
OUT="$ROOT/build"
APP="$OUT/$NAME.app"

rm -rf "$OUT"; mkdir -p "$OUT"
SOURCES=("$HERE"/main.swift "$HERE"/Backend.swift "$HERE"/Browser.swift "$HERE"/Updater.swift "$HERE"/SelfTest.swift)

echo "▸ Компиляция $VERSION (arm64 + x86_64)…"
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$ARCH-apple-macos12.0" -o "$OUT/$EXE-$ARCH" "${SOURCES[@]}" \
    -framework AppKit -framework WebKit
done

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/$EXE" "$OUT/$EXE-arm64" "$OUT/$EXE-x86_64"
rm "$OUT/$EXE-arm64" "$OUT/$EXE-x86_64"
cp -R "$ROOT/static" "$APP/Contents/Resources/static"
cp "$HERE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUM</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Чат, картинки и проекты на моделях Venice AI</string>
  <key>VCUpdateRepo</key><string>$REPO</string>
</dict></plist>
PLIST

if [ "$MODE" = "release" ]; then
  codesign --force --deep -s - "$APP"
  ZIP="$OUT/IVSE314-$VERSION.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "✓ Релиз без ключа: $ZIP"
  echo "  Загрузи его в GitHub → Releases с тегом v$VERSION"
  exit 0
fi

# Ключ владельца вшивается только в локальную сборку и .dmg — в git и релизы он не попадает
KEY="$(grep -E '^VENICE_API_KEY=' "$ROOT/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"' \r')"
if [ -n "$KEY" ]; then printf '%s' "$KEY" > "$APP/Contents/Resources/key.txt"; else echo "⚠️  В .env нет ключа — сборка без ключа"; fi
codesign --force --deep -s - "$APP"

echo "▸ Установка в ~/Applications…"
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Venice Chat.app" "$HOME/Applications/$NAME.app"
ditto "$APP" "$HOME/Applications/$NAME.app"

echo "▸ Образ .dmg…"
STAGE="$OUT/dmg"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Программы"
cp "$HERE/Как установить.txt" "$STAGE/"
DMG="$HOME/Desktop/$NAME.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
echo "✓ Готово: ~/Applications/$NAME.app и $DMG"
