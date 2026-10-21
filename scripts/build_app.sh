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

# The designated requirement names only the bundle identifier, so privacy grants
# (Microphone, Accessibility) keep matching after a rebuild changes the code hash.
codesign --force --sign - --identifier "$BUNDLE_ID" \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
codesign --verify --verbose=1 "$APP"
echo "built $APP"
