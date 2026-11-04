from sqlalchemy import select
from app.db import Session
from app.models import Audit, Draft, Job, DPS

def make(client,row,rows=None):
    r=client.post('/api/batches',json={'name':'Teste ficticio exclusao','rows':rows or [row]})
    assert r.status_code==200,r.text
    return client.get('/api/batches/'+str(r.json()['id'])).json()

def remove(client,b,id=None):
    return client.delete(f'/api/drafts/{id or b["rows"][0]["id"]}?revision={b["revision"]}')

def test_delete_last_inconsistent_draft_keeps_original_and_audit(admin,company,row):
    original=make(admin,row);duplicate=make(admin,row)
    assert duplicate['rows'][0]['status']=='Com inconsistência'
    assert remove(admin,duplicate).status_code==200
    assert admin.get(f'/api/batches/{duplicate["id"]}').json()['rows']==[]
    assert admin.get(f'/api/batches/{original["id"]}').json()==original
    with Session() as db:
        a=db.scalar(select(Audit).where(Audit.action=='delete_draft'))
        assert a.entity_id==duplicate['rows'][0]['id'] and a.info['batch_id']==duplicate['id']
        assert db.get(Draft,original['rows'][0]['id']) is not None

def test_delete_invalidates_approval_and_revalidates_remaining(admin,company,row):
    b=make(admin,row,[row,{**row,'descricao_servico':'SEGUNDO SERVICO FICTICIO'}])
    assert admin.post(f'/api/batches/{b["id"]}/approve',json={'digest':b['review']['digest'],'confirm_simulation':True}).status_code==200
    b=admin.get(f'/api/batches/{b["id"]}').json()
    assert remove(admin,b).status_code==200
    new=admin.get(f'/api/batches/{b["id"]}').json()
    assert len(new['rows'])==1 and new['approved_by'] is None and new['approval_digest'] is None
    assert new['revision']>b['revision'] and new['status']=='Aguardando aprovação'
    assert admin.post(f'/api/batches/{b["id"]}/simulate').status_code==409

def test_delete_rejects_stale_revision_and_other_owner(admin,company,row):
    b=make(admin,row)
    assert admin.delete(f'/api/drafts/{b["rows"][0]["id"]}?revision=999').status_code==409
    admin.post('/api/users',json={'username':'operador-teste','password':'Senha-ficticia-456!','role':'operator','company_ids':[company['id']]})
    admin.post('/api/logout');admin.post('/api/login',json={'username':'operador-teste','password':'Senha-ficticia-456!'})
    assert remove(admin,b).status_code==403

def test_delete_blocks_queued_and_even_hidden_jobs_or_dps(admin,company,row):
    b=make(admin,row)
    with Session() as db:
        db.add(Job(draft_id=b['rows'][0]['id'],status='Na fila'));db.commit()
    assert remove(admin,b).status_code==409
    with Session() as db:
        j=db.scalar(select(Job));db.delete(j)
        db.add(DPS(draft_id=b['rows'][0]['id'],environment='restricted',identifier='FICTICIO'));db.commit()
    assert remove(admin,b).status_code==409
