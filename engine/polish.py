"""LLM post-editing: turns a raw transcript into the text the user meant to type.

Two latency tricks:
- The system prompt (rules + vocabulary + examples) is the same for every request,
  so its cache is computed once at load time; each request only prefills the transcript.
- Prompt-lookup decoding: the edited text mostly copies the transcript, so each step
  guesses the next tokens by finding the latest generated n-gram in the transcript and
  verifies the whole guess in one forward pass. Greedy, so the output is the same as
  plain decoding; only the number of forward passes changes.
"""

from __future__ import annotations

import re
import time
from dataclasses import dataclass
from typing import Callable

import mlx.core as mx
from mlx_lm import load
from mlx_lm.models.cache import ArraysCache, make_prompt_cache

_SPLIT = "⁣SPLIT⁣"


@dataclass
class PolishResult:
    text: str
    prefill_s: float
    gen_s: float
    tokens: int
    steps: int = 0
    complete: bool = True  # False if stopped early or hit the length cap


class Polisher:
    def __init__(self, model_path: str, system_prompt: str, max_tokens: int = 2048,
                 draft_len: int = 4, prior_draft_len: int = 12, lookup: bool = True):
        self.model, self.tok = load(model_path)
        self.max_tokens = max_tokens
        self.draft_len = draft_len
        self.prior_draft_len = prior_draft_len
        self.lookup = lookup
        self.eos = set(getattr(self.tok, "eos_token_ids", None) or [self.tok.eos_token_id])
        self.set_system_prompt(system_prompt)

    # ---------- prompt / cache ----------

    def _render(self, system: str, user: str) -> str:
        msgs = [{"role": "system", "content": system}, {"role": "user", "content": user}]
        try:
            return self.tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True, enable_thinking=False)
        except TypeError:
            return self.tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True)

    def set_system_prompt(self, system_prompt: str) -> None:
        rendered = self._render(system_prompt, _SPLIT)
        prefix, self._suffix_tpl = rendered.split(_SPLIT)
        self._prefix_ids = self.tok.encode(prefix, add_special_tokens=False)
        cache = make_prompt_cache(self.model)
        self.hybrid = any(isinstance(c, ArraysCache) for c in cache)
        ids = mx.array(self._prefix_ids)
        for i in range(0, len(self._prefix_ids), 1024):
            self.model(ids[i : i + 1024][None], cache=cache)
            mx.eval([c.state for c in cache])
        self._prefix_cache = cache

    def _fresh_cache(self):
        fresh = make_prompt_cache(self.model)
        for new, old in zip(fresh, self._prefix_cache):
            _copy_into(new, old)
        return fresh

    # ---------- generation ----------

    def polish(self, user_message: str, source: str | None = None, prior: str | None = None,
               should_stop: Callable[[], bool] | None = None) -> PolishResult:
        """`source` is the transcript the output mostly copies; `prior` is an earlier
        post-edit of a prefix of it (made while the user was still talking), which is
        the best draft for the opening of the output. `should_stop` aborts early."""
        ids = self.tok.encode(user_message + self._suffix_tpl, add_special_tokens=False)
        src = self.tok.encode(source if source is not None else user_message, add_special_tokens=False)
        sources = [(src, self.draft_len)]
        if prior:
            sources.insert(0, (self.tok.encode(prior, add_special_tokens=False), self.prior_draft_len))
        # Edits never grow much: logged outputs stay under 1.18x the transcript tokens.
        limit = min(self.max_tokens, int(1.3 * len(src)) + 32)
        cache = self._fresh_cache()
        t0 = time.perf_counter()
        logits = self.model(mx.array(ids)[None], cache=cache)
        y = int(mx.argmax(logits[0, -1]).item())
        t1 = time.perf_counter()
        out: list[int] = []
        steps = 0
        complete = True
        while y not in self.eos:
            if len(out) >= limit or (should_stop and should_stop()):
                complete = False
                break
            out.append(y)
            draft = self._propose(out, sources) if self.lookup else []
            draft = draft[: max(0, limit - len(out))]
            snap = _snapshot(cache) if draft else None
            logits = self.model(mx.array([y] + draft)[None], cache=cache)
            preds = mx.argmax(logits[0], axis=-1).tolist()
            steps += 1
            n = 0
            while n < len(draft) and draft[n] == preds[n] and draft[n] not in self.eos:
                n += 1
            if n < len(draft):
                _rollback(cache, snap, len(draft) - n)
                if snap["arrays"]:  # recurrent layers cannot be trimmed: replay accepted tokens
                    self.model(mx.array([y] + draft[:n])[None], cache=cache)
            out.extend(draft[:n])
            y = preds[n]
        text = self.tok.decode(out)
        text = re.sub(r"^\s*<think>.*?</think>\s*", "", text, flags=re.S).strip()
        return PolishResult(text=text, prefill_s=t1 - t0, gen_s=time.perf_counter() - t1,
                            tokens=len(out), steps=steps, complete=complete)

    def _propose(self, out: list[int], sources: list[tuple[list[int], int]]) -> list[int]:
        """Continuation of the latest output n-gram inside a draft source."""
        min_n = 2 if self.hybrid else 1  # a rejected guess costs a replay on hybrid models
        for src, length in sources:
            for n in (4, 3, 2, 1):
                if n < min_n or len(out) < n:
                    continue
                key = out[-n:]
                # Prefer the latest occurrence so repeated phrases track the current position.
                for i in range(len(src) - n, -1, -1):
                    if src[i : i + n] == key:
                        draft = src[i + n : i + n + length]
                        if draft:
                            return draft
                        break
        return []


def _copy_into(new, old) -> None:
    """Gives `new` the state of `old` without sharing anything that gets mutated."""
    if isinstance(old, ArraysCache):
        new.cache = list(old.cache)
        new.left_padding, new.lengths = old.left_padding, old.lengths
    elif hasattr(old, "offset") and getattr(old, "keys", None) is not None:
        off = old.offset
        # Sliced to the offset, so the first update reallocates instead of writing in place.
        new.keys, new.values, new.offset = old.keys[..., :off, :], old.values[..., :off, :], off
    else:
        new.state = old.state


def _snapshot(cache) -> dict:
    return {"arrays": [(c, list(c.cache)) for c in cache if isinstance(c, ArraysCache)],
            "offsets": [(c, c.offset) for c in cache if not isinstance(c, ArraysCache)]}


def _rollback(cache, snap: dict, rejected: int) -> None:
    if snap["arrays"]:
        # Undo the whole verification step; the caller replays the accepted part.
        for c, saved in snap["arrays"]:
            c.cache = list(saved)
        for c, off in snap["offsets"]:
            c.trim(c.offset - off)
    else:
        for c, _ in snap["offsets"]:
            c.trim(rejected)
