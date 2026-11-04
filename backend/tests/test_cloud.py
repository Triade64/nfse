import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
from sqlalchemy import select,func
from app import main,security
from app.db import Session
from app.models import Job

def test_cloud_setup_requires_secret_even_before_first_user(client,monkeypatch):
    monkeypatch.setattr(main,'CLOUD',True);monkeypatch.setenv('BOOTSTRAP_TOKEN','synthetic-bootstrap-code-with-32-characters')
    credentials={'username':'cloud-admin','password':'Senha-ficticia-123!'}
    assert client.post('/api/setup',json=credentials).status_code==403
    assert client.post('/api/setup',json={**credentials,'setup_token':'wrong'}).status_code==403
    assert client.post('/api/setup',json={**credentials,'setup_token':'synthetic-bootstrap-code-with-32-characters'}).status_code==200

def test_cloud_secure_cookie(client,monkeypatch):
    monkeypatch.setattr(security,'CLOUD',True)
    response=client.post('/api/setup',json={'username':'secure-admin','password':'Senha-ficticia-123!'})
    assert response.status_code==200 and 'secure' in response.headers['set-cookie'].lower()

def test_simulation_processed_in_bounded_durable_chunks(admin,company,row):
    rows=[{**row,'descricao_servico':f'SERVICO FICTICIO CLOUD {i}'} for i in range(23)]
    b=admin.post('/api/batches',json={'name':'Cloud chunk','rows':rows}).json();b=admin.get(f'/api/batches/{b["id"]}').json()
    assert admin.post(f'/api/batches/{b["id"]}/process-simulation').status_code==409
    assert admin.post(f'/api/batches/{b["id"]}/approve',json={'digest':b['review']['digest'],'confirm_simulation':True}).status_code==200
    admin.post(f'/api/batches/{b["id"]}/simulate')
    for processed,pending in [(10,13),(10,3),(3,0)]:
        r=admin.post(f'/api/batches/{b["id"]}/process-simulation');assert r.status_code==200,r.text
        assert r.json()['processed']==processed and r.json()['pending']==pending
    assert admin.get(f'/api/batches/{b["id"]}').json()['status']=='Simulado'
    assert admin.post(f'/api/batches/{b["id"]}/process-simulation').json()['processed']==0

def test_cloud_refuses_sqlite_and_remote_plaintext_in_separate_process():
    root=Path(__file__).resolve().parents[2]
    for url in ['sqlite://','postgresql://example:secret@example.invalid/postgres']:
        env={**os.environ,'PYTHONPATH':str(root/'backend'),'NFSE_MODE':'cloud','DATABASE_URL':url}
        p=subprocess.run([sys.executable,'-c','import app.db'],env=env,capture_output=True,text=True)
        assert p.returncode!=0
        assert 'example:secret' not in p.stderr

def test_private_schema_in_generated_sql():
    sql=(Path(__file__).resolve().parents[2]/'database'/'schema.sql').read_text()
    assert 'REVOKE ALL ON SCHEMA nfse_app FROM PUBLIC, anon, authenticated' in sql
    assert 'ENABLE ROW LEVEL SECURITY' in sql
    assert 'SECURITY DEFINER' not in sql
    assert 'CREATE TABLE IF NOT EXISTS public.' not in sql
