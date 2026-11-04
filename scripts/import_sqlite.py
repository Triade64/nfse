"""One-time, all-or-nothing import from a local read-only MVP database.
Runs on the operator's PC; never uploads a SQLite file to the web app or ChatGPT.
"""
import argparse
import json
from pathlib import Path
import sqlite3
import sys

parser=argparse.ArgumentParser();parser.add_argument('--source',type=Path,required=True);parser.add_argument('--dry-run',action='store_true');args=parser.parse_args()
path=args.source.resolve()
if not path.is_file():raise SystemExit('Banco de origem não encontrado.')
source=sqlite3.connect(path.as_uri()+'?mode=ro',uri=True);source.row_factory=sqlite3.Row
source.execute('BEGIN')
allowed=['users','companies','user_companies','customers','services','batches','drafts','jobs','audit','dps','nfse']
existing={r[0] for r in source.execute("SELECT name FROM sqlite_master WHERE type='table'")}
if 'companies' not in existing or 'drafts' not in existing:raise SystemExit('A origem não parece ser um banco do sistema NFS-e.')
counts={name:source.execute(f'SELECT count(*) FROM "{name}"').fetchone()[0] for name in allowed if name in existing}
print(json.dumps({'tables':counts,'sessions':'não serão migradas'},ensure_ascii=False))
if args.dry_run:source.close();raise SystemExit(0)
if counts.get('dps',0) or counts.get('nfse',0):raise SystemExit('Há documentos fiscais na origem. A migração de XML/DANFSe requer uma etapa específica, antes de importar.')
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'backend'))
from app.db import engine,Base
from app.config import CLOUD,SCHEMA
from app import models
from sqlalchemy import select,func,insert,text,JSON,Boolean
if not CLOUD or not SCHEMA:raise SystemExit('Configure NFSE_MODE=cloud e DATABASE_URL no ambiente seguro antes de importar.')
try:
    with engine.begin() as target:
        target.execute(text('SELECT pg_advisory_xact_lock(194612311)'))
        for table in Base.metadata.sorted_tables:
            if target.scalar(select(func.count()).select_from(table)):
                raise ValueError('Destino já possui dados. A importação foi recusada para evitar mistura ou sobrescrita.')
        for table in Base.metadata.sorted_tables:
            if table.name not in counts or table.name in ('sessions','dps','nfse'):continue
            rows=[]
            for original in source.execute(f'SELECT * FROM "{table.name}"'):
                row={k:original[k] for k in original.keys() if k in table.c}
                for col in table.c:
                    if col.name in row and row[col.name] is not None:
                        if isinstance(col.type,JSON) and isinstance(row[col.name],str):row[col.name]=json.loads(row[col.name])
                        if isinstance(col.type,Boolean):row[col.name]=bool(row[col.name])
                if table.name=='jobs' and row.get('status')=='Em processamento':row['status']='Na fila'
                if table.name=='batches' and row.get('status')=='Em processamento':row['status']='Na fila'
                rows.append(row)
            for start in range(0,len(rows),200):target.execute(insert(table),rows[start:start+200])
            if 'id' in table.c:
                maximum=target.scalar(select(func.max(table.c.id))) or 0
                target.execute(text("SELECT setval(pg_get_serial_sequence(:name,'id'), :value, :called)"),{'name':f'{SCHEMA}.{table.name}','value':maximum or 1,'called':bool(maximum)})
        for table in Base.metadata.sorted_tables:
            if table.name in counts and table.name not in ('sessions','dps','nfse'):
                if target.scalar(select(func.count()).select_from(table))!=counts[table.name]:raise ValueError('Contagem divergente; importação revertida.')
except Exception as error:
    if isinstance(error,ValueError):raise SystemExit(str(error))
    raise SystemExit('Falha na importação ('+type(error).__name__+'). A transação foi revertida. Credenciais e registros não serão exibidos.')
finally:source.close()
print('Importação concluída e contagens conferidas. Faça login com o usuário/senha anteriores; sessões antigas não foram copiadas.')
