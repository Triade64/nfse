"""Builds backend/app/data/localidades.json from the official Anexo A (IBGE municipalities, ISO2 countries).

Usage: python scripts/build_localidades.py docs/official/anexo_a-municipio_ibge-paises_iso2-v1-00-snnfse-20251210.xlsx
"""
import json
import re
import sys
from pathlib import Path

import openpyxl

ROOT = Path(__file__).resolve().parents[1]
UF_BY_IBGE = {'11': 'RO', '12': 'AC', '13': 'AM', '14': 'RR', '15': 'PA', '16': 'AP', '17': 'TO', '21': 'MA', '22': 'PI', '23': 'CE', '24': 'RN',
              '25': 'PB', '26': 'PE', '27': 'AL', '28': 'SE', '29': 'BA', '31': 'MG', '32': 'ES', '33': 'RJ', '35': 'SP', '41': 'PR', '42': 'SC',
              '43': 'RS', '50': 'MS', '51': 'MT', '52': 'GO', '53': 'DF'}


def main(source: str):
    wb = openpyxl.load_workbook(source, read_only=True, data_only=True)
    municipios, paises, especiais = {}, {}, {}
    for ws in wb.worksheets:
        ws.reset_dimensions()  # the file stores a wrong <dimension>; read every row
    for _, uf, nome, codigo in wb['TAB.MUN_IBGE'].iter_rows(min_row=2, max_col=4, values_only=True):
        code = re.sub(r'\D', '', str(codigo or ''))
        if len(code) != 7 or not nome:
            continue
        # The official sheet leaves "Sigla UF" empty from Maranhão on; the 2-digit IBGE state prefix is authoritative.
        derived = UF_BY_IBGE.get(code[:2])
        if not derived:
            raise SystemExit(f'Prefixo IBGE desconhecido: {code}')
        if uf and str(uf).strip().upper() != derived:
            raise SystemExit(f'UF divergente para {code}: planilha {uf}, prefixo {derived}')
        municipios[code] = [' '.join(str(nome).split()), derived]
    for iso, nome in wb[wb.sheetnames[1]].iter_rows(min_row=2, max_col=2, values_only=True):
        if iso and nome and re.fullmatch(r'[A-Za-z]{2}', str(iso).strip()):
            paises[str(iso).strip().upper()] = ' '.join(str(nome).split())
    for nome, codigo in wb[wb.sheetnames[2]].iter_rows(min_row=2, max_col=2, values_only=True):
        code = re.sub(r'\D', '', str(codigo or ''))
        if len(code) == 7 and nome:
            especiais[code] = ' '.join(str(nome).split()).title()
    out = ROOT / 'backend' / 'app' / 'data' / 'localidades.json'
    payload = {'source': Path(source).name, 'municipios': dict(sorted(municipios.items())), 'paises': dict(sorted(paises.items())), 'especiais': especiais}
    out.write_text(json.dumps(payload, ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
    print(f'{len(municipios)} municípios, {len(paises)} países e {len(especiais)} localidades especiais gravados em {out.relative_to(ROOT)}')


if __name__ == '__main__':
    main(sys.argv[1])
