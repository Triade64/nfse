-- Migração 0.10.0: emissão em produção (tpAmb 1) além da produção restrita (tpAmb 2).
-- O Id da DPS não contém o ambiente; a mesma série/número existe uma vez em cada ambiente.
-- Troca a unicidade de "identifier" por (environment, identifier). Não apaga nem altera dados.
-- Revisar e executar no SQL Editor do projeto NFS-e, depois da 0004.
BEGIN;

DO $$
DECLARE c record;
BEGIN
  -- Remove somente restrições UNIQUE cuja única coluna seja "identifier" (nome gerado pelo Postgres: dps_identifier_key).
  FOR c IN
    SELECT con.conname
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
    WHERE nsp.nspname = 'nfse_app' AND rel.relname = 'dps' AND con.contype = 'u'
      AND con.conkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = rel.oid AND attname = 'identifier')]::int2[]
  LOOP
    EXECUTE format('ALTER TABLE nfse_app.dps DROP CONSTRAINT %I', c.conname);
  END LOOP;
END $$;

ALTER TABLE nfse_app.dps DROP CONSTRAINT IF EXISTS uq_dps_environment_identifier;
ALTER TABLE nfse_app.dps ADD CONSTRAINT uq_dps_environment_identifier UNIQUE (environment, identifier);

COMMIT;
