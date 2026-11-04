"""Create a restricted login and write its password only to an explicit private local file.
Run locally by the DB admin; never run this in a public request, build or client.
"""
import argparse
import os
from pathlib import Path
import secrets
from urllib.parse import urlsplit,urlunsplit,quote
import psycopg
from psycopg import sql
parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
url=os.environ.get('DIRECT_DATABASE_URL');pooler=os.environ.get('POOLER_URL_WITHOUT_PASSWORD')
if not url or not pooler:raise SystemExit('Defina DIRECT_DATABASE_URL e POOLER_URL_WITHOUT_PASSWORD no ambiente local.')
if args.output.exists():raise SystemExit('O arquivo de saída já existe e não será sobrescrito.')
if args.output.resolve().is_relative_to(Path(__file__).resolve().parents[1]):raise SystemExit('Guarde o arquivo de credencial FORA do projeto e do pacote.')
parts=urlsplit(pooler)
if parts.scheme not in ('postgresql','postgres') or parts.password or not parts.username or not parts.hostname:raise SystemExit('POOLER_URL_WITHOUT_PASSWORD inválida. Copie a conexão transacional do projeto sem a senha e com o usuário nfse_web.PROJECT_REF.')
if not parts.username.startswith('nfse_web.'):raise SystemExit('O usuário do pooler deve ser nfse_web.PROJECT_REF.')
password=secrets.token_urlsafe(40)
# No password is printed or passed in shell arguments. Account permissions are scoped to nfse_app.
try:
    with psycopg.connect(url,connect_timeout=10) as db:
        exists=db.execute("SELECT 1 FROM pg_roles WHERE rolname='nfse_web'").fetchone()
        if exists:raise SystemExit('O usuário nfse_web já existe. Nenhuma senha foi alterada.')
        db.execute(sql.SQL('CREATE ROLE nfse_web LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS PASSWORD {}').format(sql.Literal(password)))
        db.execute('GRANT nfse_runtime TO nfse_web')
except SystemExit:raise
except Exception as e:raise SystemExit('Não foi possível criar o login restrito: '+type(e).__name__)
host=parts.hostname+(':'+str(parts.port) if parts.port else '')
connection=urlunsplit(('postgresql',quote(parts.username,safe='')+':'+quote(password,safe='')+'@'+host,parts.path,'sslmode=require',''))
# Secret output is intentionally created by the operator, never added to the project or Library.
fd=os.open(args.output,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w',encoding='utf-8') as f:f.write('DATABASE_URL='+connection+'\n')
print('Credencial criada no arquivo privado informado. Cadastre DATABASE_URL no ambiente da Vercel, sem compartilhar a senha no chat.')
