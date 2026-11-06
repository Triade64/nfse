-- Migração 0.11.0: reforço de segurança do login e da sessão.
-- Aditiva: tentativas de login guardadas no banco (limite que vale em todas as instâncias da Vercel)
-- e última atividade da sessão (encerramento por inatividade). Não altera nem apaga dados.
-- Revisar e executar no SQL Editor do projeto NFS-e, depois da 0005.
BEGIN;

ALTER TABLE nfse_app.sessions
	ADD COLUMN IF NOT EXISTS last_seen VARCHAR(40);

CREATE TABLE IF NOT EXISTS nfse_app.login_attempts (
	id SERIAL NOT NULL,
	at VARCHAR(40) NOT NULL,
	username VARCHAR(80) NOT NULL,
	ip_hash VARCHAR(64) NOT NULL,
	success BOOLEAN NOT NULL,
	PRIMARY KEY (id)
);
ALTER TABLE nfse_app.login_attempts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON nfse_app.login_attempts FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON nfse_app.login_attempts TO nfse_runtime;
DROP POLICY IF EXISTS nfse_backend ON nfse_app.login_attempts;
CREATE POLICY nfse_backend ON nfse_app.login_attempts TO nfse_runtime USING (true) WITH CHECK (true);
CREATE INDEX IF NOT EXISTS idx_login_attempts_user_at ON nfse_app.login_attempts (username, at);
CREATE INDEX IF NOT EXISTS idx_login_attempts_ip_at ON nfse_app.login_attempts (ip_hash, at);

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA nfse_app TO nfse_runtime;
COMMIT;
