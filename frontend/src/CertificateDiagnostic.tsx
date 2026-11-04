import {useRef,useState,type FormEvent} from 'react';
type Result={offline_ok:boolean;expires_on:string;chain_certificates:number;connection:{attempted:boolean;http_status:number|null;message:string};warnings:string[]};
type Props={api:(path:string,method?:string,data?:FormData)=>Promise<Result>};
export function CertificateDiagnostic({api}:Props){
 const form=useRef<HTMLFormElement>(null);
 const [consent,setConsent]=useState(false),[busy,setBusy]=useState(false),[result,setResult]=useState<Result|null>(null),[error,setError]=useState('');
 async function submit(event:FormEvent<HTMLFormElement>){
  event.preventDefault();if(!consent||busy)return;setBusy(true);setError('');setResult(null);
  const data=new FormData(event.currentTarget);
  try{setResult(await api('/integrations/restricted/diagnostic','POST',data))}
  catch(e){setError(e instanceof Error?e.message:'Falha no diagnóstico.')}
  finally{data.delete('password');data.delete('file');form.current?.reset();setConsent(false);setBusy(false)}
 }
 return <section className="card"><h2>Produção restrita — diagnóstico do A1</h2><p>Confira o arquivo e a validade do certificado. Opcionalmente, teste uma conexão com a documentação oficial de homologação. Nenhuma DPS será enviada.</p><p className="warning">O A1 e sua senha serão enviados por HTTPS ao servidor da aplicação para este diagnóstico. Não serão guardados para emissões futuras. Para o teste de conexão, a chave temporária é criptografada e removida após carregar o TLS. Não envie esses dados pelo chat.</p><form ref={form} onSubmit={submit}><fieldset disabled={busy} style={{border:0,padding:0}}><div className="formGrid"><label>Arquivo A1 (.pfx ou .p12), até 256 KB<input name="file" type="file" accept=".pfx,.p12" required/></label><label>Senha do arquivo A1<input name="password" type="password" maxLength={512} autoComplete="off" required/></label></div><label className="checkLabel"><input type="checkbox" name="check_connection" value="true"/> Testar conexão TLS com a documentação da produção restrita</label><label className="checkLabel"><input type="checkbox" name="consent" value="true" checked={consent} onChange={e=>setConsent(e.target.checked)} required/> Sou responsável por este certificado e autorizo o envio temporário do arquivo e da senha para o diagnóstico descrito acima.</label><button className="primary" disabled={!consent||busy}>{busy?'Verificando…':'Verificar certificado'}</button></fieldset></form>{error&&<p className="error" role="alert">{error}</p>}{result&&<div role="status"><p><strong>Arquivo aberto e certificado dentro da validade.</strong> Vencimento: {result.expires_on}.</p><p>{result.connection.message}{result.connection.http_status!==null?` HTTP ${result.connection.http_status}.`:''}</p>{result.warnings.map(w=><p className="muted" key={w}>{w}</p>)}<p>Emissão em produção: bloqueada. Envio de DPS em homologação: ainda não habilitado.</p></div>}</section>
}
