"""Recognize -> fix vocabulary -> post-edit -> fix vocabulary."""

from __future__ import annotations

import logging
import os
import re
import time

import numpy as np

from asr import Recognizer
from guard import check, novelty, tokens
from lexicon import Lexicon
from polish import Polisher
from prompts import build_system_prompt, user_message
from segmenter import has_speech, join_texts, session_language

log = logging.getLogger("dazi")

_CJK = re.compile(r"[㐀-鿿]")
_DOTTED = re.compile(r"\b((?:[A-Z]\.){2,})")
_SPACED = re.compile(r"(?<![A-Za-z])([A-Z](?: [A-Z]){1,5})(?![A-Za-z])")


def collapse_acronyms(text: str) -> str:
    """Chinese mode spells acronyms out ("P.R.", "C I C D"); join them back."""
    text = _DOTTED.sub(lambda m: m.group(1).replace(".", ""), text)
    text = _SPACED.sub(lambda m: m.group(1).replace(" ", ""), text)
    return re.sub(r"\bCICD\b", "CI/CD", text)


class Pipeline:
    def __init__(self, cfg: dict, lexicon: Lexicon, status=lambda s: None):
        self.cfg = cfg
        self.lexicon = lexicon
        status("加载识别模型…")
        self.asr = Recognizer(cfg["asr_model"])
        self.asr.set_hotwords(lexicon.hotwords)
        self.allowed = {t for term in lexicon.terms for t in tokens(term)}
        self.polisher = None
        if cfg["polish"]:
            status("加载整理模型…")
            self.polisher = Polisher(cfg["llm_model"], self._system_prompt(),
                                     extra_prompts={"minimal": self._system_prompt(minimal=True)})

    def _system_prompt(self, minimal: bool = False) -> str:
        return build_system_prompt(self.lexicon.terms, self.lexicon.examples, self.lexicon.misheard, minimal=minimal)

    def reload_lexicon(self, lexicon: Lexicon) -> None:
        self.lexicon = lexicon
        self.allowed = {t for term in lexicon.terms for t in tokens(term)}
        self.asr.set_hotwords(lexicon.hotwords)
        if self.polisher:
            self.polisher.set_system_prompt(self._system_prompt(minimal=True), "minimal")
            self.polisher.set_system_prompt(self._system_prompt())

    def lexicon_changed(self, path: str) -> bool:
        return os.path.exists(path) and os.path.getmtime(path) != self.lexicon.mtime

    def warmup(self) -> None:
        self.asr.warmup()
        if self.polisher:
            self.polisher.polish(user_message("测试"), source="测试")

    # ---------- while recording ----------

    def recognize_segment(self, session, audio: np.ndarray) -> tuple[str, float]:
        """Recognizes one finished segment. Auto language first; if the recording is
        Chinese but this segment came back with no Chinese at all, it was probably
        translated (segments that start with an English word do that), so redo it in
        Chinese mode, which keeps English words in English."""
        if not has_speech(audio):
            return "", 0.0
        text, secs = self.asr.transcribe(audio)
        if session.lang == "Chinese" and text and not _CJK.search(text):
            text, more = self.asr.transcribe(audio, language="Chinese")
            secs += more
        if session.lang is None and text.strip():
            session.lang = session_language(text)
        return text, secs

    def prepolish(self, session, should_stop) -> None:
        """Post-edits the transcript so far while the user keeps talking; the result
        becomes the draft source for the final post-edit (same output, fewer steps)."""
        if not self.polisher:
            return
        done = [f.result()[0] for _, _, f in session.segments if f.done() and not f.exception()]
        if len(done) != len(session.segments):
            return
        so_far = collapse_acronyms(self.lexicon.apply(join_texts(done)))
        if len(so_far) < 30 or so_far == session.prior_source:
            return
        r = self.polisher.polish(user_message(so_far, session.app_name), source=so_far,
                                 prior=session.prior, should_stop=should_stop)
        if r.text:
            session.prior, session.prior_source = r.text, so_far

    # ---------- after release ----------

    def finalize(self, session) -> dict:
        t0 = time.perf_counter()
        audio = session.audio()
        parts, seg_time = [], 0.0
        start = 0
        for s_start, s_end, fut in session.segments:
            try:
                text, secs = fut.result()
            except Exception:
                log.exception("segment failed; recognizing it again")
                text, secs = self.recognize_segment(session, audio[s_start:s_end])
            parts.append(text)
            seg_time += secs
            start = s_end
        tail_audio = audio[start:]
        tail, tail_time = ("", 0.0)
        if has_speech(tail_audio) or not session.segments:
            tail, tail_time = self.asr.transcribe(tail_audio, language=session.lang)
        parts.append(tail)
        raw = join_texts(parts)
        fixed = collapse_acronyms(self.lexicon.apply(raw))
        timings = {"segments": len(session.segments), "asr_bg": round(seg_time, 3), "asr_tail": round(tail_time, 3)}
        text = fixed
        if self.polisher and fixed.strip():
            r = self.polisher.polish(user_message(fixed, session.app_name), source=fixed, prior=session.prior)
            timings.update(polish_prefill=round(r.prefill_s, 3), polish_gen=round(r.gen_s, 3),
                           polish_tokens=r.tokens, polish_steps=r.steps, prior=bool(session.prior))
            why = check(fixed, r.text, self.allowed) if r.complete else "incomplete"
            if why:
                # Never log dictated text; history (if enabled) has it.
                log.warning("post-edit rejected (%s): %d -> %d chars, novelty %.2f; retrying minimal edit",
                            why, len(fixed), len(r.text), novelty(fixed, r.text, self.allowed))
                timings["polish_rejected"] = why
                r = self.polisher.polish(user_message(fixed, session.app_name), source=fixed, prompt="minimal")
                timings["minimal_gen"] = round(r.gen_s, 3)
                why = check(fixed, r.text, self.allowed) if r.complete else "incomplete"
                if why:
                    timings["minimal_rejected"] = why
            if not why:
                text = self.lexicon.apply(r.text)
        timings["total_engine"] = round(time.perf_counter() - t0, 3)
        return {"text": text, "raw": raw, "timings": timings}
