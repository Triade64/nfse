import {useEffect, useState, type FormEvent} from 'react';

type Draft={id:number;batch_id:number;raw:Record<string,string>};
const options={
 op_simp_nac:[['1','Não optante'],['2','MEI'],['3','ME/EPP optante pelo SN']],
 reg_ap_trib_sn:[['1','Federais e ISS no SN'],['2','Federais no SN e ISS fora'],['3','Federais e ISS fora do SN']],
 reg_esp_trib:[['0','Nenhum'],['1','Cooperativa'],['2','Estimativa'],['3','Microempresa municipal'],['4','Notário/registrador'],['5','Profissional autônomo'],['6','Sociedade de profissionais'],['9','Outros']],
 totals_mode:[['not_informed','Não informar estimativa (indTotTrib=0)'],['simples_percent','Informar percentual total do Simples']],
 iss_rate:[['omit','Omitir alíquota neste XML'],['include','Incluir a alíquota do rascunho']],
};
type Choice=keyof typeof options;
export function DpsPreviewPanel(){
 const [drafts,setDrafts]=useState<Draft[]>([]),[id,setId]=useState(''),[cnpj,setCnpj]=useState('');
 const [form,setForm]=useState<Record<string,string>>({series:'',number:'',issued_at:'',op_simp_nac:'',reg_ap_trib_sn:'',reg_esp_trib:'',totals_mode:'',iss_rate:'',simples_percent:''});
 const [confirmed,setConfirmed]=useState(false),[busy,setBusy]=useState(false),[error,setError]=useState(''),[done,setDone]=useState('');
 useEffect(()=>{let active=true;fetch('/api/drafts').then(async r=>{if(!r.ok)throw Error('Não foi possível listar os rascunhos.');return r.json()}).then(rows=>{if(active)setDrafts(rows)}).catch(e=>{if(active)setError(e.message)});return()=>{active=false}},[]);
 const draft=drafts.find(d=>String(d.id)===id);
 function field(key:string,value:string){setForm(f=>({...f,[key]:value}));setDone('')}
 function select(key:Choice,label:string){return <label>{label}<select required value={form[key]} onChange={e=>field(key,e.target.value)}><option value="">Selecione após conferir</option>{options[key].map(([value,text])=><option key={value} value={value}>{text}</option>)}</select></label>}
 async function prepare(event:FormEvent){
  event.preventDefault();if(!draft)return;setBusy(true);setError('');setDone('');
  try{
   const batch=await fetch('/api/batches/'+draft.batch_id);if(!batch.ok)throw Error('Reabra o lote para conferir sua versão.');const b=await batch.json();
   const response=await fetch('/api/drafts/'+id+'/restricted-preview',{method:'POST',headers:{'Content-Type':'application/json','X-Requested-With':'nfse-local'},body:JSON.stringify({revision:b.revision,expected_raw:draft.raw,own_company_cnpj:cnpj,confirm_offline:confirmed,confirm_scope:confirmed,series:form.series,number:form.number,issued_at:new Date(form.issued_at).toISOString(),op_simp_nac:form.op_simp_nac,reg_ap_trib_sn:form.op_simp_nac==='3'?form.reg_ap_trib_sn:null,reg_esp_trib:form.reg_esp_trib,totals_mode:form.totals_mode,simples_percent:form.totals_mode==='simples_percent'?form.simples_percent:null,include_iss_rate:form.iss_rate==='include'})});
   const result=await response.json();if(!response.ok)throw Error(typeof result.detail==='string'?result.detail:'Confira os campos da preparação fiscal.');
   const url=URL.createObjectURL(new Blob([result.xml],{type:'application/xml;charset=utf-8'}));const a=document.createElement('a');a.href=url;a.download='Triade_DPS_Previa_Teste.xml';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);setDone(result.warning+' Abra o arquivo no conector 0.8 para conferir e assinar localmente.');
  }catch(e){setError((e as Error).message)}finally{setBusy(false)}
 }
 return <section className="card"><h2>Preparar DPS de teste — sem envio</h2><p>Escolha um rascunho do próprio escritório. Esta etapa gera um XML no leiaute de produção restrita recebido em 20/10/2026 e confere sua estrutura no XSD. Não altera a nota, não reserva numeração e não a envia.</p><p className="warning">Protótipo limitado: emissão pelo prestador, NFS-e regular, prestação nacional, operação tributável de ISS, sem retenções, descontos, deduções, benefícios, suspensão ou grupos IBS/CBS. Se a operação exigir qualquer um desses campos, aguarde a ampliação do gerador. A conferência do XSD não valida regras fiscais ou municipais.</p>
 <form onSubmit={prepare}><label>Rascunho<select required value={id} onChange={e=>{setId(e.target.value);setConfirmed(false);setDone('')}}><option value="">Selecione o documento do escritório</option>{drafts.map(d=><option value={d.id} key={d.id}>#{d.id} · {d.raw.cnpj_emitente} · {d.raw.nome_tomador} · {d.raw.competencia}</option>)}</select></label>
 {draft&&<p>Emitente: <strong>{draft.raw.cnpj_emitente}</strong> · Tomador: {draft.raw.nome_tomador} · Competência: {draft.raw.competencia} · Valor: R$ {draft.raw.valor_servico} · Alíquota cadastrada: {draft.raw.iss_aliquota}%</p>}
 <div className="formGrid"><label>CNPJ do próprio escritório<input required inputMode="numeric" pattern="[0-9]{14}" maxLength={14} value={cnpj} onChange={e=>setCnpj(e.target.value)} placeholder="14 dígitos, sem pontuação"/></label><label>Série de teste (não reservada)<input required pattern="[0-9]{1,4}|[0-8][0-9]{4}" maxLength={5} value={form.series} onChange={e=>field('series',e.target.value)}/></label><label>Número da DPS de teste (não reservado)<input required pattern="[1-9][0-9]{0,14}" maxLength={15} value={form.number} onChange={e=>field('number',e.target.value)}/></label><label>Emissão — fuso deste computador<input required type="datetime-local" value={form.issued_at} onChange={e=>field('issued_at',e.target.value)}/></label>
 {select('op_simp_nac','Situação no Simples Nacional')}{form.op_simp_nac==='3'&&select('reg_ap_trib_sn','Regime de apuração SN')}{select('reg_esp_trib','Regime especial municipal')}{select('iss_rate','Informação da alíquota de ISS')}{select('totals_mode','Informação dos tributos totais')}{form.totals_mode==='simples_percent'&&<label>Percentual total SN<input required type="number" min="0" max="100" step="0.01" value={form.simples_percent} onChange={e=>field('simples_percent',e.target.value)}/></label>}</div>
 <label className="checkLabel"><input type="checkbox" required checked={confirmed} onChange={e=>setConfirmed(e.target.checked)}/>Confirmei que o emitente é o próprio escritório, conferi os dados e as escolhas tributárias e a operação cabe nas limitações descritas. Autorizo somente gerar a prévia offline de teste.</label>
 {error&&<p role="alert" className="rowError">{error}</p>}{done&&<p role="status">{done}</p>}<button className="primary" disabled={busy||!draft||!confirmed}>{busy?'Conferindo XML…':'Validar XSD e baixar prévia XML'}</button></form></section>
}
