#requires -Version 5.1
param($Certificate,[string]$SchemaDirectory,[string]$Directory,[string]$Success)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$sample=[IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'dps-ficticia.xml'))
$withIm=Read-TriadeDps -Bytes $sample -SchemaDirectory $SchemaDirectory
$ns=[Xml.XmlNamespaceManager]::new($withIm.NameTable);$ns.AddNamespace('n','http://www.sped.fazenda.gov.br/nfse')
$prest=$withIm.SelectSingleNode('/n:DPS/n:infDPS/n:prest',$ns)
$im=$withIm.CreateElement('IM','http://www.sped.fazenda.gov.br/nfse');$im.InnerText='1234567'
$null=$prest.InsertBefore($im,$prest.SelectSingleNode('n:regTrib',$ns))
$previous=Protect-TriadeOfflineDps -Bytes ([Text.Encoding]::UTF8.GetBytes($withIm.OuterXml)) -Certificate $Certificate -SchemaDirectory $SchemaDirectory -OwnCnpj '11222333000181'
$unsigned=ConvertTo-TriadeDpsWithoutIm -Bytes $previous -Certificate $Certificate -SchemaDirectory $SchemaDirectory
$revised=Protect-TriadeOfflineDps -Bytes $unsigned -Certificate $Certificate -SchemaDirectory $SchemaDirectory -OwnCnpj '11222333000181'
$null=Test-TriadeImOnlyRevision -Previous $previous -Revised $revised -Certificate $Certificate -SchemaDirectory $SchemaDirectory
$review=Test-TriadeSignedDps -Bytes $previous -Certificate $Certificate -SchemaDirectory $SchemaDirectory
$error120='{"tipoAmbiente":2,"erros":[{"codigo":"E0120","descricao":"FICTICIO"}]}'
$error8='{"tipoAmbiente":2,"erros":[{"codigo":"E0008","descricao":"FICTICIO"}]}'
function Run-ImCase($Case,[byte[]]$Xml,[bool]$Send,[bool]$Approve=$false){
 return Invoke-TriadeSingleRestrictedDps -Bytes $Xml -Certificate $Certificate -SchemaDirectory $SchemaDirectory -JournalRoot $Case.root -Client $Case.client -ConfirmRestrictedSend:$Send -ConfirmImRevision:$Approve
}
function Check-Unchanged($Path,[byte[]]$Expected){
 if([Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) -ne [Convert]::ToBase64String($Expected)){throw 'Historico de IM alterado.'}
}
$cases=@()
try{
 $case=New-FakeClient 'im-revisao' @(404,400,404,404,201,404) @('',$error120,'','',$Success,'');$cases+=$case
 $null=Run-ImCase $case $previous $true
 $parent=Join-Path $case.root $review.identifier
 $oldState=[IO.File]::ReadAllBytes((Join-Path $parent 'estado.json'));$oldXml=[IO.File]::ReadAllBytes((Join-Path $parent 'dps-assinada.xml'));$oldResponse=[IO.File]::ReadAllBytes((Join-Path $parent 'resposta-envio.json'))
 $result=Run-ImCase $case $revised $true
 if($null -eq $result.PSObject.Properties['im_revision'] -or $case.handler.Calls.Count -ne 2){throw 'IM nao exige aprovacao especifica.'}
 $null=Run-ImCase $case $revised $false
 if($case.handler.Calls.Count -ne 2){throw 'Consulta registrou revisao de IM.'}
 $child=Join-Path (Join-Path $parent 'ajuste-im') $review.identifier;$case.handler.Marker=Join-Path $child 'estado.json'
 $result=Run-ImCase $case $revised $true $true
 if($result.state -ne 'Autorizada em teste'){throw ('IM omitida nao concluiu: '+($result|ConvertTo-Json -Depth 5 -Compress))}
 Check-Unchanged (Join-Path $parent 'estado.json') $oldState;Check-Unchanged (Join-Path $parent 'dps-assinada.xml') $oldXml;Check-Unchanged (Join-Path $parent 'resposta-envio.json') $oldResponse
 $null=Run-ImCase $case $revised $true
 if(@($case.handler.Calls|Where-Object{$_ -match '^POST '}).Count -ne 2){throw 'IM foi reenviada.'}
 $case=New-FakeClient 'im-campos' @(404,400) @('',$error120);$cases+=$case;$null=Run-ImCase $case $previous $true
 foreach($pair in @(@{from='<vServ>10.00</vServ>';to='<vServ>11.00</vServ>'},@{from='10:00:00-03:00';to='10:01:00-03:00'},@{from='<dCompet>2026-11-05</dCompet>';to='<dCompet>2026-11-04</dCompet>'})){
  $changed=([Text.Encoding]::UTF8.GetString($unsigned)).Replace($pair.from,$pair.to)
  $other=Protect-TriadeOfflineDps -Bytes ([Text.Encoding]::UTF8.GetBytes($changed)) -Certificate $Certificate -SchemaDirectory $SchemaDirectory -OwnCnpj '11222333000181'
  $result=Run-ImCase $case $other $true $true
  if($result.diagnostic.reason -ne 'IM_REVISION_INVALID' -or $case.handler.Calls.Count -ne 2){throw 'IM permitiu alterar outros campos.'}
 }
 # Reproduce the operator's chain: UTC/E0008 -> -03/E0120 -> no IM, same IdDPS.
 $utcXml=$withIm.OuterXml.Replace('2026-11-05T10:00:00-03:00','2026-11-05T13:00:00+00:00')
 $utc=Protect-TriadeOfflineDps -Bytes ([Text.Encoding]::UTF8.GetBytes($utcXml)) -Certificate $Certificate -SchemaDirectory $SchemaDirectory -OwnCnpj '11222333000181'
 $case=New-FakeClient 'im-apos-fuso' @(404,400,404,404,400,404,404,201,404) @('',$error8,'','',$error120,'','',$Success,'');$cases+=$case
 $null=Run-ImCase $case $utc $true
 $parent=Join-Path $case.root $review.identifier;$fuso=Join-Path (Join-Path $parent 'ajuste-fuso') $review.identifier
 $case.handler.Marker=Join-Path $fuso 'estado.json'
 $null=Invoke-TriadeSingleRestrictedDps -Bytes $previous -Certificate $Certificate -SchemaDirectory $SchemaDirectory -JournalRoot $case.root -Client $case.client -ConfirmRestrictedSend -ConfirmTimezoneRevision
 $oldRoot=[IO.File]::ReadAllBytes((Join-Path $parent 'estado.json'));$oldFuso=[IO.File]::ReadAllBytes((Join-Path $fuso 'estado.json'))
 $result=Run-ImCase $case $revised $true
 if($null -eq $result.PSObject.Properties['im_revision'] -or $case.handler.Calls.Count -ne 5){throw 'Cadeia de fuso nao encaminhou revisao para E0120.'}
 $leaf=Join-Path (Join-Path $fuso 'ajuste-im') $review.identifier;$case.handler.Marker=Join-Path $leaf 'estado.json'
 $result=Run-ImCase $case $revised $true $true
 if($result.state -ne 'Autorizada em teste'){throw ('Cadeia E0008/E0120 falhou: '+($result|ConvertTo-Json -Depth 5 -Compress))}
 Check-Unchanged (Join-Path $parent 'estado.json') $oldRoot;Check-Unchanged (Join-Path $fuso 'estado.json') $oldFuso
 $null=Run-ImCase $case $revised $true
 if(@($case.handler.Calls|Where-Object{$_ -match '^POST '}).Count -ne 3){throw 'Cadeia E0008/E0120 reenviou documento.'}
 $case=New-FakeClient 'im-timeout' @(404,400,404,404,404) @('',$error120,'','','');$cases+=$case;$null=Run-ImCase $case $previous $true
 $case.handler.TimeoutOnPost=$true;$case.handler.Marker=Join-Path (Join-Path (Join-Path (Join-Path $case.root $review.identifier) 'ajuste-im') $review.identifier) 'estado.json'
 $result=Run-ImCase $case $revised $true $true
 if($result.state -ne 'Situação desconhecida; consultar'){throw 'Timeout de IM nao preservado.'}
 $null=Run-ImCase $case $revised $true
 if(@($case.handler.Calls|Where-Object{$_ -match '^POST '}).Count -ne 2){throw 'Timeout IM foi reenviado.'}
 $case=New-FakeClient 'im-existente' @(404,400,200) @('',$error120,'');$cases+=$case;$null=Run-ImCase $case $previous $true
 $result=Run-ImCase $case $revised $true $true
 if($result.http_status -ne 200 -or @($case.handler.Calls|Where-Object{$_ -match '^POST '}).Count -ne 1){throw 'IM enviada sem confirmar ausencia.'}
 Write-Output 'PASS: E0120 omite somente IM, exige confirmacao e HEAD 404, preserva arquivos originais, bloqueia alteracoes e reenvios, e encadeia E0008/E0120 com transporte ficticio.'
}finally{foreach($case in $cases){$case.client.Dispose()}}
