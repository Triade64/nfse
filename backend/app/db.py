import os
from pathlib import Path
from sqlalchemy import create_engine,event
from sqlalchemy.engine import make_url
from sqlalchemy.orm import DeclarativeBase,sessionmaker
from sqlalchemy.pool import NullPool
from .config import CLOUD,SCHEMA

ROOT=Path(__file__).resolve().parents[2]
DATA=Path(os.getenv('NFSE_DATA_DIR',str(ROOT/'data'))) if not CLOUD else Path('/tmp/nfse')
if not CLOUD:DATA.mkdir(parents=True,exist_ok=True)
URL=os.getenv('DATABASE_URL','')
if CLOUD:
    if not URL.startswith(('postgresql://','postgres://','postgresql+psycopg://')):raise RuntimeError('DATABASE_URL PostgreSQL é obrigatória no modo cloud; SQLite não é permitido')
    URL=URL.replace('postgres://','postgresql+psycopg://',1).replace('postgresql://','postgresql+psycopg://',1)
    parsed=make_url(URL)
    if parsed.host not in ('127.0.0.1','localhost') and parsed.query.get('sslmode') not in ('require','verify-ca','verify-full'):raise RuntimeError('Conexão remota exige TLS: configure sslmode=require ou validação mais forte')
    kwargs={'poolclass':NullPool,'connect_args':{'prepare_threshold':None,'connect_timeout':10},'execution_options':{'schema_translate_map':{None:SCHEMA}},'hide_parameters':True}
else:
    URL=URL or f'sqlite:///{DATA/"nfse.db"}'
    kwargs={'connect_args':{'check_same_thread':False,'timeout':30}} if URL.startswith('sqlite') else {'pool_pre_ping':True,'hide_parameters':True}
engine=create_engine(URL,**kwargs)
if URL.startswith('sqlite'):
    @event.listens_for(engine,'connect')
    def pragmas(conn,_):
        conn.execute('PRAGMA foreign_keys=ON');conn.execute('PRAGMA journal_mode=WAL')
Session=sessionmaker(engine,expire_on_commit=False)
class Base(DeclarativeBase):pass
