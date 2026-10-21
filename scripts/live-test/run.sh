#!/bin/zsh
# Full live-path test: fake mic file -> Right Option hold -> engine -> paste into TextEdit -> read back.
# Usage: run from a terminal that has Accessibility (e.g. Orca): run.sh recording.wav seconds
# Opens a scratch TextEdit document, plays the WAV as the microphone (DAZI_FAKE_MIC),
# holds Right Option for the clip length, and prints what Dazi pasted.
K="$(cd "$(dirname $0)" && pwd)"; WAV="$1"; DUR="$2"; T="${TMPDIR:-/tmp}/dazi-live-test.txt"
S="$HOME/Library/Application Support/DaziLow/status.json"; LOG="$HOME/Library/Logs/DaziLow/engine.log"
pkill -x DaziLow; sleep 2; rm -f "$S"
: > "$T"
open -a TextEdit "$T"; sleep 2
DAZI_FAKE_MIC="$WAV" nohup "$HOME/Applications/DaziLow.app/Contents/MacOS/DaziLow" >/dev/null 2>&1 &
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
