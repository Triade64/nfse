import hashlib
import json
import re
from datetime import date, datetime
from decimal import Decimal, InvalidOperation

HEADERS = ['cnpj_emitente','documento_tomador','nome_tomador','competencia','municipio_ibge','descricao_servico','codigo_tributacao_nacional','codigo_tributacao_municipal','valor_servico','iss_aliquota','iss_retido','retencoes','observacoes']
REQUIRED = [x for x in HEADERS if x not in ['codigo_tributacao_municipal','observacoes']]

def digits(value):
    return re.sub(r'\D', '', str(value or ''))

def valid_document(value):
    # MVP accepts numeric CPF/CNPJ only. Alphanumeric CNPJ requires its own validated algorithm.
    text = str(value or '').strip()
    if re.search('[A-Za-z]', text):
        return False
    n = digits(text)
    if len(n) not in (11, 14) or len(set(n)) == 1:
        return False
    if len(n) == 11:
        for size in (9, 10):
            v = (sum(int(n[i]) * (size+1-i) for i in range(size)) * 10) % 11 % 10
            if v != int(n[size]):
                return False
    else:
        for size in (12, 13):
            weights = ([5,4,3,2,9,8,7,6,5,4,3,2] if size == 12 else [6,5,4,3,2,9,8,7,6,5,4,3,2])
            rem = sum(int(n[i])*weights[i] for i in range(size)) % 11
            if (0 if rem < 2 else 11-rem) != int(n[size]):
                return False
    return True

def decimal_value(value):
    s = str(value).strip().replace('R$', '').strip()
    if ',' in s:
        s = s.replace('.', '').replace(',', '.')
    n = Decimal(s)
    if not n.is_finite():
        raise ValueError('Valor não finito')
    return n

def normalize(raw):
    r = {h: ('' if raw.get(h) is None else str(raw.get(h, ''))).strip() for h in HEADERS}
    r['cnpj_emitente'] = digits(r['cnpj_emitente']) if not re.search('[A-Za-z]', r['cnpj_emitente']) else r['cnpj_emitente']
    r['documento_tomador'] = digits(r['documento_tomador']) if not re.search('[A-Za-z]', r['documento_tomador']) else r['documento_tomador']
    errors = []
    for field in REQUIRED:
        if not r[field]:
            errors.append(f'{field}: preenchimento obrigatório')
    for field, length in [('cnpj_emitente',14), ('documento_tomador',None)]:
        if not valid_document(r[field]) or (length and len(r[field]) != length):
            errors.append(f'{field}: CPF/CNPJ numérico inválido; CNPJ alfanumérico ainda não suportado')
    try:
        parsed = date.fromisoformat(r['competencia'])
        if parsed > date.today():
            errors.append('competencia: data futura; revise antes de preparar')
    except ValueError:
        errors.append('competencia: utilize AAAA-MM-DD')
    if not re.fullmatch(r'\d{7}', r['municipio_ibge']):
        errors.append('municipio_ibge: informe o código IBGE de 7 dígitos (existência ainda não consultada)')
    if not re.fullmatch(r'\d{6}', r['codigo_tributacao_nacional']):
        errors.append('codigo_tributacao_nacional: informe 6 dígitos; validade fiscal depende do catálogo oficial')
    if len(r['descricao_servico']) < 3 or len(r['descricao_servico']) > 2000:
        errors.append('descricao_servico: use de 3 a 2.000 caracteres')
    amount = 0
    try:
        n = decimal_value(r['valor_servico'])
        if n <= 0 or n > Decimal('999999999.99') or n != n.quantize(Decimal('.01')):
            raise ValueError()
        amount = int(n * 100)
        r['valor_servico'] = str(n.quantize(Decimal('.01')))
    except (InvalidOperation, ValueError):
        errors.append('valor_servico: informe valor positivo com até duas casas decimais')
    try:
        n = decimal_value(r['iss_aliquota'])
        if not 0 <= n <= 100 or n != n.quantize(Decimal('.01')):
            raise ValueError()
        r['iss_aliquota'] = str(n.quantize(Decimal('.01')))
    except (InvalidOperation, ValueError):
        errors.append('iss_aliquota: informe percentual de 0 a 100; não representa validação de alíquota legal')
    if r['iss_retido'].lower() not in ('sim', 'nao', 'não'):
        errors.append('iss_retido: use sim ou nao')
    else:
        r['iss_retido'] = 'sim' if r['iss_retido'].lower() == 'sim' else 'nao'
    try:
        taxes = json.loads(r['retencoes'])
        if not isinstance(taxes, dict) or set(taxes) - {'irrf','pis','cofins','csll','inss'}:
            raise ValueError()
        out = {}
        for k,v in taxes.items():
            n = decimal_value(v)
            if n < 0 or n != n.quantize(Decimal('.01')) or n*100 > amount:
                raise ValueError()
            out[k] = str(n.quantize(Decimal('.01')))
        if sum(Decimal(v) for v in out.values()) * 100 > amount:
            raise ValueError()
        r['retencoes'] = json.dumps(out, sort_keys=True)
    except (ValueError, InvalidOperation, TypeError):
        errors.append('retencoes: use {} ou objeto JSON com irrf/pis/cofins/csll/inss em reais, até o valor do serviço')
    # Conservative duplicate detection deliberately ignores notes and customer spelling.
    identity = {k:r[k] for k in ['cnpj_emitente','documento_tomador','competencia','municipio_ibge','descricao_servico','codigo_tributacao_nacional','valor_servico']}
    fp = hashlib.sha256(json.dumps(identity, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    return r, errors, amount, fp

def cell_text(v):
    if isinstance(v, (datetime,date)):
        return v.date().isoformat() if isinstance(v,datetime) else v.isoformat()
    return '' if v is None else str(v)
