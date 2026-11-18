import React from 'react';
import {FiscalProfileFields, EnvironmentField, REGIMES, profileForRegime} from './FiscalProfileFields';
import {MunicipioPicker} from './MunicipioPicker';
import {documentStatus, formatDocument, onlyDigits} from './documents';

type Api=(path:string,method?:string,data?:any)=>Promise<any>;
type Row=Record<string,any>;
// Older free-text fields kept for reference; they are never sent in the XML.
const OTHER:Record<string,string>={enquadramento:'Enquadramento',codigo_tributacao_nacional:'Código de tributação nacional habitual',codigo_tributacao_municipal:'Código de tributação municipal habitual',iss:'Observações sobre o ISS',credenciamento:'Credenciamento (declarado)',autenticacao:'Forma de autenticação (sem senhas)',procuracao:'Procuração (declarada)'};

// 0.14.0: guided company (prestador) form: identification, city by name, tax regime in plain words, emission settings.
export function CompanyForm({api,value,onChange,isAdmin}:{api:Api;value:Row;onChange:(v:Row)=>void;isAdmin:boolean}){
 const config=value.config||{};
 const set=(patch:Row)=>onChange({...value,...patch});
 const setConfig=(patch:Row)=>onChange({...value,config:{...config,...patch}});
 const doc=documentStatus(value.cnpj||'');
 const regime=REGIMES.find(r=>r.value===config.regime);
 function chooseRegime(v:string){const r=REGIMES.find(x=>x.value===v);if(!r)return;setConfig({regime:r.value,perfil_fiscal:profileForRegime(r.op,config.perfil_fiscal,r.value)})}
 return <div className="wide guidedForm">
  <fieldset><legend>1. Identificação</legend><div className="formGrid">
   <label>CNPJ<input required inputMode="numeric" value={value.cnpj||''} disabled={!!value.id} onChange={e=>set({cnpj:e.target.value})} onBlur={e=>doc.ok&&set({cnpj:formatDocument(e.target.value)})} aria-invalid={!!value.cnpj&&!(doc.ok&&doc.kind==='cnpj')}/>{value.id?<small>O CNPJ não muda depois do cadastro.</small>:value.cnpj&&<small className={doc.ok&&doc.kind==='cnpj'?'okText':'rowError'}>{doc.kind==='cpf'?'Informe o CNPJ da empresa (não CPF).':doc.message}</small>}</label>
   <label>Razão social<input required minLength={2} maxLength={200} value={value.name||''} onChange={e=>set({name:e.target.value})}/></label>
   <label>Nome fantasia (opcional)<input value={config.fantasia||''} onChange={e=>setConfig({fantasia:e.target.value})}/></label>
   <label>Inscrição municipal<input value={config.inscricao_municipal||''} onChange={e=>setConfig({inscricao_municipal:e.target.value})}/><small>Como consta no cadastro da prefeitura.</small></label>
  </div></fieldset>
  <fieldset><legend>2. Município do estabelecimento</legend><div className="formGrid">
   <MunicipioPicker api={api} label="Cidade" required value={config.municipio_ibge||''} onChange={(codigo,nome)=>setConfig({municipio_ibge:codigo,municipio:nome})}/>
   <p className="muted">É o município emissor da nota (cLocEmi) e entra no número da DPS.</p>
  </div></fieldset>
  <fieldset><legend>3. Regime tributário</legend>
   <div className="regimeOptions" role="radiogroup" aria-label="Regime tributário">{REGIMES.map(r=><label key={r.value} className={'regimeOption'+(config.regime===r.value?' selected':'')}><input type="radio" name="regime" required checked={config.regime===r.value} onChange={()=>chooseRegime(r.value)}/><strong>{r.label}</strong><small>{r.hint}</small></label>)}</div>
   {config.regime&&!regime&&<p className="rowError">Regime antigo "{config.regime}": escolha uma das opções acima.</p>}
  </fieldset>
  {config.perfil_fiscal&&<details className="advanced" open={!value.id}><summary>4. Ajustes da emissão (série, inscrição e alíquota no XML)</summary><FiscalProfileFields hideRegime regime={config.regime} value={config.perfil_fiscal} onChange={p=>setConfig(p?{perfil_fiscal:p}:{perfil_fiscal:null,ambiente:'2'})}/></details>}
  {isAdmin&&<EnvironmentField value={config.ambiente} hasProfile={!!config.perfil_fiscal} onChange={v=>setConfig({ambiente:v})}/>}
  <details className="advanced"><summary>Outras informações (opcional, não vão para a nota)</summary><div className="formGrid">{Object.entries(OTHER).map(([k,label])=><label key={k}>{label}<input value={config[k]||''} onChange={e=>setConfig({[k]:e.target.value})}/></label>)}</div></details>
 </div>;
}

/** Problems that block saving, in plain words (the API validates again). */
export function companyProblems(value:Row):string[]{
 const c=value.config||{},out:string[]=[];const d=documentStatus(value.cnpj||'');
 if(!value.id&&!(d.ok&&d.kind==='cnpj'))out.push('CNPJ válido');
 if(!value.name||value.name.trim().length<2)out.push('razão social');
 if(!/^\d{7}$/.test(c.municipio_ibge||''))out.push('cidade escolhida na lista');
 if(!REGIMES.some(r=>r.value===c.regime))out.push('regime tributário');
 return out;
}
export const companyPayload=(v:Row)=>({...v,cnpj:onlyDigits(v.cnpj||'')});
