"""DPS builder for the restricted (tpAmb 2) and production (tpAmb 1) environments.
No signing or submission: the XML is signed and sent by the local connector."""
from functools import lru_cache
from datetime import datetime, timezone, timedelta
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path
from typing import Literal
import json
import re
from lxml import etree
from pydantic import BaseModel, ConfigDict, Field, model_validator
from .validation import normalize
from .tomador import address_required

NS = 'http://www.sped.fazenda.gov.br/nfse'
SCHEMA_DIR = Path(__file__).resolve().parents[2] / 'schemas' / 'restricted-20261020'
PRODUCTION_SCHEMA_DIR = Path(__file__).resolve().parents[2] / 'schemas' / 'production-20260209'
RESTRICTED, PRODUCTION = '2', '1'
# Each environment runs its own published layout. Production keeps the 2026-02-09 layout (finNFSe inside IBSCBS,
# xDescServ before cNBS); the 2026-10-20 layout (NT 009) is deployed only in the restricted environment so far.
SCHEMA_DIRS = {RESTRICTED: SCHEMA_DIR, PRODUCTION: PRODUCTION_SCHEMA_DIR}
ENVIRONMENT_NAMES = {RESTRICTED: 'produção restrita (testes)', PRODUCTION: 'produção (validade jurídica)'}

# Rule E0010: series 00001-49999 are reserved for the contributor's own application (50000+ belong to the
# government emitters: mobile, web and manual transcription). Same range in both environments.
SERIES_PATTERN = r'^0{0,4}([1-9][0-9]{0,3}|[1-4][0-9]{4})$'
BRASILIA = timezone(timedelta(hours=-3))

def _check_pis_cofins(m):
    # 0.15.0: own-assessment PIS/COFINS shown on the note, never retained (tpRetPisCofins 0). Non-optants only.
    if m.pis_cofins:
        if m.op_simp_nac != '1' or m.aliq_pis is None or m.aliq_cofins is None:
            raise ValueError('Destaque de PIS/COFINS: somente para não optante do Simples, com as duas alíquotas.')
    elif m.aliq_pis is not None or m.aliq_cofins is not None:
        raise ValueError('Alíquotas de PIS/COFINS informadas sem o destaque ativado.')

class FiscalChoices(BaseModel):
    """Explicit tax choices confirmed by a person; nothing here is inferred or defaulted."""
    model_config = ConfigDict(extra='forbid')
    op_simp_nac: Literal['1','2','3']
    reg_ap_trib_sn: Literal['1','2','3'] | None
    reg_esp_trib: Literal['0','1','2','3','4','5','6','9']
    totals_mode: Literal['not_informed','simples_percent','percentages']
    simples_percent: Decimal | None = Field(default=None, ge=0, le=100, decimal_places=2)
    # 0.14.0: approximate total of taxes for non-optants (Lucro Presumido/Real), Lei 12.741 (e.g. IBPT table).
    tot_fed: Decimal | None = Field(default=None, ge=0, le=100, decimal_places=2)
    tot_est: Decimal | None = Field(default=None, ge=0, le=100, decimal_places=2)
    tot_mun: Decimal | None = Field(default=None, ge=0, le=100, decimal_places=2)
    include_provider_im: bool
    include_iss_rate: bool
    pis_cofins: bool = False
    aliq_pis: Decimal | None = Field(default=None, gt=0, le=100, decimal_places=2)
    aliq_cofins: Decimal | None = Field(default=None, gt=0, le=100, decimal_places=2)

    @model_validator(mode='after')
    def coherent(self):
        if (self.op_simp_nac == '3') != (self.reg_ap_trib_sn is not None):
            raise ValueError('Informe o regime de apuração somente para ME/EPP optante pelo SN.')
        _check_pis_cofins(self)
        percentages = (self.tot_fed, self.tot_est, self.tot_mun)
        if self.totals_mode == 'percentages':
            # Rule E0713: a non-optant can neither omit the estimate (indTotTrib) nor use the Simples percentage.
            if self.op_simp_nac != '1' or any(p is None for p in percentages) or self.simples_percent is not None:
                raise ValueError('Percentuais federal, estadual e municipal são exclusivos de não optante do Simples e precisam ser informados os três.')
            return self
        if any(p is not None for p in percentages):
            raise ValueError('Percentuais federal/estadual/municipal informados fora da opção de não optante.')
        if self.op_simp_nac == '1':
            raise ValueError('Não optante do Simples deve informar os percentuais aproximados federal, estadual e municipal (regra E0713).')
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
    totals_mode: Literal['not_informed','simples_percent','percentages']
    include_provider_im: bool
    include_iss_rate: bool
    series: str = Field(pattern=SERIES_PATTERN)
    # 0.15.0: rates live in the profile (Lucro Presumido 0.65/3.00, Lucro Real 1.65/7.60); values are computed per note.
    pis_cofins: bool = False
    aliq_pis: Decimal | None = Field(default=None, gt=0, le=100, decimal_places=2)
    aliq_cofins: Decimal | None = Field(default=None, gt=0, le=100, decimal_places=2)

    @model_validator(mode='before')
    @classmethod
    def drop_legacy_percent(cls, data):
        # Profiles saved by 0.7.0 carried a fixed percentage; it is ignored from 0.7.1 on.
        if isinstance(data, dict):
            data = {k: v for k, v in data.items() if k not in ('simples_percent', 'tot_fed', 'tot_est', 'tot_mun')}
            # Only one value is legal per regime: ME/EPP -> Simples percentage (E0712); non-optant -> federal/state/
            # municipal percentages (E0713, 0.14.0); MEI -> not informed. Older saved profiles are brought forward.
            if data.get('op_simp_nac') in ('1', '2', '3'):
                data['totals_mode'] = {'3': 'simples_percent', '1': 'percentages', '2': 'not_informed'}[data['op_simp_nac']]
        return data

    @model_validator(mode='after')
    def coherent(self):
        if (self.op_simp_nac == '3') != (self.reg_ap_trib_sn is not None):
            raise ValueError('Informe o regime de apuração somente para ME/EPP optante pelo SN.')
        _check_pis_cofins(self)
        expected = {'3': 'simples_percent', '1': 'percentages', '2': 'not_informed'}[self.op_simp_nac]
        if self.totals_mode != expected:
            raise ValueError('Tributos aproximados: ME/EPP informa o percentual do Simples (E0712); não optante informa os percentuais federal, estadual e municipal (E0713); MEI não informa.')
        return self

    def choices(self, simples_percent, percentages=None):
        """Fiscal choices for one emission; the percentages are required exactly when the profile asks for them."""
        if (self.totals_mode == 'simples_percent') != (simples_percent is not None):
            raise ValueError('Informe o percentual aproximado do Simples desta emissão.' if self.totals_mode == 'simples_percent' else 'Esta empresa não informa percentual do Simples.')
        fed, est, mun = percentages or (None, None, None)
        if self.totals_mode == 'percentages':
            if None in (fed, est, mun):
                raise ValueError('Informe os percentuais aproximados de tributos federais, estaduais e municipais desta emissão.')
        elif any(p is not None for p in (fed, est, mun)):
            raise ValueError('Esta empresa não informa percentuais federal, estadual e municipal.')
        data = self.model_dump(exclude={'series'})
        return {**data, 'simples_percent': simples_percent, 'tot_fed': fed, 'tot_est': est, 'tot_mun': mun}

def check_instant(issued_at: datetime):
    if issued_at.utcoffset() is None:
        raise ValueError('Data de emissão exige fuso horário.')
    if issued_at > datetime.now(timezone.utc):
        raise ValueError('A data/hora de emissão não pode ser futura. Confira o horário de Brasília.')

def normalize_series(series: str) -> str:
    if not re.fullmatch(SERIES_PATTERN, series or ''):
        raise ValueError('Série inválida: use de 1 a 49999, faixa do aplicativo próprio (regra E0010). 50000 em diante é dos emissores do governo.')
    return str(int(series))

class _ProductionSeriesFix(etree.Resolver):
    # The official production tiposSimples writes the TSSerieDPS pattern as '^0{0,4}\\d{1,5}$'. In XSD regular
    # expressions ^ and $ are literal characters, so libxml2 would reject every series; the government's validator
    # treats them as anchors (series 70000 was authorized in production). Only that pattern is adjusted, in memory.
    BROKEN = r'<xs:pattern value="^0{0,4}\d{1,5}$"/>'
    FIXED = r'<xs:pattern value="0{0,4}\d{1,5}"/>'

    def resolve(self, url, pubid, context):
        if url.replace('\\', '/').rsplit('/', 1)[-1] != 'tiposSimples_v1.01.xsd':
            return None
        text = (PRODUCTION_SCHEMA_DIR / 'tiposSimples_v1.01.xsd').read_text(encoding='utf-8')
        if text.count(self.BROKEN) != 1:
            raise ValueError('XSD de produção diferente do esperado.')
        return self.resolve_string(text.replace(self.BROKEN, self.FIXED), context, base_url=url)

@lru_cache(maxsize=2)
def dps_schema(environment: str) -> etree.XMLSchema:
    parser = etree.XMLParser(resolve_entities=False, no_network=True, load_dtd=False)
    if environment == PRODUCTION:
        parser.resolvers.add(_ProductionSeriesFix())
    return etree.XMLSchema(etree.parse(str(SCHEMA_DIRS[environment] / 'DPS_v1.01.xsd'), parser))

def validate_dps(xml: bytes, environment: str):
    parser = etree.XMLParser(resolve_entities=False, no_network=True, load_dtd=False)
    document = etree.fromstring(xml, parser)
    if document.getroottree().docinfo.doctype: raise ValueError('DTD não permitida')
    dps_schema(environment).assertValid(document)

def build_preview(raw: dict, company: dict, options: PreviewOptions, tomador_address: dict | None = None) -> bytes:
    return build_dps(raw, company, options, options.own_company_cnpj, options.series, options.number, options.issued_at, 'Triade-Offline-0.7', tomador_address)

def dps_identifier(municipality: str, cnpj: str, series: str, number: str) -> str:
    return f"DPS{municipality}2{cnpj}{series.zfill(5)}{number.zfill(15)}"

def build_dps(raw: dict, company: dict, options: FiscalChoices, own_company_cnpj: str, series: str, number: str, issued_at: datetime, ver_aplic: str, tomador_address: dict | None = None, environment: str = RESTRICTED) -> bytes:
    if environment not in SCHEMA_DIRS: raise ValueError('Ambiente inválido.')
    series = normalize_series(series)
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
    header=[('tpAmb',environment),('dhEmi',issued_at.astimezone(BRASILIA).isoformat(timespec='seconds')),('verAplic',ver_aplic),('serie',series),('nDPS',number),('dCompet',row['competencia']),('tpEmit','1'),('finNFSe','0'),('cLocEmi',municipality)]
    if environment == PRODUCTION: header=[item for item in header if item[0] != 'finNFSe']  # 2026-02-09 layout: finNFSe only inside IBSCBS
    for key,value in header:
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
    if environment == PRODUCTION:
        add(code,'xDescServ',row['descricao_servico'])
        if row['codigo_nbs']:add(code,'cNBS',row['codigo_nbs'])
    else:
        if row['codigo_nbs']:add(code,'cNBS',row['codigo_nbs'])
        add(code,'xDescServ',row['descricao_servico'])
    if row['observacoes']:add(add(serv,'infoCompl'),'xInfComp',row['observacoes'])
    values=add(info,'valores');add(add(values,'vServPrest'),'vServ',row['valor_servico'])
    tax=add(values,'trib');municipal=add(tax,'tribMun')
    add(municipal,'tribISSQN','1');add(municipal,'tpRetISSQN','1')
    if options.include_iss_rate:add(municipal,'pAliq',row['iss_aliquota'])
    if options.pis_cofins:
        # Base = service value (no deductions in this generator; rule E0677). Values = base x rate (E0694/E0696).
        base=Decimal(row['valor_servico']);cents=Decimal('0.01')
        group=add(add(tax,'tribFed'),'piscofins')
        add(group,'CST','01')  # taxable operation at the basic rate
        add(group,'vBCPisCofins',format(base,'.2f'))
        add(group,'pAliqPis',format(options.aliq_pis,'.2f'));add(group,'pAliqCofins',format(options.aliq_cofins,'.2f'))
        add(group,'vPis',format((base*options.aliq_pis/100).quantize(cents,ROUND_HALF_UP),'.2f'))
        add(group,'vCofins',format((base*options.aliq_cofins/100).quantize(cents,ROUND_HALF_UP),'.2f'))
        add(group,'tpRetPisCofins','0')  # PIS/COFINS/CSLL not retained
    total=add(tax,'totTrib')
    if options.totals_mode=='not_informed':add(total,'indTotTrib','0')
    elif options.totals_mode=='percentages':
        group=add(total,'pTotTrib')
        add(group,'pTotTribFed',format(options.tot_fed,'.2f'));add(group,'pTotTribEst',format(options.tot_est,'.2f'));add(group,'pTotTribMun',format(options.tot_mun,'.2f'))
    else:add(total,'pTotTribSN',format(options.simples_percent,'.2f'))
    xml=etree.tostring(root,encoding='UTF-8',xml_declaration=True,pretty_print=False)
    try:validate_dps(xml,environment)
    except (etree.DocumentInvalid,etree.XMLSyntaxError):
        raise ValueError(f'XML incompatível com o XSD de {ENVIRONMENT_NAMES[environment]}. Confira os campos e códigos; nenhum arquivo foi enviado.') from None
    return xml
