#requires -Version 5.1
param([switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Este conector requer Windows.' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot 'TriadeConnector.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'TriadeDps.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'TriadeRestricted.psm1') -Force
[Windows.Forms.Application]::EnableVisualStyles()
$script:selectedCertificate = $null
$script:lastSummary = ''
$form = [Windows.Forms.Form]::new()
$form.Text = 'Tríade NFS-e | Conector local 0.8'
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

$signDps=[Windows.Forms.Button]::new();$signDps.Text='Assinar XML local';$signDps.SetBounds(22,495,210,38);$form.Controls.Add($signDps)
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
  $lines=@('Tríade NFS-e | teste unitário 0.8','Ambiente: produção restrita.',('Situação: '+$result.state),$result.message)
  if($result.http_status -gt 0){$lines+=('HTTP '+$result.http_status)}
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
    $save=$null;$bytes=$null;$signedBytes=$null
    try {
        if($open.ShowDialog() -ne [Windows.Forms.DialogResult]::OK){return}
        if(([IO.FileInfo]::new($open.FileName)).Length -gt 2097152){throw 'XML_SIZE'}
        $bytes=[IO.File]::ReadAllBytes($open.FileName)
        $xml=Read-TriadeDps -Bytes $bytes -SchemaDirectory (Join-Path $PSScriptRoot 'schemas')
        $review=Get-TriadeDpsReview -Document $xml
        $message=@('Assinar somente no PC, sem envio à API?',('Emitente: '+$review.cnpj),('Tomador: '+$review.recipient),('Competência: '+$review.competence),('Valor: R$ '+$review.amount),'Confirme que este emitente é o próprio escritório, titular do certificado selecionado.','O arquivo assinado contém dados fiscais e o certificado público. A chave privada permanece no Windows.','Perfil XMLDSIG do manual integrado: aceitação na API de testes ainda não validada.') -join [Environment]::NewLine
        if([Windows.Forms.MessageBox]::Show($form,$message,'Tríade | Assinatura offline',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Information) -ne [Windows.Forms.DialogResult]::Yes){return}
        $signedBytes=Protect-TriadeOfflineDps -Bytes $bytes -Certificate $script:selectedCertificate -SchemaDirectory (Join-Path $PSScriptRoot 'schemas') -OwnCnpj $review.cnpj
        $save=[Windows.Forms.SaveFileDialog]::new();$save.Filter='DPS XML (*.xml)|*.xml';$save.FileName='DPS_Teste_Assinada.xml';$save.Title='Salvar em novo arquivo local'
        if($save.ShowDialog() -ne [Windows.Forms.DialogResult]::OK){return}
        # CreateNew protects the original XML and any existing file.
        $file=[IO.File]::Open($save.FileName,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$file.Write($signedBytes,0,$signedBytes.Length)}finally{$file.Dispose()}
        $script:lastSummary=@('Tríade NFS-e | preparação local 0.8','XML de produção restrita validado no XSD recebido.','Assinatura criada e integridade criptográfica conferida localmente.','CNPJ do prestador confere com o OID CNPJ do certificado.','Não foram validados cadeia ICP-Brasil, revogação, credenciamento ou aceitação da assinatura na API.','Arquivo salvo somente no PC. Nenhuma DPS enviada. Produção continua bloqueada.') -join [Environment]::NewLine
        $output.Text=$script:lastSummary;$copy.Enabled=$true
    } catch {
        $code='OFFLINE_PREPARATION_FAILED'
        foreach($candidate in @('XML_SIZE','XML_ROOT','XML_ID','RESTRICTED_OWN_ONLY','OWN_CNPJ_REQUIRED','ALREADY_SIGNED','CERT_CNPJ_MISMATCH','RSA_REQUIRED','SIGNATURE_CHECK_FAILED')){
            $exception=$_.Exception
            for($i=0;$i -lt 6 -and $null -ne $exception;$i++){if($exception.Message -eq $candidate){$code=$candidate};$exception=$exception.InnerException}
        }
        $script:lastSummary='Não foi possível preparar a DPS. Código: '+$code+'. Confira se é XML de testes válido, se o certificado pertence ao emitente e se o destino é um arquivo novo. Nenhuma DPS enviada.'
        $output.Text=$script:lastSummary;$copy.Enabled=$true
    } finally {
        $open.Dispose();if($null -ne $save){$save.Dispose()}
        if($null -ne $bytes){[Array]::Clear($bytes,0,$bytes.Length)}
        if($null -ne $signedBytes){[Array]::Clear($signedBytes,0,$signedBytes.Length)}
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
        $lines=@('Tríade NFS-e | diagnóstico local 0.8',('Arquivo/chave presentes e certificado dentro da validade. Vencimento: '+$check.expires_on))
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
        $lines=@('Tríade NFS-e | teste API somente de leitura 0.8','Ambiente: produção restrita. Origem: certificado instalado no Windows.','Método: HEAD /dps/diagnostico-local (identificador intencionalmente inválido).')
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
$copy.Add_Click({ if ($script:lastSummary.Length -gt 0) { [Windows.Forms.Clipboard]::SetText($script:lastSummary) } })
$form.Add_FormClosed({ $password.Clear();if ($null -ne $script:selectedCertificate) { $script:selectedCertificate.Dispose();$script:selectedCertificate=$null } })
if ($SelfTest) {
    $nativeUi=[Security.Cryptography.X509Certificates.X509Certificate2UI]
    $pickerMethods=@($nativeUi.GetMethods()|Where-Object { $_.Name -eq 'SelectFromCollection' -and $_.GetParameters().Count -eq 5 })
    if ($pickerMethods.Count -eq 0) { throw 'Seletor Windows indisponível.' }
    if ($form.Controls.Count -lt 10 -or -not $password.UseSystemPasswordChar -or $network.Checked) { throw 'Falha na construção da interface.' }
    $form.Dispose();Write-Output 'PASS: interface Windows construída, senha mascarada, conexão externa desmarcada.'
} else { [void]$form.ShowDialog();$form.Dispose() }
