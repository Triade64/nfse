#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
foreach($name in @('ConectorTriade.ps1','TriadeConnector.Core.psm1')) {
    $tokens=$null;$errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $name),[ref]$tokens,[ref]$errors)
    if ($errors.Count -ne 0) { throw ('Falha no parser PowerShell: '+$name) }
}
Import-Module (Join-Path $root 'TriadeConnector.Core.psm1') -Force
$key=[Security.Cryptography.RSACng]::new(2048)
$cert=$null;$expired=$null;$public=$null;$imported=$null;$handler=$null;$password=$null
$directory=Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
$null=New-Item -ItemType Directory -Path $directory
try {
    $req=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=FICTICIO-SEM-VALIDADE-ICP',$key,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
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
    & (Join-Path $root 'ConectorTriade.ps1') -SelfTest
    Write-Output 'PASS: parser Windows PowerShell, validade, chave privada, importacao efemera, senha incorreta e handler sem redirects. Sem rede ou certificados reais.'
} finally {
    foreach($object in @($handler,$imported,$public,$expired,$cert,$key,$password)) { if ($null -ne $object) { $object.Dispose() } }
    Remove-Item -LiteralPath $directory -Recurse -Force
}
