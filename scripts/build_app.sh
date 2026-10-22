#!/bin/zsh
# Builds build/Kaikou.app (release, ad-hoc signed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Kaikou.app"
BUNDLE_ID="com.wilsonzheng.kaikou"

swift build -c release --package-path "$ROOT/app"
BIN="$(swift build -c release --package-path "$ROOT/app" --show-bin-path)/Kaikou"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine"
cp "$BIN" "$APP/Contents/MacOS/Kaikou"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/app/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT"/engine/*.py "$ROOT/engine/requirements.txt" "$APP/Contents/Resources/engine/"

# Ad-hoc signature with the default (code-hash) requirement: privacy grants
# (Microphone, Accessibility) bind to this exact build. A requirement on the bundle
# identifier alone would survive rebuilds but let any app reusing the identifier
# inherit the grants; a self-signed certificate needs an admin/GUI trust prompt.
# So after reinstalling, re-enable Kaikou under Privacy & Security.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --verbose=1 "$APP"
echo "built $APP"
