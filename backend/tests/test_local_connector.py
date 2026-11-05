import io,zipfile

def test_certificate_upload_is_gone_before_parsing_body(admin):
    r=admin.post('/api/integrations/restricted/diagnostic',content=b'FICTICIO-NUNCA-PROCESSAR',headers={'Content-Type':'multipart/form-data; boundary=incompleto'})
    assert r.status_code==410 and 'FICTICIO' not in r.text

def test_connector_download_requires_admin_and_contains_only_public_program(admin,company):
    r=admin.get('/api/local-connector/download');assert r.status_code==200
    with zipfile.ZipFile(io.BytesIO(r.content)) as z:
        from app.dps_preview import SCHEMA_DIR
        expected=['Abrir_Conector.cmd','ConectorTriade.ps1','TriadeConnector.Core.psm1','TriadeDps.psm1','LEIA-ME.txt']+['schemas/'+p.name for p in SCHEMA_DIR.glob('*.xsd')]
        assert len(expected)==15
        assert sorted(z.namelist())==sorted('Triade_Conector_Local/'+n for n in expected)
        assert z.read('Triade_Conector_Local/ConectorTriade.ps1').startswith(b'\xef\xbb\xbf')
    admin.post('/api/users',json={'username':'operador-teste','password':'Senha-ficticia-456!','role':'operator','company_ids':[company['id']]})
    admin.post('/api/logout');admin.post('/api/login',json={'username':'operador-teste','password':'Senha-ficticia-456!'})
    assert admin.get('/api/local-connector/download').status_code==403
    admin.post('/api/logout');assert admin.get('/api/local-connector/download').status_code==401
