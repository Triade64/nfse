# Numeração central de DPS — versão 0.6.0

Atualizado em 05/11/2026. Pré-requisito: o operador confirmou a primeira DPS de teste do escritório **autorizada (HTTP 201) em produção restrita** pelo conector 0.8.4, após as revisões E0008 (fuso) e E0120 (omissão da IM).

## O que muda

- Nova tabela `dps_series`: próximo número por empresa, ambiente (`2` = produção restrita) e série. Ele só avança: não pode retroceder nem ficar abaixo de um número já reservado.
- `POST /api/drafts/{id}/dps` (administrador): trava a série (`SELECT … FOR UPDATE` no PostgreSQL; `BEGIN IMMEDIATE` no SQLite), consome o próximo número, gera o XML, confere-o no XSD e grava o **XML exato** e o SHA-256 na tabela `dps`, com a situação `Reservada`. A operação é idempotente: para o mesmo rascunho, devolve a reserva existente.
- Se o XML não for gerado (rascunho inválido ou operação não suportada), nenhum número é consumido. O índice único `(company_id, environment, series, number)` é a garantia final no banco.
- `dhEmi` vem do relógio do servidor, 1 minuto antes do momento da reserva, em horário de Brasília (-03:00). Isso evita uma data futura (E0008).
- `GET /api/dps/{id}/xml` baixa o XML gravado, com registro de auditoria. A auditoria não guarda o XML.
- Um lote com DPS reservada não pode ser editado, revalidado nem ter rascunhos excluídos.
- Interface (Configurações): o painel "Numeração de DPS" configura a série. Em "Preparar DPS", a opção "Reservar o próximo número da série" gera e baixa a DPS. A prévia sem reserva continua disponível.

O site **não assina nem envia**: o XML baixado segue para o conector 0.8.4 (assinar → enviar 1 DPS de teste), como antes.

## Antes de usar

1. Aplicar `database/migrations/0001_numeracao_dps.sql` no projeto Supabase do NFS-e. A migração é aditiva e não altera dados. `database/schema.sql` já inclui essas mudanças para instalações novas.
2. Configurar a série do escritório com um próximo número **maior que o da DPS já autorizada** (e de qualquer outra tentativa enviada pelo conector com número digitado).
3. Publicar o deploy na Vercel.

## Limites

- Somente produção restrita (ambiente 2) e emitente igual ao próprio escritório, como na 0.7/0.8.
- Um número reservado e não enviado fica como lacuna. Ainda não existe uma ação para descartar uma reserva. As regras da SEFIN sobre lacunas na numeração não foram verificadas.
- O resultado do envio ainda não volta ao site: o histórico continua no PC (conector). O pareamento do conector com a fila do site é a próxima etapa.

## Testes

`backend/tests/test_dps_numbering.py` cobre:

- sequência e idempotência;
- XML gravado igual ao baixado e válido no XSD;
- série que não retrocede, com controle de revisão;
- série ausente, versão desatualizada, confirmação ausente e CNPJ divergente;
- falha de geração sem consumir número;
- bloqueio de edição do lote;
- permissões.

Há também um teste de frontend do modo de reserva.

O teste `test_backup_integrity_and_no_credentials_in_audit` já falhava no Windows antes desta versão, porque o SQLite temporário fica bloqueado. Não tem relação com a numeração.
