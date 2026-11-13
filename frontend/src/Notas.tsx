import React, {useEffect, useMemo, useState, type FormEvent} from 'react';
import {Copy, Plus, Pencil, Send, Download, Trash2, Search, RefreshCw, X} from 'lucide-react';
import {readableError, hasInvalidValue} from './labels';
import {WAITING, isWaiting, type NotesFilter} from './Dashboard';

type Data=Record<string,any>;
type Api=(path:string,method?:string,data?:any)=>Promise<any>;
export type Note={id:number;batch_id:number;batch_revision:number;company_id:number|null;raw:Record<string,string>;errors:string[];amount_cents:number;situation:string;dps:Data|null;editable:boolean;address_missing?:boolean};

const money=(c:number)=>new Intl.NumberFormat('pt-BR',{style:'currency',currency:'BRL'}).format((c||0)/100);
const fmtNbs=(d:string)=>/^\d{9}$/.test(d)?`${d[0]}.${d.slice(1,5)}.${d.slice(5,7)}.${d.slice(7)}`:d;
const dateBR=(iso:string)=>iso?iso.split('-').reverse().join('/'):'—';
const tone=(s:string)=>s==='Pronta'||s==='NFS-e autorizada'?'green':s==='Com inconsistência'||s==='DPS rejeitada'?'red':s.startsWith('DPS')?'blue':'orange';
const blank=():Record<string,string>=>({cnpj_emitente:'',documento_tomador:'',nome_tomador:'',competencia:'',municipio_ibge:'',descricao_servico:'',codigo_tributacao_nacional:'',codigo_tributacao_municipal:'',codigo_nbs:'',valor_servico:'',iss_aliquota:'',iss_retido:'nao',retencoes:'{}',observacoes:''});
const SITUATIONS=['Pronta','Com inconsistência','Rascunho','DPS reservada','DPS em consulta','NFS-e autorizada','DPS rejeitada'];
const SENDABLE=['Reservada','Desconhecida'];
// An authorized NFS-e without the official PDF can go back to the connector only to fetch the DANFSe.
const needsDanfse=(n:Note)=>!!n.dps&&n.dps.status==='Autorizada'&&!n.dps.has_danfse;
const launchable=(n:Note)=>!!n.dps&&(SENDABLE.includes(n.dps.status)||needsDanfse(n));

function Dialog({title,close,children}:{title:string;close:()=>void;children:React.ReactNode}){
 return <div className="overlay"><section className="modal" role="dialog" aria-modal="true" aria-label={title}><header><h2>{title}</h2><button className="icon" onClick={close} aria-label="Fechar"><X size={20}/></button></header>{children}</section></div>;
}

export function Notas({api,companies,customers,services,role,initialFilter={}}:{api:Api;companies:Data[];customers:Data[];services:Data[];role:string;initialFilter?:NotesFilter}){
 const [notes,setNotes]=useState<Note[]>([]),[loaded,setLoaded]=useState(false),[busy,setBusy]=useState(false),[error,setError]=useState(''),[notice,setNotice]=useState('');
 const [query,setQuery]=useState(''),[company,setCompany]=useState(''),[situation,setSituation]=useState(initialFilter.situation||''),[month,setMonth]=useState(initialFilter.month||''),[environment,setEnvironment]=useState('');
 const [checked,setChecked]=useState<number[]>([]);
 const [dup,setDup]=useState<Note[]|null>(null),[dupDate,setDupDate]=useState(''),[dupOk,setDupOk]=useState(false),[requestId,setRequestId]=useState(()=>crypto.randomUUID());
 const [emitting,setEmitting]=useState<Note|null>(null),[emitOk,setEmitOk]=useState(false),[realOk,setRealOk]=useState(false),[percent,setPercent]=useState(''),[openConnector,setOpenConnector]=useState(true);
 const [waiting,setWaiting]=useState<number[]>([]),[launchUrl,setLaunchUrl]=useState('');
 const [discarding,setDiscarding]=useState<Note|null>(null),[reason,setReason]=useState(''),[discardOk,setDiscardOk]=useState(false);
 const [editing,setEditing]=useState<{note?:Note;raw:Record<string,string>}|null>(null),[nbs,setNbs]=useState<Data[]>([]);
 useEffect(()=>{if(editing&&!nbs.length)api('/nbs').then(setNbs).catch(()=>{/* the field still accepts a typed code */})},[editing]);
 const canEdit=['admin','operator','approver'].includes(role),isAdmin=role==='admin';
 const companyOf=(id:number|null|undefined)=>companies.find(c=>c.id===id);

 async function run(fn:()=>Promise<void>){setBusy(true);setError('');try{await fn()}catch(e){setError((e as Error).message)}finally{setBusy(false)}}
 async function load(){setNotes(await api('/notes'));setLoaded(true)}
 useEffect(()=>{run(load)},[]);

 const pending=notes.filter(n=>n.dps&&waiting.includes(n.dps.id)&&(SENDABLE.includes(n.dps.status)||(needsDanfse(n)&&!n.dps.danfse_error)));
 useEffect(()=>{if(!waiting.length)return;const started=Date.now();const timer=setInterval(()=>{if(Date.now()-started>15*60*1000){setWaiting([]);return}load().catch(()=>{})},5000);return()=>clearInterval(timer)},[waiting]);
 useEffect(()=>{if(waiting.length&&notes.length&&!pending.length){const done=notes.filter(n=>n.dps&&waiting.includes(n.dps.id));const ok=done.filter(n=>n.dps!.status==='Autorizada').length;setWaiting([]);setNotice(`Conector concluiu: ${ok} autorizada${ok!==1?'s':''}, ${done.length-ok} com outro resultado. Confira cada linha.`)}},[notes]);
 // Environment of a note: its DPS when emitted, otherwise the company's current choice.
 const envOf=(n:Note)=>n.dps?.environment||(companyOf(n.company_id)?.config.ambiente==='1'?'1':'2');
 const visible=useMemo(()=>notes.filter(n=>(!company||String(n.company_id)===company)&&(!situation||(situation===WAITING?isWaiting(n):n.situation===situation))&&(!environment||envOf(n)===environment)&&(!month||n.raw.competencia?.startsWith(month))&&(!query||(n.raw.nome_tomador+' '+n.raw.documento_tomador+' '+n.raw.descricao_servico).toLowerCase().includes(query.toLowerCase()))),[notes,company,situation,month,query,environment,companies]);
 const selected=notes.filter(n=>checked.includes(n.id));

 async function launch(ids:number[]){const t=await api('/connector/tickets','POST',{dps_ids:ids});setWaiting(ids);setLaunchUrl(t.url);window.location.href=t.url}
 async function sendSelected(list:Note[]){await run(async()=>{const ids=list.filter(launchable).map(n=>n.dps!.id);if(!ids.length)throw Error('Nenhuma nota selecionada com DPS reservada, em consulta ou sem DANFSe.');await launch(ids);setNotice(`Abrindo o conector para ${ids.length} nota${ids.length>1?'s':''}…`)})}
 async function openEmit(n:Note){setEmitting(n);setEmitOk(false);setRealOk(false);setOpenConnector(true);setPercent('');setNotice('');setError('');if(companyOf(n.company_id)?.config.perfil_fiscal?.op_simp_nac==='3'){try{const d=await api('/companies/'+n.company_id+'/fiscal-defaults');if(d.last_simples_percent)setPercent(d.last_simples_percent)}catch{/* prefill is optional */}}}
 function openDuplicate(list:Note[]){setDup(list);setDupDate('');setDupOk(false);setRequestId(crypto.randomUUID());setNotice('')}
 async function submitDuplicate(e:FormEvent){e.preventDefault();if(!dup)return;await run(async()=>{const r=await api('/notes/duplicate','POST',{draft_ids:dup.map(n=>n.id),competencia:dupDate,confirm_review:dupOk,request_id:requestId});setDup(null);setChecked([]);await load();setNotice(`${r.created.length} nota${r.created.length>1?'s':''} criada${r.created.length>1?'s':''} para ${dateBR(dupDate)}. Confira e emita.`)})}
 async function submitEmit(e:FormEvent){e.preventDefault();if(!emitting)return;await run(async()=>{const asks=companyOf(emitting.company_id)?.config.perfil_fiscal?.op_simp_nac==='3';const production=companyOf(emitting.company_id)?.config.ambiente==='1';const r=await api('/notes/'+emitting.id+'/emit','POST',{batch_revision:emitting.batch_revision,expected_raw:emitting.raw,confirm:emitOk,...(production?{confirm_production:realOk}:{}),...(asks?{simples_percent:percent.replace(',','.')}:{})});setEmitting(null);await load();if(openConnector){await launch([r.id]);setNotice(`${r.existing?'Esta nota já tinha DPS: ':'DPS reservada: '}série ${r.series}, nº ${r.number}. Abrindo o conector para assinar e enviar…`)}else{const a=document.createElement('a');a.href='/api/dps/'+r.id+'/xml';a.download=r.identifier+'.xml';a.click();setNotice(`${r.existing?'Esta nota já tinha DPS: ':'DPS reservada: '}série ${r.series}, nº ${r.number}. O XML foi baixado — assine e envie pelo conector.`)}})}
 async function submitDiscard(e:FormEvent){e.preventDefault();if(!discarding?.dps)return;await run(async()=>{const r=await api('/dps/'+discarding.dps!.id+'/discard','POST',{reason,confirm_not_authorized:discardOk});setDiscarding(null);await load();setNotice(`DPS série ${r.series} nº ${r.number} descartada. A nota pode ser emitida com um novo número.`)})}
 async function submitEdit(e:FormEvent){e.preventDefault();if(!editing)return;await run(async()=>{
  if(editing.note)await api('/drafts/'+editing.note.id,'PUT',{raw:editing.raw,revision:editing.note.batch_revision});
  else await api('/batches','POST',{name:(editing.raw.nome_tomador||'Nota')+' · '+editing.raw.competencia,rows:[editing.raw]});
  setEditing(null);await load();setNotice('Nota salva e validada.')})}

 function nbsLabel(v:string){if(!v)return '';const f=fmtNbs(v.replace(/\D/g,'').length===9?v.replace(/\D/g,''):v);const hit=nbs.find(x=>x.formatted===f);return hit?f+' — '+hit.description:v}
 function field(key:string,value:string){setEditing(ed=>ed&&({...ed,raw:{...ed.raw,[key]:value}}))}
 function chooseCompany(id:string){const c=companies.find(c=>String(c.id)===id);setEditing(ed=>ed&&({...ed,raw:{...ed.raw,cnpj_emitente:c?.cnpj||'',municipio_ibge:ed.raw.municipio_ibge||c?.config.municipio_ibge||'',documento_tomador:'',nome_tomador:''}}))}
 const editCompany=editing?companies.find(c=>c.cnpj===editing.raw.cnpj_emitente):undefined;
 let taxes:Data={};try{taxes=JSON.parse(editing?.raw.retencoes||'{}')||{}}catch{taxes={}}

 return <section className="card notes">
  <div className="sectionHead"><span/>
   <div className="buttonRow">{isAdmin&&selected.some(launchable)&&<button onClick={()=>sendSelected(selected)}><Send size={16}/> Abrir conector ({selected.filter(launchable).length})</button>}{canEdit&&checked.length>0&&<button onClick={()=>openDuplicate(selected)}><Copy size={16}/> Duplicar {checked.length} selecionada{checked.length>1?'s':''}</button>}{canEdit&&<button className="primary" onClick={()=>setEditing({raw:{...blank(),cnpj_emitente:companies.length===1?companies[0].cnpj:'',municipio_ibge:companies.length===1?companies[0].config.municipio_ibge||'':''}})}><Plus size={16}/> Nova nota</button>}</div></div>
  <div className="toolbar filters"><Search size={18}/><input aria-label="Buscar notas" placeholder="Tomador, documento ou serviço" value={query} onChange={e=>setQuery(e.target.value)}/>
   <select aria-label="Filtrar empresa" value={company} onChange={e=>setCompany(e.target.value)}><option value="">Todas as empresas</option>{companies.map(c=><option key={c.id} value={c.id}>{c.name}</option>)}</select>
   <select aria-label="Filtrar situação" value={situation} onChange={e=>setSituation(e.target.value)}><option value="">Todas as situações</option><option value={WAITING}>{WAITING}</option>{SITUATIONS.map(s=><option key={s}>{s}</option>)}</select>
   <select aria-label="Filtrar ambiente" value={environment} onChange={e=>setEnvironment(e.target.value)}><option value="">Todos os ambientes</option><option value="1">Produção (notas reais)</option><option value="2">Testes</option></select>
   <label className="inlineLabel">Competência<input aria-label="Filtrar competência" type="month" value={month} onChange={e=>setMonth(e.target.value)}/></label>
   <button aria-label="Atualizar lista" disabled={busy} onClick={()=>run(load)}><RefreshCw size={16}/></button></div>
  {notice&&<div className="success" role="status">{notice}</div>}{pending.length>0&&<div className="warning" role="note">Aguardando o conector para {pending.length} nota{pending.length>1?'s':''}. Se o conector não abriu, instale-o e ative a abertura pelo site em Configurações{launchUrl&&<>, ou <a href={launchUrl}>clique aqui para abrir de novo</a></>}. A lista atualiza sozinha.</div>}{error&&!dup&&!emitting&&!discarding&&!editing&&<div className="error" role="alert">{error}</div>}
  {loaded&&<div className="resultsTotal">{visible.length} nota{visible.length!==1?'s':''} <strong>{money(visible.filter(n=>!hasInvalidValue(n.errors)).reduce((s,n)=>s+n.amount_cents,0))}</strong></div>}
  <div className="tableWrap"><table><thead><tr><th><input type="checkbox" aria-label="Selecionar todas as notas visíveis" checked={visible.length>0&&visible.every(n=>checked.includes(n.id))} onChange={e=>setChecked(e.target.checked?visible.map(n=>n.id):[])}/></th><th>Tomador / serviço</th><th>Empresa</th><th>Competência</th><th>Valor</th><th>Situação</th><th>Ações</th></tr></thead>
  <tbody>{visible.map(n=><tr key={n.id}>
   <td><input type="checkbox" aria-label={'Selecionar '+n.raw.nome_tomador} checked={checked.includes(n.id)} onChange={e=>setChecked(prev=>e.target.checked?[...prev,n.id]:prev.filter(id=>id!==n.id))}/></td>
   <td><strong>{n.raw.nome_tomador||'Tomador não informado'}</strong><small>{n.raw.descricao_servico}</small>{n.raw.codigo_nbs&&<small>NBS {fmtNbs(n.raw.codigo_nbs)}</small>}</td>
   <td>{companyOf(n.company_id)?.name||n.raw.cnpj_emitente}</td><td>{dateBR(n.raw.competencia)}</td><td>{hasInvalidValue(n.errors)?<span className="muted" title="Valor inválido">—</span>:money(n.amount_cents)}</td>
   <td><span className={'badge '+tone(n.situation)}>{n.situation}</span>{envOf(n)==='1'?<span className="badge envTag prod" title="Nota real, com validade jurídica">PRODUÇÃO</span>:<span className="badge envTag" title="Produção restrita, sem validade jurídica">TESTE</span>}{n.dps&&<small>DPS série {n.dps.series} · nº {n.dps.number}</small>}{n.dps?.access_key&&<small title={n.dps.access_key}>Chave …{String(n.dps.access_key).slice(-12)}</small>}{n.dps?.status==='Rejeitada'&&n.dps.result?.codes&&<small className="rowError">SEFIN: {n.dps.result.codes}</small>}{needsDanfse(n)&&n.dps?.danfse_error&&<small className="rowError">DANFSe pendente ({n.dps.danfse_error})</small>}{waiting.includes(n.dps?.id)&&n.dps&&SENDABLE.includes(n.dps.status)&&<small>Aguardando o conector…</small>}{n.errors.map(s=><small className="rowError" key={s}>{readableError(s)}</small>)}{n.address_missing&&!n.dps&&<small className="rowError">Tomador com CNPJ sem endereço completo (E0235). Complete em Tomadores antes de emitir.</small>}</td>
   <td><div className="entryActions">
    {canEdit&&n.editable&&<button className="textBtn" onClick={()=>{setEditing({note:n,raw:{...blank(),...n.raw}});setNotice('')}}><Pencil size={15}/> Editar</button>}
    {canEdit&&<button className="textBtn" onClick={()=>openDuplicate([n])}><Copy size={15}/> Duplicar</button>}
    {isAdmin&&n.situation==='Pronta'&&!n.address_missing&&<button className="textBtn" onClick={()=>openEmit(n)}><Send size={15}/> Emitir</button>}
    {isAdmin&&n.dps&&SENDABLE.includes(n.dps.status)&&<button className="textBtn" onClick={()=>sendSelected([n])}><Send size={15}/> {n.dps.status==='Desconhecida'?'Consultar no conector':'Assinar e enviar'}</button>}{n.dps?.has_danfse&&<a className="textBtn" href={'/api/dps/'+n.dps.id+'/danfse.pdf'}><Download size={15}/> DANFSe</a>}{isAdmin&&needsDanfse(n)&&<button className="textBtn" onClick={()=>sendSelected([n])}><Download size={15}/> Buscar DANFSe</button>}{n.dps?.status==='Autorizada'?<a className="textBtn" href={'/api/dps/'+n.dps.id+'/nfse.xml'}><Download size={15}/> XML NFS-e</a>:n.dps&&<a className="textBtn" href={'/api/dps/'+n.dps.id+'/xml'} download={n.dps.identifier+'.xml'}><Download size={15}/> XML</a>}
    {isAdmin&&(n.dps?.status==='Reservada'||n.dps?.status==='Rejeitada')&&<button className="textBtn" onClick={()=>{setDiscarding(n);setReason('');setDiscardOk(false);setNotice('')}}><Trash2 size={15}/> Descartar</button>}
   </div></td></tr>)}</tbody></table></div>
  {!loaded&&!error&&<p className="muted">Carregando notas…</p>}{loaded&&!visible.length&&<p className="muted">{notes.length?'Nenhuma nota neste filtro.':'Nenhuma nota ainda. Use “Nova nota” ou importe uma planilha em Lotes e importação.'}</p>}

  {dup&&<Dialog title={dup.length>1?`Duplicar ${dup.length} notas`:'Duplicar nota'} close={()=>setDup(null)}><form onSubmit={submitDuplicate}>
   <p>{dup.length>1?`${dup.length} notas, total ${money(dup.reduce((s,n)=>s+n.amount_cents,0))}.`:`${dup[0].raw.nome_tomador} · ${money(dup[0].amount_cents)} · competência atual ${dateBR(dup[0].raw.competencia)}`}</p>
   <label>Nova competência<input required type="date" value={dupDate} onChange={e=>{setDupDate(e.target.value);setRequestId(crypto.randomUUID())}}/></label>
   <p className="muted">Tomador, serviço, valor e tributos são copiados. Cada cópia nasce validada e pode ser editada antes de emitir. Não é possível criar nota idêntica na mesma competência.</p>
   <label className="checkLabel"><input type="checkbox" checked={dupOk} onChange={e=>setDupOk(e.target.checked)}/>Conferi que valor, descrição e tributos continuam corretos para a nova competência.</label>
   {error&&<div className="error" role="alert">{error}</div>}
   <div className="modalActions"><button type="button" onClick={()=>setDup(null)}>Cancelar</button><button className="primary" disabled={busy||!dupDate||!dupOk}><Copy size={16}/> Duplicar</button></div></form></Dialog>}

  {emitting&&(()=>{const c=companyOf(emitting.company_id),p=c?.config.perfil_fiscal,production=c?.config.ambiente==='1';return <Dialog title={production?'Emitir NOTA REAL (produção)':'Emitir nota'} close={()=>setEmitting(null)}><form onSubmit={submitEmit}>
   <div className="reportRow"><strong>{emitting.raw.nome_tomador}</strong><span>{money(emitting.amount_cents)} · competência {dateBR(emitting.raw.competencia)}</span></div>
   <p>Emitente: <strong>{c?.name}</strong> ({c?.cnpj})</p>
   {p?<p className="muted">Perfil fiscal: série {p.series} · {p.op_simp_nac==='3'?'ME/EPP optante do Simples':p.op_simp_nac==='2'?'MEI':'Não optante'} · IM {p.include_provider_im?'incluída':'omitida'} · alíquota {p.include_iss_rate?'incluída':'omitida'}</p>:<div className="warning">Esta empresa ainda não tem perfil fiscal. Configure em Empresas → Editar.</div>}
   {p?.op_simp_nac==='3'&&<label>Percentual aproximado dos tributos do Simples (%)<input required inputMode="decimal" pattern="[0-9]{1,3}([.,][0-9]{1,2})?" value={percent} onChange={e=>setPercent(e.target.value)} placeholder="Alíquota efetiva deste mês, ex.: 6,54"/><small>Obrigatório para ME/EPP (E0712). Use a alíquota efetiva do mês; o campo traz o último percentual usado.</small></label>}
   {production?<div className="danger" role="note"><strong>PRODUÇÃO — NOTA REAL, COM VALIDADE JURÍDICA.</strong> A NFS-e será autorizada pela SEFIN Nacional de produção. Para corrigir depois, só cancelando ou substituindo no Emissor Nacional. O site reserva o número; a assinatura e o envio continuam no conector, no PC com o certificado.</div>:<div className="warning">Produção restrita (testes). O site reserva o próximo número e baixa o XML; a assinatura e o envio continuam no conector, no PC com o certificado.</div>}
   <label className="checkLabel"><input type="checkbox" checked={emitOk} onChange={e=>setEmitOk(e.target.checked)}/>Conferi emitente, tomador, competência e valor. Autorizo reservar o próximo número desta série.</label>
   {production&&<label className="checkLabel"><input type="checkbox" checked={realOk} onChange={e=>setRealOk(e.target.checked)}/>Confirmo que esta é uma NOTA REAL, com validade jurídica, e que os dados estão corretos.</label>}
   <label className="checkLabel"><input type="checkbox" checked={openConnector} onChange={e=>setOpenConnector(e.target.checked)}/>Abrir o conector deste PC para assinar e enviar em seguida (desmarque para só baixar o XML).</label>
   {error&&<div className="error" role="alert">{error}</div>}
   <div className="modalActions"><button type="button" onClick={()=>setEmitting(null)}>Cancelar</button><button className="primary" disabled={busy||!emitOk||(production&&!realOk)||!p||(p.op_simp_nac==='3'&&!/^[0-9]{1,3}([.,][0-9]{1,2})?$/.test(percent))}><Send size={16}/> Reservar e baixar XML</button></div></form></Dialog>})()}

  {discarding&&<Dialog title="Descartar reserva" close={()=>setDiscarding(null)}><form onSubmit={submitDiscard}>
   <p>DPS série {discarding.dps?.series} nº {discarding.dps?.number} · {discarding.raw.nome_tomador}. O número fica ocupado e nunca é reutilizado; a nota volta a poder ser emitida.</p>
   <label>Motivo do descarte<input required minLength={5} maxLength={500} value={reason} onChange={e=>setReason(e.target.value)}/></label>
   <label className="checkLabel"><input type="checkbox" checked={discardOk} onChange={e=>setDiscardOk(e.target.checked)}/>Confirmo que esta DPS não foi autorizada: não foi enviada, ou o conector registrou rejeição.</label>
   {error&&<div className="error" role="alert">{error}</div>}
   <div className="modalActions"><button type="button" onClick={()=>setDiscarding(null)}>Cancelar</button><button className="primary" disabled={busy||!discardOk||reason.trim().length<5}>Descartar reserva</button></div></form></Dialog>}

  {editing&&<Dialog title={editing.note?'Editar nota':'Nova nota'} close={()=>setEditing(null)}><form onSubmit={submitEdit}><div className="formGrid">
   <label>Empresa emitente<select required value={editCompany?.id||''} onChange={e=>chooseCompany(e.target.value)}><option value="">Selecione</option>{companies.map(c=><option key={c.id} value={c.id}>{c.name}</option>)}</select></label>
   <label>Tomador cadastrado<select value={customers.find(t=>t.company_id===editCompany?.id&&t.document===editing.raw.documento_tomador)?.id||''} onChange={e=>{const t=customers.find(t=>String(t.id)===e.target.value);if(t){field('documento_tomador',t.document);field('nome_tomador',t.name)}}}><option value="">Preencher manualmente</option>{customers.filter(t=>t.company_id===editCompany?.id).map(t=><option key={t.id} value={t.id}>{t.name} · {t.document}</option>)}</select></label>
   <label>CPF / CNPJ do tomador<input required value={editing.raw.documento_tomador} onChange={e=>field('documento_tomador',e.target.value)}/></label>
   <label>Nome do tomador<input required value={editing.raw.nome_tomador} onChange={e=>field('nome_tomador',e.target.value)}/></label>
   <label>Modelo de serviço<select value="" onChange={e=>{const s=services.find(s=>String(s.id)===e.target.value);if(s)setEditing(ed=>ed&&({...ed,raw:{...ed.raw,descricao_servico:s.config.descricao||s.name,codigo_tributacao_nacional:s.config.codigo_tributacao_nacional||'',codigo_tributacao_municipal:s.config.codigo_tributacao_municipal||'',codigo_nbs:s.config.codigo_nbs||ed.raw.codigo_nbs||'',valor_servico:s.config.valor_habitual||ed.raw.valor_servico}}))}}><option value="">Usar modelo cadastrado</option>{services.filter(s=>s.company_id===editCompany?.id).map(s=><option key={s.id} value={s.id}>{s.name}</option>)}</select></label>
   <label>Competência<input required type="date" value={editing.raw.competencia} onChange={e=>field('competencia',e.target.value)}/></label>
   <label className="wide">Descrição do serviço<textarea required value={editing.raw.descricao_servico} onChange={e=>field('descricao_servico',e.target.value)}/></label>
   <label>Valor (R$)<input required inputMode="decimal" value={editing.raw.valor_servico} onChange={e=>field('valor_servico',e.target.value)}/></label>
   <label>Código tributação nacional<input required value={editing.raw.codigo_tributacao_nacional} onChange={e=>field('codigo_tributacao_nacional',e.target.value)}/></label>
   <label>Código tributação municipal (opcional)<input value={editing.raw.codigo_tributacao_municipal} onChange={e=>field('codigo_tributacao_municipal',e.target.value)}/></label>
   <label>Código NBS (opcional)<input list="nbs-oficial" placeholder="Ex.: 1.1302.21.00 — busque pelo código ou descrição" value={nbsLabel(editing.raw.codigo_nbs)} onChange={e=>field('codigo_nbs',e.target.value.split(' — ')[0])}/><datalist id="nbs-oficial">{nbs.map(x=><option key={x.code} value={x.formatted+' — '+x.description}/>)}</datalist>{editing.raw.codigo_tributacao_nacional==='171901'&&!editing.raw.codigo_nbs&&<button type="button" className="textBtn" onClick={()=>field('codigo_nbs','1.1302.21.00')}>Usar 1.1302.21.00 (Serviços de contabilidade)</button>}<small>Lista NBS 2.0 do Anexo B. Exigido quando houver IBS/CBS ou exportação.</small></label>
   <label>Município da prestação (IBGE)<input required value={editing.raw.municipio_ibge} onChange={e=>field('municipio_ibge',e.target.value)}/></label>
   <label>Alíquota ISS (%)<input required inputMode="decimal" value={editing.raw.iss_aliquota} onChange={e=>field('iss_aliquota',e.target.value)}/></label>
   <label>ISS retido<select value={editing.raw.iss_retido} onChange={e=>field('iss_retido',e.target.value)}><option value="nao">Não</option><option value="sim">Sim</option></select></label>
   {['irrf','pis','cofins','csll','inss'].map(k=><label key={k}>Retenção {k.toUpperCase()} (R$)<input inputMode="decimal" value={taxes[k]||''} onChange={e=>{const next={...taxes};if(e.target.value)next[k]=e.target.value;else delete next[k];field('retencoes',JSON.stringify(next))}}/></label>)}
   <label className="wide">Observações (opcional)<input value={editing.raw.observacoes} onChange={e=>field('observacoes',e.target.value)}/></label>
  </div><p className="muted">A validação é cadastral; confira os tributos conforme o caso. Ao salvar, a nota é validada.</p>
  {error&&<div className="error" role="alert">{error}</div>}
  <div className="modalActions"><button type="button" onClick={()=>setEditing(null)}>Cancelar</button><button className="primary" disabled={busy}>Salvar nota</button></div></form></Dialog>}
 </section>;
}
