#requires -Version 5.1
param($Certificate,[string]$SchemaDirectory,[string]$Directory,[string]$Success)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$sample=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'dps-ficticia.xml'))
$utc=$sample.Replace('2026-11-05T10:00:00-03:00','2026-11-05T13:00:00+00:00')
$previous=Protect-TriadeOfflineDps -Bytes ([Text.Encoding]::UTF8.GetBytes($utc)) -Certificate $Certificate -SchemaDirectory $SchemaDirectory -OwnCnpj '11222333000181'
$normalized=ConvertTo-TriadeBrasiliaDps -Bytes $previous -Certificate $Certificate -SchemaDirectory $SchemaDirectory
$revised=Protect-TriadeOfflineDps -Bytes $normalized -Certificate $Certificate -SchemaDirectory $SchemaDirectory -OwnCnpj '11222333000181'
$change=Test-TriadeTimezoneOnlyRevision -Previous $previous -Revised $revised -Certificate $Certificate -SchemaDirectory $SchemaDirectory
if($change.before -ne '2026-11-05T13:00:00+00:00' -or $change.after -ne '2026-11-05T10:00:00-03:00'){throw 'Conversao mudou o instante.'}
$review=Test-TriadeSignedDps -Bytes $previous -Certificate $Certificate -SchemaDirectory $SchemaDirectory
$error8='{"tipoAmbiente":2,"erros":[{"codigo":"E0008","descricao":"FICTICIO"}]}'
function Run-TimezoneCase($Case,[byte[]]$Xml,[bool]$Send,[bool]$Approve=$false){
 return Invoke-TriadeSingleRestrictedDps -Bytes $Xml -Certificate $Certificate -SchemaDirectory $SchemaDirectory -JournalRoot $Case.root -Client $Case.client -ConfirmRestrictedSend:$Send -ConfirmTimezoneRevision:$Approve
}
$cases=@()
try{
 $case=New-FakeClient 'timezone-revisao' @(404,400,404,404,201,404) @('',$error8,'','',$Success,'');$cases+=$case
 $result=Run-TimezoneCase $case $previous $true
 if($result.state -ne 'Rejeitada em teste'){throw 'Rejeicao E0008 inicial nao preservada.'}
 $parent=Join-Path $case.root $review.identifier
 $oldState=[IO.File]::ReadAllBytes((Join-Path $parent 'estado.json'))
 $oldXml=[IO.File]::ReadAllBytes((Join-Path $parent 'dps-assinada.xml'))
 $oldResponse=[IO.File]::ReadAllBytes((Join-Path $parent 'resposta-envio.json'))
 $result=Run-TimezoneCase $case $revised $true
 if($null -eq $result.PSObject.Properties['timezone_revision'] -or $case.handler.Calls.Count -ne 2){throw 'Revisao executada sem confirmacao especifica.'}
 $result=Run-TimezoneCase $case $revised $false
 if($case.handler.Calls.Count -ne 2){throw 'Consulta registrou revisao sem aprovacao.'}
 $child=Join-Path (Join-Path $parent 'ajuste-fuso') $review.identifier
 $case.handler.Marker=Join-Path $child 'estado.json'
 $result=Run-TimezoneCase $case $revised $true $true
 if($result.state -ne 'Autorizada em teste'){throw ('Revisao valida nao concluiu: '+($result|ConvertTo-Json -Depth 5 -Compress))}
 foreach($pair in @(@{name='estado.json';bytes=$oldState},@{name='dps-assinada.xml';bytes=$oldXml},@{name='resposta-envio.json';bytes=$oldResponse})){
  if([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $parent $pair.name))) -ne [Convert]::ToBase64String($pair.bytes)){throw 'Historico original foi alterado.'}
 }
 $null=Run-TimezoneCase $case $revised $true
 if(@($case.handler.Calls|Where-Object{$_ -match '^POST '}).Count -ne 2){throw 'Revisao foi reenviada.'}
 $case=New-FakeClient 'timezone-alteracoes' @(404,400) @('',$error8);$cases+=$case
 $null=Run-TimezoneCase $case $previous $true
 foreach($pair in @(@{from='<vServ>10.00</vServ>';to='<vServ>11.00</vServ>'},@{from='10:00:00-03:00';to='10:01:00-03:00'},@{from='<dCompet>2026-11-05</dCompet>';to='<dCompet>2026-11-04</dCompet>'})){
  $changed=([Text.Encoding]::UTF8.GetString($normalized)).Replace($pair.from,$pair.to)
  $other=Protect-TriadeOfflineDps -Bytes ([Text.Encoding]::UTF8.GetBytes($changed)) -Certificate $Certificate -SchemaDirectory $SchemaDirectory -OwnCnpj '11222333000181'
  $result=Run-TimezoneCase $case $other $true $true
  if($result.diagnostic.reason -ne 'TIMEZONE_REVISION_INVALID' -or $case.handler.Calls.Count -ne 2){throw 'Alteracao fiscal foi aceita como ajuste de fuso.'}
 }
 $case=New-FakeClient 'timezone-erro-diferente' @(404,400) @('','{"tipoAmbiente":2,"erros":[{"codigo":"FICTICIO"}]}');$cases+=$case
 $null=Run-TimezoneCase $case $previous $true;$result=Run-TimezoneCase $case $revised $true $true
 if($result.diagnostic.reason -ne 'TIMEZONE_REVISION_BLOCKED' -or $case.handler.Calls.Count -ne 2){throw 'Outro erro habilitou revisao de fuso.'}
 $case=New-FakeClient 'timezone-existente' @(404,400,200) @('',$error8,'');$cases+=$case
 $null=Run-TimezoneCase $case $previous $true;$result=Run-TimezoneCase $case $revised $true $true
 if($result.http_status -ne 200 -or @($case.handler.Calls|Where-Object{$_ -match '^POST '}).Count -ne 1){throw 'Revisao enviada sem confirmar ausencia.'}
 $case=New-FakeClient 'timezone-timeout' @(404,400,404,404,404) @('',$error8,'','','');$cases+=$case
 $null=Run-TimezoneCase $case $previous $true
 $case.handler.TimeoutOnPost=$true;$case.handler.Marker=Join-Path (Join-Path (Join-Path (Join-Path $case.root $review.identifier) 'ajuste-fuso') $review.identifier) 'estado.json'
 $result=Run-TimezoneCase $case $revised $true $true
 if($result.state -ne 'Situação desconhecida; consultar'){throw 'Timeout na revisao nao foi preservado.'}
 $null=Run-TimezoneCase $case $revised $true
 if(@($case.handler.Calls|Where-Object{$_ -match '^POST '}).Count -ne 2){throw 'Timeout na revisao gerou reenvio.'}
 Write-Output 'PASS: fuso preserva instante, E0008 com confirmacao especifica, historico original intacto, bloqueio de mudanca fiscal, outro erro, DPS existente e reenvio apos timeout. Transporte ficticio.'
}finally{foreach($case in $cases){$case.client.Dispose()}}
