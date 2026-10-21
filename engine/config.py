"""Engine settings; `config.json` in the support directory overrides the defaults."""

from __future__ import annotations

import json
import os

DEFAULTS = {
    "asr_model": "mlx-community/Qwen3-ASR-1.7B-8bit",
    "llm_model": "mlx-community/Qwen3.5-9B-MLX-4bit",
    "polish": True,
    "hotwords_max": 300,
    "incremental": True,
    "prepolish": True,
    "segment": {"min_segment_s": 12.0, "max_segment_s": 28.0, "min_pause_s": 0.45},
    "keep_history": True,
}


def load_config(support: str) -> dict:
    cfg = json.loads(json.dumps(DEFAULTS))
    path = os.path.join(support, "config.json")
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            user = json.load(f)
        for k, v in user.items():
            if isinstance(v, dict) and isinstance(cfg.get(k), dict):
                cfg[k].update(v)
            else:
                cfg[k] = v
    return cfg
