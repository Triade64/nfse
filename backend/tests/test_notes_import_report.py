"""0.13.0: spreadsheet import straight into the Notas screen (one note per row) and the notes report."""
import io
from openpyxl import Workbook, load_workbook
from app.validation import HEADERS

def xlsx(rows):
    wb=Workbook();ws=wb.active;ws.title='Notas';ws.append(HEADERS)
    for r in rows:ws.append([r.get(h,'') for h in HEADERS])
    b=io.BytesIO();wb.save(b);return b.getvalue()

def test_import_creates_one_independent_note_per_row(admin,company,row):
    data=xlsx([row,{**row,'documento_tomador':'11144477735','nome_tomador':'OUTRO'},{**row,'valor_servico':'abc','descricao_servico':'COM ERRO'}])
    r=admin.post('/api/import',params={'per_note':'true'},files={'file':('notas.xlsx',data,'application/octet-stream')})
    assert r.status_code==200,r.text;assert r.json()=={'created':3,'with_errors':1}
    notes=admin.get('/api/notes').json()
    assert len(notes)==3 and len({n['batch_id'] for n in notes})==3
    assert sorted(n['situation'] for n in notes)==['Com inconsistência','Pronta','Pronta']

def test_import_refuses_bad_file_without_creating_notes(admin,company,row):
    wb=Workbook();ws=wb.active;ws.title='Notas';ws.append(['coluna_errada']);ws.append(['x']);b=io.BytesIO();wb.save(b)
    r=admin.post('/api/import',params={'per_note':'true'},files={'file':('notas.xlsx',b.getvalue(),'application/octet-stream')})
    assert r.status_code==422 and admin.get('/api/notes').json()==[]

def test_notes_report_lists_every_note(admin,company,row):
    admin.post('/api/batches',json={'name':'a','rows':[row]})
    admin.post('/api/batches',json={'name':'b','rows':[{**row,'documento_tomador':'11144477735','valor_servico':'abc'}]})
    r=admin.get('/api/notes/report.xlsx');assert r.status_code==200
    ws=load_workbook(io.BytesIO(r.content))['Notas'];rows=list(ws.values)
    assert rows[0][:7]==('Emitente','Tomador','CPF/CNPJ tomador','Competência','Valor (R$)','Serviço','Situação')
    assert len(rows)==3 and {x[6] for x in rows[1:]}=={'Pronta','Com inconsistência'}
    assert any(x[4]==1234.56 for x in rows[1:]) and any(x[4] is None and x[11] for x in rows[1:])
