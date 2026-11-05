#requires -Version 5.1
param($Certificate,[byte[]]$SignedBytes,[string]$SchemaDirectory,[string]$Directory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'TriadeRestricted.psm1') -Force
Add-Type -ReferencedAssemblies 'System.Net.Http.dll','System.dll' -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;
public sealed class TriadeFakeHttp : HttpMessageHandler {
 public readonly List<string> Calls=new List<string>();
 public readonly Queue<int> Status=new Queue<int>();
 public readonly Queue<string> Body=new Queue<string>();
 public string Marker; public bool TimeoutOnPost; public bool TimeoutOnGet; public bool InvalidUtf8;
 protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token){
  string method=request.Method.Method;Calls.Add(method+" "+request.RequestUri.AbsoluteUri);
  if(request.RequestUri.Host!="sefin.producaorestrita.nfse.gov.br" || request.RequestUri.Scheme!="https" || request.RequestUri.Port!=443)throw new Exception("URL_UNSAFE");
  if((method=="GET" || method=="HEAD") && TimeoutOnGet)throw new TaskCanceledException("SEGREDO-FICTICIO-NAO-COPIAR");
  if(method=="POST"){
   if(!System.Text.RegularExpressions.Regex.IsMatch(File.ReadAllText(Marker),"\"attempted\"\\s*:\\s*true"))throw new Exception("MARKER_NOT_DURABLE_BEFORE_POST");
   if(TimeoutOnPost)throw new TaskCanceledException("FICTICIO-SEM-SEGREDO");
  }
  HttpResponseMessage response=new HttpResponseMessage((HttpStatusCode)Status.Dequeue());string body=Body.Dequeue();response.Content=InvalidUtf8?(HttpContent)new ByteArrayContent(new byte[]{195,40}):new StringContent(body);return Task.FromResult(response);
 }
}
'@
$null=& (Get-Module TriadeRestricted) {
 param($D)
 $path=Join-Path $D 'atomic-test.txt'
 Write-TriadeDurableFile -Path $path -Bytes ([Text.Encoding]::UTF8.GetBytes('primeiro'))
 Write-TriadeDurableFile -Path $path -Bytes ([Text.Encoding]::UTF8.GetBytes('segundo')) -Replace
 if([IO.File]::ReadAllText($path) -ne 'segundo'){throw 'Substituicao atomica falhou.'}
} $Directory
$unsignedDoc=Read-TriadeDps -Bytes $SignedBytes -SchemaDirectory $SchemaDirectory
$review=Test-TriadeSignedDps -Bytes $SignedBytes -Certificate $Certificate -SchemaDirectory $SchemaDirectory
$nfse=[Xml.XmlDocument]::new();$nfse.PreserveWhitespace=$true;$nfse.XmlResolver=$null;$nfse.Load((Join-Path $PSScriptRoot 'nfse-ficticia-template.xml'))
$null=$nfse.DocumentElement.FirstChild.AppendChild($nfse.ImportNode($unsignedDoc.DocumentElement,$true))
$key=$nfse.DocumentElement.FirstChild.GetAttribute('Id').Substring(3)
$rsa=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
try{
 $sig=[Security.Cryptography.Xml.SignedXml]::new($nfse);$sig.SigningKey=$rsa
 $reference=[Security.Cryptography.Xml.Reference]::new('#NFS'+$key);$reference.AddTransform([Security.Cryptography.Xml.XmlDsigEnvelopedSignatureTransform]::new());$reference.AddTransform([Security.Cryptography.Xml.XmlDsigC14NTransform]::new());$sig.AddReference($reference)
 $sig.ComputeSignature();$null=$nfse.DocumentElement.AppendChild($nfse.ImportNode($sig.GetXml(),$true))
}finally{$rsa.Dispose()}
$schema=[Xml.Schema.XmlSchemaSet]::new();$schema.XmlResolver=[TriadeOffline.XmlFiles]::new($SchemaDirectory);$null=$schema.Add('http://www.sped.fazenda.gov.br/nfse',(Join-Path $SchemaDirectory 'NFSe_v1.01.xsd'));$schema.Compile();$nfse.Schemas=$schema;$nfse.Validate($null)
$envelope=(ConvertTo-TriadeDpsEnvelope -Bytes ([Text.Encoding]::UTF8.GetBytes($nfse.OuterXml)))|ConvertFrom-Json
$success=@{tipoAmbiente=2;idDps=$review.identifier;chaveAcesso=$key;nfseXmlGZipB64=$envelope.dpsXmlGZipB64}|ConvertTo-Json -Compress
# Exercise the real parser/recovery separately so failures are visible in the synthetic test.
$null=& (Get-Module TriadeRestricted) {param($B,$R,$D,$S) Save-TriadeReturnedNfse -Body $B -Identifier $R.identifier -Key $B.chaveAcesso -Directory $D -SchemaDirectory $S -Review $R} ($success|ConvertFrom-Json) $review $Directory $SchemaDirectory
$found=@{tipoAmbiente=2;idDps=$review.identifier;chaveAcesso=$key}|ConvertTo-Json -Compress
$missing=''
$rejected='{"tipoAmbiente":2,"erros":[{"codigo":"TESTE_REJEICAO","descricao":"FICTICIO"}]}'
function New-FakeClient([string]$Name,[int[]]$Statuses,[string[]]$Bodies){
 $journal=Join-Path $Directory $Name;$handler=[TriadeFakeHttp]::new();$handler.Marker=Join-Path (Join-Path $journal $review.identifier) 'estado.json'
 foreach($status in $Statuses){$handler.Status.Enqueue($status)};foreach($body in $Bodies){$handler.Body.Enqueue($body)}
 return [PSCustomObject]@{handler=$handler;client=[Net.Http.HttpClient]::new($handler);root=$journal}
}
function Invoke-Case($Fake,[bool]$Send){
 return Invoke-TriadeSingleRestrictedDps -Bytes $SignedBytes -Certificate $Certificate -SchemaDirectory $SchemaDirectory -JournalRoot $Fake.root -Client $Fake.client -ConfirmRestrictedSend:$Send
}
$clients=@()
try{
 $case=New-FakeClient 'somente-consulta' @(404) @($missing);$clients+=$case
 $result=Invoke-Case $case $false
 if($result.attempted -or $case.handler.Calls.Count -ne 1 -or $case.handler.Calls[0] -notmatch '^HEAD '){throw 'Consulta fez POST.'}
 $case=New-FakeClient 'timeout-consulta' @() @();$clients+=$case;$case.handler.TimeoutOnGet=$true
 $result=Invoke-Case $case $false
 if($result.state -ne 'Novo' -or $result.diagnostic.stage -ne 'CONSULTAR_DPS' -or $result.diagnostic.category -ne 'timeout' -or $result.diagnostic.post_possible_this_run -or $result.http_status -ne 0){throw 'Timeout de consulta nao foi identificado.'}
 if(($result|ConvertTo-Json -Depth 5) -match 'SEGREDO|PRIVATE|CNPJ'){throw 'Diagnostico expoe mensagem interna.'}
 $case=New-FakeClient 'utf8-invalido' @(404) @('');$clients+=$case;$case.handler.InvalidUtf8=$true
 $result=Invoke-Case $case $false
 if($result.http_status -ne 404 -or $result.diagnostic.stage -ne 'CONSULTAR_DPS' -or $result.diagnostic.post_possible_this_run){throw 'Falha ao ler corpo perdeu HTTP recebido.'}
 $case=New-FakeClient '200-ambiente-zero' @(200,200) @('','{"tipoAmbiente":0}');$clients+=$case
 $result=Invoke-Case $case $false
 if($result.http_status -ne 200 -or $result.diagnostic.stage -ne 'VALIDAR_CONSULTA' -or $result.diagnostic.reason -ne 'RESPONSE_ENVIRONMENT' -or $result.diagnostic.post_possible_this_run){throw 'Ambiente zero em resposta de sucesso nao foi bloqueado.'}
 $case=New-FakeClient 'gravacao-consulta' @(404) @($missing);$clients+=$case
 $null=[IO.Directory]::CreateDirectory((Join-Path (Join-Path $case.root $review.identifier) 'ultima-consulta.json'))
 $result=Invoke-Case $case $false
 if($result.http_status -ne 404 -or $result.diagnostic.stage -ne 'GRAVAR_CONSULTA' -or $result.diagnostic.post_possible_this_run){throw 'Falha de gravacao perdeu etapa e HTTP.'}
 if(($result|ConvertTo-Json -Depth 5).Contains($case.root)){throw 'Diagnostico expoe caminho privado.'}
 $case=New-FakeClient 'sucesso' @(404,201,404) @($missing,$success,$missing);$clients+=$case
 $result=Invoke-Case $case $true
 if($result.state -ne 'Autorizada em teste' -or $result.http_status -ne 201){throw ('Resposta 201 valida nao reconhecida. '+($result|ConvertTo-Json -Compress)+' Calls: '+($case.handler.Calls -join ';')+' Files: '+((Get-ChildItem -LiteralPath (Join-Path $case.root $review.identifier)).Name -join ','))}
 $null=Invoke-Case $case $true
 if(@($case.handler.Calls|Where-Object{$_ -match '^POST '}).Count -ne 1){throw 'POST repetido apos sucesso.'}
 $statePath=Join-Path (Join-Path $case.root $review.identifier) 'estado.json';$state=[IO.File]::ReadAllText($statePath)|ConvertFrom-Json
 if(-not $state.attempted -or $state.nfse_sha256.Length -ne 64){throw 'Resultado nao persistido.'}
 $case=New-FakeClient 'timeout' @(404,404,200,200,200) @($missing,$missing,'',$found,$success);$clients+=$case;$case.handler.TimeoutOnPost=$true
 $result=Invoke-Case $case $true
 if($result.state -ne 'Situação desconhecida; consultar' -or $result.diagnostic.stage -ne 'ENVIAR_DPS' -or -not $result.diagnostic.post_possible_this_run){throw 'Timeout nao manteve estado e etapa desconhecidos.'}
 $result=Invoke-Case $case $true
 if(@($case.handler.Calls|Where-Object{$_ -match '^POST '}).Count -ne 1 -or $result.http_status -ne 404){throw 'Timeout foi reenviado.'}
 $result=Invoke-Case $case $false
 if($result.state -ne 'Autorizada em teste' -or @($case.handler.Calls|Where-Object{$_ -match '^POST '}).Count -ne 1){throw 'Consulta nao recuperou timeout sem reenvio.'}
 $case=New-FakeClient 'rejeicao' @(404,400,404) @($missing,$rejected,$missing);$clients+=$case
 $result=Invoke-Case $case $true
 if($result.state -ne 'Rejeitada em teste' -or $result.codes -ne 'TESTE_REJEICAO'){throw 'Rejeicao nao registrada.'}
 $null=Invoke-Case $case $true
 if(@($case.handler.Calls|Where-Object{$_ -match '^POST '}).Count -ne 1){throw 'Rejeicao foi reenviada.'}
 foreach($scenario in @(@{name='redirect';status=302;body=''},@{name='404-html';status=404;body='<html>FICTICIO</html>'},@{name='404-prod';status=404;body='{"tipoAmbiente":1,"erro":{}}'})){
  $case=New-FakeClient $scenario.name @($scenario.status) @($scenario.body);$clients+=$case
  $null=Invoke-Case $case $true
  if(@($case.handler.Calls|Where-Object{$_ -match '^POST '}).Count -ne 0){throw 'Preflight ambiguo permitiu POST.'}
 }
 foreach($scenario in @(@{name='500';status=500;body='{}'},@{name='201-invalido';status=201;body='{"tipoAmbiente":2}'},@{name='201-producao';status=201;body=$success.Replace('"tipoAmbiente":2','"tipoAmbiente":1')})){
  $case=New-FakeClient $scenario.name @(404,$scenario.status,404) @($missing,$scenario.body,$missing);$clients+=$case
  $result=Invoke-Case $case $true
  if($result.state -ne 'Situação desconhecida; consultar'){throw 'Retorno ambiguo foi marcado autorizado.'}
  $null=Invoke-Case $case $true
  if(@($case.handler.Calls|Where-Object{$_ -match '^POST '}).Count -ne 1){throw 'Retorno ambiguo foi reenviado.'}
 }
 $case=New-FakeClient 'ja-existe' @(200,200,200) @('',$found,$success);$clients+=$case
 $result=Invoke-Case $case $true
 if($result.state -ne 'Autorizada em teste' -or @($case.handler.Calls|Where-Object{$_ -match '^POST '}).Count -ne 0){throw 'DPS existente enviada de novo.'}
 if(($case.handler.Calls|ForEach-Object{$_.Split(' ')[0]}) -join ',' -ne 'HEAD,GET,GET'){throw 'Sequencia de consulta nao segue o contrato HEAD/GET.'}
 $case=New-FakeClient 'adulterado' @(404,201) @($missing,$success);$clients+=$case
 $tampered=([Text.Encoding]::UTF8.GetString($SignedBytes)).Replace('<vServ>10.00</vServ>','<vServ>11.00</vServ>')
 $blocked=$false;try{$null=Invoke-TriadeSingleRestrictedDps -Bytes ([Text.Encoding]::UTF8.GetBytes($tampered)) -Certificate $Certificate -SchemaDirectory $SchemaDirectory -JournalRoot $case.root -Client $case.client -ConfirmRestrictedSend}catch{$blocked=$true}
 if(-not $blocked -or $case.handler.Calls.Count -ne 0){throw 'XML adulterado chegou ao transporte.'}
 $case=New-FakeClient 'concorrencia' @(404,201) @($missing,$success);$clients+=$case
 $lockDir=Join-Path $case.root $review.identifier;$null=[IO.Directory]::CreateDirectory($lockDir)
 $locked=[IO.File]::Open((Join-Path $lockDir 'processamento.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{$blocked=$false;try{$null=Invoke-Case $case $true}catch{$blocked=$true};if(-not $blocked -or $case.handler.Calls.Count -ne 0){throw 'Duas operacoes concorrentes permitidas.'}}finally{$locked.Dispose()}
 $encoded=ConvertTo-TriadeDpsEnvelope -Bytes $SignedBytes|ConvertFrom-Json
 $decoded=ConvertFrom-TriadeXmlEnvelope -Encoded $encoded.dpsXmlGZipB64
 if([Convert]::ToBase64String($decoded) -ne [Convert]::ToBase64String($SignedBytes)){throw 'Envelope alterou XML assinado.'}
 $bomb=[byte[]]::new(2097153);$memory=[IO.MemoryStream]::new();$gzip=[IO.Compression.GZipStream]::new($memory,[IO.Compression.CompressionMode]::Compress,$true);$gzip.Write($bomb,0,$bomb.Length);$gzip.Dispose()
 $blocked=$false;try{$null=ConvertFrom-TriadeXmlEnvelope -Encoded ([Convert]::ToBase64String($memory.ToArray()))}catch{$blocked=$true}finally{$memory.Dispose()}
 if(-not $blocked){throw 'GZip excessivo nao bloqueado.'}
 $warnings=@();Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'TriadeDps.psm1') -Force -WarningVariable warnings
 if($warnings.Count -ne 0){throw 'Aviso de verbo nao aprovado permanece.'}
 & (Join-Path $PSScriptRoot 'Test-Timezone.ps1') -Certificate $Certificate -SchemaDirectory $SchemaDirectory -Directory $Directory -Success $success
 & (Join-Path $PSScriptRoot 'Test-Im.ps1') -Certificate $Certificate -SchemaDirectory $SchemaDirectory -Directory $Directory -Success $success
 Write-Output 'PASS: diagnostico seguro de timeout antes e depois do POST, ambiente zero em sucesso bloqueado e falha de gravacao, sem mensagem interna ou caminho privado.'
 Write-Output 'PASS: transporte simulado, confirmacao, journal antes do POST, 201/400/500, timeout, consulta sem reenvio, ambiente incorreto, redirect, GZip e verbos aprovados. Nenhuma chamada fiscal real.'
}finally{foreach($item in $clients){$item.client.Dispose()}}
