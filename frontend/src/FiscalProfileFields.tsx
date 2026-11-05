type Profile={op_simp_nac:string;reg_ap_trib_sn:string|null;reg_esp_trib:string;totals_mode:string;simples_percent:string|null;include_provider_im:boolean;include_iss_rate:boolean;series:string};

// Starting point that the restricted API accepted for an ME/EPP in the Simples (E0120: omit IM; E0625: omit rate). Always reviewed per company.
const DEFAULT:Profile={op_simp_nac:'3',reg_ap_trib_sn:'1',reg_esp_trib:'0',totals_mode:'simples_percent',simples_percent:'6.00',include_provider_im:false,include_iss_rate:false,series:'1'};

export function FiscalProfileFields({value,onChange}:{value:Profile|undefined|null;onChange:(p:Profile|null)=>void}){
 if(!value)return <fieldset className="wide fiscalProfile"><legend>Perfil fiscal para emissão</legend><p className="muted">Sem perfil, as notas desta empresa não podem ser emitidas. O perfil guarda as escolhas tributárias usadas em toda emissão.</p><button type="button" onClick={()=>onChange({...DEFAULT})}>Configurar perfil fiscal</button></fieldset>;
 const set=(patch:Partial<Profile>)=>onChange({...value,...patch});
 return <fieldset className="wide fiscalProfile"><legend>Perfil fiscal para emissão</legend>
  <p className="muted">Usado em toda emissão desta empresa. Confira com a situação cadastral e as regras do município; alterar o perfil revalida as notas na próxima emissão.</p>
  <div className="formGrid">
   <label>Série da DPS<input required pattern="[0-9]{1,4}|[0-8][0-9]{4}" maxLength={5} value={value.series} onChange={e=>set({series:e.target.value})}/></label>
   <label>Situação no Simples Nacional<select value={value.op_simp_nac} onChange={e=>{const v=e.target.value;set({op_simp_nac:v,reg_ap_trib_sn:v==='3'?value.reg_ap_trib_sn||'1':null,...(v!=='3'?{totals_mode:'not_informed',simples_percent:null}:{})})}}><option value="1">Não optante</option><option value="2">MEI</option><option value="3">ME/EPP optante pelo SN</option></select></label>
   {value.op_simp_nac==='3'&&<label>Regime de apuração SN<select value={value.reg_ap_trib_sn||'1'} onChange={e=>set({reg_ap_trib_sn:e.target.value})}><option value="1">Federais e ISS no SN</option><option value="2">Federais no SN e ISS fora</option><option value="3">Federais e ISS fora do SN</option></select></label>}
   <label>Regime especial municipal<select value={value.reg_esp_trib} onChange={e=>set({reg_esp_trib:e.target.value})}><option value="0">Nenhum</option><option value="1">Cooperativa</option><option value="2">Estimativa</option><option value="3">Microempresa municipal</option><option value="4">Notário/registrador</option><option value="5">Profissional autônomo</option><option value="6">Sociedade de profissionais</option><option value="9">Outros</option></select></label>
   <label>Inscrição municipal no XML<select value={value.include_provider_im?'include':'omit'} onChange={e=>set({include_provider_im:e.target.value==='include'})}><option value="omit">Omitir (exigido quando o CNC não tem complemento — E0120)</option><option value="include">Incluir a IM cadastrada</option></select></label>
   <label>Alíquota de ISS no XML<select value={value.include_iss_rate?'include':'omit'} onChange={e=>set({include_iss_rate:e.target.value==='include'})}><option value="omit">Omitir (ME/EPP no SN sem retenção — E0625)</option><option value="include">Incluir a alíquota da nota</option></select></label>
   <label>Tributos totais<select value={value.totals_mode} onChange={e=>set({totals_mode:e.target.value,simples_percent:e.target.value==='simples_percent'?value.simples_percent||'6.00':null})}><option value="not_informed">Não informar estimativa</option>{value.op_simp_nac==='3'&&<option value="simples_percent">Percentual total do Simples</option>}</select></label>
   {value.totals_mode==='simples_percent'&&<label>Percentual total SN (%)<input required type="number" min="0" max="100" step="0.01" value={value.simples_percent||''} onChange={e=>set({simples_percent:e.target.value})}/></label>}
  </div>
  <button type="button" className="textBtn" onClick={()=>onChange(null)}>Remover perfil fiscal</button>
 </fieldset>;
}
