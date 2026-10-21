import json
import os
import sys
import tempfile
import unittest

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from lexicon import Lexicon  # noqa: E402
from pipeline import accept_polished, novelty  # noqa: E402
from segmenter import SR, Segmenter, join_texts, session_language  # noqa: E402


def tone(seconds: float, amp: float = 0.2) -> np.ndarray:
    t = np.arange(int(seconds * SR)) / SR
    return (amp * np.sin(2 * np.pi * 220 * t)).astype(np.float32)


def silence(seconds: float) -> np.ndarray:
    return np.zeros(int(seconds * SR), dtype=np.float32)


def feed(seg: Segmenter, audio: np.ndarray) -> list[int]:
    cuts = []
    for i in range(0, len(audio), 1600):
        c = seg.feed(audio[i:i + 1600])
        if c is not None:
            cuts.append(c)
    return cuts


class SegmenterTest(unittest.TestCase):
    def test_cuts_in_pause_after_min_length(self):
        audio = np.concatenate([tone(10), silence(0.6), tone(5)])
        cuts = feed(Segmenter(), audio)
        self.assertEqual(len(cuts), 1)
        self.assertTrue(10 * SR < cuts[0] < 10.6 * SR, cuts[0] / SR)

    def test_ignores_pause_before_min_length(self):
        audio = np.concatenate([tone(3), silence(0.6), tone(4)])
        self.assertEqual(feed(Segmenter(), audio), [])

    def test_waits_while_still_in_pause(self):
        seg = Segmenter()
        self.assertEqual(feed(seg, np.concatenate([tone(9), silence(1.0)])), [])

    def test_forces_cut_without_pause(self):
        cuts = feed(Segmenter(max_segment_s=20), tone(26))
        self.assertEqual(len(cuts), 1)
        self.assertTrue(17 * SR <= cuts[0] <= 20.5 * SR, cuts[0] / SR)


class JoinTest(unittest.TestCase):
    def test_drops_period_of_non_final_segments(self):
        self.assertEqual(join_texts(["然后。", "走一下 PR 流程。"]), "然后走一下 PR 流程。")

    def test_spaces_between_latin(self):
        self.assertEqual(join_texts(["we should merge", "this today."]), "we should merge this today.")
        self.assertEqual(join_texts(["开一个", "PR"]), "开一个 PR")

    def test_language_lock(self):
        self.assertEqual(session_language("我先看一下 PR"), "Chinese")
        self.assertIsNone(session_language("Let me check the PR"))


class LexiconTest(unittest.TestCase):
    def load(self, data):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(data, f)
        try:
            return Lexicon.load(f.name)
        finally:
            os.unlink(f.name)

    def test_replacements(self):
        lex = self.load({
            "terms": [{"term": "Datadog"}, "Kafka"],
            "replacements": [
                {"from": ["data dog"], "to": "Datadog", "confidence": "high"},
                {"from": ["卡夫卡"], "to": "Kafka", "confidence": "high"},
                {"from": ["index"], "to": "INDEX", "confidence": "medium"},
            ],
        })
        self.assertEqual(lex.terms, ["Datadog", "Kafka"])
        self.assertEqual(lex.apply("去 data  dog 看一下卡夫卡的 lag"), "去 Datadog 看一下Kafka的 lag")
        self.assertEqual(lex.apply("加一个 index"), "加一个 index", "medium rules are not applied")
        self.assertEqual(lex.apply("metadata dogs"), "metadata dogs", "word boundaries")

    def test_missing_file_is_empty(self):
        lex = Lexicon.load("/nonexistent/lexicon.json")
        self.assertEqual(lex.terms, [])
        self.assertEqual(lex.apply("x"), "x")


class GuardTest(unittest.TestCase):
    raw = "这个一五零九的 PR 你到底改了什么？修复了什么问题？用案例来解释。然后你就 mark ready for review。"

    def test_accepts_faithful_edit(self):
        out = "这个 1509 的 PR 你到底改了什么？修复了什么问题？用案例来解释。然后 mark ready for review。"
        self.assertTrue(accept_polished(self.raw, out))

    def test_rejects_answering(self):
        out = "关于 PR #1509 的修改内容和修复问题，请提供以下信息以便我协助整理：1. 具体修改了哪些代码或功能 2. 修复了哪些 bug"
        self.assertGreater(novelty(self.raw, out), 0.35)
        self.assertFalse(accept_polished(self.raw, out))

    def test_rejects_truncation_and_empty(self):
        self.assertFalse(accept_polished(self.raw, ""))
        self.assertFalse(accept_polished(self.raw, "PR？"))

    def test_vocabulary_fixes_are_not_novel(self):
        raw = "用 clock code 跑一下"
        out = "用 Claude Code 跑一下"
        self.assertGreater(novelty(raw, out), 0)
        self.assertEqual(novelty(raw, out, allowed={"claude", "code"}), 0)


if __name__ == "__main__":
    unittest.main()
