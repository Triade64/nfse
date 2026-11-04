import uuid
from sqlalchemy import select,func
from app.db import Session
from app.models import Batch,Job

def base(c,row):
    b=c.post('/api/batches',json={'name':'Mês anterior','rows':[row,{**row,'descricao_servico':'SEGUNDO SERVICO'}]}).json()
    return c.get(f'/api/batches/{b["id"]}').json()
def payload(b,**kwargs):
    return {'name':'Novo mês','competencia':'2026-02-10','draft_ids':[d['id'] for d in b['rows']],'source_revision':b['revision'],'keep_taxes':True,'confirm_tax_review':True,'request_id':str(uuid.uuid4()),**kwargs}

def test_repeat_preserves_clients_services_values_taxes_and_original(admin,company,row):
    b=base(admin,row);data=payload(b)
    r=admin.post(f'/api/batches/{b["id"]}/repeat',json=data)
    assert r.status_code==200,r.text
    new=r.json();assert new['id']!=b['id'] and new['status']=='Rascunho'
    for old,copy in zip(b['rows'],new['rows']):
        assert copy['id']!=old['id'] and copy['raw']=={**old['raw'],'competencia':'2026-02-10'}
        assert copy['fingerprint'] is None and copy['status']=='Rascunho'
    assert admin.get(f'/api/batches/{b["id"]}').json()==b
    with Session() as db:assert db.scalar(select(func.count()).select_from(Job))==0
    assert admin.post(f'/api/batches/{new["id"]}/simulate').status_code==409
    assert admin.post(f'/api/batches/{new["id"]}/validate').status_code==200
    assert admin.get(f'/api/batches/{new["id"]}').json()['review']['count']==2

def test_selection_and_replay_do_not_create_extra_batch(admin,company,row):
    b=base(admin,row);data=payload(b,draft_ids=[b['rows'][1]['id']])
    first=admin.post(f'/api/batches/{b["id"]}/repeat',json=data)
    second=admin.post(f'/api/batches/{b["id"]}/repeat',json=data)
    assert first.status_code==second.status_code==200 and first.json()['id']==second.json()['id']
    assert len(first.json()['rows'])==1
    assert admin.post(f'/api/batches/{b["id"]}/repeat',json={**data,'competencia':'2026-03-10'}).status_code==409
    with Session() as db:assert db.scalar(select(func.count()).select_from(Batch))==2

def test_copy_taxes_requires_confirmation_and_current_company(admin,company,row):
    b=base(admin,row)
    assert admin.post(f'/api/batches/{b["id"]}/repeat',json=payload(b,confirm_tax_review=False)).status_code==422
    admin.put(f'/api/companies/{company["id"]}',json={'cnpj':company['cnpj'],'name':company['name'],'config':{**company['config'],'regime':'Lucro Presumido'}})
    assert admin.post(f'/api/batches/{b["id"]}/repeat',json=payload(b)).status_code==409
    r=admin.post(f'/api/batches/{b["id"]}/repeat',json=payload(b,keep_taxes=False,confirm_tax_review=False))
    assert r.status_code==200,r.text
    raw=r.json()['rows'][0]['raw'];assert raw['nome_tomador']==row['nome_tomador']
    assert raw['iss_aliquota']==raw['iss_retido']==raw['codigo_tributacao_nacional']=='' and raw['retencoes']=='{}'

def test_invalid_selection_same_date_and_stale_revision(admin,company,row):
    b=base(admin,row);url=f'/api/batches/{b["id"]}/repeat'
    assert admin.post(url,json=payload(b,competencia=row['competencia'])).status_code==422
    assert admin.post(url,json=payload(b,source_revision=999)).status_code==409
    assert admin.post(url,json=payload(b,draft_ids=[999999])).status_code==422
    assert admin.post(url,json=payload(b,draft_ids=[b['rows'][0]['id']]*2)).status_code==422

def test_no_access_to_other_users_batch(admin,company,row):
    b=base(admin,row)
    admin.post('/api/users',json={'username':'outro-operador','password':'Senha-ficticia-456!','role':'operator','company_ids':[company['id']]})
    admin.post('/api/logout');admin.post('/api/login',json={'username':'outro-operador','password':'Senha-ficticia-456!'})
    assert admin.post(f'/api/batches/{b["id"]}/repeat',json=payload(b)).status_code==403
