"""Generate initial SQL locally. Does not connect to Supabase or alter any database."""
import os
from pathlib import Path
import sys
from sqlalchemy import MetaData
from sqlalchemy.schema import CreateTable
from sqlalchemy.dialects import postgresql
ROOT=Path(__file__).resolve().parents[1]
os.environ.pop('VERCEL',None);os.environ['NFSE_MODE']='local';os.environ['DATABASE_URL']='sqlite://'
sys.path.insert(0,str(ROOT/'backend'))
from app.db import Base
from app import models
meta=MetaData()
for table in Base.metadata.sorted_tables:table.to_metadata(meta,schema='nfse_app')
parts=["-- Initial NFS-e schema only. No Conecta tables or public tables are changed.","BEGIN;","CREATE SCHEMA IF NOT EXISTS nfse_app;","REVOKE ALL ON SCHEMA nfse_app FROM PUBLIC, anon, authenticated;",'''DO $$ BEGIN
IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='nfse_runtime') THEN
  CREATE ROLE nfse_runtime NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
END IF;
END $$;''',"GRANT USAGE ON SCHEMA nfse_app TO nfse_runtime;"]
for table in meta.sorted_tables:
    parts.append(str(CreateTable(table,if_not_exists=True).compile(dialect=postgresql.dialect()))+';')
    parts.append(f'ALTER TABLE nfse_app.{table.name} ENABLE ROW LEVEL SECURITY;')
    parts.append(f'REVOKE ALL ON nfse_app.{table.name} FROM PUBLIC, anon, authenticated;')
    parts.append(f'GRANT SELECT, INSERT, UPDATE, DELETE ON nfse_app.{table.name} TO nfse_runtime;')
    parts.append(f'DROP POLICY IF EXISTS nfse_backend ON nfse_app.{table.name};')
    parts.append(f'CREATE POLICY nfse_backend ON nfse_app.{table.name} TO nfse_runtime USING (true) WITH CHECK (true);')
    for column in table.columns:
        if column.foreign_keys:parts.append(f'CREATE INDEX IF NOT EXISTS idx_{table.name}_{column.name} ON nfse_app.{table.name} ({column.name});')
parts.extend(["GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA nfse_app TO nfse_runtime;","CREATE UNIQUE INDEX IF NOT EXISTS uq_repeat_request ON nfse_app.audit (user_id, (info->>'request_id')) WHERE action='repeat_batch';","CREATE UNIQUE INDEX IF NOT EXISTS uq_dps_active_draft ON nfse_app.dps (draft_id) WHERE status IS NULL OR status <> 'Descartada';","COMMIT;"])
(ROOT/'database'/'schema.sql').write_text('\n\n'.join(parts),encoding='utf-8')
print('database/schema.sql gerado; nenhuma operação remota executada.')
