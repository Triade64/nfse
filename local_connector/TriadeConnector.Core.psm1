#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Security

function Get-TriadeWindowsCertificates {
    $store=[Security.Cryptography.X509Certificates.X509Store]::new([Security.Cryptography.X509Certificates.StoreName]::My,[Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    $available=[Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
    try {
        $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
        foreach($certificate in $store.Certificates) {
            if ($certificate.HasPrivateKey) { [void]$available.Add($certificate) } else { $certificate.Dispose() }
        }
        return ,$available
    } catch {
        foreach($certificate in $available) { $certificate.Dispose() }
        throw
    } finally { $store.Close();$store.Dispose() }
}

function Import-TriadeLocalA1 {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][Security.SecureString]$Password)
    $info = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($info.Length -gt 262144) { throw 'Arquivo A1 maior que 256 KB.' }
    if (-not [Enum]::GetNames([Security.Cryptography.X509Certificates.X509KeyStorageFlags]).Contains('EphemeralKeySet')) {
        throw 'Atualize o Windows/.NET para usar A1 temporário, ou selecione um certificado já instalado no Windows.'
    }
    $bytes = [IO.File]::ReadAllBytes($info.FullName)
    try {
        # No Exportable, PersistKeySet, installation or private-key export.
        return [Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes,$Password,[Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
    } catch { throw 'Não foi possível abrir o A1. Confira o arquivo, a senha e a versão do Windows/.NET.' }
    finally { if ($null -ne $bytes) { [Array]::Clear($bytes,0,$bytes.Length) } }
}

function Get-TriadeCertificateCheck {
    param([Parameter(Mandatory=$true)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    $now = [DateTime]::UtcNow
    if (-not $Certificate.HasPrivateKey) { throw 'O certificado selecionado não tem chave privada acessível.' }
    if ($Certificate.NotBefore.ToUniversalTime() -gt $now -or $Certificate.NotAfter.ToUniversalTime() -lt $now) { throw 'Certificado fora do período de validade.' }
    $eku = $Certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' } | Select-Object -First 1
    if ($null -ne $eku) {
        $client = @($eku.EnhancedKeyUsages | Where-Object { $_.Value -eq '1.3.6.1.5.5.7.3.2' -or $_.Value -eq '2.5.29.37.0' })
        if ($client.Count -eq 0) { throw 'O certificado não declara Autenticação do Cliente.' }
    }
    return [PSCustomObject]@{ offline_ok=$true; expires_on=$Certificate.NotAfter.ToUniversalTime().ToString('yyyy-MM-dd'); issuance_enabled=$false }
}

function New-TriadeRestrictedHandler {
    param([Parameter(Mandatory=$true)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.ClientCertificateOptions = [Net.Http.ClientCertificateOption]::Manual
    if ($null -ne $handler.PSObject.Properties['SslProtocols']) { $handler.SslProtocols = [Security.Authentication.SslProtocols]::Tls12 }
    [void]$handler.ClientCertificates.Add($Certificate)
    # No validation callback: Windows checks server CA and hostname.
    return $handler
}

function Format-TriadeNumericCode {
    param([int]$Code)
    return '0x'+[BitConverter]::ToUInt32([BitConverter]::GetBytes($Code),0).ToString('X8')
}

function Get-TriadeConnectionFailure {
    param([Parameter(Mandatory=$true)][Exception]$Exception)
    $codes=@();$types=@();$networkStatus=@();$current=$Exception
    for($i=0;$null -ne $current -and $i -lt 8;$i++) {
        $codes+=Format-TriadeNumericCode -Code $current.HResult
        $types+=$current.GetType().Name
        if ($current -is [ComponentModel.Win32Exception]) { $codes+=Format-TriadeNumericCode -Code $current.NativeErrorCode }
        if ($current -is [Net.WebException]) { $networkStatus+=$current.Status.ToString() }
        if ($current -is [Net.Sockets.SocketException]) { $networkStatus+=$current.SocketErrorCode.ToString() }
        $current=$current.InnerException
    }
    $category='unknown';$message='Conexão não concluída. O código técnico abaixo permite investigar sem compartilhar certificado ou senha.'
    if ($codes -contains '0x8009030E' -or $codes -contains '0x8009030D') {
        $category='credentials';$message='O Windows não disponibilizou a credencial para TLS. Se a origem for arquivo A1 temporário, tente Selecionar certificado do Windows. O código não comprova sozinho a causa.'
    } elseif ($codes -contains '0x80090325' -or $codes -contains '0x800B0109') {
        $category='trust';$message='Falha de confiança na cadeia de certificados da conexão. Confira o Windows e a rede com a TI. Não desative a validação TLS.'
    } elseif ($codes -contains '0x80090322' -or $codes -contains '0x800B010F') {
        $category='hostname';$message='O nome do servidor não corresponde ao certificado apresentado na conexão. Confira a rede/proxy com a TI.'
    } elseif ($codes -contains '0x80090328' -or $codes -contains '0x800B0101') {
        $category='tls_validity';$message='Certificado da conexão fora da validade ou relógio do Windows incorreto. Isso pode envolver uma cadeia diferente do A1 verificado localmente.'
    } elseif ($types -contains 'TaskCanceledException' -or $types -contains 'OperationCanceledException' -or $networkStatus -contains 'Timeout') {
        $category='timeout';$message='O tempo limite da conexão foi atingido. Confira a rede e tente novamente mais tarde.'
    } elseif ($types -contains 'SocketException' -or $networkStatus -contains 'NameResolutionFailure' -or $networkStatus -contains 'ProxyNameResolutionFailure' -or $networkStatus -contains 'ConnectFailure') {
        $category='network';$message='Falha de rede, DNS, proxy ou conexão ao servidor. Confira a conectividade do PC.'
    } elseif ($types -contains 'AuthenticationException' -or $networkStatus -contains 'TrustFailure' -or $networkStatus -contains 'SecureChannelFailure' -or $codes -contains '0x80090326' -or $codes -contains '0x80090331') {
        $category='tls';$message='A negociação TLS falhou. O código técnico ajuda a verificar certificado, cadeia e protocolos, sem desativar as verificações de segurança.'
    }
    return [PSCustomObject]@{ category=$category; codes=(@($codes|Select-Object -Unique) -join ', '); types=($types -join ' > '); message=$message }
}

function Resolve-TriadeDocumentationReference {
    param([Uri]$BaseUri,[string]$Reference,[ValidateSet('json','script')][string]$Kind)
    try {
        $uri=[Uri]::new($BaseUri,$Reference.Replace('\/','/'))
        if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'sefin.producaorestrita.nfse.gov.br' -or $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { return $null }
        $path=[Uri]::UnescapeDataString($uri.AbsolutePath)
        if ($path -notmatch '^/(API/)?SefinNacional/' -or $path.Contains('..') -or $path.Contains('\')) { return $null }
        if ($Kind -eq 'json' -and ($path -match '(?i)(swagger|openapi)[^?]*\.json$' -or $path -match '(?i)^/(API/)?SefinNacional/(swagger|docs)/(docs/)?v[0-9][A-Za-z0-9._-]*(/swagger)?$')) { return $uri }
        if ($Kind -eq 'script' -and $path -match '(?i)/(swagger-ui-init|swagger-initializer)\.js$') { return $uri }
    } catch { }
    return $null
}

function Find-TriadeOpenApiReferences {
    param([string]$Text,[Uri]$BaseUri)
    # Data extraction only. Never execute JavaScript from the government page.
    $normalized=$Text.Replace('\"','"').Replace('\/','/')
    $found=@()
    foreach($match in [Regex]::Matches($normalized,'(?i)(?:["'']?url["'']?)\s*:\s*["''](?<url>[^"''\r\n]+)["'']')) {
        $uri=Resolve-TriadeDocumentationReference -BaseUri $BaseUri -Reference $match.Groups['url'].Value -Kind json
        if ($null -ne $uri -and $found -notcontains $uri.AbsoluteUri) { $found+=$uri.AbsoluteUri }
    }
    # ReDoc uses spec-url or a literal Redoc.init() URL, as observed in the supplied screenshot.
    foreach($pattern in @('(?i)\bspec-url\s*=\s*["''](?<url>[^"''\r\n]+)["'']','(?i)\bRedoc\.init\(\s*["''](?<url>[^"''\r\n]+)["'']')) {
        foreach($match in [Regex]::Matches($normalized,$pattern)) {
            $uri=Resolve-TriadeDocumentationReference -BaseUri $BaseUri -Reference $match.Groups['url'].Value -Kind json
            if ($null -ne $uri -and $found -notcontains $uri.AbsoluteUri) { $found+=$uri.AbsoluteUri }
        }
    }
    # Older Swashbuckle pages declare rootUrl and discoveryPaths explicitly.
    $rootMatch=[Regex]::Match($normalized,'(?i)\brootUrl\s*:\s*["''](?<root>[^"''\r\n]+)["'']')
    $pathsMatch=[Regex]::Match($normalized,'(?is)\bdiscoveryPaths\s*:\s*(?:arrayFrom|JSON\.parse)\(\s*(?<q>["''])(?<paths>.*?)\k<q>\s*\)')
    if ($rootMatch.Success -and $pathsMatch.Success) {
        try {
            $root=[Uri]::new($BaseUri,$rootMatch.Groups['root'].Value)
            if ($root.Scheme -eq 'https' -and $root.Host -eq 'sefin.producaorestrita.nfse.gov.br' -and $root.Port -eq 443 -and -not $root.Query -and -not $root.Fragment -and -not $root.UserInfo -and $root.AbsolutePath.TrimEnd('/') -eq '/API/SefinNacional') {
                $rawPaths=$pathsMatch.Groups['paths'].Value
                if ($rawPaths.TrimStart().StartsWith('[')) { $paths=@($rawPaths|ConvertFrom-Json) } else { $paths=@($rawPaths.Split('|')) }
                foreach($path in $paths) {
                    if ($path -isnot [string]) { continue }
                    $uri=Resolve-TriadeDocumentationReference -BaseUri ([Uri]($root.AbsoluteUri.TrimEnd('/')+'/')) -Reference $path -Kind json
                    if ($null -ne $uri -and $found -notcontains $uri.AbsoluteUri) { $found+=$uri.AbsoluteUri }
                }
            }
        } catch { }
    }
    return $found
}

function Read-TriadeDocumentationText {
    param([Net.Http.HttpClient]$Client,[Uri]$Uri)
    $response=$null;$stream=$null;$buffer=[IO.MemoryStream]::new()
    try {
        $response=$Client.GetAsync($Uri,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if ([int]$response.StatusCode -ne 200) { throw 'A documentação não retornou HTTP 200. Nenhum redirecionamento foi seguido.' }
        $stream=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult();$chunk=New-Object byte[] 8192
        while (($read=$stream.Read($chunk,0,$chunk.Length)) -gt 0) {
            if ($buffer.Length+$read -gt 2097152) { throw 'A documentação excedeu o limite de 2 MB.' }
            $buffer.Write($chunk,0,$read)
        }
        return [Text.Encoding]::UTF8.GetString($buffer.ToArray())
    } finally {
        if ($null -ne $stream) { $stream.Dispose() };$buffer.Dispose();if ($null -ne $response) { $response.Dispose() }
    }
}

function Get-TriadeDocumentationFailure {
    param([Parameter(Mandatory=$true)][Exception]$Exception)
    # Only exact messages authored by this program are allowed into the report.
    $reasons=@{
        'Não foi encontrada uma referência OpenAPI na página. Abra o Swagger no navegador e salve o JSON indicado nele; nenhuma URL foi deduzida.'=@('NO_REFERENCE','A página respondeu, mas o conector não localizou uma referência OpenAPI permitida. Abra o Swagger no navegador para conferir o endereço do JSON.')
        'A referência foi encontrada, mas o JSON OpenAPI não pôde ser validado ou baixado. Não houve envio de DPS.'=@('CONTRACT_DOWNLOAD_OR_FORMAT','Uma referência foi localizada, mas o documento não pôde ser baixado ou reconhecido como OpenAPI.')
        'A documentação não retornou HTTP 200. Nenhum redirecionamento foi seguido.'=@('HTTP_STATUS','A documentação não retornou HTTP 200. Redirecionamentos continuam bloqueados.')
        'A documentação excedeu o limite de 2 MB.'=@('SIZE_LIMIT','O documento ultrapassou o limite de 2 MB.')
        'O conteúdo recebido não é um contrato OpenAPI reconhecido.'=@('NOT_OPENAPI','O conteúdo recebido não foi reconhecido como OpenAPI.')
        'Documentação não encontrada.'=@('NO_DOCUMENT','A documentação não foi localizada.')
    }
    $current=$Exception
    for($i=0;$null -ne $current -and $i -lt 8;$i++) {
        if ($reasons.ContainsKey($current.Message)) {
            $reason=$reasons[$current.Message]
            return [PSCustomObject]@{ code=$reason[0]; message=$reason[1] }
        }
        if ($current -is [UnauthorizedAccessException] -or $current -is [IO.IOException]) {
            return [PSCustomObject]@{ code='FILE_ACCESS'; message='Não foi possível acessar o arquivo local. Tente salvar em Documentos.' }
        }
        $current=$current.InnerException
    }
    return [PSCustomObject]@{ code='UNCLASSIFIED'; message='Falha não classificada. Compartilhe somente os tipos e códigos técnicos do diagnóstico.' }
}

function Get-TriadeRestrictedOpenApi {
    param([Parameter(Mandatory=$true)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    $null=Get-TriadeCertificateCheck -Certificate $Certificate
    $handler=New-TriadeRestrictedHandler -Certificate $Certificate
    $client=[Net.Http.HttpClient]::new($handler);$client.Timeout=[TimeSpan]::FromSeconds(15)
    $index=[Uri]'https://sefin.producaorestrita.nfse.gov.br/API/SefinNacional/docs/index'
    try {
        $html=Read-TriadeDocumentationText -Client $client -Uri $index
        $candidates=@(Find-TriadeOpenApiReferences -Text $html -BaseUri $index)
        $scriptCount=0
        if ($candidates.Count -eq 0) {
            foreach($match in [Regex]::Matches($html,'(?i)<script[^>]+src=["''](?<url>[^"'']+)["'']')) {
                $scriptUri=Resolve-TriadeDocumentationReference -BaseUri $index -Reference $match.Groups['url'].Value -Kind script
                if ($null -eq $scriptUri) { continue }
                if ($scriptCount -ge 2) { break };$scriptCount++
                $scriptText=Read-TriadeDocumentationText -Client $client -Uri $scriptUri
                $candidates+=@(Find-TriadeOpenApiReferences -Text $scriptText -BaseUri $scriptUri)
            }
        }
        if ($candidates.Count -eq 0) { throw 'Não foi encontrada uma referência OpenAPI na página. Abra o Swagger no navegador e salve o JSON indicado nele; nenhuma URL foi deduzida.' }
        $lastError=$null
        foreach($candidate in @($candidates|Select-Object -Unique|Select-Object -First 4)) {
            try {
                $text=Read-TriadeDocumentationText -Client $client -Uri ([Uri]$candidate)
                $document=$text|ConvertFrom-Json
                if (($null -eq $document.PSObject.Properties['openapi'] -and $null -eq $document.PSObject.Properties['swagger']) -or $null -eq $document.PSObject.Properties['paths']) { throw 'O conteúdo recebido não é um contrato OpenAPI reconhecido.' }
                $sha=[Security.Cryptography.SHA256]::Create()
                try { $hash=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
                return [PSCustomObject]@{ environment='restricted'; source_url=$candidate; captured_at=[DateTime]::UtcNow.ToString('o'); sha256_source_utf8=$hash; source_json=$text }
            } catch { $lastError=$_.Exception }
        }
        if ($null -ne $lastError) { throw 'A referência foi encontrada, mas o JSON OpenAPI não pôde ser validado ou baixado. Não houve envio de DPS.' }
        throw 'Documentação não encontrada.'
    } finally { $client.Dispose() }
}

function New-TriadeRestrictedApiProbeRequest {
    # Path and method are confirmed by the supplied Swagger. HTTPS is mandatory.
    # This deliberately invalid identifier cannot refer to a real DPS and creates nothing.
    return [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Head,[Uri]'https://sefin.producaorestrita.nfse.gov.br/SefinNacional/dps/diagnostico-local')
}

function Invoke-TriadeRestrictedApiProbe {
    param([Parameter(Mandatory=$true)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    $null=Get-TriadeCertificateCheck -Certificate $Certificate
    $handler=$null;$client=$null;$request=$null;$response=$null
    try {
        $handler=New-TriadeRestrictedHandler -Certificate $Certificate
        $client=[Net.Http.HttpClient]::new($handler);$client.Timeout=[TimeSpan]::FromSeconds(15)
        $request=New-TriadeRestrictedApiProbeRequest
        $response=$client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $status=[int]$response.StatusCode
        $message='Resposta recebida, mas ainda não confirma acesso fiscal, autorização ou existência de documento.'
        if ($status -eq 400) { $message='HTTP 400: resposta compatível com a rejeição do identificador propositalmente inválido deste diagnóstico. Não é erro de uma nota e não autoriza emissão.' }
        elseif ($status -eq 401 -or $status -eq 403) { $message='A API recusou a autenticação/acesso. O HTTP 200 da documentação não garantia acesso fiscal.' }
        elseif ($status -eq 404) { $message='HTTP 404: não é possível distinguir por este teste entre rota não encontrada e identificador ausente. Precisamos conferir a publicação da API.' }
        elseif ($status -ge 300 -and $status -lt 400) { $message='Redirecionamento recebido e bloqueado. Nenhum destino alternativo foi acessado.' }
        return [PSCustomObject]@{ http_status=$status; failure=$null; message=$message }
    } catch {
        $failure=Get-TriadeConnectionFailure -Exception $_.Exception
        return [PSCustomObject]@{ http_status=$null; failure=$failure; message=$failure.message }
    } finally {
        if ($null -ne $response) { $response.Dispose() };if ($null -ne $request) { $request.Dispose() }
        if ($null -ne $client) { $client.Dispose() } elseif ($null -ne $handler) { $handler.Dispose() }
    }
}

function Invoke-TriadeRestrictedProbe {
    param([Parameter(Mandatory=$true)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    $null = Get-TriadeCertificateCheck -Certificate $Certificate
    $handler=$null;$client=$null;$request=$null;$response=$null
    try {
        $handler = New-TriadeRestrictedHandler -Certificate $Certificate
        $client = [Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(15)
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,[Uri]'https://sefin.producaorestrita.nfse.gov.br/API/SefinNacional/docs/index')
        $response = $client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        return [PSCustomObject]@{ attempted=$true; http_status=[int]$response.StatusCode; failure=$null; message='Servidor respondeu. Isso não confirma autorização de emissão, procuração ou credenciamento.' }
    } catch {
        $failure=Get-TriadeConnectionFailure -Exception $_.Exception
        return [PSCustomObject]@{ attempted=$true; http_status=$null; failure=$failure; message=$failure.message }
    } finally {
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $request) { $request.Dispose() }
        if ($null -ne $client) { $client.Dispose() } elseif ($null -ne $handler) { $handler.Dispose() }
    }
}

Export-ModuleMember -Function Get-TriadeWindowsCertificates,Import-TriadeLocalA1,Get-TriadeCertificateCheck,New-TriadeRestrictedHandler,Invoke-TriadeRestrictedProbe,Get-TriadeConnectionFailure,Resolve-TriadeDocumentationReference,Find-TriadeOpenApiReferences,Get-TriadeRestrictedOpenApi,Get-TriadeDocumentationFailure,New-TriadeRestrictedApiProbeRequest,Invoke-TriadeRestrictedApiProbe
