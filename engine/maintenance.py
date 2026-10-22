"""Daily housekeeping, run once a day while nobody is talking.

- Deletes recorded audio older than `audio_keep_days` (the text history stays).
- Cleans learned corrections: drops one-off fixes that never came back, and settles
  conflicts (the same word "fixed" to two spellings, or A→B and B→A) in favour of the
  one the user made more often, so rules cannot fight each other.
- Trims oversized logs.
- Writes maintenance.json with counts only (never dictated words) for the panel.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import statistics

REPORT = "maintenance.json"


def due(support: str, today: dt.date) -> bool:
    return last_run(support) != today.isoformat()


def last_run(support: str) -> str | None:
    try:
        with open(os.path.join(support, REPORT), encoding="utf-8") as f:
            return json.load(f).get("date")
    except (OSError, ValueError):
        return None


def run_daily(support: str, cfg: dict, log_dir: str, now: dt.datetime | None = None) -> dict:
    now = now or dt.datetime.now()
    removed, freed = prune_audio(os.path.join(support, "history", "audio"), now, cfg.get("audio_keep_days", 30))
    dropped = prune_learned(os.path.join(support, "learned.json"), now, cfg.get("learned_stale_days", 60))
    report = {
        "date": now.date().isoformat(),
        "ran_at": now.isoformat(timespec="seconds"),
        "audio_removed": removed,
        "freed_mb": round(freed / 1e6, 1),
        "learned_removed": dropped,
        "logs_trimmed": trim_logs(log_dir),
        "yesterday": day_stats(os.path.join(support, "history"), now.date() - dt.timedelta(days=1)),
    }
    tmp = os.path.join(support, REPORT + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=1)
    os.replace(tmp, os.path.join(support, REPORT))
    return report


def prune_audio(audio_dir: str, now: dt.datetime, keep_days: int) -> tuple[int, int]:
    if keep_days <= 0 or not os.path.isdir(audio_dir):
        return 0, 0
    cutoff = (now - dt.timedelta(days=keep_days)).timestamp()
    n = freed = 0
    for name in os.listdir(audio_dir):
        p = os.path.join(audio_dir, name)
        try:
            st = os.stat(p)
            if name.endswith(".wav") and st.st_mtime < cutoff:
                os.remove(p)
                n, freed = n + 1, freed + st.st_size
        except OSError:
            pass
    return n, freed


def prune_learned(path: str, now: dt.datetime, stale_days: int) -> int:
    """Returns how many corrections were dropped."""
    try:
        with open(path, encoding="utf-8") as f:
            items = json.load(f).get("corrections", [])
    except (OSError, ValueError):
        return 0
    cutoff = (now - dt.timedelta(days=stale_days)).isoformat(timespec="seconds")
    # Strongest first: most often, then most recent.
    ranked = sorted(items, key=lambda c: (c.get("count", 1), c.get("last", "")), reverse=True)
    kept, sources = [], set()
    for c in ranked:
        src, dst = c.get("from", ""), c.get("to", "")
        if c.get("count", 1) <= 1 and c.get("last", "") < cutoff:
            continue                                  # a one-off that never came back
        if src in sources or (dst, src) in {(k["from"], k["to"]) for k in kept}:
            continue                                  # loses to a stronger conflicting fix
        kept.append(c)
        sources.add(src)
    if len(kept) == len(items):
        return 0
    order = {id(c): i for i, c in enumerate(items)}
    kept.sort(key=lambda c: order[id(c)])
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"corrections": kept}, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)
    return len(items) - len(kept)


def trim_logs(log_dir: str, max_bytes: int = 5_000_000, keep_bytes: int = 1_000_000) -> int:
    """Keeps the tail of any log over max_bytes. Writers append (O_APPEND), so
    rewriting in place is safe while they run."""
    n = 0
    if not os.path.isdir(log_dir):
        return 0
    for name in os.listdir(log_dir):
        p = os.path.join(log_dir, name)
        try:
            if not name.endswith(".log") or os.path.getsize(p) <= max_bytes:
                continue
            with open(p, "rb") as f:
                f.seek(-keep_bytes, os.SEEK_END)
                tail = f.read()
            tail = tail[tail.find(b"\n") + 1:]
            with open(p, "r+b") as f:
                f.write(tail)
                f.truncate()
            n += 1
        except OSError:
            pass
    return n


def day_stats(history_dir: str, day: dt.date) -> dict:
    count = failed = slow = 0
    waits = []
    try:
        with open(os.path.join(history_dir, f"{day.isoformat()}.jsonl"), encoding="utf-8") as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if r.get("app") == "selftest":
                    continue
                count += 1
                if r.get("failed"):
                    failed += 1
                w = (r.get("timings") or {}).get("after_release")
                if isinstance(w, (int, float)):
                    waits.append(w)
                    slow += w > 3
    except OSError:
        pass
    return {"count": count, "failed": failed, "slow": slow,
            "median_wait": round(statistics.median(waits), 2) if waits else None}
