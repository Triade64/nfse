"""Transient PKCS#12 diagnostic. No issuance, storage, arbitrary URL or production access."""
import os
import secrets
import ssl
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, build_opener, HTTPSHandler, HTTPRedirectHandler
from cryptography import x509
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import ExtendedKeyUsageOID

DOCS_URL='https://sefin.producaorestrita.nfse.gov.br/API/SefinNacional/docs/index'
MAX_PFX=256*1024

class DiagnosticError(ValueError):pass

class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):return None

def certificate_context(key,cert,chain):
    # Default CA and hostname verification remain enabled. Explicit SSLContext avoids key-log env hooks.
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.load_default_certs();context.minimum_version=ssl.TLSVersion.TLSv1_2
    temporary_password=secrets.token_urlsafe(32).encode('ascii')
    with tempfile.TemporaryDirectory(prefix='nfse-tls-') as directory:
        os.chmod(directory,0o700)
        for name,content in [('chain.pem',b''.join(c.public_bytes(serialization.Encoding.PEM) for c in [cert,*chain])),('key.pem',key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.BestAvailableEncryption(temporary_password)))]:
            fd=os.open(Path(directory)/name,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
            with os.fdopen(fd,'wb') as out:out.write(content)
        context.load_cert_chain(str(Path(directory)/'chain.pem'),str(Path(directory)/'key.pem'),password=temporary_password)
    return context

def probe_documentation(context):
    opener=build_opener(HTTPSHandler(context=context),NoRedirect())
    try:
        with opener.open(Request(DOCS_URL,headers={'User-Agent':'Triade-NFSe-Diagnostic/0.5'},method='GET'),timeout=15) as response:
            return {'attempted':True,'http_status':response.status,'message':'O servidor respondeu. Isso não confirma permissão para emitir ou representar clientes.'}
    except HTTPError as error:
        error.close()
        return {'attempted':True,'http_status':error.code,'message':'Resposta HTTP sem confirmação de acesso à documentação. Redirecionamentos não são seguidos.'}
    except (URLError,TimeoutError,OSError):
        return {'attempted':True,'http_status':None,'message':'Não foi possível concluir a conexão TLS/HTTP. Confira cadeia do certificado, rede e disponibilidade do serviço.'}

def diagnose(data:bytes,password:str,check_connection:bool=False):
    if not data or len(data)>MAX_PFX:raise DiagnosticError('Arquivo vazio ou maior que 256 KB.')
    if not password or len(password)>512:raise DiagnosticError('Informe a senha do arquivo A1 (até 512 caracteres).')
    try:key,cert,chain=pkcs12.load_key_and_certificates(data,password.encode('utf-8'))
    except Exception:raise DiagnosticError('Não foi possível abrir o A1. Confira o arquivo e a senha.') from None
    if key is None or cert is None:raise DiagnosticError('O arquivo precisa conter certificado e chave privada.')
    public=lambda k:k.public_bytes(serialization.Encoding.DER,serialization.PublicFormat.SubjectPublicKeyInfo)
    if public(key.public_key())!=public(cert.public_key()):raise DiagnosticError('Chave privada incompatível com o certificado.')
    now=datetime.now(timezone.utc)
    if not cert.not_valid_before_utc<=now<=cert.not_valid_after_utc:raise DiagnosticError('Certificado fora do período de validade.')
    try:
        eku=cert.extensions.get_extension_for_class(x509.ExtendedKeyUsage).value
        if ExtendedKeyUsageOID.CLIENT_AUTH not in eku:raise DiagnosticError('O certificado não declara a finalidade Autenticação do Cliente.')
    except x509.ExtensionNotFound:pass
    result={'environment':'restricted','offline_ok':True,'expires_on':cert.not_valid_after_utc.date().isoformat(),'chain_certificates':len(chain or []),'connection':{'attempted':False,'http_status':None,'message':'Conexão externa não solicitada.'},'issuance_enabled':False,'warnings':['Diagnóstico não valida procuração, credenciamento, revogação ou cadeia ICP-Brasil.','Nenhuma DPS foi enviada. Simulação local continua sendo um fluxo separado.']}
    if check_connection:
        try:result['connection']=probe_documentation(certificate_context(key,cert,list(chain or [])))
        except Exception:result['connection']={'attempted':False,'http_status':None,'message':'Não foi possível preparar o certificado para TLS. Nenhum envio fiscal foi realizado.'}
    return result
