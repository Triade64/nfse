# Campos obrigatórios da DPS: análise dos anexos oficiais

Atualizado em 05/11/2026. Fontes, baixadas pelo usuário do portal gov.br/nfse → Documentação Técnica (Homologação/testes) e guardadas em `docs/official/`:

- `anexo_i-sefin_adn-dps_nfse-snnfse_prodrest-v1-01-20261020.xlsx`: leiaute e regras de negócio. As referências `#NNN` e `E0NNN` abaixo vêm da aba "RN DPS_NFS-e 1.01".
- `anexo_b-nbs2-lista_servico_nacional-snnfse-prodrest-v1-01-20260122.xlsx`: lista nacional de serviços e lista NBS 2.0.
- `anexo_c-indop_ibscbs-snnfse-prodrest-v1-01-20260122.xlsx`: código indicador de operação (IBS/CBS).
- XSD `schemas/restricted-20261020/`.
- Ainda não lidos: Nota Técnica SE/CGNFS-e nº 009 (PDF) e a tabela de CST/cClassTrib do IBS/CBS (seção RTC do portal).

## Resumo

Pelo XSD, `cNBS`, o grupo `IBSCBS` e o endereço do tomador são **opcionais**. O que os torna obrigatórios são as regras de negócio:

| Campo / grupo | Regra | Quando é exigido | Situação no gerador |
|---|---|---|---|
| `toma/end/endNac` (CEP, logradouro, número, bairro, município) | **#274 E0235** | Emitente = prestador e **tomador identificado por CNPJ**. Vale hoje, independentemente do IBS/CBS. | **Não enviamos.** Qualquer nota para cliente PJ deve ser rejeitada. A nota autorizada era para um CPF. |
| Grupo `IBSCBS` | **#565 E0855** | "É obrigatório declarar informações de IBS/CBS quando a data de competência for igual ou posterior a 01/10/2026." | **Não enviamos.** A NFS-e autorizada em 05/11/2026 tinha competência 2026-11-05 e foi aceita sem o grupo, então a regra não estava sendo aplicada na produção restrita naquela data. Tratar como obrigatória: pode passar a ser aplicada a qualquer momento e vale para produção. |
| `cServ/cNBS` | **#343 E0322** | Obrigatório sempre que o grupo IBSCBS for informado, e na exportação (#341 E0318). Se informado, precisa existir no Anexo B (#340 E0316). | Não enviamos. |
| `IBSCBS/cIndOp` | #568 E0860 / #569 E0901 | Obrigatório quando a calculadora IBS/CBS indicar tributação. | Não enviamos. |
| `IBSCBS/indDest` | XSD (obrigatório dentro do grupo); #578/#579 | 0 = destinatário é o próprio tomador (sem grupo `dest`); 1 = outro destinatário (com grupo `dest`). | Não enviamos. |
| `IBSCBS/valores/trib/CST` e `cClassTrib` | XSD; #635 E0958, #636 E0959 | Sempre, dentro do grupo. Os 3 primeiros dígitos do cClassTrib devem ser iguais ao CST. | Não enviamos. **Precisamos da tabela oficial de cClassTrib.** |
| `gIBSCBS` | #637 E0960 / #638 E0961 | Somente se a calculadora indicar tributação pelo CST/cClassTrib. | Não enviamos. |
| Tomador para IBS/CBS | #276 | Se houver tributação IBS/CBS e o cIndOp indicar o domicílio do tomador como local, o tomador precisa de CNPJ/CPF **e endereço nacional**, mesmo quando for CPF. | Não enviamos. |

## Código de serviço do escritório: 171901 (Contabilidade)

- **Incidência do ISS** (aba "MUN.INCID_INFO.SERV."): estabelecimento/domicílio do prestador (EP). O `cLocPrestacao` não muda o município do ISS desse serviço.
- **NBS** (Anexo B, NBS 2.0): `1.1302.21.00` (Serviços de contabilidade). Também existem `1.1302.22.00` (escrituração mercantil) e `1.1302.11.00` (auditoria contábil). O Anexo B não traz a correlação automática entre cTribNac e NBS; a escolha é do emitente.
- **Indicador de operação** (Anexo C): os serviços contábeis entram em "demais serviços, em operações onerosas", `cIndOp = 100301`. O local do fornecimento é o **domicílio principal do adquirente** (tomador). Isso exige o endereço do tomador (#276) quando houver tributação IBS/CBS.

## Local da prestação (`serv/locPrest`)

- É obrigatório informar `cLocPrestacao` (município IBGE) **ou** `cPaisPrestacao` (exterior).
- #330 E0302: o código precisa existir na tabela IBGE (ou `0000000`, águas marítimas).
- #332 E0304: o país precisa existir na tabela ISO2 e não pode ser BR.
- Exportação: se `cPaisPrestacao` for informado, o NBS passa a ser obrigatório (#341 E0318).
- Para serviços com incidência no prestador (EP), como o 171901, o município do ISS é o do prestador, seja qual for o local da prestação. Para serviços com incidência no local da prestação (LP, ver a aba "MUN.INCID_INFO.SERV." por código), o `cLocPrestacao` define o município do ISS, e a escolha errada leva o imposto para o município errado.
- No IBS/CBS, o `cLocPrestacao` só define o local do fornecimento nos cIndOp que apontam para ele (imóvel, evento, transporte, "endereço diverso" etc.). Não é o caso do 100301.

Hoje o site usa o campo "Município da prestação (IBGE)" de cada nota, preenchido com o município da empresa. Recomendação: manter esse padrão e mostrar a regra de incidência do código de serviço ao lado do campo (EP / LP / tomador), a partir da aba "MUN.INCID_INFO.SERV.".

## O que precisa entrar no site

1. **Tomador:** endereço estruturado no cadastro (CEP, logradouro, número, complemento, bairro, município IBGE), além de e-mail e telefone opcionais. É obrigatório para CNPJ (E0235) e, quando houver IBS/CBS no domicílio do tomador, também para CPF (#276). Enviar em `toma/end/endNac`.
2. **NBS** no cadastro de serviços e na nota, validado contra a lista do Anexo B.
3. **IBS/CBS** no perfil fiscal da empresa: `CST`, `cClassTrib`, `cIndOp` (100301 para serviços contábeis), `indDest` (0 por padrão) e `indFinal`. Os valores de CST e cClassTrib dependem da tabela oficial e da situação da empresa no Simples. **Não inferir.**
4. **Local da prestação:** manter o padrão do município da empresa e exibir a regra de incidência do código de serviço.

**Situação informada pelo escritório (05/11/2026):** no momento da emissão ainda é possível escolher informar ou não o IBS/CBS, e o escritório ainda não está informando. Isso bate com a nota autorizada sem o grupo, mesmo com competência posterior a 01/10/2026. Por isso o IBS/CBS fica para depois e entra como **opção da empresa, desligada por padrão**. O NBS, que só é obrigatório junto com o IBS/CBS ou na exportação, entra como campo opcional, já pronto para quando o IBS/CBS for ligado. O endereço do tomador PJ (E0235) independe disso e é a prioridade.

Pendências antes de implementar o item 3: ler a NT 009 e a tabela de CST/cClassTrib (seção RTC), e confirmar com o contador responsável o enquadramento IBS/CBS do Simples Nacional para 2026.

## Implementado na versão 0.8.0: endereço do tomador (E0235)

- **Cadastro de tomadores:** campos estruturados (CEP, logradouro, número, complemento, bairro e município IBGE), além de e-mail e telefone. São validados ao salvar: CEP com 8 dígitos, município com 7 dígitos, campos obrigatórios e limites de tamanho do XSD. O CEP e o código IBGE são gravados só com dígitos. O antigo campo "Endereço completo" em texto livre continua visível em cadastros antigos, mas **não é enviado**: o endereço nunca é deduzido de texto livre.
- **XML:** `toma/end/endNac(cMun, CEP)`, `xLgr`, `nro`, `xCpl` (se houver) e `xBairro`, na ordem do XSD. É enviado sempre que o endereço do tomador estiver completo no cadastro da empresa emitente, para CNPJ ou CPF.
- **Bloqueio:** um tomador com CNPJ sem endereço completo não é emitido (422 com a referência E0235), e o número da DPS **não** é consumido. A tela Notas mostra o aviso na linha e esconde o "Emitir" até o cadastro ser completado.
- **Testes:** backend com 74 de 74 aprovados (validação e normalização do cadastro, bloqueio E0235 sem consumir número, XML válido no XSD com a ordem dos campos, CPF com endereço opcional); frontend com 18 de 18 aprovados; no navegador local, salvar o cadastro incompleto mostrou "Endereço incompleto: informe Bairro, Município (IBGE)", e o cadastro completo liberou a emissão.

Próximo item: NBS opcional no cadastro de serviços e na nota.
