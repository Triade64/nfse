-- Migração 0.9.1: DANFSe oficial (PDF do ADN) obtido pelo conector com o certificado e guardado no site.
-- Aditiva. Revisar e executar no SQL Editor do projeto NFS-e, depois da 0003.
BEGIN;
ALTER TABLE nfse_app.dps
	ADD COLUMN IF NOT EXISTS danfse_pdf BYTEA,
	ADD COLUMN IF NOT EXISTS danfse_at VARCHAR(40),
	ADD COLUMN IF NOT EXISTS danfse_error VARCHAR(60);
COMMIT;
