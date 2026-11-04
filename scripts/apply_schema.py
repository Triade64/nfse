"""Explicit deployment action, run by the database administrator. No credentials in arguments."""
import os
from pathlib import Path
import psycopg
url=os.environ.get('DIRECT_DATABASE_URL')
if not url:raise SystemExit('Defina DIRECT_DATABASE_URL no ambiente seguro do responsável, sem enviar a senha por chat.')
try:
    with psycopg.connect(url,autocommit=True,connect_timeout=10) as db:db.execute((Path(__file__).resolve().parents[1]/'database'/'schema.sql').read_text())
except Exception as e:raise SystemExit('Falha ao aplicar o esquema: '+type(e).__name__+'. Confira conexão e permissões; credenciais não serão exibidas.')
print('Esquema nfse_app preparado. Configure a credencial de runtime restrita antes de publicar.')
