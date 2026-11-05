"""Offline restricted-environment prototype. No signing, submission or numbering reservation."""
from datetime import datetime, timezone, timedelta
from decimal import Decimal
from pathlib import Path
from typing import Literal
import json
from lxml import etree
from pydantic import BaseModel, ConfigDict, Field, model_validator
from .validation import normalize
from .fiscal import validate_xml

NS = 'http://www.sped.fazenda.gov.br/nfse'
SCHEMA_DIR = Path(__file__).resolve().parents[2] / 'schemas' / 'restricted-20261020'

class PreviewOptions(BaseModel):
    model_config = ConfigDict(extra='forbid')
    revision: int = Field(ge=1)
    expected_raw: dict[str,str]
    own_company_cnpj: str = Field(pattern=r'^\d{14}$')
    confirm_offline: Literal[True]
    confirm_scope: Literal[True]
    series: str = Field(pattern=r'^[0-9]{1,4}$|^[0-8][0-9]{4}$')
    number: str = Field(pattern=r'^[1-9][0-9]{0,14}$')
    issued_at: datetime
    op_simp_nac: Literal['1','2','3']
    reg_ap_trib_sn: Literal['1','2','3'] | None
    reg_esp_trib: Literal['0','1','2','3','4','5','6','9']
    totals_mode: Literal['not_informed','simples_percent']
    simples_percent: Decimal | None = Field(default=None, ge=0, le=100, decimal_places=2)
    include_iss_rate: bool

    @model_validator(mode='after')
    def coherent(self):
        if self.issued_at.utcoffset() is None:
            raise ValueError('Data de emissão exige fuso horário.')
        if self.issued_at > datetime.now(timezone.utc):
            raise ValueError('A data/hora de emissão não pode ser futura. Confira o horário de Brasília.')
        if (self.op_simp_nac == '3') != (self.reg_ap_trib_sn is not None):
            raise ValueError('Informe o regime de apuração somente para ME/EPP optante pelo SN.')
        if self.totals_mode == 'simples_percent':
            if self.op_simp_nac != '3' or self.simples_percent is None:
                raise ValueError('Percentual SN exige ME/EPP optante e percentual explícito.')
        elif self.simples_percent is not None:
            raise ValueError('Percentual informado fora da opção SN.')
        return self

def build_preview(raw: dict, company: dict, options: PreviewOptions) -> bytes:
    row, errors, _, _ = normalize(raw)
    if errors:
        raise ValueError('Corrija o rascunho antes de preparar o XML.')
    if options.own_company_cnpj != company['cnpj'] or row['cnpj_emitente'] != company['cnpj']:
        raise ValueError('O CNPJ confirmado deve ser o do próprio escritório e do rascunho.')
    municipality = str(company['config'].get('municipio_ibge',''))
    if len(municipality) != 7 or not municipality.isdecimal():
        raise ValueError('Confira o código IBGE do emitente no cadastro.')
    # Never silently drop tax information that this first prototype cannot map.
    if row['iss_retido'] != 'nao' or any(Decimal(v) != 0 for v in json.loads(row['retencoes']).values()):
        raise ValueError('Este protótipo suporta somente operação sem retenções. Não altere tributos para contornar essa limitação.')
    identifier = f"DPS{municipality}2{company['cnpj']}{options.series.zfill(5)}{options.number.zfill(15)}"
    root = etree.Element(f'{{{NS}}}DPS', nsmap={None:NS}, versao='1.01')
    def add(parent, name, text=None):
        node = etree.SubElement(parent, f'{{{NS}}}{name}')
        if text is not None: node.text = str(text)
        return node
    info = add(root,'infDPS'); info.set('Id',identifier)
    for key,value in [('tpAmb','2'),('dhEmi',options.issued_at.astimezone(timezone(timedelta(hours=-3))).isoformat(timespec='seconds')),('verAplic','Triade-Offline-0.7'),('serie',options.series),('nDPS',options.number),('dCompet',row['competencia']),('tpEmit','1'),('finNFSe','0'),('cLocEmi',municipality)]:
        add(info,key,value)
    prest=add(info,'prest'); add(prest,'CNPJ',company['cnpj'])
    # IM/address/name are conditional and must be reviewed against municipal rules.
    im=str(company['config'].get('inscricao_municipal','')).strip()
    if im:add(prest,'IM',im)
    regime=add(prest,'regTrib');add(regime,'opSimpNac',options.op_simp_nac)
    if options.reg_ap_trib_sn:add(regime,'regApTribSN',options.reg_ap_trib_sn)
    add(regime,'regEspTrib',options.reg_esp_trib)
    toma=add(info,'toma'); add(toma,'CNPJ' if len(row['documento_tomador'])==14 else 'CPF',row['documento_tomador']);add(toma,'xNome',row['nome_tomador'])
    serv=add(info,'serv'); add(add(serv,'locPrest'),'cLocPrestacao',row['municipio_ibge'])
    code=add(serv,'cServ'); add(code,'cTribNac',row['codigo_tributacao_nacional'])
    if row['codigo_tributacao_municipal']:add(code,'cTribMun',row['codigo_tributacao_municipal'])
    add(code,'xDescServ',row['descricao_servico'])
    if row['observacoes']:add(add(serv,'infoCompl'),'xInfComp',row['observacoes'])
    values=add(info,'valores');add(add(values,'vServPrest'),'vServ',row['valor_servico'])
    tax=add(values,'trib');municipal=add(tax,'tribMun')
    add(municipal,'tribISSQN','1');add(municipal,'tpRetISSQN','1')
    if options.include_iss_rate:add(municipal,'pAliq',row['iss_aliquota'])
    total=add(tax,'totTrib')
    if options.totals_mode=='not_informed':add(total,'indTotTrib','0')
    else:add(total,'pTotTribSN',format(options.simples_percent,'.2f'))
    xml=etree.tostring(root,encoding='UTF-8',xml_declaration=True,pretty_print=False)
    try:validate_xml(xml,SCHEMA_DIR/'DPS_v1.01.xsd')
    except (etree.DocumentInvalid,etree.XMLSyntaxError):
        raise ValueError('XML incompatível com o XSD de testes. Confira os campos e códigos; nenhum arquivo foi enviado.') from None
    return xml
