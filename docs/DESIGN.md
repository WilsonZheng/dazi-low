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

Post-editor, measured end to end with the real engine code (16 s live segments, the
user's lexicon, 102 clips; "MER vs Typeless" = how far the final text is from what
Typeless produced for the same recording, lower is closer):

| Post-editor | MER vs Typeless | Term recall | Guard rejections | Decode speed |
|---|---|---|---|---|
| none (recognizer + rules only) | 39.4 | 81.5 | — | — |
| **Qwen3-8B 4-bit** | **33.9** | 82.1 | **0 / 102** | 30.6 tok/s |
| Qwen3.5-9B 4-bit | 35.2 | 83.1 | 9 / 102 | 28.5 tok/s |
| Qwen3-4B-2507 8-bit | 37.9 | 81.5 | 5 / 102 | 32.0 tok/s |
| Qwen3-4B-2507 4-bit | 40.9 | 82.6 | 7 / 102 | 36.3 tok/s |

Qwen3-8B wins on closeness to Typeless and never trips the faithfulness guard; its
standard attention also makes rejected prompt-lookup drafts free to discard (the 9B's
DeltaNet layers must be replayed). Qwen3.5-4B (not in the table) answered the
instructions it was meant to edit. Larger models do not fit: the machine already runs
with ~17–27 GB of swap in use, so the engine budget is ~8 GB.

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

1. **Incremental recognition** — the Segmenter cuts at the first ≥0.45 s pause once a
   segment is ≥16 s long (eagerly, without waiting for speech to resume); those
   segments are recognized in the background while the user is still talking. On the
   eval set this costs 0.5 MER points against whole-file recognition and cuts the
   recognition left after release from p50 1.3 s / p90 4.0 s to 0.35 s / 0.70 s.
2. **Chunked editing while recording** — every recognized segment, minus its last and
   possibly unfinished sentence, is post-edited in the background; after release only
   the remainder is edited. Run-on speech with no sentence ends is split at the last
   comma past 80 characters and glued back with a comma. Numbered lists split by a
   chunk boundary keep counting. This lowered MER vs Typeless (34.1 → 32.7) and made
   waiting independent of dictation length.
3. **Cached prefixes** — the hotword prompt (ASR) and the rules/vocabulary/examples
   prompt (LLM) are prefilled once; requests only pay for their own tokens. The ASR
   wrapper also replaces mlx-audio's per-position Python loop with one concatenate.
4. **Prompt-lookup decoding** (draft length 4), greedy, so the output matches plain
   decoding. Measured ~1.7× on short contexts; MLX's quantized matmul cost grows almost
   linearly with the verified width (41 ms for 2 tokens, +18 ms per extra token on the
   M2 Pro), which caps the gain.
5. **Wired weights** — `mx.set_wired_limit(9.5 GB)`; without it, swap pressure on this
   machine paged the model out between requests (prefill p50 2.6 s instead of 0.5 s).

Measured after key release, full pipeline, 102 of the user's recordings:

| Dictation length | p50 | p90 |
|---|---|---|
| under 16 s | 0.92 s | 1.72 s |
| 16–40 s | 1.20 s | 2.41 s |
| 40–90 s | 1.55 s | 3.14 s |
| over 90 s | 1.34 s | 2.45 s |

## Quality, blind-judged

A separate judge compared outputs pairwise without knowing which system wrote which.

- Against Typeless on the user's Typeless recordings (40 clips): Typeless 21, Dazi 5,
  tie 14. Typeless still wins mostly on recognition errors the 8B editor cannot repair
  and on residual false starts.
- Against VoiceInk on held-out VoiceInk recordings (40 clips, never used for tuning):
  Dazi 28, VoiceInk 6, tie 6 — including 11–4–5 against VoiceInk's 27B-LLM enhancement.

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

- Long run-on dictations edited in chunks come out as one paragraph instead of a list.
- Accessibility may need an administrator on this managed Mac; without it the app runs
  in copy-to-clipboard mode on ⌃⌥Space.
- TCC permissions are tied to the code signature. The app is ad-hoc signed with the
  default code-hash requirement, so a reinstall needs the two permissions re-enabled
  (an identifier-only requirement would let any app reusing the identifier inherit them).
