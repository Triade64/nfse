import React, {useState} from 'react';
import {Download, Upload, X} from 'lucide-react';

type Api=(path:string,method?:string,data?:any)=>Promise<any>;
type Row={line:number;cnpj_emitente:string;documento_tomador:string;nome_tomador:string;action:string;errors:string[];warnings:string[]};
type Preview={sha256:string;summary:{total:number;novos:number;atualizar:number;erros:number;avisos:number};rows:Row[]};
const tone=(a:string)=>a==='Com erro'?'red':a==='Atualizar'?'blue':'green';

// 0.12.0: spreadsheet import of customers. Preview first (nothing written), then import the same file, all or nothing.
export function CustomerImport({api,onImported}:{api:Api;onImported:(message:string)=>void|Promise<void>}){
 const [file,setFile]=useState<File|null>(null),[preview,setPreview]=useState<Preview|null>(null),[busy,setBusy]=useState(false),[error,setError]=useState('');
 const form=(f:File)=>{const data=new FormData();data.append('file',f);return data};
 async function choose(f:File){setFile(f);setPreview(null);setError('');setBusy(true);try{setPreview(await api('/customers/import','POST',form(f)))}catch(e){setError((e as Error).message)}finally{setBusy(false)}}
 async function confirm(){if(!file||!preview)return;setBusy(true);setError('');try{const r=await api('/customers/import?confirm=true&expected_sha256='+preview.sha256,'POST',form(file));close();await onImported(`Importação concluída: ${r.created} novo${r.created!==1?'s':''} e ${r.updated} atualizado${r.updated!==1?'s':''}.`)}catch(e){setError((e as Error).message)}finally{setBusy(false)}}
 function close(){setFile(null);setPreview(null);setError('')}
 return <>
  <a className="button" href="/api/customers/template.xlsx"><Download size={15}/> Modelo de tomadores</a>
  <label className="button">{busy&&!preview?'Lendo arquivo…':<><Upload size={15}/> Importar planilha</>}<input hidden type="file" accept=".xlsx,.csv" disabled={busy} onChange={e=>{const f=e.target.files?.[0];if(f)choose(f);e.target.value=''}}/></label>
  {error&&!preview&&<div className="error" role="alert">{error}<button aria-label="Fechar" onClick={()=>setError('')}><X size={14}/></button></div>}
  {preview&&<div className="overlay"><div className="modal" role="dialog" aria-label="Prévia da importação de tomadores"><header><h2>Prévia da importação</h2><button className="icon" aria-label="Fechar" onClick={close}><X/></button></header>
   <p>{file?.name}: {preview.summary.total} tomador{preview.summary.total!==1?'es':''} · <strong>{preview.summary.novos}</strong> novo{preview.summary.novos!==1?'s':''} · <strong>{preview.summary.atualizar}</strong> a atualizar · <strong>{preview.summary.erros}</strong> com erro · {preview.summary.avisos} com aviso. Nada foi gravado ainda.</p>
   {preview.summary.erros>0&&<div className="warning">Corrija as linhas com erro na planilha e selecione o arquivo de novo. Enquanto houver erro, nada é importado.</div>}
   <div className="tableWrap batchTable"><table><thead><tr><th>Linha</th><th>Tomador</th><th>Emitente</th><th>Situação</th></tr></thead><tbody>{preview.rows.map(r=><tr key={r.line}><td>{r.line}</td><td><strong>{r.nome_tomador||'—'}</strong><small>{r.documento_tomador}</small></td><td>{r.cnpj_emitente}</td><td><span className={'badge '+tone(r.action)}>{r.action}</span>{r.errors.map(m=><small className="rowError" key={m}>{m}</small>)}{r.warnings.map(m=><small key={m}>{m}</small>)}</td></tr>)}</tbody></table></div>
   {error&&<div className="error" role="alert">{error}</div>}
   <div className="modalActions"><button type="button" onClick={close}>Cancelar</button><button className="primary" disabled={busy||preview.summary.erros>0} onClick={confirm}>{busy?'Importando…':`Importar ${preview.summary.total} tomador${preview.summary.total!==1?'es':''}`}</button></div>
  </div></div>}
 </>;
}
