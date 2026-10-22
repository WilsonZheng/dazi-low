import datetime as dt
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import maintenance  # noqa: E402

NOW = dt.datetime(2026, 10, 22, 12, 0, 0)


class MaintenanceTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()

    def write_learned(self, items):
        with open(os.path.join(self.dir, "learned.json"), "w", encoding="utf-8") as f:
            json.dump({"corrections": items}, f)

    def read_learned(self):
        with open(os.path.join(self.dir, "learned.json"), encoding="utf-8") as f:
            return [(c["from"], c["to"]) for c in json.load(f)["corrections"]]

    def test_prune_learned(self):
        self.write_learned([
            {"from": "old", "to": "Old", "count": 1, "last": "2026-07-01T00:00:00"},   # stale one-off
            {"from": "浩本", "to": "Hoffman", "count": 3, "last": "2026-10-01T00:00:00"},
            {"from": "浩本", "to": "Hopon", "count": 1, "last": "2026-10-20T00:00:00"},  # conflicts, weaker
            {"from": "Hoffman", "to": "浩本", "count": 1, "last": "2026-10-21T00:00:00"},  # flip-flop
            {"from": "残酷", "to": "仓库", "count": 1, "last": "2026-10-20T00:00:00"},
        ])
        dropped = maintenance.prune_learned(os.path.join(self.dir, "learned.json"), NOW, 60)
        self.assertEqual(dropped, 3)
        self.assertEqual(self.read_learned(), [("浩本", "Hoffman"), ("残酷", "仓库")])

    def test_prune_learned_untouched_when_clean(self):
        self.write_learned([{"from": "a", "to": "A", "count": 2, "last": "2026-01-01T00:00:00"}])
        path = os.path.join(self.dir, "learned.json")
        before = os.path.getmtime(path)
        self.assertEqual(maintenance.prune_learned(path, NOW, 60), 0)
        self.assertEqual(os.path.getmtime(path), before)

    def test_prune_audio_keeps_recent(self):
        adir = os.path.join(self.dir, "audio")
        os.makedirs(adir)
        for name, age in (("old.wav", 40), ("new.wav", 2)):
            p = os.path.join(adir, name)
            open(p, "wb").write(b"x" * 10)
            t = (NOW - dt.timedelta(days=age)).timestamp()
            os.utime(p, (t, t))
        self.assertEqual(maintenance.prune_audio(adir, NOW, 30), (1, 10))
        self.assertEqual(os.listdir(adir), ["new.wav"])

    def test_trim_logs_keeps_tail_lines(self):
        p = os.path.join(self.dir, "engine.log")
        with open(p, "w") as f:
            for i in range(2000):
                f.write(f"line {i}\n")
        self.assertEqual(maintenance.trim_logs(self.dir, max_bytes=1000, keep_bytes=100), 1)
        text = open(p).read()
        self.assertTrue(text.startswith("line ") and text.endswith("line 1999\n"))
        self.assertLessEqual(len(text), 100)

    def test_run_daily_report_and_due(self):
        hdir = os.path.join(self.dir, "history")
        os.makedirs(hdir)
        with open(os.path.join(hdir, "2026-10-21.jsonl"), "w") as f:
            for w in (1.0, 2.0, 4.0):
                f.write(json.dumps({"app": "x", "timings": {"after_release": w}}) + "\n")
            f.write(json.dumps({"app": "selftest", "timings": {"after_release": 9}}) + "\n")
            f.write(json.dumps({"app": "x", "failed": True}) + "\n")
        self.assertTrue(maintenance.due(self.dir, NOW.date()))
        r = maintenance.run_daily(self.dir, {}, os.path.join(self.dir, "logs"), NOW)
        self.assertEqual(r["yesterday"], {"count": 4, "failed": 1, "slow": 1, "median_wait": 2.0})
        self.assertFalse(maintenance.due(self.dir, NOW.date()))
        self.assertTrue(maintenance.due(self.dir, NOW.date() + dt.timedelta(days=1)))


if __name__ == "__main__":
    unittest.main()
