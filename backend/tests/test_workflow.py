import io
import zipfile
import sqlite3
from openpyxl import load_workbook
from sqlalchemy import select
from app.main import tick
from app.db import Session
from app.models import Job, Draft, NFSe, DPS
from app.validation import normalize,valid_document,HEADERS
from app.fiscal import emit, FiscalIntegrationUnavailable,validate_xml
import pytest

def batch(c,row):
    r=c.post('/api/batches',json={'name':'Lote fictício','rows':[row]})
    assert r.status_code==200,r.text
    return c.get('/api/batches/'+str(r.json()['id'])).json()
def approve(c,b,**kwargs):
    return c.post(f'/api/batches/{b["id"]}/approve',json={'digest':b['review']['digest'],'confirm_simulation':True,**kwargs})

def test_documents_and_decimal(row):
    assert valid_document('11.222.333/0001-81')
    assert valid_document('529.982.247-25')
    assert not valid_document('11111111111')
    assert not valid_document('52998224726')
    assert not valid_document('AA222333000181')
    raw,errors,amount,fp=normalize(row)
    assert not errors and amount==123456
    assert raw['valor_servico']=='1234.56'
    for bad in ['NaN','Infinity','-1','1.999','0']:
        assert normalize({**row,'valor_servico':bad})[1]

def test_auth_and_origin(client):
    assert client.get('/api/companies').status_code==401
    assert client.post('/api/setup',json={'username':'admin','password':'123456789012'},headers={'X-Requested-With':''}).status_code==403
    assert client.post('/api/setup',json={'username':'admin','password':'123456789012'},headers={'Origin':'https://evil.invalid'}).status_code==403

def test_setup_only_once(admin):
    assert admin.post('/api/setup',json={'username':'outro','password':'123456789012'}).status_code==409
    assert 'password_hash' not in admin.get('/api/me').json()
    admin.post('/api/logout')
    assert admin.get('/api/me').status_code==401
    assert admin.post('/api/login',json={'username':'administrador','password':'Senha-ficticia-123!'}).status_code==200

def test_full_approved_simulation_and_replay(admin,company,row):
    b=batch(admin,row)
    assert b['rows'][0]['status']=='Validado'
    assert admin.post(f'/api/batches/{b["id"]}/simulate').status_code==409
    assert approve(admin,b).status_code==200
    assert admin.post(f'/api/batches/{b["id"]}/simulate').status_code==200
    assert admin.post(f'/api/batches/{b["id"]}/simulate').status_code==409
    while tick():pass
    b=admin.get(f'/api/batches/{b["id"]}').json()
    assert b['status']=='Simulado' and b['rows'][0]['status']=='Simulado'
    with Session() as db:
        assert len(list(db.scalars(select(Job))))==1
        assert not list(db.scalars(select(NFSe))) and not list(db.scalars(select(DPS)))
    assert admin.get('/api/dashboard').json()['issued_cents']==0
    assert admin.post(f'/api/batches/{b["id"]}/emit').status_code==501
    with pytest.raises(FiscalIntegrationUnavailable):emit()

def test_duplicate_inside_and_across_batches(admin,company,row):
    r=admin.post('/api/batches',json={'name':'Duplicado','rows':[row,row]})
    b=admin.get('/api/batches/'+str(r.json()['id'])).json()
    assert b['review']['count']==1 and b['review']['invalid']==1
    assert 'repetido' in ' '.join(b['rows'][1]['errors'])
    second=batch(admin,row)
    assert second['review']['count']==0
    assert approve(admin,b).status_code==422
    assert approve(admin,b,valid_only=True).status_code==200

def test_correction_revokes_approval_and_stale_review(admin,company,row):
    b=batch(admin,row);d=b['rows'][0]
    assert approve(admin,b).status_code==200
    r=admin.put(f'/api/drafts/{d["id"]}',json={'revision':b['revision'],'raw':{**row,'valor_servico':'99.99'}})
    assert r.status_code==200,r.text
    assert approve(admin,b).status_code==409
    b2=admin.get(f'/api/batches/{b["id"]}').json()
    assert b2['status']=='Aguardando aprovação'
    assert b2['approval_digest'] is None
    assert b2['review']['total_cents']==9999
    assert admin.put(f'/api/drafts/{d["id"]}',json={'revision':b['revision'],'raw':row}).status_code==409

def test_company_change_invalidates_approval(admin,company,row):
    b=batch(admin,row)
    cfg={**company['config'],'regime':'Lucro Presumido'}
    assert admin.put(f'/api/companies/{company["id"]}',json={'cnpj':company['cnpj'],'name':company['name'],'config':cfg}).status_code==200
    assert approve(admin,b).status_code==409
    admin.post(f'/api/batches/{b["id"]}/validate')
    b=admin.get(f'/api/batches/{b["id"]}').json()
    assert approve(admin,b).status_code==200

def test_worker_rechecks_company(admin,company,row):
    b=batch(admin,row);approve(admin,b);admin.post(f'/api/batches/{b["id"]}/simulate')
    admin.put(f'/api/companies/{company["id"]}',json={'cnpj':company['cnpj'],'name':company['name']+' ALTERADA','config':company['config']})
    tick()
    assert admin.get(f'/api/batches/{b["id"]}').json()['status']=='Rejeitado'

def test_recover_persisted_queue(admin,company,row):
    b=batch(admin,row);approve(admin,b);admin.post(f'/api/batches/{b["id"]}/simulate')
    # Separate DB sessions prove queued work survives request completion.
    with Session() as db:assert db.scalar(select(Job)).status=='Na fila'
    assert tick()
    assert not tick()

def test_excel_csv_and_report_roundtrip(admin,company,row):
    r=admin.get('/api/template.xlsx');assert r.status_code==200
    wb=load_workbook(io.BytesIO(r.content));assert wb.sheetnames==['Notas','Instrucoes']
    assert [c.value for c in wb['Notas'][1]]==HEADERS
    wb['Notas'].append([row[h] for h in HEADERS]);buffer=io.BytesIO();wb.save(buffer)
    r=admin.post('/api/import',files={'file':('notas.xlsx',buffer.getvalue(),'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')})
    assert r.status_code==200,r.text
    report=admin.get(f'/api/batches/{r.json()["id"]}/report.xlsx')
    assert load_workbook(io.BytesIO(report.content)).active.max_row==2
    csv=';'.join(HEADERS)+'\n'+';'.join(str(row[h]) for h in HEADERS)
    assert admin.post('/api/import',files={'file':('notas.csv',csv.encode(),'text/csv')}).status_code==200
    assert admin.post('/api/import',files={'file':('notas.csv',b'errado;cabecalho\n1;2','text/csv')}).status_code==422

def test_formula_and_invalid_json_rejected(admin,company,row):
    r=admin.get('/api/template.xlsx');wb=load_workbook(io.BytesIO(r.content));row['descricao_servico']='=HYPERLINK("evil")';wb['Notas'].append([row[h] for h in HEADERS]);out=io.BytesIO();wb.save(out)
    assert admin.post('/api/import',files={'file':('notas.xlsx',out.getvalue())}).status_code==422
    assert normalize({**row,'retencoes':'[]'})[1]
    assert normalize({**row,'retencoes':'{"irrf":"999999"}'})[1]

def test_permissions_company_isolation(admin,company,row):
    b=batch(admin,row)
    assert admin.post('/api/users',json={'username':'operador','password':'Senha-ficticia-456!','role':'operator','company_ids':[]}).status_code==200
    admin.post('/api/logout');admin.post('/api/login',json={'username':'operador','password':'Senha-ficticia-456!'})
    assert admin.get('/api/companies').json()==[]
    assert admin.get('/api/batches').json()==[]
    assert admin.get('/api/batches/'+str(b['id'])).status_code==403
    assert admin.post('/api/batches',json={'name':'Não autorizado','rows':[row]}).status_code==403
    assert admin.get('/api/backup').status_code==403
    assert admin.get('/api/audit').status_code==403
    assert admin.post(f'/api/batches/{b["id"]}/approve',json={'digest':'x','confirm_simulation':True}).status_code==403

def test_customer_per_company_and_names(admin,company,row):
    c={'company_id':company['id'],'document':row['documento_tomador'],'name':'OUTRO NOME FICTÍCIO','details':{}}
    assert admin.post('/api/customers',json=c).status_code==200
    assert admin.post('/api/customers',json=c).status_code==409
    b=batch(admin,row);assert any('difere' in e for e in b['rows'][0]['errors'])

def test_backup_integrity_and_no_credentials_in_audit(admin,company,row,tmp_path):
    batch(admin,row)
    r=admin.get('/api/backup');assert r.status_code==200
    z=zipfile.ZipFile(io.BytesIO(r.content));dbpath=tmp_path/'backup.db';dbpath.write_bytes(z.read('nfse.db'))
    with sqlite3.connect(dbpath) as db:assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
    audit=admin.get('/api/audit').text
    assert 'Senha-ficticia' not in audit and row['documento_tomador'] not in audit

def test_schema_rejects_incomplete_xml(tmp_path):
    from pathlib import Path
    schema=Path(__file__).resolve().parents[2]/'schemas'/'Schemas'/'1.01'/'DPS_v1.01.xsd'
    from lxml import etree
    with pytest.raises(etree.DocumentInvalid):validate_xml(b'<DPS xmlns="http://www.sped.fazenda.gov.br/nfse" versao="1.01"/>',schema)
    with pytest.raises(ValueError):validate_xml(b'<!DOCTYPE x [<!ENTITY y "x">]><DPS/>',schema)

def test_two_hundred_rows(admin,company,row):
    rows=[{**row,'descricao_servico':f'SERVICO FICTICIO {i}'} for i in range(200)]
    r=admin.post('/api/batches',json={'name':'200 linhas','rows':rows});assert r.status_code==200,r.text
    b=admin.get('/api/batches/'+str(r.json()['id'])).json()
    assert b['review']['count']==200 and b['review']['total_cents']==24691200
