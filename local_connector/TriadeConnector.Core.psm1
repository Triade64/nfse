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

function Invoke-TriadeRestrictedProbe {
    param([Parameter(Mandatory=$true)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    $null = Get-TriadeCertificateCheck -Certificate $Certificate
    $handler = New-TriadeRestrictedHandler -Certificate $Certificate
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(15)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,[Uri]'https://sefin.producaorestrita.nfse.gov.br/API/SefinNacional/docs/index')
    $response = $null
    try {
        $response = $client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        return [PSCustomObject]@{ attempted=$true; http_status=[int]$response.StatusCode; message='Servidor respondeu. Isso não confirma autorização de emissão, procuração ou credenciamento.' }
    } catch {
        return [PSCustomObject]@{ attempted=$true; http_status=$null; message='Conexão TLS/HTTP não concluída. Se usou A1 temporário, tente selecionar o certificado já instalado no Windows. Não houve envio fiscal; não há fallback para gravar a chave.' }
    } finally {
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose(); $client.Dispose()
    }
}

Export-ModuleMember -Function Import-TriadeLocalA1,Get-TriadeCertificateCheck,New-TriadeRestrictedHandler,Invoke-TriadeRestrictedProbe
