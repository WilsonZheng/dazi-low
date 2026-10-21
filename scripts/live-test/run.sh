#!/bin/zsh
# Full live-path test: fake mic file -> Right Option hold -> engine -> paste into TextEdit -> read back.
# Usage: run from a terminal that has Accessibility (e.g. Orca): run.sh recording.wav seconds
# Opens a scratch TextEdit document, plays the WAV as the microphone (KAIKOU_FAKE_MIC),
# holds Right Option for the clip length, and prints what Kaikou pasted.
K="$(cd "$(dirname $0)" && pwd)"; WAV="$1"; DUR="$2"; T="${TMPDIR:-/tmp}/kaikou-live-test.txt"
S="$HOME/Library/Application Support/Kaikou/status.json"; LOG="$HOME/Library/Logs/Kaikou/engine.log"
pkill -x Kaikou; sleep 2; rm -f "$S"
: > "$T"
open -a TextEdit "$T"; sleep 2
KAIKOU_FAKE_MIC="$WAV" nohup "$HOME/Applications/Kaikou.app/Contents/MacOS/Kaikou" >/dev/null 2>&1 &
for i in {1..90}; do grep -q '"engine_ready" : true' "$S" 2>/dev/null && break; sleep 1; done
grep -E 'accessibility|engine_ready' "$S"
open -a TextEdit "$T"; sleep 1.5
before=$(wc -l < "$LOG")
swift "$K/hold.swift" $(( DUR + 1 ))
for i in {1..60}; do tail -n +$((before+1)) "$LOG" | grep -q 'INFO result' && break; sleep 0.5; done
tail -n +$((before+1)) "$LOG" | grep 'INFO result' | cut -c1-120
sleep 2.5
echo "--- TextEdit now contains:"
swift "$K/read_focused.swift" com.apple.TextEdit
