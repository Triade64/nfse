# Teste unitário SEFIN Nacional — conector 0.8

A versão 0.8 acrescenta somente o teste de uma DPS assinada do próprio escritório, em um PC. Não integra fila do site, não atualiza os rascunhos e não libera produção real. O XML já assinado na 0.7 pode ser reutilizado.

## Contrato usado

OpenAPI original fornecido pelo usuário em `docs/official/sefin-restricted-v1.swagger.json`. HTTPS fixo em `sefin.producaorestrita.nfse.gov.br/SefinNacional`; o campo `schemes:[http]` do Swagger não é utilizado. Somente GET `/dps/{id}`, POST `/nfse` com `dpsXmlGZipB64`, e GET `/nfse/{chaveAcesso}`. Nenhuma operação de eventos, cancelamento, bypass judicial ou produção real.

## Operação

- Confirmar o XML assinado e certificado instalado no Windows. Verificar XSD, integridade, perfil de assinatura conhecido, CNPJ exato do prestador e ambiente 2 antes de acessar a API.
- Consultar o identificador antes do POST. Somente HTTP 404 com JSON de erro do ambiente 2 permite continuar, se não houver tentativa anterior registrada.
- Persistir o XML exato e estado em `%LOCALAPPDATA%\TriadeNfse\Conector\producao-restrita\<IdDPS>`. Lock por identificador impede duas execuções concorrentes neste PC. Gravação temporária com flush em disco e substituição atômica.
- Gravar `attempted=true` antes de iniciar o POST. Esse marcador não é revertido, mesmo em timeout, erro de persistência, HTTP inesperado ou rejeição.
- 201: conferir ambiente, identificador, chave e XML retornado. Conferir XSD da NFS-e e correspondência de CNPJ, competência e valor. Preservar bytes originais, JSON e hash. Não é verificada criptograficamente a assinatura do governo no XML retornado; a origem é autenticada pelo HTTPS normal do Windows.
- 400/403 estruturados com erros: rejeição registrada, códigos seguros no diagnóstico. Mensagens detalhadas e documentos ficam no disco local.
- Outros retornos, JSON/XML inválido, timeout e falhas de arquivo: resultado desconhecido; nunca reenviar automaticamente.
- Consultar resultado: só GET. Se a DPS for localizada, recuperar XML por chave. Um 404 após tentativa não libera novo POST. Ajustes e eventual nova tentativa precisam de revisão técnica, sem apagar o histórico.

O marcador é local e não constitui coordenação entre PCs ou reserva de numeração no PostgreSQL. Não usar outro computador para repetir um teste. A integração central, controle de sequência e reconciliação entre usuários são requisitos anteriores a lotes.

## Certificado e privacidade

O certificado A1/PFX, senha e chave privada não são enviados ao site. O certificado público e a assinatura constam do XML enviado ao governo; o certificado público também é apresentado no TLS. O diretório local contém dados fiscais e deve ser protegido e incluído no backup. O diagnóstico copiável não inclui CNPJ, nomes, XML, chave de acesso ou caminhos completos. Não desativa TLS, cadeia do servidor ou política corporativa do Windows.

Cadeia ICP-Brasil/revogação do certificado cliente não são verificadas localmente; o servidor oficial fará suas validações. Credenciamento e regras fiscais continuam sujeitos ao retorno da API. O gerador inicial não cobre grupos condicionais como IBS/CBS; se exigidos, o teste poderá ser rejeitado e o gerador precisará ser ampliado. Não alterar enquadramentos para contornar rejeições.

## Testes

Transporte injetado por HttpClient/HttpMessageHandler em CI Windows, com certificados e respostas fictícios. Casos: ausência de confirmação só consulta, marcador gravado antes do POST, sucesso, rejeição, timeout e recuperação posterior, 500, 201 incompleto, ambiente incorreto, 404 HTML, redirect, consulta de DPS existente, bloqueio de concorrência e alteração do XML, envelope preservando bytes e GZip excessivo. Nenhuma chamada fiscal real nos testes automatizados.

Os testes simulados não confirmam aceitação real pela SEFIN. A validação real depende da confirmação do operador no PC com o certificado do escritório. A confirmação padrão da janela de envio é Não.

Também substitui o verbo não aprovado `Sign` por `Protect` no módulo, removendo o aviso de importação relatado pelo usuário.


## Atualização 0.8.1 — diagnóstico preservando o histórico

Após o operador informar falha genérica com estado Novo, acrescentados etapa de falha, último HTTP recebido, motivo conhecido, categoria, tipos e códigos numéricos seguros. Exceções durante a leitura do corpo preservam o HTTP recebido nos metadados da exceção, sem copiar sua mensagem.

A atualização não muda contrato fiscal, regras de reenvio, destino ou formato do journal. O operador deve usar somente Consultar resultado com o mesmo XML e certificado; a causa da falha informada ainda depende desse diagnóstico no PC. Testes sintéticos cobrem timeout antes/depois do POST, HTTP 404 vazio, corpo UTF-8 inválido, falha de gravação e ausência de mensagens internas/caminhos privados no diagnóstico.


## Atualização 0.8.2 — existência por HEAD

Operador confirmou tipoAmbiente System.Int32=0 na resposta HTTP 404 de GET. Não é aceito como ambiente de homologação. A consulta prévia passa a HEAD /dps/{id}, cujo contrato documenta 200/400/404 sem JSON. HEAD 404 e ausência de tentativa anterior permitem POST somente com confirmação explícita; HEAD 200 leva a GET para recuperar chave/documento sem POST. GET de sucesso e resposta de autorização mantêm validação estrita de ambiente=2. Destino, journal e bloqueio de reenvio permanecem os mesmos. Teste inicial solicitado ao operador: somente consulta.


## Atualização 0.8.3 — fuso explícito e revisão controlada

Caso informado pelo operador: dhEmi 2026-11-05T13:03:00+00:00, processamento 2026-11-05T10:56:16.5796177-03:00, E0008. Normalizando os fusos, a emissão era 10:03-03:00, anterior ao processamento. Portanto os horários não demonstram emissão futura. A hipótese de interpretação do fuso pelo servidor permanece pendente de teste.

Frontend usa entrada explícita Brasília, independente do fuso do navegador; backend normaliza ao offset -03:00 e recusa instante futuro. O conector pode verificar assinatura existente, normalizar apenas dhEmi ao mesmo instante e assinar um novo arquivo. Competência, numeração e todos os campos fiscais são mantidos.

Uma revisão de envio exige: original com hash íntegro e assinatura correspondente ao certificado; status Rejeitada em teste; resposta ambiente 2 com exclusivamente E0008; novo XML com assinatura válida; mesmo IdDPS e instante UTC; conteúdo XML canônico idêntico depois de normalizar dhEmi e remover as assinaturas; confirmação específica do operador; HEAD 404 antes do registro. A verificação de conteúdo inclui todos os demais elementos, valores e atributos.

Original estado.json, dps-assinada.xml e resposta-envio.json permanecem intactos. Registro correcao-fuso.json vincula somente um hash revisado; tentativa revisada usa journal separado sob ajuste-fuso/IdDPS. Nunca se zera attempted da tentativa anterior. O journal da revisão mantém todas as proteções contra reenvio e resultado desconhecido. Após registro, consultas do XML revisado são roteadas ao journal revisado.

CI usa retorno de rejeição e transporte fictícios; cobre equivalência do instante, consentimento específico, preservação byte a byte do histórico original, recuperação/limite de tentativa, campos fiscais alterados, outro código de erro, HEAD encontrando documento e timeout da revisão. Nenhum teste fiscal real foi executado pelo agente.


## Atualização 0.8.4 — omissão de IM após E0120

Mensagem da API fornecida pelo operador: IM do prestador não deve ser informada porque não existem informações complementares no CNC do município emissor. O XML enviado continha prest/IM. Não foi alterado o cadastro da empresa.

Gerador exige escolha explícita de inclusão/omissão da IM. Conector verifica assinatura e gera nova cópia removendo somente prest/IM, com o mesmo horário, IdDPS e demais campos. Envio da revisão exige rejeição E0120 isolada, ambiente 2, confirmação específica, comparação canônica de todos os campos restantes e HEAD 404. Revisões anteriores são encaminhadas por seus registros de hashes antes de comparar a nova cópia, suportando E0008 -> E0120 sem afrouxar a verificação de campos.

Registros correcao-im.json/ajuste-im são separados dos originais, sem reset de attempted, remoção de arquivos ou atualização de dados reais no banco. A configuração de uma empresa não é inferida para outras. Testes cobrem omissão no gerador sem mutação cadastral, assinatura nova, confirmação, cadeia E0008/E0120, preservação byte a byte dos históricos, alterações indevidas, DPS existente e timeout sem reenvio.
