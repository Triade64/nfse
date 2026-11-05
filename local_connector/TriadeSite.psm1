#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
# Link triade-nfse:// opened by the site (0.9.0). The link only carries WHERE (an allow-listed site) and a short-lived
# ticket. The connector downloads the reserved DPS, re-validates everything locally, asks the operator, signs with the
# Windows certificate, submits with the existing journal protections and reports the outcome back to the site.

# Only these sites can hand work to this PC. A link pointing anywhere else is refused before any network call.
$script:TriadeAllowedSites=@('https://nfse-sand.vercel.app')
$script:TriadeProtocol='triade-nfse'

function Get-TriadeAllowedSites { return ,@($script:TriadeAllowedSites) }

function Resolve-TriadeLaunchUrl {
 param([Parameter(Mandatory=$true)][string]$Url,[string[]]$AllowedSites=$script:TriadeAllowedSites)
 if($Url.Length -gt 400){throw 'LAUNCH_URL_INVALID'}
 $uri=$null
 if(-not [Uri]::TryCreate($Url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne $script:TriadeProtocol -or $uri.Host -ne 'assinar'){throw 'LAUNCH_URL_INVALID'}
 $values=@{}
 foreach($pair in $uri.Query.TrimStart('?').Split('&')){
  if(-not $pair){continue}
  $parts=$pair.Split('=',2);if($parts.Count -ne 2){throw 'LAUNCH_URL_INVALID'}
  $name=[Uri]::UnescapeDataString($parts[0]);if($values.ContainsKey($name)){throw 'LAUNCH_URL_INVALID'}
  $values[$name]=[Uri]::UnescapeDataString($parts[1].Replace('+',' '))
 }
 if(@($values.Keys|Where-Object{$_ -notin @('site','ticket')}).Count -ne 0){throw 'LAUNCH_URL_INVALID'}
 $site=[string]$values['site'];$ticket=[string]$values['ticket']
 if($ticket -notmatch '^[A-Za-z0-9_-]{30,100}$'){throw 'LAUNCH_URL_INVALID'}
 # Exact match against the allow-list: no prefixes, paths, ports or credentials can slip through.
 if(-not ($AllowedSites -ccontains $site)){throw 'SITE_NOT_ALLOWED'}
 return [PSCustomObject]@{site=$site;ticket=$ticket}
}

function New-TriadeSiteClient {
 param([Net.Http.HttpMessageHandler]$Handler)
 if($null -eq $Handler){$h=[Net.Http.HttpClientHandler]::new();$h.AllowAutoRedirect=$false;$h.UseCookies=$false;$Handler=$h}
 $client=[Net.Http.HttpClient]::new($Handler);$client.Timeout=[TimeSpan]::FromSeconds(30)
 return $client
}

function Invoke-TriadeSiteRequest {
 param([Net.Http.HttpClient]$Client,[string]$Site,[string]$Ticket,[string]$Method,[string]$Path,[string]$Json)
 $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method),$Site+$Path)
 try{
  $request.Headers.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$Ticket)
  $request.Headers.Add('X-Requested-With','nfse-local')
  if($Json){$request.Content=[Net.Http.StringContent]::new($Json,[Text.Encoding]::UTF8,'application/json')}
  $response=$Client.SendAsync($request).GetAwaiter().GetResult()
  try{
   $text=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
   if($text.Length -gt 6291456){throw 'SITE_RESPONSE_SIZE'}
   if([int]$response.StatusCode -eq 401){throw 'SITE_TICKET_EXPIRED'}
   if(-not $response.IsSuccessStatusCode){throw ('SITE_HTTP_'+[int]$response.StatusCode)}
   return ($text|ConvertFrom-Json)
  }finally{$response.Dispose()}
 }finally{$request.Dispose()}
}

function Get-TriadeSiteJobs {
 param([Net.Http.HttpClient]$Client,[string]$Site,[string]$Ticket)
 $body=Invoke-TriadeSiteRequest -Client $Client -Site $Site -Ticket $Ticket -Method GET -Path '/api/connector/jobs'
 # Emit each job to the pipeline (callers collect with @(...)); a wrapped array would reach Where-Object as one item.
 foreach($job in @($body.jobs)){Write-Output $job}
}

function Get-TriadeJobBytes {
 # The XML must arrive exactly as the site stored it (same SHA-256), before any local check or signature.
 param($Job)
 $bytes=[Text.UTF8Encoding]::new($false).GetBytes([string]$Job.xml)
 $sha=[Security.Cryptography.SHA256]::Create()
 try{$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
 if($hash -ne [string]$Job.xml_sha256){throw 'SITE_XML_INTEGRITY'}
 return ,$bytes
}

function Get-TriadeJournalOutcome {
 param([string]$JournalRoot,[string]$Identifier)
 $directory=Join-Path $JournalRoot $Identifier
 $statePath=Join-Path $directory 'estado.json'
 $outcome=[PSCustomObject]@{access_key=$null;nfse_xml_b64=$null}
 if(-not [IO.File]::Exists($statePath)){return $outcome}
 $state=[IO.File]::ReadAllText($statePath)|ConvertFrom-Json
 if($state.access_key -match '^[0-9]{50}$'){
  $outcome.access_key=$state.access_key
  $nfse=Join-Path $directory 'nfse-recebida.xml'
  if([IO.File]::Exists($nfse)){$outcome.nfse_xml_b64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($nfse))}
 }
 return $outcome
}

function Send-TriadeSiteResult {
 param([Net.Http.HttpClient]$Client,[string]$Site,[string]$Ticket,[int]$DpsId,$Result,[string]$SignedSha256,[string]$JournalRoot,[string]$Identifier)
 $state=[string]$Result.state
 if($state -notin @('Autorizada em teste','Rejeitada em teste')){$state='Situação desconhecida; consultar'}
 $payload=[ordered]@{state=$state;http_status=[int]$Result.http_status;codes=[string]$Result.codes;message=[string]$Result.message;signed_sha256=$SignedSha256}
 if($state -eq 'Autorizada em teste'){
  $outcome=Get-TriadeJournalOutcome -JournalRoot $JournalRoot -Identifier $Identifier
  if(-not $outcome.access_key -or -not $outcome.nfse_xml_b64){throw 'NFSE_RECOVERY_PENDING'}
  $payload.access_key=$outcome.access_key;$payload.nfse_xml_b64=$outcome.nfse_xml_b64
 }
 if($payload.message.Length -gt 400){$payload.message=$payload.message.Substring(0,400)}
 if($payload.codes.Length -gt 200){$payload.codes=$payload.codes.Substring(0,200)}
 return Invoke-TriadeSiteRequest -Client $Client -Site $Site -Ticket $Ticket -Method POST -Path ('/api/connector/jobs/'+$DpsId+'/result') -Json ($payload|ConvertTo-Json -Compress)
}

function Send-TriadeSiteDanfse {
 # Never changes the fiscal outcome: any failure is reported to the site as a code and the NFS-e stays authorized.
 param([Net.Http.HttpClient]$FiscalClient,[Net.Http.HttpClient]$SiteClient,[string]$Site,[string]$Ticket,[int]$DpsId,[string]$AccessKey,[string]$JournalRoot,[string]$Identifier)
 $code=$null;$pdf=$null
 try{
  $pdf=Get-TriadeDanfse -Client $FiscalClient -AccessKey $AccessKey
  $directory=Join-Path $JournalRoot $Identifier
  if([IO.Directory]::Exists($directory)){[IO.File]::WriteAllBytes((Join-Path $directory 'danfse.pdf'),$pdf)}
 }catch{
  $code=$_.Exception.Message;if($code -notmatch '^[A-Z0-9_]{3,40}$'){$code='DANFSE_UNCLASSIFIED'}
 }
 $payload=if($null -ne $code){@{error_code=$code}}else{@{pdf_b64=[Convert]::ToBase64String($pdf)}}
 $null=Invoke-TriadeSiteRequest -Client $SiteClient -Site $Site -Ticket $Ticket -Method POST -Path ('/api/connector/jobs/'+$DpsId+'/danfse') -Json ($payload|ConvertTo-Json -Compress)
 return $code
}

function Invoke-TriadeSiteJob {
 # One DPS: integrity -> local XSD/CNPJ/certificate checks + signature -> journaled submission -> report to site.
 param($Job,[Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,[string]$SchemaDirectory,[string]$JournalRoot,
       [Net.Http.HttpClient]$FiscalClient,[Net.Http.HttpClient]$SiteClient,[string]$Site,[string]$Ticket,[switch]$FetchDanfse)
 # 0.9.2: no contributor DANFSe API is published (ADN restricted /danfse -> 404, production docs 503, manuals silent).
 # The site generates the DANFSe from the authorized XML; the ADN download stays available only with -FetchDanfse.
 if([string]$Job.status -eq 'Autorizada'){
  if(-not $FetchDanfse -or -not $Job.needs_danfse -or [string]$Job.access_key -notmatch '^[0-9]{50}$'){throw 'SITE_JOB_DONE'}
  $danfse=Send-TriadeSiteDanfse -FiscalClient $FiscalClient -SiteClient $SiteClient -Site $Site -Ticket $Ticket -DpsId ([int]$Job.dps_id) -AccessKey ([string]$Job.access_key) -JournalRoot $JournalRoot -Identifier ([string]$Job.identifier)
  return [PSCustomObject]@{state='Autorizada em teste';http_status=200;codes='';message='Somente DANFSe';danfse=$(if($null -eq $danfse){'ok'}else{$danfse})}
 }
 $bytes=Get-TriadeJobBytes -Job $Job
 # Protect-TriadeOfflineDps re-validates XSD, tpAmb=2, prestador emitente and that the certificate CNPJ is the DPS CNPJ.
 $signed=Protect-TriadeOfflineDps -Bytes $bytes -Certificate $Certificate -SchemaDirectory $SchemaDirectory -OwnCnpj ([string]$Job.summary.cnpj)
 $review=Test-TriadeSignedDps -Bytes $signed -Certificate $Certificate -SchemaDirectory $SchemaDirectory
 if($review.identifier -ne [string]$Job.identifier){throw 'SITE_XML_INTEGRITY'}
 $sha=[Security.Cryptography.SHA256]::Create()
 try{$signedHash=([BitConverter]::ToString($sha.ComputeHash($signed))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
 $result=Invoke-TriadeSingleRestrictedDps -Bytes $signed -Certificate $Certificate -SchemaDirectory $SchemaDirectory -JournalRoot $JournalRoot -Client $FiscalClient -ConfirmRestrictedSend
 $null=Send-TriadeSiteResult -Client $SiteClient -Site $Site -Ticket $Ticket -DpsId ([int]$Job.dps_id) -Result $result -SignedSha256 $signedHash -JournalRoot $JournalRoot -Identifier $review.identifier
 if($FetchDanfse -and $result.state -eq 'Autorizada em teste'){
  $outcome=Get-TriadeJournalOutcome -JournalRoot $JournalRoot -Identifier $review.identifier
  $danfse=Send-TriadeSiteDanfse -FiscalClient $FiscalClient -SiteClient $SiteClient -Site $Site -Ticket $Ticket -DpsId ([int]$Job.dps_id) -AccessKey $outcome.access_key -JournalRoot $JournalRoot -Identifier $review.identifier
  $result|Add-Member -NotePropertyName danfse -NotePropertyValue $(if($null -eq $danfse){'ok'}else{$danfse}) -Force
 }
 return $result
}

function Register-TriadeProtocol {
 # Per-user registration (HKCU): no administrator rights and nothing changed for other Windows users.
 param([Parameter(Mandatory=$true)][string]$ScriptPath)
 $full=[IO.Path]::GetFullPath($ScriptPath)
 if(-not [IO.File]::Exists($full) -or [IO.Path]::GetFileName($full) -ne 'ConectorTriade.ps1'){throw 'PROTOCOL_SCRIPT_INVALID'}
 $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
 $command='"'+$powershell+'" -NoLogo -NoProfile -STA -ExecutionPolicy RemoteSigned -File "'+$full+'" -Url "%1"'
 $root='HKCU:\Software\Classes\'+$script:TriadeProtocol
 $null=New-Item -Path $root -Force
 Set-ItemProperty -Path $root -Name '(default)' -Value 'URL:Tríade NFS-e Conector'
 Set-ItemProperty -Path $root -Name 'URL Protocol' -Value ''
 $null=New-Item -Path ($root+'\shell\open\command') -Force
 Set-ItemProperty -Path ($root+'\shell\open\command') -Name '(default)' -Value $command
 return $command
}

function Get-TriadeProtocolCommand {
 $key='HKCU:\Software\Classes\'+$script:TriadeProtocol+'\shell\open\command'
 if(-not (Test-Path $key)){return $null}
 return (Get-ItemProperty -Path $key).'(default)'
}

Export-ModuleMember -Function Send-TriadeSiteDanfse,Get-TriadeAllowedSites,Resolve-TriadeLaunchUrl,New-TriadeSiteClient,Get-TriadeSiteJobs,Get-TriadeJobBytes,Send-TriadeSiteResult,Invoke-TriadeSiteJob,Register-TriadeProtocol,Get-TriadeProtocolCommand
