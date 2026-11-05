# Tela Notas — versão 0.7.0 (fase 1 da reestruturação)

Objetivo: tirar o "lote" do centro do trabalho. A rotina mensal passa a ser: abrir Notas, selecionar as notas do mês anterior, duplicar para a nova competência, conferir e emitir.

## O que muda para quem usa

- **Menu:** Início · **Notas** · Empresas · Tomadores · Serviços · Lotes e importação (avançado) · Relatórios · Configurações. A antiga tela "Emissões" foi substituída por Notas. "Preparar notas" passou a se chamar "Lotes e importação" e guarda a planilha, a grade e os lotes antigos.
- **Notas:** lista única com busca e filtros (empresa, situação, competência). Ações por linha:
  - **Editar:** só enquanto a nota não tem DPS reservada.
  - **Duplicar:** escolhe a nova data.
  - **Emitir:** apenas administrador.
  - **XML** e **Descartar** reserva.
  Também é possível selecionar várias notas e duplicá-las de uma vez.
- **Situação:** Rascunho · Com inconsistência · Pronta · DPS reservada.
- **Perfil fiscal da empresa** (Empresas → Editar): série, Simples Nacional, regime, IM no XML, alíquota no XML e tributos totais. É preenchido uma vez e usado em toda emissão. O ponto de partida sugerido segue o que a API de testes indicou para o escritório: IM omitida (E0120) e alíquota omitida para ME/EPP no SN sem retenção (E0625). Deve ser conferido para cada empresa.
- A aprovação e simulação de lotes saiu do fluxo principal. Continua disponível apenas em Lotes e importação.

## API

- `GET /api/notes`: notas com a situação calculada e a DPS ativa. Aplica as mesmas restrições de usuário e empresa da antiga lista.
- `POST /api/notes/duplicate` `{draft_ids, competencia, confirm_review: true, request_id}`:
  - Cria **uma nota por lote**, validada, de modo que travas e revisões nunca atinjam notas não relacionadas.
  - Tudo ou nada: se já existir nota idêntica na competência (mesma impressão digital), recusa com 409 e não cria nada.
  - É idempotente pelo `request_id`.
- `POST /api/notes/{id}/emit` `{batch_revision, expected_raw, confirm: true}` (administrador):
  - Usa o perfil fiscal da empresa e reaproveita a reserva central da 0.6.
  - Se o cadastro da empresa mudou desde a validação, por exemplo porque o perfil foi editado, revalida a nota antes de reservar.
- O perfil fiscal é validado no salvamento da empresa (`FiscalProfile`): combinações incoerentes e campos desconhecidos são recusados.

Sem migração de banco: o perfil fica em `companies.config`. Requer as migrações 0001 e 0002 já aplicadas.

## Ainda não incluído

- Duplicata intencional na mesma competência (fase 2, exige migração).
- Retorno automático do conector para o site, com as situações Enviada, Autorizada e Rejeitada (fase 3).

## Testes

- Backend `test_notes.py` (7 casos):
  - situação da nota;
  - duplicação para outra competência com um lote por nota;
  - recusa de nota idêntica sem criar nada;
  - idempotência;
  - validação do perfil;
  - emissão com o perfil, com revalidação automática e XML sem IM e sem alíquota;
  - lista desatualizada e permissões.
- Frontend `Notas.test.tsx` (3 casos):
  - duplicar várias notas com confirmação;
  - emitir com o perfil e baixar o XML;
  - erro de duplicata exibido no diálogo.
- Navegador, local, com dados fictícios: perfil configurado pela tela de Empresas; 2 notas duplicadas de outubro para novembro; emissão gerou série 1 nº 2 com XML sem IM e sem alíquota; descarte devolveu a nota para Pronta.
