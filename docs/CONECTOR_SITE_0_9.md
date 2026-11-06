# Conector aberto pelo site: versão 0.9.0 (site e conector)

Objetivo: o botão **Assinar e enviar** da tela Notas abre o conector no PC, de forma parecida com assinadores como o do Serpro. Foi escolhido o modelo de **link que abre o programa** (`triade-nfse://`). Ele não usa serviço local escutando porta.

## Fluxo

1. **Notas → Emitir** (com "Abrir o conector" marcado) ou **Assinar e enviar** (uma nota ou várias selecionadas). O site reserva o número, se ainda não tiver, e cria um **ticket**: `POST /api/connector/tickets {dps_ids}`, só para administrador e só para DPS `Reservada`/`Desconhecida`.
2. O navegador abre `triade-nfse://assinar?site=<origem>&ticket=<token>`. O Windows inicia `ConectorTriade.ps1 -Url "<link>"`.
3. O conector:
   - valida o link, exigindo que o site esteja **exatamente** na lista fixa (`https://nfse.triade.cnt.br` e, na transição, `https://nfse-sand.vercel.app`) e que o ticket tenha formato válido;
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

## Atualização 0.9.1: DANFSe oficial

- **Conector:** depois da autorização (inclusive quando a autorização é recuperada por consulta), `Get-TriadeDanfse` busca o PDF em `https://adn.producaorestrita.nfse.gov.br/danfse/{chaveAcesso}`:
  - endereço fixo, certificado do Windows no TLS, sem redirecionamento, limite de 8 MB;
  - exige HTTP 200 e conteúdo que comece com `%PDF-`;
  - guarda `danfse.pdf` no histórico do PC e envia ao site (`POST /api/connector/jobs/{id}/danfse`).
- **Falhas:** HTTP diferente de 200, resposta que não é PDF ou falha de rede são enviadas ao site **só como código** (por exemplo `DANFSE_HTTP_404`). A NFS-e continua autorizada.
- **Só o DANFSe:** uma DPS **Autorizada sem DANFSe** pode receber um ticket só para baixar o PDF ("Buscar DANFSe"). O conector não assina e não chama a SEFIN, só o ADN.
- **Site:**
  - guarda o PDF (`dps.danfse_pdf`, migração aditiva `0004_danfse.sql`);
  - serve o download em `GET /api/dps/{id}/danfse.pdf`;
  - aceita só PDF de até 5 MB;
  - uma falha posterior nunca apaga um PDF já guardado.
- **Notas:** botões **DANFSe** e **XML NFS-e**; para autorizada sem PDF, **Buscar DANFSe** e o aviso "DANFSe pendente (código)".

**Atenção:** o caminho `/danfse/{chave}` segue a documentação do ADN indicada pelo Swagger da SEFIN (`/DANFSe` → 501 "movido"), mas essa documentação só abre com o certificado e **ainda não foi confirmada com uma chamada real**. Se a chamada real retornar outro código, o site mostra "DANFSe pendente (DANFSE_HTTP_xxx)", e ajustamos o endereço.

**Testes:**
- backend com 84 de 84 aprovados (recebimento e validação do PDF, código de falha, PDF preservado, ticket só de DANFSe, permissões);
- frontend com 22 de 22 aprovados;
- conector com todas as suítes aprovadas (DANFSe após autorização e após consulta, 404, resposta não-PDF, job só de DANFSe sem assinatura e sem SEFIN);
- ponta a ponta local: autorização seguida do DANFSe, com o site servindo `application/pdf`.

### Verificação do DANFSe na API (05/11/2026)

Na primeira chamada real, a NFS-e (DPS série 1 nº 9) foi autorizada, mas o DANFSe voltou `DANFSE_HTTP_404`, também numa segunda tentativa cerca de 20 minutos depois. Com autorização do usuário, a documentação foi lida com o certificado do escritório, só por GET:

- **ADN de produção restrita:**
  - tudo em `/danfse/...` responde 404, inclusive `/danfse/docs/index.html`, que o portal indica;
  - as especificações disponíveis (`/adn`, `/contribuintes`, `/municipios`, salvas em `docs/official/adn-restrita-*.json`) não têm nenhum serviço de DANFSe: só recepção de lotes, distribuição por NSU (`/DFe/{NSU}`) e eventos.
- **ADN de produção:** `/danfse/docs/...` responde 503 (indisponível).
- **Manuais oficiais**, em `docs/official`:
  - "Guia para utilização das APIs do ADN" (v1.0, 12/02/2026): só distribuição e eventos;
  - "Guia para utilização das APIs do Emissor Público Nacional" (v1.2): parâmetros municipais, NFS-e, DPS e eventos.
  - **Nenhum dos dois descreve API de DANFSe.**

**Conclusão:** hoje não existe API documentada e disponível para o contribuinte obter o DANFSe na produção restrita. A busca pelo conector (0.9.1) não é um erro de endereço do nosso lado: o serviço não está publicado.

## Atualização 0.9.2: DANFSe gerado pelo site

Como não há API de DANFSe disponível (veja a verificação acima), o site gera o DANFSe a partir do **XML da NFS-e autorizada**, que ele já guarda e conferiu contra a DPS reservada (`backend/app/danfse.py`, biblioteca `fpdf2`).

- **Rota:** `GET /api/dps/{id}/danfse.pdf` serve o PDF oficial, se um tiver sido recebido do conector; se não, gera o PDF na hora a partir de `dps.nfse_xml`. Fica disponível só para NFS-e autorizada, e cada download é auditado.
- **Conteúdo, todo lido do XML:**
  - número da NFS-e, chave, competência, emissão da DPS, autorização (`dhProc`), situação, série e número da DPS, município emissor e `nDFSe`;
  - prestador (CNPJ, nome, endereço, Simples) e tomador (documento, nome, endereço);
  - código de tributação nacional e descrição, NBS, local da prestação e de incidência, descrição do serviço;
  - valores, tributação e retenção do ISSQN, alíquota, tributos aproximados e valor líquido;
  - observações.
- **Ambiente de testes** (`tpAmb=2`): faixa vermelha "PRODUÇÃO RESTRITA (AMBIENTE DE TESTES) — DOCUMENTO SEM VALOR FISCAL" e marca d'água.
- **Rodapé:** identifica o documento como representação gráfica gerada a partir do XML autorizado e orienta a conferir a chave no Portal Nacional.
- **Conector 0.9.2:** não chama mais o ADN depois da autorização. A busca continua disponível no código com `-FetchDanfse`, para quando o serviço for publicado. O site deixa de emitir ticket "só DANFSe".
- **Testes:**
  - backend com 87 de 87 aprovados: gerador (dados, aviso de testes, produção sem aviso, XML inválido) e rota (gerado sem ida ao conector, PDF oficial preferido, auditoria);
  - frontend com 22 de 22 aprovados;
  - conector com todas as suítes aprovadas, provando que por padrão não há chamada ao ADN;
  - DANFSe gerado a partir da NFS-e real da DPS nº 9 conferido visualmente.

## Atualização 0.9.3: DANFSe no modelo oficial v2.0

O DANFSe gerado pelo site passa a reproduzir o **DANFSe v2.0 do Portal Nacional**, a partir do PDF oficial que o escritório baixou para a NFS-e nº 5 (DPS nº 7). A geometria (posição, fonte e tamanho de cada texto, linhas e faixas cinza) foi medida nesse PDF.

- **Cabeçalho:**
  - logo da NFS-e (`backend/app/data/nfse-logo.png`, com transparência, extraído do modelo; é o logo que o portal disponibiliza);
  - "DANFSe v2.0 / Documento Auxiliar da NFS-e" e, em produção restrita, "NFS-e SEM VALIDADE JURÍDICA" em vermelho;
  - município, ambiente gerador e tipo de ambiente.
- **QR code:** desenhado em vetor (`segno`), aponta para a consulta pública: `https://www.producaorestrita.nfse.gov.br/ConsultaPublica?tpc=1&chave=…` em testes, a mesma URL decodificada do QR oficial; `https://www.nfse.gov.br/ConsultaPublica?tpc=1&chave=…` em produção, por analogia (ainda não confirmada).
- **Blocos, como no oficial:**
  - identificação: chave, números, datas, emitente, situação e finalidade;
  - prestador/fornecedor e tomador/adquirente;
  - destinatário e intermediário;
  - serviço prestado;
  - tributação municipal (ISSQN), tributação federal e tributação IBS/CBS;
  - valor total;
  - informações complementares, com os totais aproximados da Lei 12.741;
  - recibo no rodapé.
- **Textos das opções:** vêm das descrições do XSD oficial (Simples Nacional, regime de apuração, tributação e retenção do ISSQN, emitente, finalidade). Campos ausentes no XML saem como "-", como no oficial. Telefone, e-mail e IM do prestador vêm da DPS, como no oficial.
- **Limitação:** o nome do município de um tomador de outra cidade só aparece se estiver no XML; se não, sai o código IBGE. Para mostrar o nome, falta incorporar a tabela de municípios (Anexo A).
- **Comparação:** a mesma NFS-e nº 5 gerada pelo site ficou visualmente igual ao PDF oficial. O QR gerado decodifica para a mesma URL do QR oficial.
- **Testes:** backend com 88 de 88 aprovados, incluindo o teste do QR (`pymupdf` e `opencv-python-headless` só em `requirements-dev.txt`).
- **Dependências do site:** `fpdf2==2.8.3` e `segno==1.6.6` (Python puro).

## Atualização 0.9.4: nomes de municípios e países no DANFSe

- **Tabela oficial:** `backend/app/data/localidades.json`, gerada do Anexo A (`docs/official/anexo_a-municipio_ibge-paises_iso2-v1-00-snnfse-20251210.xlsx`) por `scripts/build_localidades.py`. Tem 5.570 municípios IBGE com nome e UF, 250 países ISO2 e a localidade especial `0000000` (Águas Marítimas).
- **Correção do Anexo A:** a planilha oficial deixa a coluna "Sigla UF" vazia a partir do Maranhão (5.120 linhas). O script deriva a UF do prefixo de 2 dígitos do código IBGE e confere com a sigla nas linhas em que ela existe. Uma divergência interrompe a geração; nenhuma foi encontrada.
- **DANFSe:**
  - "Município / Sigla UF" do prestador e do tomador mostra o nome e a UF pela tabela, também para outras cidades;
  - "Local da Prestação / Sigla UF / País" e "Município / Sigla UF / País de Incidência do ISSQN" seguem o formato oficial `Cidade / UF / -`; no exterior aparece `- / - / País`;
  - código desconhecido continua visível como `IBGE <código>`.
- **Testes:** backend com 90 de 90 aprovados (tomador em Florianópolis/SC, prestação em São Paulo/SP, prestação em Portugal, código desconhecido). A mesma NFS-e nº 5 continua igual ao modelo oficial.
