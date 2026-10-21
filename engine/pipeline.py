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


_FILLER = re.compile(r"[呃嗯额]+[，,、]?\s*")
# Stutters on function words only; real reduplication (看看, 试试, 刚刚) is left alone.
_STUTTER = re.compile(r"([我你他她它这那的了去给就是在把有要])\1+")
_REPEAT = re.compile(r"(然后|反正|就是|那个|这个|所以|但是)(?:[，,]?\s*\1)+")


_SENTENCE_END = re.compile(r"[。！？!?]|\.(?=\s)")
_CLAUSE_END = re.compile(r"[，,；;]")
_LIST_ITEM = re.compile(r"^(\d+)\.\s")


def split_complete(text: str, clause_after: int = 80) -> tuple[str, str, bool]:
    """Splits off the last sentence, which may continue in the next segment (cuts fall on
    pauses, and the recognizer closes every segment with a period even mid-sentence).

    Long run-on speech ("…，然后…，然后…") may have no sentence end at all; past
    `clause_after` characters it is split at the last comma instead, and the third value
    says the next chunk continues the same sentence."""
    body = text.rstrip()
    if body and body[-1] in "。！？!?.":
        body = body[:-1]
    ends = [m.end() for m in _SENTENCE_END.finditer(body)]
    if ends:
        return text[: ends[-1]].strip(), text[ends[-1]:].strip(), False
    clauses = [m.end() for m in _CLAUSE_END.finditer(body)]
    if len(body) >= clause_after and clauses and clauses[-1] >= 15:
        return text[: clauses[-1]].strip(), text[clauses[-1]:].strip(), True
    return "", text.strip(), False


def join_chunks(chunks: list[str], continues: list[bool] | None = None) -> str:
    """Joins separately edited chunks as paragraphs; a numbered list that a chunk boundary
    split in two keeps counting (1. 2. | 1. -> 1. 2. 3.). A chunk cut mid-sentence
    (continues[i]) is joined to the next one with a comma instead of a paragraph break."""
    continues = continues or [False] * len(chunks)
    merged: list[str] = []
    glue = False
    for chunk, cont in zip(chunks, continues + [False] * (len(chunks) - len(continues))):
        chunk = chunk.strip()
        if not chunk:
            continue
        if glue and merged:
            merged[-1] = merged[-1].rstrip("。.") + ("，" if not merged[-1].endswith(("，", ",")) else "") + chunk
        else:
            merged.append(chunk)
        glue = cont
    out: list[str] = []
    last_num = 0
    for chunk in merged:
        lines = chunk.split("\n")
        first = _LIST_ITEM.match(lines[0])
        continuing = last_num > 0 and first is not None and first.group(1) == "1"
        if out:
            out.append("" if not continuing else None)
        for line in lines:
            m = _LIST_ITEM.match(line)
            if m and continuing:
                last_num += 1
                line = f"{last_num}. " + line[m.end():]
            elif m:
                last_num = int(m.group(1))
            elif line.strip():
                last_num = 0
                continuing = False
            out.append(line)
        # keep counting only if the chunk ends on a list item
        if not (lines and _LIST_ITEM.match(lines[-1])):
            last_num = 0
    return "\n".join(l for l in out if l is not None)


def clean_fillers(text: str) -> str:
    """Deterministic cleanup for text that skipped the post-editor."""
    text = _FILLER.sub("", text)
    text = _REPEAT.sub(r"\1", text)
    return _STUTTER.sub(r"\1", text)


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
        text, secs = self.asr.transcribe(audio)
        if session.lang == "Chinese" and text and not _CJK.search(text):
            text, more = self.asr.transcribe(audio, language="Chinese")
            secs += more
        if session.lang is None and text.strip():
            session.lang = session_language(text)
        return text, secs

    def edit(self, raw: str, app_name: str, timings: dict | None = None, should_stop=None) -> str | None:
        """Post-edits one piece of transcript, with the guard and the minimal-edit retry.
        Returns None if `should_stop` interrupted it."""
        fixed = collapse_acronyms(self.lexicon.apply(raw))
        if not self.polisher or not fixed.strip():
            return fixed
        t = timings if timings is not None else {}
        r = self.polisher.polish(user_message(fixed, app_name), source=fixed, should_stop=should_stop)
        if r.stopped:
            return None
        t["polish_prefill"] = round(t.get("polish_prefill", 0) + r.prefill_s, 3)
        t["polish_gen"] = round(t.get("polish_gen", 0) + r.gen_s, 3)
        t["polish_tokens"] = t.get("polish_tokens", 0) + r.tokens
        why = check(fixed, r.text, self.allowed) if r.complete else "incomplete"
        if why:
            # Never log dictated text; history (if enabled) has it.
            log.warning("post-edit rejected (%s): %d -> %d chars, novelty %.2f; retrying minimal edit",
                        why, len(fixed), len(r.text), novelty(fixed, r.text, self.allowed))
            t["polish_rejected"] = t.get("polish_rejected", 0) + 1
            r = self.polisher.polish(user_message(fixed, app_name), source=fixed, prompt="minimal")
            why = check(fixed, r.text, self.allowed) if r.complete else "incomplete"
            if why:
                t["minimal_rejected"] = t.get("minimal_rejected", 0) + 1
                return clean_fillers(fixed)
            return clean_fillers(self.lexicon.apply(r.text))
        return self.lexicon.apply(r.text)

    def advance_chunks(self, session, should_stop=None) -> None:
        """Edits the finished part of the recording while the user keeps talking: every
        recognized segment except its last (possibly unfinished) sentence. After release
        only the rest is left to edit."""
        while session.chunked < len(session.segments):
            fut = session.segments[session.chunked][2]
            try:
                text = fut.result()[0]
            except Exception:
                return  # finalize re-recognizes failed segments
            session.chunked += 1
            pending_before = session.pending
            pending = join_texts([session.pending, text]) if session.pending else text
            complete, session.pending, cont = split_complete(pending)
            if len(complete) >= 15:
                edited = self.edit(complete, session.app_name, session.chunk_timings, should_stop)
                if edited is None:  # the key was released: finalize takes over from here
                    session.chunked -= 1
                    session.pending = pending_before
                    return
                session.edited.append(edited)
                session.continues.append(cont)
            else:
                session.pending = pending

    # ---------- after release ----------

    def finalize(self, session) -> dict:
        t0 = time.perf_counter()
        audio = session.audio()
        seg_time = 0.0
        start = 0
        for k, (s_start, s_end, fut) in enumerate(session.segments):
            try:
                seg_time += fut.result()[1]
            except Exception:
                log.exception("segment failed; recognizing it again")
                done = _Done(self.recognize_segment(session, audio[s_start:s_end]))
                session.segments[k] = (s_start, s_end, done)
            start = s_end
        tail_audio = audio[start:]
        tail, tail_time = ("", 0.0)
        if not session.segments or has_speech(tail_audio, session.segmenter.levels()):
            tail, tail_time = self.asr.transcribe(tail_audio, language=session.lang)
        raw = join_texts([f.result()[0] for _, _, f in session.segments] + [tail])
        timings = {"segments": len(session.segments), "asr_bg": round(seg_time, 3), "asr_tail": round(tail_time, 3)}

        if self.cfg.get("chunked", True) and session.segments:
            self.advance_chunks(session)  # anything the background did not get to
            rest = join_texts([session.pending, tail]) if session.pending else tail
            last = self.edit(rest, session.app_name, timings) if rest.strip() else ""
            text = join_chunks(session.edited + [last], session.continues + [False])
            timings["chunks"] = len(session.edited) + 1
            for k, v in session.chunk_timings.items():
                timings["bg_" + k] = v
        else:
            text = self.edit(raw, session.app_name, timings)
        timings["total_engine"] = round(time.perf_counter() - t0, 3)
        return {"text": text, "raw": raw, "timings": timings}


class _Done:
    """A finished future holding a value (for segments recognized again in finalize)."""

    def __init__(self, value):
        self.value = value

    def result(self):
        return self.value

    def done(self):
        return True

    def exception(self):
        return None
