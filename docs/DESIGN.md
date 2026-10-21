# Dazi Low — design

A personal, fully local push-to-talk dictation app for macOS (Apple Silicon), built to
match Typeless on accuracy and output quality for mixed Chinese–English speech, at zero
cost. One user, one machine, one job: hold a key, speak, release, the cleaned-up text
appears at the cursor.

## Goals, in priority order

1. **Accuracy** on the user's real speech: Mandarin with embedded English tech terms,
   plus pure English. Names, repos, products and jargon must come out spelled right.
2. **Free**: everything runs locally; no API keys, no subscriptions, no cloud calls.
3. **Latency**: time from key release to inserted text as short as possible.
4. **Output quality ("整理/总结")**: Typeless-style cleanup — fillers and repetitions
   removed, self-corrections resolved, long dictations split into paragraphs or
   numbered lists — while staying faithful (never answering or expanding).

Non-goals: meeting notes, commands, translation mode, multi-user settings, Windows.

## Architecture

```
┌──────────── DaziLow.app (Swift, menu bar) ────────────┐
│ HotkeyMonitor (Right ⌥)  →  AudioRecorder (16 kHz)    │
│        │                          │ 100 ms PCM chunks │
│        ▼                          ▼                   │
│   HUD capsule              EngineClient ──────────────┼──┐ Unix socket,
│        ▲                          │ result text       │  │ NDJSON
│        └──── Paster (⌘V, restores clipboard) ◀────────┘  │
└───────────────────────────────────────────────────────┘  │
┌──────────── engine/server.py (Python, MLX) ────────────┐ │
│ Segmenter: cuts at pauses while you talk  ◀────────────┼─┘
│ Recognizer: Qwen3-ASR 1.7B 8-bit + hotwords (cached)   │
│ Lexicon: deterministic replacements                     │
│ Polisher: local LLM post-editor (cached system prompt,  │
│           prompt-lookup decoding) + faithfulness guard  │
│ History: audio + raw + final, local only                │
└────────────────────────────────────────────────────────┘
```

The app owns the permissions (Microphone, Accessibility) and the UI. The engine is a
child process the app starts and restarts; it keeps both models warm in memory.

## Model choice (measured, not assumed)

Evaluation set: the user's own 111 Typeless recordings (85 min, median 33 s, mixed
Chinese–English) with Typeless's output as the reference. Typeless output is
restructured, so absolute error rates are inflated; comparisons are relative. "Term
recall" = share of the user's vocabulary terms in the reference that the output spells
exactly right.

| Recognizer | English WER | Term recall | Speed (× real time) |
|---|---|---|---|
| Qwen3-ASR 1.7B 8-bit | 38.7 | 64.6 | 24× |
| Qwen3-ASR 1.7B bf16 | 38.1 | 65.7 | 13× |
| Qwen3-ASR 0.6B 8-bit | 49.3 | 50.0 | 52× |
| SenseVoice Small | 76.5 | 18.0 | 55× |
| FireRedASR2-AED | — (no punctuation, lower-cased English, 0.5× real time) | | |

Qwen3-ASR 1.7B 8-bit wins; bf16 is no more accurate and half the speed. Whisper and
Fun-ASR are weaker on Mandarin in published benchmarks (FLEURS zh CER 8.0–8.6 vs 7.1).

Post-editor: Qwen3.5-4B is fast but not faithful (it answers the instructions it is
supposed to edit). Qwen3.5-9B 4-bit is faithful (all 30 sampled outputs passed the guard)
and brings term recall to ~97%. Larger models (Qwen3.6-35B-A3B, 20 GB) do not fit: the
machine already runs with ~27 GB of swap in use, so the engine budget is ~8 GB.

## Accuracy levers

1. **Hotwords** — the top ~300 personal terms go into Qwen3-ASR's system prompt
   (its native context-biasing mechanism). Term recall 73.8 → 77.9 on the first run.
2. **Deterministic replacements** — high-confidence misrecognition rules mined from
   history ("GroqCode" → Claude Code, "Voice In" → VoiceInk, "data dog" → Datadog …).
3. **LLM post-edit with the full vocabulary** and few-shot examples of the user's own
   Typeless output style.
4. **Language lock for live segments** — segments are recognized while the user is
   still talking; once Chinese has been heard, later segments are forced to Chinese
   mode (which keeps English words in English). Without the lock, a segment that starts
   with an English word is sometimes translated wholesale into English.

## Latency levers

1. **Incremental recognition** — the Segmenter cuts at ≥0.45 s pauses once a segment is
   ≥8 s long; those segments are recognized in the background while recording, so
   after release only the last few seconds remain (tail p50 0.5 s vs 2.3 s whole-file).
2. **Cached prefixes** — the hotword prompt (ASR) and the rules/vocabulary/examples
   prompt (LLM) are prefilled once; requests only pay for their own tokens. The ASR
   wrapper also replaces mlx-audio's per-position Python loop with one concatenate
   (identical output, ~0.6 s faster per call).
3. **Prompt-lookup decoding** — the post-edit mostly copies the transcript, so drafts
   are taken from the transcript and verified in one pass; greedy, so output is
   identical to plain decoding.
4. **Warm models** — the engine loads at app start and warms both models.

## Faithfulness guard

The post-edit is rejected (raw transcript + replacements is inserted instead) when the
output is empty, shrinks below 30% or grows past 2× the input, or when more than 35% of
its tokens never appear in the transcript or vocabulary. Calibrated on the eval set:
Typeless's own edits stay under 23% novel tokens (p97); outputs that answer instead of
edit score 55% and up.

## Privacy

Everything stays on the machine. Personal data — the vocabulary (colleague names,
internal service names), example pairs, history and audio — lives in
`~/Library/Application Support/DaziLow/`, never in this public repository.

## Hotkey

Right Option (⌥), chosen because it is free on this machine (Typeless uses
Left Ctrl+`, VoiceInk Ctrl+Tab) and is a single key.

- Hold to talk, release to insert.
- Tap once for hands-free; tap again to insert.
- Esc cancels. Pressing another key within 1 s of pressing ⌥ is treated as a normal
  Option shortcut and silently cancels.

## Open risks

- Prompt-lookup gains on hybrid (DeltaNet) models are limited because rejected drafts
  must be replayed; measured separately on an idle GPU.
- TCC permissions are tied to the code signature. The app is ad-hoc signed with the
  default code-hash requirement, so a reinstall needs the two permissions re-enabled
  (an identifier-only requirement would let any app reusing the identifier inherit them).
