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
