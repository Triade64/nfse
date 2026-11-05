#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
foreach($name in @('ConectorTriade.ps1','TriadeConnector.Core.psm1','TriadeDps.psm1','TriadeRestricted.psm1','TriadeSite.psm1','tests/Test-Restricted.ps1','tests/Test-Site.ps1','tests/Test-Timezone.ps1','tests/Test-Im.ps1')) {
    $tokens=$null;$errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $name),[ref]$tokens,[ref]$errors)
    if ($errors.Count -ne 0) { throw ('Falha no parser PowerShell: '+$name) }
}
Import-Module (Join-Path $root 'TriadeConnector.Core.psm1') -Force
Import-Module (Join-Path $root 'TriadeDps.psm1') -Force
# Exercise the same read-only store routine as the button; do not install any certificate.
$installed=Get-TriadeWindowsCertificates
if ($installed -isnot [Security.Cryptography.X509Certificates.X509Certificate2Collection]) { throw 'Colecao de certificados invalida.' }
foreach($item in $installed) { $item.Dispose() }
if ($null -eq [Security.Cryptography.X509Certificates.X509Certificate2UI]) { throw 'Assembly do seletor ausente.' }

$key=[Security.Cryptography.RSACng]::new(2048)
$cert=$null;$expired=$null;$public=$null;$imported=$null;$handler=$null;$password=$null
$directory=Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
$null=New-Item -ItemType Directory -Path $directory
try {
    $req=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=FICTICIO-SEM-VALIDADE-ICP',$key,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    # Synthetic SAN otherName 2.16.76.1.3.3, never a real taxpayer/certificate.
    $san=[byte[]](0x30,0x1B,0xA0,0x19,0x06,0x05,0x60,0x4C,0x01,0x03,0x03,0xA0,0x10,0x0C,0x0E)+[Text.Encoding]::ASCII.GetBytes('11222333000181')
    $req.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509Extension]::new('2.5.29.17',$san,$false))
    $now=[DateTimeOffset]::UtcNow
    $cert=$req.CreateSelfSigned($now.AddDays(-1),$now.AddDays(2))
    $result=Get-TriadeCertificateCheck -Certificate $cert
    if (-not $result.offline_ok -or $result.issuance_enabled) { throw 'Diagnostico incorreto.' }
    if (($result|ConvertTo-Json) -match 'FICTICIO|PRIVATE KEY') { throw 'Identidade ou chave exposta no resultado.' }
    $expired=$req.CreateSelfSigned($now.AddDays(-3),$now.AddDays(-2))
    $blocked=$false;try { $null=Get-TriadeCertificateCheck -Certificate $expired } catch { $blocked=$true }
    if (-not $blocked) { throw 'Certificado expirado nao bloqueado.' }
    $public=[Security.Cryptography.X509Certificates.X509Certificate2]::new($cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    $blocked=$false;try { $null=Get-TriadeCertificateCheck -Certificate $public } catch { $blocked=$true }
    if (-not $blocked) { throw 'Certificado sem chave privada nao bloqueado.' }
    $handler=New-TriadeRestrictedHandler -Certificate $cert
    if ($handler.AllowAutoRedirect -or $handler.ClientCertificates.Count -ne 1) { throw 'Politica TLS/redirect incorreta.' }
    $password=ConvertTo-SecureString 'APENAS-TESTE-FICTICIO-123' -AsPlainText -Force
    $path=Join-Path $directory 'ficticio.pfx'
    [IO.File]::WriteAllBytes($path,$cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx,'APENAS-TESTE-FICTICIO-123'))
    $imported=Import-TriadeLocalA1 -Path $path -Password $password
    if (-not $imported.HasPrivateKey) { throw 'A1 sintetico nao abriu.' }
    $bad=ConvertTo-SecureString 'ERRADA' -AsPlainText -Force
    try {
        $blocked=$false;try { $null=Import-TriadeLocalA1 -Path $path -Password $bad } catch { $blocked=$true }
        if (-not $blocked) { throw 'Senha errada nao bloqueada.' }
    } finally { $bad.Dispose() }
    $native=[ComponentModel.Win32Exception]::new([Convert]::ToInt32('8009030E',16),'SEGREDO-FICTICIO-NAO-MOSTRAR')
    $outer=[Net.Http.HttpRequestException]::new('CAMINHO-FICTICIO-NAO-MOSTRAR',$native)
    $failure=Get-TriadeConnectionFailure -Exception $outer
    if ($failure.category -ne 'credentials' -or $failure.codes -notmatch '8009030E') { throw 'Codigo Schannel nao classificado.' }
    if (($failure|ConvertTo-Json) -match 'SEGREDO|CAMINHO') { throw 'Mensagem interna exposta.' }
    $trust=Get-TriadeConnectionFailure -Exception ([ComponentModel.Win32Exception]::new([Convert]::ToInt32('80090325',16)))
    if ($trust.category -ne 'trust') { throw 'Confianca nao classificada.' }
    $timeout=Get-TriadeConnectionFailure -Exception ([Threading.Tasks.TaskCanceledException]::new())
    if ($timeout.category -ne 'timeout') { throw 'Timeout nao classificado.' }
    $socket=Get-TriadeConnectionFailure -Exception ([Net.Sockets.SocketException]::new(11001))
    if ($socket.category -ne 'network') { throw 'Rede nao classificada.' }
    $base=[Uri]'https://sefin.producaorestrita.nfse.gov.br/API/SefinNacional/docs/index'
    $html='var configObject = JSON.parse(''{"urls":[{"url":"../swagger/v1/swagger.json","name":"v1"}]}'');'
    $references=@(Find-TriadeOpenApiReferences -Text $html -BaseUri $base)
    if ($references.Count -ne 1 -or $references[0] -ne 'https://sefin.producaorestrita.nfse.gov.br/API/SefinNacional/swagger/v1/swagger.json') { throw 'Referencia observada nao resolvida.' }
    $redoc='<redoc spec-url="https://sefin.producaorestrita.nfse.gov.br/SefinNacional/docs/v1"></redoc>'
    $redocRefs=@(Find-TriadeOpenApiReferences -Text $redoc -BaseUri $base)
    if ($redocRefs.Count -ne 1 -or $redocRefs[0] -ne 'https://sefin.producaorestrita.nfse.gov.br/SefinNacional/docs/v1') { throw 'Referencia ReDoc nao resolvida.' }
    $legacy="rootUrl: 'https://sefin.producaorestrita.nfse.gov.br/API/SefinNacional', discoveryPaths: arrayFrom('swagger/docs/v1')"
    $legacyRefs=@(Find-TriadeOpenApiReferences -Text $legacy -BaseUri $base)
    if ($legacyRefs.Count -ne 1 -or $legacyRefs[0] -ne 'https://sefin.producaorestrita.nfse.gov.br/API/SefinNacional/swagger/docs/v1') { throw 'Referencia Swagger legada nao resolvida.' }
    foreach($reference in @('https://sefin.nfse.gov.br/swagger.json','https://example.com/openapi.json','/API/SefinNacional/nfse/123','/API/SefinNacional/swagger.json?token=ficticio','http://sefin.producaorestrita.nfse.gov.br/API/SefinNacional/swagger.json')) {
        if ($null -ne (Resolve-TriadeDocumentationReference -BaseUri $base -Reference $reference -Kind json)) { throw 'Referencia indevida aceita.' }
    }
    $noRef=[Exception]::new('Não foi encontrada uma referência OpenAPI na página. Abra o Swagger no navegador e salve o JSON indicado nele; nenhuma URL foi deduzida.')
    $reason=Get-TriadeDocumentationFailure -Exception ([Exception]::new('SEGREDO-FICTICIO',$noRef))
    if ($reason.code -ne 'NO_REFERENCE' -or ($reason|ConvertTo-Json) -match 'SEGREDO') { throw 'Mensagem publica de exportacao incorreta.' }
    $unknown=Get-TriadeDocumentationFailure -Exception ([Exception]::new('SEGREDO-FICTICIO'))
    if ($unknown.code -ne 'UNCLASSIFIED' -or ($unknown|ConvertTo-Json) -match 'SEGREDO') { throw 'Mensagem interna foi exposta.' }
    $apiRequest=New-TriadeRestrictedApiProbeRequest
    try {
        if ($apiRequest.Method.Method -ne 'HEAD' -or $apiRequest.RequestUri.AbsoluteUri -ne 'https://sefin.producaorestrita.nfse.gov.br/SefinNacional/dps/diagnostico-local' -or $null -ne $apiRequest.Content) { throw 'Diagnostico API nao esta restrito ao HEAD sem corpo.' }
    } finally { $apiRequest.Dispose() }
    $schemaDirectory=Join-Path (Split-Path -Parent $root) 'schemas/restricted-20261020'
    $unsigned=[IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'dps-ficticia.xml'))
    $signedBytes=Protect-TriadeOfflineDps -Bytes $unsigned -Certificate $cert -SchemaDirectory $schemaDirectory -OwnCnpj '11222333000181'
    $signedXml=Read-TriadeDps -Bytes $signedBytes -SchemaDirectory $schemaDirectory
    $verifier=[Security.Cryptography.Xml.SignedXml]::new($signedXml)
    $verifier.LoadXml($signedXml.GetElementsByTagName('Signature','http://www.w3.org/2000/09/xmldsig#')[0])
    if(-not $verifier.CheckSignature($cert,$true)){throw 'Assinatura local invalida.'}
    if($signedXml.GetElementsByTagName('X509Certificate','http://www.w3.org/2000/09/xmldsig#').Count -ne 1){throw 'Certificado publico ausente.'}
    $signedXml.GetElementsByTagName('vServ','http://www.sped.fazenda.gov.br/nfse')[0].InnerText='999.99'
    $tampered=[Security.Cryptography.Xml.SignedXml]::new($signedXml)
    $tampered.LoadXml($signedXml.GetElementsByTagName('Signature','http://www.w3.org/2000/09/xmldsig#')[0])
    if($tampered.CheckSignature($cert,$true)){throw 'Alteracao de valor nao detectada.'}
    foreach($cnpj in @('00000000000000','11222333000182')){
        $blocked=$false;try{$null=Protect-TriadeOfflineDps -Bytes $unsigned -Certificate $cert -SchemaDirectory $schemaDirectory -OwnCnpj $cnpj}catch{$blocked=$true}
        if(-not $blocked){throw 'Divergencia de emitente nao bloqueada.'}
    }
    foreach($text in @(([Text.Encoding]::UTF8.GetString($unsigned)).Replace('<tpAmb>2</tpAmb>','<tpAmb>1</tpAmb>'), '<!DOCTYPE DPS [<!ENTITY bad SYSTEM "file:///secret">]><DPS>&bad;</DPS>')){
        $blocked=$false;try{$null=Read-TriadeDps -Bytes ([Text.Encoding]::UTF8.GetBytes($text)) -SchemaDirectory $schemaDirectory}catch{$blocked=$true}
        if(-not $blocked){throw 'XML de producao ou DTD nao bloqueado.'}
    }
    $blocked=$false;try{$null=Protect-TriadeOfflineDps -Bytes $signedBytes -Certificate $cert -SchemaDirectory $schemaDirectory -OwnCnpj '11222333000181'}catch{$blocked=$true}
    if(-not $blocked){throw 'Segunda assinatura nao bloqueada.'}
    & (Join-Path $PSScriptRoot 'Test-Restricted.ps1') -Certificate $cert -SignedBytes $signedBytes -SchemaDirectory $schemaDirectory -Directory $directory
    & (Join-Path $root 'ConectorTriade.ps1') -SelfTest
    Write-Output 'PASS: XSD restrito, XMLDSIG, integridade, bloqueio de CNPJ divergente, producao, DTD e segunda assinatura. Sem rede.'
    Write-Output 'PASS: parser Windows PowerShell, validade, chave privada, importacao efemera, senha incorreta e handler sem redirects. Sem rede ou certificados reais.'
} finally {
    foreach($object in @($handler,$imported,$public,$expired,$cert,$key,$password)) { if ($null -ne $object) { $object.Dispose() } }
    Remove-Item -LiteralPath $directory -Recurse -Force
}
