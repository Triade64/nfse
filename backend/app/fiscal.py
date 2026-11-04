"""Fiscal boundary: no HTTP client or emission implementation exists in phase 1."""
from pathlib import Path
from lxml import etree

class FiscalIntegrationUnavailable(RuntimeError):
    pass

def emit(*args, **kwargs):
    raise FiscalIntegrationUnavailable('Emissão real desabilitada. Homologação, certificado e procuração não validados.')

def validate_xml(xml: bytes, schema_path: Path):
    parser = etree.XMLParser(resolve_entities=False, no_network=True, load_dtd=False)
    document = etree.fromstring(xml, parser)
    if document.getroottree().docinfo.doctype:
        raise ValueError('DTD não permitida')
    schema = etree.XMLSchema(etree.parse(str(schema_path), parser))
    schema.assertValid(document)
    return True
