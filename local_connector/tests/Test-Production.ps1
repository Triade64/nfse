#requires -Version 5.1
# 0.10.0: production (tpAmb 1) through the same journaled flow, with its own host, layout, schema folder and labels.
# Simulated transport only: no fiscal call leaves this PC.
param($Certificate,[string]$SchemaDirectory,[string]$Directory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'TriadeRestricted.psm1') -Force
Import-Module (Join-Path $root 'TriadeSite.psm1') -Force
if (-not ('TriadeFakeProductionHttp' -as [type])) {
Add-Type -ReferencedAssemblies 'System.Net.Http.dll','System.dll' -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;
public sealed class TriadeFakeProductionHttp : HttpMessageHandler {
 public readonly List<string> Calls=new List<string>();
 public readonly Queue<int> Status=new Queue<int>();
 public readonly Queue<string> Body=new Queue<string>();
 public string Marker;
 protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token){
  string method=request.Method.Method;Calls.Add(method+" "+request.RequestUri.AbsoluteUri);
  if(request.RequestUri.Host!="sefin.nfse.gov.br" || request.RequestUri.Scheme!="https" || request.RequestUri.Port!=443)throw new Exception("URL_NOT_PRODUCTION");
  if(method=="POST" && !System.Text.RegularExpressions.Regex.IsMatch(File.ReadAllText(Marker),"\"attempted\"\\s*:\\s*true"))throw new Exception("MARKER_NOT_DURABLE_BEFORE_POST");
  HttpResponseMessage response=new HttpResponseMessage((HttpStatusCode)Status.Dequeue());response.Content=new StringContent(Body.Dequeue());return Task.FromResult(response);
 }
}
'@
}
# Bundle layout: schemas\ = restricted, schemas\producao = production (official files, byte-identical).
$production=Join-Path $Directory 'pacote\schemas\producao';$null=[IO.Directory]::CreateDirectory($production)
foreach($file in [IO.Directory]::GetFiles((Join-Path (Split-Path -Parent $root) 'schemas\production-20260209'),'*.xsd')){[IO.File]::Copy($file,(Join-Path $production ([IO.Path]::GetFileName($file))),$true)}

# Production layout (2026-02-09): tpAmb 1, no finNFSe in infDPS, cNBS after xDescServ.
$restrictedText=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'dps-ficticia.xml'),[Text.UTF8Encoding]::new($false))
$text=$restrictedText.Replace('<tpAmb>2</tpAmb>','<tpAmb>1</tpAmb>').Replace('<finNFSe>0</finNFSe>','').Replace('</xDescServ>','</xDescServ><cNBS>113022100</cNBS>')
$unsigned=[Text.UTF8Encoding]::new($false).GetBytes($text)

# 1) Schema folder and environment must agree; each layout only passes in its own environment.
foreach($case in @(@{bytes=$unsigned;dir=$SchemaDirectory;env='1'},@{bytes=$unsigned;dir=$production;env='2'},@{bytes=$unsigned;dir=$SchemaDirectory;env='2'},@{bytes=[Text.UTF8Encoding]::new($false).GetBytes($restrictedText);dir=$production;env='1'})){
 $blocked=$false;try{$null=Read-TriadeDps -Bytes $case.bytes -SchemaDirectory $case.dir -Environment $case.env}catch{$blocked=$true}
 if(-not $blocked){throw ('XML aceito fora do seu ambiente: '+$case.dir+' / '+$case.env)}
}
# The official production pattern '^0{0,4}\d{1,5}$' must accept own-application series in .NET (series 12 here).
$signed=Protect-TriadeOfflineDps -Bytes $unsigned -Certificate $Certificate -SchemaDirectory $production -OwnCnpj '11222333000181' -Environment '1'
$review=Test-TriadeSignedDps -Bytes $signed -Certificate $Certificate -SchemaDirectory $production -Environment '1'
$blocked=$false;try{$null=Test-TriadeSignedDps -Bytes $signed -Certificate $Certificate -SchemaDirectory $SchemaDirectory}catch{$blocked=$true}
if(-not $blocked){throw 'DPS de producao aceita como teste.'}

# 2) Government answer for production: NFS-e containing this DPS, tipoAmbiente 1.
$unsignedDoc=Read-TriadeDps -Bytes $signed -SchemaDirectory $production -Environment '1'
$nfse=[Xml.XmlDocument]::new();$nfse.PreserveWhitespace=$true;$nfse.XmlResolver=$null;$nfse.Load((Join-Path $PSScriptRoot 'nfse-ficticia-template.xml'))
$null=$nfse.DocumentElement.FirstChild.AppendChild($nfse.ImportNode($unsignedDoc.DocumentElement,$true))
$key=$nfse.DocumentElement.FirstChild.GetAttribute('Id').Substring(3)
$rsa=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
try{
 $sig=[Security.Cryptography.Xml.SignedXml]::new($nfse);$sig.SigningKey=$rsa
 $reference=[Security.Cryptography.Xml.Reference]::new('#NFS'+$key);$reference.AddTransform([Security.Cryptography.Xml.XmlDsigEnvelopedSignatureTransform]::new());$reference.AddTransform([Security.Cryptography.Xml.XmlDsigC14NTransform]::new());$sig.AddReference($reference)
 $sig.ComputeSignature();$null=$nfse.DocumentElement.AppendChild($nfse.ImportNode($sig.GetXml(),$true))
}finally{$rsa.Dispose()}
$envelope=(ConvertTo-TriadeDpsEnvelope -Bytes ([Text.Encoding]::UTF8.GetBytes($nfse.OuterXml)))|ConvertFrom-Json
$success=@{tipoAmbiente=1;idDps=('NFS'+$key);chaveAcesso=$key;nfseXmlGZipB64=$envelope.dpsXmlGZipB64}|ConvertTo-Json -Compress
function New-ProductionClient([string]$Name,[int[]]$Statuses,[string[]]$Bodies){
 $journal=Join-Path $Directory ('producao-'+$Name);$h=[TriadeFakeProductionHttp]::new();$h.Marker=Join-Path (Join-Path $journal $review.identifier) 'estado.json'
 foreach($s in $Statuses){$h.Status.Enqueue($s)};foreach($b in $Bodies){$h.Body.Enqueue($b)}
 return [PSCustomObject]@{handler=$h;client=[Net.Http.HttpClient]::new($h);journal=$journal}
}
$clients=@()
try{
 # 3) Authorized in production: production host only, journal records environment 1, label names production.
 $fiscal=New-ProductionClient 'ok' @(404,201) @('',$success);$clients+=$fiscal.client
 $result=Invoke-TriadeSingleRestrictedDps -Bytes $signed -Certificate $Certificate -SchemaDirectory $production -JournalRoot $fiscal.journal -Client $fiscal.client -ConfirmRestrictedSend -Environment '1'
 if($result.state -ne 'Autorizada em produção' -or $result.http_status -ne 201){throw ('Producao nao autorizou: '+($result|ConvertTo-Json -Compress))}
 if(($fiscal.handler.Calls -join '|') -ne ('HEAD https://sefin.nfse.gov.br/SefinNacional/dps/'+$review.identifier+'|POST https://sefin.nfse.gov.br/SefinNacional/nfse')){throw ('Chamadas de producao inesperadas: '+($fiscal.handler.Calls -join ' | '))}
 $state=[IO.File]::ReadAllText((Join-Path (Join-Path $fiscal.journal $review.identifier) 'estado.json'))|ConvertFrom-Json
 if($state.environment -ne 1 -or $state.access_key -ne $key){throw 'Historico de producao incorreto.'}
 # Re-running consults first and never re-sends; a restricted call on the same journal is refused.
 $again=New-ProductionClient 'ok' @(200,200,200) @('',(@{tipoAmbiente=1;idDps=('NFS'+$key);chaveAcesso=$key}|ConvertTo-Json -Compress),$success);$clients+=$again.client
 $result=Invoke-TriadeSingleRestrictedDps -Bytes $signed -Certificate $Certificate -SchemaDirectory $production -JournalRoot $again.journal -Client $again.client -ConfirmRestrictedSend -Environment '1'
 if($result.state -ne 'Autorizada em produção' -or @($again.handler.Calls|Where-Object{$_ -match '^POST'}).Count -ne 0){throw 'Reconsulta de producao reenviou ou falhou.'}

 # 4) A test-environment answer to a production request never counts as authorization.
 $wrong=New-ProductionClient 'ambiente-errado' @(404,201) @('',$success.Replace('"tipoAmbiente":1','"tipoAmbiente":2'));$clients+=$wrong.client
 $result=Invoke-TriadeSingleRestrictedDps -Bytes $signed -Certificate $Certificate -SchemaDirectory $production -JournalRoot $wrong.journal -Client $wrong.client -ConfirmRestrictedSend -Environment '1'
 if($result.state -ne 'Situação desconhecida; consultar' -or $result.diagnostic.reason -ne 'RESPONSE_ENVIRONMENT'){throw ('Resposta de outro ambiente aceita: '+($result|ConvertTo-Json -Compress))}

 # 5) Rejection keeps the production label (the site maps it to its own environment).
 $rejected=New-ProductionClient 'rejeitada' @(404,400) @('','{"tipoAmbiente":1,"erros":[{"codigo":"E0010","descricao":"FICTICIO"}]}');$clients+=$rejected.client
 $result=Invoke-TriadeSingleRestrictedDps -Bytes $signed -Certificate $Certificate -SchemaDirectory $production -JournalRoot $rejected.journal -Client $rejected.client -ConfirmRestrictedSend -Environment '1'
 if($result.state -ne 'Rejeitada em produção' -or $result.codes -ne 'E0010'){throw 'Rejeicao em producao nao identificada.'}

 # 6) Site jobs: environment comes from the site and must match the run; old jobs without it are restricted.
 $sha=[Security.Cryptography.SHA256]::Create();$hash=([BitConverter]::ToString($sha.ComputeHash($unsigned))).Replace('-','').ToLowerInvariant();$sha.Dispose()
 $job=[PSCustomObject]@{dps_id=8;identifier=$review.identifier;environment='1';series='12';number=1;status='Reservada';xml=$text;xml_sha256=$hash;needs_danfse=$false;access_key=$null;summary=[PSCustomObject]@{cnpj='11222333000181';tomador='TOMADOR FICTICIO';competencia='2026-11-05';valor='10.00'}}
 if((Get-TriadeJobEnvironment -Job $job) -ne '1' -or (Get-TriadeJobEnvironment -Job ([PSCustomObject]@{dps_id=1})) -ne '2'){throw 'Ambiente do job mal interpretado.'}
 $blocked=$false;try{$null=Get-TriadeJobEnvironment -Job ([PSCustomObject]@{environment='3'})}catch{$blocked=$_.Exception.Message -eq 'SITE_JOB_ENVIRONMENT'}
 if(-not $blocked){throw 'Ambiente desconhecido aceito.'}
 $fake=[TriadeFakeSite]::new();$siteClient=New-TriadeSiteClient -Handler $fake;$clients+=$siteClient
 $site='https://nfse-sand.vercel.app';$ticket='T'+('b'*40)
 $mismatch=New-ProductionClient 'site-divergente' @() @();$clients+=$mismatch.client
 $blocked=$false;try{$null=Invoke-TriadeSiteJob -Job $job -Certificate $Certificate -SchemaDirectory $SchemaDirectory -JournalRoot $mismatch.journal -FiscalClient $mismatch.client -SiteClient $siteClient -Site $site -Ticket $ticket}catch{$blocked=$_.Exception.Message -eq 'SITE_JOB_ENVIRONMENT'}
 if(-not $blocked -or $mismatch.handler.Calls.Count -ne 0 -or $fake.Calls.Count -ne 0){throw 'Job de producao processado como teste.'}
 $site1=New-ProductionClient 'site' @(404,201) @('',$success);$clients+=$site1.client
 $result=Invoke-TriadeSiteJob -Job $job -Certificate $Certificate -SchemaDirectory $production -JournalRoot $site1.journal -FiscalClient $site1.client -SiteClient $siteClient -Site $site -Ticket $ticket -FetchDanfse -Environment '1'
 $posted=$fake.Posted[0]|ConvertFrom-Json
 if($result.state -ne 'Autorizada em produção' -or $posted.state -ne 'Autorizada em produção' -or $posted.access_key -ne $key -or -not $posted.nfse_xml_b64){throw ('Resultado de producao nao devolvido ao site: '+($fake.Posted -join ' | '))}
 if($fake.Posted.Count -ne 1 -or @($site1.handler.Calls|Where-Object{$_ -match 'adn\.'}).Count -ne 0){throw 'Producao tentou buscar DANFSe no ADN.'}
 Write-Output 'PASS: producao 0.10.0 — layout e esquema proprios, serie aceita no padrao oficial, host sefin.nfse.gov.br, historico separado, resposta de outro ambiente recusada, rotulo "Autorizada em produção" e job do site vinculado ao ambiente. Nenhuma chamada fiscal real.'
}finally{foreach($item in $clients){$item.Dispose()}}
