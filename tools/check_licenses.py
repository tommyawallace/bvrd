"""Check the bundled Python packages and write THIRD_PARTY_NOTICES.md.

    python3 tools/check_licenses.py <site-packages> <python-LICENSE.txt> <output.md>

Fails if a package isn't in APPROVED.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Package -> license. No GPL. LGPL only as its own library.
APPROVED = {
    'cffi': 'MIT-0',
    'einops': 'MIT',
    'mlx': 'MIT',
    'mlx-metal': 'MIT',
    'numpy': 'BSD-3-Clause (bundled parts: 0BSD, MIT, Zlib, CC0-1.0)',
    'pycparser': 'BSD-3-Clause',
    'pyloudnorm': 'MIT',
    'scipy': 'BSD-3-Clause (bundled GCC runtime libraries: GPL-3.0 with the GCC Runtime Library Exception, libquadmath LGPL-2.1)',
    'soundfile': 'BSD-3-Clause (bundled libsndfile and codecs: LGPL-2.1 and BSD)',
    'soxr': 'LGPL-2.1-or-later',
    'tokenizers': 'Apache-2.0',
    'typing-extensions': 'PSF-2.0',
}

# Packages whose wheels don't include their license text.
EXTRA_LICENSE_FILES = {
    'tokenizers': [ROOT / 'tools' / 'licenses' / 'Apache-2.0.txt'],
}

# Extra notice files inside site-packages, per package.
EXTRA_SITE_FILES = {
    'soundfile': ['licensing/license_notes.md', '_soundfile_data/COPYING'],
}


def normalize(name):
    return re.sub(r'[-_.]+', '-', name).lower()


def dist_infos(site):
    for info in sorted(site.glob('*.dist-info')):
        meta = (info / 'METADATA').read_text(errors='replace')
        name = re.search(r'^Name: (.+)$', meta, re.M).group(1).strip()
        version = re.search(r'^Version: (.+)$', meta, re.M).group(1).strip()
        yield normalize(name), version, info


def license_files(info):
    files = sorted(p for p in (info / 'licenses').rglob('*') if p.is_file()) if (info / 'licenses').exists() else []
    if not files:
        files = sorted(p for p in info.iterdir() if p.is_file() and re.match(r'(LICEN[CS]E|COPYING)', p.name, re.I))
    return files


def section(title, paths):
    parts = [f'\n\n---\n\n## {title}\n']
    for path in paths:
        parts.append(f'\n### {path.name}\n\n{path.read_text(errors='replace').strip()}\n')
    return ''.join(parts)


def main():
    site, python_license, output = (Path(a) for a in sys.argv[1:4])
    problems, body = [], []
    for name, version, info in dist_infos(site):
        if name not in APPROVED:
            problems.append(f'{name} {version} is not in the approved license list (tools/check_licenses.py)')
            continue
        files = license_files(info) + EXTRA_LICENSE_FILES.get(name, [])
        files += [site / rel for rel in EXTRA_SITE_FILES.get(name, []) if (site / rel).exists()]
        if not files:
            problems.append(f'{name} {version} ships no license text')
        body.append(section(f'{name} {version} ({APPROVED[name]})', files))

    if problems:
        print('License check failed:\n  ' + '\n  '.join(problems), file=sys.stderr)
        sys.exit(1)

    head = (ROOT / 'THIRD_PARTY_NOTICES.md').read_text().strip()
    engine = section('Chatterbox Turbo engine code (vendored from mlx-audio, MIT; KV cache from mlx-lm, MIT)',
                     [ROOT / 'engine' / 'LICENSE', ROOT / 'engine' / 'LICENSE-mlx-lm'])
    python = section('Python 3.12 (PSF-2.0)', [python_license])
    output.write_text(head + '\n\n# Full license texts' + engine + python + ''.join(body) + '\n')
    print(f'License check passed ({len(body)} packages). Wrote {output}')


if __name__ == '__main__':
    main()
