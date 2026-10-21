"""Recognize -> fix vocabulary -> post-edit -> fix vocabulary."""

from __future__ import annotations

import logging
import os
import re
import time

import numpy as np

from asr import Recognizer
from lexicon import Lexicon
from polish import Polisher
from prompts import build_system_prompt, user_message
from segmenter import join_texts

log = logging.getLogger("dazi")


_TOK = re.compile(r"[\u3400-\u9fff]|[a-z0-9]+")

# Share of output tokens that never appear in the transcript. Typeless-style edits
# of the user's own recordings stay under 0.23 (p97); outputs that answer or expand
# the transcript instead of editing it score 0.55 and up.
MAX_NOVELTY = 0.35


def _tokens(text: str) -> list[str]:
    return _TOK.findall(text.lower())


def novelty(raw: str, out: str, allowed: set[str] = frozenset()) -> float:
    seen = set(_tokens(raw)) | allowed
    toks = [t for t in _tokens(out) if not t.isdigit()]
    if not toks:
        return 0.0
    return sum(t not in seen for t in toks) / len(toks)


def accept_polished(raw: str, out: str, allowed: set[str] = frozenset()) -> bool:
    """Rejects post-edits that dropped most of the content or added their own."""
    if not out.strip():
        return False
    r, o = len(raw.strip()), len(out.strip())
    if r >= 40 and o < 0.3 * r:
        return False
    if o > 2.0 * r + 40:
        return False
    if len(_tokens(out)) >= 8 and novelty(raw, out, allowed) > MAX_NOVELTY:
        return False
    return True


class Pipeline:
    def __init__(self, cfg: dict, lexicon: Lexicon, status=lambda s: None):
        self.cfg = cfg
        self.lexicon = lexicon
        status("加载识别模型…")
        self.asr = Recognizer(cfg["asr_model"])
        self.asr.set_hotwords(lexicon.hotwords)
        self.allowed = {t for term in lexicon.terms for t in _tokens(term)}
        self.polisher = None
        if cfg["polish"]:
            status("加载整理模型…")
            self.polisher = Polisher(cfg["llm_model"], self._system_prompt())

    def _system_prompt(self) -> str:
        return build_system_prompt(self.lexicon.terms, self.lexicon.examples)

    def reload_lexicon(self, lexicon: Lexicon) -> None:
        self.lexicon = lexicon
        self.allowed = {t for term in lexicon.terms for t in _tokens(term)}
        self.asr.set_hotwords(lexicon.hotwords)
        if self.polisher:
            self.polisher.set_system_prompt(self._system_prompt())

    def warmup(self) -> None:
        self.asr.warmup()
        if self.polisher:
            self.polisher.polish(user_message("测试"))

    def recognize(self, audio: np.ndarray) -> tuple[str, float]:
        return self.asr.transcribe(audio)

    def maybe_reload_lexicon(self, path: str, max_hotwords: int) -> None:
        if os.path.exists(path) and os.path.getmtime(path) != self.lexicon.mtime:
            self.reload_lexicon(Lexicon.load(path, max_hotwords))
            log.info("lexicon reloaded: %d terms", len(self.lexicon.terms))

    def finalize(self, session) -> dict:
        t0 = time.perf_counter()
        audio = session.audio()
        parts, seg_time = [], 0.0
        start = 0
        for s_start, s_end, fut in session.segments:
            text, secs = fut.result()
            parts.append(text)
            seg_time += secs
            start = s_end
        tail, tail_time = self.asr.transcribe(audio[start:])
        parts.append(tail)
        raw = join_texts(parts)
        fixed = self.lexicon.apply(raw)
        timings = {"segments": len(session.segments), "asr_bg": round(seg_time, 3), "asr_tail": round(tail_time, 3)}
        text = fixed
        if self.polisher and fixed.strip():
            r = self.polisher.polish(user_message(fixed, session.app_name))
            timings.update(polish_prefill=round(r.prefill_s, 3), polish_gen=round(r.gen_s, 3), polish_tokens=r.tokens)
            if accept_polished(fixed, r.text, self.allowed):
                text = self.lexicon.apply(r.text)
            else:
                timings["polish_rejected"] = True
                log.warning("post-edit rejected: %r -> %r", fixed[:200], r.text[:200])
        timings["total_engine"] = round(time.perf_counter() - t0, 3)
        return {"text": text, "raw": raw, "timings": timings}
