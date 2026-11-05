-- Migração 0.9.0: conector local ligado ao site (link triade-nfse://).
-- Aditiva: resultado da emissão na DPS e tickets de uso único para o conector.
-- Revisar e executar no SQL Editor do projeto NFS-e, depois da 0001 e da 0002.
BEGIN;

ALTER TABLE nfse_app.dps
	ADD COLUMN IF NOT EXISTS access_key VARCHAR(60),
	ADD COLUMN IF NOT EXISTS nfse_xml TEXT,
	ADD COLUMN IF NOT EXISTS result JSON,
	ADD COLUMN IF NOT EXISTS result_at VARCHAR(40);

CREATE TABLE IF NOT EXISTS nfse_app.connector_tickets (
	id SERIAL NOT NULL,
	token_hash VARCHAR(64) NOT NULL,
	user_id INTEGER NOT NULL,
	dps_ids JSON NOT NULL,
	created_at VARCHAR(40) NOT NULL,
	expires_at VARCHAR(40) NOT NULL,
	revoked BOOLEAN NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (token_hash),
	FOREIGN KEY(user_id) REFERENCES nfse_app.users (id)
);
ALTER TABLE nfse_app.connector_tickets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON nfse_app.connector_tickets FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON nfse_app.connector_tickets TO nfse_runtime;
DROP POLICY IF EXISTS nfse_backend ON nfse_app.connector_tickets;
CREATE POLICY nfse_backend ON nfse_app.connector_tickets TO nfse_runtime USING (true) WITH CHECK (true);
CREATE INDEX IF NOT EXISTS idx_connector_tickets_user_id ON nfse_app.connector_tickets (user_id);

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA nfse_app TO nfse_runtime;
COMMIT;
