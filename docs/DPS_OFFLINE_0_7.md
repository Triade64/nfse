# DPS de homologação: preparação offline 0.7

Fluxo: Configurações → escolher rascunho do escritório → conferir escolhas fiscais → baixar XML sem assinatura → conector Windows → conferir → assinar → salvar novo arquivo local.

Nenhum POST fiscal existe neste fluxo. Produção permanece bloqueada. O download não aprova lote, não muda situação do rascunho, não cria NFS-e ou DPS persistida e não reserva série/número. A ação é auditada por usuário/rascunho/hash/revisão, sem XML ou certificado no log. Antes de implementar envio, será obrigatório reservar identificadores de forma transacional, persistir o XML exato e impedir reenvios ambíguos.

## Fontes e alcance

- OpenAPI fornecido pelo usuário: `docs/official/sefin-restricted-v1.swagger.json`.
- Pacote `esquemas_prod_restrita_20261020.zip` fornecido pelo usuário: arquivos originais em `schemas/restricted-20261020/`, SHA-256 e origem registrados em `provenance.json`.
- Catálogo: https://www.gov.br/nfse/pt-br/biblioteca/documentacao-tecnica/producao-restrita
- Perfil de assinatura inicial baseado no manual integrado oficial **antigo**, 1.00.02, seção 6.1.4: https://www.gov.br/nfse/pt-br/biblioteca/documentacao-tecnica/leiaute-e-esquemas-antigos/manualintegradosnnfse_v1-00-02-producao.pdf
- Implementação Windows: `System.Security.Cryptography.Xml.SignedXml`, documentação Microsoft: https://learn.microsoft.com/dotnet/api/system.security.cryptography.xml.signedxml

O XSD recebido exige `finNFSe=0`; usa raiz DPS v1.01, ambiente 2 e identificação `DPS + IBGE(7) + tipo(1) + inscrição(14) + série(5) + número(15)`. O gerador inicial aceita apenas CNPJ numérico, prestador emitente, operação nacional tributável de ISS e ausência de retenções. Exige escolhas explícitas do Simples, regime especial, informação da alíquota e tributos totais. Não calcula tributos nem escolhe enquadramento.

IBS/CBS, endereço do tomador e outros grupos condicionais não foram implementados. Mesmo que opcionais no XSD, podem ser exigidos pelas regras de negócio. Operações que precisem desses campos não estão habilitadas para envio. Os campos atuais são um protótipo estrutural e não representam conclusão sobre obrigações tributárias de 2026.

Assinatura inicial: XMLDSIG RSA-SHA1/digest SHA1, enveloped e C14N inclusiva sem comentários, referência única ao Id do infDPS e apenas certificado público final. O identificador segue o XSD recebido, não o antigo exemplo `ID` do manual. **Aceitação desse perfil no ambiente de testes de 2026 ainda não foi confirmada**. Não usar documentação de NFS-e Via para presumir regras da SEFIN Nacional.

O conector exige CNPJ exato no SAN otherName OID 2.16.76.1.3.3, correspondente ao prestador. Não usa nome CN para inferir identidade nem exporta chave privada. A assinatura é verificada novamente depois da serialização. Isso verifica integridade, não cadeia ICP-Brasil, revogação, poderes de representação ou credenciamento. Não suporta e-CPF ou atuação por procuração nesta etapa.

## Verificação

Backend: testes com XSD recebido, novo campo obrigatório, escapes, ausência de defaults fiscais, bloqueio de retenções e opções inválidas, autenticação, revisão concorrente, auditoria e ausência de documentos fiscais persistidos.
Frontend: testes de aprovação explícita e alteração concorrente do rascunho; build TypeScript.
Windows CI: certificado RSA sintético com SAN fictício, geração/verificação XMLDSIG, alteração de valor detectada, CNPJ divergente, produção, DTD e segunda assinatura bloqueados. Não utiliza certificado real ou rede.

O resultado do diagnóstico HEAD 400 informado pelo usuário confirma uma resposta HTTP ao identificador inválido usado naquele teste. Não comprova emissão nem valida o conteúdo da DPS.
