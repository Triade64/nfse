type Profile={op_simp_nac:string;reg_ap_trib_sn:string|null;reg_esp_trib:string;totals_mode:string;include_provider_im:boolean;include_iss_rate:boolean;series:string};

// Starting point the restricted API accepted for an ME/EPP in the Simples: omit IM (E0120), omit ISS rate (E0625),
// and inform the Simples percentage at each emission (E0712). Always reviewed per company.
const DEFAULT:Profile={op_simp_nac:'3',reg_ap_trib_sn:'1',reg_esp_trib:'0',totals_mode:'simples_percent',include_provider_im:false,include_iss_rate:false,series:'1'};

export function FiscalProfileFields({value,onChange}:{value:(Profile&{simples_percent?:unknown})|undefined|null;onChange:(p:Profile|null)=>void}){
 if(!value)return <fieldset className="wide fiscalProfile"><legend>Perfil fiscal para emissão</legend><p className="muted">Sem perfil, as notas desta empresa não podem ser emitidas. O perfil guarda as escolhas tributárias usadas em toda emissão.</p><button type="button" onClick={()=>onChange({...DEFAULT})}>Configurar perfil fiscal</button></fieldset>;
 const {simples_percent:_legacy,...current}=value;
 const set=(patch:Partial<Profile>)=>onChange({...current,...patch});
 return <fieldset className="wide fiscalProfile"><legend>Perfil fiscal para emissão</legend>
  <p className="muted">Usado em toda emissão desta empresa. Confira com a situação cadastral e as regras do município; alterar o perfil revalida as notas na próxima emissão.</p>
  <div className="formGrid">
   <label>Série da DPS<input required pattern="[0-9]{1,4}|[0-8][0-9]{4}" maxLength={5} value={current.series} onChange={e=>set({series:e.target.value})}/></label>
   <label>Situação no Simples Nacional<select value={current.op_simp_nac} onChange={e=>{const v=e.target.value;set({op_simp_nac:v,reg_ap_trib_sn:v==='3'?current.reg_ap_trib_sn||'1':null,totals_mode:v==='3'?'simples_percent':'not_informed'})}}><option value="1">Não optante</option><option value="2">MEI</option><option value="3">ME/EPP optante pelo SN</option></select></label>
   {current.op_simp_nac==='3'&&<label>Regime de apuração SN<select value={current.reg_ap_trib_sn||'1'} onChange={e=>set({reg_ap_trib_sn:e.target.value})}><option value="1">Federais e ISS no SN</option><option value="2">Federais no SN e ISS fora</option><option value="3">Federais e ISS fora do SN</option></select></label>}
   <label>Regime especial municipal<select value={current.reg_esp_trib} onChange={e=>set({reg_esp_trib:e.target.value})}><option value="0">Nenhum</option><option value="1">Cooperativa</option><option value="2">Estimativa</option><option value="3">Microempresa municipal</option><option value="4">Notário/registrador</option><option value="5">Profissional autônomo</option><option value="6">Sociedade de profissionais</option><option value="9">Outros</option></select></label>
   <label>Inscrição municipal no XML<select value={current.include_provider_im?'include':'omit'} onChange={e=>set({include_provider_im:e.target.value==='include'})}><option value="omit">Omitir (exigido quando o CNC não tem complemento — E0120)</option><option value="include">Incluir a IM cadastrada</option></select></label>
   <label>Alíquota de ISS no XML<select value={current.include_iss_rate?'include':'omit'} onChange={e=>set({include_iss_rate:e.target.value==='include'})}><option value="omit">Omitir (ME/EPP no SN sem retenção — E0625)</option><option value="include">Incluir a alíquota da nota</option></select></label>
   <p className="wide muted">Tributos totais: {current.op_simp_nac==='3'?'percentual aproximado do Simples, informado a cada emissão (obrigatório para ME/EPP — E0712). O campo vem preenchido com o último percentual usado.':'não informar estimativa.'}</p>
  </div>
  <button type="button" className="textBtn" onClick={()=>onChange(null)}>Remover perfil fiscal</button>
 </fieldset>;
}
