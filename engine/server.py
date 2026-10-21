"""Dazi engine: local speech-to-text + post-editing over a Unix socket.

Protocol (newline-delimited JSON):
  client -> {"type":"hello"}
  client -> {"type":"begin","id":..,"app":bundle_id,"app_name":..}
  client -> {"type":"audio","id":..,"pcm16":base64 int16 LE mono 16 kHz}
  client -> {"type":"end","id":..} | {"type":"cancel","id":..}
  engine -> {"type":"status","ready":bool,"text":..}
  engine -> {"type":"result","id":..,"text":..,"raw":..,"timings":{..}}
  engine -> {"type":"error","id":..,"text":..}
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import concurrent.futures as cf
import datetime as dt
import json
import logging
import os
import sys
import time
import wave

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from config import load_config  # noqa: E402
from lexicon import Lexicon  # noqa: E402
from pipeline import Pipeline  # noqa: E402
from segmenter import Segmenter  # noqa: E402

log = logging.getLogger("dazi")


class Session:
    def __init__(self, sid: str, app: str, app_name: str, seg_cfg: dict):
        self.id = sid
        self.app = app
        self.app_name = app_name
        self.chunks: list[np.ndarray] = []
        self.n = 0
        self.segmenter = Segmenter(**seg_cfg)
        self.segments: list[tuple[int, int, cf.Future]] = []
        self.started = time.time()
        self.cancelled = False

    def audio(self) -> np.ndarray:
        return np.concatenate(self.chunks) if self.chunks else np.zeros(0, dtype=np.float32)


class Server:
    def __init__(self, socket_path: str, support: str):
        self.socket_path = socket_path
        self.support = support
        self.cfg = load_config(support)
        self.gpu = cf.ThreadPoolExecutor(max_workers=1, thread_name_prefix="gpu")
        self.pipeline: Pipeline | None = None
        self.ready = False
        self.status_text = "加载模型中…"
        self.writers: set[asyncio.StreamWriter] = set()
        self.sessions: dict[str, Session] = {}
        self.loop: asyncio.AbstractEventLoop | None = None

    # ---------- lifecycle ----------

    async def run(self) -> None:
        self.loop = asyncio.get_running_loop()
        if os.path.exists(self.socket_path):
            os.unlink(self.socket_path)
        server = await asyncio.start_unix_server(self.handle_client, path=self.socket_path, limit=16 * 1024 * 1024)
        os.chmod(self.socket_path, 0o600)
        log.info("listening on %s", self.socket_path)
        self.loop.run_in_executor(self.gpu, self._load)
        async with server:
            await server.serve_forever()

    def _load(self) -> None:
        t = time.time()
        try:
            lex = Lexicon.load(os.path.join(self.support, "lexicon.json"), self.cfg["hotwords_max"])
            self.pipeline = Pipeline(self.cfg, lex, status=lambda s: self._set_status(False, s))
            self.pipeline.warmup()
            self._set_status(True, "就绪")
            log.info("models ready in %.1fs (asr=%s llm=%s terms=%d)", time.time() - t,
                     self.cfg["asr_model"], self.cfg["llm_model"], len(lex.terms))
        except Exception as e:  # keep the socket up so the app can show the error
            log.exception("model load failed")
            self._set_status(False, f"模型加载失败：{e}")

    def _set_status(self, ready: bool, text: str) -> None:
        self.ready, self.status_text = ready, text
        if self.loop:
            self.loop.call_soon_threadsafe(self._broadcast, {"type": "status", "ready": ready, "text": text})

    def _broadcast(self, msg: dict) -> None:
        for w in list(self.writers):
            self._send(w, msg)

    @staticmethod
    def _send(w: asyncio.StreamWriter, msg: dict) -> None:
        try:
            w.write((json.dumps(msg, ensure_ascii=False) + "\n").encode())
        except Exception:
            pass

    # ---------- client handling ----------

    async def handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self.writers.add(writer)
        self._send(writer, {"type": "status", "ready": self.ready, "text": self.status_text})
        try:
            while line := await reader.readline():
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                self.dispatch(msg, writer)
        except (ConnectionResetError, asyncio.IncompleteReadError):
            pass
        finally:
            self.writers.discard(writer)
            writer.close()

    def dispatch(self, msg: dict, writer: asyncio.StreamWriter) -> None:
        kind, sid = msg.get("type"), msg.get("id")
        if kind == "hello":
            self._send(writer, {"type": "status", "ready": self.ready, "text": self.status_text})
        elif kind == "begin" and sid:
            self.sessions[sid] = Session(sid, msg.get("app", ""), msg.get("app_name", ""), self.cfg["segment"])
        elif kind == "audio" and sid in self.sessions:
            s = self.sessions[sid]
            pcm = np.frombuffer(base64.b64decode(msg["pcm16"]), dtype="<i2").astype(np.float32) / 32768.0
            s.chunks.append(pcm)
            s.n += len(pcm)
            cut = s.segmenter.feed(pcm) if self.cfg["incremental"] else None
            if cut is not None and self.pipeline:
                start = s.segments[-1][1] if s.segments else 0
                audio = s.audio()[start:cut]
                fut = self.gpu.submit(self.pipeline.recognize, audio)
                s.segments.append((start, cut, fut))
        elif kind == "cancel" and sid in self.sessions:
            self.sessions.pop(sid).cancelled = True
        elif kind == "end" and sid in self.sessions:
            s = self.sessions.pop(sid)
            asyncio.ensure_future(self.finish(s, writer))

    async def finish(self, s: Session, writer: asyncio.StreamWriter) -> None:
        t_end = time.time()
        if not self.pipeline or not self.ready:
            self._send(writer, {"type": "error", "id": s.id, "text": self.status_text})
            return
        try:
            result = await self.loop.run_in_executor(self.gpu, self._finalize, s)
        except Exception as e:
            log.exception("finalize failed")
            self._send(writer, {"type": "error", "id": s.id, "text": f"出错了：{e}"})
            return
        result["timings"]["after_release"] = round(time.time() - t_end, 3)
        self._send(writer, {"type": "result", "id": s.id, **result})
        log.info("result %.1fs audio, %.2fs after release, %s", s.n / 16000,
                 result["timings"]["after_release"], json.dumps(result["timings"]))
        try:
            self.save_history(s, result)
        except Exception:
            log.exception("history save failed")

    def _finalize(self, s: Session) -> dict:
        try:
            self.pipeline.maybe_reload_lexicon(os.path.join(self.support, "lexicon.json"), self.cfg["hotwords_max"])
        except Exception:
            log.exception("lexicon reload failed; keeping the previous one")
        return self.pipeline.finalize(s)

    def save_history(self, s: Session, result: dict) -> None:
        if not self.cfg["keep_history"]:
            return
        day = dt.datetime.now().strftime("%Y-%m-%d")
        hdir = os.path.join(self.support, "history")
        adir = os.path.join(hdir, "audio")
        os.makedirs(adir, exist_ok=True)
        wav_path = os.path.join(adir, f"{s.id}.wav")
        pcm = (np.clip(s.audio(), -1, 1) * 32767).astype("<i2")
        with wave.open(wav_path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16000)
            w.writeframes(pcm.tobytes())
        rec = {"id": s.id, "ts": dt.datetime.now().isoformat(timespec="seconds"), "app": s.app,
               "app_name": s.app_name, "duration": round(s.n / 16000, 2), "raw": result["raw"],
               "text": result["text"], "timings": result["timings"], "audio": wav_path}
        with open(os.path.join(hdir, f"{day}.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", required=True)
    ap.add_argument("--support", required=True)
    a = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", stream=sys.stderr)
    os.makedirs(a.support, exist_ok=True)
    asyncio.run(Server(a.socket, a.support).run())


if __name__ == "__main__":
    main()
