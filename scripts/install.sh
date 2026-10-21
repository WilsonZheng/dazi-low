#!/bin/zsh
# Builds Dazi, installs it to ~/Applications, prepares the engine venv and models.
# No admin rights needed. Re-run after pulling changes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="$HOME/Library/Application Support/DaziLow"
DEST="$HOME/Applications/DaziLow.app"
mkdir -p "$SUPPORT" "$HOME/Applications" "$HOME/Library/Logs/DaziLow"

"$ROOT/scripts/build_app.sh"

echo "==> engine code (outside the app bundle, so updates keep macOS permissions)"
mkdir -p "$SUPPORT/engine"
cp "$ROOT"/engine/*.py "$ROOT/engine/requirements.txt" "$SUPPORT/engine/"

echo "==> engine environment"
if [ ! -x "$SUPPORT/venv/bin/python" ]; then
  uv venv --quiet --python 3.12 "$SUPPORT/venv"
fi
uv pip install --quiet --python "$SUPPORT/venv/bin/python" -r "$ROOT/engine/requirements.txt"

echo "==> models (first run downloads ~8 GB)"
"$SUPPORT/venv/bin/python" - "$ROOT/engine" "$SUPPORT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from config import load_config
from huggingface_hub import snapshot_download
cfg = load_config(sys.argv[2])
for key in ("asr_model", "llm_model"):
    print(" ", cfg[key], "->", snapshot_download(cfg[key]))
PY

if [ ! -f "$SUPPORT/lexicon.json" ]; then
  echo "==> no personal lexicon yet; installing an empty one ($SUPPORT/lexicon.json)"
  echo '{"terms": [], "replacements": [], "examples": []}' > "$SUPPORT/lexicon.json"
fi

mkdir -p "$HOME/.local/bin"
ln -sf "$ROOT/scripts/dazi-ensure" "$HOME/.local/bin/dazi-ensure"

echo "==> installing app"
if [ -d "$DEST" ] && [ "${1:-}" != "--app" ]; then
  # Replacing the app changes its signature and macOS drops its permissions, so only
  # the engine is updated unless --app is given.
  echo "app already installed; engine updated. Restart the engine from the menu (重启引擎)."
  echo "Pass --app to reinstall the app too (then re-enable its permissions)."
  exit 0
fi
pkill -x DaziLow 2>/dev/null && sleep 1 || true
rm -rf "$DEST"
ditto "$ROOT/build/DaziLow.app" "$DEST"
open "$DEST"
echo "installed $DEST"
