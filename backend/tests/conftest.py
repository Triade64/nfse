import os
import tempfile
os.environ['DATABASE_URL']='sqlite:///'+tempfile.mkdtemp()+'/test.db'
import pytest
from fastapi.testclient import TestClient
from app.main import app
from app.db import Base,engine

@pytest.fixture
def client():
    Base.metadata.drop_all(engine);Base.metadata.create_all(engine)
    # Deliberately no lifespan worker: tests deterministically drive the persistent queue.
    c=TestClient(app,headers={'X-Requested-With':'nfse-local'})
    try:
        yield c
    finally:
        c.close()

@pytest.fixture
def admin(client):
    r=client.post('/api/setup',json={'username':'administrador','password':'Senha-ficticia-123!'})
    assert r.status_code==200,r.text
    return client

@pytest.fixture
def company(admin):
    r=admin.post('/api/companies',json={'cnpj':'11222333000181','name':'EMPRESA FICTÍCIA DE TESTES','config':{'municipio_ibge':'4205704','regime':'Simples Nacional'}})
    assert r.status_code==200,r.text
    return r.json()

@pytest.fixture
def row():
    return {'cnpj_emitente':'11222333000181','documento_tomador':'52998224725','nome_tomador':'TOMADOR FICTÍCIO','competencia':'2026-01-10','municipio_ibge':'4205704','descricao_servico':'SERVIÇO FICTÍCIO PARA TESTES','codigo_tributacao_nacional':'010101','codigo_tributacao_municipal':'','valor_servico':'1.234,56','iss_aliquota':'2,00','iss_retido':'nao','retencoes':'{}','observacoes':'SEM VALIDADE FISCAL'}
