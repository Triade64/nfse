import re
import zlib
from pathlib import Path
from lxml import etree
from app.danfse import build_danfse

NS='http://www.sped.fazenda.gov.br/nfse'
DPS=(Path(__file__).resolve().parents[2]/'local_connector'/'tests'/'dps-ficticia.xml').read_text(encoding='utf-8')

def nfse(tp_amb='2',extra_dps=''):
    dps=etree.fromstring(DPS.encode())
    dps.find(f'.//{{{NS}}}tpAmb').text=tp_amb
    root=etree.Element(f'{{{NS}}}NFSe',nsmap={None:NS},versao='1.01');inf=etree.SubElement(root,f'{{{NS}}}infNFSe',Id='NFS'+'4'*50)
    for tag,val in [('xLocEmi','Municipio Ficticio'),('xLocPrestacao','Municipio Ficticio'),('nNFSe','12'),('xLocIncid','Municipio Ficticio'),('xTribNac','Servico ficticio – com travessão'),('cStat','100'),('dhProc','2026-11-05T16:27:04-03:00'),('nDFSe','386')]:
        etree.SubElement(inf,f'{{{NS}}}{tag}').text=val
    emit=etree.SubElement(inf,f'{{{NS}}}emit');etree.SubElement(emit,f'{{{NS}}}CNPJ').text='11222333000181';etree.SubElement(emit,f'{{{NS}}}xNome').text='EMPRESA FICTÍCIA'
    vals=etree.SubElement(inf,f'{{{NS}}}valores');etree.SubElement(vals,f'{{{NS}}}vLiq').text='10.00'
    inf.append(dps)
    return etree.tostring(root,encoding='unicode')

def text_of(pdf:bytes)->str:
    out=[]
    for m in re.finditer(rb'stream\r?\n(.*?)\r?\nendstream',pdf,re.S):
        try:out.append(zlib.decompress(m.group(1)).decode('latin-1'))
        except zlib.error:out.append(m.group(1).decode('latin-1'))
    return '\n'.join(out)

def test_danfse_contains_key_data_and_test_environment_warning():
    pdf=build_danfse(nfse('2'))
    assert pdf.startswith(b'%PDF-')
    t=text_of(pdf)
    for expected in ['NFS-e n','12','4444 4444','11.222.333/0001-81','529.982.247-25','TOMADOR FICTICIO','010101','R$ 10,00','SEM VALOR FISCAL','PRODU','Autorizada','05/11/2026 16:27:04']:
        assert expected in t,expected

def test_production_document_has_no_test_warning():
    t=text_of(build_danfse(nfse('1')))
    assert 'SEM VALOR FISCAL' not in t and 'PRODU\xc7\xc3O RESTRITA' not in t

def test_invalid_xml_is_refused():
    import pytest
    with pytest.raises(ValueError):build_danfse(f'<NFSe xmlns="{NS}"/>')
