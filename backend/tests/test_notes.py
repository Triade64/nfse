import uuid
from lxml import etree
from sqlalchemy import select
from app.db import Session
from app.models import DPS, Draft, Batch, Audit

PROFILE={'op_simp_nac':'3','reg_ap_trib_sn':'1','reg_esp_trib':'0','totals_mode':'simples_percent','include_provider_im':False,'include_iss_rate':False,'series':'1'}
CONFIG={'municipio_ibge':'4205704','regime':'Simples Nacional','inscricao_municipal':'123'}

def notes(admin):
    r=admin.get('/api/notes');assert r.status_code==200,r.text;return r.json()

def note(admin,row):
    r=admin.post('/api/batches',json={'name':'Nota','rows':[row]});assert r.status_code==200,r.text
    return next(n for n in notes(admin) if n['batch_id']==r.json()['id'])

def duplicate(admin,ids,competencia,**change):
    return admin.post('/api/notes/duplicate',json={'draft_ids':ids,'competencia':competencia,'confirm_review':True,'request_id':str(uuid.uuid4()),**change})

def set_profile(admin,company,profile=PROFILE):
    r=admin.put(f'/api/companies/{company["id"]}',json={'cnpj':company['cnpj'],'name':company['name'],'config':{**CONFIG,'perfil_fiscal':profile}})
    return r

def emit(admin,n,**change):
    return admin.post(f'/api/notes/{n["id"]}/emit',json={'batch_revision':n['batch_revision'],'expected_raw':n['raw'],'confirm':True,'simples_percent':'6.54',**change})

def test_list_shows_ready_note_with_situation(admin,company,row):
    n=note(admin,row)
    assert n['situation']=='Pronta' and n['editable'] and n['dps'] is None and n['amount_cents']==123456
    bad=note(admin,{**row,'documento_tomador':'11144477735','valor_servico':'abc'})
    assert bad['situation']=='Com inconsistência' and bad['errors']

def test_duplicate_to_new_competence_creates_one_validated_batch_per_note(admin,company,row):
    a=note(admin,row);b=note(admin,{**row,'documento_tomador':'11144477735','nome_tomador':'OUTRO'})
    r=duplicate(admin,[a['id'],b['id']],'2026-02-10');assert r.status_code==200,r.text
    created=[n for n in notes(admin) if n['id'] in r.json()['created']]
    assert len(created)==2 and {n['raw']['competencia'] for n in created}=={'2026-02-10'}
    assert all(n['situation']=='Pronta' for n in created) and len({n['batch_id'] for n in created})==2
    assert {n['raw']['valor_servico'] for n in created}=={'1234.56'}  # taxes and values copied literally

def test_duplicate_same_competence_is_refused_without_creating_anything(admin,company,row):
    a=note(admin,row)
    r=duplicate(admin,[a['id']],row['competencia']);assert r.status_code==409 and 'nota igual' in r.json()['detail']
    assert len(notes(admin))==1
    assert duplicate(admin,[a['id']],'2026-03-10',confirm_review=False).status_code==422

def test_duplicate_is_idempotent_per_request(admin,company,row):
    a=note(admin,row);body={'draft_ids':[a['id']],'competencia':'2026-04-10','confirm_review':True,'request_id':str(uuid.uuid4())}
    first=admin.post('/api/notes/duplicate',json=body).json()
    again=admin.post('/api/notes/duplicate',json=body).json()
    assert again['repeated'] and again['created']==first['created'] and len(notes(admin))==2
    assert admin.post('/api/notes/duplicate',json={**body,'competencia':'2026-05-10'}).status_code==409

def test_fiscal_profile_is_validated(admin,company):
    assert set_profile(admin,company,{**PROFILE,'op_simp_nac':'1'}).status_code==422  # reg_ap_trib_sn only for ME/EPP
    assert set_profile(admin,company,{**PROFILE,'series':'99999'}).status_code==422
    assert set_profile(admin,company,{**PROFILE,'extra':'x'}).status_code==422
    r=set_profile(admin,company);assert r.status_code==200 and r.json()['config']['perfil_fiscal']['series']=='1'

def test_emit_uses_profile_and_auto_revalidates_after_profile_change(admin,company,row):
    n=note(admin,row)
    assert emit(admin,n).status_code==422  # no profile yet
    set_profile(admin,company)  # bumps company revision: the note is now stale and must be revalidated automatically
    admin.put(f'/api/companies/{company["id"]}/dps-series',json={'series':'1','next_number':2,'expected_revision':None,'confirm_unused':True})
    n=next(x for x in notes(admin) if x['id']==n['id'])
    r=emit(admin,n);assert r.status_code==200,r.text
    assert r.json()['number']==2 and r.json()['series']=='1'
    xml=etree.fromstring(admin.get(f'/api/dps/{r.json()["id"]}/xml').content)
    assert xml.find('.//{*}prest/{*}IM') is None and xml.find('.//{*}pAliq') is None
    assert xml.find('.//{*}pTotTribSN').text=='6.54'
    after=next(x for x in notes(admin) if x['id']==n['id'])
    assert after['situation']=='DPS reservada' and not after['editable'] and after['dps']['number']==2
    assert emit(admin,after).json()['existing']

def test_emit_rejects_stale_list_and_non_admin(admin,company,row):
    set_profile(admin,company)
    admin.put(f'/api/companies/{company["id"]}/dps-series',json={'series':'1','next_number':1,'expected_revision':None,'confirm_unused':True})
    n=note(admin,row)
    assert emit(admin,n,expected_raw={**n['raw'],'valor_servico':'1.00'}).status_code==409
    assert emit(admin,n,confirm=False).status_code==422
    admin.post('/api/users',json={'username':'operador3','password':'Senha-ficticia-321!','role':'operator','company_ids':[company['id']]})
    admin.post('/api/logout');admin.post('/api/login',json={'username':'operador3','password':'Senha-ficticia-321!'})
    assert emit(admin,n).status_code==403
    assert notes(admin)==[]  # operators see only their own notes

def test_simples_percent_is_required_per_emission_and_prefilled_from_last_use(admin,company,row):
    # E0712: ME/EPP cannot send "not informed"; 0.7.0 profiles saved that way are brought forward.
    r=set_profile(admin,company,{**PROFILE,'totals_mode':'not_informed','simples_percent':'6.00'})
    assert r.status_code==200 and r.json()['config']['perfil_fiscal']['totals_mode']=='simples_percent' and 'simples_percent' not in r.json()['config']['perfil_fiscal']
    admin.put(f'/api/companies/{company["id"]}/dps-series',json={'series':'1','next_number':1,'expected_revision':None,'confirm_unused':True})
    assert admin.get(f'/api/companies/{company["id"]}/fiscal-defaults').json()=={'last_simples_percent':None}
    n=note(admin,row)
    missing=emit(admin,n,simples_percent=None);assert missing.status_code==422 and 'percentual' in missing.json()['detail']
    assert emit(admin,n,simples_percent='101').status_code==422
    n=next(x for x in notes(admin) if x['id']==n['id'])
    assert emit(admin,n,simples_percent='7.12').status_code==200
    assert admin.get(f'/api/companies/{company["id"]}/fiscal-defaults').json()=={'last_simples_percent':'7.12'}

def test_non_simples_profile_refuses_percent(admin,company,row):
    profile={**PROFILE,'op_simp_nac':'1','reg_ap_trib_sn':None,'totals_mode':'not_informed'}
    assert set_profile(admin,company,profile).status_code==200
    admin.put(f'/api/companies/{company["id"]}/dps-series',json={'series':'1','next_number':1,'expected_revision':None,'confirm_unused':True})
    n=note(admin,row)
    assert emit(admin,n).status_code==422  # percentage sent for a non-SN company
    n=next(x for x in notes(admin) if x['id']==n['id'])
    r=emit(admin,n,simples_percent=None);assert r.status_code==200,r.text
    xml=etree.fromstring(admin.get(f'/api/dps/{r.json()["id"]}/xml').content)
    assert xml.find('.//{*}indTotTrib').text=='0'
