"""Cuts a live recording at pauses so finished parts can be transcribed while the
user is still talking. Only the last part is left for after the key is released."""

from __future__ import annotations

import re

import numpy as np

SR = 16_000
FRAME = 480  # 30 ms


class Segmenter:
    def __init__(self, min_segment_s: float = 12.0, max_segment_s: float = 28.0,
                 min_pause_s: float = 0.45):
        self.min_seg = int(min_segment_s * SR)
        self.max_seg = int(max_segment_s * SR)
        self.min_pause_frames = max(1, int(min_pause_s * SR / FRAME))
        self.energies: list[float] = []   # RMS per frame of the whole recording
        self._tail = np.zeros(0, dtype=np.float32)
        self.last_cut = 0                 # sample index of the last cut

    def feed(self, samples: np.ndarray) -> int | None:
        """Adds audio; returns a cut position (sample index) when a segment is ready."""
        buf = np.concatenate([self._tail, samples])
        n = len(buf) // FRAME
        if n:
            frames = buf[: n * FRAME].reshape(n, FRAME)
            self.energies.extend(np.sqrt((frames ** 2).mean(axis=1) + 1e-12).tolist())
        self._tail = buf[n * FRAME:]
        return self._find_cut()

    def levels(self) -> tuple[float, float] | None:
        """(noise floor, speech level): 10th and 90th percentile frame energy so far."""
        if len(self.energies) < 20:
            return None
        noise, speech = np.percentile(self.energies, [10, 90])
        return float(noise), float(speech)

    def _threshold(self) -> float:
        """Silence = clearly above the noise floor but well below speech level.
        Using speech level too keeps a recording with few pauses from treating
        everything as silence."""
        e = np.array(self.energies)
        if len(e) < 20:
            return 0.002
        noise, speech = np.percentile(e, [10, 90])
        return float(max(0.0008, min(noise * 3.0, speech * 0.3)))

    def _find_cut(self) -> int | None:
        end = len(self.energies) * FRAME
        if end - self.last_cut < self.min_seg:
            return None
        thr = self._threshold()
        start_f = (self.last_cut + self.min_seg) // FRAME
        e = self.energies
        # Latest pause long enough, at least min_seg after the previous cut.
        run = 0
        for i in range(len(e) - 1, start_f - 1, -1):
            if e[i] < thr:
                run += 1
                if run >= self.min_pause_frames:
                    # Walk forward to the end of this pause and cut in its middle.
                    j = i
                    while j + 1 < len(e) and e[j + 1] < thr:
                        j += 1
                    if j == len(e) - 1:
                        # Still inside the pause: cut now, a little into it, so the part
                        # before is recognized even if the user releases the key here.
                        cut = (i + self.min_pause_frames // 2) * FRAME
                    else:
                        cut = ((i + j) // 2) * FRAME
                    self.last_cut = cut
                    return cut
            else:
                run = 0
        if end - self.last_cut >= self.max_seg:
            # No pause: cut at the quietest 300 ms in the last 3 s.
            lo = max(start_f, len(e) - 100)
            win = 10
            best, best_i = None, len(e) - 1
            for i in range(lo, len(e) - win):
                s = sum(e[i:i + win])
                if best is None or s < best:
                    best, best_i = s, i + win // 2
            cut = best_i * FRAME
            self.last_cut = cut
            return cut
        return None


_CJK = re.compile(r"[\u3400-\u9fff]")


def has_speech(audio: np.ndarray, levels: tuple[float, float] | None = None, min_s: float = 0.3) -> bool:
    """False only for clear silence (used for the bit after the last cut, where the
    recognizer would otherwise invent words). The threshold sits between the
    recording's noise floor and its speech level: microphone gain varies a lot
    (some recordings peak at RMS 0.01), so a fixed level would drop real speech."""
    n = len(audio) // FRAME
    if n == 0:
        return False
    frames = audio[: n * FRAME].reshape(n, FRAME)
    rms = np.sqrt((frames ** 2).mean(axis=1) + 1e-12)
    if levels is None:
        thr = 0.002
    else:
        noise, speech = levels
        thr = max(0.0008, min(noise * 3.0, speech * 0.35))
    return int((rms > thr).sum()) * FRAME >= min_s * SR


def session_language(first_text: str) -> str | None:
    """Locks later segments to Chinese once Chinese has been heard."""
    return "Chinese" if _CJK.search(first_text) else None


def join_texts(parts: list[str]) -> str:
    """Joins segment texts. Cuts fall on pauses, not sentence ends, so the recognizer's
    closing period on a non-final segment is dropped and left to the post-editor."""
    out = ""
    for i, p in enumerate(parts):
        p = p.strip()
        if i < len(parts) - 1:
            p = p.rstrip("。.")
        if not p:
            continue
        if out and (out[-1].isascii() and out[-1].isalnum() or p[0].isascii() and p[0].isalnum()):
            out += " "
        out += p
    return out
