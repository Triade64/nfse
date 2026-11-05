"""Builds backend/app/data/nbs.json from the official Anexo B (NBS 2.0) spreadsheet.

Only leaf codes are kept: the XSD type TSCodNBS requires exactly 9 digits (e.g. 1.1302.21.00 -> 113022100).
Usage: python scripts/build_nbs.py docs/official/anexo_b-nbs2-lista_servico_nacional-snnfse-prodrest-v1-01-20260122.xlsx
"""
import json
import re
import sys
from pathlib import Path

import openpyxl

ROOT = Path(__file__).resolve().parents[1]


def main(source: str):
    wb = openpyxl.load_workbook(source, read_only=True, data_only=True)
    ws = wb['LISTA.NBS_v2.0']
    table = {}
    for code, description in ws.iter_rows(min_row=2, max_col=2, values_only=True):
        digits = re.sub(r'\D', '', str(code or ''))
        if len(digits) == 9 and description:
            table[digits] = ' '.join(str(description).split())
    out = ROOT / 'backend' / 'app' / 'data' / 'nbs.json'
    out.parent.mkdir(parents=True, exist_ok=True)
    payload = {'source': Path(source).name, 'codes': dict(sorted(table.items()))}
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=0), encoding='utf-8')
    print(f'{len(table)} códigos NBS gravados em {out.relative_to(ROOT)}')


if __name__ == '__main__':
    main(sys.argv[1])
