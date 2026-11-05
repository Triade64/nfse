# Produção restrita — conector local

Atualizado em 05/11/2026. Preferência do escritório: o certificado e a senha devem permanecer no PC. A simulação do site não envia DPS; produção permanece bloqueada.

## Fluxo disponível

Em Configurações, o administrador baixa o ZIP do conector local 0.1. O programa usa Windows PowerShell 5.1 e .NET Framework, sem Python. Ele pode selecionar um certificado já instalado no repositório CurrentUser/My ou abrir um A1 em memória com EphemeralKeySet. Não exporta a chave, instala certificados ou envia arquivo/senha ao site.

O diagnóstico externo é opcional: somente GET para https://sefin.producaorestrita.nfse.gov.br/API/SefinNacional/docs/index . Certificado público e prova criptográfica são apresentados na autenticação TLS; chave privada e senha permanecem locais. Redirecionamentos são desabilitados e a verificação TLS do Windows não é substituída. Não há URL configurável. Algumas versões de Schannel/.NET não aceitam chave efêmera para TLS; o programa falha sem persistir a chave e orienta usar um certificado já instalado.

O resultado contém somente situação, validade e status HTTP; não contém CPF/CNPJ, nome, senha ou chave. O operador o copia manualmente. Não há pareamento, servidor localhost, fila automática, assinatura ou envio de DPS nesta versão. A3/token não foi homologado. HTTP 200 da documentação não comprova autorização para emissão ou representação.

## Upload removido

O formulário anterior de upload foi removido. A rota antiga `/api/integrations/restricted/diagnostic` responde HTTP 410 no middleware, antes do processamento do corpo multipart. O site não oferece mais coleta de A1/senha; a implementação anterior de importação do A1 no servidor foi retirada. Logs antigos de auditoria continham somente solicitação/status, não certificados.

## Fontes oficiais

- Catálogo: https://www.gov.br/nfse/pt-br/biblioteca/documentacao-tecnica/apis-prod-restrita-e-producao
- Testes/XSD: https://www.gov.br/nfse/pt-br/biblioteca/documentacao-tecnica/producao-restrita
- Referência de testes: NFSe-ESQUEMAS_XSD-PRODREST-v1.01-20261020. Não reutilizar automaticamente o pacote de produção de fevereiro.
- Representação por certificado/assinatura e procuração ou vínculos: https://www.gov.br/nfse/pt-br/noticias/nova-funcionalidade-possibilita-representacao-e-alternancia-de-perfis-na-nfs-e
- Microsoft EphemeralKeySet: https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.x509certificates.x509keystorageflags?view=netframework-4.8.1

Na pesquisa anterior, o Swagger retornou 502/503 e o download direto do XSD retornou 403. Isso não comprova indisponibilidade geral. Ainda não houve conexão autenticada com o certificado do escritório, instalação dos novos XSD, assinatura ou envio de DPS.

## Verificação

37 testes backend passaram, incluindo bloqueio de upload e download restrito do pacote. Os testes Windows usam apenas certificados autogerados e verificam parser PowerShell, validade, presença da chave, senha incorreta, importação efêmera, redirects e construção da interface. O workflow `.github/workflows/local-connector.yml` executa no Windows; seu resultado deve ser conferido antes de declarar a compatibilidade verificada. A estação de desenvolvimento é Linux.

## Continuação

Confirmar diagnóstico no PC do escritório; obter contrato OpenAPI e XSD atuais; validar credenciamento/representação e município do primeiro emitente; implementar assinatura e consultas no conector; só depois parear com o site por token de dispositivo revogável e fila com aprovação específica de homologação. Timeout fiscal exige consulta antes de reenvio. Emissão em produção requer outra autorização expressa.
