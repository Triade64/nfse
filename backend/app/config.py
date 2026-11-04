import os
import re
from urllib.parse import urlsplit

CLOUD=os.getenv('NFSE_MODE','local')=='cloud' or os.getenv('VERCEL')=='1'
SCHEMA=os.getenv('NFSE_DB_SCHEMA','nfse_app') if CLOUD else None
if SCHEMA and not re.fullmatch(r'[a-z][a-z0-9_]{1,40}',SCHEMA):raise RuntimeError('NFSE_DB_SCHEMA inválido')

def allowed_hosts():
    hosts={'localhost','127.0.0.1','testserver'}
    hosts.update(h.strip() for h in os.getenv('APP_HOSTS','').split(',') if h.strip())
    if os.getenv('VERCEL_URL'):hosts.add(os.environ['VERCEL_URL'])
    return sorted(hosts)

def allowed_origins():
    origins={'http://localhost:8000','http://127.0.0.1:8000','http://localhost:5173','http://127.0.0.1:5173'} if not CLOUD else set()
    for value in os.getenv('APP_ORIGINS','').split(','):
        value=value.strip().rstrip('/')
        if not value:continue
        p=urlsplit(value)
        if p.scheme!='https' or not p.hostname or p.path or p.query or p.fragment or p.username:raise RuntimeError('APP_ORIGINS deve conter origens HTTPS sem caminho')
        origins.add(value)
    if os.getenv('VERCEL_URL'):origins.add('https://'+os.environ['VERCEL_URL'])
    return origins
