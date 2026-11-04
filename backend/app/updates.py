import base64
import os
import threading
from pathlib import Path
from fastapi import APIRouter,Depends,HTTPException
from pydantic import BaseModel,Field
from .security import current_user,role
from . import update_core as core
from .db import ROOT

router=APIRouter(prefix='/api/updates')
lock=threading.Lock()

def install_root():
    value=os.getenv('NFSE_INSTALL_ROOT')
    if not value:raise HTTPException(409,'Use Instalar_no_PC.bat e abra o atalho para habilitar o atualizador')
    return Path(value)
def config(root):
    p=root/'update-source.json'
    return core.read_json(p) if p.exists() else {}
def current_version():
    p=ROOT/'VERSION'
    return p.read_text().strip() if p.exists() else '0.4.0'
def set_state(root,**state):core.atomic_json(root/'control'/'update-state.json',state)

@router.get('')
def status(u=Depends(current_user)):
    role(u,['admin'])
    managed=bool(os.getenv('NFSE_INSTALL_ROOT'))
    result={'managed':managed,'version':current_version(),'configured':False,'source':{},'state':{'phase':'idle'}}
    if managed:
        root=install_root();cfg=config(root)
        result['source']=cfg;result['configured']=bool(cfg.get('manifest_url') and cfg.get('public_key'))
        state=root/'control'/'update-state.json'
        if state.exists():result['state']=core.read_json(state)
    return result

class SourceInput(BaseModel):
    manifest_url:str=Field(max_length=2000)
    public_key:str=Field(max_length=100)
@router.put('/source')
def source(data:SourceInput,u=Depends(current_user)):
    role(u,['admin']);root=install_root()
    if not lock.acquire(blocking=False):raise HTTPException(409,'Preparação em andamento')
    try:
        core.https_url(data.manifest_url)
        if len(base64.b64decode(data.public_key,validate=True))!=32:raise ValueError()
        core.atomic_json(root/'update-source.json',data.model_dump())
        (root/'control'/'available.json').unlink(missing_ok=True)
        set_state(root,phase='idle',message='Fonte configurada. Verifique as atualizações.')
    except Exception as e:raise HTTPException(422,'Informe uma URL HTTPS e a chave pública Ed25519 válida do responsável pelas versões') from e
    finally:lock.release()
    return {'ok':True}

@router.post('/check')
def check(u=Depends(current_user)):
    role(u,['admin']);root=install_root()
    if not lock.acquire(blocking=False):raise HTTPException(409,'Preparação em andamento')
    try:
        result=core.check_release(config(root),current_version());payload=result['manifest']['payload']
        if result['available']:
            core.atomic_json(root/'control'/'available.json',result['manifest'])
            set_state(root,phase='available',version=payload['version'],notes=str(payload.get('notes',''))[:3000],message='Nova versão disponível')
        else:
            (root/'control'/'available.json').unlink(missing_ok=True)
            set_state(root,phase='idle',message='O sistema já está atualizado')
        return {'available':result['available'],'version':payload['version']}
    except Exception as e:raise HTTPException(422,'Não foi possível verificar a fonte ou a assinatura. Confira o endereço e a chave pública.') from e
    finally:lock.release()

@router.post('/prepare')
def prepare(u=Depends(current_user)):
    role(u,['admin']);root=install_root()
    available=root/'control'/'available.json'
    if not available.exists():raise HTTPException(409,'Verifique as atualizações primeiro')
    if not lock.acquire(blocking=False):raise HTTPException(409,'Preparação em andamento')
    try:
        envelope=core.read_json(available);cfg=config(root);payload=core.verify_envelope(envelope,cfg['public_key'])
        set_state(root,phase='preparing',version=payload['version'],message='Baixando e preparando a atualização. Você pode continuar usando o sistema.')
        def work():
            try:
                core.stage_release(root,cfg,envelope)
                set_state(root,phase='ready',version=payload['version'],message='Atualização preparada. Salve os rascunhos antes de aplicar.')
            except Exception:
                set_state(root,phase='error',message='Não foi possível preparar a versão. A instalação atual foi preservada. Consulte updates.log ou peça suporte.')
            finally:lock.release()
        threading.Thread(target=work,daemon=True).start()
    except Exception:
        lock.release();raise HTTPException(422,'Manifesto inválido. Verifique as atualizações novamente.')
    return {'phase':'preparing'}

class ApplyInput(BaseModel):
    confirm_saved:bool=False
@router.post('/apply')
def apply(data:ApplyInput,u=Depends(current_user)):
    role(u,['admin']);root=install_root()
    if not data.confirm_saved:raise HTTPException(422,'Confirme que os rascunhos foram salvos')
    if not lock.acquire(blocking=False):raise HTTPException(409,'Preparação em andamento')
    try:
        state=core.read_json(root/'control'/'update-state.json')
        if state.get('phase')!='ready':raise HTTPException(409,'Prepare a atualização antes de aplicar')
        version=state['version'];core.version_tuple(version)
        envelope=core.read_json(root/'releases'/version/'ready.json')
        payload=core.verify_envelope(envelope,config(root)['public_key'])
        if payload['version']!=version:raise ValueError()
        core.atomic_json(root/'control'/'restart.json',{'version':version})
        set_state(root,phase='restarting',version=version,message='Encerrando com segurança, fazendo backup e reiniciando…')
    except HTTPException:raise
    except Exception as e:raise HTTPException(422,'A preparação não confere. Verifique a atualização novamente.') from e
    finally:lock.release()
    return {'phase':'restarting','version':version}

@router.post('/exit')
def exit_app(data:ApplyInput,u=Depends(current_user)):
    role(u,['admin']);root=install_root()
    if not data.confirm_saved:raise HTTPException(422,'Salve os rascunhos antes de encerrar')
    if not lock.acquire(blocking=False):raise HTTPException(409,'Preparação em andamento')
    try:core.atomic_json(root/'control'/'exit.json',{'requested':True})
    finally:lock.release()
    return {'ok':True}
