-- Migração 0.6.0: numeração central de DPS (produção restrita).
-- Aditiva: cria nfse_app.dps_series e acrescenta colunas anuláveis a nfse_app.dps.
-- Não apaga nem altera dados existentes. Revisar e executar no SQL Editor do projeto NFS-e.
BEGIN;

CREATE TABLE IF NOT EXISTS nfse_app.dps_series (
	id SERIAL NOT NULL,
	company_id INTEGER NOT NULL,
	environment VARCHAR(1) NOT NULL,
	series VARCHAR(5) NOT NULL,
	next_number BIGINT NOT NULL,
	revision INTEGER NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (company_id, environment, series),
	FOREIGN KEY(company_id) REFERENCES nfse_app.companies (id),
	CHECK (next_number >= 1 AND next_number <= 999999999999999)
);
ALTER TABLE nfse_app.dps_series ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON nfse_app.dps_series FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON nfse_app.dps_series TO nfse_runtime;
DROP POLICY IF EXISTS nfse_backend ON nfse_app.dps_series;
CREATE POLICY nfse_backend ON nfse_app.dps_series TO nfse_runtime USING (true) WITH CHECK (true);
CREATE INDEX IF NOT EXISTS idx_dps_series_company_id ON nfse_app.dps_series (company_id);

ALTER TABLE nfse_app.dps
	ADD COLUMN IF NOT EXISTS company_id INTEGER REFERENCES nfse_app.companies (id),
	ADD COLUMN IF NOT EXISTS series VARCHAR(5),
	ADD COLUMN IF NOT EXISTS number BIGINT,
	ADD COLUMN IF NOT EXISTS status VARCHAR(40),
	ADD COLUMN IF NOT EXISTS issued_at VARCHAR(40),
	ADD COLUMN IF NOT EXISTS xml TEXT,
	ADD COLUMN IF NOT EXISTS created_at VARCHAR(40),
	ADD COLUMN IF NOT EXISTS created_by INTEGER REFERENCES nfse_app.users (id);
-- Garantia final no banco: um número nunca é usado duas vezes na mesma série/empresa/ambiente.
CREATE UNIQUE INDEX IF NOT EXISTS uq_dps_number ON nfse_app.dps (company_id, environment, series, number);
CREATE INDEX IF NOT EXISTS idx_dps_company_id ON nfse_app.dps (company_id);
CREATE INDEX IF NOT EXISTS idx_dps_created_by ON nfse_app.dps (created_by);

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA nfse_app TO nfse_runtime;
COMMIT;
