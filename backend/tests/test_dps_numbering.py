import hashlib
from lxml import etree
from sqlalchemy import select
from app.db import Session
from app.models import DPS, DpsSeries, Audit
from app.dps_preview import SCHEMA_DIR

FISCAL=dict(op_simp_nac='3',reg_ap_trib_sn='1',reg_esp_trib='0',totals_mode='simples_percent',simples_percent='6.00',include_provider_im=False,include_iss_rate=False)

def batch_with(admin,rows):
    b=admin.post('/api/batches',json={'name':'Lote fictício','rows':rows});assert b.status_code==200,b.text
    return admin.get('/api/batches/'+str(b.json()['id'])).json()

def reserve(admin,b,d,**change):
    body={**FISCAL,'revision':b['revision'],'expected_raw':d['raw'],'own_company_cnpj':'11222333000181','series':'1','confirm_reserve':True,'confirm_scope':True,**change}
    return admin.post(f'/api/drafts/{d["id"]}/dps',json=body)

def configure(admin,company,next_number,expected=None,series='1'):
    return admin.put(f'/api/companies/{company["id"]}/dps-series',json={'series':series,'next_number':next_number,'expected_revision':expected,'confirm_unused':True})

def test_reservation_is_sequential_idempotent_and_stores_exact_xml(admin,company,row):
    assert configure(admin,company,42).status_code==200
    b=batch_with(admin,[row,{**row,'documento_tomador':'11144477735','nome_tomador':'OUTRO TOMADOR'}])
    first=reserve(admin,b,b['rows'][0]);assert first.status_code==200,first.text
    second=reserve(admin,b,b['rows'][1]);assert second.status_code==200,second.text
    assert (first.json()['number'],second.json()['number'])==(42,43)
    assert first.json()['identifier']=='DPS420570421122233300018100001000000000000042'
    assert 'xml' not in first.json() and first.json()['status']=='Reservada'
    again=reserve(admin,b,b['rows'][0]);assert again.json()['existing'] and again.json()['number']==42
    xml=admin.get(f'/api/dps/{first.json()["id"]}/xml');assert xml.status_code==200
    assert hashlib.sha256(xml.content).hexdigest()==first.json()['xml_sha256']
    root=etree.fromstring(xml.content)
    etree.XMLSchema(etree.parse(str(SCHEMA_DIR/'DPS_v1.01.xsd'))).assertValid(root)
    assert root.find('.//{*}nDPS').text=='42' and root.find('.//{*}dhEmi').text.endswith('-03:00')
    with Session() as db:
        assert db.scalar(select(DpsSeries)).next_number==44
        assert len(list(db.scalars(select(Audit).where(Audit.action=='reserve_dps'))))==2
        assert all('xml' not in a.info for a in db.scalars(select(Audit)))

def test_series_never_moves_back_or_below_reserved(admin,company,row):
    s=configure(admin,company,10).json()
    assert configure(admin,company,5,s['revision']).status_code==409
    assert configure(admin,company,20,None).status_code==409  # stale: series already exists
    b=batch_with(admin,[row]);assert reserve(admin,b,b['rows'][0]).json()['number']==10
    with Session() as db:rev=db.scalar(select(DpsSeries)).revision
    assert configure(admin,company,11,rev).status_code==200
    assert configure(admin,company,12,rev).status_code==409

def test_reservation_requires_configured_series_valid_draft_and_current_versions(admin,company,row):
    b=batch_with(admin,[row]);d=b['rows'][0]
    assert reserve(admin,b,d).status_code==409  # no series configured
    configure(admin,company,1)
    assert reserve(admin,b,d,revision=b['revision']+1).status_code==409
    assert reserve(admin,b,d,expected_raw={}).status_code==409
    assert reserve(admin,b,d,confirm_reserve=False).status_code==422
    assert reserve(admin,b,d,own_company_cnpj='00000000000000').status_code==422
    assert reserve(admin,b,d,iss_retido='sim').status_code==422  # extra field forbidden
    bad=batch_with(admin,[{**row,'valor_servico':'abc'}])
    assert reserve(admin,bad,bad['rows'][0]).status_code==422
    with Session() as db:
        assert not list(db.scalars(select(DPS))) and db.scalar(select(DpsSeries)).next_number==1

def test_failed_xml_build_does_not_consume_a_number(admin,company,row):
    configure(admin,company,7)
    b=batch_with(admin,[{**row,'retencoes':'{"irrf":"1.00"}'}])
    assert reserve(admin,b,b['rows'][0]).status_code==422
    with Session() as db:assert db.scalar(select(DpsSeries)).next_number==7

def test_batch_with_reserved_dps_is_locked(admin,company,row):
    configure(admin,company,1)
    b=batch_with(admin,[row]);d=b['rows'][0]
    assert reserve(admin,b,d).status_code==200
    assert admin.put(f'/api/drafts/{d["id"]}',json={'raw':d['raw'],'revision':b['revision']}).status_code==409
    assert admin.post(f'/api/batches/{b["id"]}/validate').status_code==409
    assert admin.put(f'/api/preparations/{b["id"]}',json={'name':'x','revision':b['revision'],'rows':[{'id':d['id'],'raw':d['raw']}]}).status_code==409
    assert admin.delete(f'/api/drafts/{d["id"]}?revision={b["revision"]}').status_code==409

def test_non_admin_cannot_reserve_or_read_xml(admin,company,row):
    configure(admin,company,1)
    b=batch_with(admin,[row]);r=reserve(admin,b,b['rows'][0]).json()
    assert admin.post('/api/users',json={'username':'operador','password':'Senha-ficticia-456!','role':'operator','company_ids':[company['id']]}).status_code==200
    admin.post('/api/logout');admin.post('/api/login',json={'username':'operador','password':'Senha-ficticia-456!'})
    assert admin.get(f'/api/dps/{r["id"]}/xml').status_code==403
    assert configure(admin,company,99).status_code==403
    assert reserve(admin,b,b['rows'][0]).status_code==403
