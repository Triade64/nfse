#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

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

Export-ModuleMember -Function Import-TriadeLocalA1,Get-TriadeCertificateCheck,New-TriadeRestrictedHandler,Invoke-TriadeRestrictedProbe,Get-TriadeConnectionFailure
