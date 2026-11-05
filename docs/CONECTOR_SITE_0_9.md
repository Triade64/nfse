# Conector aberto pelo site: versão 0.9.0 (site e conector)

Objetivo: o botão **Assinar e enviar** da tela Notas abre o conector no PC, de forma parecida com assinadores como o do Serpro. Foi escolhido o modelo de **link que abre o programa** (`triade-nfse://`). Ele não usa serviço local escutando porta.

## Fluxo

1. **Notas → Emitir** (com "Abrir o conector" marcado) ou **Assinar e enviar** (uma nota ou várias selecionadas). O site reserva o número, se ainda não tiver, e cria um **ticket**: `POST /api/connector/tickets {dps_ids}`, só para administrador e só para DPS `Reservada`/`Desconhecida`.
2. O navegador abre `triade-nfse://assinar?site=<origem>&ticket=<token>`. O Windows inicia `ConectorTriade.ps1 -Url "<link>"`.
3. O conector:
   - valida o link, exigindo que o site esteja **exatamente** na lista fixa (`https://nfse-sand.vercel.app`) e que o ticket tenha formato válido;
   - busca os trabalhos (`GET /api/connector/jobs`, com `Authorization: Bearer <ticket>`);
   - pede **uma** confirmação com emitente, tomadores, competências e valores;
   - escolhe o certificado do Windows com o CNPJ do emitente.
4. Para cada DPS:
   - o SHA-256 do XML deve ser igual ao que o site guardou;
   - `Protect-TriadeOfflineDps` confere de novo XSD, `tpAmb=2`, prestador emitente e CNPJ do certificado, e assina;
   - `Invoke-TriadeSingleRestrictedDps` faz o mesmo envio de antes: histórico gravado antes do POST, HEAD antes de enviar e nunca reenvio automático;
   - o conector devolve o resultado em `POST /api/connector/jobs/{id}/result`.
5. O site:
   - marca **Autorizada** só depois de conferir que a NFS-e devolvida contém **a DPS reservada** (Id, série, número, competência, CNPJ do prestador e do tomador, valor e ambiente 2);
   - guarda a chave e o XML da NFS-e;
   - **Rejeitada** guarda os códigos (por exemplo E0712) e permite descartar e emitir de novo;
   - **Desconhecida** permite gerar outro link, que só consulta.
6. A tela Notas atualiza sozinha a cada 5 segundos enquanto houver nota aguardando o conector.

## Segurança

- **Ticket:** vale 15 minutos e só para as DPS escolhidas. O site guarda apenas o hash, e o token não vai para a auditoria. A rota de jobs não aceita a sessão do navegador, só o ticket.
- **Link malicioso:** um link vindo de outro site é recusado pelo conector antes de qualquer acesso à rede (`SITE_NOT_ALLOWED`), inclusive variações como sufixo de domínio, `http`, caminho, maiúsculas e parâmetros repetidos ou extras.
- **Conteúdo adulterado:** XML alterado no caminho (`SITE_XML_INTEGRITY`) ou DPS de outro CNPJ não chegam ao transporte fiscal.
- **Resultado:** uma DPS autorizada é final (o mesmo resultado repetido é idempotente; um resultado diferente recebe 409). O site recusa NFS-e com outro valor, outra DPS, ambiente de produção, chave divergente, Base64 inválido ou DTD.
- **Instalação:** `Ativar_Abertura_pelo_Site.cmd` (ou o botão na janela) registra o protocolo em `HKCU\Software\Classes\triade-nfse`, só para o usuário atual e sem administrador.
- Certificado, senha e chave privada nunca saem do PC. **A produção real continua bloqueada.**

## Banco

`database/migrations/0003_conector_site.sql` (aditiva):
- na tabela `dps`: `access_key`, `nfse_xml`, `result` e `result_at`;
- tabela nova `connector_tickets`.

Aplicar no Supabase **antes** do merge.

## Testes

- **Backend:** 81 de 81 aprovados. `test_connector_site.py` cobre:
  - ticket, link e jobs;
  - autorização idempotente e final;
  - rejeição;
  - situação desconhecida, depois nova consulta;
  - NFS-e adulterada (valor, Id, produção, chave, Base64, DTD);
  - escopo e expiração do ticket;
  - permissões.
- **Frontend:** 21 de 21 aprovados (emitir e abrir o conector, aviso de espera, chave e download da NFS-e, código da SEFIN, descarte só para rejeitada).
- **Conector (`tests/Test-Site.ps1`):**
  - 10 links maliciosos recusados;
  - busca com ticket, com o mesmo pipeline da janela;
  - autorização no formato real (`idDps=NFS+chave`);
  - rejeição;
  - timeout seguido de consulta sem reenvio (duas variações);
  - XML adulterado e outro emitente bloqueados;
  - ticket expirado.
- **Ponta a ponta local:** site real (uvicorn) e funções reais do conector por HTTP, com certificado sintético e só a SEFIN simulada. Uma DPS foi autorizada (o site mostrou "NFS-e autorizada" com a chave, e o download da NFS-e funcionou), outra foi rejeitada com E0712 (o site mostrou "DPS rejeitada"). O mesmo link foi recusado com a lista oficial de sites. Esse teste **encontrou e corrigiu** um erro em que a janela do conector descartaria todas as notas (a lista vinha "embrulhada" no pipeline do PowerShell).

Não testado: o registro do protocolo no Windows e a abertura pelo navegador, que dependem de rodar `Ativar_Abertura_pelo_Site.cmd` no PC; e o envio real à SEFIN por esse fluxo.
