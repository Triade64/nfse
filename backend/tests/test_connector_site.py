import base64
import hashlib
from datetime import datetime, timezone, timedelta
from urllib.parse import urlsplit, parse_qs
from lxml import etree
from sqlalchemy import select, update
from app.db import Session
from app.models import ConnectorTicket, DPS, Audit

PROFILE={'op_simp_nac':'3','reg_ap_trib_sn':'1','reg_esp_trib':'0','totals_mode':'simples_percent','include_provider_im':False,'include_iss_rate':False,'series':'1'}
KEY='42057042112223330001810000000000000126116525669388'
SIGNED='a'*64

def setup_reserved(admin,company,row,count=1):
    admin.put(f'/api/companies/{company["id"]}',json={'cnpj':company['cnpj'],'name':company['name'],'config':{**company['config'],'perfil_fiscal':PROFILE}})
    admin.put(f'/api/companies/{company["id"]}/dps-series',json={'series':'1','next_number':10,'expected_revision':None,'confirm_unused':True})
    ids=[]
    for i in range(count):
        b=admin.post('/api/batches',json={'name':'x','rows':[{**row,'descricao_servico':f'SERVICO {i}'}]}).json()
        n=next(x for x in admin.get('/api/notes').json() if x['batch_id']==b['id'])
        r=admin.post(f'/api/notes/{n["id"]}/emit',json={'batch_revision':n['batch_revision'],'expected_raw':n['raw'],'confirm':True,'simples_percent':'6.54'})
        assert r.status_code==200,r.text;ids.append(r.json()['id'])
    return ids

def ticket(admin,ids):
    r=admin.post('/api/connector/tickets',json={'dps_ids':ids});assert r.status_code==200,r.text
    url=r.json()['url'];parts=urlsplit(url);q=parse_qs(parts.query)
    assert parts.scheme=='triade-nfse' and parts.netloc=='assinar'
    return q['ticket'][0],q['site'][0]

def as_connector(client,token):
    # The connector is not a browser: no session cookie, only the bearer ticket.
    client.cookies.clear()
    return {'Authorization':'Bearer '+token,'X-Requested-With':'nfse-local'}

def nfse_for(reserved_xml,key=KEY,mutate=None):
    dps=etree.fromstring(reserved_xml.encode())
    if mutate:mutate(dps)
    ns='http://www.sped.fazenda.gov.br/nfse'
    root=etree.Element('{%s}NFSe'%ns,nsmap={None:ns},versao='1.01');info=etree.SubElement(root,'{%s}infNFSe'%ns,Id='NFS'+key)
    etree.SubElement(info,'{%s}nNFSe'%ns).text='1';info.append(dps)
    return base64.b64encode(etree.tostring(root,xml_declaration=True,encoding='UTF-8')).decode()

def stored_xml(dps_id):
    with Session() as db:return db.get(DPS,dps_id).xml

def result(client,headers,dps_id,**body):
    return client.post(f'/api/connector/jobs/{dps_id}/result',headers=headers,json={'state':'Autorizada em teste','http_status':201,'signed_sha256':SIGNED,**body})

def test_ticket_link_jobs_and_authorized_result(admin,company,row):
    ids=setup_reserved(admin,company,row,2)
    token,site=ticket(admin,ids)
    assert site=='http://testserver'
    with Session() as db:
        t=db.scalar(select(ConnectorTicket));assert t.token_hash==hashlib.sha256(token.encode()).hexdigest() and token not in str(t.dps_ids)
        assert all(token not in str(a.info) for a in db.scalars(select(Audit)))
    h=as_connector(admin,token)
    jobs=admin.get('/api/connector/jobs',headers=h).json()['jobs']
    assert [j['number'] for j in jobs]==[10,11] and jobs[0]['summary']['cnpj']=='11222333000181'
    assert hashlib.sha256(jobs[0]['xml'].encode()).hexdigest()==jobs[0]['xml_sha256']
    r=result(admin,h,ids[0],access_key=KEY,nfse_xml_b64=nfse_for(jobs[0]['xml']));assert r.status_code==200,r.text
    assert r.json()['status']=='Autorizada' and r.json()['access_key']==KEY and 'nfse_xml' not in r.json()
    assert result(admin,h,ids[0],access_key=KEY,nfse_xml_b64=nfse_for(jobs[0]['xml'])).status_code==200  # idempotent
    assert result(admin,h,ids[0],state='Rejeitada em teste',http_status=400,codes='E0001').status_code==409  # final
    r=result(admin,h,ids[1],state='Rejeitada em teste',http_status=400,codes='E0712');assert r.json()['status']=='Rejeitada'
    admin.post('/api/login',json={'username':'administrador','password':'Senha-ficticia-123!'})
    notes={n['dps']['id']:n for n in admin.get('/api/notes').json() if n['dps']}
    assert notes[ids[0]]['situation']=='NFS-e autorizada' and notes[ids[1]]['situation']=='DPS rejeitada'
    xml=admin.get(f'/api/dps/{ids[0]}/nfse.xml');assert xml.status_code==200 and KEY.encode() in xml.content
    assert admin.post(f'/api/dps/{ids[1]}/discard',json={'reason':'Rejeitada E0712','confirm_not_authorized':True}).status_code==200
    assert admin.post(f'/api/dps/{ids[0]}/discard',json={'reason':'tentativa indevida','confirm_not_authorized':True}).status_code==409

def test_authorized_result_must_contain_the_reserved_dps(admin,company,row):
    ids=setup_reserved(admin,company,row)
    token,_=ticket(admin,ids);h=as_connector(admin,token);xml=stored_xml(ids[0])
    ns='{http://www.sped.fazenda.gov.br/nfse}'
    def other_value(d):d.find(f'.//{ns}vServ').text='999.99'
    def other_id(d):d.find(f'{ns}infDPS').set('Id','DPS'+'9'*42)
    def production(d):d.find(f'.//{ns}tpAmb').text='1'
    for body in [dict(access_key=KEY,nfse_xml_b64=nfse_for(xml,mutate=other_value)),
                 dict(access_key=KEY,nfse_xml_b64=nfse_for(xml,mutate=other_id)),
                 dict(access_key=KEY,nfse_xml_b64=nfse_for(xml,mutate=production)),
                 dict(access_key=KEY,nfse_xml_b64=nfse_for(xml,key='1'*50)),
                 dict(access_key='123',nfse_xml_b64=nfse_for(xml)),
                 dict(access_key=KEY,nfse_xml_b64='não-é-base64'),
                 dict(access_key=KEY,nfse_xml_b64=base64.b64encode(b'<!DOCTYPE x [<!ENTITY a "b">]><x/>').decode())]:
        r=result(admin,h,ids[0],**body);assert r.status_code==422,(body.get('access_key'),r.text)
    with Session() as db:assert db.get(DPS,ids[0]).status=='Reservada'

def test_ticket_scope_expiry_and_permissions(admin,company,row):
    ids=setup_reserved(admin,company,row,2)
    token,_=ticket(admin,[ids[0]]);h=as_connector(admin,token)
    assert result(admin,h,ids[1],state='Rejeitada em teste',http_status=400).status_code==403  # outside the ticket
    assert admin.get('/api/connector/jobs',headers={'Authorization':'Bearer outro-token-qualquer-1234567890'}).status_code==401
    assert admin.get('/api/connector/jobs').status_code==401
    with Session() as db:
        db.execute(update(ConnectorTicket).values(expires_at=(datetime.now(timezone.utc)-timedelta(seconds=1)).isoformat()));db.commit()
    assert admin.get('/api/connector/jobs',headers=h).status_code==401
    admin.post('/api/login',json={'username':'administrador','password':'Senha-ficticia-123!'})
    assert admin.post('/api/connector/tickets',json={'dps_ids':[ids[0],ids[0]]}).status_code==422
    admin.post(f'/api/dps/{ids[1]}/discard',json={'reason':'teste descarte','confirm_not_authorized':True})
    r=admin.post('/api/connector/tickets',json={'dps_ids':[ids[1]]});assert r.status_code==409 and 'Descartada' in r.json()['detail']
    admin.post('/api/users',json={'username':'operador9','password':'Senha-ficticia-999!','role':'operator','company_ids':[company['id']]})
    admin.post('/api/logout');admin.post('/api/login',json={'username':'operador9','password':'Senha-ficticia-999!'})
    assert admin.post('/api/connector/tickets',json={'dps_ids':[ids[0]]}).status_code==403

def test_unknown_result_keeps_dps_open_for_a_later_consultation(admin,company,row):
    ids=setup_reserved(admin,company,row)
    token,_=ticket(admin,ids);h=as_connector(admin,token)
    r=result(admin,h,ids[0],state='Situação desconhecida; consultar',http_status=0,message='timeout');assert r.json()['status']=='Desconhecida'
    admin.post('/api/login',json={'username':'administrador','password':'Senha-ficticia-123!'})
    assert admin.post(f'/api/dps/{ids[0]}/discard',json={'reason':'nao pode','confirm_not_authorized':True}).status_code==409
    token2,_=ticket(admin,ids);h2=as_connector(admin,token2)  # a new ticket to consult again is allowed
    r=result(admin,h2,ids[0],access_key=KEY,nfse_xml_b64=nfse_for(stored_xml(ids[0])));assert r.json()['status']=='Autorizada'

PDF=b'%PDF-1.7\n%ficticio\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n'

def danfse(client,headers,dps_id,**body):
    return client.post(f'/api/connector/jobs/{dps_id}/danfse',headers=headers,json=body)

def test_danfse_is_received_from_connector_and_downloaded_on_the_site(admin,company,row):
    ids=setup_reserved(admin,company,row)
    token,_=ticket(admin,ids);h=as_connector(admin,token)
    assert danfse(admin,h,ids[0],pdf_b64=base64.b64encode(PDF).decode()).status_code==409  # not authorized yet
    result(admin,h,ids[0],access_key=KEY,nfse_xml_b64=nfse_for(stored_xml(ids[0])))
    assert danfse(admin,h,ids[0],pdf_b64=base64.b64encode(b'<html>nao e pdf</html>').decode()).status_code==422
    assert danfse(admin,h,ids[0],pdf_b64='***').status_code==422
    assert danfse(admin,h,ids[0]).status_code==422  # neither PDF nor error
    r=danfse(admin,h,ids[0],error_code='DANFSE_HTTP_404');assert r.status_code==200 and r.json()['danfse_error']=='DANFSE_HTTP_404' and r.json()['has_danfse'] and not r.json()['danfse_official']  # generated from the XML
    r=danfse(admin,h,ids[0],pdf_b64=base64.b64encode(PDF).decode());assert r.status_code==200 and r.json()['danfse_official'] and r.json()['danfse_error'] is None
    assert 'danfse_pdf' not in r.json()
    assert danfse(admin,h,ids[0],error_code='DANFSE_HTTP_500').json()['has_danfse']  # a later failure never erases a stored PDF
    admin.post('/api/login',json={'username':'administrador','password':'Senha-ficticia-123!'})
    d=admin.get(f'/api/dps/{ids[0]}/danfse.pdf');assert d.status_code==200 and d.content==PDF and d.headers['content-type']=='application/pdf'
    note=next(n for n in admin.get('/api/notes').json() if n['dps'] and n['dps']['id']==ids[0]);assert note['dps']['has_danfse']

def test_authorized_nfse_gets_a_generated_danfse_without_a_connector_trip(admin,company,row):
    ids=setup_reserved(admin,company,row)
    token,_=ticket(admin,ids);h=as_connector(admin,token)
    admin.post('/api/login',json={'username':'administrador','password':'Senha-ficticia-123!'})
    assert admin.get(f'/api/dps/{ids[0]}/danfse.pdf').status_code==404  # not authorized yet
    result(admin,as_connector(admin,token),ids[0],access_key=KEY,nfse_xml_b64=nfse_for(stored_xml(ids[0])))
    admin.post('/api/login',json={'username':'administrador','password':'Senha-ficticia-123!'})
    note=next(n for n in admin.get('/api/notes').json() if n['dps'] and n['dps']['id']==ids[0])
    assert note['dps']['has_danfse'] and not note['dps']['danfse_official']
    d=admin.get(f'/api/dps/{ids[0]}/danfse.pdf')
    assert d.status_code==200 and d.content.startswith(b'%PDF-') and d.headers['content-type']=='application/pdf'
    assert 'DANFSe_'+KEY in d.headers['content-disposition']
    assert admin.post('/api/connector/tickets',json={'dps_ids':ids}).status_code==409  # nothing for the connector to do
    from app.db import Session as S
    from app.models import Audit as A
    with S() as db:assert db.scalar(select(A).where(A.action=='download_danfse')).info=={'official':False}

def test_danfse_download_requires_session_and_company_access(admin,company,row):
    ids=setup_reserved(admin,company,row)
    admin.post('/api/logout')
    assert admin.get(f'/api/dps/{ids[0]}/danfse.pdf').status_code==401
