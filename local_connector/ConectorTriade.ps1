#requires -Version 5.1
param([switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Este conector requer Windows.' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot 'TriadeConnector.Core.psm1') -Force
[Windows.Forms.Application]::EnableVisualStyles()
$script:selectedCertificate = $null
$script:lastSummary = ''
$form = [Windows.Forms.Form]::new()
$form.Text = 'Tríade NFS-e | Conector local 0.3'
$form.ClientSize = [Drawing.Size]::new(720,650)
$form.MinimumSize = [Drawing.Size]::new(736,689)
$form.StartPosition = 'CenterScreen'
$form.Font = [Drawing.Font]::new('Segoe UI',10)
$form.BackColor = [Drawing.Color]::FromArgb(245,248,246)
function Add-Label([string]$Text,[int]$Top,[int]$Height=35) {
    $label=[Windows.Forms.Label]::new();$label.Text=$Text;$label.SetBounds(22,$Top,675,$Height);$form.Controls.Add($label);return $label
}
$null=Add-Label 'Certificado e senha permanecem neste computador' 18 30
$null=Add-Label 'Diagnóstico de produção restrita. Não emite notas e não conecta a fila do site nesta versão.' 53 45
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
$output=[Windows.Forms.TextBox]::new();$output.Multiline=$true;$output.ReadOnly=$true;$output.ScrollBars='Vertical';$output.SetBounds(22,495,675,130);$form.Controls.Add($output)

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
        $lines=@('Tríade NFS-e | diagnóstico local 0.3',('Arquivo/chave presentes e certificado dentro da validade. Vencimento: '+$check.expires_on))
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
$copy.Add_Click({ if ($script:lastSummary.Length -gt 0) { [Windows.Forms.Clipboard]::SetText($script:lastSummary) } })
$form.Add_FormClosed({ $password.Clear();if ($null -ne $script:selectedCertificate) { $script:selectedCertificate.Dispose();$script:selectedCertificate=$null } })
if ($SelfTest) {
    $nativeUi=[Security.Cryptography.X509Certificates.X509Certificate2UI]
    $pickerMethods=@($nativeUi.GetMethods()|Where-Object { $_.Name -eq 'SelectFromCollection' -and $_.GetParameters().Count -eq 5 })
    if ($pickerMethods.Count -eq 0) { throw 'Seletor Windows indisponível.' }
    if ($form.Controls.Count -lt 10 -or -not $password.UseSystemPasswordChar -or $network.Checked) { throw 'Falha na construção da interface.' }
    $form.Dispose();Write-Output 'PASS: interface Windows construída, senha mascarada, conexão externa desmarcada.'
} else { [void]$form.ShowDialog();$form.Dispose() }
