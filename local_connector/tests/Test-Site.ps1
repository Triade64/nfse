#requires -Version 5.1
param($Certificate,[string]$SchemaDirectory,[string]$Directory,[string]$Success,[string]$Rejected,[string]$Key,[string]$Found)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'TriadeSite.psm1') -Force
if (-not ('TriadeFakeSite' -as [type])) {
Add-Type -ReferencedAssemblies 'System.Net.Http.dll','System.dll' -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;
public sealed class TriadeFakeSite : HttpMessageHandler {
 public readonly List<string> Calls=new List<string>();
 public readonly List<string> Posted=new List<string>();
 public string Jobs="{\"jobs\":[]}"; public int ResultStatus=200;
 protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token){
  if(request.RequestUri.AbsoluteUri.IndexOf("sefin",StringComparison.OrdinalIgnoreCase)>=0)throw new Exception("FISCAL_ON_SITE_CLIENT");
  string auth=request.Headers.Authorization==null?"":request.Headers.Authorization.Scheme+" "+request.Headers.Authorization.Parameter;
  Calls.Add(request.Method.Method+" "+request.RequestUri.AbsolutePath+" "+auth);
  HttpResponseMessage response;
  if(request.Method==HttpMethod.Get){response=new HttpResponseMessage(HttpStatusCode.OK);response.Content=new StringContent(Jobs);}
  else{Posted.Add(request.Content.ReadAsStringAsync().Result);response=new HttpResponseMessage((HttpStatusCode)ResultStatus);response.Content=new StringContent("{}");}
  return Task.FromResult(response);
 }
}
'@
}
$site='https://nfse-sand.vercel.app';$ticket='T'+('a'*40)

# 1) The link only works for allow-listed sites, exact match, with a well-formed ticket.
$ok=Resolve-TriadeLaunchUrl -Url ('triade-nfse://assinar?site='+[Uri]::EscapeDataString($site)+'&ticket='+$ticket)
if($ok.site -ne $site -or $ok.ticket -ne $ticket){throw 'Link valido nao reconhecido.'}
$bad=@(
 'https://assinar?site=https%3A%2F%2Fnfse-sand.vercel.app&ticket='+$ticket,
 'triade-nfse://outra?site=https%3A%2F%2Fnfse-sand.vercel.app&ticket='+$ticket,
 'triade-nfse://assinar?site=https%3A%2F%2Fevil.example&ticket='+$ticket,
 'triade-nfse://assinar?site=https%3A%2F%2Fnfse-sand.vercel.app.evil.example&ticket='+$ticket,
 'triade-nfse://assinar?site=http%3A%2F%2Fnfse-sand.vercel.app&ticket='+$ticket,
 'triade-nfse://assinar?site=https%3A%2F%2Fnfse-sand.vercel.app%2Fx&ticket='+$ticket,
 'triade-nfse://assinar?site=https%3A%2F%2FNFSE-SAND.vercel.app&ticket='+$ticket,
 'triade-nfse://assinar?site=https%3A%2F%2Fnfse-sand.vercel.app&ticket=curto',
 'triade-nfse://assinar?site=https%3A%2F%2Fnfse-sand.vercel.app&ticket='+$ticket+'&extra=1',
 'triade-nfse://assinar?site=https%3A%2F%2Fevil.example&site=https%3A%2F%2Fnfse-sand.vercel.app&ticket='+$ticket)
foreach($url in $bad){$blocked=$false;try{$null=Resolve-TriadeLaunchUrl -Url $url}catch{$blocked=$true};if(-not $blocked){throw ('Link indevido aceito: '+$url)}}

$xmlText=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'dps-ficticia.xml'),[Text.UTF8Encoding]::new($false))
$xmlBytes=[Text.UTF8Encoding]::new($false).GetBytes($xmlText)
$sha=[Security.Cryptography.SHA256]::Create();$xmlHash=([BitConverter]::ToString($sha.ComputeHash($xmlBytes))).Replace('-','').ToLowerInvariant();$sha.Dispose()
$identifier=([xml]$xmlText).DPS.infDPS.Id
function New-Job([string]$Cnpj='11222333000181',[string]$Hash=$xmlHash){
 return ([PSCustomObject]@{dps_id=7;identifier=$identifier;series='12';number=1;status='Reservada';xml=$xmlText;xml_sha256=$Hash;summary=[PSCustomObject]@{cnpj=$Cnpj;tomador='TOMADOR FICTICIO';competencia='2026-11-05';valor='10.00'}})
}
function New-Fiscal([string]$Name,[int[]]$Statuses,[string[]]$Bodies){
 $journal=Join-Path $Directory ('site-'+$Name);$h=[TriadeFakeHttp]::new();$h.Marker=Join-Path (Join-Path $journal $identifier) 'estado.json'
 foreach($s in $Statuses){$h.Status.Enqueue($s)};foreach($b in $Bodies){$h.Body.Enqueue($b)}
 return [PSCustomObject]@{handler=$h;client=[Net.Http.HttpClient]::new($h);journal=$journal}
}
$clients=@()
try{
 # 2) Jobs are fetched with the bearer ticket only.
 $fakeSite=[TriadeFakeSite]::new();$fakeSite.Jobs=(@{jobs=@(New-Job)}|ConvertTo-Json -Depth 5 -Compress)
 $siteClient=New-TriadeSiteClient -Handler $fakeSite;$clients+=$siteClient
 $jobs=@(Get-TriadeSiteJobs -Client $siteClient -Site $site -Ticket $ticket)
 # Same pipeline shape as the connector window: filter by status and keep every job as its own item.
 $pending=@(Get-TriadeSiteJobs -Client $siteClient -Site $site -Ticket $ticket | Where-Object { $_.status -in @('Reservada','Desconhecida') })
 if($pending.Count -ne 1 -or $pending[0].dps_id -ne 7){throw 'Filtro da janela do conector perdeu as notas.'}
 if($jobs.Count -ne 1 -or $jobs[0].dps_id -ne 7 -or $fakeSite.Calls[0] -ne ('GET /api/connector/jobs Bearer '+$ticket)){throw 'Busca de notas nao usou o ticket.'}

 # 3) Happy path with the REAL response shape (idDps = NFS + key): signs, sends once, reports authorization with the NFS-e.
 $successNfs=$Success.Replace('"idDps":"'+$identifier+'"','"idDps":"NFS'+$Key+'"')
 $fiscal=New-Fiscal 'ok' @(404,201) @('',$successNfs);$clients+=$fiscal.client
 $result=Invoke-TriadeSiteJob -Job $jobs[0] -Certificate $Certificate -SchemaDirectory $SchemaDirectory -JournalRoot $fiscal.journal -FiscalClient $fiscal.client -SiteClient $siteClient -Site $site -Ticket $ticket
 if($result.state -ne 'Autorizada em teste'){throw ('Fluxo pelo site nao autorizou: '+($result|ConvertTo-Json -Compress))}
 if(@($fiscal.handler.Calls|Where-Object{$_ -match '^POST '}).Count -ne 1){throw 'Envio fiscal nao foi unico.'}
 $posted=$fakeSite.Posted[0]|ConvertFrom-Json
 if($fakeSite.Calls[$fakeSite.Calls.Count-1] -ne ('POST /api/connector/jobs/7/result Bearer '+$ticket) -or $posted.state -ne 'Autorizada em teste' -or $posted.access_key -ne $Key -or -not $posted.nfse_xml_b64 -or $posted.signed_sha256 -notmatch '^[0-9a-f]{64}$' -or $posted.http_status -ne 201){throw ('Resultado nao devolvido ao site. Chamadas: '+($fakeSite.Calls -join ' | '))}
 $nfse=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($posted.nfse_xml_b64));if($nfse -notmatch ('NFS'+$Key)){throw 'XML da NFS-e nao devolvido.'}

 # 4) Rejection is reported with its code and never resent.
 $fakeSite.Posted.Clear()
 $fiscal=New-Fiscal 'rejeicao' @(404,400) @('',$Rejected);$clients+=$fiscal.client
 $result=Invoke-TriadeSiteJob -Job $jobs[0] -Certificate $Certificate -SchemaDirectory $SchemaDirectory -JournalRoot $fiscal.journal -FiscalClient $fiscal.client -SiteClient $siteClient -Site $site -Ticket $ticket
 $posted=$fakeSite.Posted[0]|ConvertFrom-Json
 if($posted.state -ne 'Rejeitada em teste' -or $posted.codes -ne 'TESTE_REJEICAO' -or $posted.PSObject.Properties['access_key']){throw 'Rejeicao nao devolvida ao site.'}

 # 5) Timeout after POST: reported as unknown; a later link only consults (HEAD/GET) and reports the authorization.
 $fakeSite.Posted.Clear()
 $fiscal=New-Fiscal 'timeout' @(404,200,200,200) @('','',$Found,$successNfs);$clients+=$fiscal.client;$fiscal.handler.TimeoutOnPost=$true
 $result=Invoke-TriadeSiteJob -Job $jobs[0] -Certificate $Certificate -SchemaDirectory $SchemaDirectory -JournalRoot $fiscal.journal -FiscalClient $fiscal.client -SiteClient $siteClient -Site $site -Ticket $ticket
 if(($fakeSite.Posted[0]|ConvertFrom-Json).state -ne 'Situação desconhecida; consultar'){throw 'Timeout nao devolvido como situacao desconhecida.'}
 $fiscal.handler.TimeoutOnPost=$false
 $result=Invoke-TriadeSiteJob -Job $jobs[0] -Certificate $Certificate -SchemaDirectory $SchemaDirectory -JournalRoot $fiscal.journal -FiscalClient $fiscal.client -SiteClient $siteClient -Site $site -Ticket $ticket
 if($result.state -ne 'Autorizada em teste' -or @($fiscal.handler.Calls|Where-Object{$_ -match '^POST '}).Count -ne 1 -or ($fakeSite.Posted[1]|ConvertFrom-Json).access_key -ne $Key){throw ('Consulta posterior nao recuperou sem reenvio. '+($result|ConvertTo-Json -Compress -Depth 4)+' calls='+($fiscal.handler.Calls -join ';')+' posted='+($fakeSite.Posted -join ' || '))}

 # 5b) Same recovery with a consultation body built by hand (real API field order), separate journal.
 $fakeSite.Posted.Clear()
 $hand='{"tipoAmbiente":2,"versaoAplicativo":"SefinNacional_1.6.0","dataHoraProcessamento":"2026-11-05T14:18:59-03:00","idDps":"NFS'+$Key+'","chaveAcesso":"'+$Key+'"}'
 $fiscal=New-Fiscal 'timeout-b' @(404,200,200,200) @('','',$hand,$successNfs);$clients+=$fiscal.client;$fiscal.handler.TimeoutOnPost=$true
 $null=Invoke-TriadeSiteJob -Job $jobs[0] -Certificate $Certificate -SchemaDirectory $SchemaDirectory -JournalRoot $fiscal.journal -FiscalClient $fiscal.client -SiteClient $siteClient -Site $site -Ticket $ticket
 $fiscal.handler.TimeoutOnPost=$false
 $result=Invoke-TriadeSiteJob -Job $jobs[0] -Certificate $Certificate -SchemaDirectory $SchemaDirectory -JournalRoot $fiscal.journal -FiscalClient $fiscal.client -SiteClient $siteClient -Site $site -Ticket $ticket
 if($result.state -ne 'Autorizada em teste'){throw ('5b: '+($result|ConvertTo-Json -Compress -Depth 4))}
 # 6) Tampered XML in transit or a DPS of another issuer never reaches the fiscal transport.
 foreach($case in @(@{name='hash';job=(New-Job -Hash ('0'*64))},@{name='cnpj';job=(New-Job -Cnpj '00000000000191')})){
  $fiscal=New-Fiscal ('bloqueio-'+$case.name) @() @();$clients+=$fiscal.client
  $blocked=$false;try{$null=Invoke-TriadeSiteJob -Job $case.job -Certificate $Certificate -SchemaDirectory $SchemaDirectory -JournalRoot $fiscal.journal -FiscalClient $fiscal.client -SiteClient $siteClient -Site $site -Ticket $ticket}catch{$blocked=$true}
  if(-not $blocked -or $fiscal.handler.Calls.Count -ne 0){throw ('Job adulterado chegou ao transporte fiscal: '+$case.name)}
 }

 # 7) An expired ticket stops with a specific code.
 $expired=[TriadeFakeSite]::new();$expired.ResultStatus=401;$expiredClient=New-TriadeSiteClient -Handler $expired;$clients+=$expiredClient
 $code='';try{$null=Send-TriadeSiteResult -Client $expiredClient -Site $site -Ticket $ticket -DpsId 7 -Result ([PSCustomObject]@{state='Rejeitada em teste';http_status=400;codes='X';message=''}) -SignedSha256 ('a'*64) -JournalRoot $Directory -Identifier $identifier}catch{$code=$_.Exception.Message}
 if($code -ne 'SITE_TICKET_EXPIRED'){throw ('Ticket expirado nao identificado: '+$code)}
}finally{foreach($c in $clients){$c.Dispose()}}
Write-Output 'PASS: 0.9.0 link triade-nfse (lista de sites exata, ticket, parametros), busca com ticket, assinatura e envio unico, autorizacao/rejeicao/situacao desconhecida devolvidas ao site, consulta posterior sem reenvio, XML adulterado e emitente diverso bloqueados. Transporte ficticio.'
