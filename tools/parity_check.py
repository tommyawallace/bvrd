'''Check engine/ still matches mlx-audio.

    .venv-mlx/bin/python tools/parity_check.py
'''

import os
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
os.environ.setdefault('HF_HOME', str(ROOT / 'hf-cache'))
os.environ.setdefault('HF_HUB_OFFLINE', '1')

SNAPSHOTS = ROOT / 'hf-cache' / 'hub'
MODEL = next((SNAPSHOTS / 'models--mlx-community--chatterbox-turbo-fp16' / 'snapshots').iterdir())
S3TOK = next((SNAPSHOTS / 'models--mlx-community--S3TokenizerV2' / 'snapshots').iterdir())
VOICES = sorted((ROOT / 'voices').glob('*.wav'))[:4]

TEXTS = [
    'Hello there.',
    "Truly, it's the best of times; it's the worst of times!",
    'Dr. Smith paid $1,234.56 on Jan. 3rd \u2014 really? [laugh] Yes.',
    "Ünïcödé “quotes” and 'apostrophes' … ellipses \u2013 dashes [sigh] [clear throat] okay.",
    '   leading spaces and\nnewlines\tand tabs   ',
    'Numbers 1 22 333 4444 and URLs like https://example.com/a?b=c.',
    '日本語 and emoji 🙂 mixed in.',
]

failures = []


def check(name, ok, detail=''):
    print(f'{'PASS' if ok else 'FAIL'}  {name} {detail}')
    if not ok:
        failures.append(name)


def compare_tokenizer():
    from transformers import AutoTokenizer

    from engine.tokenizer import TextTokenizer

    ref = AutoTokenizer.from_pretrained(str(MODEL))
    new = TextTokenizer(MODEL)
    for text in TEXTS:
        a = ref(text, return_tensors='np', padding=True, truncation=True).input_ids[0].tolist()
        b = new.encode(text)
        check(f'tokenizer {text[:30]!r}', a == b, '' if a == b else f'\n  ref={a}\n  new={b}')


def compare_audio_functions():
    import librosa

    from engine import audio

    for sr, n_fft, n_mels, fmax in [(16000, 400, 40, 8000), (24000, 1920, 80, 8000), (16000, 400, 128, None)]:
        a = librosa.filters.mel(sr=sr, n_fft=n_fft, n_mels=n_mels, fmin=0, fmax=fmax)
        b = audio.mel_filters(sr=sr, n_fft=n_fft, n_mels=n_mels, fmin=0, fmax=fmax)
        check(f'mel filters sr={sr} n_mels={n_mels}', a.dtype == b.dtype and np.allclose(a, b, atol=1e-7, rtol=0),
              f'max diff {np.abs(a - b).max():.2e}')

    for path in VOICES:
        y24, _ = librosa.load(str(path), sr=24000)
        z24, _ = audio.load(str(path), sr=24000)
        check(f'load {path.name}', y24.dtype == z24.dtype and np.array_equal(y24, z24))

        y16 = librosa.resample(y24, orig_sr=24000, target_sr=16000)
        z16 = audio.resample(z24, 24000, 16000)
        check(f'resample {path.name}', y16.dtype == z16.dtype and np.array_equal(y16, z16))

        a = librosa.stft(y16, n_fft=400, hop_length=160, win_length=400, center=True, pad_mode='reflect')
        b = audio.stft(y16, n_fft=400, hop_length=160, win_length=400, center=True, pad_mode='reflect')
        check(f'stft {path.name}', a.shape == b.shape and np.allclose(a, b, atol=1e-4),
              f'max diff {np.abs(a - b).max():.2e}')

        ta = librosa.effects.trim(y16, top_db=20)[0]
        tb = audio.trim(y16, top_db=20)
        check(f'trim {path.name}', np.array_equal(ta, tb), f'{len(ta)} vs {len(tb)} samples')

    from scipy.signal import get_window

    a = get_window('hann', 16, fftbins=True)
    check('hann window', np.allclose(a, audio.hann_window(16), atol=1e-12))


def compare_models():
    import mlx.core as mx
    from mlx_audio.tts.utils import load_model as ref_load

    from engine import load_model

    ref = ref_load(str(MODEL))
    new = load_model(MODEL, S3TOK)

    def flat(conds):
        out = {'t3.speaker_emb': conds.t3.speaker_emb, 't3.tokens': conds.t3.cond_prompt_speech_tokens}
        out.update({f'gen.{k}': v for k, v in conds.gen.items()})
        return out

    for name, (a, b) in {'builtin': (ref._conds, new._conds)}.items():
        fa, fb = flat(a), flat(b)
        same = fa.keys() == fb.keys() and all(np.array_equal(np.array(fa[k]), np.array(fb[k])) for k in fa)
        check(f'conds {name}', same)

    for path in VOICES:
        ref.prepare_conditionals(str(path))
        new.prepare_conditionals(str(path))
        fa, fb = flat(ref._conds), flat(new._conds)
        for key in fa:
            x, y = np.array(fa[key]), np.array(fb[key])
            if np.issubdtype(x.dtype, np.integer):
                agree = float(np.mean(x == y)) if x.shape == y.shape else 0.0
                check(f'conds {path.stem} {key}', agree == 1.0, f'{agree:.1%} equal')
            else:
                diff = float(np.abs(x - y).max()) if x.shape == y.shape else float('inf')
                check(f'conds {path.stem} {key}', diff < 1e-3, f'max diff {diff:.2e}')

    voice = VOICES[0]
    ref.prepare_conditionals(str(voice))
    new.prepare_conditionals(str(voice))
    for text in TEXTS[:3]:
        mx.random.seed(1234)
        a = np.concatenate([np.array(r.audio) for r in ref.generate(text=text, split_pattern=None, max_tokens=200)])
        mx.random.seed(1234)
        b = np.concatenate([np.array(r.audio) for r in new.generate(text=text, split_pattern=None, max_tokens=200)])
        diff = float(np.abs(a - b).max()) if a.shape == b.shape else float('inf')
        check(f'audio {text[:30]!r}', diff < 1e-3, f'{len(a)} vs {len(b)} samples, max diff {diff:.2e}')


if __name__ == '__main__':
    compare_tokenizer()
    compare_audio_functions()
    compare_models()
    print(f'\n{len(failures)} failure(s)' if failures else '\nAll checks passed.')
    sys.exit(1 if failures else 0)
