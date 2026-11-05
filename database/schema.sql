-- Initial NFS-e schema only. No Conecta tables or public tables are changed.

BEGIN;

CREATE SCHEMA IF NOT EXISTS nfse_app;

REVOKE ALL ON SCHEMA nfse_app FROM PUBLIC, anon, authenticated;

DO $$ BEGIN
IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='nfse_runtime') THEN
  CREATE ROLE nfse_runtime NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
END IF;
END $$;

GRANT USAGE ON SCHEMA nfse_app TO nfse_runtime;


CREATE TABLE IF NOT EXISTS nfse_app.companies (
	id SERIAL NOT NULL, 
	cnpj VARCHAR(14) NOT NULL, 
	name VARCHAR(200) NOT NULL, 
	config JSON NOT NULL, 
	revision INTEGER NOT NULL, 
	PRIMARY KEY (id), 
	UNIQUE (cnpj)
)

;

ALTER TABLE nfse_app.companies ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON nfse_app.companies FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON nfse_app.companies TO nfse_runtime;

DROP POLICY IF EXISTS nfse_backend ON nfse_app.companies;

CREATE POLICY nfse_backend ON nfse_app.companies TO nfse_runtime USING (true) WITH CHECK (true);


CREATE TABLE IF NOT EXISTS nfse_app.users (
	id SERIAL NOT NULL, 
	username VARCHAR(80) NOT NULL, 
	password_hash TEXT NOT NULL, 
	role VARCHAR(20) NOT NULL, 
	active BOOLEAN NOT NULL, 
	PRIMARY KEY (id), 
	UNIQUE (username)
)

;

ALTER TABLE nfse_app.users ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON nfse_app.users FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON nfse_app.users TO nfse_runtime;

DROP POLICY IF EXISTS nfse_backend ON nfse_app.users;

CREATE POLICY nfse_backend ON nfse_app.users TO nfse_runtime USING (true) WITH CHECK (true);


CREATE TABLE IF NOT EXISTS nfse_app.audit (
	id SERIAL NOT NULL, 
	at VARCHAR NOT NULL, 
	user_id INTEGER, 
	action VARCHAR(80) NOT NULL, 
	entity VARCHAR(40) NOT NULL, 
	entity_id INTEGER NOT NULL, 
	info JSON NOT NULL, 
	PRIMARY KEY (id), 
	FOREIGN KEY(user_id) REFERENCES nfse_app.users (id)
)

;

ALTER TABLE nfse_app.audit ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON nfse_app.audit FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON nfse_app.audit TO nfse_runtime;

DROP POLICY IF EXISTS nfse_backend ON nfse_app.audit;

CREATE POLICY nfse_backend ON nfse_app.audit TO nfse_runtime USING (true) WITH CHECK (true);

CREATE INDEX IF NOT EXISTS idx_audit_user_id ON nfse_app.audit (user_id);


CREATE TABLE IF NOT EXISTS nfse_app.batches (
	id SERIAL NOT NULL, 
	name VARCHAR(200) NOT NULL, 
	owner_id INTEGER NOT NULL, 
	created_at VARCHAR NOT NULL, 
	revision INTEGER NOT NULL, 
	status VARCHAR(40) NOT NULL, 
	approval_digest VARCHAR(64), 
	approved_by INTEGER, 
	PRIMARY KEY (id), 
	FOREIGN KEY(approved_by) REFERENCES nfse_app.users (id), 
	FOREIGN KEY(owner_id) REFERENCES nfse_app.users (id)
)

;

ALTER TABLE nfse_app.batches ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON nfse_app.batches FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON nfse_app.batches TO nfse_runtime;

DROP POLICY IF EXISTS nfse_backend ON nfse_app.batches;

CREATE POLICY nfse_backend ON nfse_app.batches TO nfse_runtime USING (true) WITH CHECK (true);

CREATE INDEX IF NOT EXISTS idx_batches_owner_id ON nfse_app.batches (owner_id);

CREATE INDEX IF NOT EXISTS idx_batches_approved_by ON nfse_app.batches (approved_by);


CREATE TABLE IF NOT EXISTS nfse_app.customers (
	id SERIAL NOT NULL, 
	company_id INTEGER NOT NULL, 
	document VARCHAR(14) NOT NULL, 
	name VARCHAR(200) NOT NULL, 
	details JSON NOT NULL, 
	PRIMARY KEY (id), 
	FOREIGN KEY(company_id) REFERENCES nfse_app.companies (id), 
	UNIQUE (company_id, document)
)

;

ALTER TABLE nfse_app.customers ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON nfse_app.customers FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON nfse_app.customers TO nfse_runtime;

DROP POLICY IF EXISTS nfse_backend ON nfse_app.customers;

CREATE POLICY nfse_backend ON nfse_app.customers TO nfse_runtime USING (true) WITH CHECK (true);

CREATE INDEX IF NOT EXISTS idx_customers_company_id ON nfse_app.customers (company_id);


CREATE TABLE IF NOT EXISTS nfse_app.dps_series (
	id SERIAL NOT NULL, 
	company_id INTEGER NOT NULL, 
	environment VARCHAR(1) NOT NULL, 
	series VARCHAR(5) NOT NULL, 
	next_number BIGINT NOT NULL, 
	revision INTEGER NOT NULL, 
	PRIMARY KEY (id), 
	FOREIGN KEY(company_id) REFERENCES nfse_app.companies (id), 
	UNIQUE (company_id, environment, series)
)

;

ALTER TABLE nfse_app.dps_series ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON nfse_app.dps_series FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON nfse_app.dps_series TO nfse_runtime;

DROP POLICY IF EXISTS nfse_backend ON nfse_app.dps_series;

CREATE POLICY nfse_backend ON nfse_app.dps_series TO nfse_runtime USING (true) WITH CHECK (true);

CREATE INDEX IF NOT EXISTS idx_dps_series_company_id ON nfse_app.dps_series (company_id);


CREATE TABLE IF NOT EXISTS nfse_app.services (
	id SERIAL NOT NULL, 
	company_id INTEGER NOT NULL, 
	name VARCHAR(200) NOT NULL, 
	config JSON NOT NULL, 
	revision INTEGER NOT NULL, 
	PRIMARY KEY (id), 
	FOREIGN KEY(company_id) REFERENCES nfse_app.companies (id)
)

;

ALTER TABLE nfse_app.services ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON nfse_app.services FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON nfse_app.services TO nfse_runtime;

DROP POLICY IF EXISTS nfse_backend ON nfse_app.services;

CREATE POLICY nfse_backend ON nfse_app.services TO nfse_runtime USING (true) WITH CHECK (true);

CREATE INDEX IF NOT EXISTS idx_services_company_id ON nfse_app.services (company_id);


CREATE TABLE IF NOT EXISTS nfse_app.sessions (
	token_hash VARCHAR(64) NOT NULL, 
	user_id INTEGER NOT NULL, 
	expires VARCHAR(40) NOT NULL, 
	PRIMARY KEY (token_hash), 
	FOREIGN KEY(user_id) REFERENCES nfse_app.users (id)
)

;

ALTER TABLE nfse_app.sessions ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON nfse_app.sessions FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON nfse_app.sessions TO nfse_runtime;

DROP POLICY IF EXISTS nfse_backend ON nfse_app.sessions;

CREATE POLICY nfse_backend ON nfse_app.sessions TO nfse_runtime USING (true) WITH CHECK (true);

CREATE INDEX IF NOT EXISTS idx_sessions_user_id ON nfse_app.sessions (user_id);


CREATE TABLE IF NOT EXISTS nfse_app.user_companies (
	user_id INTEGER NOT NULL, 
	company_id INTEGER NOT NULL, 
	PRIMARY KEY (user_id, company_id), 
	FOREIGN KEY(user_id) REFERENCES nfse_app.users (id), 
	FOREIGN KEY(company_id) REFERENCES nfse_app.companies (id)
)

;

ALTER TABLE nfse_app.user_companies ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON nfse_app.user_companies FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON nfse_app.user_companies TO nfse_runtime;

DROP POLICY IF EXISTS nfse_backend ON nfse_app.user_companies;

CREATE POLICY nfse_backend ON nfse_app.user_companies TO nfse_runtime USING (true) WITH CHECK (true);

CREATE INDEX IF NOT EXISTS idx_user_companies_user_id ON nfse_app.user_companies (user_id);

CREATE INDEX IF NOT EXISTS idx_user_companies_company_id ON nfse_app.user_companies (company_id);


CREATE TABLE IF NOT EXISTS nfse_app.drafts (
	id SERIAL NOT NULL, 
	batch_id INTEGER NOT NULL, 
	company_id INTEGER, 
	line INTEGER NOT NULL, 
	raw JSON NOT NULL, 
	errors JSON NOT NULL, 
	amount_cents INTEGER NOT NULL, 
	fingerprint VARCHAR(64), 
	status VARCHAR(60) NOT NULL, 
	company_revision INTEGER, 
	snapshot JSON NOT NULL, 
	PRIMARY KEY (id), 
	UNIQUE (fingerprint), 
	FOREIGN KEY(company_id) REFERENCES nfse_app.companies (id), 
	FOREIGN KEY(batch_id) REFERENCES nfse_app.batches (id)
)

;

ALTER TABLE nfse_app.drafts ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON nfse_app.drafts FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON nfse_app.drafts TO nfse_runtime;

DROP POLICY IF EXISTS nfse_backend ON nfse_app.drafts;

CREATE POLICY nfse_backend ON nfse_app.drafts TO nfse_runtime USING (true) WITH CHECK (true);

CREATE INDEX IF NOT EXISTS idx_drafts_batch_id ON nfse_app.drafts (batch_id);

CREATE INDEX IF NOT EXISTS idx_drafts_company_id ON nfse_app.drafts (company_id);


CREATE TABLE IF NOT EXISTS nfse_app.dps (
	id SERIAL NOT NULL, 
	draft_id INTEGER NOT NULL, 
	environment VARCHAR(20) NOT NULL, 
	identifier VARCHAR(80) NOT NULL, 
	xml_path VARCHAR, 
	xml_sha256 VARCHAR(64), 
	company_id INTEGER, 
	series VARCHAR(5), 
	number BIGINT, 
	status VARCHAR(40), 
	issued_at VARCHAR(40), 
	xml TEXT, 
	created_at VARCHAR(40), 
	created_by INTEGER, 
	PRIMARY KEY (id), 
	UNIQUE (draft_id), 
	UNIQUE (identifier), 
	FOREIGN KEY(draft_id) REFERENCES nfse_app.drafts (id), 
	CONSTRAINT uq_dps_number UNIQUE (company_id, environment, series, number), 
	FOREIGN KEY(created_by) REFERENCES nfse_app.users (id), 
	FOREIGN KEY(company_id) REFERENCES nfse_app.companies (id)
)

;

ALTER TABLE nfse_app.dps ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON nfse_app.dps FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON nfse_app.dps TO nfse_runtime;

DROP POLICY IF EXISTS nfse_backend ON nfse_app.dps;

CREATE POLICY nfse_backend ON nfse_app.dps TO nfse_runtime USING (true) WITH CHECK (true);

CREATE INDEX IF NOT EXISTS idx_dps_draft_id ON nfse_app.dps (draft_id);

CREATE INDEX IF NOT EXISTS idx_dps_company_id ON nfse_app.dps (company_id);

CREATE INDEX IF NOT EXISTS idx_dps_created_by ON nfse_app.dps (created_by);


CREATE TABLE IF NOT EXISTS nfse_app.jobs (
	id SERIAL NOT NULL, 
	draft_id INTEGER NOT NULL, 
	status VARCHAR(40) NOT NULL, 
	mode VARCHAR(20) NOT NULL, 
	result JSON NOT NULL, 
	PRIMARY KEY (id), 
	UNIQUE (draft_id), 
	FOREIGN KEY(draft_id) REFERENCES nfse_app.drafts (id)
)

;

ALTER TABLE nfse_app.jobs ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON nfse_app.jobs FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON nfse_app.jobs TO nfse_runtime;

DROP POLICY IF EXISTS nfse_backend ON nfse_app.jobs;

CREATE POLICY nfse_backend ON nfse_app.jobs TO nfse_runtime USING (true) WITH CHECK (true);

CREATE INDEX IF NOT EXISTS idx_jobs_draft_id ON nfse_app.jobs (draft_id);


CREATE TABLE IF NOT EXISTS nfse_app.nfse (
	id SERIAL NOT NULL, 
	dps_id INTEGER NOT NULL, 
	access_key VARCHAR(60) NOT NULL, 
	protocol VARCHAR, 
	xml_path VARCHAR NOT NULL, 
	danfse_path VARCHAR, 
	xml_sha256 VARCHAR(64) NOT NULL, 
	PRIMARY KEY (id), 
	UNIQUE (dps_id), 
	UNIQUE (access_key), 
	FOREIGN KEY(dps_id) REFERENCES nfse_app.dps (id)
)

;

ALTER TABLE nfse_app.nfse ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON nfse_app.nfse FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON nfse_app.nfse TO nfse_runtime;

DROP POLICY IF EXISTS nfse_backend ON nfse_app.nfse;

CREATE POLICY nfse_backend ON nfse_app.nfse TO nfse_runtime USING (true) WITH CHECK (true);

CREATE INDEX IF NOT EXISTS idx_nfse_dps_id ON nfse_app.nfse (dps_id);

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA nfse_app TO nfse_runtime;

CREATE UNIQUE INDEX IF NOT EXISTS uq_repeat_request ON nfse_app.audit (user_id, (info->>'request_id')) WHERE action='repeat_batch';

COMMIT;