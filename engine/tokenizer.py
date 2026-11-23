'''Text tokenizer for this model, including tags like [laugh] and [sigh].'''

import json
from pathlib import Path

from tokenizers import AddedToken, Tokenizer, decoders, models, pre_tokenizers

MAX_LENGTH = 1024


class TextTokenizer:
    def __init__(self, model_path):
        model_path = Path(model_path)
        bpe = models.BPE.from_file(
            str(model_path / 'vocab.json'),
            str(model_path / 'merges.txt'),
            continuing_subword_prefix='',
            end_of_word_suffix='',
            fuse_unk=False,
        )
        tokenizer = Tokenizer(bpe)
        tokenizer.pre_tokenizer = pre_tokenizers.ByteLevel(add_prefix_space=False)
        tokenizer.decoder = decoders.ByteLevel()

        config = json.loads((model_path / 'tokenizer_config.json').read_text())
        for token_id, spec in sorted(config.get('added_tokens_decoder', {}).items(), key=lambda kv: int(kv[0])):
            token = AddedToken(
                spec['content'],
                single_word=spec.get('single_word', False),
                lstrip=spec.get('lstrip', False),
                rstrip=spec.get('rstrip', False),
                normalized=spec.get('normalized', True),
                special=spec.get('special', False),
            )
            if token.special:
                tokenizer.add_special_tokens([token])
            else:
                tokenizer.add_tokens([token])
            if tokenizer.token_to_id(spec['content']) != int(token_id):
                raise ValueError(f'Tokenizer id mismatch for {spec['content']!r}')
        self._tokenizer = tokenizer

    def encode(self, text):
        return self._tokenizer.encode(text, add_special_tokens=False).ids[:MAX_LENGTH]

    def decode(self, ids):
        return self._tokenizer.decode(ids)
