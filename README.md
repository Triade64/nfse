# Tríade NFS-e — versão web 0.7.2

Preparação e repetição de notas para os mesmos tomadores, com nova competência e conferência humana. React/TypeScript e FastAPI na Vercel; PostgreSQL no Supabase. Nenhuma nota fiscal real é emitida: o processamento disponível é uma simulação.

## Funcionalidades

- Empresas com configurações fiscais individuais e permissões por usuário/empresa.
- Tomadores e serviços reutilizáveis; preparação diretamente na interface.
- Repetição de lotes anteriores: selecionar notas, informar competência e revisar tributos antes de aprovar.
- Importação Excel/CSV opcional, validação por linha e relatório de inconsistências.
- Conferência, aprovação explícita, fila persistida, simulação e auditoria.
- Autenticação própria do aplicativo (senha com Argon2 e sessão HttpOnly), não Supabase Auth.

## Publicação

Siga [docs/PUBLICACAO.md](docs/PUBLICACAO.md). A raiz do repositório é a raiz do projeto Vercel. Não use `frontend` como Root Directory: a API Python também faz parte da aplicação.

As credenciais ficam exclusivamente nas variáveis de ambiente do servidor. Não envie arquivos de banco, senhas, certificados ou `.env` ao GitHub.

## Desenvolvimento local

Requer Python 3.12 e Node.js 22. No PowerShell, na pasta do projeto:

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\python -m pip install -r requirements-dev.txt
npm ci --prefix frontend
$env:PYTHONPATH="backend"
.\.venv\Scripts\python -m uvicorn app.main:app --host 127.0.0.1 --port 8000
```

Em outro terminal: `npm run dev --prefix frontend`. Abra o endereço mostrado pelo Vite. O modo local usa SQLite em `data/`; isso não configura o Supabase. A API não deve ser exposta na rede nesse modo.

## Verificação

```powershell
$env:PYTHONPATH="backend"
.\.venv\Scripts\python -m pytest backend/tests -q
npm test --prefix frontend
npm run build --prefix frontend
.\.venv\Scripts\python scripts/prepare_static.py
```

Veja [docs/VALIDACAO.md](docs/VALIDACAO.md) para resultados e limites. Numeração central de DPS: [docs/NUMERACAO_0_6.md](docs/NUMERACAO_0_6.md). A implantação efetiva na Vercel e a conexão com o projeto Supabase ainda precisam ser verificadas.

## Organização

`backend/app`: API, permissões, validações, recorrência e fila. `frontend/src`: interface. `database/schema.sql`: esquema privado PostgreSQL. `scripts`: publicação de arquivos estáticos e migração assistida. `schemas`: referências oficiais de XML; a presença desses arquivos não significa integração fiscal concluída.

A emissão real, assinatura digital, guarda de certificados e recuperação de XML/DANFSe dependem de uma fase de integração e homologação própria, com autorização antes de produção.
