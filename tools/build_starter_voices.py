#!/usr/bin/env python3
'''Make the starter voices from LibriVox. About 18 seconds each, 24 kHz mono.'''

import json
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

import numpy as np
import soundfile as sf

HERE = Path(__file__).resolve().parent.parent
VOICES = HERE / 'voices'
FFMPEG = '/opt/homebrew/bin/ffmpeg'
SR = 24000
CLIP_SECONDS = 18

STARTERS = [
    # id, display title, LibriVox archive.org identifier, narrator, book
    ('british_male_deep_brisk', 'British Male - Deep & Brisk', 'adventuressherlockholmes_v4_1501_librivox', 'David Clarke', 'The Adventures of Sherlock Holmes'),
    ('british_female_low_calm', 'British Female - Low & Calm', 'adventures_sherlock_holmes_rg_librivox', 'Ruth Golding', 'The Adventures of Sherlock Holmes'),
    ('american_male_steady', 'American Male - Steady', 'adventures_sherlockholmes_1007_librivox', 'Mark F. Smith', 'The Adventures of Sherlock Holmes'),
    ('american_female_expressive', 'American Female - Expressive', 'prideandprejudice_1005_librivox', 'Elizabeth Klett', 'Pride and Prejudice'),
    ('male_deep_slow', 'Male - Deep & Slow', 'treasure_island_ap_librivox', 'Adrian Praetzellis', 'Treasure Island'),
    ('british_female_bright_crisp', 'British Female - Bright & Crisp', 'frankenstein_cs_librivox', 'Cori Samuel', 'Frankenstein'),
    ('american_male_warm_relaxed', 'American Male - Warm & Relaxed', 'alice_underground_pc_librivox', 'Phil Chenevert', "Alice's Adventures Underground"),
    ('british_male_dramatic', 'British Male - Dramatic', 'dracula_version_5_2012_librivox', 'Peter John Keeble', 'Dracula'),
    ('female_soft_even', 'Female - Soft & Even', 'dracula_v4_1903_librivox', 'Corrinne LePage', 'Dracula'),
    ('male_very_deep_quick', 'Male - Very Deep & Quick', 'alice_wonderland_0711_librivox', 'Peter Yearsley', "Alice's Adventures in Wonderland"),
]


def pick_chapter(identifier):
    with urllib.request.urlopen(f'https://archive.org/metadata/{identifier}', timeout=30) as r:
        meta = json.load(r)
    mp3s = sorted(f['name'] for f in meta['files'] if f['name'].endswith('_64kb.mp3'))
    if not mp3s:
        mp3s = sorted(f['name'] for f in meta['files'] if f['name'].endswith('.mp3'))
    return mp3s[min(2, len(mp3s) - 1)]


def best_window(audio):
    '''Steadiest CLIP_SECONDS of speech, skipping the first minute.'''
    frame = SR // 4
    n = len(audio) // frame
    rms = np.array([np.sqrt(np.mean(audio[i * frame:(i + 1) * frame] ** 2)) for i in range(n)])
    speech = rms > (np.median(rms) * 0.35)
    win = CLIP_SECONDS * 4
    start_min = min(60 * 4, max(0, n - win - 1))
    best, best_score = start_min, -1.0
    for s in range(start_min, n - win):
        seg = speech[s:s + win]
        longest_gap = max((len(g) for g in ''.join('1' if x else '0' for x in seg).split('1')), default=0)
        score = seg.mean() - 0.05 * longest_gap
        if score > best_score:
            best, best_score = s, score
    s, e = best, best + win
    while s > 0 and speech[s]:  # back up to a pause so the clip starts cleanly
        s -= 1
    while e < n and speech[e - 1]:
        e += 1
    if (e - s) / 4 > CLIP_SECONDS + 6:
        s, e = best, best + win
    return audio[s * frame:e * frame], best_score


def build(entry, tmp):
    vid, title, identifier, narrator, book = entry
    chapter = pick_chapter(identifier)
    url = f'https://archive.org/download/{identifier}/{urllib.request.quote(chapter)}'
    mp3 = tmp / f'{vid}.mp3'
    urllib.request.urlretrieve(url, mp3)
    wav = tmp / f'{vid}.wav'
    subprocess.run([FFMPEG, '-y', '-loglevel', 'error', '-i', str(mp3), '-ac', '1', '-ar', str(SR),
                    '-af', 'highpass=f=70,loudnorm=I=-20:TP=-2', str(wav)], check=True)
    audio, _ = sf.read(wav, dtype='float32')
    clip, score = best_window(audio)
    fade = int(0.05 * SR)
    clip[:fade] *= np.linspace(0, 1, fade)
    clip[-fade:] *= np.linspace(1, 0, fade)
    sf.write(VOICES / f'{vid}.wav', clip, SR)
    print(f'{vid:13} {len(clip) / SR:5.1f}s  speech-score {score:.2f}  {narrator}, {chapter}')
    return vid, {
        'title': title,
        'description': f'Narrated by {narrator}',
        'source': f'{narrator}, “{book}” (LibriVox, public domain)',
        'url': f'https://archive.org/details/{identifier}',
        'starter': True,
    }


def main():
    VOICES.mkdir(exist_ok=True)
    meta_path = VOICES / 'voices.json'
    meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
    only = set(sys.argv[1:])
    with tempfile.TemporaryDirectory() as t:
        for entry in STARTERS:
            if only and entry[0] not in only:
                continue
            try:
                vid, info = build(entry, Path(t))
                meta[vid] = info
            except Exception as e:
                print(f'{entry[0]:13} FAILED: {e}')
    meta_path.write_text(json.dumps(meta, indent=2, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
