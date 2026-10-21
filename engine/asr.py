"""Speech recognizer: Qwen3-ASR (mlx-audio weights) with a cached context prefix.

The vocabulary goes into the system prompt, which comes before the audio, so its KV
cache is computed once and reused; each request only prefills its own audio tokens.
The audio embeddings are spliced in with one concatenate instead of mlx-audio's
per-position Python loop.
"""

from __future__ import annotations

import re
import time

import mlx.core as mx
import numpy as np
from mlx_audio.stt import load

_LANG_TAG = re.compile(r"^\s*language\s+[\w-]+\s*<asr_text>", re.I)
_SUFFIX = "<|audio_end|><|im_end|>\n<|im_start|>assistant\n"


class Recognizer:
    def __init__(self, model_id: str):
        self.model_id = model_id
        self.model = load(model_id)
        self.tok = self.model._tokenizer
        self.eos = self.model._eos_token_ids()
        self.audio_token = self.model.config.audio_token_id
        self._head_ids = self.tok.encode("<|im_end|>\n<|im_start|>user\n<|audio_start|>", add_special_tokens=False)
        self._suffix_ids = self.tok.encode(_SUFFIX, add_special_tokens=False)
        self.context = ""
        self._prefix_cache = None
        self.set_hotwords([])

    def set_hotwords(self, hotwords: list[str]) -> None:
        self.context = ", ".join(hotwords)
        # Cached part ends right after the hotwords so per-request context can follow.
        prefix = f"<|im_start|>system\n{self.context}\n" if self.context else "<|im_start|>system\n"
        ids = mx.array(self.tok.encode(prefix, add_special_tokens=False))[None]
        cache = self.model.make_cache()
        self.model.model(inputs_embeds=self.model.model.embed_tokens(ids), cache=cache)
        mx.eval([c.state for c in cache])
        self._prefix_cache = cache
        self.prefix_tokens = ids.shape[1]

    def _fresh_cache(self):
        fresh = self.model.make_cache()
        for new, old in zip(fresh, self._prefix_cache):
            new.state = old.state  # trimmed to offset, so the first update copies
        return fresh

    def warmup(self) -> None:
        self.transcribe(np.zeros(16_000, dtype=np.float32))

    def transcribe(self, audio: np.ndarray, language: str | None = None) -> tuple[str, float]:
        """`language` (e.g. "Chinese") skips auto-detection. Chinese mode keeps English
        words in English, so it is the right lock for mixed speech: without it, a
        segment that starts with an English word can come back translated to English."""
        if len(audio) < 1_600:  # under 0.1 s
            return "", 0.0
        t = time.perf_counter()
        feats, mask, n_audio = self.model._preprocess_audio(audio.astype(np.float32))
        audio_emb = self.model.get_audio_features(feats, mask)
        head_emb = self.model.model.embed_tokens(mx.array(self._head_ids))
        suffix_ids = self._suffix_ids + (self.tok.encode(f"language {language}<asr_text>", add_special_tokens=False)
                                         if language else [])
        text_emb = self.model.model.embed_tokens(mx.array(suffix_ids))
        embeds = mx.concatenate([head_emb, audio_emb.astype(text_emb.dtype), text_emb], axis=0)
        m = self.model
        cache = self._fresh_cache()
        hidden = m.model(inputs_embeds=embeds[None], cache=cache)[:, -1:, :]
        logits = m.lm_head(hidden) if m.lm_head is not None else m.model.embed_tokens.as_linear(hidden)
        y = mx.argmax(logits[:, -1, :], axis=-1)
        mx.async_eval(y)
        out: list[int] = []
        for _ in range(64 + n_audio * 2):
            # Queue the next step before reading this token (GPU/Python overlap).
            nxt = mx.argmax(m._forward_with_embeds(m.model.embed_tokens(y[:, None]), cache)[:, -1, :], axis=-1)
            mx.async_eval(nxt)
            tid = int(y.item())
            if tid in self.eos:
                break
            out.append(tid)
            if len(out) % 8 == 0 and _looping(out):
                out = _trim_loop(out)
                break
            y = nxt
        text = self.tok.decode(out)
        return _LANG_TAG.sub("", text).strip(), time.perf_counter() - t


def _looping(out: list[int], min_k: int = 4, max_k: int = 40) -> bool:
    """True when the output ends with the same k tokens three times in a row, the
    classic decoder repetition loop (real speech almost never does that)."""
    for k in range(min_k, min(max_k, len(out) // 3) + 1):
        if out[-k:] == out[-2 * k:-k] == out[-3 * k:-2 * k]:
            return True
    return False


def _trim_loop(out: list[int], min_k: int = 4, max_k: int = 40) -> list[int]:
    for k in range(min_k, min(max_k, len(out) // 3) + 1):
        if out[-k:] == out[-2 * k:-k] == out[-3 * k:-2 * k]:
            end = len(out) - 2 * k
            while end - k >= 0 and out[end - k:end] == out[end:end + k]:
                end -= k
            return out[:end + k]
    return out
