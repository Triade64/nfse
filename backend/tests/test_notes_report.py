"""0.13.0: notes report (one spreadsheet with every note)."""
import io
from openpyxl import load_workbook

def test_notes_report_lists_every_note(admin,company,row):
    admin.post('/api/batches',json={'name':'a','rows':[row]})
    admin.post('/api/batches',json={'name':'b','rows':[{**row,'documento_tomador':'11144477735','valor_servico':'abc'}]})
    r=admin.get('/api/notes/report.xlsx');assert r.status_code==200
    ws=load_workbook(io.BytesIO(r.content))['Notas'];rows=list(ws.values)
    assert rows[0][:7]==('Emitente','Tomador','CPF/CNPJ tomador','Competência','Valor (R$)','Serviço','Situação')
    assert len(rows)==3 and {x[6] for x in rows[1:]}=={'Pronta','Com inconsistência'}
    assert any(x[4]==1234.56 for x in rows[1:]) and any(x[4] is None and x[11] for x in rows[1:])
