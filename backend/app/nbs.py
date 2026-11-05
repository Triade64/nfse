"""NBS 2.0 table (Anexo B, leaf codes with 9 digits as required by TSCodNBS). Built by scripts/build_nbs.py."""
import json
import re
from functools import lru_cache
from pathlib import Path

DATA = Path(__file__).resolve().parent / 'data' / 'nbs.json'


@lru_cache(maxsize=1)
def nbs_table() -> dict[str, str]:
    return json.loads(DATA.read_text(encoding='utf-8'))['codes']


def normalize_nbs(value) -> tuple[str, str | None]:
    """Returns (9-digit code or '', error). Accepts 1.1302.21.00 or 113022100; empty means 'not informed'."""
    text = str(value or '').strip()
    if not text:
        return '', None
    digits = re.sub(r'\D', '', text)
    if len(digits) != 9:
        return text, 'codigo_nbs: informe o código NBS completo com 9 dígitos (ex.: 1.1302.21.00)'
    if digits not in nbs_table():
        return digits, 'codigo_nbs: código inexistente na lista NBS 2.0 do Anexo B (regra E0316)'
    return digits, None


def format_nbs(digits: str) -> str:
    return f'{digits[0]}.{digits[1:5]}.{digits[5:7]}.{digits[7:9]}' if len(digits) == 9 else digits
