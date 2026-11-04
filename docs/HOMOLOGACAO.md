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
4. Configurar certificado e senha em canal seguro, segregados dos segredos de banco e nunca no GitHub/chat/logs. Há um formulário exclusivo de diagnóstico temporário do A1 em Configurações, com consentimento explícito e perfil administrador. Ele não guarda credenciais para uso posterior e não habilita emissão.
5. Testar conexão e consulta antes de habilitar aprovação específica de envio para testes. Persistir identificador da DPS antes do envio; em timeout consultar antes de qualquer reenvio.
6. Guardar XML/retorno de teste separadamente e identificar explicitamente o ambiente. Não converter um resultado Simulado em Emitido.

A exclusão de rascunhos foi publicada separadamente, sem remover dados do usuário automaticamente: 35 testes backend e 10 frontend passaram. Documentos com fila, processamento ou DPS são bloqueados para exclusão.

## Diagnóstico A1 pela interface

Em Configurações, o administrador pode enviar um PKCS#12 de até 256 KB e sua senha via HTTPS, com consentimento explícito. A API verifica abertura, presença da chave privada, correspondência com a chave pública, validade temporal e finalidade de cliente quando a extensão existir. O resultado não contém nome/CNPJ do titular, chave, senha ou arquivo.

O teste externo é opcional e faz apenas GET para o endereço oficial de documentação de produção restrita acima. TLS do servidor e hostname são verificados; redirecionamentos não são seguidos. A chave é carregada no contexto TLS usando um arquivo temporário criptografado, removido em seguida. O conteúdo e a senha não são persistidos no banco nem nos logs; a auditoria guarda somente a solicitação do teste e o status HTTP. Dados da requisição podem permanecer em memória durante seu processamento; não há promessa de apagamento físico da memória Python.

HTTP 200 significa resposta da documentação, não autorização de emissão ou validação da representação. O diagnóstico não verifica cadeia ICP-Brasil, revogação, procuração ou credenciamento. Não assina XML, não envia DPS e não altera os estados fiscais de qualquer lote.

Validação: 41 testes backend, 12 testes frontend e compilação TypeScript/Vite passaram. Os testes novos usam certificados autogerados fictícios, sem validade ICP-Brasil. Ainda não houve teste com o certificado do escritório; nenhum certificado real foi recebido durante o desenvolvimento.
