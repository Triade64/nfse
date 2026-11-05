-- Migração 0.6.1: descarte de reserva de DPS.
-- Um rascunho pode ter reservas descartadas, mas no máximo uma DPS ativa.
-- Números descartados continuam ocupados (uq_dps_number) e nunca são reutilizados.
-- Aditiva: nenhum dado é apagado. Revisar e executar no SQL Editor do projeto NFS-e, depois da 0001.
BEGIN;

ALTER TABLE nfse_app.dps
	ADD COLUMN IF NOT EXISTS discarded_at VARCHAR(40),
	ADD COLUMN IF NOT EXISTS discarded_by INTEGER REFERENCES nfse_app.users (id),
	ADD COLUMN IF NOT EXISTS discard_reason VARCHAR(500);

-- A unicidade por rascunho passa a valer só para DPS ativas.
-- Cria primeiro o índice novo, para nunca ficar sem proteção dentro da transação.
CREATE UNIQUE INDEX IF NOT EXISTS uq_dps_active_draft ON nfse_app.dps (draft_id)
	WHERE status IS NULL OR status <> 'Descartada';
ALTER TABLE nfse_app.dps DROP CONSTRAINT IF EXISTS dps_draft_id_key;
CREATE INDEX IF NOT EXISTS idx_dps_discarded_by ON nfse_app.dps (discarded_by);

COMMIT;
