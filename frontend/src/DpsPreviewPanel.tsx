import {useEffect, useState, type FormEvent} from 'react';

type Draft={id:number;batch_id:number;raw:Record<string,string>};
const options={
 im_mode:[['omit','Omitir do XML'],['include','Incluir a IM cadastrada']],
 op_simp_nac:[['1','Não optante'],['2','MEI'],['3','ME/EPP optante pelo SN']],
 reg_ap_trib_sn:[['1','Federais e ISS no SN'],['2','Federais no SN e ISS fora'],['3','Federais e ISS fora do SN']],
 reg_esp_trib:[['0','Nenhum'],['1','Cooperativa'],['2','Estimativa'],['3','Microempresa municipal'],['4','Notário/registrador'],['5','Profissional autônomo'],['6','Sociedade de profissionais'],['9','Outros']],
 totals_mode:[['not_informed','Não informar estimativa (indTotTrib=0)'],['simples_percent','Informar percentual total do Simples']],
 iss_rate:[['omit','Omitir alíquota neste XML'],['include','Incluir a alíquota do rascunho']],
};
type Choice=keyof typeof options;
export function DpsPreviewPanel(){
 const [drafts,setDrafts]=useState<Draft[]>([]),[id,setId]=useState(''),[cnpj,setCnpj]=useState('');
 const [form,setForm]=useState<Record<string,string>>({series:'',number:'',issued_at:'',op_simp_nac:'',reg_ap_trib_sn:'',reg_esp_trib:'',totals_mode:'',iss_rate:'',im_mode:'',simples_percent:''});
 const [confirmed,setConfirmed]=useState(false),[busy,setBusy]=useState(false),[error,setError]=useState(''),[done,setDone]=useState('');
 const [mode,setMode]=useState<'preview'|'reserve'>('preview');const reserve=mode==='reserve';
 useEffect(()=>{let active=true;fetch('/api/drafts').then(async r=>{if(!r.ok)throw Error('Não foi possível listar os rascunhos.');return r.json()}).then(rows=>{if(active)setDrafts(rows)}).catch(e=>{if(active)setError(e.message)});return()=>{active=false}},[]);
 const draft=drafts.find(d=>String(d.id)===id);
 function field(key:string,value:string){setForm(f=>({...f,[key]:value}));setDone('')}
 function select(key:Choice,label:string){return <label>{label}<select required value={form[key]} onChange={e=>field(key,e.target.value)}><option value="">Selecione após conferir</option>{options[key].map(([value,text])=><option key={value} value={value}>{text}</option>)}</select></label>}
 async function prepare(event:FormEvent){
  event.preventDefault();if(!draft)return;setBusy(true);setError('');setDone('');
  try{
   const batch=await fetch('/api/batches/'+draft.batch_id);if(!batch.ok)throw Error('Reabra o lote para conferir sua versão.');const b=await batch.json();
   const fiscal={op_simp_nac:form.op_simp_nac,reg_ap_trib_sn:form.op_simp_nac==='3'?form.reg_ap_trib_sn:null,reg_esp_trib:form.reg_esp_trib,totals_mode:form.totals_mode,simples_percent:form.totals_mode==='simples_percent'?form.simples_percent:null,include_provider_im:form.im_mode==='include',include_iss_rate:form.iss_rate==='include'};
   const body=reserve?{revision:b.revision,expected_raw:draft.raw,own_company_cnpj:cnpj,confirm_reserve:confirmed,confirm_scope:confirmed,series:form.series,...fiscal}:{revision:b.revision,expected_raw:draft.raw,own_company_cnpj:cnpj,confirm_offline:confirmed,confirm_scope:confirmed,series:form.series,number:form.number,issued_at:form.issued_at+'-03:00',...fiscal};
   const response=await fetch('/api/drafts/'+id+(reserve?'/dps':'/restricted-preview'),{method:'POST',headers:{'Content-Type':'application/json','X-Requested-With':'nfse-local'},body:JSON.stringify(body)});
   const result=await response.json();if(!response.ok)throw Error(typeof result.detail==='string'?result.detail:'Confira os campos da preparação fiscal.');
   if(reserve){
    const a=document.createElement('a');a.href='/api/dps/'+result.id+'/xml';a.download=result.identifier+'.xml';a.click();
    setDone((result.existing?'Este rascunho já tinha DPS reservada: ':'Reservada: ')+'série '+result.series+', número '+result.number+'. O XML gravado foi baixado. Assine e envie pelo conector 0.8.5.');
   }else{
    const url=URL.createObjectURL(new Blob([result.xml],{type:'application/xml;charset=utf-8'}));const a=document.createElement('a');a.href=url;a.download='Triade_DPS_Previa_Teste.xml';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);setDone(result.warning+' Abra o arquivo no conector 0.8.5 para conferir e assinar localmente.');
   }
  }catch(e){setError((e as Error).message)}finally{setBusy(false)}
 }
 return <section className="card"><h2>Preparar DPS de teste — sem envio</h2><p>Escolha um rascunho do próprio escritório. Esta etapa gera um XML no leiaute de produção restrita recebido em 20/10/2026 e confere sua estrutura no XSD. O site não assina nem envia: isso continua no conector.</p>
 <label>Numeração<select value={mode} onChange={e=>{setMode(e.target.value as 'preview'|'reserve');setConfirmed(false);setDone('')}}><option value="preview">Prévia sem reserva (série e número informados manualmente)</option><option value="reserve">Reservar o próximo número da série (numeração central)</option></select></label>
 {reserve&&<p className="warning">A reserva consome o número definitivamente, mesmo que a DPS não seja enviada, e bloqueia a edição do lote. A data/hora de emissão é a do servidor, em horário de Brasília.</p>}<p className="warning">Protótipo limitado: emissão pelo prestador, NFS-e regular, prestação nacional, operação tributável de ISS, sem retenções, descontos, deduções, benefícios, suspensão ou grupos IBS/CBS. Se a operação exigir qualquer um desses campos, aguarde a ampliação do gerador. A conferência do XSD não valida regras fiscais ou municipais.</p>
 <form onSubmit={prepare}><label>Rascunho<select required value={id} onChange={e=>{setId(e.target.value);setConfirmed(false);setDone('')}}><option value="">Selecione o documento do escritório</option>{drafts.map(d=><option value={d.id} key={d.id}>#{d.id} · {d.raw.cnpj_emitente} · {d.raw.nome_tomador} · {d.raw.competencia}</option>)}</select></label>
 {draft&&<p>Emitente: <strong>{draft.raw.cnpj_emitente}</strong> · Tomador: {draft.raw.nome_tomador} · Competência: {draft.raw.competencia} · Valor: R$ {draft.raw.valor_servico} · Alíquota cadastrada: {draft.raw.iss_aliquota}%</p>}
 <div className="formGrid"><label>CNPJ do próprio escritório<input required inputMode="numeric" pattern="[0-9]{14}" maxLength={14} value={cnpj} onChange={e=>setCnpj(e.target.value)} placeholder="14 dígitos, sem pontuação"/></label><label>{reserve?'Série (numeração central)':'Série de teste (não reservada)'}<input required pattern="0{0,4}([1-9][0-9]{0,3}|[1-4][0-9]{4})" title="De 1 a 49999: faixa do aplicativo próprio (regra E0010)" maxLength={5} value={form.series} onChange={e=>field('series',e.target.value)}/></label>{!reserve&&<><label>Número da DPS de teste (não reservado)<input required pattern="[1-9][0-9]{0,14}" maxLength={15} value={form.number} onChange={e=>field('number',e.target.value)}/></label><label>Emissão — horário de Brasília<input required type="datetime-local" value={form.issued_at} onChange={e=>field('issued_at',e.target.value)}/></label></>}
 {select('op_simp_nac','Situação no Simples Nacional')}{form.op_simp_nac==='3'&&select('reg_ap_trib_sn','Regime de apuração SN')}{select('reg_esp_trib','Regime especial municipal')}{select('im_mode','Inscrição municipal no XML — conferir exigência do CNC')}{select('iss_rate','Informação da alíquota de ISS')}{select('totals_mode','Informação dos tributos totais')}{form.totals_mode==='simples_percent'&&<label>Percentual total SN<input required type="number" min="0" max="100" step="0.01" value={form.simples_percent} onChange={e=>field('simples_percent',e.target.value)}/></label>}</div>
 <label className="checkLabel"><input type="checkbox" required checked={confirmed} onChange={e=>setConfirmed(e.target.checked)}/>Confirmei que o emitente é o próprio escritório, conferi os dados e as escolhas tributárias e a operação cabe nas limitações descritas. {reserve?'Autorizo reservar definitivamente o próximo número desta série para este rascunho.':'Autorizo somente gerar a prévia offline de teste.'}</label>
 {error&&<p role="alert" className="rowError">{error}</p>}{done&&<p role="status">{done}</p>}<button className="primary" disabled={busy||!draft||!confirmed}>{busy?'Conferindo XML…':reserve?'Reservar número e baixar DPS':'Validar XSD e baixar prévia XML'}</button></form></section>
}

type Company={id:number;cnpj:string;name:string};
type Series={id:number;environment:string;series:string;next_number:number;revision:number};
const ENV_LABEL:Record<string,string>={'1':'Produção','2':'Produção restrita'};
export function DpsSeriesPanel(){
 const [companies,setCompanies]=useState<Company[]>([]),[companyId,setCompanyId]=useState(''),[series,setSeries]=useState<Series[]>([]);
 const [form,setForm]=useState({environment:'2',series:'',next_number:''}),[confirmed,setConfirmed]=useState(false),[error,setError]=useState(''),[done,setDone]=useState('');
 useEffect(()=>{fetch('/api/companies').then(r=>r.ok?r.json():[]).then(setCompanies).catch(()=>setError('Não foi possível listar as empresas.'))},[]);
 async function load(id:string){setCompanyId(id);setSeries([]);if(!id)return;const r=await fetch('/api/companies/'+id+'/dps-series');if(r.ok)setSeries(await r.json())}
 async function save(event:FormEvent){
  event.preventDefault();setError('');setDone('');
  const current=series.find(s=>s.environment===form.environment&&s.series===String(Number(form.series)));
  const r=await fetch('/api/companies/'+companyId+'/dps-series',{method:'PUT',headers:{'Content-Type':'application/json','X-Requested-With':'nfse-local'},body:JSON.stringify({series:form.series,next_number:Number(form.next_number),expected_revision:current?current.revision:null,confirm_unused:confirmed,environment:form.environment})});
  const result=await r.json();if(!r.ok){setError(typeof result.detail==='string'?result.detail:'Confira série e número.');return}
  setDone(ENV_LABEL[result.environment]+', série '+result.series+': próximo número '+result.next_number+'.');setConfirmed(false);await load(companyId);
 }
 return <section className="card"><h2>Numeração de DPS</h2><p>Defina, por empresa, ambiente e série, o próximo número a reservar. Cada ambiente tem numeração própria; use séries de 1 a 49999 (aplicativo próprio, regra E0010). Em produção, comece uma série nova do aplicativo (ex.: série 1, nº 1), diferente da série do Emissor Web (70000). Informe um número <strong>maior que qualquer DPS já enviada</strong> nessa série, inclusive testes feitos no conector com número digitado manualmente. A numeração só avança e nunca é reutilizada.</p>
 <label>Empresa<select value={companyId} onChange={e=>load(e.target.value)}><option value="">Selecione</option>{companies.map(c=><option key={c.id} value={c.id}>{c.name} · {c.cnpj}</option>)}</select></label>
 {companyId&&<><table><thead><tr><th>Ambiente</th><th>Série</th><th>Próximo número</th></tr></thead><tbody>{series.length?series.map(s=><tr key={s.id}><td>{s.environment==='1'?<span className="badge red">Produção</span>:'Produção restrita'}</td><td>{s.series}</td><td>{s.next_number}</td></tr>):<tr><td colSpan={3}>Nenhuma série configurada.</td></tr>}</tbody></table>
 <form onSubmit={save}><div className="formGrid"><label>Ambiente<select value={form.environment} onChange={e=>setForm(f=>({...f,environment:e.target.value}))}><option value="2">Produção restrita (testes)</option><option value="1">Produção (validade jurídica)</option></select></label><label>Série<input required pattern="0{0,4}([1-9][0-9]{0,3}|[1-4][0-9]{4})" title="De 1 a 49999: faixa do aplicativo próprio (regra E0010)" maxLength={5} value={form.series} onChange={e=>setForm(f=>({...f,series:e.target.value}))}/></label><label>Próximo número<input required inputMode="numeric" pattern="[1-9][0-9]{0,14}" maxLength={15} value={form.next_number} onChange={e=>setForm(f=>({...f,next_number:e.target.value}))}/></label></div>
 <label className="checkLabel"><input type="checkbox" required checked={confirmed} onChange={e=>setConfirmed(e.target.checked)}/>Conferi que nenhuma DPS desta empresa e série foi enviada com número igual ou maior.</label>
 {error&&<p role="alert" className="rowError">{error}</p>}{done&&<p role="status">{done}</p>}<button className="primary" disabled={!confirmed}>Salvar numeração</button></form></>}</section>
}

type DpsRow={id:number;identifier:string;series:string|null;number:number|null;status:string|null;created_at:string|null;discard_reason:string|null};
export function DpsListPanel(){
 const [rows,setRows]=useState<DpsRow[]>([]),[target,setTarget]=useState<number|null>(null),[reason,setReason]=useState(''),[confirmed,setConfirmed]=useState(false),[error,setError]=useState(''),[done,setDone]=useState('');
 async function load(){const r=await fetch('/api/dps');if(r.ok)setRows(await r.json());else setError('Não foi possível listar as DPS.')}
 useEffect(()=>{load()},[]);
 async function discard(event:FormEvent){
  event.preventDefault();setError('');setDone('');
  const r=await fetch('/api/dps/'+target+'/discard',{method:'POST',headers:{'Content-Type':'application/json','X-Requested-With':'nfse-local'},body:JSON.stringify({reason,confirm_not_authorized:confirmed})});
  const result=await r.json();if(!r.ok){setError(typeof result.detail==='string'?result.detail:'Informe o motivo (mínimo 5 caracteres) e confirme.');return}
  setDone('DPS série '+result.series+' nº '+result.number+' descartada. O número não será reutilizado; o rascunho pode reservar um novo número.');setTarget(null);setReason('');setConfirmed(false);await load();
 }
 return <section className="card"><h2>DPS reservadas</h2><p>Descarte uma reserva que não será enviada (por exemplo, número que coincide com um teste antigo do conector). O número continua ocupado e nunca é reutilizado; o rascunho fica livre para reservar o próximo número.</p>
 {done&&<p role="status">{done}</p>}{error&&!target&&<p role="alert" className="rowError">{error}</p>}
 <table><thead><tr><th>Série / nº</th><th>Situação</th><th>Reservada em</th><th>Ações</th></tr></thead><tbody>{rows.length?rows.map(d=><tr key={d.id}><td>{d.series} / {d.number}</td><td>{d.status}{d.discard_reason?' — '+d.discard_reason:''}</td><td>{d.created_at?new Date(d.created_at).toLocaleString('pt-BR'):''}</td><td><a className="button" href={'/api/dps/'+d.id+'/xml'} download={d.identifier+'.xml'}>XML</a>{d.status==='Reservada'&&<button type="button" onClick={()=>{setTarget(d.id);setError('');setDone('')}}>Descartar</button>}</td></tr>):<tr><td colSpan={4}>Nenhuma DPS reservada.</td></tr>}</tbody></table>
 {target!==null&&<form onSubmit={discard}><label>Motivo do descarte<input required minLength={5} maxLength={500} value={reason} onChange={e=>setReason(e.target.value)}/></label>
 <label className="checkLabel"><input type="checkbox" required checked={confirmed} onChange={e=>setConfirmed(e.target.checked)}/>Confirmo que esta DPS não foi autorizada: não foi enviada, ou o conector registrou rejeição. Descartar uma DPS autorizada permitiria emitir a mesma nota duas vezes.</label>
 {error&&<p role="alert" className="rowError">{error}</p>}<div className="actions"><button className="primary" disabled={!confirmed}>Descartar reserva</button><button type="button" onClick={()=>setTarget(null)}>Cancelar</button></div></form>}</section>
}
