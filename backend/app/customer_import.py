"""0.12.0: customer (tomador) import from a spreadsheet: template, line-by-line preview, then an all-or-nothing import.

Nothing is guessed: an invalid line blocks the whole import until it is corrected in the file. Blank cells of an existing
customer never erase registered data; only filled cells are written.
"""
import csv
import hashlib
import io
import re
import zipfile
from openpyxl import Workbook, load_workbook
from openpyxl.styles import Font, PatternFill
from .tomador import normalize_address, address_required, ADDRESS_FIELDS
from .validation import digits, valid_document

SHEET = 'Tomadores'
COLUMNS = ['cnpj_emitente', 'documento_tomador', 'nome_tomador', 'cep', 'logradouro', 'numero', 'complemento', 'bairro',
           'municipio_ibge', 'email', 'telefone']
REQUIRED = ('cnpj_emitente', 'documento_tomador', 'nome_tomador')
LABELS = {'cnpj_emitente': 'CNPJ do emitente (empresa cadastrada)', 'documento_tomador': 'CPF ou CNPJ do tomador',
          'nome_tomador': 'Nome / razão social', 'cep': 'CEP (8 dígitos)', 'logradouro': 'Logradouro', 'numero': 'Número',
          'complemento': 'Complemento', 'bairro': 'Bairro', 'municipio_ibge': 'Código IBGE do município (7 dígitos)',
          'email': 'E-mail', 'telefone': 'Telefone'}
MAX_BYTES = 8 * 1024 * 1024
MAX_ROWS = 2000
EMAIL = re.compile(r'^[^@\s]{1,64}@[^@\s]{1,190}\.[^@\s]{2,}$')


def template_workbook():
    wb = Workbook(); ws = wb.active; ws.title = SHEET; ws.append(COLUMNS)
    for cell in ws[1]:
        cell.font = Font(bold=True, color='FFFFFF'); cell.fill = PatternFill('solid', fgColor='165B45')
        ws.column_dimensions[cell.column_letter].width = 26
    # Text format keeps leading zeros of CPF, CNPJ and CEP.
    for column in ws.iter_cols(min_row=2, max_row=MAX_ROWS + 1):
        for cell in column: cell.number_format = '@'
    ws.freeze_panes = 'A2'
    help_ws = wb.create_sheet('Instrucoes')
    for line in [
        'Preencha uma linha por tomador na aba Tomadores. Não altere nem remova os cabeçalhos.',
        'Obrigatórios: cnpj_emitente (empresa já cadastrada no site), documento_tomador (CPF ou CNPJ) e nome_tomador.',
        'Endereço: obrigatório para tomador com CNPJ (regra E0235). Se informar o endereço, preencha CEP, logradouro, número, bairro e município IBGE.',
        'Município: código IBGE de 7 dígitos (ex.: Garopaba = 4205704).',
        'Tomador já cadastrado para o mesmo emitente é ATUALIZADO. Células vazias não apagam dados já cadastrados.',
        'Use apenas números ou com pontuação nos documentos e CEP; fórmulas não são aceitas.',
        'Antes de gravar, o site mostra a prévia de cada linha. Se houver erro em qualquer linha, nada é importado.',
    ]:
        help_ws.append([line])
    help_ws.column_dimensions['A'].width = 130
    return wb


def _text(value, column):
    if value is None: return ''
    # Excel may turn CPF/CNPJ/CEP typed as numbers into int/float and drop leading zeros.
    if isinstance(value, (int, float)) and not isinstance(value, bool) and column in ('cnpj_emitente', 'documento_tomador', 'cep', 'municipio_ibge'):
        n = str(int(value))
        if column == 'cep': return n.zfill(8)
        if column == 'cnpj_emitente': return n.zfill(14)
        if column == 'documento_tomador': return n.zfill(11) if len(n) <= 11 else n.zfill(14)
        return n
    return ' '.join(str(value).split())


def read_rows(data: bytes, filename: str):
    """Rows as dicts (with their spreadsheet line). Raises ValueError with a safe message."""
    if len(data) > MAX_BYTES: raise ValueError('Arquivo maior que 8 MB.')
    suffix = (filename or '').lower().rsplit('.', 1)[-1]
    rows = []
    if suffix == 'xlsx':
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                if sum(i.file_size for i in z.infolist()) > 40 * 1024 * 1024 or len(z.infolist()) > 500:
                    raise ValueError('Excel descompactado excessivo.')
        except zipfile.BadZipFile:
            raise ValueError('Arquivo Excel inválido.') from None
        wb = load_workbook(io.BytesIO(data), read_only=True, data_only=False)
        try:
            if SHEET not in wb.sheetnames: raise ValueError('Aba Tomadores não encontrada. Use o modelo baixado no site.')
            values = wb[SHEET].iter_rows(values_only=True)
            heads = [_text(x, '').strip() for x in next(values, ())]
            _check_heads(heads)
            for line, vals in enumerate(values, start=2):
                if not any(v is not None and str(v).strip() for v in vals): continue
                if len(vals) > len(heads) and any(v is not None and str(v).strip() for v in vals[len(heads):]):
                    raise ValueError(f'Linha {line}: valores fora das colunas do modelo.')
                if any(isinstance(v, str) and v.lstrip().startswith('=') for v in vals): raise ValueError(f'Linha {line}: fórmulas não são aceitas.')
                rows.append((line, {h: _text(v, h) for h, v in zip(heads, vals)}))
                if len(rows) > MAX_ROWS: raise ValueError(f'Limite de {MAX_ROWS} tomadores por arquivo.')
        finally:
            wb.close()
    elif suffix == 'csv':
        try: text = data.decode('utf-8-sig')
        except UnicodeDecodeError: raise ValueError('CSV deve estar em UTF-8.') from None
        first = text.splitlines()[0] if text else ''
        reader = csv.DictReader(io.StringIO(text), delimiter=';' if ';' in first else ',')
        heads = [h.strip() for h in (reader.fieldnames or [])]
        _check_heads(heads)
        for line, row in enumerate(reader, start=2):
            if None in row: raise ValueError(f'Linha {line}: quantidade de colunas incompatível.')
            if any(str(v).lstrip().startswith('=') for v in row.values()): raise ValueError(f'Linha {line}: fórmulas não são aceitas.')
            row = {k.strip(): _text(v, k.strip()) for k, v in row.items()}
            if any(row.values()): rows.append((line, row))
            if len(rows) > MAX_ROWS: raise ValueError(f'Limite de {MAX_ROWS} tomadores por arquivo.')
    else:
        raise ValueError('Use o modelo .xlsx ou um .csv UTF-8.')
    if not rows: raise ValueError('Arquivo sem tomadores preenchidos.')
    return rows


def _check_heads(heads):
    if len(heads) != len(set(heads)) or set(heads) != set(COLUMNS):
        raise ValueError('Cabeçalhos incompatíveis. Baixe o modelo de tomadores no site e preserve todas as colunas.')


def file_digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def analyze(rows, companies_by_cnpj: dict, allowed, existing):
    """companies_by_cnpj: cnpj -> company id; allowed(company_id) -> bool; existing(company_id, document) -> Customer|None.
    Returns one entry per line with action, errors and warnings (no database writes)."""
    out, seen = [], {}
    for line, row in rows:
        errors, warnings = [], []
        missing = [LABELS[k] for k in REQUIRED if not row.get(k)]
        if missing: errors.append('Preencha: ' + ', '.join(missing) + '.')
        issuer = digits(row.get('cnpj_emitente'))
        company_id = companies_by_cnpj.get(issuer)
        if issuer and company_id is None: errors.append('Emitente não cadastrado no site.')
        elif company_id is not None and not allowed(company_id): errors.append('Empresa emitente não autorizada para o seu usuário.')
        document = digits(row.get('documento_tomador'))
        if row.get('documento_tomador') and not valid_document(row.get('documento_tomador')): errors.append('CPF/CNPJ do tomador inválido.')
        name = row.get('nome_tomador', '')
        if name and not 2 <= len(name) <= 200: errors.append('Nome deve ter de 2 a 200 caracteres.')
        address, problems = normalize_address({k: row.get(k, '') for k in ADDRESS_FIELDS})
        errors += problems
        email = row.get('email', '')
        if email and (len(email) > 254 or not EMAIL.match(email)): errors.append('E-mail inválido.')
        if len(row.get('telefone', '')) > 30: errors.append('Telefone excede 30 caracteres.')
        key = (company_id, document)
        if company_id is not None and document:
            if key in seen: errors.append(f'Tomador repetido no arquivo (linha {seen[key]}).')
            else: seen[key] = line
        current = existing(company_id, document) if company_id is not None and document and not errors else None
        if errors:
            pass  # a line with errors only lists its errors
        elif address_required(document) and address is None and not (current and _has_address(current)):
            warnings.append('Tomador com CNPJ sem endereço: a nota não poderá ser emitida até completar (E0235).')
        if current and current.name.casefold() != name.casefold() and name:
            warnings.append(f'Nome atual "{current.name}" será substituído.')
        action = 'Com erro' if errors else ('Atualizar' if current else 'Novo')
        out.append({'line': line, 'cnpj_emitente': issuer, 'company_id': company_id, 'documento_tomador': document, 'nome_tomador': name,
                    'address': address, 'email': email, 'telefone': row.get('telefone', ''), 'action': action,
                    'errors': errors, 'warnings': warnings})
    return out


def _has_address(customer):
    address, problems = normalize_address(customer.details or {})
    return address is not None and not problems


def merged_details(current: dict, entry: dict) -> dict:
    """Filled cells win; blank cells keep what is registered (never erase)."""
    details = dict(current or {})
    if entry['address']:
        for key, value in entry['address'].items():
            if value: details[key] = value
    for key in ('email', 'telefone'):
        if entry[key]: details[key] = entry[key]
    return details
