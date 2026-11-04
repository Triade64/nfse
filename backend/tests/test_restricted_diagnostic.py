from datetime import datetime,timedelta,timezone
import ssl
import pytest
from cryptography import x509
from cryptography.x509.oid import NameOID,ExtendedKeyUsageOID
from cryptography.hazmat.primitives import serialization,hashes
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from sqlalchemy import select
from app.db import Session
from app.models import Audit
from app import restricted_diagnostic as diagnostic

@pytest.fixture(scope='module')
def identity():
    key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
    def make(expired=False):
        now=datetime.now(timezone.utc);name=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'FICTICIO NAO ICP BRASIL')])
        cert=(x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now-timedelta(days=5)).not_valid_after(now+timedelta(days=-1 if expired else 10)).add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CLIENT_AUTH]),critical=False).sign(key,hashes.SHA256()))
        return pkcs12.serialize_key_and_certificates(b'ficticio',key,cert,None,serialization.BestAvailableEncryption(b'APENAS-TESTE-123'))
    return make

def test_offline_check_not_issuance_or_chain_validation(identity,monkeypatch):
    monkeypatch.setattr(diagnostic,'probe_documentation',lambda _:pytest.fail('Unexpected network'))
    result=diagnostic.diagnose(identity(),'APENAS-TESTE-123')
    assert result['offline_ok'] and not result['issuance_enabled'] and not result['connection']['attempted']
    assert 'FICTICIO NAO ICP BRASIL' not in str(result) and 'APENAS-TESTE-123' not in str(result)

def test_expired_wrong_password_and_large_file_rejected(identity):
    for blob,pw in [(identity(True),'APENAS-TESTE-123'),(identity(),'ERRADA'),(b'x'*(diagnostic.MAX_PFX+1),'APENAS-TESTE-123')]:
        with pytest.raises(diagnostic.DiagnosticError):diagnostic.diagnose(blob,pw)

def test_context_loads_encrypted_key_and_removes_temporary_directory(identity,monkeypatch,tmp_path):
    original=diagnostic.tempfile.TemporaryDirectory
    monkeypatch.setattr(diagnostic.tempfile,'TemporaryDirectory',lambda **kwargs:original(dir=tmp_path,**kwargs))
    key,cert,chain=pkcs12.load_key_and_certificates(identity(),b'APENAS-TESTE-123')
    ctx=diagnostic.certificate_context(key,cert,list(chain or []))
    assert ctx.check_hostname and ctx.verify_mode==ssl.CERT_REQUIRED
    assert list(tmp_path.iterdir())==[]

def test_probe_is_get_on_fixed_restricted_docs_and_no_redirect(monkeypatch):
    class Response:
        status=200
        def __enter__(self):return self
        def __exit__(self,*args):pass
    class Opener:
        def open(self,request,timeout):
            assert request.full_url==diagnostic.DOCS_URL and request.get_method()=='GET' and timeout==15
            return Response()
    monkeypatch.setattr(diagnostic,'build_opener',lambda *args:Opener())
    r=diagnostic.probe_documentation(ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT))
    assert r['http_status']==200
    assert diagnostic.NoRedirect().redirect_request(None,None,302,'',{},'https://example.com') is None

def test_endpoint_requires_consent_and_never_returns_secret(admin,identity):
    url='/api/integrations/restricted/diagnostic';files={'file':('ficticio.pfx',identity(),'application/octet-stream')}
    assert admin.post(url,data={'password':'APENAS-TESTE-123'},files=files).status_code==422
    r=admin.post(url,data={'password':'APENAS-TESTE-123','consent':'true'},files=files)
    assert r.status_code==200,r.text
    assert 'APENAS-TESTE-123' not in r.text and 'FICTICIO NAO ICP BRASIL' not in r.text
    r=admin.post(url,data={'password':'S'*513,'consent':'true'},files=files)
    assert r.status_code==422 and 'S'*513 not in r.text
    with Session() as db:
        a=db.scalar(select(Audit).where(Audit.action=='restricted_diagnostic'))
        assert a.info=={'connection_requested':False,'http_status':None}

def test_operator_cannot_send_certificate(admin,company,identity):
    admin.post('/api/users',json={'username':'operador-teste','password':'Senha-ficticia-456!','role':'operator','company_ids':[company['id']]})
    admin.post('/api/logout');admin.post('/api/login',json={'username':'operador-teste','password':'Senha-ficticia-456!'})
    assert admin.post('/api/integrations/restricted/diagnostic',data={'password':'APENAS-TESTE-123','consent':'true'},files={'file':('ficticio.pfx',identity())}).status_code==403
