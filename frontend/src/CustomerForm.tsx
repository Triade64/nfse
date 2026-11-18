import React from 'react';
import {MunicipioPicker} from './MunicipioPicker';
import {documentStatus, formatDocument, onlyCep, onlyDigits} from './documents';

type Api=(path:string,method?:string,data?:any)=>Promise<any>;
type Row=Record<string,any>;
const ADDRESS=['cep','logradouro','numero','bairro','municipio_ibge'];

// 0.14.0: guided customer (tomador) form. The address is required for CNPJ customers (rule E0235), optional for CPF.
export function CustomerForm({api,value,onChange,companies}:{api:Api;value:Row;onChange:(v:Row)=>void;companies:Row[]}){
 const details=value.details||{};
 const set=(patch:Row)=>onChange({...value,...patch});
 const setDetails=(patch:Row)=>onChange({...value,details:{...details,...patch}});
 const doc=documentStatus(value.document||'');
 const needsAddress=doc.kind==='cnpj';
 const anyAddress=ADDRESS.some(k=>details[k]);
 return <div className="wide guidedForm">
  <fieldset><legend>1. Quem emite</legend><div className="formGrid">
   <label>Empresa emitente<select required value={value.company_id||''} disabled={!!value.id} onChange={e=>set({company_id:Number(e.target.value)})}><option value="">Selecione</option>{companies.map(c=><option key={c.id} value={c.id}>{c.name}</option>)}</select>{value.id?<small>O tomador fica vinculado a esta empresa.</small>:<small>O tomador fica disponível nas notas desta empresa.</small>}</label>
  </div></fieldset>
  <fieldset><legend>2. Tomador</legend><div className="formGrid">
   <label>CPF ou CNPJ<input required inputMode="numeric" value={value.document||''} onChange={e=>set({document:e.target.value})} onBlur={e=>doc.ok&&set({document:formatDocument(e.target.value)})} aria-invalid={!!value.document&&!doc.ok}/>{value.document&&<small className={doc.ok?'okText':'rowError'}>{doc.message}</small>}</label>
   <label>{doc.kind==='cnpj'?'Razão social':'Nome completo'}<input required minLength={2} maxLength={200} value={value.name||''} onChange={e=>set({name:e.target.value})}/></label>
   <label>E-mail (opcional)<input type="email" value={details.email||''} onChange={e=>setDetails({email:e.target.value})}/></label>
   <label>Telefone (opcional)<input inputMode="tel" value={details.telefone||''} onChange={e=>setDetails({telefone:e.target.value})}/></label>
  </div></fieldset>
  <fieldset><legend>3. Endereço {needsAddress?<span className="badge red">obrigatório para CNPJ</span>:<span className="badge">opcional para CPF</span>}</legend>
   {needsAddress&&<p className="muted">Para tomador com CNPJ a NFS-e exige o endereço completo (regra E0235). Sem ele, a nota não pode ser emitida.</p>}
   <div className="formGrid">
    <label>CEP<input inputMode="numeric" required={needsAddress||anyAddress} maxLength={9} value={details.cep||''} onChange={e=>setDetails({cep:e.target.value})} onBlur={e=>{const c=onlyCep(e.target.value);if(c.length===8)setDetails({cep:c.replace(/(\d{5})(\d{3})/,'$1-$2')})}}/></label>
    <MunicipioPicker api={api} label="Cidade" required={needsAddress||anyAddress} value={details.municipio_ibge||''} onChange={codigo=>setDetails({municipio_ibge:codigo})}/>
    <label className="wide">Logradouro<input required={needsAddress||anyAddress} maxLength={255} placeholder="Rua, avenida…" value={details.logradouro||''} onChange={e=>setDetails({logradouro:e.target.value})}/></label>
    <label>Número<input required={needsAddress||anyAddress} maxLength={60} placeholder="S/N se não houver" value={details.numero||''} onChange={e=>setDetails({numero:e.target.value})}/></label>
    <label>Complemento (opcional)<input maxLength={156} value={details.complemento||''} onChange={e=>setDetails({complemento:e.target.value})}/></label>
    <label>Bairro<input required={needsAddress||anyAddress} maxLength={60} value={details.bairro||''} onChange={e=>setDetails({bairro:e.target.value})}/></label>
   </div>
  </fieldset>
  <details className="advanced"><summary>Observações internas (opcional, não vão para a nota)</summary><label>Observações<textarea maxLength={1000} value={details.dados_fiscais||''} onChange={e=>setDetails({dados_fiscais:e.target.value})}/></label></details>
 </div>;
}

export function customerProblems(value:Row):string[]{
 const d=value.details||{},out:string[]=[];const doc=documentStatus(value.document||'');
 if(!value.company_id)out.push('empresa emitente');
 if(!doc.ok)out.push('CPF ou CNPJ válido');
 if(!value.name||value.name.trim().length<2)out.push('nome');
 const filled=ADDRESS.some(k=>d[k]);
 if(doc.kind==='cnpj'||filled){if(onlyCep(d.cep||'').length!==8)out.push('CEP com 8 dígitos');if(!/^\d{7}$/.test(d.municipio_ibge||''))out.push('cidade escolhida na lista');for(const [k,l] of [['logradouro','logradouro'],['numero','número'],['bairro','bairro']])if(!(d[k]||'').trim())out.push(l)}
 return out;
}
export const customerPayload=(v:Row)=>({...v,document:onlyDigits(v.document||''),details:{...(v.details||{}),cep:onlyCep((v.details||{}).cep||'')}});
