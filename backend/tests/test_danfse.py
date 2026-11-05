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
    for expected in ['DANFSe v2.0','Documento Auxiliar da NFS-e','4'*50,'11.222.333/0001-81','529.982.247-25','TOMADOR FICTICIO','01.01.01 / -','R$ 10,00','NFS-e SEM VALIDADE JUR','NFS-e Gerada','NFS-e regular','Prestador','05/11/2026 16:27:04','IBS/CBS','DATA CIENTIFICA']:
        assert expected in t,expected

def test_production_document_has_no_test_warning():
    t=text_of(build_danfse(nfse('1')))
    assert 'NFS-e SEM VALIDADE JUR' not in t and 'DANFSe v2.0' in t and 'Tipo de Ambiente: 1' in t

def test_invalid_xml_is_refused():
    import pytest
    with pytest.raises(ValueError):build_danfse(f'<NFSe xmlns="{NS}"/>')


def test_qr_code_points_to_public_consultation_of_the_environment():
    import fitz,cv2,numpy as np
    for amb,host in [('2','https://www.producaorestrita.nfse.gov.br/ConsultaPublica?tpc=1&chave='),('1','https://www.nfse.gov.br/ConsultaPublica?tpc=1&chave=')]:
        page=fitz.open(stream=build_danfse(nfse(amb)),filetype='pdf')[0]
        pix=page.get_pixmap(dpi=300,clip=fitz.Rect(485,40,545,95))
        img=np.frombuffer(pix.samples,dtype=np.uint8).reshape(pix.h,pix.w,pix.n)
        assert cv2.QRCodeDetector().detectAndDecode(img[:,:,:3].copy())[0]==host+'4'*50


def _with_places(toma_mun='4205407',prest_mun='3550308',pais=None):
    x=etree.fromstring(nfse('2').encode())
    toma=x.find(f'.//{{{NS}}}infDPS/{{{NS}}}toma')
    end=etree.SubElement(toma,f'{{{NS}}}end');nac=etree.SubElement(end,f'{{{NS}}}endNac')
    etree.SubElement(nac,f'{{{NS}}}cMun').text=toma_mun;etree.SubElement(nac,f'{{{NS}}}CEP').text='88010001'
    for tag,val in [('xLgr','Rua Ficticia'),('nro','10'),('xBairro','Centro')]:etree.SubElement(end,f'{{{NS}}}{tag}').text=val
    loc=x.find(f'.//{{{NS}}}locPrest')
    for c in list(loc):loc.remove(c)
    if pais:etree.SubElement(loc,f'{{{NS}}}cPaisPrestacao').text=pais
    else:etree.SubElement(loc,f'{{{NS}}}cLocPrestacao').text=prest_mun
    return etree.tostring(x,encoding='unicode')

def test_municipality_names_and_uf_come_from_the_official_ibge_table():
    t=text_of(build_danfse(_with_places()))
    assert 'Florian\xf3polis / SC' in t          # tomador in another city: name + UF, not the IBGE code
    assert '42.05407 / 88.010-001' in t
    assert 'S\xe3o Paulo / SP / -' in t           # place of service elsewhere
    assert 'IBGE 4205407' not in t

def test_service_abroad_shows_the_country_and_unknown_codes_stay_visible():
    t=text_of(build_danfse(_with_places(pais='PT')))
    assert '- / - / Portugal' in t
    t=text_of(build_danfse(_with_places(toma_mun='9999999')))
    assert 'IBGE 9999999' in t
