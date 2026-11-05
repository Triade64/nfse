#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Net.Http

function Get-TriadeXmlHash {
 param([byte[]]$Bytes)
 $hash=[Security.Cryptography.SHA256]::Create()
 try{return ([BitConverter]::ToString($hash.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
}
function Write-TriadeDurableFile {
 param([string]$Path,[byte[]]$Bytes,[switch]$Replace)
 $temp=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
 try {
  $stream=[IO.FileStream]::new($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
  try{$stream.Write($Bytes,0,$Bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
  if([IO.File]::Exists($Path)){
   if(-not $Replace){throw 'FILE_EXISTS'}
   [IO.File]::Replace($temp,$Path,[NullString]::Value)
  }else{[IO.File]::Move($temp,$Path)}
 }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Save-TriadeRestrictedState {
 param([string]$Path,$State)
 $State.updated_utc=[DateTime]::UtcNow.ToString('o')
 Write-TriadeDurableFile -Path $Path -Bytes ([Text.UTF8Encoding]::new($false).GetBytes(($State|ConvertTo-Json -Depth 8))) -Replace
}
function ConvertTo-TriadeDpsEnvelope {
 param([byte[]]$Bytes)
 if($Bytes.Length -eq 0 -or $Bytes.Length -gt 2097152){throw 'XML_SIZE'}
 $memory=[IO.MemoryStream]::new();$gzip=$null
 try{
  $gzip=[IO.Compression.GZipStream]::new($memory,[IO.Compression.CompressionMode]::Compress,$true)
  $gzip.Write($Bytes,0,$Bytes.Length);$gzip.Dispose();$gzip=$null
  return (@{dpsXmlGZipB64=[Convert]::ToBase64String($memory.ToArray())}|ConvertTo-Json -Compress)
 }finally{if($null -ne $gzip){$gzip.Dispose()};$memory.Dispose()}
}
function ConvertFrom-TriadeXmlEnvelope {
 param([string]$Encoded)
 if([string]::IsNullOrWhiteSpace($Encoded) -or $Encoded.Length -gt 8388608){throw 'ENVELOPE_SIZE'}
 $source=[IO.MemoryStream]::new([Convert]::FromBase64String($Encoded));$gzip=$null;$target=[IO.MemoryStream]::new()
 try{
  $gzip=[IO.Compression.GZipStream]::new($source,[IO.Compression.CompressionMode]::Decompress)
  $buffer=[byte[]]::new(8192)
  while(($count=$gzip.Read($buffer,0,$buffer.Length)) -gt 0){
   if($target.Length+$count -gt 2097152){throw 'XML_SIZE'}
   $target.Write($buffer,0,$count)
  }
  if($target.Length -eq 0){throw 'XML_SIZE'}
  return ,$target.ToArray()
 }finally{if($null -ne $gzip){$gzip.Dispose()};$source.Dispose();$target.Dispose()}
}
function New-TriadeFiscalRequest {
 param([ValidateSet('HEAD_DPS','GET_DPS','GET_NFSE','POST_DPS')][string]$Operation,[string]$Identifier,[byte[]]$Xml)
 $base='https://sefin.producaorestrita.nfse.gov.br/SefinNacional'
 switch($Operation){
  HEAD_DPS {
   if($Identifier -cnotmatch '^DPS[0-9]{42}$'){throw 'XML_ID'}
   return [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Head,($base+'/dps/'+$Identifier))
  }
  GET_DPS {
   if($Identifier -cnotmatch '^DPS[0-9]{42}$'){throw 'XML_ID'}
   return [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,($base+'/dps/'+$Identifier))
  }
  GET_NFSE {
   if($Identifier -notmatch '^[0-9]{50}$'){throw 'ACCESS_KEY'}
   return [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,($base+'/nfse/'+$Identifier))
  }
  POST_DPS {
   $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,($base+'/nfse'))
   $request.Content=[Net.Http.StringContent]::new((ConvertTo-TriadeDpsEnvelope -Bytes $Xml),[Text.Encoding]::UTF8,'application/json')
   return $request
  }
 }
}
function Invoke-TriadeFiscalHttp {
 param([Net.Http.HttpClient]$Client,[Net.Http.HttpRequestMessage]$Request)
 $cancel=[Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(35));$response=$null;$stream=$null;$memory=[IO.MemoryStream]::new()
 try{
  $response=$Client.SendAsync($Request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cancel.Token).GetAwaiter().GetResult()
  if($response.Content.Headers.ContentLength -gt 8388608){throw 'HTTP_SIZE'}
  $stream=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult();$buffer=[byte[]]::new(8192)
  while(($count=$stream.ReadAsync($buffer,0,$buffer.Length,$cancel.Token).GetAwaiter().GetResult()) -gt 0){
   if($memory.Length+$count -gt 8388608){throw 'HTTP_SIZE'}
   $memory.Write($buffer,0,$count)
  }
  return [PSCustomObject]@{status=[int]$response.StatusCode;text=[Text.UTF8Encoding]::new($false,$true).GetString($memory.ToArray())}
 }catch{
  if($null -ne $response){$_.Exception.Data['TriadeHttpStatus']=[int]$response.StatusCode}
  throw
 }finally{if($null -ne $stream){$stream.Dispose()};if($null -ne $response){$response.Dispose()};$memory.Dispose();$cancel.Dispose();$Request.Dispose()}
}
function Get-TriadeDanfse {
 # Official DANFSe (PDF) from the ADN of the restricted environment. Fixed host, no redirects (handler), 8 MB cap.
 # Moved from SEFIN to ADN per the SEFIN Swagger (/DANFSe -> 501). Returns the PDF bytes or throws a safe code.
 param([Parameter(Mandatory=$true)][Net.Http.HttpClient]$Client,[Parameter(Mandatory=$true)][string]$AccessKey)
 if($AccessKey -notmatch '^[0-9]{50}$'){throw 'ACCESS_KEY'}
 $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,('https://adn.producaorestrita.nfse.gov.br/danfse/'+$AccessKey))
 $request.Headers.Accept.ParseAdd('application/pdf')
 $cancel=[Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(45));$response=$null;$stream=$null;$memory=[IO.MemoryStream]::new()
 try{
  $response=$Client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cancel.Token).GetAwaiter().GetResult()
  if([int]$response.StatusCode -ne 200){throw ('DANFSE_HTTP_'+[int]$response.StatusCode)}
  if($response.Content.Headers.ContentLength -gt 8388608){throw 'DANFSE_SIZE'}
  $stream=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult();$buffer=[byte[]]::new(8192)
  while(($count=$stream.ReadAsync($buffer,0,$buffer.Length,$cancel.Token).GetAwaiter().GetResult()) -gt 0){
   if($memory.Length+$count -gt 8388608){throw 'DANFSE_SIZE'}
   $memory.Write($buffer,0,$count)
  }
  $bytes=$memory.ToArray()
  if($bytes.Length -lt 5 -or [Text.Encoding]::ASCII.GetString($bytes,0,5) -ne '%PDF-'){throw 'DANFSE_FORMAT'}
  return ,$bytes
 }finally{if($null -ne $stream){$stream.Dispose()};if($null -ne $response){$response.Dispose()};$memory.Dispose();$cancel.Dispose();$request.Dispose()}
}
function Read-TriadeFiscalJson {
 param($Response)
 if([string]::IsNullOrWhiteSpace($Response.text)){throw 'RESPONSE_FORMAT'}
 $body=$Response.text|ConvertFrom-Json
 if($body -isnot [PSCustomObject] -or ($body.tipoAmbiente -isnot [int] -and $body.tipoAmbiente -isnot [long]) -or $body.tipoAmbiente -ne 2){throw 'RESPONSE_ENVIRONMENT'}
 return $body
}
function Get-TriadeFiscalErrorCodes {
 param($Body)
 $codes=@()
 foreach($error in @($Body.erros)){
  if([string]$error.codigo -match '^[A-Za-z][A-Za-z0-9._-]{0,31}$'){$codes += [string]$error.codigo}
  if($codes.Count -ge 10){break}
 }
 return ($codes -join ', ')
}
function Test-TriadeResponseId {
 # The Swagger describes idDps as the DPS identifier, but the restricted API answered the first authorization (2026-11-05)
 # with idDps = "NFS" + access key, i.e. the NFS-e Id. Accept exactly those two forms; the binding to OUR DPS is enforced
 # afterwards by Save-TriadeReturnedNfse, which requires the returned XML to contain this DPS Id, CNPJ, competence and amount.
 param($Value,[string]$Identifier,$Key)
 if([string]$Key -notmatch '^[0-9]{50}$'){return $false}
 return ([string]$Value -ceq $Identifier) -or ([string]$Value -ceq ('NFS'+[string]$Key))
}
function Save-TriadeReturnedNfse {
 param($Body,[string]$Identifier,[string]$Key,[string]$Directory,[string]$SchemaDirectory,$Review)
 if($Body.tipoAmbiente -ne 2 -or $Key -notmatch '^[0-9]{50}$' -or $Body.chaveAcesso -ne $Key){throw 'RESPONSE_ID'}
 $bytes=ConvertFrom-TriadeXmlEnvelope -Encoded $Body.nfseXmlGZipB64
 # Preserve exactly the returned bytes; never regenerate a government document.
 Write-TriadeDurableFile -Path (Join-Path $Directory 'nfse-recebida.xml') -Bytes $bytes -Replace
 $settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null;$settings.MaxCharactersInDocument=2097152
 $stream=[IO.MemoryStream]::new($bytes,$false);$reader=$null
 try{
  $reader=[Xml.XmlReader]::Create($stream,$settings)
  $doc=[Xml.XmlDocument]::new();$doc.PreserveWhitespace=$true;$doc.XmlResolver=$null;$doc.Load($reader)
 }finally{if($null -ne $reader){$reader.Dispose()};$stream.Dispose()}
 $schemas=[Xml.Schema.XmlSchemaSet]::new();$schemas.XmlResolver=[TriadeOffline.XmlFiles]::new($SchemaDirectory)
 $null=$schemas.Add('http://www.sped.fazenda.gov.br/nfse',(Join-Path $SchemaDirectory 'NFSe_v1.01.xsd'));$schemas.Compile();$doc.Schemas=$schemas;$doc.Validate($null)
 $ns=[Xml.XmlNamespaceManager]::new($doc.NameTable);$ns.AddNamespace('n','http://www.sped.fazenda.gov.br/nfse')
 $info=$doc.SelectSingleNode('/n:NFSe/n:infNFSe',$ns)
 $dps=$doc.SelectSingleNode('/n:NFSe/n:infNFSe/n:DPS/n:infDPS',$ns)
 if($null -eq $info -or $null -eq $dps -or $info.GetAttribute('Id') -ne ('NFS'+$Key) -or $dps.GetAttribute('Id') -ne $Identifier -or $dps.SelectSingleNode('n:tpAmb',$ns).InnerText -ne '2'){throw 'RESPONSE_ID'}
 if($dps.SelectSingleNode('n:prest/n:CNPJ',$ns).InnerText -ne $Review.cnpj -or $dps.SelectSingleNode('n:dCompet',$ns).InnerText -ne $Review.competence -or $dps.SelectSingleNode('n:valores/n:vServPrest/n:vServ',$ns).InnerText -ne $Review.amount){throw 'RESPONSE_ID'}
 return Get-TriadeXmlHash -Bytes $bytes
}
function Get-TriadeRestrictedFailureInfo {
 param([Exception]$Exception,[int]$LastHttp)
 $failure=Get-TriadeConnectionFailure -Exception $Exception
 $reason='UNCLASSIFIED';$cursor=$Exception
 $allowed=@('IM_REVISION_INVALID','IM_REVISION_BLOCKED','TIMEZONE_REVISION_INVALID','TIMEZONE_REVISION_BLOCKED','JOURNAL_INVALID','JOURNAL_CONFLICT','RESPONSE_FORMAT','RESPONSE_ENVIRONMENT','RESPONSE_ID','HTTP_SIZE','XML_SIZE','ENVELOPE_SIZE','NFSE_RECOVERY_PENDING','FILE_EXISTS')
 for($i=0;$i -lt 8 -and $null -ne $cursor;$i++){
  if($allowed -ccontains $cursor.Message){$reason=$cursor.Message}
  if($cursor.Data.Contains('TriadeHttpStatus')){
   $status=$cursor.Data['TriadeHttpStatus'];if($status -is [int] -and $status -ge 100 -and $status -le 599){$LastHttp=$status}
  }
  $cursor=$cursor.InnerException
 }
 return [PSCustomObject]@{reason=$reason;http_status=$LastHttp;category=$failure.category;codes=$failure.codes;types=$failure.types}
}
function Get-TriadeRestrictedResult {
 param($State,[string]$Message,[int]$HttpStatus=0,[string]$ErrorCodes='')
 return [PSCustomObject]@{state=$State.status;attempted=[bool]$State.attempted;http_status=$HttpStatus;codes=$ErrorCodes;message=$Message}
}
function Invoke-TriadeSingleRestrictedDps {
 param([Parameter(Mandatory=$true)][byte[]]$Bytes,[Parameter(Mandatory=$true)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,[Parameter(Mandatory=$true)][string]$SchemaDirectory,[Parameter(Mandatory=$true)][string]$JournalRoot,[Parameter(Mandatory=$true)][Net.Http.HttpClient]$Client,[switch]$ConfirmRestrictedSend,[switch]$ConfirmTimezoneRevision,[switch]$ConfirmImRevision)
 $review=Test-TriadeSignedDps -Bytes $Bytes -Certificate $Certificate -SchemaDirectory $SchemaDirectory
 $hash=Get-TriadeXmlHash -Bytes $Bytes
 $directory=Join-Path $JournalRoot $review.identifier
 $null=[IO.Directory]::CreateDirectory($directory)
 $lock=$null;$state=$null;$statePath=Join-Path $directory 'estado.json'
 $phase='ABRIR_HISTORICO';$lastHttp=0;$postPossible=$false
 try{
  $lock=[IO.File]::Open((Join-Path $directory 'processamento.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
  if([IO.File]::Exists($statePath)){
   if(([IO.FileInfo]::new($statePath)).Length -gt 32768){throw 'JOURNAL_INVALID'}
   $state=[IO.File]::ReadAllText($statePath)|ConvertFrom-Json
   if($state.version -ne 1 -or $state.environment -ne 2 -or $state.identifier -ne $review.identifier -or $state.attempted -isnot [bool]){throw 'JOURNAL_CONFLICT'}
   $savedXml=Join-Path $directory 'dps-assinada.xml'
   if(-not [IO.File]::Exists($savedXml) -or ([IO.FileInfo]::new($savedXml)).Length -gt 2097152 -or (Get-TriadeXmlHash -Bytes ([IO.File]::ReadAllBytes($savedXml))) -ne $state.xml_sha256){throw 'JOURNAL_INVALID'}
   if($state.xml_sha256 -ne $hash){
    $phase='CONFERIR_REVISAO'
    if(-not $state.attempted){throw 'TIMEZONE_REVISION_BLOCKED'}
    $responsePath=Join-Path $directory 'resposta-envio.json'
    if(-not [IO.File]::Exists($responsePath) -or ([IO.FileInfo]::new($responsePath)).Length -gt 8388608){throw 'TIMEZONE_REVISION_BLOCKED'}
    $errorBody=Read-TriadeFiscalJson -Response ([PSCustomObject]@{text=[IO.File]::ReadAllText($responsePath)})
    $errors=@($errorBody.erros)
    if($errors.Count -ne 1){throw 'TIMEZONE_REVISION_BLOCKED'}
    $idProperty=$errorBody.PSObject.Properties['idDPS']
    if($null -ne $idProperty -and -not [string]::IsNullOrEmpty([string]$idProperty.Value) -and $idProperty.Value -ne $review.identifier){throw 'RESPONSE_ID'}
    switch -CaseSensitive ($errors[0].codigo){
     'E0008' {$kind='timezone';$registrationName='correcao-fuso.json';$folder='ajuste-fuso';$reason='E0008_TIMEZONE_ONLY';$approved=$ConfirmTimezoneRevision;break}
     'E0120' {$kind='im';$registrationName='correcao-im.json';$folder='ajuste-im';$reason='E0120_IM_ONLY';$approved=$ConfirmImRevision;break}
     default {throw 'TIMEZONE_REVISION_BLOCKED'}
    }
    $registrationPath=Join-Path $directory $registrationName
    $revisionRoot=Join-Path $directory $folder
    if([IO.File]::Exists($registrationPath)){
     # Follow existing revision links BEFORE comparing the candidate against the old rejected payload.
     # This supports E0008 -> E0120 without allowing changes against the wrong ancestor.
     if(([IO.FileInfo]::new($registrationPath)).Length -gt 4096){throw 'JOURNAL_INVALID'}
     $registered=[IO.File]::ReadAllText($registrationPath)|ConvertFrom-Json
     if($registered.previous_sha256 -ne $state.xml_sha256 -or $registered.revised_sha256 -notmatch '^[0-9a-f]{64}$' -or $registered.reason -cne $reason){throw 'JOURNAL_CONFLICT'}
     $childDirectory=Join-Path $revisionRoot $review.identifier
     if($registered.revised_sha256 -ne $hash){
      $childStatePath=Join-Path $childDirectory 'estado.json'
      if(-not [IO.File]::Exists($childStatePath) -or ([IO.FileInfo]::new($childStatePath)).Length -gt 32768){throw 'JOURNAL_CONFLICT'}
      $childState=[IO.File]::ReadAllText($childStatePath)|ConvertFrom-Json
      if($childState.xml_sha256 -ne $registered.revised_sha256){throw 'JOURNAL_CONFLICT'}
     }
     $childXml=Join-Path $childDirectory 'dps-assinada.xml'
     if([IO.File]::Exists($childXml) -and (([IO.FileInfo]::new($childXml)).Length -gt 2097152 -or (Get-TriadeXmlHash -Bytes ([IO.File]::ReadAllBytes($childXml))) -ne $registered.revised_sha256)){throw 'JOURNAL_INVALID'}
     # Parent queries may already have located an authorization; such a path becomes read-only.
     $maySend=$ConfirmRestrictedSend -and $state.status -eq 'Rejeitada em teste'
     return Invoke-TriadeSingleRestrictedDps -Bytes $Bytes -Certificate $Certificate -SchemaDirectory $SchemaDirectory -JournalRoot $revisionRoot -Client $Client -ConfirmRestrictedSend:$maySend -ConfirmTimezoneRevision:$ConfirmTimezoneRevision -ConfirmImRevision:$ConfirmImRevision
    }
    if($state.status -ne 'Rejeitada em teste'){throw 'TIMEZONE_REVISION_BLOCKED'}
    $previous=[IO.File]::ReadAllBytes($savedXml)
    if($kind -eq 'timezone'){
     $phase='CONFERIR_REVISAO_FUSO'
     $change=Test-TriadeTimezoneOnlyRevision -Previous $previous -Revised $Bytes -Certificate $Certificate -SchemaDirectory $SchemaDirectory
    }else{
     $phase='CONFERIR_REVISAO_IM'
     $change=Test-TriadeImOnlyRevision -Previous $previous -Revised $Bytes -Certificate $Certificate -SchemaDirectory $SchemaDirectory
    }
    if(-not $ConfirmRestrictedSend -or -not $approved){
     $result=Get-TriadeRestrictedResult -State $state -Message 'Revisão limitada ao campo indicado pela rejeição. A tentativa anterior será preservada; uma nova tentativa exige confirmação específica.'
     $property=if($kind -eq 'timezone'){'timezone_revision'}else{'im_revision'}
     $result|Add-Member -NotePropertyName $property -NotePropertyValue $change
     return $result
    }
    $phase='CONSULTAR_ANTES_DA_REVISAO'
    $check=Invoke-TriadeFiscalHttp -Client $Client -Request (New-TriadeFiscalRequest -Operation HEAD_DPS -Identifier $review.identifier)
    $lastHttp=$check.status
    if($check.status -ne 404 -or -not [string]::IsNullOrWhiteSpace($check.text)){
     return Get-TriadeRestrictedResult -State $state -HttpStatus $check.status -Message 'Não foi confirmada ausência da DPS. Revisão não enviada; consulte o resultado usando o XML da tentativa anterior.'
    }
    $registration=@{previous_sha256=$state.xml_sha256;revised_sha256=$hash;created_utc=[DateTime]::UtcNow.ToString('o');reason=$reason}|ConvertTo-Json
    Write-TriadeDurableFile -Path $registrationPath -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($registration))
    return Invoke-TriadeSingleRestrictedDps -Bytes $Bytes -Certificate $Certificate -SchemaDirectory $SchemaDirectory -JournalRoot $revisionRoot -Client $Client -ConfirmRestrictedSend
   }
  }else{
   $state=[PSCustomObject]@{version=1;environment=2;identifier=$review.identifier;xml_sha256=$hash;attempted=$false;status='Novo';updated_utc='';access_key='';nfse_sha256=''}
   # Persist the exact signed XML before any fiscal HTTP request.
   $xmlPath=Join-Path $directory 'dps-assinada.xml'
   if([IO.File]::Exists($xmlPath)){
    if((Get-TriadeXmlHash -Bytes ([IO.File]::ReadAllBytes($xmlPath))) -ne $hash){throw 'JOURNAL_CONFLICT'}
   }else{Write-TriadeDurableFile -Path $xmlPath -Bytes $Bytes}
   Save-TriadeRestrictedState -Path $statePath -State $state
  }
  $phase='CONSULTAR_DPS'
  # Always reconcile, including after a previous timeout or a process crash.
  $lookup=Invoke-TriadeFiscalHttp -Client $Client -Request (New-TriadeFiscalRequest -Operation HEAD_DPS -Identifier $review.identifier)
  $lastHttp=$lookup.status;$phase='GRAVAR_CONSULTA'
  Write-TriadeDurableFile -Path (Join-Path $directory 'ultima-consulta.json') -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($lookup.text)) -Replace
  $phase='VALIDAR_CONSULTA'
  if(-not [string]::IsNullOrWhiteSpace($lookup.text)){throw 'RESPONSE_FORMAT'}
  if($lookup.status -eq 200){
   $phase='RECUPERAR_CHAVE_DPS'
   $lookup=Invoke-TriadeFiscalHttp -Client $Client -Request (New-TriadeFiscalRequest -Operation GET_DPS -Identifier $review.identifier)
   $lastHttp=$lookup.status
   Write-TriadeDurableFile -Path (Join-Path $directory 'consulta-chave-dps.json') -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($lookup.text)) -Replace
   if($lookup.status -ne 200){throw 'NFSE_RECOVERY_PENDING'}
   $phase='VALIDAR_CONSULTA'
   $found=Read-TriadeFiscalJson -Response $lookup
   if(-not (Test-TriadeResponseId -Value $found.idDps -Identifier $review.identifier -Key $found.chaveAcesso)){throw 'RESPONSE_ID'}
   $state.status='Localizada; documento pendente';$state.attempted=$true;$state.access_key=$found.chaveAcesso
   Save-TriadeRestrictedState -Path $statePath -State $state
   $phase='CONSULTAR_NFSE'
   $nfse=Invoke-TriadeFiscalHttp -Client $Client -Request (New-TriadeFiscalRequest -Operation GET_NFSE -Identifier $found.chaveAcesso)
   $lastHttp=$nfse.status;$phase='GRAVAR_CONSULTA_NFSE'
   Write-TriadeDurableFile -Path (Join-Path $directory 'resposta-consulta-nfse.json') -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($nfse.text)) -Replace
   if($nfse.status -ne 200){throw 'NFSE_RECOVERY_PENDING'}
   $phase='VALIDAR_NFSE'
   $body=Read-TriadeFiscalJson -Response $nfse
   $state.nfse_sha256=Save-TriadeReturnedNfse -Body $body -Identifier $review.identifier -Key $found.chaveAcesso -Directory $directory -SchemaDirectory $SchemaDirectory -Review $review
   $state.status='Autorizada em teste';Save-TriadeRestrictedState -Path $statePath -State $state
   return Get-TriadeRestrictedResult -State $state -Message 'NFS-e de teste localizada e XML recuperado. Nenhum POST foi realizado nesta execução.' -HttpStatus 200
  }
  if($lookup.status -ne 404){return Get-TriadeRestrictedResult -State $state -Message 'A consulta prévia não confirmou ausência da DPS. Envio bloqueado; confira o HTTP e consulte novamente.' -HttpStatus $lookup.status}
  if($state.attempted){return Get-TriadeRestrictedResult -State $state -Message 'Consulta retornou 404, mas existe tentativa anterior registrada. Reenvio bloqueado; o resultado anterior precisa ser reconciliado.' -HttpStatus 404}
  if(-not $ConfirmRestrictedSend){return Get-TriadeRestrictedResult -State $state -Message 'Consulta retornou 404. Nenhuma tentativa de envio registrada neste PC e nenhum POST realizado.' -HttpStatus 404}
  $phase='PREPARAR_ENVIO'
  $post=New-TriadeFiscalRequest -Operation POST_DPS -Xml $Bytes
  try{
   # Fail closed: this durable marker MUST precede SendAsync. Never reset it after failure.
   $phase='GRAVAR_MARCADOR'
   $state.attempted=$true;$state.status='Situação desconhecida; consultar'
   Save-TriadeRestrictedState -Path $statePath -State $state
   $phase='ENVIAR_DPS';$postPossible=$true;$lastHttp=0
   $response=Invoke-TriadeFiscalHttp -Client $Client -Request $post
  }finally{$post.Dispose()}
  $lastHttp=$response.status;$phase='GRAVAR_RESPOSTA'
  Write-TriadeDurableFile -Path (Join-Path $directory 'resposta-envio.json') -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($response.text)) -Replace
  $phase='VALIDAR_RESPOSTA'
  if($response.status -eq 201){
   $body=Read-TriadeFiscalJson -Response $response
   if(-not (Test-TriadeResponseId -Value $body.idDps -Identifier $review.identifier -Key $body.chaveAcesso)){throw 'RESPONSE_ID'}
   $state.nfse_sha256=Save-TriadeReturnedNfse -Body $body -Identifier $review.identifier -Key $body.chaveAcesso -Directory $directory -SchemaDirectory $SchemaDirectory -Review $review
   $state.access_key=$body.chaveAcesso;$state.status='Autorizada em teste';Save-TriadeRestrictedState -Path $statePath -State $state
   return Get-TriadeRestrictedResult -State $state -Message 'API autorizou a NFS-e em produção restrita. XML original e resposta preservados no PC.' -HttpStatus 201
  }
  if($response.status -eq 400 -or $response.status -eq 403){
   $body=Read-TriadeFiscalJson -Response $response
   if($null -eq $body.erros -or @($body.erros).Count -eq 0){throw 'RESPONSE_FORMAT'}
   $idProperty=$body.PSObject.Properties['idDPS']
   if($null -ne $idProperty -and -not [string]::IsNullOrEmpty([string]$idProperty.Value) -and $idProperty.Value -ne $review.identifier){throw 'RESPONSE_ID'}
   $codes=Get-TriadeFiscalErrorCodes -Body $body
   $state.status='Rejeitada em teste';Save-TriadeRestrictedState -Path $statePath -State $state
   return Get-TriadeRestrictedResult -State $state -Message 'API rejeitou o teste. A resposta detalhada está salva somente no PC. Não há reenvio automático.' -HttpStatus $response.status -ErrorCodes $codes
  }
  return Get-TriadeRestrictedResult -State $state -Message 'Resposta inesperada após a tentativa. Use Consultar resultado; reenvio bloqueado.' -HttpStatus $response.status
 }catch{
  if($null -eq $state){throw}
  # Do not guess whether the request reached the server. The pre-send marker survives exceptions.
  $failure=Get-TriadeRestrictedFailureInfo -Exception $_.Exception -LastHttp $lastHttp
  $result=Get-TriadeRestrictedResult -State $state -HttpStatus $failure.http_status -Message 'Não foi possível concluir a operação. O diagnóstico abaixo identifica a etapa; não apague o histórico nem repita o envio.'
  $result|Add-Member -NotePropertyName diagnostic -NotePropertyValue ([PSCustomObject]@{stage=$phase;reason=$failure.reason;category=$failure.category;codes=$failure.codes;types=$failure.types;post_possible_this_run=$postPossible})
  return $result
 }finally{if($null -ne $lock){$lock.Dispose()}}
}
Export-ModuleMember -Function ConvertTo-TriadeDpsEnvelope,ConvertFrom-TriadeXmlEnvelope,New-TriadeFiscalRequest,Invoke-TriadeSingleRestrictedDps,Get-TriadeDanfse
