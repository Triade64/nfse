"""Signed releases, isolated staging and data-preserving activation primitives.
No automatic publishing, no credentials, and no unsigned remote execution.
"""
import base64
import hashlib
import json
import os
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import venv
import zipfile
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

APP_ID='triade-nfse'
VERSION_PATTERN=r'\d+\.\d+\.\d+'
MAX_PACKAGE=100*1024*1024
MAX_EXPANDED=350*1024*1024
class UpdateError(ValueError):pass

def atomic_json(path, data):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    temp=path.with_suffix(path.suffix+'.tmp')
    temp.write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf-8');os.replace(temp,path)

def read_json(path):return json.loads(Path(path).read_text(encoding='utf-8'))
def version_tuple(v):
    if not isinstance(v,str) or not re.fullmatch(VERSION_PATTERN,v):raise UpdateError('Versão inválida')
    return tuple(map(int,v.split('.')))
def canonical(data):return json.dumps(data,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()
def https_url(url):
    p=urllib.parse.urlsplit(url)
    if p.scheme!='https' or not p.hostname or p.username or p.password or p.fragment:raise UpdateError('Use endereço HTTPS sem credenciais ou fragmento')
    return url
class SecureRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        https_url(newurl)
        return super().redirect_request(req,fp,code,msg,headers,newurl)

def download(url, limit):
    https_url(url)
    request=urllib.request.Request(url,headers={'User-Agent':'Triade-NFSe-Updater/1'})
    with urllib.request.build_opener(SecureRedirect()).open(request,timeout=30) as r:
        https_url(r.geturl())
        data=r.read(limit+1)
        if len(data)>limit:raise UpdateError('Download excede o limite permitido')
        return data

def verify_envelope(envelope,public_key):
    try:
        payload=envelope['payload']
        key=Ed25519PublicKey.from_public_bytes(base64.b64decode(public_key,validate=True))
        key.verify(base64.b64decode(envelope['signature'],validate=True),canonical(payload))
    except Exception as e:raise UpdateError('Assinatura da atualização inválida') from e
    if payload.get('app_id')!=APP_ID or payload.get('format')!=1:raise UpdateError('Pacote de outro aplicativo ou formato')
    version_tuple(payload.get('version'))
    if payload.get('data_schema')!=1 or payload.get('launcher_min',1)>1:raise UpdateError('Esta versão exige um novo instalador; atualização automática recusada')
    https_url(payload.get('package_url',''))
    if not re.fullmatch('[a-f0-9]{64}',str(payload.get('sha256',''))):raise UpdateError('Hash inválido')
    if type(payload.get('size')) is not int or not 0<payload['size']<=MAX_PACKAGE:raise UpdateError('Tamanho inválido')
    return payload

def check_release(config,current_version):
    if not config.get('manifest_url') or not config.get('public_key'):raise UpdateError('Configure a fonte de atualizações primeiro')
    envelope=json.loads(download(config['manifest_url'],128*1024))
    payload=verify_envelope(envelope,config['public_key'])
    return {'available':version_tuple(payload['version'])>version_tuple(current_version),'manifest':envelope}

def safe_extract(archive,destination):
    destination=Path(destination)
    with zipfile.ZipFile(archive) as z:
        entries=z.infolist()
        if len(entries)>2000 or sum(i.file_size for i in entries)>MAX_EXPANDED:raise UpdateError('Pacote descompactado excessivo')
        seen=set()
        for info in entries:
            name=info.filename
            if '\\' in name or ':' in name or name.startswith('/') or stat.S_ISLNK(info.external_attr>>16):raise UpdateError('Caminho inseguro no pacote')
            parts=name.rstrip('/').split('/')
            if parts[0]!='nfse-triade' or any(p in ('','.','..') or p.endswith(('.', ' ')) for p in parts):raise UpdateError('Estrutura inválida do pacote')
            reserved={'CON','PRN','AUX','NUL',*[f'COM{i}' for i in range(1,10)],*[f'LPT{i}' for i in range(1,10)]}
            if any(p.split('.')[0].upper() in reserved for p in parts):raise UpdateError('Nome reservado no pacote')
            relative=parts[1:]
            if any(p.casefold() in ('data','.venv','node_modules','.git') for p in relative):raise UpdateError('Pacote não pode conter dados, ambientes ou repositórios')
            lower='/'.join(parts).casefold()
            if lower in seen:raise UpdateError('Caminho duplicado no pacote')
            seen.add(lower)
        z.extractall(destination)
    app=destination/'nfse-triade'
    for required in ['VERSION','requirements.txt','backend/app/main.py','frontend/dist/index.html']:
        if not (app/required).is_file():raise UpdateError('Pacote incompleto')
    return app

def env_python(app):return Path(app)/'.venv'/('Scripts/python.exe' if os.name=='nt' else 'bin/python')
def run_checked(command,env=None,log=None):
    result=subprocess.run([str(c) for c in command],env=env,stdout=log or subprocess.DEVNULL,stderr=log or subprocess.DEVNULL,timeout=600)
    if result.returncode:raise UpdateError('Falha ao preparar dependências ou verificar a nova versão. Consulte o log local.')

def prepare_environment(app, log=None):
    venv.EnvBuilder(with_pip=True).create(Path(app)/'.venv')
    run_checked([env_python(app),'-m','pip','install','--disable-pip-version-check','-r',Path(app)/'requirements.txt'],log=log)
    # Probe uses an isolated temporary database, never the office database.
    with tempfile.TemporaryDirectory() as td:
        env={**os.environ,'PYTHONPATH':str(Path(app)/'backend'),'DATABASE_URL':'sqlite:///'+str(Path(td)/'probe.db'),'NFSE_DATA_DIR':td}
        run_checked([env_python(app),'-c','from app.main import app; from app.db import Base,engine; Base.metadata.create_all(engine); assert any(r.path == "/api/health" for r in app.routes)'],env=env,log=log)

def stage_release(root,config,envelope, prepare=prepare_environment,fetch=download):
    root=Path(root);payload=verify_envelope(envelope,config['public_key']);version=payload['version']
    current=read_json(root/'current.json')
    if version_tuple(version)<=version_tuple(current['version']):raise UpdateError('A versão instalada já é igual ou mais recente')
    target=root/'releases'/version
    if target.exists():
        receipt=target/'ready.json'
        if receipt.is_file() and read_json(receipt)==envelope:return target
        raise UpdateError('Já existe uma preparação incompleta desta versão; consulte o suporte')
    package=fetch(payload['package_url'],payload['size'])
    if len(package)!=payload['size'] or hashlib.sha256(package).hexdigest()!=payload['sha256']:raise UpdateError('Conteúdo da atualização não confere com o manifesto assinado')
    target.parent.mkdir(parents=True,exist_ok=True)
    staging=Path(tempfile.mkdtemp(prefix='preparando-',dir=target.parent))
    try:
        archive=staging/'download.zip';archive.write_bytes(package)
        app=safe_extract(archive,staging)
        if app.joinpath('VERSION').read_text().strip()!=version:raise UpdateError('Versão interna divergente')
        # Rename BEFORE creating the venv: Windows virtual environments cannot be relocated.
        os.replace(staging,target)
        try:
            with (root/'updates.log').open('a',encoding='utf-8') as log:prepare(target/'nfse-triade',log)
            atomic_json(target/'ready.json',envelope)
        except Exception:
            shutil.rmtree(target,ignore_errors=True);raise
        return target
    finally:
        if staging.exists():shutil.rmtree(staging,ignore_errors=True)

def backup_database(root):
    root=Path(root);db=root/'data'/'nfse.db'
    if not db.exists():return None
    from datetime import datetime,timezone
    backup=root/'backups'/('antes-atualizacao-'+datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S-%f')+'.db')
    backup.parent.mkdir(parents=True,exist_ok=True)
    with sqlite3.connect(db) as source,sqlite3.connect(backup) as dest:source.backup(dest)
    return backup

def install_pointer(root,version):
    version_tuple(version);root=Path(root)
    if not (root/'releases'/version/'nfse-triade'/'VERSION').is_file():raise UpdateError('Versão preparada não encontrada')
    atomic_json(root/'current.json',{'version':version})
