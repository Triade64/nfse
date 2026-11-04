from app.db import Session
from app.models import Draft
from sqlalchemy import select

def save(c,rows,name='Preenchimento no site'):
    return c.post('/api/preparations',json={'name':name,'rows':[{'raw':r} for r in rows]})

def test_incomplete_persists_without_approval(admin,company):
    r=save(admin,[{'cnpj_emitente':company['cnpj'],'nome_tomador':'Ainda incompleto'}])
    assert r.status_code==200,r.text
    b=r.json();d=b['rows'][0]
    assert b['status']=='Rascunho' and d['status']=='Rascunho'
    loaded=admin.get(f'/api/batches/{b["id"]}').json()
    assert loaded['rows'][0]['raw']['nome_tomador']=='Ainda incompleto'
    assert loaded['review']['count']==0
    assert admin.post(f'/api/batches/{b["id"]}/approve',json={'digest':loaded['review']['digest'],'confirm_simulation':True}).status_code==409

def test_grid_add_remove_and_stale_revision(admin,company,row):
    b=save(admin,[row]).json();id=b['id'];d=b['rows'][0]
    added={**row,'descricao_servico':'SEGUNDA NOTA FICTICIA'}
    payload={'name':'Lote editado','revision':b['revision'],'rows':[{'id':d['id'],'raw':row},{'raw':added}]}
    r=admin.put(f'/api/preparations/{id}',json=payload)
    assert r.status_code==200,r.text
    b2=r.json();assert len(b2['rows'])==2 and b2['rows'][0]['id']==d['id']
    assert admin.put(f'/api/preparations/{id}',json=payload).status_code==409
    kept=b2['rows'][1]
    r=admin.put(f'/api/preparations/{id}',json={'name':'Somente segunda','revision':b2['revision'],'rows':[{'id':kept['id'],'raw':kept['raw']}]})
    assert r.status_code==200 and len(r.json()['rows'])==1
    assert r.json()['rows'][0]['id']==kept['id']
    assert admin.get(f'/api/batches/{id}').json()['review']['count']==0

def test_grid_edit_revokes_approval_then_validate(admin,company,row):
    b=save(admin,[row]).json();id=b['id']
    assert admin.post(f'/api/batches/{id}/validate').status_code==200
    checked=admin.get(f'/api/batches/{id}').json()
    assert checked['review']['count']==1
    assert admin.post(f'/api/batches/{id}/approve',json={'digest':checked['review']['digest'],'confirm_simulation':True}).status_code==200
    r=admin.put(f'/api/preparations/{id}',json={'name':'Corrigido','revision':checked['revision'],'rows':[{'id':checked['rows'][0]['id'],'raw':{**row,'valor_servico':'20,00'}}]})
    assert r.status_code==200,r.text
    assert r.json()['approval_digest'] is None and r.json()['status']=='Rascunho'
    assert admin.post(f'/api/batches/{id}/simulate').status_code==409
    assert admin.post(f'/api/batches/{id}/validate').status_code==200
    assert admin.get(f'/api/batches/{id}').json()['review']['total_cents']==2000

def test_cannot_edit_queued_or_reference_foreign_line(admin,company,row):
    b=save(admin,[row]).json();other=save(admin,[row]).json()
    payload={'name':'Invalido','revision':b['revision'],'rows':[{'id':other['rows'][0]['id'],'raw':row}]}
    assert admin.put(f'/api/preparations/{b["id"]}',json=payload).status_code==422
    admin.post(f'/api/batches/{b["id"]}/validate');v=admin.get(f'/api/batches/{b["id"]}').json()
    admin.post(f'/api/batches/{b["id"]}/approve',json={'digest':v['review']['digest'],'confirm_simulation':True});admin.post(f'/api/batches/{b["id"]}/simulate')
    assert admin.put(f'/api/preparations/{b["id"]}',json={'name':'Bloqueado','revision':v['revision'],'rows':[{'id':b['rows'][0]['id'],'raw':row}]}).status_code==409

def test_grid_company_scope(admin,company,row):
    admin.post('/api/users',json={'username':'sem-escopo','password':'Senha-ficticia-456!','role':'operator','company_ids':[]})
    admin.post('/api/logout');admin.post('/api/login',json={'username':'sem-escopo','password':'Senha-ficticia-456!'})
    assert save(admin,[row]).status_code==403
    with Session() as db:assert not list(db.scalars(select(Draft)))
