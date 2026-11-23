# Acknowledgements

This app is built on open-source software and openly licensed AI models. Thank you to
everyone who made them. The full license text of each component follows this summary.

## Voice model (downloaded on first launch)

- **Chatterbox Turbo** by Resemble AI. MIT License. https://github.com/resemble-ai/chatterbox
  MLX weights: mlx-community/chatterbox-turbo-fp16 on Hugging Face.
- **S3Tokenizer V2** speech tokenizer from CosyVoice (FunAudioLLM, Alibaba). Apache License 2.0.
  MLX weights: mlx-community/S3TokenizerV2 on Hugging Face.

## Engine code (included in the app)

- **mlx-audio** by Prince Canuma and contributors. MIT License. The Chatterbox Turbo
  implementation was vendored from mlx-audio and modified to remove unneeded dependencies.
- **mlx-lm** by Apple Inc. MIT License (key-value cache).
- **MLX** by Apple Inc. MIT License.
- **NumPy**, BSD 3-Clause License. **SciPy**, BSD 3-Clause License; its bundled GCC runtime
  libraries are GPL-3.0 with the GCC Runtime Library Exception, which permits distribution
  in any application, and libquadmath is LGPL-2.1.
- **pyloudnorm**, MIT License. **einops**, MIT License.
- **Tokenizers** by Hugging Face, Apache License 2.0.
- **python-soundfile**, BSD 3-Clause License, with **libsndfile** and its codecs (LGPL-2.1 and
  BSD; see the notes below).
- **python-soxr** and **libsoxr**, LGPL-2.1-or-later.
- **cffi** (MIT-0), **pycparser** (BSD 3-Clause), **typing_extensions** (PSF-2.0).
- **Python** 3.12 (python-build-standalone), Python Software Foundation License 2.0.

The LGPL-licensed libraries (libsndfile, libsoxr, libquadmath) are included unmodified as
separate shared libraries inside the app (Contents/Resources/python). You may replace them
with your own builds. Their source code is available from the projects:
https://github.com/libsndfile/libsndfile, https://github.com/dofuuz/python-soxr,
https://sourceforge.net/projects/soxr/, and https://gcc.gnu.org.

## Starter voices

Starter voices are short clips from public-domain LibriVox recordings (https://librivox.org).
The narrators are credited in the Voice Manager and in the app's Voices/CREDITS.md.

## Voices you add

You are responsible for the voices you add. Only clone recordings you own or have the
speaker's permission to use.
