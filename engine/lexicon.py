"""Personal vocabulary: hotwords for the recognizer, spellings for the post-editor,
and deterministic replacement rules applied after both."""

from __future__ import annotations

import json
import os
import re
import time
from dataclasses import dataclass, field


@dataclass
class Lexicon:
    terms: list[str] = field(default_factory=list)       # canonical spellings, most valuable first
    hotwords: list[str] = field(default_factory=list)    # subset fed to the recognizer
    replacements: list[tuple[re.Pattern, str]] = field(default_factory=list)
    examples: list[tuple[str, str]] = field(default_factory=list)
    # Known misrecognitions too risky to replace blindly; the post-editor gets them as hints.
    misheard: list[tuple[str, str]] = field(default_factory=list)
    # Learned once from the user's edits: sent with each request rather than baked into
    # the cached system prompt, so learning never forces a slow prompt rebuild.
    learned_hints: list[tuple[str, str]] = field(default_factory=list)
    mtime: float = 0.0
    base_mtime: float = 0.0

    @classmethod
    def load(cls, path: str, max_hotwords: int = 300) -> "Lexicon":
        learned = load_learned(learned_path(path))
        if not os.path.exists(path) and not learned:
            return cls()
        data = {}
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        data = merge_learned(data, learned)
        learned_hints = [tuple(h) for h in data.pop("learned_hints", [])]
        terms = []
        for t in data.get("terms", []):
            term = t["term"] if isinstance(t, dict) else str(t)
            if term and term not in terms:
                terms.append(term)
        hot = data.get("hotwords") or terms[:max_hotwords]
        reps, misheard = [], []
        for r in data.get("replacements", []) + data.get("uncertain_replacements", []):
            froms = r["from"] if isinstance(r, dict) else r[0]
            to = r["to"] if isinstance(r, dict) else r[1]
            froms = [froms] if isinstance(froms, str) else froms
            high = isinstance(r, (list, tuple)) or r.get("confidence", "high") == "high"
            case = isinstance(r, dict) and r.get("match") == "case_sensitive"
            for src in froms:
                if not src or src == to:
                    continue
                if high and r not in data.get("uncertain_replacements", []):
                    reps.append((_pattern(src, case), to))
                else:
                    misheard.append((src, to))
        misheard += [tuple(m) for m in data.get("misheard", [])]
        examples = [(e["raw"], e["text"]) for e in data.get("examples", []) if e.get("raw") and e.get("text")]
        return cls(terms=terms, hotwords=hot[:max_hotwords], replacements=reps, examples=examples,
                   misheard=misheard, learned_hints=learned_hints, mtime=lexicon_mtime(path),
                   base_mtime=os.path.getmtime(path) if os.path.exists(path) else 0.0)

    def apply(self, text: str) -> str:
        for pat, to in self.replacements:
            text = pat.sub(to, text)
        return text


# ---------- corrections learned from the user's own edits ----------

def learned_path(lexicon_path: str) -> str:
    return os.path.join(os.path.dirname(lexicon_path) or ".", "learned.json")


def lexicon_mtime(lexicon_path: str) -> float:
    times = [os.path.getmtime(p) for p in (lexicon_path, learned_path(lexicon_path)) if os.path.exists(p)]
    return max(times) if times else 0.0


def load_learned(path: str) -> list[dict]:
    if not os.path.exists(path):
        return []
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f).get("corrections", [])
    except (OSError, ValueError):
        return []


def record_learned(path: str, pairs: list[tuple[str, str]]) -> list[dict]:
    """Counts each (heard, meant) pair the user fixed by hand."""
    items = load_learned(path)
    index = {(c["from"], c["to"]): c for c in items}
    now = time.strftime("%Y-%m-%dT%H:%M:%S")
    for src, dst in pairs:
        src, dst = src.strip(), dst.strip()
        if not src or not dst or src == dst:
            continue
        c = index.get((src, dst))
        if c:
            c["count"] += 1
            c["last"] = now
        else:
            c = {"from": src, "to": dst, "count": 1, "first": now, "last": now}
            items.append(c)
            index[(src, dst)] = c
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"corrections": items}, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)
    return items


def merge_learned(data: dict, learned: list[dict]) -> dict:
    """Corrections the user made twice become replacement rules; once, a hint for the
    post-editor. The corrected spelling also goes to the front of the vocabulary and
    the recognizer's hotwords."""
    if not learned:
        return data
    data = dict(data)
    rules = list(data.get("replacements", []))
    hints = []
    fronts = []
    for c in sorted(learned, key=lambda c: -c.get("count", 1)):
        if c.get("count", 1) >= 2:
            rules.append({"from": [c["from"]], "to": c["to"], "confidence": "high"})
        hints.append([c["from"], c["to"]])
        if re.search(r"[A-Za-z]", c["to"]) and len(c["to"]) <= 40:
            fronts.append(c["to"])
    data["replacements"], data["learned_hints"] = rules, hints[:40]
    hot = data.get("hotwords") or [t["term"] if isinstance(t, dict) else t for t in data.get("terms", [])]
    data["hotwords"] = list(dict.fromkeys(fronts + list(hot)))
    return data


def _pattern(src: str, case_sensitive: bool = False) -> re.Pattern:
    """Latin phrases match whole words (case-insensitively unless told otherwise) and
    never inside a domain, path or identifier ("github.com", ".github/"); CJK matches
    literally."""
    if re.search(r"[A-Za-z0-9]", src):
        body = r"\s*".join(re.escape(w) for w in src.split())
        pat = r"(?<![A-Za-z0-9./_-])" + body + r"(?![A-Za-z0-9_/-]|\.[A-Za-z0-9])"
        return re.compile(pat, 0 if case_sensitive else re.I)
    return re.compile(re.escape(src))
