#requires -Version 5.1
param([switch]$SelfTest,[string]$Url,[switch]$RegisterProtocol)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Este conector requer Windows.' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot 'TriadeConnector.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'TriadeDps.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'TriadeRestricted.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'TriadeSite.psm1') -Force
[Windows.Forms.Application]::EnableVisualStyles()
$script:selectedCertificate = $null
$script:lastSummary = ''
$form = [Windows.Forms.Form]::new()
$form.Text = 'Tríade NFS-e | Conector local 0.10.1'
$form.ClientSize = [Drawing.Size]::new(720,705)
$form.MinimumSize = [Drawing.Size]::new(736,744)
$form.StartPosition = 'CenterScreen'
$form.Font = [Drawing.Font]::new('Segoe UI',10)
$form.BackColor = [Drawing.Color]::FromArgb(245,248,246)
function Add-Label([string]$Text,[int]$Top,[int]$Height=35) {
    $label=[Windows.Forms.Label]::new();$label.Text=$Text;$label.SetBounds(22,$Top,675,$Height);$form.Controls.Add($label);return $label
}
$null=Add-Label 'Certificado e senha permanecem neste computador' 18 30
$null=Add-Label 'Produção restrita: assinatura local e envio unitário com confirmação. Produção real bloqueada.' 53 45
$windowsButton=[Windows.Forms.Button]::new();$windowsButton.Text='Selecionar certificado do Windows';$windowsButton.SetBounds(22,105,330,38);$form.Controls.Add($windowsButton)
$selection=Add-Label 'Nenhum certificado selecionado.' 150 45
$protocolButton=[Windows.Forms.Button]::new();$protocolButton.Text='Ativar abertura pelo site';$protocolButton.SetBounds(367,105,330,38);$form.Controls.Add($protocolButton)
$null=Add-Label 'Ou use um arquivo A1 local (.pfx/.p12), sem instalar a chave:' 203 30
$fileBox=[Windows.Forms.TextBox]::new();$fileBox.ReadOnly=$true;$fileBox.SetBounds(22,237,555,28);$form.Controls.Add($fileBox)
$fileButton=[Windows.Forms.Button]::new();$fileButton.Text='Selecionar A1';$fileButton.SetBounds(585,234,112,34);$form.Controls.Add($fileButton)
$null=Add-Label 'Senha do arquivo A1 (somente neste PC):' 278 27
$password=[Windows.Forms.TextBox]::new();$password.UseSystemPasswordChar=$true;$password.SetBounds(22,309,675,28);$form.Controls.Add($password)
$network=[Windows.Forms.CheckBox]::new();$network.Text='Testar conexão com a documentação oficial da produção restrita';$network.SetBounds(22,350,675,28);$form.Controls.Add($network)
$null=Add-Label 'Na conexão, o certificado público é apresentado ao governo. A chave privada e a senha não são enviadas. HTTP 200 não comprova permissão para emitir.' 383 53
$run=[Windows.Forms.Button]::new();$run.Text='Verificar';$run.SetBounds(22,444,160,38);$form.Controls.Add($run)
$copy=[Windows.Forms.Button]::new();$copy.Text='Copiar resultado';$copy.Enabled=$false;$copy.SetBounds(196,444,185,38);$form.Controls.Add($copy)
$saveApi=[Windows.Forms.Button]::new();$saveApi.Text='Salvar OpenAPI';$saveApi.SetBounds(397,444,170,38);$form.Controls.Add($saveApi)
$apiProbe=[Windows.Forms.Button]::new();$apiProbe.Text='Testar API';$apiProbe.SetBounds(580,444,117,38);$form.Controls.Add($apiProbe)
$output=[Windows.Forms.TextBox]::new();$output.Multiline=$true;$output.ReadOnly=$true;$output.ScrollBars='Vertical';$output.SetBounds(22,550,675,130);$form.Controls.Add($output)

$signDps=[Windows.Forms.Button]::new();$signDps.Text='Assinar / preparar XML';$signDps.SetBounds(22,495,210,38);$form.Controls.Add($signDps)
$sendDps=[Windows.Forms.Button]::new();$sendDps.Text='Enviar 1 DPS de teste';$sendDps.SetBounds(245,495,225,38);$form.Controls.Add($sendDps)
$consultDps=[Windows.Forms.Button]::new();$consultDps.Text='Consultar resultado';$consultDps.SetBounds(482,495,215,38);$form.Controls.Add($consultDps)
function Invoke-TriadeDpsAction([bool]$Send) {
 if($null -eq $script:selectedCertificate){$output.Text='Selecione o certificado instalado do próprio escritório.';return}
 $dialog=[Windows.Forms.OpenFileDialog]::new();$dialog.Filter='DPS assinada (*.xml)|*.xml';$dialog.Title='Escolha a DPS de teste já assinada'
 $bytes=$null;$handler=$null;$client=$null
 try{
  if($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK){return}
  if(([IO.FileInfo]::new($dialog.FileName)).Length -gt 2097152){throw 'XML_SIZE'}
  $bytes=[IO.File]::ReadAllBytes($dialog.FileName)
  $schema=Join-Path $PSScriptRoot 'schemas'
  $review=Test-TriadeSignedDps -Bytes $bytes -Certificate $script:selectedCertificate -SchemaDirectory $schema
  $message=@(('Emitente: '+$review.cnpj),('Tomador: '+$review.recipient),('Competência: '+$review.competence),('Valor: R$ '+$review.amount),('DPS: '+$review.identifier),'Confirme que o emitente é o próprio escritório e os dados/tributos foram conferidos.','A chave privada e a senha permanecem no Windows. O certificado público e dados fiscais são apresentados à API oficial de testes.')
  if($Send){$message+=@('AUTORIZA CRIAR UMA ÚNICA NFS-e EM PRODUÇÃO RESTRITA?','O conector consultará o identificador primeiro. Tentativas anteriores impedem novo envio. Produção real bloqueada.')}
  else{$message+='A ação fará somente consultas. Nenhuma DPS será enviada.'}
  if([Windows.Forms.MessageBox]::Show($form,($message -join [Environment]::NewLine),'Tríade | '+$(if($Send){'Confirmar envio de teste'}else{'Somente consulta'}),[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning,[Windows.Forms.MessageBoxDefaultButton]::Button2) -ne [Windows.Forms.DialogResult]::Yes){return}
  $local=[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
  if([string]::IsNullOrWhiteSpace($local)){throw 'LOCAL_DATA_UNAVAILABLE'}
  $journal=Join-Path $local 'TriadeNfse\Conector\producao-restrita'
  $form.Enabled=$false;$form.UseWaitCursor=$true;$output.Text='Conferindo histórico e consultando a produção restrita...';$form.Refresh()
  $handler=New-TriadeRestrictedHandler -Certificate $script:selectedCertificate
  $client=[Net.Http.HttpClient]::new($handler);$client.Timeout=[TimeSpan]::FromSeconds(35)
  $result=Invoke-TriadeSingleRestrictedDps -Bytes $bytes -Certificate $script:selectedCertificate -SchemaDirectory $schema -JournalRoot $journal -Client $client -ConfirmRestrictedSend:$Send
  $kind='timezone';$revision=$result.PSObject.Properties['timezone_revision']
  if($null -eq $revision){$kind='im';$revision=$result.PSObject.Properties['im_revision']}
  if($Send -and $null -ne $revision){
   $form.Enabled=$true;$form.UseWaitCursor=$false
   $change=$revision.Value
   if($kind -eq 'im'){
    $intro='A tentativa anterior foi rejeitada com E0120. Esta revisão omite somente a inscrição municipal deste XML, mantendo cadastro, instante e demais campos.'
   }else{$intro='A tentativa anterior foi rejeitada com E0008. Esta revisão muda somente a representação do fuso, mantendo o instante e os demais campos.'}
   $question=@($intro,('Antes: '+$change.before),('Depois: '+$change.after),'Autoriza UMA tentativa corrigida em produção restrita, após consulta de ausência?','XMLs, respostas e marcadores das tentativas anteriores serão preservados. O cadastro da empresa não será alterado.') -join [Environment]::NewLine
   if([Windows.Forms.MessageBox]::Show($form,$question,'Tríade | Autorizar revisão de teste',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning,[Windows.Forms.MessageBoxDefaultButton]::Button2) -eq [Windows.Forms.DialogResult]::Yes){
    $form.Enabled=$false;$form.UseWaitCursor=$true
    $result=Invoke-TriadeSingleRestrictedDps -Bytes $bytes -Certificate $script:selectedCertificate -SchemaDirectory $schema -JournalRoot $journal -Client $client -ConfirmRestrictedSend -ConfirmTimezoneRevision:($kind -eq 'timezone') -ConfirmImRevision:($kind -eq 'im')
   }
  }
  $lines=@('Tríade NFS-e | teste unitário 0.8.5','Ambiente: produção restrita.',('Situação: '+$result.state),$result.message)
  if($result.http_status -gt 0){$lines+=('HTTP '+$result.http_status)}
  $diagnostic=$result.PSObject.Properties['diagnostic']
  if($null -ne $diagnostic){
   $d=$diagnostic.Value
   $lines+=@(('Etapa: '+$d.stage),('Motivo: '+$d.reason),('Categoria: '+$d.category),('Códigos técnicos: '+$d.codes),('Tipos: '+$d.types))
   if($d.post_possible_this_run){$lines+='Uma tentativa de POST pode ter sido iniciada nesta execução. Use somente Consultar resultado.'}
   else{$lines+='Nenhum POST iniciado nesta execução. Isso não descarta tentativas anteriores; mantenha o histórico.'}
  }
  if(-not [string]::IsNullOrWhiteSpace($result.codes)){$lines+=('Códigos da API: '+$result.codes)}
  $lines+=@('Histórico e respostas ficam neste PC, em LocalAppData\TriadeNfse\Conector\producao-restrita. Não apague essa pasta para tentar novamente.','O site não foi atualizado. Produção real continua bloqueada.')
  $script:lastSummary=$lines -join [Environment]::NewLine;$output.Text=$script:lastSummary;$copy.Enabled=$true
 }catch{
  $failure=Get-TriadeConnectionFailure -Exception $_.Exception
  $script:lastSummary=@('Operação de teste não concluída. Confira XML assinado, certificado do emitente e acesso à pasta local.',('Códigos técnicos: '+$failure.codes),'Se houve tentativa anterior, use Consultar resultado. Não repita o envio nem apague o histórico. Produção real bloqueada.') -join [Environment]::NewLine
  $output.Text=$script:lastSummary;$copy.Enabled=$true
 }finally{
  $dialog.Dispose();if($null -ne $client){$client.Dispose()}elseif($null -ne $handler){$handler.Dispose()}
  if($null -ne $bytes){[Array]::Clear($bytes,0,$bytes.Length)}
  $form.Enabled=$true;$form.UseWaitCursor=$false
 }
}
$sendDps.Add_Click({Invoke-TriadeDpsAction -Send $true})
$consultDps.Add_Click({Invoke-TriadeDpsAction -Send $false})
$signDps.Add_Click({
    if($null -eq $script:selectedCertificate){$output.Text='Selecione o certificado instalado no Windows para a assinatura offline.';return}
    $open=[Windows.Forms.OpenFileDialog]::new();$open.Filter='DPS XML (*.xml)|*.xml';$open.Title='Abrir prévia de DPS do próprio escritório'
    $save=$null;$bytes=$null;$signedBytes=$null;$unsigned=$null
    try {
        if($open.ShowDialog() -ne [Windows.Forms.DialogResult]::OK){return}
        if(([IO.FileInfo]::new($open.FileName)).Length -gt 2097152){throw 'XML_SIZE'}
        $bytes=[IO.File]::ReadAllBytes($open.FileName)
        $xml=Read-TriadeDps -Bytes $bytes -SchemaDirectory (Join-Path $PSScriptRoot 'schemas')
        $review=Get-TriadeDpsReview -Document $xml
        $omitIm=$false
        $im=$xml.SelectSingleNode('/*[local-name()="DPS"]/*[local-name()="infDPS"]/*[local-name()="prest"]/*[local-name()="IM"]')
        if($null -ne $im){
            $answer=[Windows.Forms.MessageBox]::Show($form,'Omitir a inscrição municipal SOMENTE desta cópia XML para atender à rejeição E0120? Selecione Sim apenas para essa correção; Não mantém a inscrição. O cadastro da empresa permanece intacto.','Tríade | Inscrição municipal',[Windows.Forms.MessageBoxButtons]::YesNoCancel,[Windows.Forms.MessageBoxIcon]::Question,[Windows.Forms.MessageBoxDefaultButton]::Button2)
            if($answer -eq [Windows.Forms.DialogResult]::Cancel){return}
            $omitIm=$answer -eq [Windows.Forms.DialogResult]::Yes
        }
        if($omitIm){$unsigned=ConvertTo-TriadeDpsWithoutIm -Bytes $bytes -Certificate $script:selectedCertificate -SchemaDirectory (Join-Path $PSScriptRoot 'schemas')}
        else{$unsigned=ConvertTo-TriadeBrasiliaDps -Bytes $bytes -Certificate $script:selectedCertificate -SchemaDirectory (Join-Path $PSScriptRoot 'schemas')}
        $imSummary=if($omitIm){'IM omitida somente deste XML. Horário original preservado.'}else{'IM preservada; fuso expresso em -03:00, mantendo o mesmo instante.'}
        $normalizedXml=Read-TriadeDps -Bytes $unsigned -SchemaDirectory (Join-Path $PSScriptRoot 'schemas')
        $beforeTime=$xml.GetElementsByTagName('dhEmi','http://www.sped.fazenda.gov.br/nfse')[0].InnerText
        $afterTime=$normalizedXml.GetElementsByTagName('dhEmi','http://www.sped.fazenda.gov.br/nfse')[0].InnerText
        $message=@('Assinar somente no PC, sem envio à API? A assinatura existente foi conferida antes do preparo.',$imSummary,('Emitente: '+$review.cnpj),('Tomador: '+$review.recipient),('Competência: '+$review.competence),('Valor: R$ '+$review.amount),('Horário original: '+$beforeTime),('Horário normalizado: '+$afterTime),'Confirme que este emitente é o próprio escritório, titular do certificado selecionado.','O arquivo assinado contém dados fiscais e o certificado público. A chave privada permanece no Windows.','Perfil XMLDSIG do manual integrado: aceitação na API de testes ainda não validada.') -join [Environment]::NewLine
        if([Windows.Forms.MessageBox]::Show($form,$message,'Tríade | Assinatura offline',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Information) -ne [Windows.Forms.DialogResult]::Yes){return}
        $signedBytes=Protect-TriadeOfflineDps -Bytes $unsigned -Certificate $script:selectedCertificate -SchemaDirectory (Join-Path $PSScriptRoot 'schemas') -OwnCnpj $review.cnpj
        $save=[Windows.Forms.SaveFileDialog]::new();$save.Filter='DPS XML (*.xml)|*.xml';$save.FileName='DPS_Teste_Assinada_Revisada.xml';$save.Title='Salvar em novo arquivo local'
        if($save.ShowDialog() -ne [Windows.Forms.DialogResult]::OK){return}
        # CreateNew protects the original XML and any existing file.
        $file=[IO.File]::Open($save.FileName,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$file.Write($signedBytes,0,$signedBytes.Length)}finally{$file.Dispose()}
        $script:lastSummary=@('Tríade NFS-e | preparação local 0.8.5','XML de produção restrita validado no XSD recebido.','Assinatura criada e integridade criptográfica conferida localmente.','CNPJ do prestador confere com o OID CNPJ do certificado.','Não foram validados cadeia ICP-Brasil, revogação, credenciamento ou aceitação da assinatura na API.','Arquivo salvo somente no PC. Nenhuma DPS enviada. Produção continua bloqueada.') -join [Environment]::NewLine
        $output.Text=$script:lastSummary;$copy.Enabled=$true
    } catch {
        $code='OFFLINE_PREPARATION_FAILED'
        foreach($candidate in @('IM_REVISION_INVALID','XML_SIZE','XML_ROOT','XML_ID','RESTRICTED_OWN_ONLY','OWN_CNPJ_REQUIRED','ALREADY_SIGNED','CERT_CNPJ_MISMATCH','RSA_REQUIRED','SIGNATURE_CHECK_FAILED')){
            $exception=$_.Exception
            for($i=0;$i -lt 6 -and $null -ne $exception;$i++){if($exception.Message -eq $candidate){$code=$candidate};$exception=$exception.InnerException}
        }
        $script:lastSummary='Não foi possível preparar a DPS. Código: '+$code+'. Confira se é XML de testes válido, se o certificado pertence ao emitente e se o destino é um arquivo novo. Nenhuma DPS enviada.'
        $output.Text=$script:lastSummary;$copy.Enabled=$true
    } finally {
        $open.Dispose();if($null -ne $save){$save.Dispose()}
        if($null -ne $bytes){[Array]::Clear($bytes,0,$bytes.Length)}
        if($null -ne $signedBytes){[Array]::Clear($signedBytes,0,$signedBytes.Length)}
        if($null -ne $unsigned){[Array]::Clear($unsigned,0,$unsigned.Length)}
    }
})
$windowsButton.Add_Click({
    $available=$null;$picked=$null;$phase='leitura do repositório CurrentUser/My'
    try {
        $available=Get-TriadeWindowsCertificates
        if ($available.Count -eq 0) {
            $script:lastSummary='Nenhum certificado com chave privada foi encontrado em Pessoal do usuário atual. Confira com Win+R > certmgr.msc > Pessoal > Certificados. Ter o arquivo A1 no PC não significa que esteja instalado no Windows. Nenhum certificado foi enviado.'
            $output.Text=$script:lastSummary;$copy.Enabled=$true
            return
        }
        $phase='janela de seleção do Windows'
        $picked=[Security.Cryptography.X509Certificates.X509Certificate2UI]::SelectFromCollection($available,'Tríade NFS-e','Selecione o certificado do escritório. Ele permanece no Windows.',[Security.Cryptography.X509Certificates.X509SelectionFlag]::SingleSelection,$form.Handle)
        if ($picked.Count -gt 0) {
            $phase='seleção do certificado'
            $newSelection=[Security.Cryptography.X509Certificates.X509Certificate2]::new($picked[0])
            if ($null -ne $script:selectedCertificate) { $script:selectedCertificate.Dispose() }
            $script:selectedCertificate=$newSelection
            $selection.Text='Certificado do Windows selecionado. Validade: '+$script:selectedCertificate.NotAfter.ToString('dd/MM/yyyy')
            $fileBox.Clear();$password.Clear();$output.Clear();$copy.Enabled=$false
        }
    } catch {
        $failure=Get-TriadeConnectionFailure -Exception $_.Exception
        $script:lastSummary=@('Falha ao selecionar certificado do Windows.',('Etapa: '+$phase),('Códigos: '+$failure.codes),('Tipos: '+$failure.types),'Nenhum certificado foi enviado; nenhuma permissão foi alterada.') -join [Environment]::NewLine
        $output.Text=$script:lastSummary;$copy.Enabled=$true
    } finally {
        if ($null -ne $available) { foreach($certificate in $available) { $certificate.Dispose() } }
    }
})
$fileButton.Add_Click({
    $dialog=[Windows.Forms.OpenFileDialog]::new();$dialog.Title='Selecionar A1 local';$dialog.Filter='Certificado A1 (*.pfx;*.p12)|*.pfx;*.p12';$dialog.CheckFileExists=$true
    try { if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
        if ($null -ne $script:selectedCertificate) { $script:selectedCertificate.Dispose();$script:selectedCertificate=$null }
        $fileBox.Text=$dialog.FileName;$selection.Text='Modo A1 temporário. Nenhuma chave será instalada pelo conector.';$password.Clear();$output.Clear();$copy.Enabled=$false
    } } finally { $dialog.Dispose() }
})
$run.Add_Click({
    $run.Enabled=$false;$windowsButton.Enabled=$false;$fileButton.Enabled=$false;$form.UseWaitCursor=$true;$copy.Enabled=$false;$output.Text='Verificando...';$form.Refresh()
    $temporary=$null;$secure=$null
    try {
        $active=$script:selectedCertificate
        if ($null -eq $active) {
            if ([String]::IsNullOrWhiteSpace($fileBox.Text) -or $password.Text.Length -eq 0) { throw 'Selecione um certificado do Windows ou informe arquivo A1 e senha.' }
            $secure=[Security.SecureString]::new();foreach($character in $password.Text.ToCharArray()) { $secure.AppendChar($character) };$secure.MakeReadOnly();$password.Clear()
            $temporary=Import-TriadeLocalA1 -Path $fileBox.Text -Password $secure;$active=$temporary
        }
        $check=Get-TriadeCertificateCheck -Certificate $active
        $lines=@('Tríade NFS-e | diagnóstico local 0.8.5',('Arquivo/chave presentes e certificado dentro da validade. Vencimento: '+$check.expires_on))
        if ($null -ne $temporary) { $lines+='Origem: arquivo A1 temporário (chave efêmera).' } else { $lines+='Origem: certificado instalado no Windows.' }
        $lines+=('PowerShell: '+$PSVersionTable.PSVersion.ToString()+' | .NET: '+[Environment]::Version.ToString())
        if ($network.Checked) {
            $probe=Invoke-TriadeRestrictedProbe -Certificate $active
            if ($null -ne $probe.http_status) { $lines+=('HTTP '+$probe.http_status) }
            $lines+=$probe.message
            if ($null -ne $probe.failure) { $lines+=('Categoria: '+$probe.failure.category+' | Códigos: '+$probe.failure.codes);$lines+=('Tipos: '+$probe.failure.types) }
        } else { $lines+='Sem conexão externa: apenas verificação local.' }
        $lines+='Nenhuma DPS enviada. Cadeia ICP-Brasil, revogação, procuração e credenciamento não foram validados.'
        $script:lastSummary=$lines -join [Environment]::NewLine;$output.Text=$script:lastSummary;$copy.Enabled=$true
    } catch { $script:lastSummary='Diagnóstico não concluído. Confira seleção, senha, validade e compatibilidade do Windows. Nenhum envio fiscal foi realizado.';$output.Text=$script:lastSummary;$copy.Enabled=$true }
    finally {
        $password.Clear();if ($null -ne $secure) { $secure.Dispose() };if ($null -ne $temporary) { $temporary.Dispose() }
        $form.UseWaitCursor=$false;$run.Enabled=$true;$windowsButton.Enabled=$true;$fileButton.Enabled=$true
    }
})
$apiProbe.Add_Click({
    if ($null -eq $script:selectedCertificate) { $output.Text='Selecione o certificado instalado no Windows para este teste da API.';return }
    $answer=[Windows.Forms.MessageBox]::Show($form,'Consultar a rota HEAD /dps com identificador de diagnóstico inválido, em produção restrita? Isso não envia DPS e não consulta uma nota real.','Tríade | Teste somente de leitura',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Information)
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
    $apiProbe.Enabled=$false;$saveApi.Enabled=$false;$run.Enabled=$false;$windowsButton.Enabled=$false;$fileButton.Enabled=$false;$form.UseWaitCursor=$true;$output.Text='Consultando rota de diagnóstico...';$form.Refresh()
    try {
        $probe=Invoke-TriadeRestrictedApiProbe -Certificate $script:selectedCertificate
        $lines=@('Tríade NFS-e | teste API somente de leitura 0.8.5','Ambiente: produção restrita. Origem: certificado instalado no Windows.','Método: HEAD /dps/diagnostico-local (identificador intencionalmente inválido).')
        if ($null -ne $probe.http_status) { $lines+=('HTTP '+$probe.http_status) };$lines+=$probe.message
        if ($null -ne $probe.failure) { $lines+=('Categoria: '+$probe.failure.category+' | Códigos: '+$probe.failure.codes);$lines+=('Tipos: '+$probe.failure.types) }
        $lines+='Nenhuma DPS enviada. Produção continua bloqueada.'
        $script:lastSummary=$lines -join [Environment]::NewLine;$output.Text=$script:lastSummary;$copy.Enabled=$true
    } catch { $output.Text='Não foi possível concluir o diagnóstico da API. Nenhuma DPS foi enviada.' }
    finally { $apiProbe.Enabled=$true;$saveApi.Enabled=$true;$run.Enabled=$true;$windowsButton.Enabled=$true;$fileButton.Enabled=$true;$form.UseWaitCursor=$false }
})
$saveApi.Add_Click({
    if ($null -eq $script:selectedCertificate) {
        $output.Text='Para salvar a documentação, selecione primeiro o certificado instalado no Windows. Não use A1 temporário para este teste.'
        return
    }
    $dialog=[Windows.Forms.SaveFileDialog]::new();$dialog.Title='Salvar documentação pública de homologação';$dialog.Filter='Documento JSON (*.json)|*.json';$dialog.FileName='Triade_OpenAPI_ProducaoRestrita.json';$dialog.OverwritePrompt=$true
    try {
        if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
        $saveApi.Enabled=$false;$run.Enabled=$false;$windowsButton.Enabled=$false;$fileButton.Enabled=$false;$form.UseWaitCursor=$true;$output.Text='Lendo referências da documentação oficial...';$form.Refresh()
        $package=Get-TriadeRestrictedOpenApi -Certificate $script:selectedCertificate
        [IO.File]::WriteAllText($dialog.FileName,($package|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
        $script:lastSummary='OpenAPI de produção restrita salvo. O JSON contém somente documentação, origem e hash, sem certificado ou senha. Nenhuma DPS enviada.'
        $output.Text=$script:lastSummary;$copy.Enabled=$true
    } catch {
        $failure=Get-TriadeConnectionFailure -Exception $_.Exception
        $reason=Get-TriadeDocumentationFailure -Exception $_.Exception
        $script:lastSummary=@('Não foi possível salvar a documentação OpenAPI. Nenhuma DPS enviada.',('Motivo: '+$reason.code),$reason.message,('Códigos: '+$failure.codes),('Tipos: '+$failure.types),'Se a conexão já retornou HTTP 200, abra o Swagger no navegador e salve o JSON que ele indica.') -join [Environment]::NewLine
        $output.Text=$script:lastSummary;$copy.Enabled=$true
    } finally { $dialog.Dispose();$saveApi.Enabled=$true;$run.Enabled=$true;$windowsButton.Enabled=$true;$fileButton.Enabled=$true;$form.UseWaitCursor=$false }
})
$protocolButton.Add_Click({
    try {
        $command=Register-TriadeProtocol -ScriptPath $PSCommandPath
        $script:lastSummary=@('Abertura pelo site ativada para este usuário do Windows (sem administrador).','Agora o botão "Assinar e enviar" do site abre este conector, a partir desta pasta.','Se mover ou atualizar a pasta do conector, clique de novo neste botão.','Sites autorizados: '+((Get-TriadeAllowedSites) -join ', ')) -join [Environment]::NewLine
    } catch { $script:lastSummary='Não foi possível ativar a abertura pelo site: '+$_.Exception.Message }
    $output.Text=$script:lastSummary;$copy.Enabled=$true
})
function Get-TriadeCertificateCnpj([Security.Cryptography.X509Certificates.X509Certificate2]$Certificate) {
    foreach($extension in $Certificate.Extensions){ if($extension.Oid.Value -eq '2.5.29.17'){ try { return [TriadeOffline.Cnpj]::FromSan($extension.RawData) } catch { return $null } } }
    return $null
}
function Select-TriadeCertificateFor([string]$Cnpj) {
    if ($null -ne $script:selectedCertificate -and (Get-TriadeCertificateCnpj $script:selectedCertificate) -eq $Cnpj) { return $script:selectedCertificate }
    $available=Get-TriadeWindowsCertificates
    $matching=[Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
    foreach($c in $available){ if((Get-TriadeCertificateCnpj $c) -eq $Cnpj -and $c.NotAfter -gt (Get-Date)){ [void]$matching.Add($c) } }
    if ($matching.Count -eq 0) { throw 'CERT_NOT_FOUND' }
    $picked=$matching
    if ($matching.Count -gt 1) { $picked=[Security.Cryptography.X509Certificates.X509Certificate2UI]::SelectFromCollection($matching,'Tríade NFS-e','Selecione o certificado do emitente '+$Cnpj+'.',[Security.Cryptography.X509Certificates.X509SelectionFlag]::SingleSelection,$form.Handle) }
    if ($picked.Count -eq 0) { throw 'CERT_NOT_SELECTED' }
    $chosen=[Security.Cryptography.X509Certificates.X509Certificate2]::new($picked[0])
    if ($null -ne $script:selectedCertificate) { $script:selectedCertificate.Dispose() }
    $script:selectedCertificate=$chosen
    $selection.Text='Certificado do Windows: '+$chosen.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false)+' (válido até '+$chosen.NotAfter.ToString('dd/MM/yyyy')+')'
    return $chosen
}
function Invoke-TriadeSiteFlow([string]$LaunchUrl) {
    $siteClient=$null;$fiscalClient=$null;$lines=@()
    try {
        $launch=Resolve-TriadeLaunchUrl -Url $LaunchUrl
        $output.Text='Buscando as notas no site '+$launch.site+' ...';$form.Refresh()
        $siteClient=New-TriadeSiteClient
        $jobs=@(Get-TriadeSiteJobs -Client $siteClient -Site $launch.site -Ticket $launch.ticket | Where-Object { $_.status -in @('Reservada','Desconhecida') -or ($_.status -eq 'Autorizada' -and $_.needs_danfse) })
        if ($jobs.Count -eq 0) { $output.Text='Nenhuma DPS pendente neste link. Volte ao site e atualize a lista.';return }
        $issuers=@($jobs|ForEach-Object{[string]$_.summary.cnpj}|Select-Object -Unique)
        if ($issuers.Count -ne 1) { throw 'SITE_MIXED_ISSUERS' }
        # 0.10.0: each link carries ONE environment (the company's). Production = notes with legal validity.
        $environments=@($jobs|ForEach-Object{Get-TriadeJobEnvironment -Job $_}|Select-Object -Unique)
        if ($environments.Count -ne 1) { throw 'SITE_MIXED_ENVIRONMENTS' }
        $environment=[string]$environments[0];$production=$environment -eq '1'
        $schemas=if($production){Join-Path $PSScriptRoot 'schemas\producao'}else{Join-Path $PSScriptRoot 'schemas'}
        if (-not (Test-Path -LiteralPath (Join-Path $schemas 'DPS_v1.01.xsd'))) { throw 'PRODUCTION_SCHEMAS_MISSING' }
        $list=@($jobs|ForEach-Object{('Série '+$_.series+' nº '+$_.number+' — '+$_.summary.tomador+' — competência '+$_.summary.competencia+' — R$ '+$_.summary.valor+$(if($_.status -eq 'Desconhecida'){' (consultar tentativa anterior)'}elseif($_.status -eq 'Autorizada'){' (já autorizada: só baixar o DANFSe)'}else{''}))})
        if ($production) {
            $question=@('ATENÇÃO: PRODUÇÃO — NOTA REAL, COM VALIDADE JURÍDICA.','',('Site: '+$launch.site),('Emitente (CNPJ): '+$issuers[0]),('Notas: '+$jobs.Count),'') + $list + @('','AUTORIZA ASSINAR E ENVIAR ESTAS DPS À SEFIN NACIONAL DE PRODUÇÃO?','Cada nota é consultada antes do envio; tentativas anteriores nunca são reenviadas. A chave privada não sai deste PC.')
            $title='Tríade | PRODUÇÃO — notas reais';$icon=[Windows.Forms.MessageBoxIcon]::Error
        } else {
            $question=@(('Site: '+$launch.site),('Emitente (CNPJ): '+$issuers[0]),('Notas: '+$jobs.Count),'') + $list + @('','AUTORIZA ASSINAR E ENVIAR ESTAS DPS À PRODUÇÃO RESTRITA (TESTES)?','Cada nota é consultada antes do envio; tentativas anteriores nunca são reenviadas. A chave privada não sai deste PC.')
            $title='Tríade | Assinar e enviar notas do site';$icon=[Windows.Forms.MessageBoxIcon]::Warning
        }
        if ([Windows.Forms.MessageBox]::Show($form,($question -join [Environment]::NewLine),$title,[Windows.Forms.MessageBoxButtons]::YesNo,$icon,[Windows.Forms.MessageBoxDefaultButton]::Button2) -ne [Windows.Forms.DialogResult]::Yes) { $output.Text='Cancelado. Nenhuma DPS assinada ou enviada.';return }
        if ($production) {
            $again=@(('Segunda confirmação: '+$jobs.Count+' NFS-e real(is) do CNPJ '+$issuers[0]+'.'),'','Depois de autorizada, a nota só pode ser cancelada ou substituída no Emissor Nacional.','','Confirma o envio à PRODUÇÃO?') -join [Environment]::NewLine
            if ([Windows.Forms.MessageBox]::Show($form,$again,'Tríade | Confirmar NOTA REAL',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Error,[Windows.Forms.MessageBoxDefaultButton]::Button2) -ne [Windows.Forms.DialogResult]::Yes) { $output.Text='Cancelado. Nenhuma DPS assinada ou enviada.';return }
        }
        $certificate=Select-TriadeCertificateFor $issuers[0]
        $local=[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if([string]::IsNullOrWhiteSpace($local)){throw 'LOCAL_DATA_UNAVAILABLE'}
        # Separate history per environment; never delete these folders.
        $journal=if($production){Join-Path $local 'TriadeNfse\Conector\producao'}else{Join-Path $local 'TriadeNfse\Conector\producao-restrita'}
        $fiscalClient=[Net.Http.HttpClient]::new((New-TriadeRestrictedHandler -Certificate $certificate));$fiscalClient.Timeout=[TimeSpan]::FromSeconds(35)
        $form.Enabled=$false;$form.UseWaitCursor=$true
        foreach($job in $jobs){
            $label='Série '+$job.series+' nº '+$job.number
            $output.Text=(($lines+@($label+': assinando e enviando...')) -join [Environment]::NewLine);$form.Refresh()
            try {
                $result=Invoke-TriadeSiteJob -Job $job -Certificate $certificate -SchemaDirectory $schemas -JournalRoot $journal -FiscalClient $fiscalClient -SiteClient $siteClient -Site $launch.site -Ticket $launch.ticket -Environment $environment
                $extra=@();if($result.codes){$extra+='códigos '+$result.codes};if($result.PSObject.Properties['diagnostic']){$extra+='etapa '+$result.diagnostic.stage+' / '+$result.diagnostic.reason};if($result.PSObject.Properties['danfse']){$extra+=$(if($result.danfse -eq 'ok'){'DANFSe enviado ao site'}else{'DANFSe pendente ('+$result.danfse+')'})}
                $lines+=$label+': '+$result.state+' (HTTP '+$result.http_status+')'+$(if($extra){' — '+($extra -join '; ')}else{''})
            } catch {
                $code=$_.Exception.Message;if($code -notmatch '^[A-Z0-9_]{3,40}$'){$code='UNCLASSIFIED'}
                $lines+=$label+': não concluída ('+$code+'). Se houve envio, o histórico deste PC guarda o resultado; gere um novo link no site para consultar.'
                if($code -eq 'SITE_TICKET_EXPIRED'){break}
            }
        }
        $script:lastSummary=(@('Tríade NFS-e | conector 0.10.1 pelo site',$(if($production){'Ambiente: PRODUÇÃO (notas reais). Histórico: LocalAppData\TriadeNfse\Conector\producao'}else{'Ambiente: produção restrita (testes).'})) + $lines + @('','Volte ao site: a tela Notas atualiza a situação de cada nota.')) -join [Environment]::NewLine
    } catch {
        $code=$_.Exception.Message;if($code -notmatch '^[A-Z0-9_]{3,40}$'){$code='UNCLASSIFIED'}
        $hint=@{LAUNCH_URL_INVALID='Link inválido. Gere de novo no site.';SITE_NOT_ALLOWED='Este link aponta para um site não autorizado. Nada foi feito.';SITE_TICKET_EXPIRED='O link expirou (15 minutos). Gere de novo no site.';CERT_NOT_FOUND='Nenhum certificado do Windows com o CNPJ do emitente foi encontrado.';CERT_NOT_SELECTED='Nenhum certificado selecionado.';SITE_MIXED_ISSUERS='O link mistura emitentes diferentes.';SITE_MIXED_ENVIRONMENTS='O link mistura produção e testes. Gere um link por ambiente.';SITE_JOB_ENVIRONMENT='Ambiente da nota inválido. Nada foi enviado.';PRODUCTION_SCHEMAS_MISSING='Este conector não tem os esquemas de produção. Baixe o conector 0.10.0 em Configurações no site.';SCHEMA_ENVIRONMENT='Esquemas incompatíveis com o ambiente. Nada foi enviado.'}[$code]
        $script:lastSummary=@('Não foi possível processar o link do site. Nenhuma DPS enviada nesta etapa.',('Código: '+$code),$hint) -join [Environment]::NewLine
    } finally {
        if($null -ne $fiscalClient){$fiscalClient.Dispose()};if($null -ne $siteClient){$siteClient.Dispose()}
        $form.Enabled=$true;$form.UseWaitCursor=$false
        $output.Text=$script:lastSummary;$copy.Enabled=$true
    }
}
$copy.Add_Click({ if ($script:lastSummary.Length -gt 0) { [Windows.Forms.Clipboard]::SetText($script:lastSummary) } })
$form.Add_FormClosed({ $password.Clear();if ($null -ne $script:selectedCertificate) { $script:selectedCertificate.Dispose();$script:selectedCertificate=$null } })
if ($SelfTest) {
    $nativeUi=[Security.Cryptography.X509Certificates.X509Certificate2UI]
    $pickerMethods=@($nativeUi.GetMethods()|Where-Object { $_.Name -eq 'SelectFromCollection' -and $_.GetParameters().Count -eq 5 })
    if ($pickerMethods.Count -eq 0) { throw 'Seletor Windows indisponível.' }
    if ($form.Controls.Count -lt 10 -or -not $password.UseSystemPasswordChar -or $network.Checked) { throw 'Falha na construção da interface.' }
    $form.Dispose();Write-Output 'PASS: interface Windows construída, senha mascarada, conexão externa desmarcada.'
} elseif ($RegisterProtocol) {
    $command=Register-TriadeProtocol -ScriptPath $PSCommandPath;$form.Dispose()
    [void][Windows.Forms.MessageBox]::Show('Abertura pelo site ativada para este usuário do Windows.','Tríade NFS-e')
} else {
    if ($Url) { $form.Add_Shown({ Invoke-TriadeSiteFlow $Url }) }
    [void]$form.ShowDialog();$form.Dispose()
}
