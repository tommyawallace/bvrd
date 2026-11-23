'''Load the model from local folders. No network.'''

import glob
from pathlib import Path

import mlx.core as mx

from .chatterbox_turbo import ChatterboxTurboTTS


def load_model(model_path, s3_tokenizer_path):
    model_path = Path(model_path)
    weights = {}
    for path in glob.glob(str(model_path / '*.safetensors')):
        weights.update(mx.load(path))
    model = ChatterboxTurboTTS({})
    weights = model.sanitize(weights)
    model.load_weights(list(weights.items()), strict=True)
    mx.eval(model.parameters())
    model.eval()
    return ChatterboxTurboTTS.post_load_hook(model, model_path, Path(s3_tokenizer_path))
