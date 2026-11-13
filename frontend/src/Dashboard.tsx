import React, {useEffect, useState} from 'react';
import {ArrowUpRight, Download} from 'lucide-react';
import type {Note} from './Notas';

type Api=(path:string,method?:string,data?:any)=>Promise<any>;
type Company={id:number;name:string;config:Record<string,any>};
export type NotesFilter={situation?:string;month?:string};

const money=(c:number)=>new Intl.NumberFormat('pt-BR',{style:'currency',currency:'BRL'}).format((c||0)/100);
const monthName=(ym:string)=>new Date(ym+'-01T12:00:00').toLocaleDateString('pt-BR',{month:'long',year:'numeric'});
export const WAITING='Aguardando o conector';
export const isWaiting=(n:Note)=>n.situation==='DPS reservada'||n.situation==='DPS em consulta';

// 0.13.0: overview built from the notes themselves (the batch flow is legacy). Each tile opens Notas already filtered.
export function Dashboard({api,companies,openNotes,today=new Date()}:{api:Api;companies:Company[];openNotes:(f:NotesFilter)=>void;today?:Date}){
 const [notes,setNotes]=useState<Note[]|null>(null),[error,setError]=useState('');
 useEffect(()=>{api('/notes').then(setNotes).catch(e=>setError((e as Error).message))},[]);
 if(error)return <div className="error" role="alert">{error}</div>;
 if(!notes)return <p className="muted">Carregando indicadores…</p>;
 const month=`${today.getFullYear()}-${String(today.getMonth()+1).padStart(2,'0')}`;
 const authorizedMonth=notes.filter(n=>n.situation==='NFS-e autorizada'&&n.raw.competencia?.startsWith(month));
 const count=(f:(n:Note)=>boolean)=>notes.filter(f).length;
 const tiles:[string,string|number,string,NotesFilter,string][]=[
  ['Autorizadas em '+monthName(month),authorizedMonth.length,money(authorizedMonth.reduce((s,n)=>s+n.amount_cents,0)),{situation:'NFS-e autorizada',month},'green'],
  ['Prontas para emitir',count(n=>n.situation==='Pronta'),'Conferidas, aguardando emissão',{situation:'Pronta'},''],
  [WAITING,count(isWaiting),'Número reservado; assinar e enviar no conector',{situation:WAITING},'blue'],
  ['Rejeitadas',count(n=>n.situation==='DPS rejeitada'),'Corrija e descarte para emitir de novo',{situation:'DPS rejeitada'},'red'],
  ['Com inconsistência',count(n=>n.situation==='Com inconsistência'),'Dados a corrigir antes de emitir',{situation:'Com inconsistência'},'orange'],
 ];
 const latest=notes.filter(n=>n.situation==='NFS-e autorizada').sort((a,b)=>String(b.dps?.result_at||'').localeCompare(String(a.dps?.result_at||''))).slice(0,6);
 const nameOf=(id:number|null)=>companies.find(c=>c.id===id)?.name||'—';
 return <>
  <div className="metrics dashTiles">{tiles.map(([title,value,sub,filter,tone])=><button type="button" className={'metric tile '+tone} key={title} onClick={()=>openNotes(filter)}><span>{title}</span><strong>{value}</strong><small>{sub}</small></button>)}</div>
  <div className="twoColumn">
   <section className="card"><div className="sectionHead"><div><h2>Últimas notas autorizadas</h2><p>As mais recentes primeiro.</p></div><button className="textBtn" onClick={()=>openNotes({situation:'NFS-e autorizada'})}>Ver todas <ArrowUpRight size={15}/></button></div>
    {latest.length?<div className="tableWrap"><table><thead><tr><th>Tomador</th><th>Competência</th><th>Valor</th><th></th></tr></thead><tbody>{latest.map(n=><tr key={n.id}><td><strong>{n.raw.nome_tomador}</strong><small>{nameOf(n.company_id)}{n.dps?.environment==='1'?'':' · teste'}</small></td><td>{n.raw.competencia?.split('-').reverse().join('/')}</td><td>{money(n.amount_cents)}</td><td>{n.dps?.has_danfse&&<a className="textBtn" href={'/api/dps/'+n.dps.id+'/danfse.pdf'}><Download size={14}/> DANFSe</a>}</td></tr>)}</tbody></table></div>:<p className="muted">Nenhuma nota autorizada ainda. Emita pela tela Notas.</p>}
   </section>
   <section className="card"><h2>Por empresa</h2><p className="muted">Competência de {monthName(month)}.</p>
    <div className="tableWrap"><table><thead><tr><th>Empresa</th><th>Ambiente</th><th>Autorizadas</th><th>Valor</th></tr></thead><tbody>{companies.map(c=>{const mine=authorizedMonth.filter(n=>n.company_id===c.id);return <tr key={c.id}><td>{c.name}</td><td>{c.config?.ambiente==='1'?<span className="badge red">Produção</span>:<span className="badge">Testes</span>}</td><td>{mine.length}</td><td>{money(mine.reduce((s,n)=>s+n.amount_cents,0))}</td></tr>})}</tbody></table></div>
    {!companies.length&&<p className="muted">Cadastre a primeira empresa em Empresas.</p>}
   </section>
  </div>
 </>;
}
