# Validação da versão web — 04/11/2026

- 26 testes de regressão backend passaram: cadastros, importação, revisão, permissões, aprovação e repetição.
- 5 testes adicionais passaram: proteção do administrador inicial, cookie seguro, fila em passos de 10 documentos, bloqueio de configuração insegura de banco e esquema privado.
- 10 testes de componentes frontend passaram; TypeScript/Vite compilou e a cópia para `public/` foi concluída.
- Teste PostgreSQL em PGlite com protocolo PostgreSQL/psycopg passou: aplicação do SQL, bloqueio de leitura anônima, grupo de servidor, criação do administrador, cadastro, preparação, aprovação, simulação e repetição para nova competência.

O teste PGlite usou dados fictícios e um banco descartável local. Não equivale a homologação no Supabase e não testou TLS remoto, carga concorrente, pooler Supavisor ou execução na Vercel. A migração de um banco real não foi executada. Nenhuma nota fiscal real foi emitida. A autenticação é própria da aplicação; Supabase Auth não está integrado. O limitador de login em memória não é compartilhado entre instâncias.

Após provisionar os serviços, é obrigatório verificar o fluxo HTTPS completo no deployment e a persistência dos dados no PostgreSQL antes de migrar cadastros reais.

## Verificação no serviço publicado

Em 04/11/2026, o deployment da Vercel conectado ao pooler transacional Supabase respondeu: página inicial HTTP 200; JavaScript e CSS HTTP 200; `/api/health` HTTP 200, versão 0.5.0/cloud; `/api/setup` HTTP 200 com consulta ao PostgreSQL; `/api/me` HTTP 401 sem sessão. As 12 tabelas têm RLS e os papéis anon/authenticated não têm USAGE no schema privado. A verificação de segurança Supabase não retornou advertências.

A declaração de dependências Python foi corrigida em pyproject.toml; a interface passou a ser servida de frontend/dist pelo FastAPI após confirmar ausência dos arquivos no CDN deste deployment. Os 31 testes backend foram executados novamente e passaram. Nenhum usuário administrador ou cadastro real foi criado; o fluxo autenticado completo no serviço publicado depende do primeiro acesso pelo responsável. A proteção de acesso da Vercel permanece habilitada.
