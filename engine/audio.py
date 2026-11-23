'''Stand-ins for the librosa and scipy calls the engine makes.'''

import numpy as np
import soundfile as sf
import soxr


def resample(y, orig_sr, target_sr):
    '''librosa.resample with its default "soxr_hq" mode.'''
    if orig_sr == target_sr:
        return y
    n_samples = int(np.ceil(y.shape[-1] * float(target_sr) / orig_sr))
    y_hat = soxr.resample(y, orig_sr, target_sr, quality='soxr_hq')
    if len(y_hat) > n_samples:
        y_hat = y_hat[:n_samples]
    elif len(y_hat) < n_samples:
        y_hat = np.pad(y_hat, (0, n_samples - len(y_hat)))
    return np.asarray(y_hat, dtype=y.dtype)


def load(path, sr):
    '''librosa.load(path, sr=sr): mono float32 at the requested sample rate.'''
    y, native_sr = sf.read(path, dtype='float32', always_2d=True)
    y = y.mean(axis=1) if y.shape[1] > 1 else y[:, 0]
    return resample(np.ascontiguousarray(y), native_sr, sr), sr


def hann_window(n):
    '''scipy.signal.get_window("hann", n, fftbins=True): the periodic Hann window.'''
    return 0.5 - 0.5 * np.cos(2.0 * np.pi * np.arange(n) / n)


def _hz_to_mel(freqs):
    freqs = np.asanyarray(freqs, dtype=np.float64)
    f_sp = 200.0 / 3
    mels = freqs / f_sp
    min_log_hz = 1000.0
    min_log_mel = min_log_hz / f_sp
    logstep = np.log(6.4) / 27.0
    return np.where(freqs >= min_log_hz, min_log_mel + np.log(np.maximum(freqs, 1e-10) / min_log_hz) / logstep, mels)


def _mel_to_hz(mels):
    mels = np.asanyarray(mels, dtype=np.float64)
    f_sp = 200.0 / 3
    freqs = f_sp * mels
    min_log_hz = 1000.0
    min_log_mel = min_log_hz / f_sp
    logstep = np.log(6.4) / 27.0
    return np.where(mels >= min_log_mel, min_log_hz * np.exp(logstep * (mels - min_log_mel)), freqs)


def mel_filters(sr, n_fft, n_mels, fmin=0.0, fmax=None):
    '''librosa.filters.mel with its defaults (Slaney mel scale and area normalization).'''
    fmax = sr / 2 if fmax is None else fmax
    fftfreqs = np.fft.rfftfreq(n=n_fft, d=1.0 / sr)
    mel_f = _mel_to_hz(np.linspace(_hz_to_mel(fmin), _hz_to_mel(fmax), n_mels + 2))
    fdiff = np.diff(mel_f)
    ramps = np.subtract.outer(mel_f, fftfreqs)
    weights = np.zeros((n_mels, 1 + n_fft // 2), dtype=np.float32)
    for i in range(n_mels):
        lower = -ramps[i] / fdiff[i]
        upper = ramps[i + 2] / fdiff[i + 1]
        weights[i] = np.maximum(0, np.minimum(lower, upper))
    enorm = 2.0 / (mel_f[2 : n_mels + 2] - mel_f[:n_mels])
    weights *= enorm[:, np.newaxis]
    return weights


def stft(y, n_fft, hop_length, win_length, center=True, pad_mode='reflect'):
    '''librosa.stft with a Hann window: complex64 array of shape (1 + n_fft // 2, frames).'''
    window = hann_window(win_length)
    if win_length < n_fft:
        left = (n_fft - win_length) // 2
        window = np.pad(window, (left, n_fft - win_length - left))
    if center:
        y = np.pad(y, (n_fft // 2, n_fft // 2), mode=pad_mode)
    frames = np.lib.stride_tricks.sliding_window_view(y, n_fft)[::hop_length]
    windowed = (frames * window.astype(y.dtype)).astype(np.float32)
    return np.fft.rfft(windowed, axis=-1).astype(np.complex64).T


def trim(y, top_db=60, frame_length=2048, hop_length=512):
    '''librosa.effects.trim: drop leading and trailing audio quieter than top_db below the peak.'''
    padded = np.pad(y, (frame_length // 2, frame_length // 2), mode='constant')
    frames = np.lib.stride_tricks.sliding_window_view(padded, frame_length)[::hop_length]
    rms = np.sqrt(np.mean(np.abs(frames) ** 2, axis=-1))
    amin = 1e-10
    power = rms**2
    ref = np.max(rms) ** 2
    db = 10.0 * np.log10(np.maximum(amin, power)) - 10.0 * np.log10(np.maximum(amin, ref))
    nonzero = np.flatnonzero(db > -top_db)
    if nonzero.size == 0:
        return y[0:0]
    start = int(nonzero[0] * hop_length)
    end = min(y.shape[-1], int((nonzero[-1] + 1) * hop_length))
    return y[start:end]
