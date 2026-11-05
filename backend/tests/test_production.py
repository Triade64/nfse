"""0.10.0: emission in production (tpAmb 1) per company, alongside the restricted environment (tpAmb 2)."""
from datetime import datetime, timezone, timedelta
from lxml import etree
from sqlalchemy import select
from app.db import Session
from app.models import Audit, DPS
from app.dps_preview import build_dps, FiscalChoices, validate_dps, normalize_series
from test_connector_site import KEY, PROFILE, ticket, as_connector, nfse_for, result

NS={'n':'http://www.sped.fazenda.gov.br/nfse'}
CHOICES=FiscalChoices(op_simp_nac='3',reg_ap_trib_sn='1',reg_esp_trib='0',totals_mode='simples_percent',simples_percent='6.54',include_provider_im=False,include_iss_rate=False)
COMPANY={'cnpj':'11222333000181','config':{'municipio_ibge':'4205704'}}

def build(row,environment,series='1'):
    raw={**row,'codigo_nbs':'113022100'}
    xml=build_dps(raw,COMPANY,CHOICES,'11222333000181',series,'1',datetime.now(timezone.utc)-timedelta(minutes=5),'Triade-Web-0.10',environment=environment)
    return etree.fromstring(xml)

def names(parent):
    return [etree.QName(x).localname for x in parent]

def test_production_dps_follows_the_production_layout(row):
    prod=build(row,'1');rest=build(row,'2')
    assert prod.findtext('n:infDPS/n:tpAmb',namespaces=NS)=='1' and rest.findtext('n:infDPS/n:tpAmb',namespaces=NS)=='2'
    # Layout 2026-02-09 (production): no finNFSe in infDPS; xDescServ before cNBS. Layout 2026-10-20 (restricted): the opposite.
    assert 'finNFSe' not in names(prod.find('n:infDPS',NS)) and 'finNFSe' in names(rest.find('n:infDPS',NS))
    assert names(prod.find('n:infDPS/n:serv/n:cServ',NS))==['cTribNac','xDescServ','cNBS']
    assert names(rest.find('n:infDPS/n:serv/n:cServ',NS))==['cTribNac','cNBS','xDescServ']
    # Same Id in both environments: the DPS identifier carries no environment.
    assert prod.find('n:infDPS',NS).get('Id')==rest.find('n:infDPS',NS).get('Id')

def test_each_layout_is_rejected_by_the_other_environment_schema(row):
    prod=etree.tostring(build(row,'1'));rest=etree.tostring(build(row,'2'))
    validate_dps(prod,'1');validate_dps(rest,'2')
    for xml,env in ((prod,'2'),(rest,'1')):
        try:validate_dps(xml,env)
        except etree.DocumentInvalid:pass
        else:raise AssertionError('layout aceito no ambiente errado')

def test_production_schema_accepts_own_application_series_despite_official_pattern(row):
    # The official production pattern '^0{0,4}\d{1,5}$' only works with ^/$ as anchors (government validator behaviour).
    for series in ('1','00001','49999'):build(row,'1',series)

def test_series_outside_own_application_range_is_refused():
    for bad in ('0','00000','50000','70000','89999','99999','123456','1a'):
        try:normalize_series(bad)
        except ValueError as exc:assert 'E0010' in str(exc)
        else:raise AssertionError(bad)
    assert normalize_series('00042')=='42'

def put_company(admin,company,**config):
    return admin.put(f'/api/companies/{company["id"]}',json={'cnpj':company['cnpj'],'name':company['name'],'config':{**company['config'],**config}})

def make_note(admin,row,**change):
    b=admin.post('/api/batches',json={'name':'x','rows':[{**row,**change}]}).json()
    return next(x for x in admin.get('/api/notes').json() if x['batch_id']==b['id'])

def emit(admin,n,**change):
    return admin.post(f'/api/notes/{n["id"]}/emit',json={'batch_revision':n['batch_revision'],'expected_raw':n['raw'],'confirm':True,'simples_percent':'6.54',**change})

def series(admin,company,environment,next_number=1):
    return admin.put(f'/api/companies/{company["id"]}/dps-series',json={'series':'1','next_number':next_number,'expected_revision':None,'confirm_unused':True,'environment':environment})

def test_company_environment_is_validated_and_audited(admin,company):
    assert put_company(admin,company,ambiente='3').status_code==422
    assert put_company(admin,company,ambiente='1').status_code==422  # needs the fiscal profile first
    r=put_company(admin,company,perfil_fiscal=PROFILE,ambiente='1');assert r.status_code==200 and r.json()['config']['ambiente']=='1'
    with Session() as db:
        change=db.scalar(select(Audit).where(Audit.action=='change_environment'))
        assert change is not None and change.info=={'from':'2','to':'1'}
    assert put_company(admin,company,perfil_fiscal={**PROFILE,'series':'70000'},ambiente='1').status_code==422  # E0010

def test_production_emission_requires_confirmation_and_own_series(admin,company,row):
    assert put_company(admin,company,perfil_fiscal=PROFILE).status_code==200
    assert series(admin,company,'2').status_code==200
    test=emit(admin,make_note(admin,row));assert test.status_code==200,test.text
    assert test.json()['environment']=='2' and test.json()['number']==1
    assert put_company(admin,company,perfil_fiscal=PROFILE,ambiente='1').status_code==200
    n=make_note(admin,row,descricao_servico='SERVIÇO REAL')
    r=emit(admin,n);assert r.status_code==422 and 'NOTA REAL' in r.json()['detail']
    r=emit(admin,n,confirm_production=True);assert r.status_code==409 and 'produção (validade jurídica)' in r.json()['detail']
    assert series(admin,company,'1').status_code==200
    r=emit(admin,n,confirm_production=True);assert r.status_code==200,r.text
    real=r.json();assert real['environment']=='1' and real['series']=='1' and real['number']==1
    assert real['identifier']==test.json()['identifier']  # same Id, other environment
    with Session() as db:
        xml=db.get(DPS,real['id']).xml
    assert '<tpAmb>1</tpAmb>' in xml and '<finNFSe>' not in xml
    # Series are independent per environment.
    listed={(s['environment'],s['series']):s['next_number'] for s in admin.get(f'/api/companies/{company["id"]}/dps-series').json()}
    assert listed=={('1','1'):2,('2','1'):2}

def test_legacy_draft_reservation_is_blocked_in_production(admin,company,row):
    put_company(admin,company,perfil_fiscal=PROFILE,ambiente='1');series(admin,company,'1')
    n=make_note(admin,row)
    body={**{k:v for k,v in PROFILE.items() if k!='series'},'simples_percent':'6.54','series':'1','revision':n['batch_revision'],'expected_raw':n['raw'],'own_company_cnpj':company['cnpj'],'confirm_reserve':True,'confirm_scope':True}
    r=admin.post(f'/api/drafts/{n["id"]}/dps',json=body);assert r.status_code==409 and 'tela Notas' in r.json()['detail']

def test_connector_result_must_match_the_dps_environment(admin,company,row):
    put_company(admin,company,perfil_fiscal=PROFILE,ambiente='1');series(admin,company,'1')
    dps_id=emit(admin,make_note(admin,row),confirm_production=True).json()['id']
    token,_=ticket(admin,[dps_id]);h=as_connector(admin,token)
    job=admin.get('/api/connector/jobs',headers=h).json()['jobs'][0];assert job['environment']=='1'
    nfse=nfse_for(job['xml'])
    assert result(admin,h,dps_id,access_key=KEY,nfse_xml_b64=nfse).status_code==409  # 'Autorizada em teste' label
    def as_test(dps):dps.find('n:infDPS/n:tpAmb',NS).text='2'
    r=result(admin,h,dps_id,state='Autorizada em produção',access_key=KEY,nfse_xml_b64=nfse_for(job['xml'],mutate=as_test))
    assert r.status_code==422  # NFS-e from the other environment
    r=result(admin,h,dps_id,state='Autorizada em produção',access_key=KEY,nfse_xml_b64=nfse);assert r.status_code==200,r.text
    assert r.json()['status']=='Autorizada' and r.json()['has_danfse']

def test_restricted_result_label_cannot_report_production(admin,company,row):
    put_company(admin,company,perfil_fiscal=PROFILE);series(admin,company,'2')
    dps_id=emit(admin,make_note(admin,row)).json()['id']
    token,_=ticket(admin,[dps_id]);h=as_connector(admin,token)
    assert result(admin,h,dps_id,state='Rejeitada em produção',http_status=400,codes='E0001').status_code==409
