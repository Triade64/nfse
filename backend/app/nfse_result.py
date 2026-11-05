"""Server-side check of an NFS-e reported by the local connector.

The connector already validates the government response (XSD, ids, environment). The site does not trust the PC
blindly: before marking a DPS as authorized it re-checks that the returned NFS-e contains exactly the DPS it reserved.
"""
import base64
import binascii
import re
from lxml import etree

NS = {'n': 'http://www.sped.fazenda.gov.br/nfse'}
MAX_BYTES = 2 * 1024 * 1024


def _parse(xml: bytes):
    parser = etree.XMLParser(resolve_entities=False, no_network=True, load_dtd=False, huge_tree=False)
    doc = etree.fromstring(xml, parser)
    if doc.getroottree().docinfo.doctype:
        raise ValueError('XML com DTD não é aceito.')
    return doc


def check_authorized_nfse(nfse_b64: str, access_key: str, reserved_xml: str, environment: str = '2') -> str:
    """Returns the decoded NFS-e XML (text) or raises ValueError with a safe message."""
    if not re.fullmatch(r'[0-9]{50}', access_key or ''):
        raise ValueError('Chave de acesso inválida.')
    try:
        raw = base64.b64decode(nfse_b64 or '', validate=True)
    except (binascii.Error, ValueError):
        raise ValueError('XML da NFS-e em Base64 inválido.') from None
    if not raw or len(raw) > MAX_BYTES:
        raise ValueError('XML da NFS-e vazio ou grande demais.')
    try:
        nfse = _parse(raw)
        reserved = _parse(reserved_xml.encode('utf-8'))
    except etree.XMLSyntaxError:
        raise ValueError('XML da NFS-e malformado.') from None
    info = nfse.find('n:infNFSe', NS)
    dps = nfse.find('n:infNFSe/n:DPS/n:infDPS', NS)
    sent = reserved.find('n:infDPS', NS)
    if nfse.tag != '{%s}NFSe' % NS['n'] or info is None or dps is None or sent is None:
        raise ValueError('Estrutura da NFS-e inesperada.')
    if info.get('Id') != 'NFS' + access_key:
        raise ValueError('A NFS-e não corresponde à chave informada.')
    if dps.get('Id') != sent.get('Id'):
        raise ValueError('A NFS-e não contém a DPS reservada pelo site.')
    for path in ('n:tpAmb', 'n:nDPS', 'n:serie', 'n:dCompet', 'n:prest/n:CNPJ', 'n:valores/n:vServPrest/n:vServ', 'n:toma/n:CNPJ', 'n:toma/n:CPF'):
        if (dps.findtext(path, namespaces=NS) or '') != (sent.findtext(path, namespaces=NS) or ''):
            raise ValueError('Dados da NFS-e divergem da DPS reservada.')
    if environment not in ('1', '2') or dps.findtext('n:tpAmb', namespaces=NS) != environment:
        raise ValueError('NFS-e de ambiente diferente do da DPS reservada.')
    return raw.decode('utf-8')
