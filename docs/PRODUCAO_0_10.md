# Produção (0.10.0): emissão de notas reais

A partir da versão 0.10.0, cada empresa emite em um de dois ambientes:

- **produção restrita** (testes, `tpAmb` 2): é o padrão;
- **produção** (notas reais, com validade jurídica, `tpAmb` 1).

Só um administrador troca o ambiente, e cada troca fica registrada na auditoria (`change_environment`).

## O que foi conferido antes

| Item | Resultado |
|---|---|
| API de produção (Swagger lido com o certificado do escritório, somente GET, em 05/11/2026) | Contrato idêntico ao da produção restrita: mesmos caminhos, métodos e modelos. Base `https://sefin.nfse.gov.br/SefinNacional`. Cópia em `docs/official/sefin-producao-v1.swagger.json`. |
| Leiaute em produção | Página oficial "Documentação Atual (Produção)": esquemas **v1.01 de 09/02/2026**. A atualização de 20/10/2026 (NT 009) consta **só** na produção restrita ("Atualizações e Implantações"). |
| Diferenças que afetam o nosso XML | Em produção, `finNFSe` não existe em `infDPS`: só dentro de `IBSCBS`, que não enviamos. `xDescServ` vem **antes** de `cNBS`. O site gera cada leiaute conforme o ambiente. |
| NFS-e real do escritório (nº 69, Emissor Web, 04/11/2026) | Série 70000, faixa do Emissor Web. Saiu sem IBS/CBS, logo a produção aceita a nota sem esse grupo. |
| Série | Regra E0010: de 00001 a 49999 é a faixa do **aplicativo próprio**; de 50000 em diante, a dos emissores do governo. O site recusa séries fora de 1–49999 nos dois ambientes. |

## Defeitos nos esquemas oficiais de produção (contornados em memória, arquivos intactos)

1. **Padrão da série.** `TSSerieDPS` usa `^0{0,4}\d{1,5}$`. Em expressões regulares de XSD, `^` e `$` são caracteres literais, então o libxml2 do site recusaria qualquer série. O validador do governo (.NET) os trata como âncoras, e por isso a série 70000 foi autorizada. O site valida com uma cópia **em memória** sem `^`/`$`. O .NET do conector já aceita o padrão como está.
2. **DOCTYPE no `xmldsig-core-schema.xsd`.** O arquivo de produção traz o cabeçalho DTD do W3C, e o conector proíbe DTD. O resolvedor do conector remove em memória **exatamente** esse cabeçalho conhecido e recusa qualquer outro. Sem o cabeçalho, o arquivo é idêntico ao da produção restrita.

`schemas/production-20260209/provenance.json` registra o SHA-256 do pacote e de cada arquivo.

## Passo a passo do piloto (só o escritório)

1. Aplicar `database/migrations/0005_producao.sql` no SQL Editor do Supabase **antes** do merge. Ela troca a unicidade do identificador da DPS por (ambiente, identificador), porque o Id da DPS não contém o ambiente.
2. Depois do deploy, baixar de novo o conector em **Configurações** (versão 0.10.0, com `schemas\producao`), substituir a pasta e rodar `Ativar_Abertura_pelo_Site.cmd`.
3. Em **Configurações → Numeração de DPS**, escolher o ambiente **Produção**, a **série 1** e o próximo número **1**.
4. Em **Empresas → Editar**, mudar o ambiente de emissão para **Produção**. O site pede uma confirmação.
5. Emitir **uma** nota real de valor conhecido pela tela Notas. A confirmação "NOTA REAL" é obrigatória. O conector mostra o aviso vermelho e pede **duas** confirmações.
6. Conferir a nota autorizada no Emissor Nacional / Consulta Pública. O número da NFS-e (`nNFSe`) segue a sequência do escritório (≈ 70), atribuída pela SEFIN.
7. Se algo estiver errado, **cancelar ou substituir no Emissor Nacional web**. O cancelamento pelo sistema ainda não existe.

Para voltar aos testes, basta mudar o ambiente da empresa para produção restrita. As numerações dos dois ambientes são independentes.

## Proteções

- O ambiente da DPS é gravado na reserva e acompanha o job do conector. Um link nunca mistura ambientes.
- O conector usa um esquema e um host fixos por ambiente, e um histórico separado em `%LOCALAPPDATA%\TriadeNfse\Conector\producao`.
- A pasta de esquemas precisa corresponder ao ambiente (`SCHEMA_ENVIRONMENT`).
- Uma resposta ou NFS-e com `tipoAmbiente`/`tpAmb` diferente do ambiente da DPS nunca vale como autorização, nem no conector nem no site.
- O resultado informado pelo conector traz o ambiente no rótulo ("Autorizada em produção"). O site recusa um rótulo de outro ambiente.
- A reserva pela tela antiga de rascunhos é bloqueada para empresas em produção.
- O marcador de tentativa continua gravado antes do POST, com consulta prévia obrigatória. Não há reenvio automático.

## Limitações conhecidas

- O QR do DANFSe de produção aponta para `https://www.nfse.gov.br/ConsultaPublica?tpc=1&chave=…`, deduzido do QR da produção restrita. Precisa ser conferido na primeira nota real.
- O IBS/CBS continua não enviado, o que a produção aceita hoje: a NFS-e nº 69 saiu sem o grupo.
- O certificado do escritório vence em **17/11/2026**.
