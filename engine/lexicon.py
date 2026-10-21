"""Personal vocabulary: hotwords for the recognizer, spellings for the post-editor,
and deterministic replacement rules applied after both."""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, field


@dataclass
class Lexicon:
    terms: list[str] = field(default_factory=list)       # canonical spellings, most valuable first
    hotwords: list[str] = field(default_factory=list)    # subset fed to the recognizer
    replacements: list[tuple[re.Pattern, str]] = field(default_factory=list)
    examples: list[tuple[str, str]] = field(default_factory=list)
    mtime: float = 0.0

    @classmethod
    def load(cls, path: str, max_hotwords: int = 300) -> "Lexicon":
        if not os.path.exists(path):
            return cls()
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        terms = []
        for t in data.get("terms", []):
            term = t["term"] if isinstance(t, dict) else str(t)
            if term and term not in terms:
                terms.append(term)
        hot = data.get("hotwords") or terms[:max_hotwords]
        reps = []
        for r in data.get("replacements", []):
            if isinstance(r, dict) and r.get("confidence", "high") != "high":
                continue
            froms = r["from"] if isinstance(r, dict) else r[0]
            to = r["to"] if isinstance(r, dict) else r[1]
            for src in [froms] if isinstance(froms, str) else froms:
                if src and src != to:
                    reps.append((_pattern(src), to))
        examples = [(e["raw"], e["text"]) for e in data.get("examples", []) if e.get("raw") and e.get("text")]
        return cls(terms=terms, hotwords=hot[:max_hotwords], replacements=reps, examples=examples,
                   mtime=os.path.getmtime(path))

    def apply(self, text: str) -> str:
        for pat, to in self.replacements:
            text = pat.sub(to, text)
        return text


def _pattern(src: str) -> re.Pattern:
    """Latin phrases match on word boundaries, case-insensitively; CJK matches literally."""
    if re.search(r"[A-Za-z0-9]", src):
        body = r"\s*".join(re.escape(w) for w in src.split())
        return re.compile(r"(?<![A-Za-z0-9])" + body + r"(?![A-Za-z0-9])", re.I)
    return re.compile(re.escape(src))
