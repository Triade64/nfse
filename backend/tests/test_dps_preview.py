import hashlib
import json
from pathlib import Path
from lxml import etree
import pytest
from app.dps_preview import PreviewOptions, build_preview, SCHEMA_DIR
from app.db import Session
from app.models import DPS, NFSe, Audit
from sqlalchemy import select

OPTIONS=dict(include_provider_im=False,revision=1,expected_raw={},own_company_cnpj='11222333000181',confirm_offline=True,confirm_scope=True,series='12',number='1',issued_at='2026-11-05T10:00:00-03:00',op_simp_nac='3',reg_ap_trib_sn='1',reg_esp_trib='0',totals_mode='simples_percent',simples_percent='6.00',include_iss_rate=False)

def test_new_restricted_layout_and_escaped_content(row,company):
    xml=build_preview({**row,'descricao_servico':'Teste & conferência <fictícia>'},company,PreviewOptions(**OPTIONS))
    root=etree.fromstring(xml);ns={'n':root.nsmap[None]}
    assert root.xpath('string(n:infDPS/n:finNFSe)',namespaces=ns)=='0'
    assert root.xpath('string(n:infDPS/n:tpAmb)',namespaces=ns)=='2'
    assert root.xpath('string(n:infDPS/n:serv/n:cServ/n:xDescServ)',namespaces=ns)=='Teste & conferência <fictícia>'
    assert root[0].get('Id')=='DPS420570421122233300018100012000000000000001'
    assert not root.xpath('//n:pAliq',namespaces=ns)
    # The uploaded XSD, not an old production XSD, must reject a missing new field.
    root[0].remove(root.find('.//{*}finNFSe'))
    schema=etree.XMLSchema(etree.parse(str(SCHEMA_DIR/'DPS_v1.01.xsd')))
    assert not schema.validate(root)

@pytest.mark.parametrize('change',[{'own_company_cnpj':'00000000000000'},{'op_simp_nac':'1'},{'series':'90000'},{'issued_at':'2026-11-05T10:00:00'},{'confirm_offline':False},{'environment':1}])
def test_options_fail_closed(row,company,change):
    with pytest.raises(ValueError):build_preview(row,company,PreviewOptions(**{**OPTIONS,**change}))

@pytest.mark.parametrize('change',[{'iss_retido':'sim'},{'retencoes':json.dumps({'irrf':'10'})},{'codigo_tributacao_nacional':'123'}])
def test_unsupported_operation_is_not_silently_changed(row,company,change):
    with pytest.raises(ValueError):build_preview({**row,**change},company,PreviewOptions(**OPTIONS))

def test_endpoint_is_offline_audited_and_stale_protected(admin,company,row):
    b=admin.post('/api/batches',json={'name':'Teste fictício','rows':[row]}).json()
    b=admin.get('/api/batches/'+str(b['id'])).json();d=b['rows'][0]
    url=f'/api/drafts/{d["id"]}/restricted-preview'
    response=admin.post(url,json={**OPTIONS,'revision':b['revision'],'expected_raw':d['raw']});assert response.status_code==200,response.text
    result=response.json();assert not result['submitted'] and not result['number_reserved']
    assert result['sha256']==hashlib.sha256(result['xml'].encode()).hexdigest()
    assert admin.post(url,json={**OPTIONS,'revision':b['revision']+1}).status_code==409
    assert admin.post(url,json={**OPTIONS,'revision':b['revision'],'expected_raw':{}}).status_code==409
    after=admin.get('/api/batches/'+str(b['id'])).json();assert after['rows']==b['rows'] and after['status']==b['status']
    with Session() as db:
        assert not list(db.scalars(select(DPS))) and not list(db.scalars(select(NFSe)))
        events=list(db.scalars(select(Audit).where(Audit.action=='offline_dps_preview')))
        assert len(events)==1 and 'xml' not in events[0].info
    admin.post('/api/logout');assert admin.post(url,json=OPTIONS).status_code==401


def test_utc_emission_uses_same_instant_in_brasilia(row,company):
    from datetime import datetime, timezone, timedelta
    xml=build_preview(row,company,PreviewOptions(**{**OPTIONS,'issued_at':'2026-11-05T13:03:00+00:00'}))
    text=etree.fromstring(xml).find('.//{*}dhEmi').text
    assert text=='2026-11-05T10:03:00-03:00'
    assert datetime.fromisoformat(text)==datetime.fromisoformat('2026-11-05T13:03:00+00:00')
    with pytest.raises(ValueError,match='futura'):
        PreviewOptions(**{**OPTIONS,'issued_at':datetime.now(timezone.utc)+timedelta(hours=1)})


def test_im_is_explicit_without_changing_company_registration(row,company):
    import copy
    registered=copy.deepcopy(company)
    registered['config']['inscricao_municipal']='1234567'
    snapshot=copy.deepcopy(registered)
    omitted=etree.fromstring(build_preview(row,registered,PreviewOptions(**OPTIONS)))
    included=etree.fromstring(build_preview(row,registered,PreviewOptions(**{**OPTIONS,'include_provider_im':True})))
    assert omitted.find('.//{*}prest/{*}IM') is None
    assert included.find('.//{*}prest/{*}IM').text=='1234567'
    assert registered==snapshot
    with pytest.raises(ValueError,match='sem inscrição'):
        build_preview(row,company,PreviewOptions(**{**OPTIONS,'include_provider_im':True}))
