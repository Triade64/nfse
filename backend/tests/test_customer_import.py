"""0.12.0: customers (tomadores) imported from a spreadsheet: template, preview and all-or-nothing import."""
import io
from openpyxl import Workbook, load_workbook
from sqlalchemy import select
from app.db import Session
from app.models import Audit, Customer
from app.customer_import import COLUMNS

ADDRESS={'cep':'88495000','logradouro':'RUA A','numero':'10','complemento':'','bairro':'CENTRO','municipio_ibge':'4205704'}

def xlsx(rows,heads=COLUMNS,sheet='Tomadores'):
    wb=Workbook();ws=wb.active;ws.title=sheet;ws.append(heads)
    for r in rows:ws.append([r.get(h,'') for h in heads])
    b=io.BytesIO();wb.save(b);return b.getvalue()

def send(client,data,name='tomadores.xlsx',**params):
    return client.post('/api/customers/import',params=params,files={'file':(name,data,'application/octet-stream')})

def person(**change):
    return {'cnpj_emitente':'11222333000181','documento_tomador':'52998224725','nome_tomador':'TOMADOR PF',**change}

def test_template_has_the_expected_columns(admin):
    r=admin.get('/api/customers/template.xlsx');assert r.status_code==200
    wb=load_workbook(io.BytesIO(r.content))
    assert [c.value for c in wb['Tomadores'][1]]==COLUMNS and 'Instrucoes' in wb.sheetnames
    assert wb['Tomadores']['B2'].number_format=='@'  # keeps leading zeros of CPF/CNPJ

def test_preview_writes_nothing_and_import_needs_the_same_file(admin,company):
    data=xlsx([person(),person(documento_tomador='11144477735',nome_tomador='OUTRO',email='a@b.com.br')])
    r=send(admin,data);assert r.status_code==200,r.text
    body=r.json();assert body['summary']=={'total':2,'novos':2,'atualizar':0,'erros':0,'avisos':0} and not body['imported']
    with Session() as db:assert db.scalar(select(Customer)) is None
    assert send(admin,data,confirm=True,expected_sha256='0'*64).status_code==409
    r=send(admin,data,confirm=True,expected_sha256=body['sha256']);assert r.status_code==200 and r.json()['created']==2
    with Session() as db:
        names={c.document:c for c in db.scalars(select(Customer))}
        assert set(names)=={'52998224725','11144477735'} and names['11144477735'].details['email']=='a@b.com.br'
        assert db.scalar(select(Audit).where(Audit.action=='import_customers')).info['created']==2

def test_existing_customer_is_updated_without_erasing_blank_cells(admin,company):
    admin.post('/api/customers',json={'company_id':company['id'],'document':'52998224725','name':'NOME ANTIGO','details':{**ADDRESS,'email':'antigo@x.com.br','dados_fiscais':'MANTER'}})
    data=xlsx([person(nome_tomador='NOME NOVO',telefone='48 99999-0000')])
    body=send(admin,data).json();row=body['rows'][0]
    assert row['action']=='Atualizar' and 'NOME ANTIGO' in row['warnings'][0]
    assert send(admin,data,confirm=True,expected_sha256=body['sha256']).json()['updated']==1
    with Session() as db:
        c=db.scalar(select(Customer))
        assert c.name=='NOME NOVO' and c.details['email']=='antigo@x.com.br' and c.details['dados_fiscais']=='MANTER'
        assert c.details['logradouro']=='RUA A' and c.details['telefone']=='48 99999-0000'

def test_any_error_blocks_the_whole_import(admin,company):
    rows=[person(),
          person(documento_tomador='12345678900'),                      # invalid CPF
          person(cnpj_emitente='99999999000191',documento_tomador='11144477735'),  # issuer not registered
          person(documento_tomador='529.982.247-25'),                   # repeated in the file
          {**person(documento_tomador='11144477735'),'cep':'123'},      # incomplete address
          person(documento_tomador='39053344705',email='sem-arroba')]
    body=send(admin,xlsx(rows)).json()
    assert [r['action'] for r in body['rows']]==['Novo','Com erro','Com erro','Com erro','Com erro','Com erro']
    assert 'linha 2' in body['rows'][3]['errors'][0] and body['rows'][1]['line']==3
    r=send(admin,xlsx(rows),confirm=True,expected_sha256=body['sha256']);assert r.status_code==422
    with Session() as db:assert db.scalar(select(Customer)) is None

def test_cnpj_customer_without_address_is_a_warning(admin,company):
    body=send(admin,xlsx([person(documento_tomador='11444777000161',nome_tomador='EMPRESA SEM ENDERECO')])).json()
    row=body['rows'][0];assert row['action']=='Novo' and 'E0235' in row['warnings'][0] and body['summary']['avisos']==1

def test_numeric_cells_keep_leading_zeros(admin,company):
    # CPF 012.345.678-90 typed as a number in Excel loses its leading zero; the importer restores it.
    body=send(admin,xlsx([person(documento_tomador=1234567890,cep=1001000,logradouro='RUA',numero='1',bairro='B',municipio_ibge=3550308)])).json()
    row=body['rows'][0];assert row['documento_tomador']=='01234567890' and row['action']=='Novo',row

def test_bad_files_are_refused(admin,company):
    assert send(admin,xlsx([person()],heads=COLUMNS[:-1])).status_code==422
    assert send(admin,xlsx([person()],sheet='Outra')).status_code==422
    assert send(admin,xlsx([person(nome_tomador='=HYPERLINK("x")')])).status_code==422
    assert send(admin,b'nao e zip').status_code==422
    assert send(admin,b'x',name='tomadores.txt').status_code==422
    csv=(';'.join(COLUMNS)+'\n11222333000181;52998224725;TOMADOR CSV;;;;;;;;\n').encode()
    assert send(admin,csv,name='t.csv').json()['summary']['novos']==1

def test_operator_only_imports_for_authorized_companies(admin,company):
    admin.post('/api/users',json={'username':'operador-teste','password':'Senha-ficticia-456!','role':'operator','company_ids':[]})
    admin.post('/api/logout');admin.post('/api/login',json={'username':'operador-teste','password':'Senha-ficticia-456!'})
    row=send(admin,xlsx([person()])).json()['rows'][0]
    assert row['action']=='Com erro' and 'não autorizada' in row['errors'][0]
    admin.post('/api/logout');assert send(admin,xlsx([person()])).status_code==401
