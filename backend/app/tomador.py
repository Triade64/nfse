"""Structured customer (tomador) address, as required by the national DPS layout (toma/end/endNac).

Rule #274 / E0235 (Anexo I, 2026-10-20): when the issuer is the provider and the customer is identified by CNPJ,
the national address group is mandatory. The address lives in the customer registry (customers.details), never inferred.
"""
import re

ADDRESS_FIELDS = ('cep', 'logradouro', 'numero', 'complemento', 'bairro', 'municipio_ibge')
REQUIRED = ('cep', 'logradouro', 'numero', 'bairro', 'municipio_ibge')
LIMITS = {'logradouro': 255, 'numero': 60, 'complemento': 156, 'bairro': 60}
LABELS = {'cep': 'CEP', 'logradouro': 'Logradouro', 'numero': 'Número', 'bairro': 'Bairro', 'municipio_ibge': 'Município (IBGE)'}


def normalize_address(details: dict):
    """Returns (address or None when nothing was filled, list of errors). Never guesses missing parts."""
    raw = {k: ' '.join(str((details or {}).get(k) or '').split()) for k in ADDRESS_FIELDS}
    if not any(raw.values()):
        return None, []
    errors = []
    raw['cep'] = re.sub(r'\D', '', raw['cep'])
    raw['municipio_ibge'] = re.sub(r'\D', '', raw['municipio_ibge'])
    missing = [LABELS[k] for k in REQUIRED if not raw[k]]
    if missing:
        errors.append('Endereço incompleto: informe ' + ', '.join(missing) + '.')
    if raw['cep'] and len(raw['cep']) != 8:
        errors.append('CEP deve ter 8 dígitos.')
    if raw['municipio_ibge'] and len(raw['municipio_ibge']) != 7:
        errors.append('Município IBGE deve ter 7 dígitos.')
    for key, limit in LIMITS.items():
        if len(raw[key]) > limit:
            errors.append(f'{key} excede {limit} caracteres.')
    return raw, errors


def complete_address(details: dict):
    """The address only when every mandatory part is valid; otherwise None."""
    address, errors = normalize_address(details)
    return address if address and not errors else None


def address_required(document: str) -> bool:
    """E0235: mandatory for CNPJ customers when the provider issues the DPS."""
    return len(re.sub(r'\D', '', document or '')) == 14
