#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Security
# Restrict XSD imports to the bundled directory. No network or arbitrary file reads.
if (-not ('TriadeOffline.XmlFiles' -as [type])) {
Add-Type -ReferencedAssemblies 'System.Xml.dll','System.dll' -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Xml;
using System.Collections.Generic;
namespace TriadeOffline {
 public sealed class XmlFiles : XmlUrlResolver {
  readonly string root;
  public XmlFiles(string directory) { root=Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar)+Path.DirectorySeparatorChar; }
  // The official production package (2026-02-09) ships xmldsig-core-schema.xsd with the W3C DOCTYPE header; DTDs stay
  // prohibited, so exactly that known header is removed in memory. Any other DOCTYPE is refused. The file is not changed.
  const string W3cDoctype="<!DOCTYPE schema\n  PUBLIC \"-//W3C//DTD XMLSchema 200102//EN\" \"http://www.w3.org/2001/XMLSchema.dtd\"\n [\n   <!ATTLIST schema \n     xmlns:ds CDATA #FIXED \"http://www.w3.org/2000/09/xmldsig#\">\n   <!ENTITY dsig 'http://www.w3.org/2000/09/xmldsig#'>\n   <!ENTITY % p ''>\n   <!ENTITY % s ''>\n  ]>";
  public override object GetEntity(Uri uri,string role,Type type) {
   if(!uri.IsFile || !Path.GetFullPath(uri.LocalPath).StartsWith(root,StringComparison.OrdinalIgnoreCase) || Path.GetDirectoryName(Path.GetFullPath(uri.LocalPath))+Path.DirectorySeparatorChar != root || Path.GetExtension(uri.LocalPath)!=".xsd") throw new XmlException("XSD_IMPORT_BLOCKED");
   if(Path.GetFileName(uri.LocalPath)=="xmldsig-core-schema.xsd") {
    string text=File.ReadAllText(uri.LocalPath).Replace("\r\n","\n");
    int i=text.IndexOf("<!DOCTYPE",StringComparison.Ordinal);
    if(i>=0) {
     if(i+W3cDoctype.Length>text.Length || string.CompareOrdinal(text,i,W3cDoctype,0,W3cDoctype.Length)!=0 || text.IndexOf("<!DOCTYPE",i+1,StringComparison.Ordinal)>=0 || text.IndexOf("<!ENTITY",i+W3cDoctype.Length,StringComparison.Ordinal)>=0) throw new XmlException("XSD_DOCTYPE_BLOCKED");
     text=text.Remove(i,W3cDoctype.Length);
    }
    return new MemoryStream(new System.Text.UTF8Encoding(false).GetBytes(text));
   }
   return File.OpenRead(uri.LocalPath);
  }
 }
 public static class Cnpj {
  static byte[] Value(byte[] data, ref int pos, out byte tag) {
   if(pos+2>data.Length)throw new FormatException();
   tag=data[pos++]; int length=data[pos++];
   if((length&128)!=0) { int count=length&127; if(count<1||count>4||pos+count>data.Length)throw new FormatException(); length=0; for(int i=0;i<count;i++)length=checked(length*256+data[pos++]); }
   if(length<0||length>data.Length-pos)throw new FormatException();
   byte[] result=new byte[length];Buffer.BlockCopy(data,pos,result,0,length);pos+=length;return result;
  }
  public static string FromSan(byte[] raw) {
   int p=0; byte tag;byte[] sequence=Value(raw,ref p,out tag);if(tag!=48||p!=raw.Length)throw new FormatException();
   string result=null; p=0;
   while(p<sequence.Length) {
    byte[] name=Value(sequence,ref p,out tag);if(tag!=160)continue;
    int q=0;byte[] oid=Value(name,ref q,out tag);if(tag!=6||BitConverter.ToString(oid)!="60-4C-01-03-03")continue;
    byte[] explicitValue=Value(name,ref q,out tag);if(tag!=160||q!=name.Length)throw new FormatException();
    int k=0;byte[] text=Value(explicitValue,ref k,out tag);if(k!=explicitValue.Length||!(tag==4||tag==12||tag==19||tag==22)||text.Length!=14)throw new FormatException();
    foreach(byte ch in text)if(ch<48||ch>57)throw new FormatException();
    string value=System.Text.Encoding.ASCII.GetString(text);if(result!=null&&result!=value)throw new FormatException();result=value;
   }
   return result;
  }
 }
}
'@
}

function Assert-TriadeSchemaEnvironment {
 # 0.10.0: schemas\ holds the restricted layout (tpAmb 2) and schemas\producao the production layout (tpAmb 1).
 # The schema folder and the expected environment must agree, so a production XML is never checked against test rules.
 param([string]$SchemaDirectory,[string]$Environment)
 $leaf=[IO.Path]::GetFileName([IO.Path]::GetFullPath($SchemaDirectory).TrimEnd('\','/'))
 if($Environment -notin @('1','2') -or (($Environment -eq '1') -ne ($leaf -eq 'producao'))){throw 'SCHEMA_ENVIRONMENT'}
}
function Read-TriadeDps {
 param([Parameter(Mandatory=$true)][byte[]]$Bytes,[Parameter(Mandatory=$true)][string]$SchemaDirectory,[ValidateSet('1','2')][string]$Environment='2')
 Assert-TriadeSchemaEnvironment -SchemaDirectory $SchemaDirectory -Environment $Environment
 if($Bytes.Length -eq 0 -or $Bytes.Length -gt 2097152){throw 'XML_SIZE'}
 $settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null;$settings.MaxCharactersInDocument=2097152
 $stream=[IO.MemoryStream]::new($Bytes,$false);$reader=$null
 try {
  $reader=[Xml.XmlReader]::Create($stream,$settings)
  $document=[Xml.XmlDocument]::new();$document.PreserveWhitespace=$true;$document.XmlResolver=$null;$document.Load($reader)
 } finally {if($null -ne $reader){$reader.Dispose()};$stream.Dispose()}
 $schemas=[Xml.Schema.XmlSchemaSet]::new();$schemas.XmlResolver=[TriadeOffline.XmlFiles]::new($SchemaDirectory)
 $null=$schemas.Add('http://www.sped.fazenda.gov.br/nfse',(Join-Path $SchemaDirectory 'DPS_v1.01.xsd'));$schemas.Compile()
 $document.Schemas=$schemas;$document.Validate($null)
 $ns=[Xml.XmlNamespaceManager]::new($document.NameTable);$ns.AddNamespace('n','http://www.sped.fazenda.gov.br/nfse')
 $root=$document.DocumentElement
 if($root.LocalName -ne 'DPS' -or $root.NamespaceURI -ne 'http://www.sped.fazenda.gov.br/nfse' -or $root.GetAttribute('versao') -ne '1.01'){throw 'XML_ROOT'}
 if($document.SelectNodes('//n:infDPS',$ns).Count -ne 1 -or $document.SelectNodes('//*[@Id or @ID or @id]').Count -ne 1){throw 'XML_ID'}
 if($document.SelectSingleNode('/n:DPS/n:infDPS/n:tpAmb',$ns).InnerText -ne $Environment -or $document.SelectSingleNode('/n:DPS/n:infDPS/n:tpEmit',$ns).InnerText -ne '1'){throw 'RESTRICTED_OWN_ONLY'}
 return ,$document
}

function Get-TriadeDpsReview {
 param([Parameter(Mandatory=$true)][Xml.XmlDocument]$Document)
 $ns=[Xml.XmlNamespaceManager]::new($Document.NameTable);$ns.AddNamespace('n','http://www.sped.fazenda.gov.br/nfse')
 $info=$Document.SelectSingleNode('/n:DPS/n:infDPS',$ns)
 $cnpj=$info.SelectSingleNode('n:prest/n:CNPJ',$ns)
 if($null -eq $cnpj){throw 'OWN_CNPJ_REQUIRED'}
 $expectedId='DPS'+$info.SelectSingleNode('n:cLocEmi',$ns).InnerText+'2'+$cnpj.InnerText+$info.SelectSingleNode('n:serie',$ns).InnerText.PadLeft(5,'0')+$info.SelectSingleNode('n:nDPS',$ns).InnerText.PadLeft(15,'0')
 if($info.GetAttribute('Id') -ne $expectedId){throw 'XML_ID'}
 return [PSCustomObject]@{cnpj=$cnpj.InnerText;identifier=$info.GetAttribute('Id');competence=$info.SelectSingleNode('n:dCompet',$ns).InnerText;amount=$info.SelectSingleNode('n:valores/n:vServPrest/n:vServ',$ns).InnerText;recipient=$info.SelectSingleNode('n:toma/n:xNome',$ns).InnerText}
}

function Protect-TriadeOfflineDps {
 param([Parameter(Mandatory=$true)][byte[]]$Bytes,[Parameter(Mandatory=$true)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,[Parameter(Mandatory=$true)][string]$SchemaDirectory,[Parameter(Mandatory=$true)][string]$OwnCnpj,[ValidateSet('1','2')][string]$Environment='2')
 $null=Get-TriadeCertificateCheck -Certificate $Certificate
 $document=Read-TriadeDps -Bytes $Bytes -SchemaDirectory $SchemaDirectory -Environment $Environment
 if($document.GetElementsByTagName('Signature','http://www.w3.org/2000/09/xmldsig#').Count -ne 0){throw 'ALREADY_SIGNED'}
 $review=Get-TriadeDpsReview -Document $document
 $certificateCnpj=$null
 foreach($extension in $Certificate.Extensions){if($extension.Oid.Value -eq '2.5.29.17'){$certificateCnpj=[TriadeOffline.Cnpj]::FromSan($extension.RawData)}}
 if($OwnCnpj -notmatch '^[0-9]{14}$' -or $OwnCnpj -ne $review.cnpj -or $certificateCnpj -ne $OwnCnpj){throw 'CERT_CNPJ_MISMATCH'}
 $key=$null
 try {
  $key=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
  if($null -eq $key){throw 'RSA_REQUIRED'}
  $signed=[Security.Cryptography.Xml.SignedXml]::new($document);$signed.SigningKey=$key
  # Baseline from official integrated manual 1.00.02 section 6.1.4.
  # API acceptance for the 2026 restricted layout is NOT asserted by offline verification.
  $signed.SignedInfo.CanonicalizationMethod=[Security.Cryptography.Xml.SignedXml]::XmlDsigC14NTransformUrl
  $signed.SignedInfo.SignatureMethod=[Security.Cryptography.Xml.SignedXml]::XmlDsigRSASHA1Url
  $reference=[Security.Cryptography.Xml.Reference]::new('#'+$review.identifier)
  $reference.DigestMethod=[Security.Cryptography.Xml.SignedXml]::XmlDsigSHA1Url
  $reference.AddTransform([Security.Cryptography.Xml.XmlDsigEnvelopedSignatureTransform]::new())
  $reference.AddTransform([Security.Cryptography.Xml.XmlDsigC14NTransform]::new());$signed.AddReference($reference)
  $signed.KeyInfo=[Security.Cryptography.Xml.KeyInfo]::new();$signed.KeyInfo.AddClause([Security.Cryptography.Xml.KeyInfoX509Data]::new($Certificate))
  $signed.ComputeSignature();$null=$document.DocumentElement.AppendChild($document.ImportNode($signed.GetXml(),$true))
  $result=[Text.UTF8Encoding]::new($false).GetBytes($document.OuterXml)
  $roundtrip=Read-TriadeDps -Bytes $result -SchemaDirectory $SchemaDirectory -Environment $Environment
  $verifier=[Security.Cryptography.Xml.SignedXml]::new($roundtrip);$verifier.LoadXml($roundtrip.GetElementsByTagName('Signature','http://www.w3.org/2000/09/xmldsig#')[0])
  if(-not $verifier.CheckSignature($Certificate,$true)){throw 'SIGNATURE_CHECK_FAILED'}
  return ,$result
 } finally {if($null -ne $key){$key.Dispose()}}
}

function Test-TriadeSignedDps {
 param([Parameter(Mandatory=$true)][byte[]]$Bytes,[Parameter(Mandatory=$true)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,[Parameter(Mandatory=$true)][string]$SchemaDirectory,[ValidateSet('1','2')][string]$Environment='2')
 $null=Get-TriadeCertificateCheck -Certificate $Certificate
 $document=Read-TriadeDps -Bytes $Bytes -SchemaDirectory $SchemaDirectory -Environment $Environment
 $review=Get-TriadeDpsReview -Document $document
 $certCnpj=$null
 foreach($extension in $Certificate.Extensions){if($extension.Oid.Value -eq '2.5.29.17'){$certCnpj=[TriadeOffline.Cnpj]::FromSan($extension.RawData)}}
 if($certCnpj -ne $review.cnpj){throw 'CERT_CNPJ_MISMATCH'}
 $ns=[Xml.XmlNamespaceManager]::new($document.NameTable);$ns.AddNamespace('n','http://www.sped.fazenda.gov.br/nfse');$ns.AddNamespace('ds','http://www.w3.org/2000/09/xmldsig#')
 $signatures=$document.SelectNodes('/n:DPS/ds:Signature',$ns)
 if($signatures.Count -ne 1 -or $document.GetElementsByTagName('Signature','http://www.w3.org/2000/09/xmldsig#').Count -ne 1){throw 'SIGNATURE_REQUIRED'}
 $signature=$signatures[0]
 $reference=$signature.SelectNodes('ds:SignedInfo/ds:Reference',$ns)
 if($reference.Count -ne 1 -or $reference[0].GetAttribute('URI') -ne ('#'+$review.identifier)){throw 'SIGNATURE_PROFILE'}
 $transforms=$reference[0].SelectNodes('ds:Transforms/ds:Transform',$ns)
 if($transforms.Count -ne 2 -or $transforms[0].GetAttribute('Algorithm') -ne [Security.Cryptography.Xml.SignedXml]::XmlDsigEnvelopedSignatureTransformUrl -or $transforms[1].GetAttribute('Algorithm') -ne [Security.Cryptography.Xml.SignedXml]::XmlDsigC14NTransformUrl){throw 'SIGNATURE_PROFILE'}
 if($signature.SelectSingleNode('ds:SignedInfo/ds:CanonicalizationMethod',$ns).GetAttribute('Algorithm') -ne [Security.Cryptography.Xml.SignedXml]::XmlDsigC14NTransformUrl -or $signature.SelectSingleNode('ds:SignedInfo/ds:SignatureMethod',$ns).GetAttribute('Algorithm') -ne [Security.Cryptography.Xml.SignedXml]::XmlDsigRSASHA1Url -or $reference[0].SelectSingleNode('ds:DigestMethod',$ns).GetAttribute('Algorithm') -ne [Security.Cryptography.Xml.SignedXml]::XmlDsigSHA1Url){throw 'SIGNATURE_PROFILE'}
 $publicCerts=$signature.SelectNodes('ds:KeyInfo/ds:X509Data/ds:X509Certificate',$ns)
 if($publicCerts.Count -ne 1 -or $publicCerts[0].InnerText -ne [Convert]::ToBase64String($Certificate.RawData)){throw 'SIGNATURE_CERTIFICATE'}
 $verifier=[Security.Cryptography.Xml.SignedXml]::new($document);$verifier.LoadXml($signature)
 if(-not $verifier.CheckSignature($Certificate,$true)){throw 'SIGNATURE_CHECK_FAILED'}
 return $review
}
function ConvertTo-TriadeBrasiliaDps {
 param([byte[]]$Bytes,[Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,[string]$SchemaDirectory)
 $document=Read-TriadeDps -Bytes $Bytes -SchemaDirectory $SchemaDirectory
 $signatures=$document.GetElementsByTagName('Signature','http://www.w3.org/2000/09/xmldsig#')
 if($signatures.Count -gt 0){
  $null=Test-TriadeSignedDps -Bytes $Bytes -Certificate $Certificate -SchemaDirectory $SchemaDirectory
  $null=$signatures[0].ParentNode.RemoveChild($signatures[0])
 }
 $ns=[Xml.XmlNamespaceManager]::new($document.NameTable);$ns.AddNamespace('n','http://www.sped.fazenda.gov.br/nfse')
 $date=$document.SelectSingleNode('/n:DPS/n:infDPS/n:dhEmi',$ns)
 $instant=[DateTimeOffset]::Parse($date.InnerText,[Globalization.CultureInfo]::InvariantCulture)
 $date.InnerText=$instant.ToOffset([TimeSpan]::FromHours(-3)).ToString('yyyy-MM-ddTHH:mm:sszzz',[Globalization.CultureInfo]::InvariantCulture)
 return ,([Text.UTF8Encoding]::new($false).GetBytes($document.OuterXml))
}
function Test-TriadeTimezoneOnlyRevision {
 param([byte[]]$Previous,[byte[]]$Revised,[Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,[string]$SchemaDirectory)
 $old=Test-TriadeSignedDps -Bytes $Previous -Certificate $Certificate -SchemaDirectory $SchemaDirectory
 $new=Test-TriadeSignedDps -Bytes $Revised -Certificate $Certificate -SchemaDirectory $SchemaDirectory
 if($old.identifier -ne $new.identifier){throw 'TIMEZONE_REVISION_INVALID'}
 $a=Read-TriadeDps -Bytes $Previous -SchemaDirectory $SchemaDirectory
 $b=Read-TriadeDps -Bytes $Revised -SchemaDirectory $SchemaDirectory
 $ns=[Xml.XmlNamespaceManager]::new($a.NameTable);$ns.AddNamespace('n','http://www.sped.fazenda.gov.br/nfse')
 $oldNode=$a.SelectSingleNode('/n:DPS/n:infDPS/n:dhEmi',$ns)
 $ns2=[Xml.XmlNamespaceManager]::new($b.NameTable);$ns2.AddNamespace('n','http://www.sped.fazenda.gov.br/nfse')
 $newNode=$b.SelectSingleNode('/n:DPS/n:infDPS/n:dhEmi',$ns2)
 $oldTime=[DateTimeOffset]::Parse($oldNode.InnerText,[Globalization.CultureInfo]::InvariantCulture)
 $newTime=[DateTimeOffset]::Parse($newNode.InnerText,[Globalization.CultureInfo]::InvariantCulture)
 if($oldNode.InnerText -eq $newNode.InnerText -or $newNode.InnerText -notmatch '-03:00$' -or $oldTime.UtcDateTime.Ticks -ne $newTime.UtcDateTime.Ticks){throw 'TIMEZONE_REVISION_INVALID'}
 $before=$oldNode.InnerText;$after=$newNode.InnerText
 $oldNode.InnerText=$newNode.InnerText
 $canonical=@()
 foreach($doc in @($a,$b)){
  $sig=$doc.GetElementsByTagName('Signature','http://www.w3.org/2000/09/xmldsig#')[0];$null=$sig.ParentNode.RemoveChild($sig)
  $transform=[Security.Cryptography.Xml.XmlDsigC14NTransform]::new();$transform.LoadInput($doc)
  $output=$transform.GetOutput([IO.Stream]);$memory=[IO.MemoryStream]::new()
  try{$output.CopyTo($memory);$canonical+= [Convert]::ToBase64String($memory.ToArray())}finally{$output.Dispose();$memory.Dispose()}
 }
 if($canonical[0] -cne $canonical[1]){throw 'TIMEZONE_REVISION_INVALID'}
 return [PSCustomObject]@{before=$before;after=$after}
}
function ConvertTo-TriadeDpsWithoutIm {
 param([byte[]]$Bytes,[Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,[string]$SchemaDirectory)
 $document=Read-TriadeDps -Bytes $Bytes -SchemaDirectory $SchemaDirectory
 $signatures=$document.GetElementsByTagName('Signature','http://www.w3.org/2000/09/xmldsig#')
 if($signatures.Count -gt 0){
  $null=Test-TriadeSignedDps -Bytes $Bytes -Certificate $Certificate -SchemaDirectory $SchemaDirectory
  $null=$signatures[0].ParentNode.RemoveChild($signatures[0])
 }
 $ns=[Xml.XmlNamespaceManager]::new($document.NameTable);$ns.AddNamespace('n','http://www.sped.fazenda.gov.br/nfse')
 $im=$document.SelectSingleNode('/n:DPS/n:infDPS/n:prest/n:IM',$ns)
 if($null -eq $im){throw 'IM_REVISION_INVALID'}
 $null=$im.ParentNode.RemoveChild($im)
 return ,([Text.UTF8Encoding]::new($false).GetBytes($document.OuterXml))
}
function Test-TriadeImOnlyRevision {
 param([byte[]]$Previous,[byte[]]$Revised,[Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,[string]$SchemaDirectory)
 $old=Test-TriadeSignedDps -Bytes $Previous -Certificate $Certificate -SchemaDirectory $SchemaDirectory
 $new=Test-TriadeSignedDps -Bytes $Revised -Certificate $Certificate -SchemaDirectory $SchemaDirectory
 if($old.identifier -ne $new.identifier){throw 'IM_REVISION_INVALID'}
 $a=Read-TriadeDps -Bytes $Previous -SchemaDirectory $SchemaDirectory
 $b=Read-TriadeDps -Bytes $Revised -SchemaDirectory $SchemaDirectory
 $ns=[Xml.XmlNamespaceManager]::new($a.NameTable);$ns.AddNamespace('n','http://www.sped.fazenda.gov.br/nfse')
 $ns2=[Xml.XmlNamespaceManager]::new($b.NameTable);$ns2.AddNamespace('n','http://www.sped.fazenda.gov.br/nfse')
 $im=$a.SelectSingleNode('/n:DPS/n:infDPS/n:prest/n:IM',$ns)
 if($null -eq $im -or $null -ne $b.SelectSingleNode('/n:DPS/n:infDPS/n:prest/n:IM',$ns2)){throw 'IM_REVISION_INVALID'}
 $null=$im.ParentNode.RemoveChild($im)
 $canonical=@()
 foreach($doc in @($a,$b)){
  $sig=$doc.GetElementsByTagName('Signature','http://www.w3.org/2000/09/xmldsig#')[0];$null=$sig.ParentNode.RemoveChild($sig)
  $transform=[Security.Cryptography.Xml.XmlDsigC14NTransform]::new();$transform.LoadInput($doc)
  $output=$transform.GetOutput([IO.Stream]);$memory=[IO.MemoryStream]::new()
  try{$output.CopyTo($memory);$canonical+=[Convert]::ToBase64String($memory.ToArray())}finally{$output.Dispose();$memory.Dispose()}
 }
 if($canonical[0] -cne $canonical[1]){throw 'IM_REVISION_INVALID'}
 return [PSCustomObject]@{before='Inscrição municipal incluída';after='Inscrição municipal omitida somente neste XML'}
}
Export-ModuleMember -Function ConvertTo-TriadeDpsWithoutIm,Test-TriadeImOnlyRevision,ConvertTo-TriadeBrasiliaDps,Test-TriadeTimezoneOnlyRevision,Read-TriadeDps,Get-TriadeDpsReview,Protect-TriadeOfflineDps,Test-TriadeSignedDps
