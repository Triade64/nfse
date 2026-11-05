"""Restricted-environment DPS builder. No signing or submission: the XML is signed and sent by the local connector."""
from datetime import datetime, timezone, timedelta
from decimal import Decimal
from pathlib import Path
from typing import Literal
import json
import re
from lxml import etree
from pydantic import BaseModel, ConfigDict, Field, model_validator
from .validation import normalize
from .fiscal import validate_xml
from .tomador import address_required

NS = 'http://www.sped.fazenda.gov.br/nfse'
SCHEMA_DIR = Path(__file__).resolve().parents[2] / 'schemas' / 'restricted-20261020'

SERIES_PATTERN = r'^[0-9]{1,4}$|^[0-8][0-9]{4}$'
BRASILIA = timezone(timedelta(hours=-3))

class FiscalChoices(BaseModel):
    """Explicit tax choices confirmed by a person; nothing here is inferred or defaulted."""
    model_config = ConfigDict(extra='forbid')
    op_simp_nac: Literal['1','2','3']
    reg_ap_trib_sn: Literal['1','2','3'] | None
    reg_esp_trib: Literal['0','1','2','3','4','5','6','9']
    totals_mode: Literal['not_informed','simples_percent']
    simples_percent: Decimal | None = Field(default=None, ge=0, le=100, decimal_places=2)
    include_provider_im: bool
    include_iss_rate: bool

    @model_validator(mode='after')
    def coherent(self):
        if (self.op_simp_nac == '3') != (self.reg_ap_trib_sn is not None):
            raise ValueError('Informe o regime de apuração somente para ME/EPP optante pelo SN.')
        if self.totals_mode == 'simples_percent':
            if self.op_simp_nac != '3' or self.simples_percent is None:
                raise ValueError('Percentual SN exige ME/EPP optante e percentual explícito.')
        elif self.simples_percent is not None:
            raise ValueError('Percentual informado fora da opção SN.')
        elif self.op_simp_nac == '3':
            # API rule E0712 (confirmed in the restricted environment on 2026-11-05).
            raise ValueError('Para ME/EPP optante pelo SN a API exige o percentual aproximado do Simples (E0712); "não informar" é recusado.')
        return self

class PreviewOptions(FiscalChoices):
    revision: int = Field(ge=1)
    expected_raw: dict[str,str]
    own_company_cnpj: str = Field(pattern=r'^\d{14}$')
    confirm_offline: Literal[True]
    confirm_scope: Literal[True]
    series: str = Field(pattern=SERIES_PATTERN)
    number: str = Field(pattern=r'^[1-9][0-9]{0,14}$')
    issued_at: datetime

    @model_validator(mode='after')
    def emission_instant(self):
        check_instant(self.issued_at)
        return self

class ReserveOptions(FiscalChoices):
    """Reserves the next central number; emission instant comes from the server clock."""
    revision: int = Field(ge=1)
    expected_raw: dict[str,str]
    own_company_cnpj: str = Field(pattern=r'^\d{14}$')
    series: str = Field(pattern=SERIES_PATTERN)
    confirm_reserve: Literal[True]
    confirm_scope: Literal[True]

class FiscalProfile(BaseModel):
    """Per-company fiscal choices, reviewed once by an administrator and reused on every emission.
    The Simples percentage varies month to month, so it is NOT stored here: it is confirmed at each emission."""
    model_config = ConfigDict(extra='forbid')
    op_simp_nac: Literal['1','2','3']
    reg_ap_trib_sn: Literal['1','2','3'] | None
    reg_esp_trib: Literal['0','1','2','3','4','5','6','9']
    totals_mode: Literal['not_informed','simples_percent']
    include_provider_im: bool
    include_iss_rate: bool
    series: str = Field(pattern=SERIES_PATTERN)

    @model_validator(mode='before')
    @classmethod
    def drop_legacy_percent(cls, data):
        # Profiles saved by 0.7.0 carried a fixed percentage; it is ignored from 0.7.1 on.
        if isinstance(data, dict):
            data = {k: v for k, v in data.items() if k != 'simples_percent'}
            # Only one value is legal per regime (E0712), so a 0.7.0 profile saved as "not_informed" is brought forward.
            if data.get('op_simp_nac') in ('1', '2', '3'):
                data['totals_mode'] = 'simples_percent' if data['op_simp_nac'] == '3' else 'not_informed'
        return data

    @model_validator(mode='after')
    def coherent(self):
        if (self.op_simp_nac == '3') != (self.reg_ap_trib_sn is not None):
            raise ValueError('Informe o regime de apuração somente para ME/EPP optante pelo SN.')
        if (self.op_simp_nac == '3') != (self.totals_mode == 'simples_percent'):
            raise ValueError('ME/EPP optante pelo SN informa o percentual do Simples a cada emissão (E0712); demais regimes não informam estimativa.')
        return self

    def choices(self, simples_percent):
        """Fiscal choices for one emission; the percentage is required exactly when the profile asks for it."""
        if (self.totals_mode == 'simples_percent') != (simples_percent is not None):
            raise ValueError('Informe o percentual aproximado do Simples desta emissão.' if self.totals_mode == 'simples_percent' else 'Esta empresa não informa percentual do Simples.')
        data = self.model_dump(exclude={'series'})
        return {**data, 'simples_percent': simples_percent}

def check_instant(issued_at: datetime):
    if issued_at.utcoffset() is None:
        raise ValueError('Data de emissão exige fuso horário.')
    if issued_at > datetime.now(timezone.utc):
        raise ValueError('A data/hora de emissão não pode ser futura. Confira o horário de Brasília.')

def normalize_series(series: str) -> str:
    if not re.fullmatch(SERIES_PATTERN, series):
        raise ValueError('Série inválida.')
    return str(int(series))

def build_preview(raw: dict, company: dict, options: PreviewOptions, tomador_address: dict | None = None) -> bytes:
    return build_dps(raw, company, options, options.own_company_cnpj, options.series, options.number, options.issued_at, 'Triade-Offline-0.7', tomador_address)

def dps_identifier(municipality: str, cnpj: str, series: str, number: str) -> str:
    return f"DPS{municipality}2{cnpj}{series.zfill(5)}{number.zfill(15)}"

def build_dps(raw: dict, company: dict, options: FiscalChoices, own_company_cnpj: str, series: str, number: str, issued_at: datetime, ver_aplic: str, tomador_address: dict | None = None) -> bytes:
    check_instant(issued_at)
    row, errors, _, _ = normalize(raw)
    if errors:
        raise ValueError('Corrija o rascunho antes de preparar o XML.')
    if own_company_cnpj != company['cnpj'] or row['cnpj_emitente'] != company['cnpj']:
        raise ValueError('O CNPJ confirmado deve ser o do próprio escritório e do rascunho.')
    municipality = str(company['config'].get('municipio_ibge',''))
    if len(municipality) != 7 or not municipality.isdecimal():
        raise ValueError('Confira o código IBGE do emitente no cadastro.')
    # Never silently drop tax information that this first prototype cannot map.
    if row['iss_retido'] != 'nao' or any(Decimal(v) != 0 for v in json.loads(row['retencoes']).values()):
        raise ValueError('Este protótipo suporta somente operação sem retenções. Não altere tributos para contornar essa limitação.')
    identifier = dps_identifier(municipality, company['cnpj'], series, number)
    root = etree.Element(f'{{{NS}}}DPS', nsmap={None:NS}, versao='1.01')
    def add(parent, name, text=None):
        node = etree.SubElement(parent, f'{{{NS}}}{name}')
        if text is not None: node.text = str(text)
        return node
    info = add(root,'infDPS'); info.set('Id',identifier)
    for key,value in [('tpAmb','2'),('dhEmi',issued_at.astimezone(BRASILIA).isoformat(timespec='seconds')),('verAplic',ver_aplic),('serie',series),('nDPS',number),('dCompet',row['competencia']),('tpEmit','1'),('finNFSe','0'),('cLocEmi',municipality)]:
        add(info,key,value)
    prest=add(info,'prest'); add(prest,'CNPJ',company['cnpj'])
    # IM/address/name are conditional and must be reviewed against municipal rules.
    im=str(company['config'].get('inscricao_municipal','')).strip()
    if options.include_provider_im:
        if not im:raise ValueError('Cadastro sem inscrição municipal. Confira a exigência antes de incluí-la no XML.')
        add(prest,'IM',im)
    regime=add(prest,'regTrib');add(regime,'opSimpNac',options.op_simp_nac)
    if options.reg_ap_trib_sn:add(regime,'regApTribSN',options.reg_ap_trib_sn)
    add(regime,'regEspTrib',options.reg_esp_trib)
    toma=add(info,'toma'); add(toma,'CNPJ' if len(row['documento_tomador'])==14 else 'CPF',row['documento_tomador']);add(toma,'xNome',row['nome_tomador'])
    if tomador_address is None and address_required(row['documento_tomador']):
        raise ValueError('Tomador com CNPJ exige endereço completo (regra E0235). Cadastre CEP, logradouro, número, bairro e município em Tomadores.')
    if tomador_address is not None:
        end=add(toma,'end');nac=add(end,'endNac');add(nac,'cMun',tomador_address['municipio_ibge']);add(nac,'CEP',tomador_address['cep'])
        add(end,'xLgr',tomador_address['logradouro']);add(end,'nro',tomador_address['numero'])
        if tomador_address['complemento']:add(end,'xCpl',tomador_address['complemento'])
        add(end,'xBairro',tomador_address['bairro'])
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
