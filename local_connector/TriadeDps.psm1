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
  public override object GetEntity(Uri uri,string role,Type type) {
   if(!uri.IsFile || !Path.GetFullPath(uri.LocalPath).StartsWith(root,StringComparison.OrdinalIgnoreCase) || Path.GetDirectoryName(Path.GetFullPath(uri.LocalPath))+Path.DirectorySeparatorChar != root || Path.GetExtension(uri.LocalPath)!=".xsd") throw new XmlException("XSD_IMPORT_BLOCKED");
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

function Read-TriadeDps {
 param([Parameter(Mandatory=$true)][byte[]]$Bytes,[Parameter(Mandatory=$true)][string]$SchemaDirectory)
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
 if($document.SelectSingleNode('/n:DPS/n:infDPS/n:tpAmb',$ns).InnerText -ne '2' -or $document.SelectSingleNode('/n:DPS/n:infDPS/n:tpEmit',$ns).InnerText -ne '1'){throw 'RESTRICTED_OWN_ONLY'}
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

function Sign-TriadeOfflineDps {
 param([Parameter(Mandatory=$true)][byte[]]$Bytes,[Parameter(Mandatory=$true)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,[Parameter(Mandatory=$true)][string]$SchemaDirectory,[Parameter(Mandatory=$true)][string]$OwnCnpj)
 $null=Get-TriadeCertificateCheck -Certificate $Certificate
 $document=Read-TriadeDps -Bytes $Bytes -SchemaDirectory $SchemaDirectory
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
  $roundtrip=Read-TriadeDps -Bytes $result -SchemaDirectory $SchemaDirectory
  $verifier=[Security.Cryptography.Xml.SignedXml]::new($roundtrip);$verifier.LoadXml($roundtrip.GetElementsByTagName('Signature','http://www.w3.org/2000/09/xmldsig#')[0])
  if(-not $verifier.CheckSignature($Certificate,$true)){throw 'SIGNATURE_CHECK_FAILED'}
  return ,$result
 } finally {if($null -ne $key){$key.Dispose()}}
}
Export-ModuleMember -Function Read-TriadeDps,Get-TriadeDpsReview,Sign-TriadeOfflineDps
