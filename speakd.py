#!/usr/bin/env python3
'''Voice server. The app starts it. Listens on 127.0.0.1 only.

    BVRD_MODEL_DIR       chatterbox-turbo/ and s3-tokenizer/
    BVRD_VOICE_DIRS      wav folders, separated by ":". Earlier ones win.
    BVRD_PLAYER          path to BVRDPlayer
    BVRD_PARENT_PID      exit when this process is gone
    SPEAKD_PORT          default 59125
    SPEAKD_IDLE_MINUTES  unload after this long idle (default 30)

    GET  /status
    POST /speak   text, voice, speed, optional save path
    POST /stop
    POST /quit
'''

import json
import os
import queue
import re
import subprocess
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

PORT = int(os.environ.get('SPEAKD_PORT', '59125'))
MODEL_DIR = Path(os.environ.get('BVRD_MODEL_DIR', HERE / 'model'))
VOICE_DIRS = [Path(p) for p in os.environ.get('BVRD_VOICE_DIRS', str(HERE / 'voices')).split(os.pathsep) if p]
PLAYER = os.environ.get('BVRD_PLAYER', 'BVRDPlayer')
PARENT_PID = int(os.environ.get('BVRD_PARENT_PID', '0'))
IDLE_MINUTES = float(os.environ.get('SPEAKD_IDLE_MINUTES', '30'))
FIRST_CHUNK_CHARS = 120
MAX_CHUNK_CHARS = 300
CHUNK_GROWTH = 2.0
FADE_SECONDS = 0.008


ABBREVIATIONS = {
    'mr', 'mrs', 'ms', 'dr', 'prof', 'sr', 'jr', 'st', 'mt', 'vs', 'etc', 'inc', 'ltd', 'co', 'no',
    'fig', 'vol', 'ch', 'approx', 'gen', 'col', 'lt', 'sgt', 'rev', 'capt', 'dept', 'est',
    'jan', 'feb', 'mar', 'apr', 'jun', 'jul', 'aug', 'sep', 'sept', 'oct', 'nov', 'dec',
}


def ends_with_abbreviation(piece):
    """Dr., U.S., J. The period isn't the end of the sentence."""
    if not piece.endswith('.'):
        return False
    last = piece.split()[-1].rstrip('.').lower()
    return last in ABBREVIATIONS or len(last) == 1 or '.' in last


def too_short(piece):
    '''A few words on their own get merged. The model garbles those.'''
    return len(piece.split()) < 4


def pack(parts, limit):
    pieces, current = [], ''
    for part in parts:
        if current and len(current) + 1 + len(part) > limit:
            pieces.append(current)
            current = part
        else:
            current = f'{current} {part}' if current else part
    if current:
        if pieces and too_short(current):
            pieces[-1] += ' ' + current
        else:
            pieces.append(current)
    return pieces


def split_long(sentence, limit):
    '''Split a long sentence on commas or dashes, then on words.'''
    if len(sentence) <= limit:
        return [sentence]
    pieces = []
    for piece in pack(re.split('(?<=[,;:\u2014\u2013])\\s+', sentence), limit):
        pieces += pack(piece.split(), limit) if len(piece) > limit else [piece]
    return pieces


def playback_chunks(text):
    '''Group sentences so playback can start before the whole thing is ready.
    The first chunk is short. Later ones grow so each finishes before the last one ends.
    '''
    merged = []
    for piece in re.split('(?<=[.!?])\\s+|\\s*\\n\\s*(?=[A-Z0-9•*\\-\u2013\u2014\\"“(])|\\n\\s*\\n', text):
        piece = ' '.join(piece.split())
        if not piece:
            continue
        if merged and (ends_with_abbreviation(merged[-1]) or too_short(merged[-1])):
            merged[-1] += (' ' if merged[-1][-1] in '.!?,;:' else '. ') + piece
        else:
            merged.append(piece)
    if len(merged) > 1 and too_short(merged[-1]):
        tail = merged.pop()
        merged[-1] += ' ' + tail

    sentences = []
    for sentence in merged:
        sentences += split_long(sentence, MAX_CHUNK_CHARS)
    if sentences:
        sentences[:1] = split_long(sentences[0], FIRST_CHUNK_CHARS)

    chunks, current, cap = [], '', FIRST_CHUNK_CHARS
    for sentence in sentences:
        if current and (not chunks or len(current) + 1 + len(sentence) > cap):
            chunks.append(current)
            cap = min(MAX_CHUNK_CHARS, len(current) * CHUNK_GROWTH)
            current = sentence
        else:
            current = f'{current} {sentence}' if current else sentence
    if current:
        chunks.append(current)
    return chunks or [text]


def token_budget(chunk):
    '''How long a chunk is allowed to run. Stops the model if it never ends the sentence.'''
    return int(min(800, max(60, len(chunk) * 3.5)))


def fade_edges(audio, sample_rate):
    """Fade the edges so chunks don't click."""
    import numpy as np

    n = min(int(sample_rate * FADE_SECONDS), len(audio) // 2)
    if n:
        ramp = np.linspace(0.0, 1.0, n, dtype=np.float32)
        audio = audio.astype(np.float32).copy()
        audio[:n] *= ramp
        audio[-n:] *= ramp[::-1]
    return audio


def open_player(sample_rate, speed):
    '''Start BVRDPlayer. Audio goes in on stdin.'''
    return subprocess.Popen(
        [PLAYER, str(sample_rate), f'{speed:.3f}'],
        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def voice_files():
    '''Name to wav path. Earlier folders win.'''
    found = {}
    for folder in reversed(VOICE_DIRS):
        for path in folder.glob('*.wav'):
            found[path.stem] = path
    return found


class Job:
    def __init__(self, text, voice, speed=1.0, save=None):
        self.text, self.voice, self.save = text, voice, save
        self.speed = min(2.0, max(0.5, float(speed)))
        self.cancelled = threading.Event()
        self.finished = threading.Event()
        self.error = None


class Engine:
    def __init__(self):
        self.model = None
        self.sample_rate = 24000
        self.ready = threading.Event()
        self.load_error = None
        self.conds = {}
        self.jobs = queue.Queue()
        self.current = None
        self.player_proc = None
        self.lock = threading.Lock()
        self.last_activity = time.time()

    def available_voices(self):
        return ['builtin'] + sorted(voice_files())

    def load(self):
        from engine import load_model

        self.model = load_model(MODEL_DIR / 'chatterbox-turbo', MODEL_DIR / 's3-tokenizer')
        self.sample_rate = self.model.sample_rate
        self.conds['builtin'] = (None, self.model._conds)
        for _ in self.model.generate(text='Hello there.', split_pattern=None):
            pass
        self.ready.set()

    def prepare_idle_voices(self):
        '''Prep each voice so the first play is faster.'''
        for name in self.available_voices():
            if not self.jobs.empty():
                return
            try:
                self.use_voice(name)
            except Exception:
                pass

    def use_voice(self, name):
        if name == 'builtin':
            self.model._conds = self.conds['builtin'][1]
            return
        path = voice_files().get(name)
        if path is None:
            raise ValueError(f"Unknown voice '{name}'.")
        key = (str(path), path.stat().st_mtime)
        cached = self.conds.get(name)
        if cached is None or cached[0] != key:
            self.model.prepare_conditionals(str(path))
            cached = (key, self.model._conds)
            self.conds[name] = cached
        self.model._conds = cached[1]

    def submit(self, job):
        self.stop()
        with self.lock:
            self.current = job
        self.last_activity = time.time()
        self.jobs.put(job)

    def stop(self):
        with self.lock:
            job, proc = self.current, self.player_proc
            self.current = None
        if job:
            job.cancelled.set()
            job.finished.set()
        if proc and proc.poll() is None:
            proc.kill()

    def speaking(self):
        job = self.current
        return job is not None and not job.finished.is_set()

    def generate_loop(self):
        try:
            self.load()
        except Exception as e:
            traceback.print_exc()
            self.load_error = f"Couldn't load the voice model: {e}"
            return
        while True:
            self.prepare_idle_voices()
            try:
                job = self.jobs.get(timeout=30)
            except queue.Empty:
                if not self.speaking() and time.time() - self.last_activity > IDLE_MINUTES * 60:
                    os._exit(0)
                continue
            if job.cancelled.is_set():
                continue
            try:
                self.use_voice(job.voice)
                if job.save:
                    self.render(job)
                else:
                    self.stream(job)
            except Exception as e:
                traceback.print_exc()
                job.error = str(e)
                job.finished.set()
            finally:
                self.last_activity = time.time()

    def generate_chunks(self, job):
        import numpy as np

        for chunk in playback_chunks(job.text):
            if job.cancelled.is_set():
                return
            audio = np.concatenate([np.array(r.audio) for r in self.model.generate(
                text=chunk, split_pattern=None, max_tokens=token_budget(chunk))])
            yield fade_edges(audio, self.sample_rate)

    def render(self, job):
        import numpy as np
        import soundfile as sf

        parts = list(self.generate_chunks(job))
        if parts and not job.cancelled.is_set():
            sf.write(job.save, np.concatenate(parts), self.sample_rate)
        job.finished.set()

    def stream(self, job):
        proc = open_player(self.sample_rate, job.speed)
        with self.lock:
            if job.cancelled.is_set():
                proc.kill()
                return
            self.player_proc = proc
        chunks = queue.Queue()
        threading.Thread(target=self.feed_player, args=(job, proc, chunks), daemon=True).start()
        try:
            for audio in self.generate_chunks(job):
                if not job.cancelled.is_set():
                    chunks.put(audio.tobytes())
        finally:
            chunks.put(None)

    def feed_player(self, job, proc, chunks):
        try:
            while (data := chunks.get()) is not None and not job.cancelled.is_set():
                proc.stdin.write(data)
                proc.stdin.flush()
            proc.stdin.close()
            proc.wait()
        except (BrokenPipeError, OSError, ValueError):
            pass
        finally:
            job.finished.set()
            self.last_activity = time.time()


engine = Engine()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == '/status':
            self.reply(200, {
                'ready': engine.ready.is_set(),
                'speaking': engine.speaking(),
                'error': engine.load_error,
                'voices': engine.available_voices(),
            })
        else:
            self.reply(404, {'error': 'not found'})

    def do_POST(self):
        length = int(self.headers.get('Content-Length') or 0)
        data = json.loads(self.rfile.read(length) or b'{}')
        if self.path == '/stop':
            engine.stop()
            self.reply(200, {'ok': True})
        elif self.path == '/quit':
            engine.stop()
            self.reply(200, {'ok': True})
            threading.Timer(0.2, os._exit, args=(0,)).start()
        elif self.path == '/speak':
            text = (data.get('text') or '').strip()
            if not text:
                return self.reply(400, {'error': 'no text'})
            if engine.load_error:
                return self.reply(503, {'error': engine.load_error})
            voice = data.get('voice') or 'builtin'
            if voice not in engine.available_voices():
                return self.reply(404, {'error': f"Unknown voice '{voice}'."})
            job = Job(text, voice, data.get('speed') or 1.0, data.get('save'))
            engine.submit(job)
            if job.save:
                job.finished.wait()
            if job.error:
                return self.reply(500, {'error': job.error})
            self.reply(200, {'ok': True})
        else:
            self.reply(404, {'error': 'not found'})


def watch_parent():
    '''Quit if the app that started us is gone.'''
    while True:
        time.sleep(2)
        try:
            os.kill(PARENT_PID, 0)
        except ProcessLookupError:
            engine.stop()
            os._exit(0)
        except PermissionError:
            pass


def main():
    server = ThreadingHTTPServer(('127.0.0.1', PORT), Handler)
    threading.Thread(target=engine.generate_loop, daemon=True).start()
    if PARENT_PID:
        threading.Thread(target=watch_parent, daemon=True).start()
    server.serve_forever()


if __name__ == '__main__':
    main()
