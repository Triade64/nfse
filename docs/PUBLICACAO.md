# Configuração Supabase + Vercel

## 1. Banco dedicado

Prefira criar um projeto Supabase separado para NFS-e, na organização Tríade, região São Paulo. Verifique plano/custo antes da criação. Não aplique este SQL no projeto Conecta sem uma decisão explícita de compartilhar esse projeto.

No SQL Editor do projeto correto, revise e execute `database/schema.sql`. Ele cria o schema privado `nfse_app`, tabelas, índices, políticas e o grupo `nfse_runtime`. Não adiciona o schema aos schemas expostos pela Data API.

Todas as tabelas têm RLS e acesso revogado de `anon` e `authenticated`. A política do grupo de servidor permite acesso às linhas: a separação entre usuários e empresas é aplicada pela API FastAPI. Não se trata de RLS por usuário do Supabase Auth. O backend é um componente confiável e sua credencial nunca vai ao navegador.

Crie um login PostgreSQL restrito usando `scripts/provision_runtime.py`, executado localmente pelo administrador. Ele recebe `DIRECT_DATABASE_URL` e `POOLER_URL_WITHOUT_PASSWORD` do ambiente, sem imprimi-los, e grava a conexão final num arquivo privado fora do repositório. O pooler deve ser a conexão transacional copiada do painel Connect, com usuário `nfse_web.REFERENCIA_DO_PROJETO`, sem senha. Não invente host de conexão. Não use a senha administrativa do PostgreSQL como credencial permanente da aplicação.

```powershell
# Configure as variáveis em um ambiente privado; não cole credenciais no chat.
.\.venv\Scripts\python scripts/provision_runtime.py --output C:\PastaPrivada\nfse-credencial.env
```

Guarde o arquivo com acesso restrito. Configure backups do PostgreSQL conforme o plano contratado e teste a restauração. A aplicação web não fornece download de backup SQLite.

## 2. Projeto Vercel

Importe `Triade64/nfse`, usando a raiz do repositório. A configuração `vercel.json` compila o frontend; nesta versão a API também serve a interface de `frontend/dist/`. A cópia para `public/` é gerada, mas a validação do deployment confirmou a entrega pelo FastAPI. A API é `index.py` / FastAPI, Python 3.12. Confira no plano Vercel se o uso pelo escritório é permitido antes de publicar: não presuma elegibilidade comercial no plano Hobby.

Cadastre as variáveis como variáveis do servidor, nunca com prefixo `VITE_`:

| Variável | Valor |
|---|---|
| `NFSE_MODE` | `cloud` |
| `NFSE_DB_SCHEMA` | `nfse_app` |
| `DATABASE_URL` | Conexão transacional do Supabase, login restrito, `sslmode=require` |
| `APP_HOSTS` | Host estável da aplicação, sem protocolo, separado por vírgulas se houver mais de um |
| `APP_ORIGINS` | Origem HTTPS estável, sem barra final; múltiplas separadas por vírgulas |
| `BOOTSTRAP_TOKEN` | Segredo aleatório de pelo menos 32 caracteres para criação inicial do administrador |

`VERCEL_URL` também é aceito automaticamente como host/origem do deployment. O pooler usa SQLAlchemy NullPool e `prepare_threshold=None`. Não configure um worker permanente: a fila de simulação é processada em passos limitados pela API, enquanto a interface acompanha o lote. Se fechar a tela, o trabalho pendente continua armazenado e pode ser retomado ao abri-la.

Não conecte previews de código não revisado ao banco com dados reais. Use um banco de teste separado ou não disponibilize `DATABASE_URL` nos previews.

## 3. Primeiro acesso e validação

Abra o deployment HTTPS, use o código inicial para criar o administrador e confira `/health`. Se migrar o banco local primeiro, use a conta antiga: a migração preserva hashes de senha e descarta sessões.

Com dados fictícios, valide: cadastro de empresa e tomador; preparação; repetição para outra competência; aprovação explícita; simulação; acesso negado a outra empresa. Verifique logs sem dados pessoais/segredos. O limitador de tentativas de login atual é por instância; antes de liberar acesso amplo, configure limitação de requisições na borda ou um limitador distribuído e valide o comportamento.

## 4. Migração do banco local

Faça backup e feche o aplicativo local. No PC do escritório, sem enviar o arquivo para este chat ou para o GitHub:

```powershell
.\.venv\Scripts\python scripts/import_sqlite.py --source C:\PastaPrivada\nfse.db --dry-run
# Depois de revisar contagens e configurar NFSE_MODE=cloud / DATABASE_URL no ambiente:
.\.venv\Scripts\python scripts/import_sqlite.py --source C:\PastaPrivada\nfse.db
```

O destino deve estar vazio, inclusive sem administrador cadastrado. A migração é transacional e recusa mesclar dados ou migrar uma origem com DPS/NFS-e fiscais. Não apaga nem grava na origem SQLite. Sessões antigas não são copiadas. Teste primeiro com uma cópia fictícia e confira as contagens no destino.

## 5. Atualizações e domínio

Após configurar a integração Git, alterações na branch de produção geram novos deployments. Os cadastros ficam no Supabase, fora do pacote da aplicação. Mudanças de estrutura exigem migrações de banco revisadas antes da nova versão; não basta repetir um `CREATE TABLE IF NOT EXISTS`.

Depois da validação, associe preferencialmente `nfse.triade.cnt.br` ao projeto Vercel e configure na Hostinger somente os registros DNS indicados pela Vercel. Atualize `APP_HOSTS` e `APP_ORIGINS`. O site principal pode continuar na Hostinger. Nenhuma alteração de DNS é necessária nesta etapa.
