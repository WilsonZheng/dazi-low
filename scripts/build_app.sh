#!/bin/zsh
# Builds build/DaziLow.app (release, ad-hoc signed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/DaziLow.app"
BUNDLE_ID="com.wilsonzheng.dazilow"

swift build -c release --package-path "$ROOT/app"
BIN="$(swift build -c release --package-path "$ROOT/app" --show-bin-path)/DaziLow"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine"
cp "$BIN" "$APP/Contents/MacOS/DaziLow"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT"/engine/*.py "$ROOT/engine/requirements.txt" "$APP/Contents/Resources/engine/"

# Ad-hoc signature with the default (code-hash) requirement: privacy grants
# (Microphone, Accessibility) bind to this exact build. A requirement on the bundle
# identifier alone would survive rebuilds but let any app reusing the identifier
# inherit the grants; a self-signed certificate needs an admin/GUI trust prompt.
# So after reinstalling, re-enable Dazi under Privacy & Security.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --verbose=1 "$APP"
echo "built $APP"
