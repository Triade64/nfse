# Produção restrita — levantamento em 04/11/2026

A simulação do MVP não envia DPS à SEFIN. A integração autenticada ainda não está habilitada. Produção permanece bloqueada.

## Fontes oficiais verificadas

- Catálogo de APIs: https://www.gov.br/nfse/pt-br/biblioteca/documentacao-tecnica/apis-prod-restrita-e-producao
- Swagger indicado para SEFIN de testes: https://sefin.producaorestrita.nfse.gov.br/API/SefinNacional/docs/index
- Documentação específica de testes: https://www.gov.br/nfse/pt-br/biblioteca/documentacao-tecnica/producao-restrita
- Pacote indicado: NFSe-ESQUEMAS_XSD-PRODREST-v1.01-20261020, ligado no catálogo a https://www.gov.br/nfse/pt-br/biblioteca/documentacao-tecnica/producao-restrita/esquemas_prod_restrita_20261020.zip
- Manual API contribuinte: https://www.gov.br/nfse/pt-br/biblioteca/documentacao-tecnica/documentacao-atual/manual-contribuintes-emissor-publico-api-sistema-nacional-nfs-e-v1-2-out2025.pdf
- Representação por procuração/vínculos, disponível a partir de 01/11/2026: https://www.gov.br/nfse/pt-br/noticias/nova-funcionalidade-possibilita-representacao-e-alternancia-de-perfis-na-nfs-e

## Confirmado e pendente

O catálogo separa os endereços de testes e produção. A documentação de testes inclui grupos IBS/CBS e pacote de 20/10/2026; não usar automaticamente os XSD de produção de fevereiro já incluídos no projeto. A notícia oficial confirma representação nas APIs de Emissão e Distribuição, validada pelo certificado da conexão e assinaturas, mediante autorizações pertinentes. Isso não comprova a autorização de nenhum CNPJ do escritório.

O manual descreve POST /nfse, GET /nfse/{chaveAcesso}, GET e HEAD /dps/{id}. As rotas são relativas: base de API, contratos JSON, assinatura e regras atuais devem ser conferidos no Swagger antes da implementação. Não foram deduzidas URLs adicionais nem implementados envios a partir de suposições.

Nesta verificação, o acesso ao Swagger falhou (502 na ferramenta de pesquisa e 503 na tentativa HTTP direta). O download direto do pacote XSD retornou 403. Isso descreve somente estas tentativas, não comprova indisponibilidade geral ou a causa da rejeição. Nenhum XSD novo foi instalado e nenhum envio autenticado foi feito.

## Próximo teste autorizado: somente homologação

1. Identificar primeiro emitente e certificado disponível. A1 em PKCS#12 é a opção técnica preferida para servidor; token/cartão A3 exige outra forma de integração e não deve ser presumido compatível com Vercel.
2. Conferir representação/credenciamento e município do emitente de teste. Não presumir que gov.br/senha autentique a API.
3. Obter contrato OpenAPI e XSD de testes, registrar versão/hash e validar XML offline.
4. Configurar certificado e senha em canal seguro, segregados dos segredos de banco e nunca no GitHub/chat/logs. Ainda não há upload ou guarda de certificados fiscais na interface.
5. Testar conexão e consulta antes de habilitar aprovação específica de envio para testes. Persistir identificador da DPS antes do envio; em timeout consultar antes de qualquer reenvio.
6. Guardar XML/retorno de teste separadamente e identificar explicitamente o ambiente. Não converter um resultado Simulado em Emitido.

A exclusão de rascunhos foi publicada separadamente, sem remover dados do usuário automaticamente: 35 testes backend e 10 frontend passaram. Documentos com fila, processamento ou DPS são bloqueados para exclusão.
