"""Fails when requirements.txt and pyproject.toml declare different Python dependencies.

Vercel installs from pyproject.toml; local development and CI install from requirements.txt. Both must match exactly,
otherwise a security update can reach the tests but not the published site (as happened in 0.11.0).
"""
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
requirements = sorted(l.strip() for l in (ROOT / 'requirements.txt').read_text(encoding='utf-8').splitlines() if l.strip() and not l.lstrip().startswith('#'))
project = sorted(tomllib.loads((ROOT / 'pyproject.toml').read_text(encoding='utf-8'))['project']['dependencies'])
if requirements != project:
    print('requirements.txt e pyproject.toml divergem:')
    for item in sorted(set(requirements) ^ set(project)):
        print(('  só em requirements.txt: ' if item in requirements else '  só em pyproject.toml:   ') + item)
    sys.exit(1)
unpinned = [d for d in requirements if '==' not in d]
if unpinned:
    print('Dependências sem versão fixa: ' + ', '.join(unpinned)); sys.exit(1)
print(f'{len(requirements)} dependências iguais e fixadas em requirements.txt e pyproject.toml.')
