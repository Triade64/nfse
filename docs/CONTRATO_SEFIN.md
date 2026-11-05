# Contrato SEFIN recebido em 05/11/2026

Arquivo Swagger 2.0 fornecido pelo usuário a partir do botão Download da documentação oficial em produção restrita. Cópia original: `official/sefin-restricted-v1.swagger.json` (14303 bytes), SHA-256 `a2fae14f273f0966e7ff68a6a79f3df38286162206f76668e53416a39dfdfc1c`.

## Confirmado no arquivo

- Host: `sefin.producaorestrita.nfse.gov.br`; basePath: `/SefinNacional`.
- `schemes` contém somente `http`, mas a descrição exige TLS com autenticação mútua. O conector usa exclusivamente HTTPS com validação do servidor; não segue o esquema inseguro do metadado e não tenta URLs alternativas.
- `POST /nfse` recebe objeto JSON com campo obrigatório `dpsXmlGZipB64`. Sucesso documentado: 201 com `tipoAmbiente`, `idDps`, `chaveAcesso`, `nfseXmlGZipB64` e demais metadados. HTTP 400/403/500 são documentados.
- `GET /dps/{id}` e `HEAD /dps/{id}` estão descritos. A descrição do HEAD prevê 400 para identificador inválido, 404 para não encontrado e 200 para encontrado.
- `GET /nfse/{chaveAcesso}` exige chave com 50 números e devolve XML GZip/Base64; pode negar acesso por certificado/permissão.
- DANFSe e parâmetros municipais nesta SEFIN estão marcados como movidos para documentação própria do ADN. Não implementar emissão nesses endpoints antigos.
- Ausência de `securityDefinitions` não significa acesso anônimo: o texto exige certificado ICP-Brasil de cliente.

## Implementado nesta etapa

`backend/app/fiscal_codec.py` implementa somente o envelope GZip/Base64 e sua leitura com limites de tamanho. Não gera, valida ou assina DPS e não contém transporte HTTP. Os testes conferem o nome do campo com o Swagger recebido e bloqueiam conteúdos inválidos/excessivos.

O conector local 0.6 acrescenta um diagnóstico explícito, confirmado pelo operador: HEAD para `https://sefin.producaorestrita.nfse.gov.br/SefinNacional/dps/diagnostico-local`. O identificador é deliberadamente inválido e não corresponde a uma DPS real. A consulta não tem corpo, não faz POST e não gera documento. HTTP 400 seria compatível com a rejeição prevista do identificador; não comprova autorização de emissão. HTTP 404 é ambíguo entre rota e identificador e não é tratado como sucesso. 401/403 indicam recusa de acesso. Não há retry ou redirecionamento.

A exportação também passa a reconhecer referências ReDoc, conforme o screenshot recebido. A navegação continua limitada às referências de documentação observadas no host de homologação, sem executar JavaScript.

## Pendente

Ainda precisamos do pacote XSD específico de produção restrita para validar o XML antes de implementar geração/assinatura e envio. Não houve consulta autenticada dessa rota com o certificado real na estação de desenvolvimento, nem envio de DPS. O certificado continua no PC do escritório. Nenhum dado fiscal de cadastro ou documento real foi alterado.
