# Validação da versão web — 04/11/2026

- 26 testes de regressão backend passaram: cadastros, importação, revisão, permissões, aprovação e repetição.
- 5 testes adicionais passaram: proteção do administrador inicial, cookie seguro, fila em passos de 10 documentos, bloqueio de configuração insegura de banco e esquema privado.
- 10 testes de componentes frontend passaram; TypeScript/Vite compilou e a cópia para `public/` foi concluída.
- Teste PostgreSQL em PGlite com protocolo PostgreSQL/psycopg passou: aplicação do SQL, bloqueio de leitura anônima, grupo de servidor, criação do administrador, cadastro, preparação, aprovação, simulação e repetição para nova competência.

O teste PGlite usou dados fictícios e um banco descartável local. Não equivale a homologação no Supabase e não testou TLS remoto, carga concorrente, pooler Supavisor ou execução na Vercel. A migração de um banco real não foi executada. Nenhuma nota fiscal real foi emitida. A autenticação é própria da aplicação; Supabase Auth não está integrado. O limitador de login em memória não é compartilhado entre instâncias.

Após provisionar os serviços, é obrigatório verificar o fluxo HTTPS completo no deployment e a persistência dos dados no PostgreSQL antes de migrar cadastros reais.
