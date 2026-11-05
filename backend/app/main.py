import csv
import os
import secrets
import hashlib
import io
import json
import sqlite3
import threading
import time
import zipfile
from collections import defaultdict
from contextlib import asynccontextmanager
from datetime import date, datetime, timezone
from pathlib import Path
from fastapi import FastAPI, Depends, HTTPException, UploadFile, File, Request, Response
from fastapi.responses import FileResponse, StreamingResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field, ConfigDict
from sqlalchemy import select, func, update, delete, text
from sqlalchemy.exc import IntegrityError
from starlette.middleware.trustedhost import TrustedHostMiddleware
from .config import CLOUD,allowed_hosts,allowed_origins
from .db import Base, engine, Session, ROOT, DATA, URL
from .models import User, LoginSession, Company, Customer, Service, Batch, Draft, Job, Audit, Access
from .security import current_user, db_session, hasher, role, allowed_company, company_ids, issue_session
from .validation import HEADERS, REQUIRED, normalize, digits, valid_document, cell_text
from .dps_preview import PreviewOptions, build_preview, SCHEMA_DIR
from argon2.exceptions import VerificationError, InvalidHashError
from openpyxl import Workbook, load_workbook
from openpyxl.styles import Font, PatternFill

ALL_STATES = ['Rascunho','Aguardando validação','Com inconsistência','Validado','Aguardando aprovação','Aprovado','Na fila','Em processamento','Emitido','Rejeitado','Situação desconhecida, aguardando consulta','Cancelado','Simulado']
LOCKED = ['Na fila','Em processamento','Simulado','Emitido','Situação desconhecida, aguardando consulta','Cancelado','Rejeitado']

def audit(db,user,action,entity,entity_id,info=None):
    db.add(Audit(user_id=user.id if user else None,action=action,entity=entity,entity_id=entity_id,info=info or {}))

def get_or_404(db, cls, id, locked=False):
    obj = db.scalar(select(cls).where(cls.id==id).with_for_update()) if locked and not URL.startswith('sqlite') else db.get(cls,id)
    if not obj:
        raise HTTPException(404,'Registro não encontrado')
    return obj

def batch_access(db,user,b):
    # Batch staging is private to its creator and administrators; all resolved companies must also be permitted.
    if user.role != 'admin' and b.owner_id != user.id:
        raise HTTPException(403,'Lote de outro usuário; somente administrador pode revisá-lo')
    for c in db.scalars(select(Draft.company_id).where(Draft.batch_id==b.id,Draft.company_id.is_not(None)).distinct()):
        allowed_company(db,user,c)

def serialize(obj):
    return {c.name:getattr(obj,c.name) for c in obj.__table__.columns if c.name not in ('password_hash','token_hash')}

def validation(db,user,d):
    raw, errors, amount, fp = normalize(d.raw)
    c = db.scalar(select(Company).where(Company.cnpj==raw['cnpj_emitente']))
    if not c:
        errors.append('cnpj_emitente: cadastre a empresa antes de validar')
    else:
        allowed_company(db,user,c.id)
        cust = db.scalar(select(Customer).where(Customer.company_id==c.id,Customer.document==raw['documento_tomador']))
        if cust and cust.name.casefold() != raw['nome_tomador'].casefold():
            errors.append('nome_tomador: difere do cadastro desta empresa; confira e corrija')
    duplicate = db.scalar(select(Draft.id).where(Draft.fingerprint==fp,Draft.id != (d.id or -1)))
    if duplicate:
        errors.append('Documento repetido: já existe rascunho com os mesmos dados principais')
    d.raw=raw; d.errors=errors; d.amount_cents=amount
    d.company_id=c.id if c else None
    d.company_revision=c.revision if c else None
    d.fingerprint=fp if not errors else None
    d.snapshot={'company':serialize(c)} if c else {}
    d.status='Com inconsistência' if errors else 'Validado'

def validate_batch(db,user,b):
    rows = list(db.scalars(select(Draft).where(Draft.batch_id==b.id).order_by(Draft.line)))
    # Release fingerprints first so a correction can resolve an old intra-batch duplicate.
    for d in rows:
        d.fingerprint=None
    db.flush()
    for d in rows:
        validation(db,user,d)
        db.flush()
    b.revision+=1; b.approval_digest=None; b.approved_by=None
    b.status='Aguardando aprovação' if any(not d.errors for d in rows) else 'Com inconsistência'

def review(db,b):
    rows=list(db.scalars(select(Draft).where(Draft.batch_id==b.id).order_by(Draft.line)))
    valid=[d for d in rows if not d.errors and d.fingerprint]
    companies={}
    for d in valid:
        c=db.get(Company,d.company_id)
        companies[c.id]={'cnpj':c.cnpj,'name':c.name,'revision':c.revision}
    payload={'revision':b.revision,'documents':[{'id':d.id,'raw':d.raw,'status':d.status,'snapshot':d.snapshot} for d in valid],'companies':companies}
    digest=hashlib.sha256(json.dumps(payload,sort_keys=True,ensure_ascii=False).encode()).hexdigest()
    return {'digest':digest,'count':len(valid),'invalid':len(rows)-len(valid),'total_cents':sum(d.amount_cents for d in valid),'companies':list(companies.values()),'alerts':['Validação cadastral básica; não confirma enquadramento fiscal, município, NBS ou IBS/CBS.','Aprovação exclusiva para SIMULAÇÃO. Nenhum documento fiscal será emitido.']}

def tick():
    with Session() as db:
        job=db.scalar(select(Job).where(Job.status=='Na fila').order_by(Job.id).limit(1))
        if not job:
            return False
        claimed=db.execute(update(Job).where(Job.id==job.id,Job.status=='Na fila').values(status='Em processamento')).rowcount
        if not claimed:
            db.rollback(); return False
        d=db.get(Draft,job.draft_id)
        c=db.get(Company,d.company_id)
        if not c or c.revision != d.company_revision:
            job.status='Rejeitado'; job.result={'message':'Cadastro da empresa alterado após aprovação. Prepare um novo lote.'}; d.status='Rejeitado'
        else:
            job.status='Simulado'; job.result={'message':'Simulação local concluída. Sem envio, chave ou validade fiscal.'}; d.status='Simulado'
        audit(db,None,'simulation_finished','draft',d.id,{'status':d.status})
        db.flush()
        pending=db.scalar(select(func.count()).select_from(Job).join(Draft,Job.draft_id==Draft.id).where(Draft.batch_id==d.batch_id,Job.status.in_(['Na fila','Em processamento'])))
        if not pending:
            b=db.get(Batch,d.batch_id)
            failed=db.scalar(select(func.count()).select_from(Draft).where(Draft.batch_id==b.id,Draft.status=='Rejeitado'))
            b.status='Rejeitado' if failed else 'Simulado'
        db.commit(); return True

@asynccontextmanager
async def lifespan(app):
    if CLOUD:
        # Migrations are deployed explicitly, never on request startup.
        yield
        return
    Base.metadata.create_all(engine)
    stop=threading.Event()
    def worker():
        while not stop.wait(.3):
            try:
                tick()
            except Exception:
                # No payloads or personal data in console logs. DB rollback leaves queued work recoverable.
                import logging
                logging.getLogger('nfse').error('Falha no worker de simulação; operação revertida')
    thread=threading.Thread(target=worker,daemon=True); thread.start()
    yield
    stop.set(); thread.join(timeout=3)

app=FastAPI(title='Tríade NFS-e • preparação local',version='0.5.0',lifespan=lifespan)
app.add_middleware(TrustedHostMiddleware,allowed_hosts=allowed_hosts())

@app.middleware('http')
async def local_protection(request,call_next):
    if request.url.path=='/api/integrations/restricted/diagnostic':
        return JSONResponse({'detail':'Diagnóstico por upload desativado. Use o conector local em Configurações.'},status_code=410)
    if request.method not in ('GET','HEAD','OPTIONS') and request.headers.get('X-Requested-With') != 'nfse-local':
        return JSONResponse({'detail':'Requisição sem proteção de origem'},status_code=403)
    origin=request.headers.get('origin')
    if origin and origin not in allowed_origins():
        return JSONResponse({'detail':'Origem não permitida'},status_code=403)
    response=await call_next(request)
    response.headers['X-Content-Type-Options']='nosniff'
    response.headers['X-Frame-Options']='DENY'
    response.headers['Cache-Control']='no-store'
    response.headers['Content-Security-Policy']="default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; object-src 'none'; frame-ancestors 'none'; base-uri 'self'"
    return response

@app.exception_handler(IntegrityError)
async def conflict(request,exc):
    return JSONResponse({'detail':'Registro repetido ou conflito de gravação. Recarregue e confira os dados.'},status_code=409)

class Credentials(BaseModel):
    username: str = Field(min_length=3,max_length=80,pattern=r'^[A-Za-z0-9_.@-]+$')
    password: str = Field(min_length=12,max_length=200)

class SetupInput(Credentials):
    setup_token:str|None=Field(default=None,max_length=512)

@app.get('/api/local-connector/download')
def download_local_connector(u=Depends(current_user)):
    role(u,['admin'])
    package=ROOT/'local_connector'
    names=['Abrir_Conector.cmd','ConectorTriade.ps1','TriadeConnector.Core.psm1','TriadeDps.psm1','TriadeRestricted.psm1','LEIA-ME.txt']
    if any(not (package/name).is_file() for name in names) or len(list(SCHEMA_DIR.glob('*.xsd')))!=10:
        raise HTTPException(503,'Pacote do conector ainda não disponível neste deployment.')
    output=io.BytesIO()
    with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED) as archive:
        for name in names:archive.writestr('Triade_Conector_Local/'+name,(package/name).read_bytes())
        for path in sorted(SCHEMA_DIR.glob('*.xsd')):
            archive.writestr('Triade_Conector_Local/schemas/'+path.name,path.read_bytes())
    output.seek(0)
    return StreamingResponse(output,media_type='application/zip',headers={'Content-Disposition':'attachment; filename="Triade_Conector_Local_0_8_3.zip"'})

@app.post('/api/drafts/{id}/restricted-preview')
def restricted_preview(id:int,data:PreviewOptions,u=Depends(current_user),db=Depends(db_session)):
    role(u,['admin'])
    d=get_or_404(db,Draft,id)
    b=get_or_404(db,Batch,d.batch_id);batch_access(db,u,b)
    if b.revision!=data.revision:raise HTTPException(409,'Lote alterado. Reabra a conferência.')
    if d.raw!=data.expected_raw:raise HTTPException(409,'Rascunho alterado. Recarregue a tela antes de gerar a prévia.')
    if not d.company_id:raise HTTPException(422,'Rascunho sem emitente cadastrado.')
    c=get_or_404(db,Company,d.company_id);allowed_company(db,u,c.id)
    try:xml=build_preview(d.raw,serialize(c),data)
    except ValueError as exc:raise HTTPException(422,str(exc)) from None
    digest=hashlib.sha256(xml).hexdigest()
    audit(db,u,'offline_dps_preview','draft',d.id,{'xml_sha256':digest,'environment':2,'batch_revision':b.revision,'number_reserved':False})
    db.commit()
    return {'xml':xml.decode('utf-8'),'sha256':digest,'environment':2,'submitted':False,'number_reserved':False,
            'warning':'Prévia offline validada no XSD. Numeração não reservada. Regras fiscais e aceitação da assinatura na API pendentes.'}

@app.get('/api/setup')
def setup_status(db=Depends(db_session)):
    return {'required':db.scalar(select(func.count()).select_from(User))==0,'mode':'simulation','cloud':CLOUD,'requires_token':CLOUD}

@app.post('/api/setup')
def setup(data:SetupInput,response:Response,db=Depends(db_session)):
    if CLOUD:
        token=os.getenv('BOOTSTRAP_TOKEN','')
        if len(token)<32 or not secrets.compare_digest(data.setup_token or '',token):raise HTTPException(403,'Código inicial inválido. Consulte o responsável pelo sistema.')
        if not URL.startswith('sqlite'):db.execute(text('SELECT pg_advisory_xact_lock(194612311)'))
    # Single SQLite writer transaction prevents racing first-admin creation.
    if URL.startswith('sqlite'):
        db.connection().exec_driver_sql('BEGIN IMMEDIATE')
    if db.scalar(select(func.count()).select_from(User)):
        raise HTTPException(409,'Administrador já configurado')
    u=User(username=data.username.strip(),password_hash=hasher.hash(data.password),role='admin')
    db.add(u); db.flush(); audit(db,u,'setup','user',u.id); issue_session(db,u,response)
    return serialize(u)

attempts={}; attempts_lock=threading.Lock()
@app.post('/api/login')
def login(data:Credentials,request:Request,response:Response,db=Depends(db_session)):
    key=request.client.host if request.client else 'local'
    with attempts_lock:
        recent=[x for x in attempts.get(key,[]) if time.monotonic()-x<60]
        if len(recent)>=10:
            raise HTTPException(429,'Muitas tentativas. Aguarde um minuto.')
        attempts[key]=recent+[time.monotonic()]
    u=db.scalar(select(User).where(User.username==data.username))
    try:
        if not u or not u.active:
            raise ValueError()
        hasher.verify(u.password_hash,data.password)
    except (VerificationError,InvalidHashError,ValueError):
        raise HTTPException(401,'Usuário ou senha inválidos')
    audit(db,u,'login','user',u.id); issue_session(db,u,response)
    return serialize(u)

@app.get('/api/me')
def me(u=Depends(current_user)):
    return serialize(u)
@app.post('/api/logout')
def logout(request:Request,response:Response,u=Depends(current_user),db=Depends(db_session)):
    db.execute(delete(LoginSession).where(LoginSession.token_hash==hashlib.sha256(request.cookies.get('nfse_session','').encode()).hexdigest()))
    db.commit(); response.delete_cookie('nfse_session'); return {'ok':True}

class CompanyInput(BaseModel):
    model_config=ConfigDict(extra='forbid')
    cnpj: str
    name: str=Field(min_length=2,max_length=200)
    config: dict=Field(default_factory=dict)

@app.get('/api/companies')
def companies(u=Depends(current_user),db=Depends(db_session)):
    q=select(Company); ids=company_ids(db,u)
    if ids is not None:q=q.where(Company.id.in_(ids))
    return [serialize(c) for c in db.scalars(q.order_by(Company.name))]

def save_company(data,db,u,c=None):
    role(u,['admin'])
    doc=digits(data.cnpj)
    if len(doc)!=14 or not valid_document(data.cnpj):raise HTTPException(422,'CNPJ numérico inválido ou formato ainda não suportado')
    cfg=data.config
    if not str(cfg.get('municipio_ibge','')).isdigit() or len(str(cfg.get('municipio_ibge','')))!=7:
        raise HTTPException(422,'Informe município IBGE de 7 dígitos')
    if not cfg.get('regime'):raise HTTPException(422,'Informe o regime tributário')
    if c is None:c=Company(cnpj=doc,name=data.name,config=cfg);db.add(c)
    else:
        if c.cnpj!=doc:raise HTTPException(422,'CNPJ é imutável. Cadastre outra empresa.')
        c.name=data.name;c.config=cfg;c.revision+=1
    db.flush();audit(db,u,'save','company',c.id);db.commit();return serialize(c)
@app.post('/api/companies')
def create_company(data:CompanyInput,u=Depends(current_user),db=Depends(db_session)):
    return save_company(data,db,u)
@app.put('/api/companies/{id}')
def edit_company(id:int,data:CompanyInput,u=Depends(current_user),db=Depends(db_session)):
    return save_company(data,db,u,get_or_404(db,Company,id))

class CustomerInput(BaseModel):
    company_id:int
    document:str
    name:str=Field(min_length=2,max_length=200)
    details:dict=Field(default_factory=dict)
class ServiceInput(BaseModel):
    company_id:int
    name:str=Field(min_length=2,max_length=200)
    config:dict=Field(default_factory=dict)

@app.get('/api/customers')
def customers(company_id:int|None=None,q:str='',u=Depends(current_user),db=Depends(db_session)):
    query=select(Customer);ids=company_ids(db,u)
    if ids is not None:query=query.where(Customer.company_id.in_(ids))
    if company_id:allowed_company(db,u,company_id);query=query.where(Customer.company_id==company_id)
    if q:query=query.where(Customer.name.ilike(f'%{q}%')|Customer.document.contains(q))
    return [serialize(c) for c in db.scalars(query.order_by(Customer.name))]

def save_customer(data,db,u,c=None):
    role(u,['admin','operator','approver']);allowed_company(db,u,data.company_id);get_or_404(db,Company,data.company_id)
    if not valid_document(data.document):raise HTTPException(422,'CPF/CNPJ inválido ou não suportado')
    if c and c.company_id!=data.company_id:raise HTTPException(422,'Não transfira cadastros entre empresas')
    if not c:c=Customer(company_id=data.company_id);db.add(c)
    c.document=digits(data.document);c.name=data.name;c.details=data.details
    db.flush();audit(db,u,'save','customer',c.id);db.commit();return serialize(c)
@app.post('/api/customers')
def create_customer(data:CustomerInput,u=Depends(current_user),db=Depends(db_session)):return save_customer(data,db,u)
@app.put('/api/customers/{id}')
def edit_customer(id:int,data:CustomerInput,u=Depends(current_user),db=Depends(db_session)):
    c=get_or_404(db,Customer,id);allowed_company(db,u,c.company_id);return save_customer(data,db,u,c)

@app.get('/api/services')
def services(u=Depends(current_user),db=Depends(db_session)):
    q=select(Service);ids=company_ids(db,u)
    if ids is not None:q=q.where(Service.company_id.in_(ids))
    return [serialize(s) for s in db.scalars(q.order_by(Service.name))]

def save_service(data,db,u,s=None):
    role(u,['admin','operator','approver']);allowed_company(db,u,data.company_id);get_or_404(db,Company,data.company_id)
    if s and s.company_id!=data.company_id:raise HTTPException(422,'Não transfira serviços entre empresas')
    if not s:s=Service(company_id=data.company_id);db.add(s)
    else:s.revision+=1
    s.name=data.name;s.config=data.config
    db.flush();audit(db,u,'save','service',s.id);db.commit();return serialize(s)
@app.post('/api/services')
def create_service(data:ServiceInput,u=Depends(current_user),db=Depends(db_session)):return save_service(data,db,u)
@app.put('/api/services/{id}')
def edit_service(id:int,data:ServiceInput,u=Depends(current_user),db=Depends(db_session)):
    s=get_or_404(db,Service,id);allowed_company(db,u,s.company_id);return save_service(data,db,u,s)

class NewBatch(BaseModel):
    name:str=Field(min_length=1,max_length=200)
    rows:list[dict]=Field(min_length=1,max_length=2000)

def make_batch(db,u,name,rows):
    b=Batch(name=name,owner_id=u.id);db.add(b);db.flush()
    for i,row in enumerate(rows,2):
        if set(row)-set(HEADERS):raise HTTPException(422,'Colunas desconhecidas. Use o modelo da aplicação.')
        if any(len(str(v))>10000 for v in row.values()):raise HTTPException(422,'Célula excede 10.000 caracteres')
        d=Draft(batch_id=b.id,line=i,raw={k:cell_text(v) for k,v in row.items()})
        db.add(d)
    db.flush();validate_batch(db,u,b);audit(db,u,'import','batch',b.id,{'rows':len(rows)});db.commit()
    return serialize(b)

@app.post('/api/batches')
def new_batch(data:NewBatch,u=Depends(current_user),db=Depends(db_session)):
    role(u,['admin','operator','approver']);return make_batch(db,u,data.name,data.rows)

class PreparationRow(BaseModel):
    id:int|None=None
    raw:dict

class PreparationInput(BaseModel):
    name:str=Field(min_length=1,max_length=200)
    revision:int|None=None
    rows:list[PreparationRow]=Field(min_length=1,max_length=2000)

def save_preparation(data,db,u,b=None):
    role(u,['admin','operator','approver'])
    if b:
        batch_access(db,u,b)
        if b.status in LOCKED or b.revision!=data.revision:
            raise HTTPException(409,'Lote processado ou alterado. Reabra a versão atual antes de editar.')
        if db.scalar(select(Job.id).join(Draft,Job.draft_id==Draft.id).where(Draft.batch_id==b.id)):
            raise HTTPException(409,'Lote já enviado à fila; prepare outro lote.')
    else:
        b=Batch(name=data.name,owner_id=u.id);db.add(b);db.flush()
    current={d.id:d for d in db.scalars(select(Draft).where(Draft.batch_id==b.id))}
    ids=[r.id for r in data.rows if r.id is not None]
    if len(ids)!=len(set(ids)) or set(ids)-set(current):
        raise HTTPException(422,'Linhas repetidas ou pertencentes a outro lote')
    for item in data.rows:
        if set(item.raw)-set(HEADERS) or any(len(str(v))>10000 for v in item.raw.values()):
            raise HTTPException(422,'Campos inválidos ou célula maior que 10.000 caracteres')
        doc=digits(item.raw.get('cnpj_emitente'))
        c=db.scalar(select(Company).where(Company.cnpj==doc))
        if c:allowed_company(db,u,c.id)
    removed=[id for id in current if id not in ids]
    for id in removed:db.delete(current[id])
    for index,item in enumerate(data.rows,1):
        d=current[item.id] if item.id is not None else Draft(batch_id=b.id)
        if item.id is None:db.add(d)
        d.line=index;d.raw={k:cell_text(v) for k,v in item.raw.items()}
        c=db.scalar(select(Company).where(Company.cnpj==digits(d.raw.get('cnpj_emitente'))))
        d.company_id=c.id if c else None
        d.errors=[];d.amount_cents=0;d.fingerprint=None;d.snapshot={};d.company_revision=None;d.status='Rascunho'
    b.name=data.name;b.status='Rascunho';b.revision+=1;b.approval_digest=None;b.approved_by=None
    db.flush();audit(db,u,'save_preparation','batch',b.id,{'rows':len(data.rows),'removed_draft_ids':removed});db.commit()
    return {**serialize(b),'rows':[serialize(d) for d in db.scalars(select(Draft).where(Draft.batch_id==b.id).order_by(Draft.line))]}

@app.post('/api/preparations')
def create_preparation(data:PreparationInput,u=Depends(current_user),db=Depends(db_session)):
    if URL.startswith('sqlite'):db.connection().exec_driver_sql('BEGIN IMMEDIATE')
    return save_preparation(data,db,u)

@app.put('/api/preparations/{id}')
def update_preparation(id:int,data:PreparationInput,u=Depends(current_user),db=Depends(db_session)):
    if URL.startswith('sqlite'):db.connection().exec_driver_sql('BEGIN IMMEDIATE')
    return save_preparation(data,db,u,get_or_404(db,Batch,id,locked=True))

@app.post('/api/import')
async def import_file(file:UploadFile=File(...),u=Depends(current_user),db=Depends(db_session)):
    role(u,['admin','operator','approver'])
    data=await file.read(8*1024*1024+1)
    if len(data)>8*1024*1024:raise HTTPException(413,'Arquivo maior que 8 MB')
    name=file.filename or 'arquivo';suffix=Path(name).suffix.lower()
    try:
        if suffix=='.xlsx':
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                if sum(i.file_size for i in z.infolist())>40*1024*1024 or len(z.infolist())>500:
                    raise ValueError('Excel descompactado excessivo')
            wb=load_workbook(io.BytesIO(data),read_only=True,data_only=False)
            if 'Notas' not in wb.sheetnames:raise ValueError('Aba Notas não encontrada')
            values=wb['Notas'].iter_rows(values_only=True)
            heads=[cell_text(x).strip() for x in next(values)]
            rows=[]
            for vals in values:
                if not any(v is not None and str(v).strip() for v in vals):continue
                if len(vals)>len(heads) and any(x is not None for x in vals[len(heads):]):raise ValueError('Valores sem cabeçalho')
                row=dict(zip(heads,[cell_text(x) for x in vals]))
                if any(str(v).startswith('=') for v in row.values()):raise ValueError('Fórmulas não são aceitas na importação')
                rows.append(row)
                if len(rows)>2000:raise ValueError('Limite de 2.000 linhas')
            wb.close()
        elif suffix=='.csv':
            text=data.decode('utf-8-sig');delimiter=';' if ';' in text.splitlines()[0] else ','
            reader=csv.DictReader(io.StringIO(text),delimiter=delimiter);heads=reader.fieldnames or []
            rows=[]
            for row in reader:
                if None in row:raise ValueError('Quantidade de colunas incompatível')
                if any(str(v).startswith('=') for v in row.values()):raise ValueError('Fórmulas não são aceitas')
                if any(v for v in row.values()):rows.append(row)
                if len(rows)>2000:raise ValueError('Limite de 2.000 linhas')
        else:raise ValueError('Use .xlsx ou .csv UTF-8')
        if len(heads)!=len(set(heads)) or set(heads)!=set(HEADERS):raise ValueError('Cabeçalhos incompatíveis. Baixe o modelo na aplicação e preserve todas as colunas.')
        if not rows:raise ValueError('Arquivo sem registros')
    except Exception as e:
        # No file content in errors; return known parsing messages only.
        message=str(e) if isinstance(e,ValueError) else 'Não foi possível ler o arquivo. Verifique o formato.'
        raise HTTPException(422,message)
    return make_batch(db,u,Path(name).name[:200],rows)

@app.delete('/api/drafts/{id}')
def delete_draft(id:int,revision:int,u=Depends(current_user),db=Depends(db_session)):
    role(u,['admin','operator','approver'])
    if URL.startswith('sqlite'):db.connection().exec_driver_sql('BEGIN IMMEDIATE')
    batch_id=db.scalar(select(Draft.batch_id).where(Draft.id==id))
    if batch_id is None:raise HTTPException(404,'Rascunho não encontrado')
    b=get_or_404(db,Batch,batch_id,locked=True);batch_access(db,u,b)
    if b.revision!=revision:raise HTTPException(409,'Lote alterado. Reabra a versão atual antes de excluir.')
    editable=['Rascunho','Aguardando validação','Com inconsistência','Validado','Aguardando aprovação','Aprovado']
    if b.status not in editable:raise HTTPException(409,'Lote enviado ou processado não pode ter rascunhos excluídos.')
    if db.scalar(select(Job.id).join(Draft,Job.draft_id==Draft.id).where(Draft.batch_id==b.id)):
        raise HTTPException(409,'Lote já enviado à fila; a exclusão está bloqueada.')
    from .models import DPS
    if db.scalar(select(DPS.id).join(Draft,DPS.draft_id==Draft.id).where(Draft.batch_id==b.id)):
        raise HTTPException(409,'Há documento fiscal vinculado; a exclusão está bloqueada.')
    d=get_or_404(db,Draft,id)
    if d.status not in editable:raise HTTPException(409,'Documento enviado ou processado não pode ser excluído.')
    audit(db,u,'delete_draft','draft',d.id,{'batch_id':b.id,'line':d.line,'previous_status':d.status})
    db.delete(d);db.flush()
    if db.scalar(select(Draft.id).where(Draft.batch_id==b.id).limit(1)):
        validate_batch(db,u,b)
    else:
        b.status='Rascunho';b.revision+=1;b.approval_digest=None;b.approved_by=None
    db.commit()
    return {'ok':True,'batch_id':b.id,'revision':b.revision}

@app.get('/api/batches')
def batches(u=Depends(current_user),db=Depends(db_session)):
    q=select(Batch).order_by(Batch.id.desc())
    if u.role!='admin':q=q.where(Batch.owner_id==u.id)
    return [serialize(b) for b in db.scalars(q)]
@app.get('/api/batches/{id}')
def batch_detail(id:int,u=Depends(current_user),db=Depends(db_session)):
    b=get_or_404(db,Batch,id);batch_access(db,u,b)
    return {**serialize(b),'rows':[serialize(d) for d in db.scalars(select(Draft).where(Draft.batch_id==id).order_by(Draft.line))],'review':review(db,b)}

class RepeatBatchInput(BaseModel):
    name:str=Field(min_length=1,max_length=200)
    competencia:date
    draft_ids:list[int]=Field(min_length=1,max_length=2000)
    source_revision:int
    keep_taxes:bool=True
    confirm_tax_review:bool=False
    request_id:str=Field(pattern=r'^[A-Za-z0-9-]{16,80}$')

@app.post('/api/batches/{id}/repeat')
def repeat_batch(id:int,data:RepeatBatchInput,u=Depends(current_user),db=Depends(db_session)):
    role(u,['admin','operator','approver'])
    if URL.startswith('sqlite'):db.connection().exec_driver_sql('BEGIN IMMEDIATE')
    source=get_or_404(db,Batch,id,locked=True);batch_access(db,u,source)
    request_digest=hashlib.sha256(json.dumps(data.model_dump(mode='json'),sort_keys=True).encode()).hexdigest()
    previous=db.scalar(select(Audit).where(Audit.action=='repeat_batch',Audit.user_id==u.id,Audit.info['request_id'].as_string()==data.request_id))
    if previous:
        if previous.info.get('source_batch_id')!=id or previous.info.get('request_digest')!=request_digest:raise HTTPException(409,'Identificador já usado em outra solicitação')
        b=get_or_404(db,Batch,previous.entity_id);batch_access(db,u,b)
        return {**serialize(b),'rows':[serialize(d) for d in db.scalars(select(Draft).where(Draft.batch_id==b.id).order_by(Draft.line))]}
    if source.revision!=data.source_revision:raise HTTPException(409,'Lote de origem alterado. Selecione-o novamente.')
    if len(set(data.draft_ids))!=len(data.draft_ids):raise HTTPException(422,'Seleção de notas repetida')
    available={d.id:d for d in db.scalars(select(Draft).where(Draft.batch_id==id))}
    if set(data.draft_ids)-set(available):raise HTTPException(422,'Nota não pertence ao lote selecionado')
    if data.keep_taxes and not data.confirm_tax_review:
        raise HTTPException(422,'Confirme a revisão tributária antes de manter os tributos')
    rows=[]
    for draft_id in data.draft_ids:
        d=available[draft_id]
        if d.raw.get('competencia')==data.competencia.isoformat():
            raise HTTPException(422,'Escolha uma nova competência, diferente da nota de origem')
        if data.keep_taxes:
            c=db.get(Company,d.company_id) if d.company_id else None
            if not c or d.company_revision!=c.revision or d.errors or not d.fingerprint:
                raise HTTPException(409,'Origem não validada ou empresa alterada. Desmarque Manter tributos para revisar os campos no novo lote.')
        raw={**d.raw,'competencia':data.competencia.isoformat()}
        if not data.keep_taxes:
            for key in ['codigo_tributacao_nacional','codigo_tributacao_municipal','iss_aliquota','iss_retido']:
                raw[key]=''
            raw['retencoes']='{}'
        rows.append(raw)
    b=Batch(name=data.name,owner_id=u.id,status='Rascunho');db.add(b);db.flush()
    for index,raw in enumerate(rows,1):
        c=db.scalar(select(Company).where(Company.cnpj==digits(raw.get('cnpj_emitente'))))
        if c:allowed_company(db,u,c.id)
        db.add(Draft(batch_id=b.id,company_id=c.id if c else None,line=index,raw=raw,errors=[],amount_cents=0,status='Rascunho',snapshot={}))
    db.flush();audit(db,u,'repeat_batch','batch',b.id,{'source_batch_id':id,'source_draft_ids':data.draft_ids,'request_id':data.request_id,'request_digest':request_digest,'keep_taxes':data.keep_taxes,'competencia':data.competencia.isoformat()});db.commit()
    return {**serialize(b),'rows':[serialize(d) for d in db.scalars(select(Draft).where(Draft.batch_id==b.id).order_by(Draft.line))]}

class EditRow(BaseModel):
    raw:dict
    revision:int
@app.put('/api/drafts/{id}')
def edit_row(id:int,data:EditRow,u=Depends(current_user),db=Depends(db_session)):
    role(u,['admin','operator','approver'])
    if URL.startswith('sqlite'):db.connection().exec_driver_sql('BEGIN IMMEDIATE')
    d=get_or_404(db,Draft,id);b=get_or_404(db,Batch,d.batch_id,locked=True);batch_access(db,u,b)
    if b.status in LOCKED or b.revision!=data.revision:raise HTTPException(409,'Lote processado ou alterado por outra operação. Recarregue.')
    if set(data.raw)-set(HEADERS) or any(len(str(v))>10000 for v in data.raw.values()):raise HTTPException(422,'Campos inválidos')
    d.raw={k:cell_text(v) for k,v in data.raw.items()};validate_batch(db,u,b);audit(db,u,'edit','draft',id);db.commit();return serialize(b)
@app.post('/api/batches/{id}/validate')
def revalidate(id:int,u=Depends(current_user),db=Depends(db_session)):
    role(u,['admin','operator','approver'])
    if URL.startswith('sqlite'):db.connection().exec_driver_sql('BEGIN IMMEDIATE')
    b=get_or_404(db,Batch,id,locked=True);batch_access(db,u,b)
    if b.status in LOCKED:raise HTTPException(409,'Lote já processado')
    validate_batch(db,u,b);audit(db,u,'validate','batch',id);db.commit();return review(db,b)
class Approval(BaseModel):
    digest:str
    valid_only:bool=False
    confirm_simulation:bool=False
@app.post('/api/batches/{id}/approve')
def approve(id:int,data:Approval,u=Depends(current_user),db=Depends(db_session)):
    role(u,['admin','approver'])
    if URL.startswith('sqlite'):db.connection().exec_driver_sql('BEGIN IMMEDIATE')
    b=get_or_404(db,Batch,id,locked=True);batch_access(db,u,b)
    if b.status!='Aguardando aprovação':raise HTTPException(409,'Valide o lote antes de aprovar')
    r=review(db,b)
    if data.digest!=r['digest']:raise HTTPException(409,'Conferência desatualizada. Recarregue e revise.')
    if not data.confirm_simulation or not r['count']:raise HTTPException(422,'Confirme a simulação dos documentos válidos')
    if r['invalid'] and not data.valid_only:raise HTTPException(422,'Existem erros. Autorize explicitamente somente os válidos ou corrija-os.')
    for d in db.scalars(select(Draft).where(Draft.batch_id==id,Draft.fingerprint.is_not(None))):
        c=db.get(Company,d.company_id)
        if c.revision!=d.company_revision:raise HTTPException(409,'Empresa alterada; revalide o lote')
        d.status='Aprovado'
    b.status='Aprovado';b.approval_digest=r['digest'];b.approved_by=u.id
    audit(db,u,'approve_simulation','batch',id,{'count':r['count'],'total_cents':r['total_cents'],'valid_only':data.valid_only});db.commit();return serialize(b)
@app.post('/api/batches/{id}/simulate')
def enqueue(id:int,u=Depends(current_user),db=Depends(db_session)):
    role(u,['admin','approver'])
    if URL.startswith('sqlite'):db.connection().exec_driver_sql('BEGIN IMMEDIATE')
    b=get_or_404(db,Batch,id,locked=True);batch_access(db,u,b)
    if b.status!='Aprovado':raise HTTPException(409,'O lote precisa de aprovação explícita')
    # Revalidate company revisions immediately before queueing.
    for d in db.scalars(select(Draft).where(Draft.batch_id==id,Draft.status=='Aprovado')):
        c=db.get(Company,d.company_id)
        if c.revision!=d.company_revision:raise HTTPException(409,'Empresa alterada; revalide e aprove novamente')
        db.add(Job(draft_id=d.id));d.status='Na fila'
    b.status='Na fila';audit(db,u,'enqueue_simulation','batch',id);db.commit();return serialize(b)
@app.post('/api/batches/{id}/emit')
def real_emit(id:int,u=Depends(current_user)):
    raise HTTPException(501,'Emissão real bloqueada nesta versão. Nenhuma conexão fiscal implementada.')

@app.get('/api/drafts')
def draft_list(company_id:int|None=None,status:str='',q:str='',start:str='',end:str='',u=Depends(current_user),db=Depends(db_session)):
    query=select(Draft).join(Batch,Draft.batch_id==Batch.id)
    if u.role!='admin':query=query.where(Batch.owner_id==u.id)
    ids=company_ids(db,u)
    if ids is not None:query=query.where(Draft.company_id.in_(ids))
    if company_id:allowed_company(db,u,company_id);query=query.where(Draft.company_id==company_id)
    if status:query=query.where(Draft.status==status)
    rows=[serialize(d) for d in db.scalars(query.order_by(Draft.id.desc()))]
    return [d for d in rows if (not q or q.casefold() in (d['raw'].get('nome_tomador','')+d['raw'].get('documento_tomador','')).casefold()) and (not start or d['raw'].get('competencia','')>=start) and (not end or d['raw'].get('competencia','')<=end)]

@app.get('/api/dashboard')
def dashboard(u=Depends(current_user),db=Depends(db_session)):
    rows=draft_list(u=u,db=db);counts=defaultdict(int);bycompany={}
    for d in rows:
        counts[d['status']]+=1
        c=str(d['company_id']);bycompany.setdefault(c,{'company_id':d['company_id'],'count':0,'total_cents':0})
        bycompany[c]['count']+=1;bycompany[c]['total_cents']+=d['amount_cents']
    return {'total':len(rows),'counts':dict(counts),'prepared_cents':sum(d['amount_cents'] for d in rows if not d['errors']),'issued_cents':0,'companies':list(bycompany.values()),'mode':'simulation','states':ALL_STATES}

def excel_response(wb,filename):
    stream=io.BytesIO();wb.save(stream);stream.seek(0)
    return StreamingResponse(stream,media_type='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',headers={'Content-Disposition':f'attachment; filename="{filename}"'})
def safe_cell(value):
    s=str(value or '')
    return "'"+s if s.lstrip().startswith(('=','+','-','@')) else s

def template_workbook():
    wb=Workbook();ws=wb.active;ws.title='Notas';ws.append(HEADERS);ws.freeze_panes='A2';ws.auto_filter.ref='A1:M1'
    for c in ws[1]:c.font=Font(bold=True,color='FFFFFF');c.fill=PatternFill('solid',fgColor='165B45');ws.column_dimensions[c.column_letter].width=28
    helpws=wb.create_sheet('Instrucoes')
    for row in [ ['MODELO DE PREPARAÇÃO — SEM VALIDADE FISCAL'],['Uma linha = um rascunho. Preencha na aba Notas, sem renomear cabeçalhos.'],['CPF/CNPJ, códigos e competência devem ser texto. CNPJ alfanumérico ainda não suportado.'],['Competência: AAAA-MM-DD; código IBGE: 7 dígitos; tributação nacional: 6 dígitos.'],['ISS alíquota: percentual numérico; ISS retido: sim/nao; retenções: {} ou JSON em reais.'],['Valor: 1234,56 ou 1234.56. Não utilizar fórmulas.'],['Cadastre emitentes antes de importar. A aprovação exige conferência humana.'],['Campos são preparatórios: não abrangem todo o XSD; NBS/IBS/CBS e regras municipais serão tratados na fase 2.'],['codigo_tributacao_municipal e observacoes são opcionais; os demais campos são obrigatórios.'] ]:helpws.append(row)
    helpws.column_dimensions['A'].width=125
    return wb
@app.get('/api/template.xlsx')
def template(u=Depends(current_user)):return excel_response(template_workbook(),'modelo_preparacao.xlsx')
@app.get('/api/batches/{id}/report.xlsx')
def report(id:int,u=Depends(current_user),db=Depends(db_session)):
    b=get_or_404(db,Batch,id);batch_access(db,u,b)
    wb=Workbook();ws=wb.active;ws.title='Conferencia';ws.append(['linha','situacao',*HEADERS,'inconsistencias'])
    for d in db.scalars(select(Draft).where(Draft.batch_id==id).order_by(Draft.line)):
        ws.append([d.line,d.status,*[safe_cell(d.raw.get(h)) for h in HEADERS],safe_cell(' | '.join(d.errors))])
    ws.freeze_panes='A2';ws.auto_filter.ref=ws.dimensions
    return excel_response(wb,f'lote_{id}_conferencia.xlsx')

@app.get('/api/audit')
def audits(u=Depends(current_user),db=Depends(db_session)):
    role(u,['admin']);return [serialize(a) for a in db.scalars(select(Audit).order_by(Audit.id.desc()).limit(1000))]
class UserInput(Credentials):
    role:str
    company_ids:list[int]=Field(default_factory=list)
@app.get('/api/users')
def users(u=Depends(current_user),db=Depends(db_session)):
    role(u,['admin']);return [{**serialize(x),'company_ids':list(db.scalars(select(Access.company_id).where(Access.user_id==x.id)))} for x in db.scalars(select(User))]
@app.post('/api/users')
def add_user(data:UserInput,u=Depends(current_user),db=Depends(db_session)):
    role(u,['admin'])
    if data.role not in ['admin','operator','approver','viewer']:raise HTTPException(422,'Perfil inválido')
    for c in data.company_ids:get_or_404(db,Company,c)
    x=User(username=data.username,password_hash=hasher.hash(data.password),role=data.role);db.add(x);db.flush()
    for c in set(data.company_ids):db.add(Access(user_id=x.id,company_id=c))
    audit(db,u,'create_user','user',x.id);db.commit();return serialize(x)
@app.get('/api/backup')
def backup(u=Depends(current_user),db=Depends(db_session)):
    role(u,['admin'])
    if not URL.startswith('sqlite'):raise HTTPException(501,'Use pg_dump para PostgreSQL')
    audit(db,u,'backup','database',0);db.commit()
    # SQLite online backup produces a consistent image including committed WAL transactions.
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        path=Path(tmp)/'nfse.db'
        with engine.connect() as conn:
            with sqlite3.connect(path) as dst:conn.connection.driver_connection.backup(dst)
        buffer=io.BytesIO()
        with zipfile.ZipFile(buffer,'w',zipfile.ZIP_DEFLATED) as z:
            z.write(path,'nfse.db');z.writestr('LEIA.txt','Backup contém dados pessoais e hashes de senha. Guarde em local protegido. Restaure apenas com o servidor parado.')
        buffer.seek(0)
    return StreamingResponse(buffer,media_type='application/zip',headers={'Content-Disposition':'attachment; filename="backup_nfse.zip"'})

DIST=ROOT/'frontend'/'dist'
if DIST.exists():
    app.mount('/assets',StaticFiles(directory=DIST/'assets'),name='assets')
    @app.get('/')
    def index():return FileResponse(DIST/'index.html')


if not CLOUD:
    from .updates import router as updates_router
    app.include_router(updates_router)

@app.get('/api/health')
def health():
    import os
    return {'app_id':'triade-nfse','version':(ROOT/'VERSION').read_text().strip(),'instance':'cloud' if CLOUD else os.getenv('NFSE_INSTANCE','portable'),'local_connector_available':all((ROOT/'local_connector'/name).is_file() for name in ['Abrir_Conector.cmd','ConectorTriade.ps1','TriadeConnector.Core.psm1','TriadeDps.psm1','TriadeRestricted.psm1','LEIA-ME.txt'])}

@app.post('/api/batches/{id}/process-simulation')
def process_simulation(id:int,u=Depends(current_user),db=Depends(db_session)):
    """Bounded, durable work per request: no permanent thread in a serverless runtime."""
    role(u,['admin','approver'])
    b=get_or_404(db,Batch,id,locked=True);batch_access(db,u,b)
    if b.status not in ('Na fila','Em processamento','Simulado','Rejeitado'):
        raise HTTPException(409,'Envie o lote aprovado para simulação primeiro')
    query=select(Job).join(Draft,Job.draft_id==Draft.id).where(Draft.batch_id==id,Job.status=='Na fila').order_by(Job.id).limit(10)
    if not URL.startswith('sqlite'):query=query.with_for_update(of=Job,skip_locked=True)
    jobs=list(db.scalars(query))
    for job in jobs:
        d=db.get(Draft,job.draft_id);c=db.get(Company,d.company_id)
        if c and c.revision==d.company_revision:
            job.status=d.status='Simulado';job.result={'message':'Simulação concluída. Sem envio ou validade fiscal.'}
        else:
            job.status=d.status='Rejeitado';job.result={'message':'Cadastro alterado após aprovação. Prepare outro lote.'}
        audit(db,u,'simulation_finished','draft',d.id,{'status':d.status})
    db.flush()
    pending=db.scalar(select(func.count()).select_from(Job).join(Draft,Job.draft_id==Draft.id).where(Draft.batch_id==id,Job.status=='Na fila'))
    if not pending:
        failed=db.scalar(select(func.count()).select_from(Draft).where(Draft.batch_id==id,Draft.status=='Rejeitado'))
        b.status='Rejeitado' if failed else 'Simulado'
    db.commit()
    return {'processed':len(jobs),'pending':pending,'status':b.status}
